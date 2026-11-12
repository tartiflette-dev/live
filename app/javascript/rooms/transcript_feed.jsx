// Panneau Transcript dans la salle (scène, intervenant,
// spectateur). Flux unique côté client : hook `useTranscriptions` de
// @livekit/components-react 2.9 — qui agrège les text streams du topic
// `lk.transcription` (voir components-core setupTextStream). Chaque
// segment porte des attributs posés par l'agent transcriber (Python
// LiveKit Agents) :
//
//   lk.segment_id            = UUID stable (idempotence + dédoublonnage
//                              client ; le hook agrège les updates
//                              interim → final sur le même id)
//   lk.transcription_final   = "true" quand le segment est final
//   lk.participant_identity  = identité du participant TRANSCRIT (le
//                              publisher du stream est l'AGENT, pas le
//                              speaker — on ne peut pas se fier à
//                              `participantInfo.identity` ici)
//   lk.participant_name      = nom affiché résolu côté agent (fallback
//                              `localParticipant.name` du speaker)
//
// Aucun de ces attributs ne dit QUAND la phrase a été prononcée, et
// `streamInfo.timestamp` est l'heure d'ENVOI du segment par le
// transcripteur : un segment émis en retard porte une heure d'envoi
// récente. Le panneau affiche donc dans l'ordre d'arrivée, et c'est au
// transcripteur, seul à connaître l'heure de parole, d'écarter un segment
// trop vieux.
//
// On affiche les segments FINAUX uniquement (évite les flashs
// d'intérimaires sur Whisper non-streaming), débarrassés du bruit Whisper
// (phrases fantômes, hésitations : transcript_filter.js) et des doublons
// (même locuteur, même texte, à quelques secondes d'écart) — affichage
// seul, l'archive reste intacte ; auto-scroll vers le bas. Le fil est
// l'onglet « Transcription » du panneau latéral (side_panel.jsx), qui le
// garde monté même masqué. CSS: body.room .lk-transcript__* (room.css,
// zéro hex).

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef } from "react";
import { useParticipants, useTranscriptions } from "@livekit/components-react";
import { displayableTranscript, normalize } from "./transcript_filter";

// Un même segment peut arriver deux fois (par exemple deux pipelines STT
// sur la même piste) : même locuteur, même texte, heures d'envoi à moins de
// cette fenêtre du dernier affiché. Au-delà, c'est une vraie répétition.
// Perte acceptée, l'affichage seul étant concerné : un « Oui. » redit dans
// les 10 s n'apparaît qu'une fois.
const DUPLICATE_WINDOW_MS = 10000;

// Jamais l'identité technique à l'écran (elle porte l'identifiant OIDC de
// l'animateur ou un id interne) : libellé neutre si aucun nom n'est connu.
function neutralLabel(identity) {
  if (identity.startsWith("host-")) return "Animateur";
  if (identity.startsWith("speaker-")) return "Intervenant";
  if (identity.startsWith("viewer-")) return "Participant";
  return "Participant";
}

// `visible` : l'onglet est affiché (panneau déplié, onglet actif).
export function TranscriptFeed({ visible }) {
  const transcriptions = useTranscriptions();
  const participants = useParticipants();

  // Jointure identité → nom affiché. L'agent passe `lk.participant_name`
  // en attribut mais ce champ reflète l'instant d'émission ; si le
  // participant renomme en cours de direct (NameSync), on préfère son
  // nom live côté client.
  const nameByIdentity = useMemo(() => {
    const map = new Map();
    for (const p of participants) {
      if (p.identity) map.set(p.identity, p.name || neutralLabel(p.identity));
    }
    return map;
  }, [participants]);

  // On ne garde que les segments FINAUX. Un segment interim arrive avec
  // le même `lk.segment_id` mais `lk.transcription_final = "false"` —
  // setupTextStream fait l'agrégation ; nous, on filtre à l'affichage.
  // Le tableau du hook est dans l'ordre d'arrivée (un segment nouveau
  // s'ajoute à la fin, une mise à jour garde sa place) : on le conserve.
  const items = useMemo(() => {
    const result = [];
    const lastShownAt = new Map();
    for (const entry of transcriptions) {
      const attrs = entry.streamInfo?.attributes || {};
      if (attrs["lk.transcription_final"] !== "true") continue;
      const text = displayableTranscript(entry.text || "");
      if (text === null) continue;
      const identity = attrs["lk.participant_identity"]
        || entry.participantInfo?.identity
        || "participant";
      const sentAt = entry.streamInfo?.timestamp || 0;
      const duplicateKey = `${identity}\n${normalize(text)}`;
      const previousSentAt = lastShownAt.get(duplicateKey);
      if (previousSentAt !== undefined && Math.abs(sentAt - previousSentAt) <= DUPLICATE_WINDOW_MS) continue;
      // Heure d'envoi inconnue : on affiche sans en faire une référence,
      // sinon toute répétition serait masquée jusqu'à la fin du direct.
      if (sentAt) lastShownAt.set(duplicateKey, sentAt);
      const displayed = nameByIdentity.get(identity)
        || attrs["lk.participant_name"]
        || neutralLabel(identity);
      result.push({
        id: attrs["lk.segment_id"] || entry.streamInfo?.id || `${identity}:${sentAt}`,
        displayed,
        text,
      });
    }
    return result;
  }, [transcriptions, nameByIdentity]);

  const scrollRef = useRef(null);
  const atBottomRef = useRef(true);

  const handleScroll = useCallback(() => {
    const el = scrollRef.current;
    if (!el) return;
    const distance = el.scrollHeight - el.scrollTop - el.clientHeight;
    atBottomRef.current = distance < 16;
  }, []);

  // Auto-scroll : SEULEMENT si l'utilisateur est déjà au bas (évite de
  // le re-précipiter en bas pendant qu'il lit du passé).
  useLayoutEffect(() => {
    if (!visible) return;
    const el = scrollRef.current;
    if (!el) return;
    if (atBottomRef.current) {
      el.scrollTop = el.scrollHeight;
    }
  }, [items, visible]);

  // Onglet (ré)affiché : repartir en bas, l'utilisateur vient de demander
  // à voir « le dernier état ».
  useEffect(() => {
    if (!visible) return;
    const el = scrollRef.current;
    if (!el) return;
    el.scrollTop = el.scrollHeight;
    atBottomRef.current = true;
  }, [visible]);

  return (
    <ol
      className="lk-transcript__feed"
      ref={scrollRef}
      onScroll={handleScroll}
      aria-live="polite"
      aria-label="Transcription en direct"
      data-testid="transcript-feed"
    >
      {items.length === 0 ? (
        <li className="lk-transcript__waiting">
          En attente d'une prise de parole.
        </li>
      ) : items.map((item) => (
        <li className="lk-transcript__entry" key={item.id}>
          <span className="lk-transcript__speaker">{item.displayed}</span>
          <span className="lk-transcript__text">{item.text}</span>
        </li>
      ))}
    </ol>
  );
}
