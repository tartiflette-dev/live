// Question posée depuis le lecteur de replay (replays/_interactions) —
// contrat DOM :
//   • `form[data-replay-question]` porte data-questions-url (POST JSON
//     { label, at }) et vit dans `[data-replay-player]`, à côté de la
//     `<video>` ;
//   • il contient `[data-replay-question-text]` (le texte),
//     `[data-replay-question-instant]` (l'instant affiché) et
//     `[data-replay-question-status]` (issue de l'envoi, région live).
//
// La question est ancrée à l'instant où la personne commence à l'écrire
// (premier focus ou première frappe depuis le dernier envoi) : la vidéo peut
// continuer pendant qu'elle tape, l'instant reste celui du passage qui l'a
// fait réagir. Sans texte en cours (champ quitté vide, question envoyée),
// l'instant affiché suit de nouveau la lecture.
// Fail-loud : chaque refus est écrit sous le formulaire.
//
// No-op sans `form[data-replay-question]`.

import { videoTimecode } from "./rooms/video_timecode.mjs";

const REFUSALS = {
  404: "Ce replay n'est plus disponible : question non envoyée.",
  422: "Question vide ou trop longue.",
  429: "Trop de questions d'affilée : réessaie dans quelques minutes.",
};

const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content || "";

export const mountReplayQuestions = () => {
  document.querySelectorAll("form[data-replay-question]").forEach((form) => {
    const video = form.closest("[data-replay-player]")?.querySelector("video");
    const text = form.querySelector("[data-replay-question-text]");
    const instant = form.querySelector("[data-replay-question-instant]");
    const status = form.querySelector("[data-replay-question-status]");
    const submit = form.querySelector("button[type=submit]");
    if (!video || !text || !instant || !status || !submit) return;

    let anchor = null;
    const position = () => (anchor === null ? video.currentTime : anchor);
    const showInstant = () => {
      instant.textContent = videoTimecode(position());
    };
    const anchorNow = () => {
      if (anchor === null) anchor = video.currentTime;
      showInstant();
    };

    video.addEventListener("timeupdate", showInstant);
    video.addEventListener("seeked", showInstant);
    text.addEventListener("focus", anchorNow);
    text.addEventListener("input", anchorNow);
    text.addEventListener("blur", () => {
      if (text.value.trim()) return;
      anchor = null;
      showInstant();
    });

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const label = text.value.trim();
      if (!label) {
        status.textContent = REFUSALS[422];
        return;
      }
      const at = position();
      submit.disabled = true;
      status.textContent = "";
      try {
        const response = await fetch(form.dataset.questionsUrl, {
          method: "POST", credentials: "same-origin", cache: "no-store", redirect: "manual",
          headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
          body: JSON.stringify({ label, at }),
        });
        if (!response.ok) {
          const payload = await response.json().catch(() => null);
          if (payload?.error === "invalid_authenticity_token") throw new Error("Session expirée : recharge la page.");
          throw new Error(REFUSALS[response.status] || `Question non envoyée (${response.status || "réseau"}).`);
        }
        text.value = "";
        anchor = null;
        showInstant();
        status.textContent = `Question envoyée aux animateurs (à ${videoTimecode(at)} de la vidéo).`;
      } catch (failure) {
        status.textContent = failure instanceof TypeError ? "Réseau indisponible : question non envoyée." : failure.message;
      } finally {
        submit.disabled = false;
      }
    });

    form.hidden = false;
    showInstant();
  });
};
