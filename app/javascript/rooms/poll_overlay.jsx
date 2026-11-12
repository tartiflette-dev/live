// Pop-up des sondages du direct — montée dans la
// salle pour TOUS les rôles : l'animation voit exactement ce que voient les
// participants, et peut répondre comme eux.
//
// Ce qui est à l'écran est décidé par le serveur (PollParticipationsController,
// PollBroadcast) : le sondage ouvert, ou celui dont l'animation montre le
// résultat. Le client le reçoit par le data channel LiveKit (paquets filtrés
// par poll_state.mjs) et le relit par HTTP (le plus récent gagne) : toutes les 30 s
// tant que la salle est connectée (le data channel porte le temps réel),
// toutes les 5 s sinon, et aussitôt la connexion retrouvée. Il n'émet jamais
// sur le data channel. La réponse part en HTTP et peut être modifiée tant que
// le sondage est ouvert.
//
// Non bloquante : une carte sur le côté de la vidéo, jamais une modale ; on
// la réduit en une pastille (bouton ou Échap) et un nouveau sondage, sa
// fermeture ou son résultat la rouvrent. Le focus n'est jamais volé (la
// personne écrit peut-être dans la discussion) : l'arrivée d'un sondage est
// annoncée par une région live. La réponse est nominative et la carte le dit
// au moment de répondre (consentement éclairé). Fail-loud : chaque refus est
// un message visible dans la carte.

import { useCallback, useEffect, useId, useRef, useState } from "react";
import { useConnectionState, useRoomContext } from "@livekit/components-react";
import { ConnectionState, RoomEvent } from "livekit-client";
import { csrfToken } from "./state_button";
import { TEXT_LIMIT, applyHttpSnapshot, applyPacketSnapshot, formatOf, percentages, readServerSnapshot, scaleValues, validSnapshot } from "./poll_state.mjs";
import { NewTabHint } from "./new_tab_hint";

const CONNECTED_POLL_INTERVAL_MS = 30000;
const FALLBACK_POLL_INTERVAL_MS = 5000;
const REFUSALS = {
  403: "Vous ne pouvez pas répondre à ce sondage.",
  409: "Le sondage est fermé : réponse non enregistrée.",
  422: "Réponse incomplète ou trop longue.",
  429: "Trop d'envois d'affilée : patientez quelques secondes.",
};

function requestHeaders(speakerToken) {
  const headers = { Accept: "application/json" };
  if (speakerToken) headers["X-Speaker-Token"] = speakerToken;
  return headers;
}

async function readSnapshot(response) {
  const body = await response.json().catch(() => null);
  if (!body || !validSnapshot(body)) throw new Error("Réponse de sondage invalide.");
  return body;
}

// État partagé : sondage à l'écran + réponse de la personne.
export function usePoll({ pollsUrl, speakerToken }) {
  const room = useRoomContext();
  const connected = useConnectionState(room) === ConnectionState.Connected;
  const [state, setState] = useState({ at: null, poll: null, myResponse: null });
  const [syncError, setSyncError] = useState("");
  const applyHttp = useCallback((snapshot) => {
    setState((previous) => applyHttpSnapshot(previous, snapshot, snapshot.my_response));
  }, []);

  useEffect(() => {
    const receive = (payload, participant) => {
      const snapshot = readServerSnapshot(payload, participant);
      if (snapshot) setState((previous) => applyPacketSnapshot(previous, snapshot, Date.now()));
    };
    room.on(RoomEvent.DataReceived, receive);
    return () => {
      room.off(RoomEvent.DataReceived, receive);
    };
  }, [room]);

  // Relu au montage et à chaque changement de connexion (reconnexion :
  // des paquets ont pu se perdre), puis au rythme de la connexion.
  useEffect(() => {
    const aborter = new AbortController();
    let timer = null;
    const poll = async () => {
      try {
        const response = await fetch(`${pollsUrl}/current`, {
          credentials: "same-origin", cache: "no-store", redirect: "manual", signal: aborter.signal,
          headers: requestHeaders(speakerToken),
        });
        if (!response.ok) throw new Error(`Sondages indisponibles (${response.status || "réseau"}).`);
        applyHttp(await readSnapshot(response));
        setSyncError("");
      } catch (error) {
        if (!aborter.signal.aborted) setSyncError(error.message || "Sondages momentanément indisponibles.");
      } finally {
        if (!aborter.signal.aborted) timer = setTimeout(poll, connected ? CONNECTED_POLL_INTERVAL_MS : FALLBACK_POLL_INTERVAL_MS);
      }
    };
    poll();
    return () => {
      aborter.abort();
      clearTimeout(timer);
    };
  }, [pollsUrl, speakerToken, applyHttp, connected]);

  const respond = useCallback(async (pollId, value) => {
    let response;
    try {
      response = await fetch(`${pollsUrl}/${pollId}/responses`, {
        method: "POST", credentials: "same-origin", cache: "no-store", redirect: "manual",
        headers: { ...requestHeaders(speakerToken), "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
        body: JSON.stringify({ value }),
      });
    } catch (_networkError) {
      throw new Error("Réseau indisponible : réponse non envoyée.");
    }
    if (!response.ok) {
      const body = await response.json().catch(() => null);
      if (body?.error === "invalid_authenticity_token") throw new Error("Session expirée : rechargez la page.");
      throw new Error(REFUSALS[response.status] || `Réponse non confirmée (${response.status || "réseau"}).`);
    }
    applyHttp(await readSnapshot(response));
  }, [pollsUrl, speakerToken, applyHttp]);

  return { ...state, syncError, respond };
}

function plural(count, word) {
  return `${count} ${word}${count > 1 ? "s" : ""}`;
}

// Barres de résultat (choix, échelle) : le texte porte l'information
// (lecteur d'écran), la barre n'est qu'un repère visuel.
function BarResults({ poll, results }) {
  const shares = percentages(results);
  return (
    <ol className="lk-poll__bars" data-testid="poll-results">
      {formatOf(poll).resultLabels(poll).map((label, index) => (
        <li key={index} className="lk-poll__bar" data-share={shares[index]}>
          <span className="lk-poll__bar-label">{label}</span>
          <span className="lk-poll__bar-value">{shares[index]} % ({results.counts[index]})</span>
          <span className="lk-poll__bar-track" aria-hidden="true">
            <span className="lk-poll__bar-fill" style={{ width: `${shares[index]}%` }} />
          </span>
        </li>
      ))}
    </ol>
  );
}

function TextResults({ results }) {
  if (results.answers.length === 0) return <p className="lk-poll__hint">Aucune réponse.</p>;
  return (
    <ul className="lk-poll__answers" data-testid="poll-text-results">
      {results.answers.map((answer, index) => <li key={index} className="lk-poll__answer">{answer}</li>)}
    </ul>
  );
}

const RESULT_VIEWS = { choice: BarResults, scale: BarResults, short_text: TextResults };

function ChoiceField({ poll, name, draft, setDraft }) {
  const toggle = (index) => {
    if (!poll.multiple) return setDraft([index]);
    setDraft((current) => (current.includes(index) ? current.filter((value) => value !== index) : [...current, index].sort()));
  };
  return (
    <fieldset className="lk-poll__choices">
      <legend className="lk-poll__hint">{poll.multiple ? "Plusieurs choix possibles" : "Un seul choix"}</legend>
      {poll.options.map((option, index) => (
        <label key={index} className="lk-poll__choice">
          <input type={poll.multiple ? "checkbox" : "radio"} name={name} checked={draft.includes(index)} onChange={() => toggle(index)} />
          <span>{option}</span>
        </label>
      ))}
    </fieldset>
  );
}

function ScaleField({ poll, name, draft, setDraft }) {
  const scale = poll.options;
  return (
    <fieldset className="lk-poll__choices">
      <legend className="lk-poll__hint">De {scale.min} à {scale.max}</legend>
      <div className="lk-poll__scale">
        {scaleValues(poll).map((value) => (
          <label key={value} className="lk-poll__scale-value">
            <input type="radio" name={name} checked={draft === value} onChange={() => setDraft(value)} />
            <span>{value}</span>
          </label>
        ))}
        {scale.min_label || scale.max_label ? (
          <p className="lk-poll__scale-labels">
            <span>{scale.min} : {scale.min_label || "—"}</span>
            <span>{scale.max} : {scale.max_label || "—"}</span>
          </p>
        ) : null}
      </div>
    </fieldset>
  );
}

function TextField({ name, draft, setDraft }) {
  return (
    <>
      <label className="lk-poll__hint" htmlFor={name}>Votre réponse ({TEXT_LIMIT} caractères au plus)</label>
      <input id={name} className="lk-poll__input" type="text" maxLength={TEXT_LIMIT} value={draft}
             onChange={(event) => setDraft(event.target.value)} />
    </>
  );
}

const FIELD_VIEWS = { choice: ChoiceField, scale: ScaleField, short_text: TextField };

function PollForm({ poll, myResponse, onRespond }) {
  const name = useId();
  const format = formatOf(poll);
  const Field = FIELD_VIEWS[poll.kind];
  const answered = myResponse !== null && myResponse !== undefined;
  const [draft, setDraft] = useState(() => (answered ? myResponse : format.initialDraft()));
  const [sending, setSending] = useState(false);
  const [notice, setNotice] = useState("");

  const submit = async (event) => {
    event.preventDefault();
    if (sending || !format.ready(draft)) return;
    setSending(true);
    try {
      await onRespond(poll.id, format.submitted(draft));
      setNotice("Réponse enregistrée — modifiable tant que le sondage est ouvert.");
    } catch (error) {
      setNotice(error.message);
    } finally {
      setSending(false);
    }
  };

  return (
    <form className="lk-poll__form" onSubmit={submit}>
      <Field poll={poll} name={name} draft={draft} setDraft={setDraft} />
      <p className="lk-poll__hint" data-testid="poll-consent">
        Réponse nominative : l'animation voit votre nom et votre réponse ; les autres participants ne voient que
        le résultat d'ensemble (<a href="/confidentialite" target="_blank" rel="noopener">confidentialité<NewTabHint /></a>).
      </p>
      <div className="lk-poll__actions">
        <button type="submit" className="lk-poll__submit" disabled={sending || !format.ready(draft)}>
          {answered ? "Modifier ma réponse" : "Répondre"}
        </button>
      </div>
      {notice ? <p className="lk-poll__notice" role="status">{notice}</p> : null}
    </form>
  );
}

// Point de montage unique dans la salle (room.jsx), à l'intérieur de
// <LiveKitRoom> (data channel).
export function PollOverlay({ pollsUrl, speakerToken }) {
  const { poll, myResponse, syncError, respond } = usePoll({ pollsUrl, speakerToken });
  const titleId = useId();
  const cardId = useId();
  const [reduced, setReduced] = useState(false);
  const [announcement, setAnnouncement] = useState("");
  const shownKey = poll ? `${poll.id}:${poll.open}:${poll.results ? 1 : 0}` : null;
  const previousKey = useRef(null);
  const sectionRef = useRef(null);
  const pillRef = useRef(null);

  // Un nouveau sondage, sa fermeture ou son résultat rouvrent la carte et
  // sont annoncés — sans prendre le focus.
  useEffect(() => {
    if (shownKey === previousKey.current) return;
    previousKey.current = shownKey;
    if (!poll) return;
    setReduced(false);
    setAnnouncement(poll.results ? `Résultat du sondage : ${poll.label}` : poll.open ? `Nouveau sondage : ${poll.label}` : "");
  }, [shownKey, poll]);

  // Geste de la personne : le focus suit (carte ↔ pastille), il ne se perd pas.
  const reduce = () => {
    setReduced(true);
    requestAnimationFrame(() => pillRef.current?.focus());
  };
  const expand = () => {
    setReduced(false);
    requestAnimationFrame(() => sectionRef.current?.focus());
  };
  const handleKeyDown = (event) => {
    if (event.key === "Escape") reduce();
  };

  const live = <p className="lk-poll__live" aria-live="polite" data-testid="poll-announcement">{announcement}</p>;
  if (!poll) return syncError ? <>{live}<p className="lk-poll__sync-error" role="alert">{syncError}</p></> : live;

  const answered = myResponse !== null && myResponse !== undefined;
  const status = poll.open ? (answered ? "Vous avez répondu" : "Sondage en cours") : "Résultat du sondage";
  const Results = RESULT_VIEWS[poll.kind];
  // Réduite, la carte reste montée (cachée) : un brouillon commencé survit.
  return (
    <>
      {live}
      {reduced ? (
        <button type="button" ref={pillRef} className="lk-poll lk-poll--reduced" onClick={expand}
                aria-expanded="false" aria-controls={cardId} data-testid="poll-reduced">
          {status} · {poll.open && !answered ? "Répondre" : "Afficher"}
        </button>
      ) : null}
      <section className="lk-poll" id={cardId} role="dialog" aria-modal="false" aria-labelledby={titleId} onKeyDown={handleKeyDown}
               ref={sectionRef} tabIndex={-1} hidden={reduced} data-testid="poll-overlay" data-poll-id={poll.id} data-open={poll.open}>
        <header className="lk-poll__header">
          <span className="lk-poll__status">{status}</span>
          <span className="lk-poll__count">{plural(poll.responses_count, "réponse")}</span>
          <button type="button" className="lk-poll__reduce" onClick={reduce} aria-expanded="true" aria-controls={cardId}>
            Réduire
          </button>
        </header>
        <h2 className="lk-poll__label" id={titleId}>{poll.label}</h2>
        {syncError ? <p className="lk-poll__sync-error" role="alert">{syncError}</p> : null}
        {poll.results ? <Results poll={poll} results={poll.results} /> : null}
        {poll.open ? <PollForm key={poll.id} poll={poll} myResponse={myResponse} onRespond={respond} /> : null}
      </section>
    </>
  );
}
