// Confirmation en deux temps, sans modale (audit UX), pour les
// gestes qui touchent toute la salle ou une personne : terminer ou reprendre
// le direct (StateButton), retirer un participant (régie).
//
// Le premier clic ARME le contrôle pendant ARM_TIMEOUT_MS, le second agit ;
// Échap, « Annuler », un clic hors du contrôle (`controlRef`) ou le délai
// désarment. La confirmation n'est acceptée qu'ARM_GUARD_MS après
// l'armement : un double-clic (ou un tap répété) arme sans agir.

import { useCallback, useEffect, useRef, useState } from "react";

const ARM_TIMEOUT_MS = 5000;
const ARM_GUARD_MS = 500;

// `confirmed()` : premier appel, arme et répond false ; appel suivant passé
// la garde, désarme et répond true (agir) ; pendant la garde, false.
export function useTwoStepConfirm() {
  const [armed, setArmed] = useState(false);
  const armedAtRef = useRef(0);
  const controlRef = useRef(null);

  useEffect(() => {
    if (!armed) return undefined;
    const disarm = () => setArmed(false);
    const timer = setTimeout(disarm, ARM_TIMEOUT_MS);
    const onKeyDown = (event) => { if (event.key === "Escape") disarm(); };
    const onPointerDown = (event) => {
      if (controlRef.current && !controlRef.current.contains(event.target)) disarm();
    };
    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("pointerdown", onPointerDown);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("pointerdown", onPointerDown);
    };
  }, [armed]);

  const confirmed = useCallback(() => {
    if (!armed) {
      armedAtRef.current = Date.now();
      setArmed(true);
      return false;
    }
    if (Date.now() - armedAtRef.current < ARM_GUARD_MS) return false;
    setArmed(false);
    return true;
  }, [armed]);

  const disarm = useCallback(() => setArmed(false), []);

  return { armed, confirmed, disarm, controlRef };
}
