// Régie du direct :
// « même quelqu'un qui est animateur doit voir la même chose que les
// participants […] on a un autre onglet sur lequel on peut aller lancer
// une question, mettre un truc en plein écran […] démarrer et arrêter les
// enregistrements ».
//
// La salle de l'animation est celle des participants ; les commandes sont
// ici, dans un onglet à part (2e écran, tablette). La régie NE REJOINT PAS
// la salle LiveKit : aucun flux vidéo, aucune connexion média, aucun hook
// qui exigerait un RoomContext. Tout passe par Rails :
//   - /regie/status (5 s) : état du direct, présents, scène, mise en avant
//     (lus par le serveur dans LiveKit, RoomSnapshot), transcription
//     interrompue (bandeau), caméras émises sous 720p et replis sans
//     simulcast (CameraSample, CameraQualityConsole) ;
//   - la modération : couper le micro d'un
//     intervenant ou d'un spectateur, ou le retirer du direct
//     (WebinarParticipantsController), et régénérer le lien intervenants
//     partagé (WebinarShareLinkRegenerationsController) ;
//   - les endpoints existants des composants réutilisés (StateButton,
//     RecordingControl, HandRaiseHost, mise en avant, DiscussionPanel), qui
//     revérifient le rôle d'animation à chaque appel ;
//   - /registrations/attendance (5 s, si la personne voit la liste des
//     inscrits) : chaque inscrit, présent, venu puis parti, ou absent ;
//   - les consoles autonomes des sondages (PollConsole, son propre chrono
//     lu sur le plan serveur, présents fournis par /regie/status) et des
//     questions du public (QaConsole). « Ajouter à la file » depuis la
//     discussion crée une question manuelle et relit aussitôt la file.
//
// Rangement par moment (regie_layout.mjs) : deux colonnes,
// pilotage à gauche, public à droite ; en priorité ce que la scène ne montre
// pas ; après la fin, un bilan. Rien ne disparaît : ce qui est secondaire est
// replié (RegieFold), jamais retiré.
//
// Fail-loud : une salle illisible ou un refus s'affichent, jamais devinés.

import { createRoot } from "react-dom/client";
import { useCallback, useEffect, useRef, useState } from "react";
import { StateButton, csrfToken } from "./state_button";
import { useTwoStepConfirm } from "./two_step_confirm";
import { RecordingControl } from "./recording_control";
import { HandRaiseHost, toAdmit } from "./hand_raise_host";
import { useSpotlightControl } from "./spotlight";
import { DiscussionPanel, useChat } from "./chat";
import { PollConsole } from "./poll_console";
import { QaConsole } from "./qa_console";
import { CameraQualityConsole } from "./camera_quality_console";
import { COPIED, FAILED, FEEDBACK_MS, copyText } from "../copy_link.js";
import { regieLayout } from "./regie_layout.mjs";
import { clockTime } from "./clock_time.mjs";
import { NewTabHint } from "./new_tab_hint";

const MOUNT_ID = "regie";
const STATUS_POLL_MS = 5000;
// Onglet masqué (la salle au premier plan, régie derrière) : la page n'est
// pas lue, on relit rarement ; au retour, relecture immédiate.
const HIDDEN_STATUS_POLL_MS = 30000;
const STATE_LABELS = { draft: "Hors antenne", live: "En direct", ended: "Terminé" };
const STATE_BADGES = { draft: "etat--neutre", live: "etat--en-cours", ended: "etat--neutre" };

async function readStatus(url) {
  const res = await fetch(url, {
    credentials: "same-origin",
    cache: "no-store",
    redirect: "manual",
    headers: { Accept: "application/json" },
  });
  if (res.type === "opaqueredirect") throw new Error("session animateur expirée, reconnectez-vous");
  if (!res.ok) throw new Error(`serveur ${res.status}`);
  return res.json();
}

// État de la régie relu sur le serveur, toutes les STATUS_POLL_MS (onglet
// visible) ou HIDDEN_STATUS_POLL_MS (onglet masqué). `refresh` force une
// relecture (après une commande, pour ne pas attendre le prochain tour).
function useRegieStatus(statusUrl) {
  const [status, setStatus] = useState(null);
  const [error, setError] = useState(null);
  const mountedRef = useRef(true);
  useEffect(() => () => { mountedRef.current = false; }, []);

  const refresh = useCallback(async () => {
    try {
      const payload = await readStatus(statusUrl);
      if (!mountedRef.current) return;
      setStatus(payload);
      setError(null);
    } catch (err) {
      if (mountedRef.current) setError(err.message || "réseau");
    }
  }, [statusUrl]);

  useEffect(() => {
    let timer = null;
    const schedule = () => {
      clearTimeout(timer);
      timer = setTimeout(tick, document.hidden ? HIDDEN_STATUS_POLL_MS : STATUS_POLL_MS);
    };
    const tick = () => {
      refresh();
      schedule();
    };
    const onVisibilityChange = () => (document.hidden ? schedule() : tick());
    tick();
    document.addEventListener("visibilitychange", onVisibilityChange);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [refresh]);

  return { status, error, refresh };
}

function useNow(running) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (!running) return undefined;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [running]);
  return now;
}

function formatElapsed(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = String(Math.floor((total % 3600) / 60)).padStart(2, "0");
  const seconds = String(total % 60).padStart(2, "0");
  return `${hours}:${minutes}:${seconds}`;
}

// Chrono depuis le premier démarrage du direct (`started_at`, conservé à la
// reprise). Rien à compter hors direct.
function LiveClock({ state, liveSince }) {
  const running = state === "live" && !!liveSince;
  const now = useNow(running);
  if (!running) return null;
  return (
    <span className="regie-entete__chrono" data-testid="regie-clock" aria-label="Temps écoulé depuis le début du direct">
      {formatElapsed(now - Date.parse(liveSince))}
    </span>
  );
}

function presentLabel(status) {
  if (!status) return "Salle : lecture…";
  if (status.room === "unavailable") return "Salle LiveKit injoignable";
  if (status.room === "closed") return "Salle vide";
  return `${status.present} présent${status.present > 1 ? "s" : ""}`;
}

// Bilan d'un direct terminé : ses heures et sa durée, depuis le premier
// démarrage (`started_at`, conservé à la reprise) jusqu'à la fin.
function bilanLabel(liveSince, endedAt) {
  const start = Date.parse(liveSince);
  const end = Date.parse(endedAt);
  if (Number.isNaN(start) || Number.isNaN(end)) return "Direct terminé";
  return `Direct de ${clockTime(liveSince)} à ${clockTime(endedAt)} · ${formatElapsed(end - start)}`;
}

// Après la fin, l'en-tête devient un bilan : « Reprendre le direct » reste
// là, discret (regie.css), sans le poids d'une commande de direct.
function RegieHeader({ state, liveSince, endedAt, status, urls, onStateChange }) {
  const [stateError, setStateError] = useState(null);
  const ended = state === "ended";
  return (
    <section className={ended ? "regie-entete regie-entete--bilan" : "regie-entete"} aria-label="Direct" data-testid="regie-header">
      <div className="regie-entete__faits">
        <span className={`etat ${STATE_BADGES[state] || "etat--neutre"}`} data-testid="regie-state" data-state={state}>
          {STATE_LABELS[state] || state}
        </span>
        <LiveClock state={state} liveSince={liveSince} />
        {ended ? <span className="regie-entete__bilan" data-testid="regie-bilan">{bilanLabel(liveSince, endedAt)}</span> : null}
        <span className="regie-entete__presents" data-testid="regie-present" aria-live="polite">{presentLabel(status)}</span>
        <a className="btn btn--secondary regie-bouton regie-entete__salle" href={urls.stage} target="_blank" rel="noopener" data-testid="regie-open-room">
          Ouvrir la salle <span aria-hidden="true">↗</span>
          <NewTabHint />
        </a>
      </div>
      {/* Seul sur sa ligne, calé à gauche : armé, le bouton s'élargit vers
          la droite et « Annuler » vient après lui — le second clic d'un
          double-clic retombe sur le bouton, jamais sur « Annuler ». */}
      <div className="regie-entete__actions">
        <StateButton
          state={state}
          stateUrl={urls.state}
          goLiveUrl={urls.goLive}
          endUrl={urls.end}
          resumeUrl={urls.resume}
          onStateChange={onStateChange}
          onError={setStateError}
        />
      </div>
      {stateError ? <p className="regie-alerte" role="alert" data-testid="state-error">{stateError}</p> : null}
    </section>
  );
}

const PARIS_CLOCK = new Intl.DateTimeFormat("fr-FR", {
  hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZone: "Europe/Paris",
});

// Heure de Paris en H:MM (9:30, 14:00).
function parisClock(iso) {
  const parts = Object.fromEntries(PARIS_CLOCK.formatToParts(new Date(iso)).map(({ type, value }) => [type, value]));
  return `${Number(parts.hour)}:${parts.minute}`;
}

// Transcripteur absent d'une salle occupée au-delà du seuil
// (Webinar::TranscriptionOutage) : l'animation le sait pendant le direct ;
// l'équipe a reçu l'alerte. Disparaît au retour du transcripteur.
function TranscriptionNotice({ since }) {
  if (!since) return null;
  return (
    <p className="regie-alerte regie-alerte--attention" role="status" data-testid="regie-transcription-interrupted">
      Transcription en direct interrompue depuis {parisClock(since)} — l'équipe est prévenue
    </p>
  );
}

// Bloc de la régie. `titled` faux : la console porte déjà son propre titre
// (Questions, Sondages), jamais deux titres pour une zone.
function RegieSection({ title, testid, rank, titled = true, children }) {
  return (
    <section className="regie-bloc" aria-label={title} data-testid={testid} style={{ order: rank }}>
      {titled ? <h2 className="regie-bloc__titre">{title}</h2> : null}
      {children}
    </section>
  );
}

// Bloc secondaire, replié : son résumé (`summary`) dit l'essentiel sans
// l'ouvrir. `open`/`onOpenChange` facultatifs : un bloc qui demande un geste
// (main levée) s'ouvre de lui-même, la personne peut le refermer.
function RegieFold({ title, summary, testid, rank, open, onOpenChange, attention = false, children }) {
  const controlled = open !== undefined;
  return (
    <details
      className="regie-bloc regie-repli"
      data-testid={testid}
      data-attention={attention ? "true" : "false"}
      style={{ order: rank }}
      {...(controlled ? { open, onToggle: (event) => onOpenChange(event.currentTarget.open) } : {})}
    >
      <summary className="regie-repli__titre">
        <h2 className="regie-bloc__titre">{title}</h2>
        {summary ? <span className="regie-repli__resume">{summary}</span> : null}
      </summary>
      <div className="regie-repli__corps">{children}</div>
    </details>
  );
}

// Mise en avant : la régie demande, le serveur écrit les métadonnées de la
// salle, la relecture du statut montre ce que la salle diffuse. Un partage
// d'écran passe d'office en plein cadre chez tous (priorité de la salle,
// spotlight.jsx) : il est signalé, pas commandé.
function SpotlightConsole({ spotlightUrl, status, onChanged }) {
  const control = useSpotlightControl(spotlightUrl);
  const request = useCallback(async (identity) => {
    await control.request(identity);
    onChanged();
  }, [control, onChanged]);

  if (!status) return <p className="regie-note">Lecture de la salle…</p>;
  if (status.room === "unavailable") {
    return <p className="regie-alerte" role="alert">Salle LiveKit injoignable : la mise en avant est indisponible.</p>;
  }
  const onStage = status.on_stage || [];
  const featured = status.spotlight;
  const sharing = onStage.filter((person) => person.screen_share);
  const featuredAbsent = featured && !onStage.some((person) => person.identity === featured);

  return (
    <div className="regie-scene" data-testid="regie-spotlight">
      {sharing.length > 0 ? (
        <p className="regie-note regie-note--info" data-testid="regie-screen-share">
          Partage d'écran de {sharing.map((person) => person.name).join(", ")} : en plein cadre pour tous tant qu'il dure.
        </p>
      ) : null}
      {onStage.length === 0 ? (
        <p className="regie-note">Personne sur scène.</p>
      ) : (
        <ul className="regie-liste">
          {onStage.map((person) => {
            const isFeatured = person.identity === featured;
            const label = isFeatured ? "Retirer la mise en avant" : "Mettre en avant";
            return (
              <li className="regie-liste__item" key={person.identity} data-testid="regie-stage-person" data-featured={isFeatured}>
                <span className="regie-liste__nom">{person.name}</span>
                {isFeatured ? <span className="regie-liste__meta">en avant</span> : null}
                {person.awaiting_consent ? (
                  <span className="regie-liste__meta" data-testid="regie-awaiting-consent">en attente d'accord</span>
                ) : person.camera ? null : <span className="regie-liste__meta">caméra coupée</span>}
                <button
                  type="button"
                  className="btn btn--secondary regie-bouton"
                  aria-pressed={isFeatured}
                  aria-label={`${label} : ${person.name}`}
                  disabled={control.pending}
                  onClick={() => request(isFeatured ? null : person.identity)}
                  data-testid="regie-spotlight-toggle"
                >
                  {label}
                </button>
              </li>
            );
          })}
        </ul>
      )}
      {featuredAbsent ? <p className="regie-note">La personne mise en avant a quitté la scène : la salle affiche la mosaïque.</p> : null}
      <button
        type="button"
        className="btn btn--secondary regie-bouton"
        disabled={!featured || control.pending}
        onClick={() => request(null)}
        data-testid="regie-spotlight-clear"
      >
        Revenir à la mosaïque
      </button>
      {control.error ? <p className="regie-alerte" role="alert" data-testid="spotlight-error">{control.error}</p> : null}
    </div>
  );
}

// Résumé du repli « Mise en avant » : ce que la salle diffuse.
function spotlightSummary(status) {
  if (!status || status.room === "unavailable") return null;
  const onStage = status.on_stage || [];
  if (onStage.some((person) => person.screen_share)) return "partage d'écran en cours";
  const featured = onStage.find((person) => person.identity === status.spotlight);
  return featured ? `${featured.name} en avant` : "mosaïque";
}

const ROLE_NAMES = { speaker: "intervenant", viewer: "spectateur" };

const MODERATION_REFUSALS = {
  invalid_identity: "personne non modérable depuis la régie",
  not_found: "personne inconnue de ce direct",
  not_in_room: "la personne n'est plus dans la salle, rien n'a été fait",
  not_live: "hors direct, seuls le propriétaire et l'animateur du projet modèrent",
  room_update_failed: "la salle LiveKit n'a pas répondu",
};

// Refus définitifs : relancer ne changerait rien.
const FINAL_REFUSALS = new Set(["invalid_identity", "not_found", "not_in_room", "not_live"]);

const SHARE_LINK_REFUSALS = {
  no_share_link: "aucun lien intervenants actif",
  not_live: "hors direct, seuls le propriétaire et l'animateur du projet régénèrent le lien",
  not_found: "webinaire hors de votre animation",
  animateur_session_required: "session animateur expirée, reconnectez-vous",
  invalid_authenticity_token: "page expirée, rechargez la régie",
};

// Commande de la régie (POST JSON) : modération, régénération du lien
// intervenants. Le serveur revérifie le rôle d'animation et la cible à chaque
// appel ; un refus se lit dans `refusals` par son code, `error.final` dit si
// relancer ne changerait rien. @return réponse JSON
async function postCommand(url, refusals) {
  let response;
  try {
    response = await fetch(url, {
      method: "POST", credentials: "same-origin", cache: "no-store", redirect: "manual",
      headers: { Accept: "application/json", "X-CSRF-Token": csrfToken() },
    });
  } catch (_networkError) {
    throw new Error("réseau indisponible");
  }
  if (response.type === "opaqueredirect") throw new Error("session animateur expirée, reconnectez-vous");
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    const error = new Error(refusals[payload?.error] || `serveur ${response.status}`);
    error.final = FINAL_REFUSALS.has(payload?.error);
    throw error;
  }
  return payload || {};
}

// Une personne modérable. « Retirer » se confirme en deux temps : la personne
// quitte le direct ; ce que le retrait garantit et ne garantit pas est écrit
// sous la liste (docs/moderation.md).
function ParticipantRow({ person, participantsUrl, onChanged, onRemoved, onError }) {
  const [pending, setPending] = useState(false);
  const { armed, confirmed, disarm, controlRef } = useTwoStepConfirm();
  const baseUrl = `${participantsUrl}/${encodeURIComponent(person.identity)}`;

  // @return réponse du serveur, null si la commande a échoué
  const run = useCallback(async (action, failure, finalFailure = failure) => {
    setPending(true);
    onError(null);
    try {
      return await postCommand(`${baseUrl}/${action}`, MODERATION_REFUSALS);
    } catch (err) {
      onError(`${err.final ? finalFailure : failure} : ${err.message}.`);
      return null;
    } finally {
      setPending(false);
      onChanged();
    }
  }, [baseUrl, onChanged, onError]);

  const mute = () => run("mute", `Micro de ${person.name} non coupé`);
  const remove = async () => {
    if (pending || !confirmed()) return;
    const result = await run("remove", `Retrait de ${person.name} non confirmé, relancez « Retirer »`, `${person.name} non retiré`);
    if (result) onRemoved({ name: person.name, shareLinkReentry: result.share_link_reentry === true });
  };

  return (
    <li className="regie-liste__item" data-testid="regie-participant" data-identity={person.identity}>
      <span className="regie-liste__nom">{person.name}</span>
      <span className="regie-liste__meta">{ROLE_NAMES[person.role] || person.role}</span>
      {person.microphone ? <span className="regie-liste__meta">micro ouvert</span> : null}
      <span className="regie-moderation" ref={controlRef}>
        <button
          type="button"
          className="btn btn--secondary regie-bouton"
          aria-label={`Couper le micro : ${person.name}`}
          disabled={pending || !person.microphone}
          onClick={mute}
          data-testid="regie-participant-mute"
        >
          Couper le micro
        </button>
        <button
          type="button"
          className="btn btn--secondary regie-bouton regie-bouton--critique"
          aria-label={armed ? `Confirmer le retrait de ${person.name}` : `Retirer ${person.name} du direct`}
          data-armed={armed ? "true" : "false"}
          disabled={pending}
          onClick={remove}
          data-testid="regie-participant-remove"
        >
          {armed ? "Confirmer le retrait\u00a0?" : "Retirer"}
        </button>
        {armed ? (
          <button type="button" className="btn btn--secondary regie-bouton" onClick={disarm} data-testid="regie-participant-cancel">
            Annuler
          </button>
        ) : null}
      </span>
    </li>
  );
}

// Intervenants et spectateurs présents (jamais l'animation), lus par le
// serveur dans LiveKit (/regie/status, `participants`).
function ParticipantList({ status, participantsUrl, onChanged, onRemoved, onError }) {
  if (!status) return <p className="regie-note">Lecture de la salle…</p>;
  if (status.room === "unavailable") {
    return <p className="regie-alerte" role="alert">Salle LiveKit injoignable : la modération est indisponible.</p>;
  }
  const people = status.participants || [];
  if (people.length === 0) return <p className="regie-note">Aucun intervenant ni spectateur dans la salle.</p>;

  return (
    <ul className="regie-liste">
      {people.map((person) => (
        <ParticipantRow key={person.identity} person={person} participantsUrl={participantsUrl}
          onChanged={onChanged} onRemoved={onRemoved} onError={onError} />
      ))}
    </ul>
  );
}

// « Copier le lien » d'un lien reçu par la régie : même presse-papiers et
// mêmes retours que les boutons de la page du webinaire (copy_link.js).
// L'URL complète ne vit que dans `data-copy-link`, comme là-bas.
function CopyLinkButton({ link }) {
  const [feedback, setFeedback] = useState(null);
  useEffect(() => {
    if (!feedback) return undefined;
    const timer = setTimeout(() => setFeedback(null), FEEDBACK_MS);
    return () => clearTimeout(timer);
  }, [feedback]);

  const copy = async () => setFeedback((await copyText(link)) ? COPIED : FAILED);
  return (
    <>
      <button type="button" className="btn btn--secondary regie-bouton" data-copy-link={link} onClick={copy}
        data-testid="regie-share-link-copy">
        Copier le lien
      </button>
      <span role="status" aria-live="polite" className={feedback?.className}>{feedback?.text}</span>
    </>
  );
}

// Lien intervenants partagé (lien participants privé, /i) : la régie qui vient
// de retirer quelqu'un peut le régénérer pour lui fermer la porte
// (docs/moderation.md). Ce n'est plus un bouton permanent : il est proposé
// (`offered`) après un « Retirer » fait dans CETTE régie, jusqu'à son
// rechargement ; le propriétaire le régénère aussi depuis la page du webinaire. Rien sans lien actif (empreinte nulle dans
// /regie/status) : le créer et le désactiver restent sur la page du webinaire.
//
// Le nouveau lien n'arrive que dans la réponse au POST : affiché masqué, copié
// par son bouton, il ne revient jamais par un GET, donc plus après un
// rechargement. Il quitte l'affichage dès que l'empreinte lue n'est plus la
// sienne : remplacé depuis (autre animateur, page du webinaire) ou désactivé.
// Tant que le statut n'a pas été relu, l'empreinte d'avant vaut encore.
// `fresh`/`onFresh` : le nouveau lien vit dans la régie (useModerationMemory),
// pas dans ce bloc, qui se démonte quand il passe de déplié à replié (fin
// ou reprise du direct) : il reste affiché une fois la proposition refermée.
function ShareLinkControl({ regenerationUrl, fingerprint, offered, fresh, onFresh, onRegenerated }) {
  const [pending, setPending] = useState(false);
  const [error, setError] = useState(null);
  const { armed, confirmed, disarm, controlRef } = useTwoStepConfirm();

  if (!fingerprint) return null;
  const freshIsCurrent = fresh && (fingerprint === fresh.fingerprint || fingerprint === fresh.previousFingerprint);
  if (!offered && !freshIsCurrent && !armed && !error) return null;

  const regenerate = async () => {
    if (pending || !confirmed()) return;
    setPending(true);
    setError(null);
    try {
      const result = await postCommand(regenerationUrl, SHARE_LINK_REFUSALS);
      onFresh({ link: result.link, maskedLink: result.masked_link, fingerprint: result.fingerprint,
        previousFingerprint: fingerprint });
      onRegenerated();
    } catch (err) {
      setError(`Lien intervenants non régénéré : ${err.message}.`);
    } finally {
      setPending(false);
    }
  };

  return (
    <div className="regie-lien" data-testid="regie-share-link">
      <span className="regie-lien__commandes" ref={controlRef}>
        <button
          type="button"
          className="btn btn--secondary regie-bouton regie-bouton--critique"
          data-armed={armed ? "true" : "false"}
          disabled={pending}
          onClick={regenerate}
          data-testid="regie-share-link-regenerate"
        >
          {armed ? "Confirmer la régénération\u00a0?" : "Régénérer le lien intervenants"}
        </button>
        {armed ? (
          <button type="button" className="btn btn--secondary regie-bouton" onClick={disarm} data-testid="regie-share-link-cancel">
            Annuler
          </button>
        ) : null}
      </span>
      {freshIsCurrent && !fresh.link ? (
        <p className="regie-note regie-note--info" role="status" data-testid="regie-share-link-fresh">
          Nouveau lien intervenants créé : l'ancien ne fonctionne plus. Le propriétaire du webinaire le transmettra
          aux intervenants qui ne sont pas encore entrés.
        </p>
      ) : freshIsCurrent ? (
        <>
          <p className="regie-note regie-note--info" role="status" data-testid="regie-share-link-fresh">
            Nouveau lien intervenants : l'ancien ne fonctionne plus. À transmettre aux intervenants qui ne sont pas
            encore entrés ; il ne s'affichera plus après un rechargement de la régie.
          </p>
          <span className="regie-lien__actions">
            <input type="text" readOnly className="regie-lien__champ" value={fresh.maskedLink}
              aria-label="Nouveau lien intervenants (masqué)" data-testid="regie-share-link-url" />
            <CopyLinkButton link={fresh.link} />
          </span>
        </>
      ) : (
        <p className="regie-note">
          {fresh ? "Le lien affiché plus tôt a été remplacé depuis : il ne fonctionne plus. " : null}
          Régénérer : l'ancien lien intervenants ne fonctionne plus. Les intervenants déjà entrés gardent leur lien
          personnel ; les autres devront recevoir le nouveau.
        </p>
      )}
      {error ? <p className="regie-alerte" role="alert" data-testid="share-link-error">{error}</p> : null}
    </div>
  );
}

// Bloc « Participants » : modération des présents, confirmation du dernier
// retrait et régénération du lien intervenants. Après un retrait, tant que le
// lien partagé est actif, la confirmation propose de le régénérer ; entré par
// ce lien (`share_link_reentry`), la personne pourrait revenir par lui. Jamais
// d'office : ce serait couper les intervenants légitimes qui n'ont pas encore
// cliqué. L'aide détaillée est repliée sous « En savoir plus ». Le dernier
// retrait et le nouveau lien (`memory`) vivent dans la régie : ils survivent
// au passage du bloc de déplié à replié.
function ParticipantsConsole({ participantsUrl, shareLinkRegenerationUrl, status, onChanged, memory }) {
  const [error, setError] = useState(null);
  const { removal, setRemoval, fresh, setFresh } = memory;
  const handleRegenerated = useCallback(() => {
    setRemoval(null);
    onChanged();
  }, [onChanged]);

  return (
    <div className="regie-scene" data-testid="regie-participants">
      <ParticipantList status={status} participantsUrl={participantsUrl} onChanged={onChanged}
        onRemoved={setRemoval} onError={setError} />
      {removal ? (
        <p className="regie-note regie-note--info" role="status" data-testid="regie-removal-notice">
          Retrait de {removal.name} confirmé.
          {removal.shareLinkReentry && status?.share_link_fingerprint
            ? " La personne pourrait revenir par le lien partagé : le régénérer ?"
            : null}
        </p>
      ) : null}
      <ShareLinkControl regenerationUrl={shareLinkRegenerationUrl} fingerprint={status?.share_link_fingerprint ?? null}
        offered={Boolean(removal)} fresh={fresh} onFresh={setFresh} onRegenerated={handleRegenerated} />
      {error ? <p className="regie-alerte" role="alert" data-testid="participants-error">{error}</p> : null}
      <details className="regie-aide" data-testid="regie-moderation-help">
        <summary className="regie-aide__titre">En savoir plus</summary>
        <p className="regie-note">
          Couper le micro : la personne peut le rallumer. Retirer : elle quitte le direct et ne peut plus revenir depuis
          le même navigateur, avec les mêmes cookies. Une inscription confirmée ne revient pas non plus avec la même
          adresse. Une identité provisoire (mail pas encore confirmé) libère l'adresse : elle peut resservir. Retirer ne
          l'empêche pas de revenir depuis un autre navigateur ou en navigation privée, avec une autre adresse, ou par le
          lien intervenants partagé tant qu'il n'est pas régénéré : sa régénération est proposée après chaque retrait.
        </p>
      </details>
    </div>
  );
}

const ENQUEUE_REFUSALS = {
  404: "Message introuvable : rechargez la page.",
  422: "Message effacé : il ne peut pas entrer dans la file.",
};

// Inscrits et présence dans la salle (/registrations/attendance,
// RoomAttendance) : présents maintenant, venus puis partis, jamais venus.
// Réservé à qui voit déjà la liste des inscrits : sans URL, pas de bloc.
// « Venu, reparti » : déjà vu dans la salle, direct lancé ou non (RoomAttendance).
const ATTENDANCE_LABELS = { present: "Présent", left: "Venu, reparti", absent: "Absent" };
// Trois niveaux lisibles d'un coup d'œil : badge succès (coche), badge neutre
// sans pictogramme, texte grisé. Jamais `etat--info` : son « i » se lit
// comme une lettre devant le libellé (« I VENU, REPARTI », Pixel 4).
const ATTENDANCE_CLASSES = {
  present: "etat etat--succes",
  left: "etat etat--neutre",
  absent: "regie-liste__meta",
};

function plural(count, word) {
  return `${count} ${word}${count > 1 ? "s" : ""}`;
}

function RegistrationRow({ registration }) {
  return (
    <li className="regie-liste__item" data-testid="regie-registration" data-status={registration.status}>
      <span className="regie-liste__nom">{registration.name}</span>
      <span className="regie-liste__meta regie-liste__courriel">{registration.email}</span>
      {registration.participation === "participant" ? <span className="regie-liste__meta">veut intervenir</span> : null}
      {registration.confirmed ? null : <span className="regie-liste__meta">non confirmé</span>}
      {registration.removed ? <span className="regie-liste__meta">retiré du direct</span> : null}
      <span className={`${ATTENDANCE_CLASSES[registration.status] || "regie-liste__meta"} regie-liste__etat`}
        data-testid="regie-registration-status">
        {ATTENDANCE_LABELS[registration.status] || registration.status}
      </span>
    </li>
  );
}

// Lien vers la page « Présence » (qui s'est connecté quand, courbe,
// tentatives sans entrée), dans un autre onglet : la régie reste ouverte.
function RoomPresenceLink({ url }) {
  if (!url) return null;
  return (
    <p className="regie-note">
      <a className="renvoi" href={url} target="_blank" rel="noopener" data-testid="regie-room-presence-link">
        Présence en salle <span aria-hidden="true">↗</span>
        <NewTabHint />
      </a>
    </p>
  );
}

function AttendanceConsole({ attendanceUrl, roomPresenceUrl }) {
  const { status: attendance, error } = useRegieStatus(attendanceUrl);
  if (!attendance && !error) {
    return (
      <div className="regie-scene">
        <p className="regie-note">Lecture des inscrits…</p>
        <RoomPresenceLink url={roomPresenceUrl} />
      </div>
    );
  }
  if (!attendance) {
    return (
      <div className="regie-scene">
        <p className="regie-alerte" role="alert" data-testid="regie-registrations-error">Inscrits illisibles : {error}</p>
        <RoomPresenceLink url={roomPresenceUrl} />
      </div>
    );
  }
  const list = attendance.registrations || [];
  return (
    <div className="regie-scene">
      <p className="regie-note" data-testid="regie-registrations-count">
        {attendance.room === "unavailable"
          ? `${plural(attendance.registered, "inscrit")} · présence en salle inconnue`
          : `${plural(attendance.present, "présent")} sur ${plural(attendance.registered, "inscrit")}`}
        {attendance.came > attendance.present ? ` · ${plural(attendance.came, "venu")} dans la salle au total` : ""}
      </p>
      {attendance.room === "unavailable" ? (
        <p className="regie-alerte" role="alert">Salle LiveKit injoignable : seuls les inscrits déjà venus sont connus.</p>
      ) : null}
      {error ? <p className="regie-alerte" role="alert">Dernière relecture en échec : {error}</p> : null}
      {list.length === 0 ? (
        <p className="regie-note">Aucun inscrit pour ce webinaire.</p>
      ) : (
        <ul className="regie-liste" data-testid="regie-registrations">
          {list.map((registration) => <RegistrationRow key={registration.id} registration={registration} />)}
        </ul>
      )}
      <RoomPresenceLink url={roomPresenceUrl} />
    </div>
  );
}

// Ajout manuel d'un message à la file des questions (QaItemsController#create,
// source « manual »). 201 = nouvelle question, 200 = message déjà dans la
// file (le serveur ne crée pas de doublon).
async function enqueueMessage(qaItemsUrl, message) {
  let response;
  try {
    response = await fetch(qaItemsUrl, {
      method: "POST", credentials: "same-origin", cache: "no-store", redirect: "manual",
      headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
      body: JSON.stringify({ message_id: message.id }),
    });
  } catch (_networkError) {
    throw new Error("Réseau indisponible.");
  }
  if (response.type === "opaqueredirect") throw new Error("Session animateur expirée, reconnectez-vous.");
  if (!response.ok) throw new Error(ENQUEUE_REFUSALS[response.status] || `Ajout à la file refusé (${response.status}).`);
  return response.status === 201 ? "Ajouté à la file des questions." : "Ce message est déjà dans la file des questions.";
}

// Discussion de la régie. Direct terminé (`closed`) : le fil reste lisible,
// sans saisie ni modération (le serveur répond 410 après la fin) ; « Ajouter
// à la file » reste, pour les questions à reprendre après le direct.
function Discussion({ messagesUrl, moderationUrl, qaItemsUrl, onEnqueued, closed, organization }) {
  const chat = useChat({ messagesUrl, speakerToken: null });
  const onEnqueue = useCallback(async (message) => {
    const notice = await enqueueMessage(qaItemsUrl, message);
    onEnqueued();
    return notice;
  }, [qaItemsUrl, onEnqueued]);
  return <DiscussionPanel chat={chat} moderationUrl={moderationUrl} onEnqueue={onEnqueue} closed={closed} visible organization={organization} />;
}

function participantsSummary(status) {
  if (!status || status.room === "unavailable") return null;
  const count = (status.participants || []).length;
  return count === 0 ? "personne dans la salle" : `${count} dans la salle`;
}

const waitingHand = (hand) => hand.state === "waiting";

// Résumé du repli : la file entière (comme « File (n) » dans le bloc), dont
// les mains en attente de parole et les personnes à admettre en caméra.
function handsSummary(hands) {
  if (hands.length === 0) return "aucune";
  const s = hands.length > 1 ? "s" : "";
  const waiting = hands.filter(waitingHand).length;
  const toAdmitCount = hands.filter(toAdmit).length;
  return [
    `${hands.length} main${s} levée${s}`,
    waiting > 0 && waiting < hands.length ? `${waiting} en attente` : null,
    toAdmitCount > 0 ? `${toAdmitCount} à admettre` : null,
  ].filter(Boolean).join(" · ");
}

// Dernier retrait et nouveau lien intervenants : tenus par la régie, pas par
// le bloc Participants, qui se démonte quand il passe de déplié à replié.
function useModerationMemory() {
  const [removal, setRemoval] = useState(null);
  const [fresh, setFresh] = useState(null);
  return { removal, setRemoval, fresh, setFresh };
}

// Mains levées : la scène les montre déjà, le bloc reste replié tant que
// personne n'attend. Pendant ou avant le direct (`autoOpen`), une NOUVELLE
// main levée l'ouvre (donner la parole ne se fait qu'ici) ; refermé à la
// main, il le reste jusqu'à la suivante. Après la fin, il ne s'ouvre plus de
// lui-même.
function useHandsFold(autoOpen) {
  const [hands, setHands] = useState([]);
  const [open, setOpen] = useState(false);
  const seenRef = useRef(new Set());
  useEffect(() => {
    const arrived = hands.some((hand) => !seenRef.current.has(hand.id));
    hands.forEach((hand) => seenRef.current.add(hand.id));
    if (arrived && autoOpen) setOpen(true);
  }, [hands, autoOpen]);
  return { hands, setHands, open, setOpen };
}

function Regie({ initialState, initialLiveSince, initialEndedAt, urls, organization }) {
  const { status, error: statusError, refresh } = useRegieStatus(urls.status);
  const [state, setState] = useState(initialState || "draft");
  const serverState = status?.state;
  // Le serveur reste juge : un changement venu d'ailleurs (autre animateur,
  // fin automatique) s'impose à l'affichage.
  useEffect(() => {
    if (serverState) setState(serverState);
  }, [serverState]);
  const liveSince = status ? status.live_since : initialLiveSince;
  const endedAt = status ? status.ended_at : initialEndedAt;

  const handleStateChange = useCallback((next) => {
    setState(next);
    refresh();
  }, [refresh]);

  // Un ajout depuis la discussion relit aussitôt la file des questions.
  const [qaRefresh, setQaRefresh] = useState(0);
  const handleEnqueued = useCallback(() => setQaRefresh((count) => count + 1), []);
  const handsFold = useHandsFold(state !== "ended");
  const moderationMemory = useModerationMemory();

  // Un bloc se pose ouvert ou replié selon le moment (regie_layout.mjs).
  const place = ({ block, folded, rank }, { title, testid, summary, titled, open, onOpenChange, attention, children }) => (
    folded ? (
      <RegieFold key={block} title={title} testid={testid} rank={rank} summary={summary}
        open={open} onOpenChange={onOpenChange} attention={attention}>
        {children}
      </RegieFold>
    ) : (
      <RegieSection key={block} title={title} testid={testid} rank={rank} titled={titled}>{children}</RegieSection>
    )
  );

  const renderers = {
    recording: (entry) => place(entry, {
      title: "Enregistrement", testid: "regie-recording",
      children: <RecordingControl statusUrl={urls.recordingStatus} startUrl={urls.recordingStart} />,
    }),
    cameras: (entry) => place(entry, {
      title: "Caméras", testid: "regie-cameras-section",
      children: <CameraQualityConsole status={status} />,
    }),
    polls: (entry) => place(entry, {
      title: "Sondages", testid: "regie-polls", titled: false,
      children: <PollConsole pollsUrl={urls.polls} presentCount={status?.present ?? null} />,
    }),
    participants: (entry) => place(entry, {
      title: "Participants", testid: "regie-participants-section", summary: participantsSummary(status),
      children: <ParticipantsConsole participantsUrl={urls.participants} shareLinkRegenerationUrl={urls.shareLinkRegeneration}
        status={status} onChanged={refresh} memory={moderationMemory} />,
    }),
    attendance: (entry) => (urls.attendance ? place(entry, {
      title: "Inscrits", testid: "regie-registrations-section",
      children: <AttendanceConsole attendanceUrl={urls.attendance} roomPresenceUrl={urls.roomPresence} />,
    }) : null),
    spotlight: (entry) => place(entry, {
      title: "Mise en avant", testid: "regie-spotlight-section", summary: spotlightSummary(status),
      children: <SpotlightConsole spotlightUrl={urls.spotlight} status={status} onChanged={refresh} />,
    }),
    hands: (entry) => place(entry, {
      title: "Mains levées", testid: "regie-hands", summary: handsSummary(handsFold.hands),
      open: handsFold.open, onOpenChange: handsFold.setOpen, attention: handsFold.hands.some(toAdmit),
      children: <HandRaiseHost listUrl={urls.handRaises} onHandsChange={handsFold.setHands} />,
    }),
    questions: (entry) => place(entry, {
      title: "Questions", testid: "regie-qa", titled: false,
      children: <QaConsole itemsUrl={urls.qaItems} refreshSignal={qaRefresh} ended={state === "ended"} />,
    }),
    discussion: (entry) => place(entry, {
      title: "Discussion", testid: "regie-discussion",
      children: <Discussion messagesUrl={urls.messages} moderationUrl={urls.messageModeration}
        qaItemsUrl={urls.qaItems} onEnqueued={handleEnqueued} closed={state === "ended"} organization={organization} />,
    }),
  };

  const layout = regieLayout(state, { handsRaised: handsFold.hands.some(waitingHand) });
  return (
    <div className="regie__grille" data-testid="regie-grille" data-moment={layout.moment}>
      <RegieHeader state={state} liveSince={liveSince} endedAt={endedAt} status={status} urls={urls}
        onStateChange={handleStateChange} />
      {statusError ? (
        <p className="regie-alerte" role="alert" data-testid="regie-status-error">
          État de la régie illisible : {statusError}
        </p>
      ) : null}
      <TranscriptionNotice since={status?.transcription_interrupted_since} />
      <div className="regie__colonne">
        {layout.left.map((entry) => renderers[entry.block](entry))}
      </div>
      <div className="regie__colonne">
        {layout.right.map((entry) => renderers[entry.block](entry))}
      </div>
    </div>
  );
}

export function mountRegie() {
  const el = document.getElementById(MOUNT_ID);
  if (!el) return;
  const data = el.dataset;
  if (!data.slug || !data.statusUrl) {
    // Marqueur explicite d'un data-attr manquant (fail-loud).
    el.textContent = "regie: data-slug ou data-status-url manquant";
    return;
  }
  const urls = {
    status: data.statusUrl,
    state: data.stateUrl,
    goLive: data.goLiveUrl,
    end: data.endUrl,
    resume: data.resumeUrl,
    recordingStatus: data.recordingStatusUrl,
    recordingStart: data.recordingStartUrl,
    handRaises: data.handRaisesUrl,
    spotlight: data.spotlightUrl,
    participants: data.participantsUrl,
    shareLinkRegeneration: data.shareLinkRegenerationUrl,
    messages: data.messagesUrl,
    messageModeration: data.messageModerationUrl,
    polls: data.pollsUrl,
    qaItems: data.qaItemsUrl,
    stage: data.stageUrl,
    attendance: data.attendanceUrl || null,
    roomPresence: data.roomPresenceUrl || null,
  };
  createRoot(el).render(
    <Regie initialState={data.state} initialLiveSince={data.liveSince || null} initialEndedAt={data.endedAt || null}
      urls={urls} organization={data.organization} />,
  );
}
