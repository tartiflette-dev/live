// Texte masqué pour un lien qui ouvre un autre onglet : les lecteurs
// d'écran l'annoncent ; l'écran le cache (classe `.visually-hidden`).
// L'espace initial sépare du mot précédent (« confidentialité (nouvel onglet) »).
export function NewTabHint() {
  return <>{" "}<span className="visually-hidden">(nouvel onglet)</span></>;
}
