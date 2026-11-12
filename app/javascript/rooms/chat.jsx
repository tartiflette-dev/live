// Discussion du direct (contrat serveur : MessagesController, MessageModerationsController).
//
// Un seul fil pour tous les participants : spectateur inscrit, intervenant,
// animation. Le client POSTe à Rails et n'émet JAMAIS sur le data channel.
// Il reçoit :
//   - les pages HTTP de Rails : au montage tout l'historique (les messages
//     arrivés avant l'entrée de la personne), puis toutes les 10 s. Elles
//     seules font avancer le curseur (updated_at, id) ;
//   - les paquets temps réel diffusés par le serveur (MessageBroadcast),
//     acceptés seulement sans participant émetteur (chat_state.mjs).
// Le texte est rendu en nœuds React, jamais en HTML. Fail-loud : chaque
// panne est un message visible dans le panneau ; un envoi refusé garde le
// brouillon. Aucun console.*.
//
// `useChat` est appelé par SidePanel, AU-DESSUS du repli : le fil reste
// synchronisé panneau replié, ce qui alimente le badge de non-lus.
// `arrivalId` (dernier message de l'historique trouvé à l'arrivée) : ce qui
// précède l'entrée de la personne n'est pas « non lu ».
//
// Hors salle LiveKit (régie) : pas de data channel, le fil
// avance par les seules pages HTTP, relues plus souvent.

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { useMaybeRoomContext } from "@livekit/components-react";
import { RoomEvent } from "livekit-client";
import { csrfToken } from "./state_button";
import { BODY_LIMIT, INITIAL_CURSOR, PAGE_SIZE, mergeMessages, nextCursor, readServerMessage, validMessage } from "./chat_state.mjs";
import { clockTime } from "./clock_time.mjs";
import { NewTabHint } from "./new_tab_hint";

const POLL_INTERVAL_MS = 10000;
const POLL_WITHOUT_REALTIME_MS = 3000;
const ROLE_LABELS = { host: "Animateur", speaker: "Intervenant" };
const REFUSALS = {
  403: "Vous ne pouvez pas écrire dans cette discussion.",
  410: "Le direct est terminé : la discussion est close.",
  422: "Message vide ou trop long (1 000 caractères au plus).",
  429: "Trop de messages d'affilée : patientez quelques secondes.",
};

function requestHeaders(speakerToken) {
  const headers = { Accept: "application/json" };
  if (speakerToken) headers["X-Speaker-Token"] = speakerToken;
  return headers;
}

async function refusalMessage(response) {
  const body = await response.json().catch(() => null);
  if (body && body.error === "invalid_authenticity_token") return "Session expirée : rechargez la page.";
  return REFUSALS[response.status] || `Action non confirmée (${response.status || "réseau"}).`;
}

async function fetchPage(url, cursor, speakerToken, signal) {
  const query = cursor.updated_since === null ? "" : `?${new URLSearchParams(cursor)}`;
  const response = await fetch(`${url}${query}`, {
    credentials: "same-origin", cache: "no-store", redirect: "manual", signal,
    headers: requestHeaders(speakerToken),
  });
  if (!response.ok) throw new Error(`Discussion indisponible (${response.status || "réseau"}).`);
  const page = (await response.json())?.messages;
  if (!Array.isArray(page) || page.length > PAGE_SIZE || !page.every(validMessage)) {
    throw new Error("Réponse de discussion invalide.");
  }
  return page;
}

export function useChat({ messagesUrl, speakerToken }) {
  const room = useMaybeRoomContext();
  const pollInterval = room ? POLL_INTERVAL_MS : POLL_WITHOUT_REALTIME_MS;
  const [messages, setMessages] = useState([]);
  const [ownIds, setOwnIds] = useState(() => new Set());
  const [syncError, setSyncError] = useState("");
  const [arrivalId, setArrivalId] = useState(null);
  const upsert = useCallback((incoming) => setMessages((previous) => mergeMessages(previous, incoming)), []);

  useEffect(() => {
    if (!room) return undefined;
    const receive = (payload, participant) => {
      const message = readServerMessage(payload, participant);
      if (message) upsert([message]);
    };
    room.on(RoomEvent.DataReceived, receive);
    return () => {
      room.off(RoomEvent.DataReceived, receive);
    };
  }, [room, upsert]);

  // Chaque cycle vide toutes les pages disponibles avant d'attendre.
  useEffect(() => {
    const aborter = new AbortController();
    let timer = null;
    let cursor = INITIAL_CURSOR;
    let newestSeen = 0;
    const poll = async () => {
      try {
        let page;
        do {
          page = await fetchPage(messagesUrl, cursor, speakerToken, aborter.signal);
          upsert(page);
          cursor = nextCursor(cursor, page);
          newestSeen = Math.max(newestSeen, ...page.map((message) => message.id));
        } while (page.length === PAGE_SIZE && !aborter.signal.aborted);
        setArrivalId((current) => current ?? newestSeen);
        setSyncError("");
      } catch (error) {
        if (!aborter.signal.aborted) setSyncError(error.message || "Discussion momentanément indisponible.");
      } finally {
        if (!aborter.signal.aborted) timer = setTimeout(poll, pollInterval);
      }
    };
    poll();
    return () => {
      aborter.abort();
      clearTimeout(timer);
    };
  }, [messagesUrl, speakerToken, upsert, pollInterval]);

  const post = useCallback(async (url, body) => {
    let response;
    try {
      response = await fetch(url, {
        method: "POST", credentials: "same-origin", cache: "no-store", redirect: "manual",
        headers: { ...requestHeaders(speakerToken), "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
        body: JSON.stringify(body),
      });
    } catch (_networkError) {
      throw new Error("Réseau indisponible.");
    }
    if (!response.ok) throw new Error(await refusalMessage(response));
    const message = await response.json().catch(() => null);
    if (!validMessage(message)) throw new Error("Réponse invalide : vérifiez le fil avant de réessayer.");
    upsert([message]);
    return message;
  }, [speakerToken, upsert]);

  const send = useCallback(async (body) => {
    const message = await post(messagesUrl, { body });
    setOwnIds((previous) => new Set(previous).add(message.id));
    return message;
  }, [messagesUrl, post]);

  return { messages, ownIds, arrivalId, syncError, send, post };
}

// En-tête d'un message ; les actions d'animation (children) se rangent
// au bout de la même ligne, pour ne pas allonger le fil.
function MessageMeta({ message, children }) {
  const role = ROLE_LABELS[message.author_role];
  return (
    <div className="lk-discussion__meta">
      <span className="lk-discussion__author">{message.name}</span>
      {role ? <span className="lk-discussion__role">{role}</span> : null}
      {message.kind === "question" ? (
        <span className="lk-discussion__tag">{message.answered_at ? "Question répondue" : "Question"}</span>
      ) : null}
      <time className="lk-discussion__time" dateTime={message.created_at}>{clockTime(message.created_at)}</time>
      {children ? <span className="lk-discussion__actions">{children}</span> : null}
    </div>
  );
}

// Contenu de l'onglet Discussion (salle) et du bloc Discussion de la régie.
// `moderationUrl` n'est posé que par la régie (la salle de
// l'animation est celle des participants) : il ajoute, dans le fil même,
// « Répondu » aux questions adressées à @animateur et « Épingler » ; les
// endpoints revérifient le rôle à chaque appel. Les questions ont leur zone
// à part dans la régie (QaConsole) : pas de second panneau ici. `onEnqueue`
// (régie seulement) ajoute « Ajouter à la file » à chaque message du fil : il
// rend l'avis à afficher, ou lève ; la file reste ouverte après la fin.
// `closed` (régie, direct terminé) : plus de saisie ni de modération du fil
// (le serveur répond 410).
export function DiscussionPanel({ chat, moderationUrl, onEnqueue, visible, closed = false, organization }) {
  const [draft, setDraft] = useState("");
  const [sending, setSending] = useState(false);
  const [moderating, setModerating] = useState(false);
  const [notice, setNotice] = useState("");
  const listRef = useRef(null);
  const atBottomRef = useRef(true);
  const canModerate = Boolean(moderationUrl) && !closed;
  const pinned = chat.messages.filter((message) => message.pinned_at);
  const unanswered = (message) => message.kind === "question" && !message.answered_at;

  // Suit le dernier message SEULEMENT si la personne lit déjà le bas du fil.
  useLayoutEffect(() => {
    const list = listRef.current;
    if (visible && list && atBottomRef.current) list.scrollTop = list.scrollHeight;
  }, [chat.messages, visible]);

  const handleScroll = useCallback(() => {
    const list = listRef.current;
    if (list) atBottomRef.current = list.scrollHeight - list.scrollTop - list.clientHeight < 24;
  }, []);

  const submit = async (event) => {
    event.preventDefault();
    const submitted = draft.trim();
    if (sending || !submitted) return;
    setSending(true);
    try {
      const message = await chat.send(submitted);
      atBottomRef.current = true;
      setDraft((current) => (current === draft ? "" : current));
      setNotice(message.broadcast === "unavailable"
        ? "Message enregistré ; diffusion en direct indisponible, les autres le verront sous quelques secondes."
        : "");
    } catch (error) {
      setNotice(`${error.message} Votre texte est conservé.`);
    } finally {
      setSending(false);
    }
  };

  // Entrée envoie, Maj+Entrée va à la ligne (hors composition IME).
  const handleKeyDown = (event) => {
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) submit(event);
  };

  const moderationButton = (message, action, label) => (
    <button type="button" className="lk-discussion__action" disabled={moderating} onClick={() => moderate(message, action)}>
      {label}
    </button>
  );

  // Une action d'animation à la fois, son avis ou son refus affiché.
  const runAction = async (perform) => {
    if (moderating) return;
    setModerating(true);
    try {
      setNotice((await perform()) || "");
    } catch (error) {
      setNotice(error.message);
    } finally {
      setModerating(false);
    }
  };
  const moderate = (message, action) => runAction(async () => {
    await chat.post(`${moderationUrl}/${message.id}/${action}`, {});
  });
  const enqueueButton = (message) => (
    <button type="button" className="lk-discussion__action" disabled={moderating}
      onClick={() => runAction(() => onEnqueue(message))} data-testid="discussion-enqueue">
      Ajouter à la file
    </button>
  );

  return (
    <div className="lk-discussion" data-testid="discussion">
      {chat.syncError ? <p className="lk-discussion__alert" role="alert">{chat.syncError}</p> : null}
      {pinned.length > 0 ? (
        <section className="lk-discussion__pinned" aria-label="Messages épinglés" data-testid="pinned-messages">
          {pinned.map((message) => (
            <article className="lk-discussion__pin" key={message.id}>
              <MessageMeta message={message}>
                {canModerate ? moderationButton(message, "unpin", "Désépingler") : null}
              </MessageMeta>
              <p className="lk-discussion__body">{message.body}</p>
            </article>
          ))}
        </section>
      ) : null}
      <ol className="lk-discussion__messages" ref={listRef} onScroll={handleScroll} aria-label="Messages"
          aria-live="polite" data-testid="discussion-messages">
        {chat.messages.length === 0 ? (
          <li className="lk-discussion__empty">Aucun message pour l'instant.</li>
        ) : chat.messages.map((message) => (
          <li className="lk-discussion__message" key={message.id} data-message-id={message.id} data-kind={message.kind}>
            <MessageMeta message={message}>
              {canModerate && unanswered(message) ? moderationButton(message, "answer", "Répondu") : null}
              {onEnqueue ? enqueueButton(message) : null}
              {canModerate && !message.pinned_at ? moderationButton(message, "pin", "Épingler") : null}
            </MessageMeta>
            <p className="lk-discussion__body">{message.body}</p>
          </li>
        ))}
      </ol>
      {notice ? <p className="lk-discussion__notice" role="status">{notice}</p> : null}
      {closed ? (
        <p className="lk-discussion__notice" data-testid="discussion-closed">Le direct est terminé : la discussion est close.</p>
      ) : (
        <>
          <form className="lk-discussion__form" onSubmit={submit}>
            <label className="lk-discussion__label" htmlFor="lk-discussion-draft">Votre message</label>
            <textarea
              id="lk-discussion-draft"
              className="lk-discussion__input"
              rows={2}
              maxLength={BODY_LIMIT}
              value={draft}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Visible par tous · @animateur pour une question"
            />
            <button type="submit" className="lk-discussion__send" disabled={sending || !draft.trim()}>Envoyer</button>
          </form>
          {/* File Q&R (politique v1.8) : l'analyse des messages est
              annoncée là où on écrit. */}
          <p className="lk-discussion__privacy" data-testid="discussion-privacy">
            Les messages peuvent être analysés par un modèle hébergé chez {organization} pour regrouper les questions
            (<a href="/confidentialite" target="_blank" rel="noopener">confidentialité<NewTabHint /></a>).
          </p>
        </>
      )}
    </div>
  );
}
