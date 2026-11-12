// Bouton unique d'état du direct.
//
// Monté par la régie (regie.jsx, état relu par /regie/status), par l'écran
// de sortie de salle de l'animation (room_exit.jsx, « Terminer ») et par la
// scène d'un direct terminé (live_state_control.jsx, « Reprendre »). Les
// endpoints go_live/end/resume restent réservés à l'animation : une URL
// forgée n'obtient rien. Rendu selon l'état SERVEUR courant :
//   draft → « Démarrer le direct »
//   live  → « Terminer le direct »
//   ended → « Reprendre le direct » (« j'ai
//           même pas moyen de remettre le truc en direct »)
// Sans l'URL de la transition, aucun bouton.
//
// Clic → fetch POST redirect="manual" vers l'URL correspondante. LE
// SERVEUR (WebinarStatesController) répond 303 DANS LES DEUX CAS :
// succès (transition appliquée) ET refus (« Transition refusée »,
// flash[:alert], redirect_to webinar_path). Avec redirect:"manual", fetch
// retourne response.type === "opaqueredirect" pour TOUT 3xx sans lire le
// Location — impossible de distinguer succès de refus depuis le status
// seul (race entre deux animateurs simultanés).
//
// La vérité est donc RELUE côté serveur : après opaqueredirect on GET
// /w/<slug>/state.json (route publique) et on positionne le rendu
// sur l'état RÉEL. Si l'état est resté identique → transition refusée →
// onError visible dans la scène (fail-loud, cf. doctrine room.jsx :
// pas de console.*, pas d'alert).
//
// Bouton `disabled` pendant la requête → pas de second POST tant que le
// premier est en cours.
//
// Terminer ou reprendre le direct touche toute la salle : la fin arrête
// tous les enregistrements, la reprise en relance de nouveaux. D'où une
// confirmation en deux temps, sans modale (useTwoStepConfirm) : le premier
// clic ARME le bouton (« Confirmer… ? » + « Annuler »), le second agit.
// Démarrer le direct reste à un clic : c'est le geste attendu en draft.

import { useCallback, useEffect, useState } from "react";
import { useTwoStepConfirm } from "./two_step_confirm";

// CSRF meta lu à chaque requête (le token n'est pas cached : Rails peut
// avoir tourné entre-temps). Ré-export utilisé par room.jsx (SRP : même
// acteur = protection CSRF Rails omakase, une seule définition).
export function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.getAttribute("content") : "";
}

// Transition proposée par état : libellé, question de confirmation (absente
// = un clic suffit) et URL parmi celles reçues.
const TRANSITIONS = {
  draft: { label: "Démarrer le direct", url: (urls) => urls.goLiveUrl },
  live:  { label: "Terminer le direct", confirm: "Confirmer la fin du direct\u00a0?", url: (urls) => urls.endUrl },
  ended: { label: "Reprendre le direct", confirm: "Confirmer la reprise du direct\u00a0?", url: (urls) => urls.resumeUrl },
};

export function StateButton({ state, stateUrl, goLiveUrl, endUrl, resumeUrl, onStateChange, onError }) {
  // Hooks AVANT tout early-return (règle React stricte, cf. bandeau room.jsx).
  const [pending, setPending] = useState(false);
  const { armed, confirmed, disarm, controlRef } = useTwoStepConfirm();

  // Un changement d'état serveur désarme toujours.
  useEffect(() => {
    disarm();
  }, [state, disarm]);

  const transition = TRANSITIONS[state];
  const url = transition ? transition.url({ goLiveUrl, endUrl, resumeUrl }) : null;

  const handleClick = useCallback(async () => {
    if (!url || pending) return;
    if (transition.confirm && !confirmed()) return;
    setPending(true);
    try {
      const res = await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        redirect: "manual",
        headers: {
          "X-CSRF-Token": csrfToken(),
          "Accept": "text/html",
        },
      });
      // response.type === "opaqueredirect" = fetch a vu UN 3xx et suivi
      // manuel — succès ET refus tombent ici (les DEUX réponses controller
      // sont des 303, cf. bandeau). status === 200 sert de filet si la
      // route change un jour ; toute autre issue = erreur réseau/serveur.
      const httpOk =
        res.type === "opaqueredirect" || res.status === 303 || res.status === 200;
      if (!httpOk) {
        throw new Error(`serveur ${res.status || res.type}`);
      }

      // Vérité serveur relue : GET /w/<slug>/state.json (route publique).
      // L'état RÉEL tranche succès vs refus — jamais confiance dans
      // le seul status HTTP.
      if (!stateUrl) {
        throw new Error("URL d'état absente (data-state-url manquant)");
      }
      const stateRes = await fetch(stateUrl, {
        credentials: "same-origin",
        headers: { "Accept": "application/json" },
      });
      if (!stateRes.ok) {
        throw new Error(`état illisible (${stateRes.status})`);
      }
      const payload = await stateRes.json();
      const serverState = payload && payload.state;
      const warnings = Array.isArray(payload?.warnings)
        ? payload.warnings.filter((warning) => typeof warning?.message === "string").map((warning) => warning.message).join(" ")
        : "";
      if (!serverState) {
        throw new Error("état absent de la réponse");
      }
      if (serverState === state) {
        // Le serveur a refusé la transition (flash[:alert] côté redirect).
        // On garde l'état affiché et on signale au host.
        onError(["Transition refusée par le serveur (état inchangé).", warnings].filter(Boolean).join(" "));
      } else {
        onStateChange(serverState);
        onError(warnings || null);
      }
    } catch (err) {
      const msg = err && err.message ? err.message : "réseau";
      onError(`Transition impossible : ${msg}. Rechargez la page.`);
    } finally {
      setPending(false);
    }
  }, [confirmed, pending, state, stateUrl, url, transition, onStateChange, onError]);

  if (!url) return null;

  return (
    <span className="lk-state-control" ref={controlRef}>
      <button
        type="button"
        className="lk-state-button"
        data-state={state}
        data-armed={armed ? "true" : "false"}
        data-testid="state-button"
        onClick={handleClick}
        disabled={pending}
      >
        {pending ? "…" : armed ? transition.confirm : transition.label}
      </button>
      {armed ? (
        <button
          type="button"
          className="lk-state-button__cancel"
          data-testid="state-button-cancel"
          onClick={disarm}
        >
          Annuler
        </button>
      ) : null}
    </span>
  );
}
