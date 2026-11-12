// Bouton « Copier le lien » de la page animateur (constat en direct :
// les liens secrets ne s'affichent plus, ils se copient).
//
// Contrat DOM (WebinarLinksHelper) : un `button[data-copy-link]` porte
// l'URL complète ; son `aria-controls` désigne la zone `role="status"`
// qui annonce le résultat, effacé après FEEDBACK_MS.
//
// Presse-papiers : `navigator.clipboard.writeText`, sinon repli textarea
// hors écran + execCommand("copy") (API absente hors contexte sécurisé,
// permission refusée, navigateur ancien). No-op sans bouton.
//
// `copyText` et les retours sont repris par le bouton « Copier le lien » de
// la régie (rooms/regie.jsx), rendu par React après la page.

export const FEEDBACK_MS = 4000;
export const COPIED = { text: "Lien copié", className: "etat etat--succes" };
export const FAILED = { text: "Copie impossible depuis ce navigateur", className: "etat etat--ecart" };

const resetTimers = new WeakMap();

const copyWithExecCommand = (text) => {
  const previousFocus = document.activeElement;
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.setAttribute("aria-hidden", "true");
  textarea.style.position = "fixed";
  textarea.style.top = "0";
  textarea.style.left = "-9999px";
  textarea.style.opacity = "0";
  document.body.appendChild(textarea);
  textarea.select();
  try {
    return document.execCommand("copy");
  } catch (_error) {
    return false;
  } finally {
    textarea.remove();
    if (previousFocus instanceof HTMLElement) {
      previousFocus.focus();
    }
  }
};

export const copyText = async (text) => {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch (_error) {
    return copyWithExecCommand(text);
  }
};

const announce = (status, { text, className }) => {
  status.textContent = text;
  status.className = className;
  window.clearTimeout(resetTimers.get(status));
  resetTimers.set(
    status,
    window.setTimeout(() => {
      status.textContent = "";
      status.removeAttribute("class");
    }, FEEDBACK_MS),
  );
};

const bindCopyButton = (button) => {
  const status = document.getElementById(button.getAttribute("aria-controls"));
  button.addEventListener("click", async () => {
    const copied = await copyText(button.dataset.copyLink);
    if (status) {
      announce(status, copied ? COPIED : FAILED);
    }
  });
};

export function mountCopyLinks() {
  document.querySelectorAll("button[data-copy-link]").forEach(bindCopyButton);
}
