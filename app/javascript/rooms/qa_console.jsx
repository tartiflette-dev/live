// Console Q&R de la régie — composant AUTONOME : il ne
// dépend que de l'URL de la file (QaItemsController), pas de la salle.
//
//   <QaConsole itemsUrl="/webinars/<slug>/qa_items" refreshSignal={n} />
//   montée par la régie (regie.jsx).
//
// La file arrive par HTTP : au montage, toutes les `pollIntervalMs`, et dès
// qu'un paquet `qa` du serveur passe sur le data channel quand la console
// est montée DANS une salle LiveKit (useMaybeRoomContext ; la régie, sans
// vidéo, n'en a pas et vit du polling). Le paquet ne sert que de signal : la
// file et ses auteurs ne voyagent qu'en HTTP, réservés à l'animation.
// `refreshSignal` (facultatif) : chaque nouvelle valeur relit la file tout
// de suite — la régie l'incrémente après un ajout depuis la discussion.
// `ended` (facultatif) : direct terminé, plus rien ne s'affiche à l'écran
// (le serveur refuse) — « Afficher à l'écran » disparaît, le reste demeure.
//
// Ouvertes d'abord ; les traitées (répondues, écartées) dans un repli.
// Chaque question montre sa reformulation, le nombre et les noms de ceux qui
// l'ont posée, leurs messages d'origine (dépliables) — ou, posée depuis le
// replay, l'instant de la vidéo où elle l'a été — et les actions :
// afficher / retirer de l'écran, répondue, écarter, rouvrir, modifier le
// libellé. Texte rendu en nœuds React, jamais en HTML. Fail-loud : chaque
// panne est un message visible dans la console.

import { useCallback, useEffect, useRef, useState } from "react";
import { useMaybeRoomContext } from "@livekit/components-react";
import { RoomEvent } from "livekit-client";
import { csrfToken } from "./state_button";
import { LABEL_LIMIT, authorsSummary, readServerQa, validConsoleItem } from "./qa_state.mjs";
import { clockTime } from "./clock_time.mjs";
import { videoTimecode } from "./video_timecode.mjs";

const POLL_INTERVAL_MS = 5000;
const SOURCE_LABELS = { llm: "Reformulée", mention: "Texte brut", manual: "Ajoutée", replay: "Replay" };
const ANALYSIS_FAILURES = {
  timeout: "délai dépassé",
  unreachable: "modèle injoignable",
  invalid: "réponse inexploitable",
  error: "erreur imprévue",
};
const STATUS_LABELS = { answered: "Répondue", dismissed: "Écartée" };
const ROLE_LABELS = { host: "Animateur", speaker: "Intervenant" };
const REFUSALS = {
  404: "Question introuvable : rechargez la page.",
  410: "Le direct est terminé : plus rien ne s'affiche à l'écran.",
  422: "Action refusée (libellé vide ou trop long, ou question déjà traitée).",
};

async function refusal(response) {
  const body = await response.json().catch(() => null);
  if (body && body.error === "invalid_authenticity_token") return "Session expirée : rechargez la page.";
  return REFUSALS[response.status] || `Action non confirmée (${response.status || "réseau"}).`;
}

// État RÉEL de l'analyse (QaItemsController#analysis) : drapeau de
// configuration et issue du dernier appel au LLM local pour ce webinaire.
function AnalysisStatus({ analysis }) {
  if (!analysis) return null;
  if (!analysis.enabled) {
    return <p className="qa-console__hint" data-analysis="disabled">Analyse automatique coupée : seules les questions adressées à @animateur arrivent ici, en texte brut.</p>;
  }
  if (!analysis.outcome) {
    return <p className="qa-console__hint" data-analysis="idle">Analyse automatique active : aucun message analysé pour l'instant.</p>;
  }
  const when = analysis.at ? clockTime(analysis.at) : "?";
  const seconds = Number.isFinite(analysis.duration_ms) ? ` (${(analysis.duration_ms / 1000).toLocaleString("fr-FR", { maximumFractionDigits: 1 })} s)` : "";
  if (analysis.outcome === "ok") {
    return <p className="qa-console__hint" data-analysis="ok">Analyse automatique : dernier appel réussi à {when}{seconds}.</p>;
  }
  const reason = ANALYSIS_FAILURES[analysis.outcome] || analysis.outcome;
  return (
    <p className="qa-console__alert" role="alert" data-analysis="failed">
      Analyse automatique en panne au dernier appel ({when}, {reason}{seconds}) : seules les questions adressées à @animateur arrivent, en texte brut.
    </p>
  );
}

function useQaQueue(itemsUrl, pollIntervalMs) {
  const [items, setItems] = useState([]);
  const [analysis, setAnalysis] = useState(null);
  const [syncError, setSyncError] = useState("");
  const refreshRef = useRef(() => {});

  useEffect(() => {
    const aborter = new AbortController();
    let timer = null;
    const refresh = async () => {
      try {
        const response = await fetch(itemsUrl, {
          credentials: "same-origin", cache: "no-store", redirect: "manual", signal: aborter.signal,
          headers: { Accept: "application/json" },
        });
        if (!response.ok) throw new Error(`File Q&R indisponible (${response.status || "réseau"}).`);
        const body = await response.json();
        if (!Array.isArray(body?.items) || !body.items.every(validConsoleItem)) throw new Error("Réponse de la file Q&R invalide.");
        setItems(body.items);
        setAnalysis(body.analysis && typeof body.analysis === "object" ? body.analysis : null);
        setSyncError("");
      } catch (error) {
        if (!aborter.signal.aborted) setSyncError(error.message || "File Q&R momentanément indisponible.");
      } finally {
        // Un rafraîchissement anticipé (signal, action) remplace le minuteur
        // en cours : jamais deux boucles de polling.
        clearTimeout(timer);
        if (!aborter.signal.aborted) timer = setTimeout(refresh, pollIntervalMs);
      }
    };
    refreshRef.current = refresh;
    refresh();
    return () => {
      aborter.abort();
      clearTimeout(timer);
    };
  }, [itemsUrl, pollIntervalMs]);

  const refresh = useCallback(() => refreshRef.current(), []);
  return { items, analysis, syncError, refresh };
}

// Signal temps réel quand la console vit dans une salle LiveKit.
function useQaSignal(onSignal) {
  const room = useMaybeRoomContext();
  useEffect(() => {
    if (!room) return undefined;
    const receive = (payload, participant) => {
      if (readServerQa(payload, participant)) onSignal();
    };
    room.on(RoomEvent.DataReceived, receive);
    return () => {
      room.off(RoomEvent.DataReceived, receive);
    };
  }, [room, onSignal]);
}

function LabelEditor({ item, busy, onSave, onCancel }) {
  const [draft, setDraft] = useState(item.label);
  const submit = (event) => {
    event.preventDefault();
    if (draft.trim()) onSave(draft.trim());
  };
  return (
    <form className="qa-console__edit" onSubmit={submit}>
      <label className="qa-console__edit-label" htmlFor={`qa-label-${item.id}`}>Libellé de la question</label>
      <textarea id={`qa-label-${item.id}`} rows={2} maxLength={LABEL_LIMIT} value={draft} onChange={(event) => setDraft(event.target.value)} />
      <span className="qa-console__actions">
        <button type="submit" className="btn btn--secondary" disabled={busy || !draft.trim()}>Enregistrer</button>
        <button type="button" className="btn btn--discret" onClick={onCancel}>Annuler</button>
      </span>
    </form>
  );
}

function QaCard({ item, busy, act, relabel, ended }) {
  const [editing, setEditing] = useState(false);
  const count = item.authors.length;
  const button = (action, text, variant = "btn--secondary") => (
    <button type="button" className={`btn ${variant}`} disabled={busy} onClick={() => act(item, action)}>{text}</button>
  );

  return (
    <li className="qa-console__item" data-qa-item-id={item.id} data-status={item.status} data-displayed={item.displayed_at ? "true" : undefined}>
      <div className="qa-console__meta">
        <span className="qa-console__count" title={item.authors.map((author) => author.name).join(", ")}>
          {count} personne{count > 1 ? "s" : ""} · {authorsSummary(item.authors)}
        </span>
        <span className="qa-console__tag">{STATUS_LABELS[item.status] || SOURCE_LABELS[item.source] || item.source}</span>
        {item.displayed_at ? <span className="qa-console__tag qa-console__tag--live">À l'écran</span> : null}
        <time className="qa-console__time" dateTime={item.created_at}>{clockTime(item.created_at)}</time>
      </div>
      {item.source === "replay" ? (
        <p className="qa-console__hint" data-qa-replay-position>Posée depuis le replay, à {videoTimecode(item.video_position)} de la vidéo</p>
      ) : null}
      {editing ? (
        <LabelEditor item={item} busy={busy} onCancel={() => setEditing(false)}
          onSave={async (label) => { if (await relabel(item, label)) setEditing(false); }} />
      ) : (
        <p className="qa-console__label">{item.label}</p>
      )}
      {item.messages.length === 0 ? null : <details className="qa-console__origins">
        <summary>Messages d'origine ({item.messages.length})</summary>
        <ol>
          {item.messages.map((message) => (
            <li key={message.id}>
              <div className="qa-console__meta">
                <span className="qa-console__author">{message.name}</span>
                {ROLE_LABELS[message.author_role] ? <span className="qa-console__tag">{ROLE_LABELS[message.author_role]}</span> : null}
                <time className="qa-console__time" dateTime={message.created_at}>{clockTime(message.created_at)}</time>
              </div>
              <p className="qa-console__body">{message.body}</p>
            </li>
          ))}
        </ol>
      </details>}
      <div className="qa-console__actions">
        {item.status === "open" ? (
          <>
            {item.displayed_at ? button("hide", "Retirer de l'écran") : ended ? null : button("display", "Afficher à l'écran", "")}
            {button("answer", "Répondue")}
            {button("dismiss", "Écarter", "btn--discret")}
            {editing ? null : <button type="button" className="btn btn--discret" disabled={busy} onClick={() => setEditing(true)}>Modifier</button>}
          </>
        ) : button("reopen", "Rouvrir", "btn--discret")}
      </div>
    </li>
  );
}

export function QaConsole({ itemsUrl, pollIntervalMs = POLL_INTERVAL_MS, refreshSignal = 0, ended = false }) {
  const queue = useQaQueue(itemsUrl, pollIntervalMs);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");
  useQaSignal(queue.refresh);
  const { refresh } = queue;
  useEffect(() => {
    if (refreshSignal) refresh();
  }, [refreshSignal, refresh]);

  const request = async (url, method, body) => {
    if (busy) return false;
    setBusy(true);
    try {
      const response = await fetch(url, {
        method, credentials: "same-origin", cache: "no-store", redirect: "manual",
        headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
        body: JSON.stringify(body),
      });
      if (!response.ok) throw new Error(await refusal(response));
      const item = await response.json().catch(() => null);
      setNotice(item?.broadcast === "unavailable" ? "Enregistré ; la salle le verra sous quelques secondes (diffusion en direct indisponible)." : "");
      return true;
    } catch (error) {
      setNotice(error instanceof TypeError ? "Réseau indisponible." : error.message);
      return false;
    } finally {
      setBusy(false);
      queue.refresh();
    }
  };

  const act = (item, action) => request(`${itemsUrl}/${item.id}/${action}`, "POST", {});
  const relabel = (item, label) => request(`${itemsUrl}/${item.id}`, "PATCH", { label });

  const open = queue.items.filter((item) => item.status === "open");
  const done = queue.items.filter((item) => item.status !== "open");
  const card = (item) => <QaCard key={item.id} item={item} busy={busy} act={act} relabel={relabel} ended={ended} />;

  return (
    <section className="qa-console" data-testid="qa-console" aria-label="Questions du public">
      <header className="qa-console__header">
        <h2 className="qa-console__title">Questions ({open.length})</h2>
        <AnalysisStatus analysis={queue.analysis} />
      </header>
      {queue.syncError ? <p className="qa-console__alert" role="alert">{queue.syncError}</p> : null}
      {notice ? <p className="qa-console__alert" role="status">{notice}</p> : null}
      {open.length === 0 ? <p className="qa-console__empty">Aucune question en attente.</p> : <ol className="qa-console__list">{open.map(card)}</ol>}
      {done.length > 0 ? (
        <details className="qa-console__done">
          <summary>Traitées ({done.length})</summary>
          <ol className="qa-console__list">{done.map(card)}</ol>
        </details>
      ) : null}
    </section>
  );
}
