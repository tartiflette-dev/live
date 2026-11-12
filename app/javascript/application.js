// Entry point for the build script in your package.json
//
// Bundle unique (Rails omakase, INTRA-APP) :
//   • mountRoom     → monte le composant salle sur #livekit-room quand présent
//                     (stage/viewer/join en état live) ;
//   • mountCountdown → active [data-countdown] sur la page avant-direct ;
//   • mountLiveStateControl → « Reprendre le direct » sur la scène d'un
//                     direct terminé ([data-live-state-control]) ;
//   • mountCopyLinks → boutons « Copier le lien » de la page animateur
//                     ([data-copy-link]) ;
//   • mountConfirmations → confirmation des formulaires [data-confirm]
//                     (actions destructrices de la page animateur) ;
//   • mountRegie    → régie du direct, onglet animateur sans vidéo (#regie),
//                     qui monte aussi les consoles Sondages et Questions ;
//   • mountReplayPlayer → lecteur de replay ([data-replay-player]) :
//                     battements de visionnage, sous-titres ;
//   • mountReplayPolls / mountReplayQuestions → couches interactives du
//                     replay publié ([data-replay-polls],
//                     form[data-replay-question]) : sondages du direct,
//                     question ancrée à l'instant de la vidéo ;
//   • mountReplayNavigation → chapitres du replay et instant de départ
//                     ([data-replay-navigation], ?instant= lu par le serveur).
// Chaque fonction est un no-op si son marqueur DOM est absent — les pages
// qui ne portent qu'un des marqueurs (catalogue, avant-direct, salle)
// consomment le même bundle sans effet croisé.

import { mountRoom } from "./rooms/room.jsx";
import { mountCountdown } from "./countdown.js";
import { mountLiveStateControl } from "./rooms/live_state_control.jsx";
import { mountCopyLinks } from "./copy_link.js";
import { mountConfirmations } from "./confirm_action.js";
import { mountRegie } from "./rooms/regie.jsx";
import { mountReplayPlayer } from "./replay_player.js";
import { mountReplayPolls } from "./replay_polls.js";
import { mountReplayQuestions } from "./replay_questions.js";
import { mountReplayNavigation } from "./replay_navigation.js";

const boot = () => {
  mountRoom();
  mountCountdown();
  mountLiveStateControl();
  mountCopyLinks();
  mountConfirmations();
  mountRegie();
  mountReplayPlayer();
  mountReplayPolls();
  mountReplayQuestions();
  mountReplayNavigation();
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
