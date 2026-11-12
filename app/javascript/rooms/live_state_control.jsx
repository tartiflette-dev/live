// « Reprendre le direct » hors salle : la scène d'un
// direct terminé (webinars/ended.html.erb) monte ici le même StateButton que
// la salle — même confirmation en deux temps, même relecture de l'état
// serveur. Une fois le direct repris, la page est rechargée : le serveur
// rend alors la salle et les enregistrements repartent.

import { createRoot } from "react-dom/client";
import { useState } from "react";
import { StateButton } from "./state_button";

function LiveStateControl({ state, stateUrl, resumeUrl }) {
  const [error, setError] = useState(null);
  return (
    <>
      <StateButton
        state={state}
        stateUrl={stateUrl}
        resumeUrl={resumeUrl}
        onStateChange={() => window.location.reload()}
        onError={setError}
      />
      {error ? <p className="lk-exit-screen__error" role="alert" data-testid="state-error">{error}</p> : null}
    </>
  );
}

export function mountLiveStateControl() {
  document.querySelectorAll("[data-live-state-control]").forEach((el) => {
    const { state, stateUrl, resumeUrl } = el.dataset;
    createRoot(el).render(<LiveStateControl state={state} stateUrl={stateUrl} resumeUrl={resumeUrl} />);
  });
}
