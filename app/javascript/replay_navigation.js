// Navigation dans le replay (replays/_navigation) — contrat DOM :
//   • `[data-replay-navigation]` porte data-duration (secondes de la vidéo)
//     et, si un lien de recherche l'a demandé, data-start (instant de
//     départ, secondes) ;
//   • la vidéo est celle de `[data-replay-player]` sur la même page ;
//   • chapitres : boutons `[data-seek]` (instant, secondes) dans des
//     `[data-chapter-offset]`, et un conteneur `[data-replay-markers]` où le
//     script place un repère cliquable par chapitre (position en % de la
//     durée, posée par le CSSOM : aucun style en ligne dans le HTML).
//
// Départ : la vidéo est placée à data-start dès que ses métadonnées sont
// là, sans lancer la lecture. Clic sur un chapitre ou un repère : la vidéo
// saute à son instant et lit. Le chapitre en cours porte aria-current.
// Les sauts passent par `currentTime` : le lecteur (replay_player.js) en
// compte les battements comme ceux de ses propres commandes.
//
// No-op sans `[data-replay-navigation]` ou sans vidéo.

const whenSeekable = (video, action) => {
  if (video.readyState >= 1) {
    action();
  } else {
    video.addEventListener("loadedmetadata", action, { once: true });
  }
};

const seekAndPlay = (video, seconds) => {
  whenSeekable(video, () => {
    video.currentTime = seconds;
    const playing = video.play();
    if (playing && playing.catch) playing.catch(() => {});
  });
};

const drawMarkers = (nav, video, duration) => {
  const markers = nav.querySelector("[data-replay-markers]");
  if (!markers || !(duration > 0)) return;

  nav.querySelectorAll("[data-chapter-offset]").forEach((chapter) => {
    const offset = Number(chapter.dataset.chapterOffset);
    const title = chapter.querySelector(".replay-chapitre-titre")?.textContent || "";
    const marker = document.createElement("button");
    marker.type = "button";
    marker.className = "replay-repere";
    marker.setAttribute("aria-label", `Chapitre : ${title}`);
    marker.title = title;
    marker.style.left = `${Math.min(100, (offset / duration) * 100)}%`;
    marker.addEventListener("click", () => seekAndPlay(video, offset));
    markers.appendChild(marker);
  });
  markers.hidden = false;
};

const trackCurrentChapter = (nav, video) => {
  const chapters = Array.from(nav.querySelectorAll("[data-chapter-offset]"));
  if (chapters.length === 0) return;

  let current = null;
  const render = () => {
    const position = video.currentTime;
    const active = chapters.filter((chapter) => Number(chapter.dataset.chapterOffset) <= position + 0.5).pop() || null;
    if (active === current) return;
    if (current) current.removeAttribute("aria-current");
    if (active) active.setAttribute("aria-current", "true");
    current = active;
  };
  video.addEventListener("timeupdate", render);
  video.addEventListener("seeked", render);
  render();
};

export const mountReplayNavigation = () => {
  document.querySelectorAll("[data-replay-navigation]").forEach((nav) => {
    const video = document.querySelector("[data-replay-player] video");
    if (!video) return;

    const start = Number(nav.dataset.start);
    if (nav.dataset.start && Number.isFinite(start)) {
      whenSeekable(video, () => {
        video.currentTime = start;
      });
    }
    nav.querySelectorAll("[data-seek]").forEach((button) => {
      button.addEventListener("click", () => seekAndPlay(video, Number(button.dataset.seek)));
    });
    drawMarkers(nav, video, Number(nav.dataset.duration));
    trackCurrentChapter(nav, video);
  });
};
