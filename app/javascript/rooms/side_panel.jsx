// Panneau latéral de la salle — scène, intervenant et spectateur.
//
// Onglets « Discussion · Transcription » dans UNE colonne de la mise en
// page (room.css, bloc « Panneau latéral ») : jamais en surimpression, il
// prend sa place et réduit la zone vidéo ; sous 768 px, ou dans une fenêtre
// en hauteur jusqu'à 1024 px de large, il passe sous la vidéo. Discussion
// par défaut ; l'onglet Transcription n'existe que si le serveur l'active
// (data-transcript-enabled). Repliable en onglet vertical
// (étroit : une ligne d'en-tête) ; repli et onglet mémorisés par appareil,
// replié d'office sur petit écran sans préférence — la vidéo passe d'abord.
// Replié, ou sur l'onglet Transcription, un badge compte les messages non
// lus : ceux des autres, arrivés depuis l'entrée dans la salle.
//
// Les deux contenus restent MONTÉS quel que soit l'onglet ou le repli : les
// flux (useChat, useTranscriptions) n'accumulent que montés, et le badge a
// besoin du fil à jour panneau replié.

import { useCallback, useEffect, useState } from "react";
import { DiscussionPanel, useChat } from "./chat";
import { TranscriptFeed } from "./transcript_feed";
import { newestId, unreadCount } from "./chat_state.mjs";

const COLLAPSED_KEY = "undust-live:side-panel:collapsed";
const TAB_KEY = "undust-live:side-panel:tab";
// Repli d'office (sans préférence) : sous 768 px seulement. Entre 769 et
// 1024 px, une fenêtre en hauteur met le panneau SOUS la vidéo (room.css,
// bloc « Étroit ») mais le laisse ouvert : la vidéo a déjà toute la
// largeur, la discussion a la place de quelques messages.
const NARROW_QUERY = "(max-width: 768px)";
const TABS = { discussion: "Discussion", transcript: "Transcription" };

// localStorage peut lever (mode privé Safari, stockage désactivé) : la
// préférence est alors perdue au rechargement, le panneau reste utilisable.
function readPreference(key) {
  try {
    return window.localStorage ? window.localStorage.getItem(key) : null;
  } catch (_err) {
    return null;
  }
}

function writePreference(key, value) {
  try {
    if (window.localStorage) window.localStorage.setItem(key, value);
  } catch (_err) {
    // Préférence non mémorisée — sans effet sur l'usage.
  }
}

const isNarrow = () => !!window.matchMedia && window.matchMedia(NARROW_QUERY).matches;

function initiallyCollapsed() {
  const stored = readPreference(COLLAPSED_KEY);
  return stored === null ? isNarrow() : stored === "1";
}

function UnreadBadge({ count }) {
  if (count === 0) return null;
  const plural = count > 1 ? "s" : "";
  return (
    <span className="lk-side-panel__badge" data-testid="unread-badge" aria-label={`${count} message${plural} non lu${plural}`}>
      {count > 99 ? "99+" : count}
    </span>
  );
}

export function SidePanel({ messagesUrl, speakerToken, transcriptEnabled, organization }) {
  const chat = useChat({ messagesUrl, speakerToken });
  const [collapsed, setCollapsed] = useState(initiallyCollapsed);
  const [tab, setTab] = useState(() => (readPreference(TAB_KEY) === "transcript" ? "transcript" : "discussion"));
  const activeTab = transcriptEnabled ? tab : "discussion";
  const discussionVisible = !collapsed && activeTab === "discussion";

  // Dernier message vu : avance tant que la discussion est sous les yeux ;
  // l'historique trouvé à l'arrivée compte comme vu.
  const [lastSeenId, setLastSeenId] = useState(0);
  const newest = newestId(chat.messages);
  useEffect(() => {
    if (discussionVisible) setLastSeenId(newest);
  }, [discussionVisible, newest]);
  const seenId = Math.max(lastSeenId, chat.arrivalId ?? newest);
  const unread = discussionVisible ? 0 : unreadCount(chat.messages, seenId, chat.ownIds);

  const toggle = useCallback(() => {
    setCollapsed((previous) => {
      writePreference(COLLAPSED_KEY, previous ? "0" : "1");
      return !previous;
    });
  }, []);

  const select = useCallback((next) => {
    writePreference(TAB_KEY, next);
    setTab(next);
  }, []);

  const tabButton = (id) => (
    <button
      type="button"
      role="tab"
      id={`lk-side-panel-tab-${id}`}
      className="lk-side-panel__tab"
      aria-selected={activeTab === id}
      aria-controls={`lk-side-panel-${id}`}
      onClick={() => select(id)}
      data-testid={`side-panel-tab-${id}`}
    >
      {TABS[id]}
      {id === "discussion" ? <UnreadBadge count={unread} /> : null}
    </button>
  );

  return (
    <aside
      className={`lk-side-panel${collapsed ? " lk-side-panel--collapsed" : ""}`}
      data-testid="side-panel"
      aria-label={transcriptEnabled ? "Discussion et transcription" : "Discussion"}
    >
      <header className="lk-side-panel__header">
        {transcriptEnabled && !collapsed ? (
          <div className="lk-side-panel__tabs" role="tablist" aria-label="Contenu du panneau">
            {tabButton("discussion")}
            {tabButton("transcript")}
          </div>
        ) : (
          <h2 className="lk-side-panel__title">
            {TABS.discussion}
            <UnreadBadge count={unread} />
          </h2>
        )}
        {/* Ouvert : chevron vers le bord où le panneau se range (à droite,
            vers le bas une fois empilé — room.css). Le libellé reste le nom
            accessible ; il n'est masqué que VISUELLEMENT sous 22 rem
            d'en-tête (requête de conteneur, room.css) — donc toujours à
            côté de la vidéo, jamais sur un panneau empilé assez large.
            Replié : libellé seul, vertical. */}
        <button
          type="button"
          className="lk-side-panel__toggle"
          onClick={toggle}
          aria-expanded={!collapsed}
          title={collapsed ? "Afficher le panneau" : "Masquer le panneau"}
          data-testid="side-panel-toggle"
        >
          {collapsed ? null : (
            <svg className="lk-side-panel__toggle-icon" viewBox="0 0 16 16" aria-hidden="true">
              <path d="M6 3l5 5-5 5" />
            </svg>
          )}
          <span className="lk-side-panel__toggle-label">{collapsed ? "Afficher" : "Masquer"}</span>
        </button>
      </header>
      <section
        id="lk-side-panel-discussion"
        className="lk-side-panel__section"
        role={transcriptEnabled ? "tabpanel" : undefined}
        aria-labelledby={transcriptEnabled ? "lk-side-panel-tab-discussion" : undefined}
        hidden={!discussionVisible}
      >
        <DiscussionPanel chat={chat} visible={discussionVisible} organization={organization} />
      </section>
      {transcriptEnabled ? (
        <section
          id="lk-side-panel-transcript"
          className="lk-side-panel__section"
          role="tabpanel"
          aria-labelledby="lk-side-panel-tab-transcript"
          hidden={collapsed || activeTab !== "transcript"}
        >
          <TranscriptFeed visible={!collapsed && activeTab === "transcript"} />
        </section>
      ) : null}
    </aside>
  );
}
