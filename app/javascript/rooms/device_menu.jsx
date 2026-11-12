// Menu de choix d'un périphérique.
//
// Remplace <MediaDeviceMenu> de @livekit/components-react, dont il garde le
// DOM et les classes (charte room.css, tests de la scène). Vendor
// (components-react 2.9.24, components-core 0.12.15) a deux défauts :
//   - avec une piste d'aperçu (PreJoin), un clic change bien le
//     périphérique de l'aperçu mais le choix ne REMONTE jamais :
//     setupDeviceSelector publie l'identifiant actif dans un sujet que
//     personne n'écoute. Le PreJoin rejoignait avec le défaut et
//     n'enregistrait rien (constat en direct, intervenant à deux micros) ;
//   - une entrée est marquée active par identifiant ET, quand l'actif est
//     « default », la première de la liste dès qu'aucun libellé ne
//     commence par l'anglais « Default ». En français l'entrée s'appelle
//     « Par défaut - … » : deux micros en orange quand la première entrée
//     n'est pas le défaut.
// Ici une seule entrée est marquée, et `onSelect` n'est appelé que sur un
// clic : un changement venu du système (périphérique débranché) n'est pas
// un choix à mémoriser.
//
// Accessibilité : une simple liste de boutons (pas de rôle listbox, qui
// promettrait une navigation aux flèches), l'entrée active porte
// `aria-current`, le bouton d'ouverture `aria-expanded` ; Échap ferme et
// rend le focus au bouton.
//
// Sortie son : le même menu, ouvert par un bouton libellé (`children`,
// `buttonClassName`) et non par le seul chevron d'un groupe ; `note`
// s'affiche en tête de liste.

import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { RoomEvent } from "livekit-client";
import { computeMenuPosition } from "@livekit/components-core";
import { useMediaDeviceSelect, useRoomContext } from "@livekit/components-react";
import {
  AUDIO_OUTPUT,
  DEFAULT_DEVICE_ID,
  canChooseAudioOutput,
  useDevicePreferences,
} from "./device_preferences";

// Index de l'entrée active, -1 si aucune. « default » sans entrée de ce
// nom (Firefox, Safari) : le défaut du système est la première entrée.
function activeDeviceIndex(devices, activeDeviceId) {
  const exact = devices.findIndex((device) => device.deviceId === activeDeviceId);
  if (exact !== -1) return exact;
  return activeDeviceId === DEFAULT_DEVICE_ID && devices.length > 0 ? 0 : -1;
}

export function DeviceMenu({
  ariaLabel,
  devices,
  activeDeviceId,
  onSelect,
  onOpen,
  disabled = false,
  buttonClassName = "lk-button lk-button-menu",
  children,
  note,
  emptyText,
}) {
  const [open, setOpen] = useState(false);
  const menuId = useId();
  const buttonRef = useRef(null);
  const menuRef = useRef(null);
  const active = activeDeviceIndex(devices, activeDeviceId);

  // Menu fermé = hors de la mise en page (display: none). Chez vendor il
  // restait seulement invisible, et débordait de la vue s'il était près
  // d'un bord (le menu « Son » dans l'en-tête du spectateur faisait
  // défiler la page en largeur). À l'ouverture, il est placé au-dessus du
  // bouton, retourné ou décalé s'il déborde, et rendu visible seulement
  // une fois placé ; à la fermeture, il redevient invisible (la visibilité
  // n'est tenue qu'ici, jamais par le style React).
  useLayoutEffect(() => {
    const menu = menuRef.current;
    if (disabled || !open || !buttonRef.current || !menu) return undefined;
    const stop = computeMenuPosition(buttonRef.current, menu, (x, y) => {
      Object.assign(menu.style, { left: `${x}px`, top: `${y}px`, visibility: "visible" });
    });
    return () => {
      stop();
      menu.style.visibility = "hidden";
    };
  }, [disabled, devices, open]);

  useEffect(() => {
    if (!open) return undefined;
    const closeOnOutsideClick = (event) => {
      if (menuRef.current?.contains(event.target) || buttonRef.current?.contains(event.target)) return;
      setOpen(false);
    };
    const closeOnEscape = (event) => {
      if (event.key !== "Escape") return;
      setOpen(false);
      buttonRef.current?.focus();
    };
    document.addEventListener("click", closeOnOutsideClick);
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.removeEventListener("click", closeOnOutsideClick);
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [open]);

  const toggle = () => {
    if (!open) onOpen?.();
    setOpen(!open);
  };

  const choose = (device) => {
    setOpen(false);
    onSelect(device);
  };

  return (
    <>
      <button
        type="button"
        className={buttonClassName}
        data-device-menu=""
        aria-label={ariaLabel}
        aria-expanded={open}
        aria-controls={disabled ? undefined : menuId}
        disabled={disabled}
        onClick={toggle}
        ref={buttonRef}
      >
        {children}
      </button>
      {disabled ? null : (
        <div className="lk-device-menu device-menu" id={menuId} ref={menuRef} style={open ? undefined : { display: "none" }}>
          {note ? <p className="lk-device-menu__note">{note}</p> : null}
          {devices.length === 0 && emptyText ? <p className="lk-device-menu__note">{emptyText}</p> : null}
          <ul className="lk-list lk-media-device-select">
            {devices.map((device, index) => (
              <li key={device.deviceId} data-device-id={device.deviceId} data-lk-active={index === active}>
                <button
                  type="button"
                  className="lk-button"
                  aria-current={index === active ? "true" : undefined}
                  onClick={() => choose(device)}
                >
                  {device.label}
                </button>
              </li>
            ))}
          </ul>
        </div>
      )}
    </>
  );
}

// Menu de la barre de contrôle, dans la salle : la liste et l'entrée
// active suivent la Room (y compris un changement venu du système).
// `onChoose(kind, device)` n'est appelé qu'après une bascule réussie. Les
// échecs (liste, bascule) passent par l'erreur média de la Room, comme
// chez vendor : bannière de room.jsx.
export function RoomDeviceMenu({ kind, ariaLabel, onChoose, buttonClassName, children, note, emptyText }) {
  const room = useRoomContext();
  // Comme vendor : pas de demande d'autorisation avant la première
  // ouverture (sinon une invite au montage de la barre).
  const [requestPermissions, setRequestPermissions] = useState(false);
  const reportError = useCallback((err) => room.emit(RoomEvent.MediaDevicesError, err, kind), [room, kind]);
  const { devices, activeDeviceId, setActiveMediaDevice } = useMediaDeviceSelect({
    kind,
    room,
    requestPermissions,
    onError: reportError,
  });

  const select = async (device) => {
    try {
      await setActiveMediaDevice(device.deviceId, { exact: true });
    } catch (err) {
      reportError(err);
      return;
    }
    onChoose(kind, { deviceId: device.deviceId, label: device.label });
  };

  return (
    <DeviceMenu
      ariaLabel={ariaLabel}
      devices={devices}
      activeDeviceId={activeDeviceId}
      onSelect={select}
      onOpen={() => setRequestPermissions(true)}
      buttonClassName={buttonClassName}
      note={note}
      emptyText={emptyText}
    >
      {children}
    </DeviceMenu>
  );
}

function SpeakerIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true" focusable="false">
      <path d="M2 6h2.5L8 3v10L4.5 10H2z" fill="currentColor" />
      <path
        d="M10.5 5.5a3.5 3.5 0 0 1 0 5M12.5 3.5a6.3 6.3 0 0 1 0 9"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
      />
    </svg>
  );
}

// Choix de la sortie son (haut-parleurs, casque…), pour tous les rôles :
// un participant entend la salle sur le mauvais périphérique (casque
// branché mais son dans les enceintes, écran HDMI…) sans pouvoir le
// corriger depuis la page. Le choix vaut pour tout le son de la salle et
// reste mémorisé sur ce poste ; il est reposé à l'entrée suivante
// (RestorePreferredOutput, monté par la salle).
// Absent là où le navigateur ne sait pas changer de sortie (Safari).
// `labelClassName` : classe du libellé « Son » (la barre de la scène le
// masque visuellement en largeur étroite) ; `note` : texte en tête de liste.
export function AudioOutputMenu({ labelClassName, note }) {
  const preferences = useDevicePreferences();
  if (!canChooseAudioOutput()) return null;

  return (
    <RoomDeviceMenu
      kind={AUDIO_OUTPUT}
      ariaLabel="Choisir la sortie son"
      buttonClassName="lk-button lk-output-menu"
      onChoose={(kind, device) => preferences?.save({ [kind]: device })}
      note={note}
      emptyText="Aucune sortie son listée par le navigateur : le son passe par la sortie du système."
    >
      <SpeakerIcon />
      <span className={labelClassName}>Son</span>
    </RoomDeviceMenu>
  );
}
