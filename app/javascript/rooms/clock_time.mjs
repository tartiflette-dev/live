// Heure d'horloge affichée à l'animation et au public : 9:30, jamais 09:30
// (convention d'écriture des heures du produit). `seconds` : 9:30:05.
// @return "" pour une date absente ou illisible.
export function clockTime(iso, { seconds = false } = {}) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString("fr-FR", { hour: "numeric", minute: "2-digit", ...(seconds ? { second: "2-digit" } : {}) });
}
