// Confirmation des actions destructrices de la page animateur (Régénérer,
// Désactiver, Révoquer).
//
// Contrat DOM : un `form[data-confirm]` (button_to …, form: { data: {
// confirm: "…" } }) n'est envoyé qu'après un « OK » à window.confirm. Le
// bundle ne charge pas Turbo : `data-turbo-confirm` n'aurait aucun effet.
// Sans JS, le formulaire part sans question, comme avant.

let mounted = false;

export const mountConfirmations = () => {
  if (mounted) return;
  mounted = true;
  document.addEventListener(
    "submit",
    (event) => {
      const form = event.target;
      if (!(form instanceof HTMLFormElement)) return;
      const message = form.dataset.confirm;
      if (message && !window.confirm(message)) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    },
    true,
  );
};
