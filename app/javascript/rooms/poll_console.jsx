// Console des sondages pour la régie animateur.
// Composant AUTONOME : il ne dépend ni de LiveKit
// ni de la salle — la régie n'a pas de flux vidéo — et se synchronise par
// HTTP sur PollsController (toutes les 2 s onglet visible, 30 s onglet
// masqué et aussitôt au retour ; animation seulement).
//
//   <PollConsole pollsUrl="/webinars/<slug>/polls" presentCount={12} />
//
// montée par la régie (regie.jsx).
//
// Plan du webinaire dans son ordre : minute prévue face au chrono du direct
// (« dans 3 min », « 2 min de retard »), aide-mémoire, lancement, fermeture,
// compteur de répondants (sur les présents si la régie les fournit), % par
// option, qui a répondu quoi, montrer / masquer le résultat à la salle.
// Création à la volée : « Ajouter au plan » ou « Lancer maintenant ».
// Styles : app/assets/stylesheets/polls.css (tokens de la charte).
// Fail-loud : tout refus serveur est un message visible.

import { useCallback, useEffect, useId, useState } from "react";
import { csrfToken } from "./state_button";
import { FORMATS, formatOf, percentages } from "./poll_state.mjs";

const REFRESH_INTERVAL_MS = 2000;
// Onglet masqué (la salle au premier plan) : relecture rare, comme
// /regie/status ; au retour sur l'onglet, relecture immédiate.
const HIDDEN_REFRESH_INTERVAL_MS = 30000;
const STATE_LABELS = { planned: "Prévu", open: "En cours", closed: "Fermé" };
// Chrono absent : le direct n'a pas commencé, ou il est fini — jamais
// « non démarré » après la fin.
const CLOCK_IDLE_LABELS = { draft: "Direct non démarré", ended: "Direct terminé" };
const ERRORS = {
  webinar_not_live: "Le direct n'est pas en cours : impossible de lancer un sondage.",
  already_opened: "Ce sondage a déjà été lancé : il n'est plus modifiable.",
  other_poll_open: "Un autre sondage est en cours : fermez-le avant de montrer ce résultat.",
  never_opened: "Ce sondage n'a pas encore été lancé.",
  poll_open: "Fermez le sondage avant de montrer ses réponses courtes à la salle.",
  invalid_order: "Le plan a changé entre-temps : réessayez.",
  invalid_authenticity_token: "Session expirée : rechargez la page.",
};

async function request(url, { method = "GET", body } = {}) {
  let response;
  try {
    response = await fetch(url, {
      method, credentials: "same-origin", cache: "no-store", redirect: "manual",
      headers: {
        Accept: "application/json",
        ...(method === "GET" ? {} : { "X-CSRF-Token": csrfToken() }),
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (_networkError) {
    throw new Error("Réseau indisponible.");
  }
  if (response.type === "opaqueredirect") throw new Error("Session expirée : reconnectez-vous.");
  if (response.status === 204) return null;
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    const detail = payload?.details ? ` (${payload.details.join(", ")})` : "";
    throw new Error((ERRORS[payload?.error] || `Action refusée (${response.status}).`) + detail);
  }
  return payload;
}

// Minutes écoulées depuis le début du direct, horloge serveur (`now` du
// plan) corrigée de l'écart avec l'horloge locale.
function useLiveClock(startedAt, serverOffsetMs) {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  if (!startedAt) return null;
  return Math.max(0, now + serverOffsetMs - Date.parse(startedAt));
}

function formatClock(elapsedMs) {
  const total = Math.floor(elapsedMs / 1000);
  const hours = Math.floor(total / 3600);
  const minutes = String(Math.floor((total % 3600) / 60)).padStart(2, "0");
  const seconds = String(total % 60).padStart(2, "0");
  return hours > 0 ? `${hours}:${minutes}:${seconds}` : `${minutes}:${seconds}`;
}

// Écart entre la minute prévue et le chrono, pour un sondage pas encore lancé.
function timingLabel(poll, elapsedMs) {
  if (poll.planned_minute === null) return "Sans horaire";
  const planned = `À ${poll.planned_minute} min`;
  if (elapsedMs === null || poll.state !== "planned") return planned;
  const delta = poll.planned_minute - Math.floor(elapsedMs / 60000);
  if (delta > 0) return `${planned} · dans ${delta} min`;
  if (delta === 0) return `${planned} · maintenant`;
  return `${planned} · ${-delta} min de retard`;
}

// Champs d'options propres à chaque type (un éditeur par format) : lecture
// d'un sondage existant, champs du formulaire, options envoyées au serveur.
function ChoiceOptionsFields({ id, draft, set }) {
  return (
    <>
      <div className="poll-console__row">
        <label htmlFor={`${id}-options`}>Choix (un par ligne, 2 à 6)</label>
        <textarea id={`${id}-options`} rows={4} value={draft.optionsText} onChange={set("optionsText")} />
      </div>
      <label className="poll-console__check">
        <input type="checkbox" checked={draft.multiple} onChange={set("multiple")} /> Plusieurs choix possibles
      </label>
    </>
  );
}

function ScaleOptionsFields({ draft, set }) {
  return (
    <div className="poll-console__scale">
      <label>De <input type="number" min={0} max={1} value={draft.min} onChange={set("min")} aria-label="Minimum" /></label>
      <label>à <input type="number" min={2} max={10} value={draft.max} onChange={set("max")} aria-label="Maximum" /></label>
      <input type="text" maxLength={120} placeholder="Libellé du minimum" value={draft.min_label} onChange={set("min_label")} aria-label="Libellé du minimum" />
      <input type="text" maxLength={120} placeholder="Libellé du maximum" value={draft.max_label} onChange={set("max_label")} aria-label="Libellé du maximum" />
    </div>
  );
}

const OPTION_EDITORS = {
  choice: {
    Fields: ChoiceOptionsFields,
    read: (poll) => ({ optionsText: poll.options.join("\n") }),
    payload: (draft) => draft.optionsText.split("\n").map((line) => line.trim()).filter(Boolean),
  },
  scale: {
    Fields: ScaleOptionsFields,
    read: (poll) => ({ min: poll.options.min, max: poll.options.max, min_label: poll.options.min_label || "", max_label: poll.options.max_label || "" }),
    payload: (draft) => ({ min: Number(draft.min), max: Number(draft.max), min_label: draft.min_label, max_label: draft.max_label }),
  },
  short_text: { Fields: () => null, read: () => ({}), payload: () => null },
};

function emptyDraft() {
  return { kind: "choice", label: "", optionsText: "", multiple: false, min: 1, max: 5, min_label: "", max_label: "", planned_minute: "", note: "" };
}

function draftFromPoll(poll) {
  return {
    ...emptyDraft(),
    kind: poll.kind, label: poll.label, multiple: poll.multiple, note: poll.note || "",
    planned_minute: poll.planned_minute ?? "",
    ...OPTION_EDITORS[poll.kind].read(poll),
  };
}

function pollPayload(draft) {
  return {
    kind: draft.kind, label: draft.label, note: draft.note, multiple: draft.multiple,
    planned_minute: draft.planned_minute === "" ? null : Number(draft.planned_minute),
    options: OPTION_EDITORS[draft.kind].payload(draft),
  };
}

// Formulaire de question : création (plan ou à la volée) et modification.
function PollEditor({ initial, submitLabel, onSubmit, onLaunch, onCancel }) {
  const id = useId();
  const [draft, setDraft] = useState(initial);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const OptionFields = OPTION_EDITORS[draft.kind].Fields;
  const set = (field) => (event) => {
    const value = event.target.type === "checkbox" ? event.target.checked : event.target.value;
    setDraft((current) => ({ ...current, [field]: value }));
  };

  const run = async (action) => {
    if (busy) return;
    setBusy(true);
    try {
      await action(pollPayload(draft));
      setError("");
      if (!onCancel) setDraft(emptyDraft());
    } catch (failure) {
      setError(failure.message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="poll-console__editor" onSubmit={(event) => { event.preventDefault(); run(onSubmit); }}>
      <div className="poll-console__row">
        <label htmlFor={`${id}-kind`}>Type</label>
        <select id={`${id}-kind`} value={draft.kind} onChange={set("kind")}>
          {Object.entries(FORMATS).map(([kind, format]) => <option key={kind} value={kind}>{format.label}</option>)}
        </select>
      </div>
      <div className="poll-console__row">
        <label htmlFor={`${id}-label`}>Question</label>
        <input id={`${id}-label`} type="text" maxLength={300} required value={draft.label} onChange={set("label")} />
      </div>
      <OptionFields id={id} draft={draft} set={set} />
      <div className="poll-console__row poll-console__row--inline">
        <label htmlFor={`${id}-minute`}>Minute prévue</label>
        <input id={`${id}-minute`} type="number" min={0} max={600} value={draft.planned_minute} onChange={set("planned_minute")} />
      </div>
      <div className="poll-console__row">
        <label htmlFor={`${id}-note`}>Aide-mémoire (vous seul)</label>
        <input id={`${id}-note`} type="text" maxLength={1000} value={draft.note} onChange={set("note")} />
      </div>
      {error ? <p className="poll-console__error" role="alert">{error}</p> : null}
      <div className="poll-console__buttons">
        <button type="submit" className="poll-console__button" disabled={busy}>{submitLabel}</button>
        {onLaunch ? (
          <button type="button" className="poll-console__button poll-console__button--primary" disabled={busy} onClick={() => run(onLaunch)}>
            Lancer maintenant
          </button>
        ) : null}
        {onCancel ? <button type="button" className="poll-console__button" onClick={onCancel}>Annuler</button> : null}
      </div>
    </form>
  );
}

// Détail nominatif : qui a répondu quoi, par option ou valeur (barres),
// ou chaque texte avec son nom (réponse courte).
function RespondentBars({ poll }) {
  const shares = percentages(poll.results);
  return (
    <ol className="poll-console__results" data-testid="poll-console-results">
      {formatOf(poll).resultLabels(poll).map((label, index) => (
        <li key={index} className="poll-console__result">
          <div className="poll-console__result-head">
            <span>{label}</span>
            <span className="poll-console__share">{shares[index]} % ({poll.results.counts[index]})</span>
          </div>
          <span className="poll-console__track" aria-hidden="true">
            <span className="poll-console__fill" style={{ width: `${shares[index]}%` }} />
          </span>
          {poll.respondents[index].length > 0 ? (
            <p className="poll-console__names">{poll.respondents[index].join(", ")}</p>
          ) : null}
        </li>
      ))}
    </ol>
  );
}

function RespondentTexts({ poll }) {
  return (
    <ul className="poll-console__texts" data-testid="poll-console-texts">
      {poll.respondents.map((answer, index) => (
        <li key={index}><strong>{answer.name}</strong> — {answer.text}</li>
      ))}
    </ul>
  );
}

const RESPONDENT_VIEWS = { choice: RespondentBars, scale: RespondentBars, short_text: RespondentTexts };

function PollRespondents({ poll }) {
  if (!poll.respondents) return <p className="poll-console__hint">Chargement des répondants…</p>;
  const View = RESPONDENT_VIEWS[poll.kind];
  return <View poll={poll} />;
}

function PollItem({ poll, detail, live, elapsedMs, presentCount, isFirst, isLast, onAction, onMove, onEdit, onToggle, expanded }) {
  const respondents = presentCount ? `${poll.responses_count} / ${presentCount} présents` : `${poll.responses_count} réponse${poll.responses_count > 1 ? "s" : ""}`;
  const average = poll.results?.average !== null && poll.results?.average !== undefined ? ` · moyenne ${poll.results.average}` : "";
  return (
    <li className="poll-console__item" data-poll-id={poll.id} data-state={poll.state} data-testid="poll-console-item">
      <div className="poll-console__item-head">
        <span className="poll-console__state" data-state={poll.state}>{STATE_LABELS[poll.state]}</span>
        <span className="poll-console__timing">{timingLabel(poll, elapsedMs)}</span>
        <span className="poll-console__kind">{formatOf(poll).label}{poll.multiple ? " multiple" : ""}</span>
      </div>
      <p className="poll-console__label">{poll.label}</p>
      {poll.note ? <p className="poll-console__note">{poll.note}</p> : null}
      {poll.state !== "planned" ? (
        <p className="poll-console__count" data-testid="poll-console-count">{respondents}{average}{poll.results_shown ? " · résultat affiché" : ""}</p>
      ) : null}
      <div className="poll-console__buttons">
        {poll.state === "planned" ? (
          <>
            <button type="button" className="poll-console__button poll-console__button--primary" disabled={!live}
                    title={live ? undefined : "Le direct n'est pas en cours"} onClick={() => onAction(poll, "open")}>Lancer</button>
            <button type="button" className="poll-console__button" onClick={() => onEdit(poll)}>Modifier</button>
            <button type="button" className="poll-console__button" onClick={() => onAction(poll, "delete")}>Supprimer</button>
            <button type="button" className="poll-console__button" disabled={isFirst} onClick={() => onMove(poll, -1)} aria-label={`Monter « ${poll.label} »`}>↑</button>
            <button type="button" className="poll-console__button" disabled={isLast} onClick={() => onMove(poll, 1)} aria-label={`Descendre « ${poll.label} »`}>↓</button>
          </>
        ) : null}
        {poll.state === "open" ? (
          <button type="button" className="poll-console__button poll-console__button--primary" onClick={() => onAction(poll, "close")}>Fermer</button>
        ) : null}
        {poll.state !== "planned" ? (
          <>
            <button type="button" className="poll-console__button" aria-pressed={poll.results_shown}
                    disabled={!poll.results_shown && !poll.results_showable}
                    title={poll.results_shown || poll.results_showable ? undefined : ERRORS.poll_open}
                    onClick={() => onAction(poll, poll.results_shown ? "hide_results" : "show_results")}>
              {poll.results_shown ? "Masquer le résultat" : "Montrer le résultat"}
            </button>
            {poll.state === "closed" ? (
              <button type="button" className="poll-console__button" aria-expanded={expanded} onClick={() => onToggle(poll)}>
                {expanded ? "Masquer le détail" : "Qui a répondu ?"}
              </button>
            ) : null}
          </>
        ) : null}
      </div>
      {expanded && poll.state !== "planned" ? <PollRespondents poll={detail || poll} /> : null}
    </li>
  );
}

export function PollConsole({ pollsUrl, presentCount = null }) {
  const [plan, setPlan] = useState(null);
  const [serverOffsetMs, setServerOffsetMs] = useState(0);
  const [details, setDetails] = useState({});
  const [expandedIds, setExpandedIds] = useState(() => new Set());
  const [editing, setEditing] = useState(null);
  const [error, setError] = useState("");
  const [syncError, setSyncError] = useState("");

  const refresh = useCallback(async () => {
    const payload = await request(pollsUrl);
    setPlan(payload);
    setServerOffsetMs(Date.parse(payload.now) - Date.now());
    return payload;
  }, [pollsUrl]);

  const refreshDetail = useCallback(async (pollId) => {
    const payload = await request(`${pollsUrl}/${pollId}`);
    setDetails((current) => ({ ...current, [pollId]: payload.poll }));
  }, [pollsUrl]);

  // Le sondage en cours est toujours détaillé : les répondants arrivent.
  const openPoll = plan?.polls.find((poll) => poll.state === "open");
  const watchedIds = [...new Set([...expandedIds, ...(openPoll ? [openPoll.id] : [])])];
  const watchedKey = watchedIds.join(",");

  useEffect(() => {
    let cancelled = false;
    let timer = null;
    let running = false;
    const tick = async () => {
      running = true;
      try {
        await refresh();
        await Promise.all(watchedKey ? watchedKey.split(",").map((id) => refreshDetail(id)) : []);
        if (!cancelled) setSyncError("");
      } catch (failure) {
        if (!cancelled) setSyncError(`Synchronisation interrompue : ${failure.message}`);
      } finally {
        running = false;
        if (!cancelled) timer = setTimeout(tick, document.hidden ? HIDDEN_REFRESH_INTERVAL_MS : REFRESH_INTERVAL_MS);
      }
    };
    // Changement de visibilité : la prochaine relecture passe au rythme
    // masqué, ou a lieu tout de suite au retour. Une relecture en cours
    // replanifie elle-même au bon rythme.
    const onVisibilityChange = () => {
      if (running) return;
      clearTimeout(timer);
      if (document.hidden) timer = setTimeout(tick, HIDDEN_REFRESH_INTERVAL_MS);
      else tick();
    };
    tick();
    document.addEventListener("visibilitychange", onVisibilityChange);
    return () => {
      cancelled = true;
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [refresh, refreshDetail, watchedKey]);

  const act = async (action) => {
    try {
      await action();
      setError("");
      await refresh();
    } catch (failure) {
      setError(failure.message);
    }
  };

  const onAction = (poll, action) => act(async () => {
    if (action === "delete") {
      if (!window.confirm(`Supprimer « ${poll.label} » du plan ?`)) return;
      await request(`${pollsUrl}/${poll.id}`, { method: "DELETE" });
      return;
    }
    const payload = await request(`${pollsUrl}/${poll.id}/${action}`, { method: "POST" });
    setDetails((current) => ({ ...current, [poll.id]: payload.poll }));
  });

  const onMove = (poll, direction) => act(async () => {
    const ids = plan.polls.map((item) => item.id);
    const from = ids.indexOf(poll.id);
    [ids[from], ids[from + direction]] = [ids[from + direction], ids[from]];
    await request(`${pollsUrl}/reorder`, { method: "PATCH", body: { ids } });
  });

  const onToggle = (poll) => setExpandedIds((current) => {
    const next = new Set(current);
    if (next.has(poll.id)) next.delete(poll.id); else next.add(poll.id);
    return next;
  });

  const create = (launch) => async (payload) => {
    await request(pollsUrl, { method: "POST", body: { poll: payload, open: launch } });
    await refresh();
  };

  const update = (poll) => async (payload) => {
    await request(`${pollsUrl}/${poll.id}`, { method: "PATCH", body: { poll: payload } });
    setEditing(null);
    await refresh();
  };

  const elapsedMs = useLiveClock(plan?.webinar.state === "live" ? plan.webinar.started_at : null, serverOffsetMs);
  if (!plan) {
    return (
      <section className="poll-console" aria-label="Sondages" data-testid="poll-console">
        <p className="poll-console__hint">{syncError || "Chargement des sondages…"}</p>
      </section>
    );
  }

  const live = plan.webinar.state === "live";
  return (
    <section className="poll-console" aria-label="Sondages" data-testid="poll-console">
      <header className="poll-console__header">
        <h2 className="poll-console__title">Sondages</h2>
        <span className="poll-console__clock" data-testid="poll-console-clock">
          {elapsedMs === null ? CLOCK_IDLE_LABELS[plan.webinar.state] ?? "" : `Direct ${formatClock(elapsedMs)}`}
        </span>
      </header>
      {syncError ? <p className="poll-console__error" role="alert">{syncError}</p> : null}
      {error ? <p className="poll-console__error" role="alert">{error}</p> : null}
      {plan.polls.length === 0 ? <p className="poll-console__hint">Aucun sondage prévu pour ce direct.</p> : (
        <ol className="poll-console__plan">
          {plan.polls.map((poll, index) => (
            editing === poll.id ? (
              <li key={poll.id} className="poll-console__item">
                <PollEditor initial={draftFromPoll(poll)} submitLabel="Enregistrer" onSubmit={update(poll)} onCancel={() => setEditing(null)} />
              </li>
            ) : (
              <PollItem key={poll.id} poll={poll} detail={details[poll.id]} live={live} elapsedMs={elapsedMs}
                        presentCount={presentCount} isFirst={index === 0} isLast={index === plan.polls.length - 1}
                        expanded={expandedIds.has(poll.id) || poll.state === "open"}
                        onAction={onAction} onMove={onMove} onEdit={(item) => setEditing(item.id)} onToggle={onToggle} />
            )
          ))}
        </ol>
      )}
      <details className="poll-console__new">
        <summary>Nouvelle question</summary>
        <PollEditor initial={emptyDraft()} submitLabel="Ajouter au plan" onSubmit={create(false)} onLaunch={live ? create(true) : null} />
      </details>
    </section>
  );
}
