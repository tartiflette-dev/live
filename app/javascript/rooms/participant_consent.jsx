// Accord à l'image dans la salle.
//
// Intervenant, co-animateur invité, ou spectateur à qui la parole est
// donnée : avant la PREMIÈRE activation de sa caméra ou de son micro dans ce
// webinaire, une fenêtre recueille son accord :
//   (a) filmé·e, enregistré·e et transcrit·e, replay rediffusé — obligatoire ;
//   (b) extraits publiés par l'organisation et les co-animateurs — facultatif ;
//   (c) 18 ans ou plus — obligatoire.
// Sans (a) ou (c), caméra et micro restent coupés : la personne reste dans la
// salle en spectatrice. L'animation de droit n'a pas de fenêtre
// (`participantConsent` null dans la réponse de POST /api/token).
//
// Le SERVEUR décide : qui doit donner son accord, les libellés affichés (ceux
// qu'il fige dans la preuve), le porteur de l'accord (POST et DELETE
// /api/participant_consent, contrat ParticipantConsent), et le droit de
// publier (PublishPermission) : sans accord, le jeton ne publie pas ; l'accord
// enregistré, la salle ouvre la publication. Ce module demande, puis publie ce
// que la personne a choisi d'allumer, une fois la permission arrivée.
//
// Retrait (« Retirer mon accord ») : caméra, micro et partage d'écran sont
// coupés et dépubliés ici d'abord, puis le serveur horodate le retrait et
// retire le droit de publier ; la personne repasse spectatrice.

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import { ParticipantEvent, RoomEvent, Track } from "livekit-client";
import { CameraDisabledIcon, MicDisabledIcon, useParticipantPermissions, useRoomContext } from "@livekit/components-react";
import { csrfToken } from "./state_button";
import { AUDIO_INPUT, VIDEO_INPUT } from "./device_preferences";
import { useTwoStepConfirm } from "./two_step_confirm";

const ENDPOINT = "/api/participant_consent";

const MISSING_RECORDING = "Sans cet accord, caméra et micro restent coupés : vous restez dans la salle en spectateur·rice.";
const MINOR = "Pour intervenir à l'image, il faut avoir 18 ans ou plus : vous suivez le direct en spectateur·rice.";
const NOT_OPENED = "Accord enregistré, mais la salle n'a pas ouvert votre caméra et votre micro : réessayez.";

async function sendConsent(method, { slug, speakerToken }, boxes = {}) {
  const res = await fetch(ENDPOINT, {
    method,
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrfToken() },
    body: JSON.stringify({ slug, speaker_token: speakerToken || null, ...boxes }),
  });
  if (res.ok) return res.json();

  const payload = await res.json().catch(() => null);
  if (payload?.error === "permission_update_failed") throw new Error(NOT_OPENED);
  throw new Error(`Accord non enregistré (serveur ${res.status}) : caméra et micro restent coupés. Réessayez.`);
}

// Publication ouverte par la salle (PublishPermission, côté serveur) : une
// piste n'est publiée qu'une fois la permission reçue.
function whenPublishAllowed(lp) {
  if (lp.permissions?.canPublish) return Promise.resolve();
  return new Promise((resolve) => {
    const check = () => {
      if (!lp.permissions?.canPublish) return;
      lp.off(ParticipantEvent.ParticipantPermissionsChanged, check);
      resolve();
    };
    lp.on(ParticipantEvent.ParticipantPermissionsChanged, check);
  });
}

// Sources allumées au PreJoin ; l'intervenant les retrouve une fois son
// accord donné.
function chosenSources(joinChoices) {
  if (!joinChoices) return [];
  return [
    joinChoices.audioEnabled ? Track.Source.Microphone : null,
    joinChoices.videoEnabled ? Track.Source.Camera : null,
  ].filter(Boolean);
}

// Périphériques choisis au PreJoin, posés comme périphériques actifs de la
// salle : rien n'est publié, la première activation les prendra.
function applyJoinDevices(room, joinChoices) {
  [[AUDIO_INPUT, joinChoices.audioDeviceId], [VIDEO_INPUT, joinChoices.videoDeviceId]].forEach(([kind, deviceId]) => {
    if (!deviceId) return;
    room.switchActiveDevice(kind, deviceId, false).catch((err) => room.emit(RoomEvent.MediaDevicesError, err, kind));
  });
}

const ParticipantConsentContext = createContext(null);

// `{ required, given, needed, request(sources), withdraw() }`, ou null hors
// d'un fournisseur.
export function useParticipantConsent() {
  return useContext(ParticipantConsentContext);
}

// `consent` : `participantConsent` du jeton (null pour l'animation).
// `joinChoices` : choix du PreJoin quand la salle a été rejointe SANS média
// faute d'accord (l'accord demandé d'emblée les rallume), sinon null.
export function ParticipantConsentProvider({ consent, slug, speakerToken, joinChoices, children }) {
  const room = useRoomContext();
  const required = !!consent;
  const [given, setGiven] = useState(!!consent?.given);
  const [pendingSources, setPendingSources] = useState(null);
  // Pistes créées après un accord : arrêtées au retrait même si leur
  // publication n'est pas encore confirmée par la salle.
  const startedTracks = useRef(new Set());
  const joinHandled = useRef(false);

  useEffect(() => {
    if (joinHandled.current || !joinChoices) return;
    joinHandled.current = true;
    applyJoinDevices(room, joinChoices);
    const sources = chosenSources(joinChoices);
    if (sources.length > 0) setPendingSources(sources);
  }, [room, joinChoices]);

  const publish = useCallback((sources) => {
    const lp = room.localParticipant;
    sources.forEach((source) => {
      const kind = source === Track.Source.Camera ? VIDEO_INPUT : AUDIO_INPUT;
      lp.createTracks(kind === VIDEO_INPUT ? { video: true } : { audio: true })
        .then(async ([track]) => {
          startedTracks.current.add(track);
          await whenPublishAllowed(lp);
          // Une piste arrêtée entre-temps (retrait) n'a plus à paraître.
          if (!startedTracks.current.has(track)) return;
          await lp.publishTrack(track).catch((err) => {
            if (startedTracks.current.has(track)) room.emit(RoomEvent.MediaDevicesError, err, kind);
          });
        })
        .catch((err) => room.emit(RoomEvent.MediaDevicesError, err, kind));
    });
  }, [room]);

  const accept = useCallback(async (boxes) => {
    await sendConsent("POST", { slug, speakerToken }, boxes);
    setGiven(true);
    const sources = pendingSources;
    setPendingSources(null);
    publish(sources);
  }, [slug, speakerToken, pendingSources, publish]);

  const decline = useCallback(() => setPendingSources(null), []);

  const withdraw = useCallback(async () => {
    const lp = room.localParticipant;
    const published = [...lp.trackPublications.values()].map((publication) => publication.track).filter(Boolean);
    [...startedTracks.current, ...published].forEach((track) => track.stop());
    startedTracks.current.clear();
    // Pistes déjà arrêtées (caméra et micro éteints) : un échec de
    // dépublication ne laisse qu'une piste muette, que le retrait du droit
    // de publier par le serveur fait tomber.
    published.forEach((track) => lp.unpublishTrack(track).catch(() => null));
    await sendConsent("DELETE", { slug, speakerToken });
    setGiven(false);
  }, [room, slug, speakerToken]);

  const value = useMemo(() => ({
    required,
    given,
    needed: required && !given,
    request: (sources) => setPendingSources(sources),
    withdraw,
  }), [required, given, withdraw]);

  return (
    <ParticipantConsentContext.Provider value={value}>
      {children}
      {pendingSources && required ? (
        <ConsentDialog labels={consent.labels} contact={consent.contact} onAccept={accept} onDecline={decline} />
      ) : null}
    </ParticipantConsentContext.Provider>
  );
}

// Fenêtre de consentement. Les libellés viennent du serveur, tels quels.
function ConsentDialog({ labels, contact, onAccept, onDecline }) {
  const [boxes, setBoxes] = useState({ recording: false, excerpts: false, adult: false });
  const [message, setMessage] = useState(null);
  const [busy, setBusy] = useState(false);
  const firstBox = useRef(null);

  useEffect(() => { firstBox.current?.focus(); }, []);

  const toggle = (key) => (event) => setBoxes((current) => ({ ...current, [key]: event.target.checked }));

  const submit = async (event) => {
    event.preventDefault();
    if (!boxes.recording || !boxes.adult) {
      setMessage(boxes.recording ? MINOR : MISSING_RECORDING);
      return;
    }
    setBusy(true);
    try {
      await onAccept(boxes);
    } catch (err) {
      setMessage(err.message);
      setBusy(false);
    }
  };

  return (
    <div className="lk-consent" data-testid="consent-dialog">
      <form className="lk-consent__dialog" role="dialog" aria-modal="true" aria-labelledby="lk-consent-title"
            onSubmit={submit} onKeyDown={(event) => { if (event.key === "Escape") onDecline(); }}>
        <h2 className="lk-consent__title" id="lk-consent-title">Avant d'allumer votre caméra ou votre micro</h2>
        <p className="lk-consent__intro">
          Pendant que vous avez la parole, votre image et votre voix sont enregistrées et votre voix est transcrite.
        </p>
        <fieldset className="lk-consent__choices">
          <label className="lk-consent__choice">
            <input ref={firstBox} type="checkbox" name="recording" checked={boxes.recording} onChange={toggle("recording")} />
            <span>{labels.recording}</span>
          </label>
          <label className="lk-consent__choice">
            <input type="checkbox" name="excerpts" checked={boxes.excerpts} onChange={toggle("excerpts")} />
            <span>{labels.excerpts} <span className="lk-consent__optional">(facultatif)</span></span>
          </label>
          <label className="lk-consent__choice">
            <input type="checkbox" name="adult" checked={boxes.adult} onChange={toggle("adult")} />
            <span>{labels.adult}</span>
          </label>
        </fieldset>
        <p className="lk-consent__intro">
          Vous pourrez retirer votre accord à tout moment, depuis la salle ou en écrivant à {contact}
          (<a href="/confidentialite" target="_blank" rel="noopener">confidentialité</a>).
        </p>
        {message ? <p className="lk-consent__message" role="alert" data-testid="consent-message">{message}</p> : null}
        <div className="lk-consent__actions">
          <button type="submit" className="lk-consent__accept" disabled={busy}>
            {busy ? "…" : "Allumer"}
          </button>
          <button type="button" className="lk-consent__decline" onClick={onDecline}>
            Rester spectateur·rice
          </button>
        </div>
      </form>
    </div>
  );
}

// Intervenant ou co-animateur invité (identité `speaker-…`, `host-…`) que la
// salle ne laisse pas encore publier, faute d'accord à l'image
// (PublishPermission) : il reste sur scène, « en attente d'accord », pour que
// l'animation le voie arriver et puisse le mettre en avant. Un spectateur
// (`viewer-…`) n'y monte qu'avec la parole et la publication ouvertes.
export function awaitsConsent(participant, permissions = participant.permissions) {
  return !permissions?.canPublish && /^(speaker|host)-/.test(participant.identity);
}

// Pastille « En attente d'accord » sur la tuile caméra (RoomTile, sur scène).
export function ConsentPendingMarker({ participant }) {
  const permissions = useParticipantPermissions({ participant });
  return awaitsConsent(participant, permissions)
    ? <span className="lk-consent-pending" data-testid="consent-pending">En attente d'accord</span>
    : null;
}

const GATED_ICONS = { [Track.Source.Camera]: CameraDisabledIcon, [Track.Source.Microphone]: MicDisabledIcon };

// Bouton Micro ou Caméra éteint tant que l'accord manque : même apparence
// que le TrackToggle de LiveKit, mais un clic ouvre la fenêtre au lieu
// d'allumer.
export function ConsentGatedToggle({ source, children }) {
  const consent = useParticipantConsent();
  const Icon = GATED_ICONS[source];
  return (
    <button type="button" className="lk-button" data-lk-source={source} data-lk-enabled="false" aria-pressed="false"
            onClick={() => consent.request([source])}>
      <Icon />
      {children}
    </button>
  );
}

// « Retirer mon accord », confirmé en deux temps : un clic de trop couperait
// la parole en plein direct. Après le retrait, l'avis reste affiché.
export function ConsentWithdrawal() {
  const consent = useParticipantConsent();
  const { armed, confirmed, disarm, controlRef } = useTwoStepConfirm();
  const [state, setState] = useState({ busy: false, withdrawn: false, error: null });

  const handleClick = async () => {
    if (!confirmed()) return;
    setState({ busy: true, withdrawn: false, error: null });
    try {
      await consent.withdraw();
      setState({ busy: false, withdrawn: true, error: null });
    } catch (err) {
      setState({ busy: false, withdrawn: false, error: `Retrait non enregistré (${err.message}) : réessayez.` });
    }
  };

  if (!consent?.required) return null;
  if (!consent.given) {
    return state.withdrawn ? (
      <span className="lk-consent-withdrawal__note" role="status" data-testid="consent-withdrawn">
        Accord retiré : caméra et micro coupés, vous restez dans la salle en spectateur·rice.
      </span>
    ) : null;
  }
  return (
    <span className="lk-consent-withdrawal" ref={controlRef}>
      <button type="button" className="lk-consent-withdrawal__button" onClick={handleClick} disabled={state.busy}
              data-testid="consent-withdraw">
        {state.busy ? "…" : armed ? "Confirmer : couper caméra et micro" : "Retirer mon accord"}
      </button>
      {armed ? <button type="button" className="lk-consent-withdrawal__button" onClick={disarm}>Annuler</button> : null}
      {state.error ? <span className="lk-consent-withdrawal__note" role="alert">{state.error}</span> : null}
    </span>
  );
}
