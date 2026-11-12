// UI salle LiveKit.
//
// Un unique point d'entrée qui gère les trois rôles (host, speaker, viewer) :
// le rôle N'EST PAS lu dans le DOM — il est DÉCIDÉ CÔTÉ SERVEUR par
// `POST /api/token`. Le composant :
//
//   1. lit slug (+ speaker_token éventuel) depuis les data-attrs du container ;
//   2. POST /api/token avec CSRF header (Rails omakase) ;
//   3. HOST/SPEAKER : affiche <StagePreJoin> (prejoin.jsx : aperçu
//      caméra, sélecteurs périphériques, toggles on/off, nom) —
//      l'utilisateur choisit explicitement ses périphériques AVANT de
//      rejoindre la salle, pré-remplis par ses préférences mémorisées
//      (device_preferences.js, livrées avec le token) ;
//   4. onSubmit(userChoices) → monte <LiveKitRoom> avec audio/video ciblés
//      sur les deviceId retenus (ou false si l'utilisateur a coupé) ; un
//      intervenant sans accord à l'image rejoint micro et caméra coupés, la
//      fenêtre de consentement les rallume (participant_consent.jsx) ;
//   5. VIEWER : monte <LiveKitRoom> directement (subscribe-only, aucun
//      choix de périphérique — pas de publication) ; un inscrit qui n'a
//      jamais choisi « J'observe » ou « Je participe » choisit d'abord, avant
//      même le jeton (participation_choice.js) ;
//   6. une fois la salle quittée (« Quitter », expulsion, salle fermée,
//      connexion perdue) : <RoomExit> remplace la salle.
//
// Volontairement AUCUN mapping "url→rôle" côté client : si on donnait au
// front la moindre autorité sur le rôle, un spectateur bricoleur pourrait
// obtenir un token host en manipulant le fetch. Toute la décision vit dans
// RoomParticipant#resolve_role, appelé par Api::TokensController (test
// `token_endpoint_role_enforcement`).
//
// FAIL-LOUD MICRO :
// trois étages de panne étaient invisibles côté UI (choix persisté LiveKit,
// gain ALSA effondré, Chrome orphelin d'un restart PipeWire → zéro
// périphérique audio). Le bouton micro restait inerte, sans message.
//
// La bascule vers <PreJoin> transforme ces
// pannes en signaux immédiats : aperçu caméra visible ou noir, dropdowns
// vides ou peuplées, le toggle micro EST l'état explicite. Le hint « 5 s
// après montage micro non publié » est RETIRÉ (le PreJoin gère l'état
// micro explicitement au moment du choix, plus de « où est mon micro »
// implicite). Restent :
//   (a) handler onError du PreJoin → bannière MediaFailureBanner mappée
//       (NotFound / PermissionDenied / DeviceInUse / Other) ;
//   (b) enumerateDevices() au montage du PreJoin : si AUCUN audioinput,
//       on force la bannière NotFound sans attendre le premier submit
//       (couvre "Chrome orphelin PipeWire" où les dropdowns sont vides
//       et où PreJoin lui-même n'émet pas d'erreur explicite).
//
// BUG HOOKS RÉGÉ (crash "Rendered more hooks than during the previous
// render" → page /w/<slug>/stage blanche) : deux `useCallback` étaient déclarés APRÈS les early-returns
// conditionnels loading/error. Règle React : tous les hooks AVANT le
// premier return conditionnel.
//
// Règle fail-loud : jamais avaler une panne silencieusement.

import { createRoot } from "react-dom/client";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  DisconnectButton,
  LiveKitRoom,
  useTracks,
  useParticipants,
  RoomAudioRenderer,
  LayoutContextProvider,
  useCreateLayoutContext,
  usePinnedTracks,
  isTrackReference,
  useRoomContext,
  useConnectionState,
} from "@livekit/components-react";
import { ConnectionState, DisconnectReason, RoomEvent, Track, VideoPresets } from "livekit-client";
import "@livekit/components-styles";
import { csrfToken } from "./state_button";
import { RecordingIndicator } from "./recording_indicator";
import { HandRaiseViewer } from "./hand_raise_viewer";
import { SidePanel } from "./side_panel";
import { QaBanner } from "./qa_banner";
import { RoomControls } from "./room_controls";
import { StagePreJoin } from "./prejoin";
import { DevicePreferencesProvider, RestorePreferredOutput, createDevicePreferences } from "./device_preferences";
import { RoomExit } from "./room_exit";
import { spotlightTrack, useSpotlightIdentity } from "./spotlight";
import { FocusStage, MosaicGrid, useMosaicMode, useStripSide } from "./room_tiles";
import { PollOverlay } from "./poll_overlay";
import { ConsentWithdrawal, ParticipantConsentProvider, awaitsConsent } from "./participant_consent";
import { awaitParticipationChoice } from "./participation_choice";
import { AudioOutputMenu } from "./device_menu";
import { CameraHealth } from "./camera_health";
import { NewTabHint } from "./new_tab_hint";

const MOUNT_ID = "livekit-room";

// Un seul appel réseau au montage. Si la requête échoue on affiche le
// message d'erreur brut (fail-loud — leçon multitrack : jamais avaler
// une panne silencieusement). En dev/test le composant fonctionne même
// hors média réel car LiveKitRoom se contente de tenter la connexion
// WebRTC ; l'échec de connexion s'affiche dans le control bar natif.
async function fetchToken({ slug, speakerToken }) {
  const res = await fetch("/api/token", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      "X-CSRF-Token": csrfToken(),
      "Accept": "application/json",
    },
    body: JSON.stringify({
      slug,
      speaker_token: speakerToken || null,
    }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`token endpoint returned ${res.status}: ${text}`);
  }
  return res.json();
}

// Mapping MediaDeviceFailure → message français exploitable pour l'user.
// Les 4 valeurs suivent l'enum livekit-client (errors.d.ts) : PermissionDenied
// NotFound / DeviceInUse / Other. `kind` (audioinput|videoinput|audiooutput)
// n'est pas toujours renseigné par LiveKit — le message reste utile sans.
function mediaFailureMessage(failure, kind) {
  if (kind === "audiooutput") {
    if (failure === "PermissionDenied") {
      return "Sans accès au micro, le navigateur ne nomme pas les sorties son : le son passe par la sortie du système. "
        + "Pour en choisir une, autorisez le micro (icône cadenas dans la barre d'adresse), puis rechargez la page.";
    }
    return `Sortie son indisponible (${failure || "erreur inconnue"}) : le son passe par la sortie du système. `
      + "Choisissez-en une autre avec le bouton « Son ».";
  }
  const device = kind === "videoinput" ? "caméra"
              : kind === "audioinput" ? "microphone"
              : "périphérique audio/vidéo";
  switch (failure) {
    case "NotFound":
      return `Aucun ${device} détecté par le navigateur. Si le son système vient d'être réparé, redémarrez le navigateur (chrome://restart) pour qu'il re-détecte les périphériques.`;
    case "PermissionDenied":
      return `Accès ${device} refusé. Cliquez l'icône caméra ou cadenas dans la barre d'adresse pour autoriser, puis rechargez la page.`;
    case "DeviceInUse":
      return `Le ${device} est utilisé par une autre application. Fermez l'autre logiciel (Zoom, Meet, OBS…) puis rechargez la page.`;
    default:
      return `Impossible d'accéder au ${device} (${failure || "erreur inconnue"}). Consultez la console du navigateur pour le détail.`;
  }
}

// Adaptateur PreJoin.onError (Error natif DOMException) → forme unifiée
// { failure, kind } consommée par MediaFailureBanner. Les noms DOMException
// suivent la spec MediaDevices (NotFoundError, NotAllowedError,
// NotReadableError = périphérique occupé). Kind non déductible depuis
// l'Error natif — laissé à null, le message reste explicite.
function errorToFailure(err) {
  const name = err && err.name ? String(err.name) : "";
  switch (name) {
    case "NotFoundError":
    case "OverconstrainedError":
      return { failure: "NotFound", kind: null };
    case "NotAllowedError":
    case "SecurityError":
      return { failure: "PermissionDenied", kind: null };
    case "NotReadableError":
    case "AbortError":
      return { failure: "DeviceInUse", kind: null };
    default:
      return { failure: err && err.message ? err.message : "Other", kind: null };
  }
}

// Styles inline volontaires : la vue salle échappe à chrome.css (body.room)
// et @livekit/components-styles ne fournit pas de bannière custom. Un
// composant fail-loud DOIT être visible dès le premier render — style
// inline garantit qu'aucune régression CSS ne le masque. Couleurs = tokens
// de la charte (chargés par layouts/room avant le bundle), variantes
// « -dark » car la salle est toujours sombre (cf. room.css) : texte
// gray.925 sur status-critical-dark ≈ 5,5:1.
const BANNER_STYLE = {
  position: "fixed",
  top: "0.75rem",
  left: "50%",
  transform: "translateX(-50%)",
  zIndex: 1000,
  maxWidth: "min(42rem, calc(100vw - 1.5rem))",
  padding: "0.75rem 2.5rem 0.75rem 1rem",
  background: "var(--status-critical-dark)",
  color: "var(--gray-925)",
  borderRadius: "var(--radius-card)",
  fontFamily: "var(--font-sans)",
  fontSize: "0.95rem",
  lineHeight: 1.4,
};
const BANNER_DISMISS_STYLE = {
  position: "absolute",
  top: "0.25rem",
  right: "0.5rem",
  background: "transparent",
  color: "inherit",
  border: "none",
  fontSize: "1.5rem",
  lineHeight: 1,
  cursor: "pointer",
  padding: "0.25rem 0.5rem",
};

// Bannière fail-loud — role="alert" (SR + a11y), dismissible. Le dismiss
// ne masque QUE la bannière ; la panne sous-jacente reste, un nouveau
// failure la ré-affiche.
function MediaFailureBanner({ error, onDismiss }) {
  return (
    <div style={BANNER_STYLE} role="alert" data-testid="media-error-banner">
      <p style={{ margin: 0 }}>{mediaFailureMessage(error.failure, error.kind)}</p>
      <button
        type="button"
        style={BANNER_DISMISS_STYLE}
        onClick={onDismiss}
        aria-label="Masquer ce message"
      >
        ×
      </button>
    </div>
  );
}

// Note du menu « Son » chez le spectateur : Chrome ne nomme les sorties
// qu'après un accès au micro.
const VIEWER_OUTPUT_NOTE = "Pour nommer vos sorties son, le navigateur peut demander l'accès au micro : "
  + "il n'est ni enregistré ni transmis.";

// Layout SPECTATEUR — subscribe-only, focus sur la scène.
// Pas de barre de contrôle (pas de publication) PAR DÉFAUT ; la prise de
// parole ré-ouvre micro+caméra via HandRaiseViewer dès
// que la permission LiveKit canPublish bascule à true. Compteur de
// présents, agents exclus (le transcripteur n'est pas un présent).
// Panneau latéral (discussion, transcription) : colonne à droite (étroit :
// sous la scène), jamais en surimpression (room.css, `.lk-viewer__column`).
//
// Mise en avant : le spectateur voit ce que la salle
// diffuse (métadonnées LiveKit, spotlight.jsx), sans rien pouvoir changer
// — pas de bouton, pas de ⤢ (aucun LayoutContext ici). En grand : le
// partage d'écran s'il existe, sinon la personne mise en avant ; les
// autres dans la bande de vignettes, à droite comme sur la scène par
// défaut (FocusStage). Sinon la mosaïque, en disposition automatique
// (pas de sélecteur pour le public).
function ViewerLayout({ handRaisesUrl, participantWaiting, recordingNotice, recordingViewerStatusUrl, sidePanel, qaBanner }) {
  const participants = useParticipants();
  const present = participants.filter((p) => !p.isAgent).length;
  const tracks = useTracks(
    [
      { source: Track.Source.Camera, withPlaceholder: false },
      { source: Track.Source.ScreenShare, withPlaceholder: false },
    ],
    { onlySubscribed: true },
  );
  const spotlightIdentity = useSpotlightIdentity();
  const featured = tracks.find((t) => t.source === Track.Source.ScreenShare)
    ?? spotlightTrack(tracks, spotlightIdentity);
  const others = tracks.filter((t) => !isSameTrackRef(t, featured));
  return (
    <div className="lk-viewer">
      <div className="lk-viewer__column">
        <header className="lk-viewer__header">
          <span className="lk-viewer__count" data-testid="participant-count">
            {present} présent{present > 1 ? "s" : ""}
          </span>
          {/* Consentement :
              indicateur passif « Enregistrement en cours » pour le
              spectateur. Monté dès que la data-attr URL est présente
              (= viewer dans la salle live). Le composant se cache si
              aucun enregistrement n'est actif — pas de bruit. */}
          {recordingViewerStatusUrl ? (
            <RecordingIndicator statusUrl={recordingViewerStatusUrl} />
          ) : null}
          {/* Accord à l'image (participant_consent.jsx) : celui qui l'a donné
              en prenant la parole peut le retirer, même la parole rendue. */}
          <ConsentWithdrawal />
          {/* Sortie son : le spectateur
              entend la salle sur le périphérique de son choix. Chrome ne
              nomme les sorties qu'après un accès au micro : on le dit. */}
          <AudioOutputMenu note={VIEWER_OUTPUT_NOTE} />
          {/* Sortie explicite : sans elle, le spectateur
              ne quittait la salle qu'en fermant l'onglet, et ne voyait jamais
              l'écran de sortie. */}
          <DisconnectButton className="lk-viewer__leave">Quitter</DisconnectButton>
        </header>
        {qaBanner}
        <main className="lk-viewer__stage">
          {tracks.length === 0 ? (
            <p className="lk-viewer__waiting">En attente du démarrage…</p>
          ) : featured && others.length > 0 ? (
            <FocusStage focusTrack={featured} otherTracks={others} />
          ) : (
            <MosaicGrid tracks={tracks} />
          )}
        </main>
        {handRaisesUrl ? <HandRaiseViewer endpointUrl={handRaisesUrl} participantWaiting={participantWaiting}
          recordingNotice={recordingNotice} /> : null}
      </div>
      <SidePanel {...sidePanel} />
      <RoomAudioRenderer />
      <RestorePreferredOutput />
    </div>
  );
}

// Nom affiché : posé une fois la room connectée (setName exige la
// connexion ET le grant canUpdateOwnMetadata). Échec = message VISIBLE
// (onError → note sous le compteur, fail-loud strict : jamais la console),
// jamais bloquant : la salle fonctionne avec l'identité serveur.
function NameSync({ displayName, onError }) {
  const room = useRoomContext();
  const state = useConnectionState(room);
  useEffect(() => {
    if (state !== ConnectionState.Connected) return;
    const name = (displayName || "").trim();
    if (!name || room.localParticipant.name === name) return;
    room.localParticipant.setName(name).catch((err) => {
      onError(`Nom affiché non appliqué (${err?.message || "refus serveur"}) — identité par défaut conservée.`);
    });
  }, [room, state, displayName, onError]);
  return null;
}

// État de connexion en français : remplace le toast
// vendor ConnectionStateToast, figé en anglais (« Disconnected » affiché à
// l'animateur). Même emplacement (classe vendor lk-toast), donc
// même place prise. Une sortie de salle après connexion n'arrive pas ici :
// <RoomExit> remplace la salle.
const CONNECTION_NOTICES = {
  [ConnectionState.Connecting]: "Connexion à la salle…",
  [ConnectionState.Reconnecting]: "Connexion perdue, reconnexion…",
  [ConnectionState.SignalReconnecting]: "Connexion perdue, reconnexion…",
  [ConnectionState.Disconnected]: "Connexion impossible",
};

function ConnectionNotice() {
  const notice = CONNECTION_NOTICES[useConnectionState()];
  if (!notice) return null;
  return (
    <div className="lk-toast" role="status" data-testid="connection-notice">
      {notice}
    </div>
  );
}

// Un participant est « sur scène » s'il peut publier (host / speaker), ou
// s'il est intervenant ou co-animateur en attente d'accord à l'image
// (`awaitsConsent`, participant_consent.jsx : tuile sans vidéo, pastille).
// Les spectateurs (canPublish=false) ne reçoivent AUCUNE tuile : avant ce
// filtre, <VideoConference> (withPlaceholder) affichait une case vide
// « viewer-xxxx » PAR spectateur sur la grille de l'animateur — 30
// spectateurs = 30 cases vides (constat en répétition).
// `permissions` est diffusé par le serveur pour chaque participant.
//
// Un agent (transcripteur `agent-AJ_…`, kind AGENT) n'est JAMAIS sur
// scène : il a canPublish pour ses text streams mais aucune image, et
// occupait une tuile avatar par défaut. Il n'est pas
// non plus un spectateur : `isAudience` l'exclut du compteur.
function isOnStage(participant) {
  if (participant.isAgent) return false;
  return participant.isLocal || !!participant.permissions?.canPublish || awaitsConsent(participant);
}

function isAudience(participant) {
  return !participant.isAgent && !isOnStage(participant);
}

// Layout SCÈNE post-PreJoin (host + speaker) — publication autorisée.
// Réplique du prefab <VideoConference> de components-react 2.9 (grille /
// focus auto sur le partage d'écran + barre de contrôle), MOINS le chat
// et les settings, PLUS le filtre isOnStage, le compteur de spectateurs,
// la barre de contrôle française (RoomControls), le mode focus maison
// (FocusStage, à la place du carrousel vendor) et la mosaïque maison
// (MosaicGrid, à la place de GridLayout).
// Périphériques déjà choisis côté PreJoin, passés à LiveKitRoom en props
// audio/video (deviceId ciblés) ; le menu de la barre permet d'en changer.
//
// Mise en page (room.css : tout tassé sur une rangée,
// transcription posée SUR la barre de contrôle et interceptant ses clics) :
// une colonne principale (barre de scène, vidéo, barre de contrôle — dans
// cet ordre, en flux) et, à côté, le panneau latéral (discussion,
// transcription). Aucun élément n'est en surimpression d'un autre ; en
// étroit, le panneau passe sous la colonne.
//
// Mise en avant : la scène affiche ce que voit le
// public — partage d'écran épinglé d'office, sinon la personne mise en
// avant, sinon la grille. Le ⤢ des tuiles reste un zoom LOCAL ; une
// nouvelle mise en avant le lève. Chacun sur scène voit la pastille
// « En avant » ; la commande est dans la régie. En focus, la bande de
// vignettes est à droite par défaut ; sa bascule gauche/droite est
// mémorisée par appareil (useStripSide).
//
// Salle animateur = salle participant
// (« même quelqu'un qui est animateur doit voir la même chose que les
// participants ») : l'animation a ici exactement la scène d'un intervenant
// — micro, caméra, partage d'écran, périphériques, discussion,
// transcription, indicateur d'enregistrement — plus le lien « Régie ↗ »
// (regieUrl), qui ouvre les commandes du direct dans un autre onglet.
//
// Mosaïque : en
// grille, colonnes et rangées sont calculées sur la taille de la zone
// (MosaicGrid). Son sélecteur « Mosaïque » impose une disposition ; choix
// local à la personne, mémorisé par appareil (useMosaicMode). Pas dans la
// barre de scène : à 1000 px, direct et enregistrement en cours, il la
// faisait passer sur deux rangées (48 px pris à la vidéo, mesuré).
function StageLayout({ displayName, deviceSaveError, recordingStatusUrl, regieUrl, sidePanel, qaBanner }) {
  const lastAutoFocusedScreenShareTrack = useRef(null);
  const [nameError, setNameError] = useState(null);
  const allTracks = useTracks(
    [
      { source: Track.Source.Camera, withPlaceholder: true },
      { source: Track.Source.ScreenShare, withPlaceholder: false },
    ],
    { updateOnlyOn: [RoomEvent.ActiveSpeakersChanged], onlySubscribed: false },
  );
  const tracks = useMemo(
    () => allTracks.filter((t) => isOnStage(t.participant)),
    [allTracks],
  );
  const participants = useParticipants();
  const audience = participants.filter(isAudience).length;
  const spotlightIdentity = useSpotlightIdentity();
  const spotlight = { identity: spotlightIdentity };
  const [stripSide, toggleStripSide] = useStripSide();
  const [mosaicMode, setMosaicMode] = useMosaicMode();

  const layoutContext = useCreateLayoutContext();
  const screenShareTracks = tracks
    .filter(isTrackReference)
    .filter((t) => t.publication.source === Track.Source.ScreenShare);
  const pinnedTrack = usePinnedTracks(layoutContext)?.[0];
  const focusTrack = pinnedTrack ?? spotlightTrack(tracks, spotlightIdentity);
  const stripTracks = tracks.filter((t) => !isSameTrackRef(t, focusTrack));
  const showsFocus = !!focusTrack && stripTracks.length > 0;

  // Auto-focus du partage d'écran (même règle que le prefab) : dès qu'un
  // screen share est souscrit, il est épinglé ; quand il disparaît, on
  // désépingle. Un focus posé sur une référence devenue placeholder est
  // ré-aligné sur la vraie publication.
  useEffect(() => {
    if (
      screenShareTracks.some((t) => t.publication.isSubscribed) &&
      lastAutoFocusedScreenShareTrack.current === null
    ) {
      layoutContext.pin.dispatch?.({ msg: "set_pin", trackReference: screenShareTracks[0] });
      lastAutoFocusedScreenShareTrack.current = screenShareTracks[0];
    } else if (
      lastAutoFocusedScreenShareTrack.current &&
      !screenShareTracks.some(
        (t) => t.publication.trackSid === lastAutoFocusedScreenShareTrack.current?.publication?.trackSid,
      )
    ) {
      layoutContext.pin.dispatch?.({ msg: "clear_pin" });
      lastAutoFocusedScreenShareTrack.current = null;
    }
    if (pinnedTrack && !isTrackReference(pinnedTrack)) {
      const updated = tracks.find(
        (t) => t.participant.identity === pinnedTrack.participant.identity && t.source === pinnedTrack.source,
      );
      if (updated !== pinnedTrack && isTrackReference(updated)) {
        layoutContext.pin.dispatch?.({ msg: "set_pin", trackReference: updated });
      }
    }
  }, [
    screenShareTracks.map((t) => `${t.publication.trackSid}_${t.publication.isSubscribed}`).join(),
    pinnedTrack?.publication?.trackSid,
    tracks,
  ]);

  // Une nouvelle mise en avant s'impose à toute la scène : un zoom local
  // (⤢) posé avant est levé, pour que chacun voie ce que voit le public.
  // Le partage d'écran épinglé d'office garde sa priorité. Déclaré APRÈS
  // l'auto-focus : un partage épinglé dans le même rendu est déjà connu.
  useEffect(() => {
    if (lastAutoFocusedScreenShareTrack.current) return;
    layoutContext.pin.dispatch?.({ msg: "clear_pin" });
  }, [spotlightIdentity]);

  return (
    <div className="lk-video-conference lk-stage" data-testid="stage">
      <div className="lk-stage__column">
        <div className="lk-stage__bar" data-testid="stage-bar">
          <span className="lk-stage__summary">
            <span className="lk-stage__audience" data-testid="audience-count" aria-live="polite">
              {audience} spectateur{audience > 1 ? "s" : ""}
            </span>
          </span>
          {/* Consentement : qui publie voit que l'enregistrement tourne
              (lecture seule ; le pilotage est dans la régie). */}
          {recordingStatusUrl ? <RecordingIndicator statusUrl={recordingStatusUrl} /> : null}
          <ConsentWithdrawal />
          {nameError ? <span className="lk-stage__note" role="status">{nameError}</span> : null}
          {deviceSaveError ? (
            <span className="lk-stage__note" role="status" data-testid="device-preferences-error">{deviceSaveError}</span>
          ) : null}
          {regieUrl ? (
            <a className="lk-stage__regie" href={regieUrl} target="_blank" rel="noopener" data-testid="regie-link">
              Régie <span aria-hidden="true">↗</span>
              <NewTabHint />
            </a>
          ) : null}
        </div>
        {qaBanner}
        <LayoutContextProvider value={layoutContext}>
          <div className="lk-video-conference-inner lk-stage__main">
            {showsFocus ? (
              <div className="lk-focus-layout-wrapper lk-stage__tiles">
                <FocusStage
                  focusTrack={focusTrack}
                  otherTracks={stripTracks}
                  spotlight={spotlight}
                  side={stripSide}
                  onToggleSide={toggleStripSide}
                />
              </div>
            ) : (
              <div className="lk-grid-layout-wrapper lk-stage__tiles">
                <MosaicGrid tracks={tracks} mode={mosaicMode} onModeChange={setMosaicMode} spotlight={spotlight} />
              </div>
            )}
            <RoomControls />
          </div>
        </LayoutContextProvider>
      </div>
      <NameSync displayName={displayName} onError={setNameError} />
      <SidePanel {...sidePanel} />
      <RoomAudioRenderer />
      <RestorePreferredOutput />
      <ConnectionNotice />
    </div>
  );
}

// Égalité de références de piste (équivalent isEqualTrackRef, non exporté
// par le bundle 2.9) : même participant + même source ; deux vraies
// publications se comparent par trackSid.
function isSameTrackRef(a, b) {
  if (!a || !b) return false;
  if (isTrackReference(a) && isTrackReference(b)) {
    return a.publication.trackSid === b.publication.trackSid;
  }
  return a.participant.identity === b.participant.identity && a.source === b.source;
}

// Vidéo publiée en H.264 (caméra, écran) : l'enregistrement par piste
// (egress sans transcodage) démarre de façon fiable sur H.264 (8 essais
// sur 8) mais seulement 2 fois sur 5 sur le VP8 par défaut du
// navigateur (« Stop called before pipeline could start », fichier vide).
//
// Débit réglé sur chaque connexion :
//   • adaptiveStream : chaque abonné ne reçoit que la couche qui correspond
//     à la taille de la tuile affichée, rien pour une vidéo hors écran ou un
//     onglet masqué. Sans lui, chacun recevait la couche haute de chaque
//     caméra (4 à 6 Mb/s par spectateur, mesuré en direct) ; le SFU ajuste en
//     plus la couche à la bande passante de chaque abonné (allocateur de flux,
//     congestion_control actif par défaut dans livekit-server).
//   • dynacast : l'émetteur met en pause les couches que personne ne
//     regarde. D'après les sources (egress v1.9.0, livekit-server v1.13.5 :
//     SubscribedTrack.Bound et dynacastqualityvideo), l'enregistrement par
//     piste garde la couche haute : l'egress s'abonne sans adaptiveStream,
//     le serveur lui donne la couche haute par défaut, et dynacast garde la
//     couche demandée par le plus exigeant des abonnés, egress compris.
//
// Caméra en 1080p : capture demandée en 1920x1080,
// publiée en trois couches simulcast, 360p, 540p et 1080p (q, h, f). La
// couche haute, celle de l'enregistrement, monte à 3 Mb/s, les deux autres
// ajoutent 1,25 Mb/s au débit montant. Un spectateur sur une petite tuile ou
// une petite connexion reçoit 360p ou 540p ; un émetteur limité par son débit
// coupe la 1080p et garde la 540p, enregistrement compris. La résolution
// demandée n'est qu'un idéal : une caméra qui ne fait pas la 1080p donne sa
// meilleure résolution, sans erreur, et livekit-client calcule les couches
// sur la capture réelle. Une caméra 720p sort 360p, 540p et 720p : 540p et
// non 720p pour la couche h, sinon h et f seraient deux encodages 720p
// identiques sur les machines les plus faibles. Le repli sans simulcast
// (camera_health.jsx) repasse la capture en 720p.
// Constante de module : LiveKitRoom ne doit pas recevoir un objet neuf à
// chaque rendu.
const ROOM_OPTIONS = {
  adaptiveStream: true,
  dynacast: true,
  videoCaptureDefaults: { resolution: VideoPresets.h1080.resolution },
  publishDefaults: {
    videoCodec: "h264",
    videoEncoding: VideoPresets.h1080.encoding,
    videoSimulcastLayers: [VideoPresets.h360, VideoPresets.h540],
  },
};

function Room({ slug, speakerToken, initialName, stateUrl, endUrl, recordingStatusUrl, recordingViewerStatusUrl, viewerHandRaisesUrl, participantWaiting, recordingNotice, regieUrl, messagesUrl, qaDisplayUrl, transcriptEnabled, pollsUrl, organization }) {
  // TOUS les hooks AVANT tout return conditionnel — règle React stricte.
  // Une page blanche venait de deux
  // useCallback déclarés après les returns loading/error : à la 2e phase
  // (state=ready), React voyait "plus de hooks qu'à la précédente" et
  // démontait tout le sous-arbre.
  const [connection, setConnection] = useState({ state: "loading" });
  const [mediaError, setMediaError] = useState(null);
  const [userChoices, setUserChoices] = useState(null);
  const [deviceSaveError, setDeviceSaveError] = useState(null);
  // Sortie de salle : { reason } dès qu'on a quitté une
  // salle rejointe, ou cliqué « Quitter ». Un échec de la connexion initiale
  // n'est pas une sortie : la scène reste affichée avec son avis de connexion.
  const [exit, setExit] = useState(null);
  const connectedRef = useRef(false);

  useEffect(() => {
    let cancelled = false;
    fetchToken({ slug, speakerToken })
      .then((payload) => {
        if (cancelled) return;
        setConnection({ state: "ready", payload });
      })
      .catch((err) => {
        if (cancelled) return;
        setConnection({ state: "error", error: err.message });
      });
    return () => {
      cancelled = true;
    };
  }, [slug, speakerToken]);

  const handleMediaDeviceFailure = useCallback((failure, kind) => {
    setMediaError({ failure: failure || "Other", kind: kind || null });
  }, []);

  const handleEnumFailure = useCallback((failure) => {
    setMediaError(failure);
  }, []);

  const handlePreJoinError = useCallback((err) => {
    setMediaError(errorToFailure(err));
  }, []);

  const handlePreJoinSubmit = useCallback((choices) => {
    setUserChoices(choices);
  }, []);

  // Préférences de périphériques du participant, créées UNE fois le token
  // reçu (il porte la mémoire serveur ; null pour un spectateur ou un
  // serveur qui ne la livre pas).
  const devicePreferences = useMemo(() => {
    if (connection.state !== "ready") return null;
    return createDevicePreferences({
      server: connection.payload.devicePreferences ?? null,
      slug,
      speakerToken,
      onSaveError: setDeviceSaveError,
    });
  }, [connection, slug, speakerToken]);

  const handleConnected = useCallback(() => {
    connectedRef.current = true;
  }, []);

  const handleDisconnected = useCallback((reason) => {
    if (reason === DisconnectReason.CLIENT_INITIATED || connectedRef.current) setExit({ reason });
  }, []);

  const handleRejoin = useCallback(() => window.location.reload(), []);

  // canPublish et audio/video props dépendent de connection.payload —
  // calcul mémoïsé pour stabiliser les props passées à LiveKitRoom.
  const canPublish = useMemo(() => {
    if (connection.state !== "ready") return false;
    const role = connection.payload.role;
    // "cohost" = co-animateur invité : publie
    // comme un host côté UI, SANS roomAdmin côté LiveKit grants.
    return role === "host" || role === "cohost" || role === "speaker";
  }, [connection]);

  const audioProp = useMemo(() => {
    if (!userChoices) return false;
    return userChoices.audioEnabled
      ? { deviceId: userChoices.audioDeviceId || undefined }
      : false;
  }, [userChoices]);

  const videoProp = useMemo(() => {
    if (!userChoices) return false;
    return userChoices.videoEnabled
      ? { deviceId: userChoices.videoDeviceId || undefined }
      : false;
  }, [userChoices]);

  // Accord à l'image (participant_consent.jsx) : null pour l'animation.
  // Sans accord déjà donné dans ce webinaire, la salle est rejointe micro et
  // caméra coupés ; la fenêtre de consentement les rallume s'ils avaient
  // été choisis au PreJoin. Lu une fois, au jeton : un accord donné ensuite
  // allume les pistes lui-même.
  const participantConsent = connection.state === "ready" ? connection.payload.participantConsent ?? null : null;
  const joinsWithMedia = !participantConsent || participantConsent.given;

  if (connection.state === "loading") {
    return <p className="lk-status">Connexion à la salle…</p>;
  }
  if (connection.state === "error") {
    return (
      <p className="lk-status lk-status--error" role="alert">
        Impossible de rejoindre la salle : {connection.error}
      </p>
    );
  }

  if (exit) {
    return (
      <RoomExit
        reason={exit.reason}
        stateUrl={stateUrl}
        endUrl={endUrl}
        recordingStatusUrl={recordingStatusUrl || recordingViewerStatusUrl}
        onRejoin={handleRejoin}
      />
    );
  }

  const { token, serverUrl } = connection.payload;
  const sidePanel = { messagesUrl, speakerToken, transcriptEnabled, organization };
  // Bandeau « Question en cours » (file Q&R) : le même pour tous les rôles.
  const qaBanner = qaDisplayUrl ? <QaBanner url={qaDisplayUrl} speakerToken={speakerToken} /> : null;

  // HOST/SPEAKER pas encore passé par PreJoin → afficher PreJoin d'abord.
  // La bannière media reste visible au-dessus du PreJoin si un failure a
  // été signalé (enumerateDevices vide ou onError PreJoin).
  if (canPublish && !userChoices) {
    return (
      <>
        {mediaError ? (
          <MediaFailureBanner
            error={mediaError}
            onDismiss={() => setMediaError(null)}
          />
        ) : null}
        <StagePreJoin
          initialName={initialName}
          preferences={devicePreferences}
          onSubmit={handlePreJoinSubmit}
          onEnumFailure={handleEnumFailure}
          onError={handlePreJoinError}
        />
      </>
    );
  }

  return (
    <>
      {mediaError ? (
        <MediaFailureBanner
          error={mediaError}
          onDismiss={() => setMediaError(null)}
        />
      ) : null}
      <DevicePreferencesProvider value={devicePreferences}>
        <LiveKitRoom
          token={token}
          serverUrl={serverUrl}
          connect={true}
          audio={canPublish && joinsWithMedia ? audioProp : false}
          video={canPublish && joinsWithMedia ? videoProp : false}
          onMediaDeviceFailure={handleMediaDeviceFailure}
          onConnected={handleConnected}
          onDisconnected={handleDisconnected}
          options={ROOM_OPTIONS}
          data-testid="livekit-room"
        >
          {/* Mesure de la caméra publiée et repli sans simulcast
              (camera_health.jsx) ; sans caméra publiée, rien. */}
          <CameraHealth slug={slug} speakerToken={speakerToken} />
          <ParticipantConsentProvider
            consent={participantConsent}
            slug={slug}
            speakerToken={speakerToken}
            joinChoices={joinsWithMedia ? null : userChoices}
          >
            {canPublish ? (
              <StageLayout
                displayName={userChoices?.username}
                deviceSaveError={deviceSaveError}
                recordingStatusUrl={recordingStatusUrl}
                regieUrl={regieUrl}
                sidePanel={sidePanel}
                qaBanner={qaBanner}
              />
            ) : (
              <ViewerLayout
                handRaisesUrl={viewerHandRaisesUrl}
                participantWaiting={participantWaiting}
                recordingNotice={recordingNotice}
                recordingViewerStatusUrl={recordingViewerStatusUrl}
                sidePanel={sidePanel}
                qaBanner={qaBanner}
              />
            )}
            {/* Sondages du direct : la même pop-up pour tous les
                rôles, animation comprise ; le serveur décide qui répond. */}
            {pollsUrl ? <PollOverlay pollsUrl={pollsUrl} speakerToken={speakerToken} /> : null}
          </ParticipantConsentProvider>
        </LiveKitRoom>
      </DevicePreferencesProvider>
    </>
  );
}

export function mountRoom() {
  const el = document.getElementById(MOUNT_ID);
  if (!el) return;
  const slug = el.dataset.slug;
  const speakerToken = el.dataset.speakerToken || null;
  const initialName = el.dataset.name || "";
  // Salle animateur = salle participant : aucune commande
  // d'animation n'arrive ici (cf. webinars/room.html.erb).
  // data-state-url (public) est posé pour tous : l'écran de sortie de salle
  // en lit l'état du direct. data-end-url (stage) ne sert qu'à cet écran,
  // hors salle : l'animation qui vient de quitter peut terminer le direct.
  const stateUrl = el.dataset.stateUrl || null;
  const endUrl = el.dataset.endUrl || null;
  // Indicateur d'enregistrement (consentement), lecture seule : statut
  // animateur / intervenant (stage, join) ou spectateur (viewer dans la
  // salle, pour le consentement du spectateur).
  const recordingStatusUrl = el.dataset.recordingStatusUrl || null;
  const recordingViewerStatusUrl = el.dataset.recordingViewerStatusUrl || null;
  // Prise de parole : POST/DELETE/GET du spectateur —
  // SEULEMENT quand la vue viewer rend EFFECTIVEMENT la salle (@viewer_room
  // = true, c'est-à-dire webinaire live ET current_registration confirmée).
  const viewerHandRaisesUrl = el.dataset.viewerHandRaisesUrl || null;
  // Inscrit venu participer (caméra et micro) dont la main attend
  // l'animation : textes neutres dans la tonalité de l'émission, posés par
  // le serveur avec l'URL de la main (hand_raise_viewer.jsx).
  const participantWaiting = el.dataset.participantWaitingMessage
    ? { message: el.dataset.participantWaitingMessage, cancelLabel: el.dataset.participantCancelLabel }
    : null;
  const recordingNotice = el.dataset.recordingNotice || null;
  // Lien vers la régie : animation seulement.
  const regieUrl = el.dataset.regieUrl || null;
  // Discussion du direct : fil posé pour toute salle rendue (le serveur
  // revérifie le participant à chaque appel).
  const messagesUrl = el.dataset.messagesUrl;
  // Organisation qui opère l'instance, nommée par l'avis de la discussion.
  const organization = el.dataset.organization;
  // File Q&R : question affichée à l'écran, lisible par tout participant.
  const qaDisplayUrl = el.dataset.qaDisplayUrl || null;
  // Panneau Transcript. Drapeau serveur (data-transcript-
  // enabled="true") posé par app/views/webinars/room.html.erb quand
  // TRANSCRIPT_ENABLED est à "true". Absence du data-attr = pas de
  // panneau — comportement neutre pour la prod tant qu'on n'active pas.
  const transcriptEnabled = el.dataset.transcriptEnabled === "true";
  // Sondages du direct : préfixe /w/:slug/polls posé pour toute salle rendue.
  const pollsUrl = el.dataset.pollsUrl || null;
  if (!slug) {
    // Marqueur explicite pour diagnostiquer un data-attr manquant
    // (échec silencieux = 100 % du temps de debug perdu, cf.
    // multitrack recorder).
    el.textContent = "livekit-room: data-slug manquant";
    return;
  }
  const enter = () => createRoot(el).render(
    <Room
      slug={slug}
      speakerToken={speakerToken}
      initialName={initialName}
      stateUrl={stateUrl}
      endUrl={endUrl}
      recordingStatusUrl={recordingStatusUrl}
      recordingViewerStatusUrl={recordingViewerStatusUrl}
      viewerHandRaisesUrl={viewerHandRaisesUrl}
      participantWaiting={participantWaiting}
      recordingNotice={recordingNotice}
      regieUrl={regieUrl}
      messagesUrl={messagesUrl}
      qaDisplayUrl={qaDisplayUrl}
      transcriptEnabled={transcriptEnabled}
      pollsUrl={pollsUrl}
      organization={organization}
    />
  );
  // Inscrit qui n'a jamais choisi « J'observe » ou « Je participe » : la salle
  // n'est montée (jeton LiveKit compris) qu'une fois son choix enregistré.
  const choice = document.querySelector("[data-role=participation-choice]");
  if (choice) {
    awaitParticipationChoice(choice, enter);
  } else {
    enter();
  }
}
