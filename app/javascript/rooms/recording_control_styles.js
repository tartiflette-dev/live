// Palette « REC » partagée entre <RecordingControl> (régie) et
// <RecordingIndicator> (salle : scène, intervenant, spectateur — consentement).
// Couleur critique = la propriété
// `--recording-critical`, par défaut la variante « -dark » du token (la
// salle est toujours sombre) ; la régie, sous le chrome clair ou sombre, la
// redéfinit sur `--status-critical` (regie.css), qui suit le thème. Le
// bouton ne porte ici que sa géométrie : filet, couleur et curseur vivent
// dans regie.css, où les classes is-<phase> doivent pouvoir les changer (un
// style inline l'emporterait). La pastille garde son remplissage inline :
// signal REC, pas un aplat ; la feuille n'y joue que l'opacité et
// l'animation.

export const STYLE_WRAPPER = { display: "inline-flex", alignItems: "center", gap: "0.5rem" };
export const STYLE_DOT     = { display: "inline-block", width: "0.6rem", height: "0.6rem", borderRadius: "50%", background: "var(--recording-critical, var(--status-critical-dark))" };
export const STYLE_DOT_OFF = { ...STYLE_DOT, background: "transparent", border: "1px solid var(--gray-350)" };
export const STYLE_BUTTON  = { padding: "0.4rem 0.875rem", borderRadius: "var(--radius-interactive)", background: "transparent", fontFamily: "inherit", fontSize: "0.8125rem", fontWeight: 600 };
export const STYLE_ERROR   = { color: "var(--recording-critical, var(--status-critical-dark))", fontSize: "0.8125rem" };
