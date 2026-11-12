// Sondages du direct dans le lecteur de replay (replays/_interactions) —
// contrat DOM :
//   • `[data-replay-polls]` porte data-polls-url (GET la liste, POST
//     `<url>/<id>/reponses`) et vit dans `[data-replay-player]`, à côté de
//     la `<video>`.
//
// Chaque sondage (ReplayPollsController, ReplayPoll) a son créneau
// `[start, end[` en secondes de la vidéo : la carte paraît quand la lecture
// y entre (lecture, saut, pause), disparaît quand elle en sort — sauf le
// sondage dont la personne s'est saisie (focus, choix, texte, réponse
// envoyée) : il reste tant qu'aucun autre sondage n'arrive et qu'elle ne
// l'a pas masqué, la vidéo pouvant continuer. Jamais incrustée dans la
// vidéo, jamais modale, le focus n'est jamais volé : l'arrivée est annoncée
// par la région live du conteneur (aria-live). « Masquer » la retire
// jusqu'au sondage suivant.
//
// Avant de répondre : la question et le formulaire, avec la mention que la
// réponse est nominative. Après (au direct ou dans le replay) : la réponse
// et le résultat direct + replay réunis, avec la part de chacun. Une
// réponse courte ne montre que le nombre de réponses. Fail-loud : chaque
// refus est un message visible dans la carte ; un refus « déjà répondu au
// direct » relit la liste, la carte montre alors cette réponse.
//
// No-op sans `[data-replay-polls]`.

const REFUSALS = {
  404: "Ce sondage n'est plus disponible.",
  409: "Tu as déjà répondu à ce sondage pendant le direct.",
  422: "Réponse incomplète ou trop longue.",
  429: "Trop d'envois d'affilée : patiente une minute.",
};
const TEXT_LIMIT = 200;

const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content || "";

const element = (tag, attributes = {}, text = null) => {
  const node = document.createElement(tag);
  Object.entries(attributes).forEach(([name, value]) => node.setAttribute(name, value));
  if (text !== null) node.textContent = text;
  return node;
};

const plural = (count, word) => `${count} ${word}${count > 1 ? "s" : ""}`;

const scaleValues = (options) => {
  const values = [];
  for (let value = options.min; value <= options.max; value += 1) values.push(value);
  return values;
};

// Libellés des barres de résultat, dans l'ordre de `results.counts`.
const resultLabels = (poll) => {
  if (poll.kind === "choice") return poll.options;
  const values = scaleValues(poll.options);
  return values.map((value, index) => {
    if (index === 0 && poll.options.min_label) return `${value} — ${poll.options.min_label}`;
    if (index === values.length - 1 && poll.options.max_label) return `${value} — ${poll.options.max_label}`;
    return String(value);
  });
};

const answerText = (poll, value) => {
  if (poll.kind === "choice") return value.map((index) => poll.options[index]).join(", ");
  return String(value);
};

const shareLine = (results) =>
  `${plural(results.respondents, "réponse")} : ${results.live} pendant le direct, ${results.replay} dans le replay.`;

const renderResults = (poll) => {
  const results = poll.results;
  const block = element("div", { class: "replay-sondage__resultats", "data-replay-poll-results": "" });
  if (poll.kind !== "short_text") {
    const list = element("ol", { class: "replay-sondage__barres" });
    resultLabels(poll).forEach((label, index) => {
      const count = results.counts[index] || 0;
      const share = results.respondents > 0 ? Math.round((count * 100) / results.respondents) : 0;
      const item = element("li", { class: "replay-sondage__barre" });
      item.append(element("span", {}, `${label} : ${share} % (${count})`));
      const track = element("span", { class: "replay-sondage__piste", "aria-hidden": "true" });
      const fill = element("span", { class: "replay-sondage__remplissage" });
      fill.style.width = `${share}%`;
      track.append(fill);
      item.append(track);
      list.append(item);
    });
    block.append(list);
  }
  block.append(element("p", { class: "replay-sondage__note" }, shareLine(results)));
  return block;
};

const choiceInputs = (poll, form) => {
  const type = poll.multiple ? "checkbox" : "radio";
  const labels = poll.kind === "choice" ? poll.options : resultLabels(poll);
  const values = poll.kind === "choice" ? poll.options.map((_option, index) => index) : scaleValues(poll.options);
  const group = element("fieldset", { class: "replay-sondage__choix" });
  group.append(element("legend", { class: "sr-only" }, poll.label));
  labels.forEach((label, index) => {
    const line = element("label", { class: "replay-sondage__option" });
    const input = element("input", { type, name: `replay-poll-${poll.id}`, value: String(values[index]) });
    line.append(input, document.createTextNode(` ${label}`));
    group.append(line);
  });
  form.append(group);
  return () => {
    const checked = Array.from(form.querySelectorAll("input:checked"), (input) => Number(input.value));
    if (checked.length === 0) return null;
    if (poll.kind === "scale") return checked[0];
    return checked;
  };
};

const textInput = (poll, form) => {
  const area = element("textarea", { rows: "2", maxlength: String(TEXT_LIMIT), "aria-label": poll.label });
  form.append(area);
  return () => area.value.trim() || null;
};

export const mountReplayPolls = () => {
  document.querySelectorAll("[data-replay-polls]").forEach((root) => {
    const video = root.closest("[data-replay-player]")?.querySelector("video");
    if (!video) return;

    const url = root.dataset.pollsUrl;
    let polls = [];
    let shownId = null;
    const dismissed = new Set();

    // Sondage dont la personne s'est saisie : il reste hors de son créneau.
    let engagedId = null;

    const activePoll = () => {
      const time = video.currentTime;
      const open = polls.filter((poll) => time >= poll.start && time < poll.end && !dismissed.has(poll.id));
      if (open.length > 0) return open[open.length - 1];
      return dismissed.has(engagedId) ? null : polls.find((poll) => poll.id === engagedId) || null;
    };

    const card = (poll) => {
      const body = element("div", { class: "replay-sondage__carte", "data-replay-poll-id": String(poll.id) });
      const header = element("div", { class: "replay-sondage__entete" });
      header.append(element("p", { class: "replay-sondage__titre" }, "Sondage du direct"));
      const hide = element("button", { type: "button", class: "btn btn--discret" }, "Masquer");
      hide.addEventListener("click", () => {
        dismissed.add(poll.id);
        render({ force: true });
      });
      header.append(hide);
      body.append(header, element("p", { class: "replay-sondage__question" }, poll.label));
      const error = element("p", { class: "replay-sondage__erreur", role: "alert" });

      if (poll.my_response) {
        const origin = poll.my_response.origin === "live" ? "pendant le direct" : "dans le replay";
        body.append(element("p", { class: "replay-sondage__note", "data-replay-poll-answered": poll.my_response.origin },
          `Ta réponse, ${origin} : ${answerText(poll, poll.my_response.value)}`));
        body.append(renderResults(poll));
        return body;
      }

      const form = element("form", { class: "replay-sondage__formulaire" });
      ["focusin", "input", "change"].forEach((name) => form.addEventListener(name, () => {
        engagedId = poll.id;
      }));
      const read = poll.kind === "short_text" ? textInput(poll, form) : choiceInputs(poll, form);
      form.append(element("p", { class: "replay-sondage__note" }, "Ta réponse est enregistrée à ton nom : les animateurs la voient."));
      const submit = element("button", { type: "submit", class: "btn" }, "Répondre");
      form.append(submit, error);
      form.addEventListener("submit", async (event) => {
        event.preventDefault();
        const value = read();
        if (value === null) {
          error.textContent = "Choisis une réponse avant d'envoyer.";
          return;
        }
        submit.disabled = true;
        error.textContent = "";
        try {
          const response = await fetch(`${url}/${poll.id}/reponses`, {
            method: "POST", credentials: "same-origin", cache: "no-store", redirect: "manual",
            headers: { Accept: "application/json", "Content-Type": "application/json", "X-CSRF-Token": csrfToken() },
            body: JSON.stringify({ value }),
          });
          const payload = await response.json().catch(() => null);
          if (!response.ok) {
            if (payload?.error === "invalid_authenticity_token") throw new Error("Session expirée : recharge la page.");
            if (payload?.error === "answered_live") {
              load();
              return;
            }
            throw new Error(REFUSALS[response.status] || `Réponse non enregistrée (${response.status || "réseau"}).`);
          }
          polls = polls.map((candidate) => (candidate.id === poll.id ? payload : candidate));
          render({ force: true });
        } catch (failure) {
          error.textContent = failure instanceof TypeError ? "Réseau indisponible : réponse non envoyée." : failure.message;
          submit.disabled = false;
        }
      });
      body.append(form);
      return body;
    };

    // `force` : redessine même si le sondage affiché n'a pas changé (réponse
    // reçue, liste relue, carte masquée).
    const render = ({ force = false } = {}) => {
      const poll = activePoll();
      if (!force && (poll?.id ?? null) === shownId) return;
      shownId = poll?.id ?? null;
      root.replaceChildren(...(poll ? [card(poll)] : []));
      root.hidden = !poll;
    };

    ["timeupdate", "seeked", "loadedmetadata"].forEach((name) => video.addEventListener(name, () => render()));

    function load() {
      fetch(url, { credentials: "same-origin", cache: "no-store", headers: { Accept: "application/json" } })
        .then((response) => (response.ok ? response.json() : Promise.reject(new Error(String(response.status)))))
        .then((payload) => {
          polls = Array.isArray(payload?.polls) ? payload.polls : [];
          render({ force: true });
        })
        .catch(() => {
          root.replaceChildren(element("p", { class: "replay-sondage__erreur", role: "alert" },
            "Les sondages de ce direct sont momentanément indisponibles."));
          root.hidden = false;
        });
    }
    load();
  });
};
