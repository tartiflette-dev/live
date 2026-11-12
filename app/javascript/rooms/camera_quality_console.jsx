// Bloc « Caméras » de la régie : caméras émises sous 720p depuis plus de
// 15 s, avec la raison et l'encodeur, caméras publiées mais non mesurées
// (aucune alerte possible pour elles) et replis sans simulcast du direct.
// Les mesures ne sont enregistrées que pendant le direct : hors direct, rien
// n'est attendu, le bloc le dit.
// Données : /regie/status, `camera_health` (CameraSample), mesurées par le
// navigateur de chaque personne qui publie (camera_health.jsx). Les noms
// viennent de la scène lue dans LiveKit (`on_stage`).

const REASONS = {
  bandwidth: "débit montant insuffisant",
  cpu: "processeur saturé",
  other: "limite du navigateur",
  none: "aucune limite signalée : encodeur ou capture",
};
const ROLE_LABELS = { host: "Animation", speaker: "Intervenant", viewer: "Spectateur" };

function clockTime(iso) {
  const date = new Date(iso);
  return `${date.getHours()}:${String(date.getMinutes()).padStart(2, "0")}`;
}

function frameSize(width, height) {
  return width && height ? `${width}×${height}` : null;
}

function alertText(alert) {
  const emitted = frameSize(alert.width, alert.height);
  const details = [REASONS[alert.reason] || (alert.reason ? `limite « ${alert.reason} »` : "raison inconnue")];
  const capture = frameSize(alert.capture_width, alert.capture_height);
  if (capture && capture !== emitted) details.push(`capture ${capture}`);
  if (alert.encoder) details.push(`encodeur ${alert.encoder}`);
  const state = emitted ? `émise en ${emitted}` : "n'émet aucune image";
  return `${state} depuis ${clockTime(alert.since)} — ${details.join(" · ")}`;
}

function fallbackText(fallback) {
  const at = clockTime(fallback.at);
  if (fallback.outcome === "simulcast_fallback") {
    const encoder = fallback.encoder ? ` (encodeur ${fallback.encoder})` : "";
    return `republiée sans simulcast en 720p${encoder} : seule la couche basse sortait (journalisé à ${at}).`;
  }
  return `: repli sans simulcast refusé, la caméra garde sa publication d'origine (journalisé à ${at}).`;
}

export function CameraQualityConsole({ status }) {
  if (!status) return <p className="regie-note">Lecture des caméras…</p>;
  if (status.state !== "live") {
    return <p className="regie-note" data-testid="regie-cameras-off-air">Caméras mesurées pendant le direct seulement.</p>;
  }
  const { alerts = [], fallbacks = [], measured = [] } = status.camera_health || {};
  const onStage = status.on_stage || [];
  const names = new Map(onStage.map((person) => [person.identity, person.name]));
  const nameOf = (identity) => names.get(identity) || ROLE_LABELS[identity.split("-", 1)[0]] || "Participant";
  const unmeasured = onStage.filter((person) => person.camera && !measured.includes(person.identity));

  return (
    <div className="regie-scene" data-testid="regie-cameras">
      {alerts.length === 0 ? (
        <p className="regie-note" data-testid="regie-cameras-ok">Aucune caméra émise sous 720p.</p>
      ) : alerts.map((alert) => (
        <p className="regie-alerte" role="alert" key={alert.identity} data-testid="regie-camera-alert" data-identity={alert.identity}>
          Caméra de {nameOf(alert.identity)} {alertText(alert)}
        </p>
      ))}
      {unmeasured.length > 0 ? (
        <p className="regie-note" data-testid="regie-cameras-unmeasured">
          Non mesurée : {unmeasured.map((person) => person.name).join(", ")}. Normal dans les 15 s qui suivent l'arrivée
          d'une caméra ou le début du direct. Au-delà, la mesure n'arrive pas : page de la salle ouverte avant cette
          version (à recharger), navigateur sans statistiques ou mesure refusée par le serveur.
        </p>
      ) : null}
      {fallbacks.map((fallback) => (
        <p className="regie-note regie-note--info" key={`${fallback.identity}-${fallback.at}`} data-testid="regie-camera-fallback">
          Caméra de {nameOf(fallback.identity)} {fallbackText(fallback)}
        </p>
      ))}
    </div>
  );
}
