// Choix « J'observe » / « Je participe » avant d'entrer dans la salle.
//
// Contrat DOM (webinars/room.html.erb) : `[data-role=participation-choice]`
// n'est rendu que pour un inscrit qui n'a jamais choisi ; son formulaire
// porte l'URL du choix (`data-participation-url`) et le message d'échec
// dans la tonalité de l'émission (`data-error-message`).
//
// Le choix part en JSON (PATCH, X-CSRF-Token) AVANT le jeton LiveKit : le
// serveur l'enregistre et la main le suit (« Je participe » la lève,
// HandRaiseControl#follow_participation). Enregistré, la carte disparaît et
// `enter` monte la salle. Refusé ou réseau coupé : message visible (il
// propose de recharger la page), la carte reste, un nouvel envoi réessaie
// (jamais d'entrée silencieuse sur un choix perdu). Le premier choix gagne
// côté serveur : un second onglet entre avec le choix déjà gardé, la main
// levée ou baissée dans la salle sert ensuite à changer d'avis.

import { csrfToken } from "./state_button";

async function saveChoice(url, participation) {
  const res = await fetch(url, {
    method: "PATCH",
    credentials: "same-origin",
    redirect: "manual",
    headers: {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "X-CSRF-Token": csrfToken(),
    },
    body: JSON.stringify({ participation }),
  });
  if (!res.ok) throw new Error(`participation ${res.status}`);
}

// @param {HTMLElement} section `[data-role=participation-choice]`
// @param {() => void} enter monte la salle, une fois le choix enregistré
export function awaitParticipationChoice(section, enter) {
  const form = section.querySelector("form");
  const error = section.querySelector("[data-role=participation-error]");
  const submit = form.querySelector("button[type=submit]");

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const checked = form.querySelector("input[name=participation]:checked");
    if (!checked || submit.getAttribute("aria-busy") === "true") return;

    // Charte : l'envoi en cours se dit par aria-busy, jamais par disabled.
    submit.setAttribute("aria-busy", "true");
    error.hidden = true;
    try {
      await saveChoice(form.dataset.participationUrl, checked.value);
    } catch (_) {
      error.textContent = form.dataset.errorMessage;
      error.hidden = false;
      submit.removeAttribute("aria-busy");
      return;
    }
    section.remove();
    enter();
  });
}
