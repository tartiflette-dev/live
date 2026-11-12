// Préférences de périphériques d'un participant.
//
// Mémorisé : le micro et la caméra choisis, chacun par identifiant ET par
// libellé, et si chacun était activé ; la sortie son choisie (même forme).
// Deux mémoires :
//   - le SERVEUR, rattaché au participant identifié (animateur = User,
//     intervenant = Speaker ; contrat DevicePreference). Livré avec le
//     token (POST /api/token, `devicePreferences`), écrit par
//     PATCH /api/device_preferences. `null` pour un spectateur ;
//   - ce NAVIGATEUR (localStorage) : le dernier choix fait ici, quelle que
//     soit la salle. Seule mémoire du spectateur, repli de tous (un nouvel
//     intervenant a un Speaker neuf à chaque webinaire). La sortie son
//     n'est gardée QUE là : c'est un réglage du poste (casque, enceintes),
//     propre à cet ordinateur, que le serveur ne connaît pas.
//
// Un deviceId est propre au navigateur et à l'origine, et peut changer
// (données du site effacées, identifiants renouvelés) : le périphérique
// est retrouvé par identifiant, puis par libellé — sinon le défaut du
// système.

import { createContext, useContext, useEffect } from "react";
import { RoomEvent, Track, supportsAudioOutputSelection } from "livekit-client";
import { useRoomContext } from "@livekit/components-react";
import { csrfToken } from "./state_button";

export const AUDIO_INPUT = "audioinput";
export const VIDEO_INPUT = "videoinput";
export const AUDIO_OUTPUT = "audiooutput";
export const DEFAULT_DEVICE_ID = "default";

const LOCAL_KEY = "undust-live:device-preferences";
const SERVER_URL = "/api/device_preferences";

function deviceOrNull(value) {
  if (!value || typeof value.deviceId !== "string" || value.deviceId === "") return null;
  return { deviceId: value.deviceId, label: typeof value.label === "string" ? value.label : "" };
}

function flagOrNull(value) {
  return typeof value === "boolean" ? value : null;
}

// Forme unique, quelle que soit la source (serveur, stockage local, valeur
// corrompue) : un champ illisible devient null.
function normalizePreferences(raw) {
  const source = raw && typeof raw === "object" ? raw : {};
  return {
    [AUDIO_INPUT]: deviceOrNull(source[AUDIO_INPUT]),
    [VIDEO_INPUT]: deviceOrNull(source[VIDEO_INPUT]),
    [AUDIO_OUTPUT]: deviceOrNull(source[AUDIO_OUTPUT]),
    audioEnabled: flagOrNull(source.audioEnabled),
    videoEnabled: flagOrNull(source.videoEnabled),
  };
}

// Navigation privée ou stockage plein : pas de mémoire locale, ce n'est
// pas une panne (la mémoire serveur, quand elle existe, prend le relais).
function readLocalPreferences() {
  try {
    return normalizePreferences(JSON.parse(window.localStorage.getItem(LOCAL_KEY)));
  } catch (_) {
    return normalizePreferences(null);
  }
}

function writeLocalPreferences(preferences) {
  try {
    window.localStorage.setItem(LOCAL_KEY, JSON.stringify(preferences));
  } catch (_) {
    // cf. readLocalPreferences
  }
}

export function listDevices() {
  if (!navigator.mediaDevices?.enumerateDevices) {
    return Promise.reject(new Error("enumerateDevices indisponible"));
  }
  return navigator.mediaDevices.enumerateDevices();
}

// Identifiant à utiliser parmi `devices` (d'un même type) : d'abord un
// candidat dont l'identifiant est listé (il a été choisi dans CE
// navigateur), ensuite seulement un périphérique de même libellé (les
// libellés génériques, « Microphone (Realtek(R) Audio) », se retrouvent
// d'un poste à l'autre) ; à défaut, le défaut du système.
function resolveDeviceId(devices, candidates) {
  const listed = candidates.find((candidate) => devices.some((device) => device.deviceId === candidate.deviceId));
  if (listed) return listed.deviceId;
  for (const candidate of candidates) {
    const sameLabel = candidate.label && devices.find((device) => device.label === candidate.label);
    if (sameLabel) return sameLabel.deviceId;
  }
  return DEFAULT_DEVICE_ID;
}

// Avant toute autorisation, le navigateur ne livre ni identifiants ni
// libellés : on tente alors le premier candidat, en contrainte souple (un
// identifiant périmé retombe sur le défaut du système).
export function preferredDeviceId(devices, candidates) {
  if (devices.some((device) => device.label !== "")) return resolveDeviceId(devices, candidates);
  return candidates[0]?.deviceId ?? DEFAULT_DEVICE_ID;
}

// N'envoie que `patch` : le serveur ne change que les clés présentes (une
// page ouverte plus tôt n'écrase pas un choix fait entre-temps ailleurs).
async function patchServerPreferences({ slug, speakerToken }, patch) {
  const res = await fetch(SERVER_URL, {
    method: "PATCH",
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "X-CSRF-Token": csrfToken(),
    },
    body: JSON.stringify({ slug, speaker_token: speakerToken || null, device_preferences: patch }),
  });
  if (!res.ok) throw new Error(`serveur ${res.status}`);
}

// Préférences du participant pour la durée de la page. `server` = valeur
// `devicePreferences` du token (null : pas de mémoire serveur).
//
// Les deux mémoires restent distinctes et n'enregistrent que des CHOIX
// (un périphérique cliqué, un micro ou une caméra coupé ou rétabli) ; elles
// ne se fondent qu'à la lecture, le serveur d'abord. Recopier l'une dans
// l'autre ferait écraser, par une simple bascule de caméra, le micro que
// ce poste avait retenu par celui d'un autre poste.
//
// Les écritures serveur sont en file : la dernière demandée est la
// dernière écrite. `onSaveError(message | null)` reçoit l'issue de la
// dernière écriture serveur.
export function createDevicePreferences({ server, slug, speakerToken, onSaveError }) {
  let remote = server ? normalizePreferences(server) : null;
  let local = readLocalPreferences();
  let pending = Promise.resolve();

  return {
    // Périphériques à essayer pour `kind`, par ordre de préférence.
    candidates(kind) {
      const [first, second] = [remote?.[kind], local[kind]];
      if (!first) return second ? [second] : [];
      return second && second.deviceId !== first.deviceId ? [first, second] : [first];
    },

    enabled(flag) {
      return remote?.[flag] ?? local[flag] ?? true;
    },

    save(patch) {
      local = { ...local, ...patch };
      writeLocalPreferences(local);
      // La sortie son reste sur ce poste (cf. en-tête).
      const { [AUDIO_OUTPUT]: _output, ...serverPatch } = patch;
      if (!remote || Object.keys(serverPatch).length === 0) return pending;
      remote = { ...remote, ...serverPatch };
      pending = pending
        .then(() => patchServerPreferences({ slug, speakerToken }, serverPatch))
        .then(
          () => onSaveError(null),
          (err) => onSaveError(`Choix des périphériques non enregistré (${err.message}).`),
        );
      return pending;
    },
  };
}

const SOURCE_OF_KIND = { [AUDIO_INPUT]: Track.Source.Microphone, [VIDEO_INPUT]: Track.Source.Camera };

// Spectateur à qui l'on donne la parole (`active`) : rien n'est encore
// publié, et la Room ouvrira micro et caméra sur son périphérique actif. On
// y pose ses périphériques préférés (pour la scène, c'est le PreJoin qui
// les applique). Jamais leur état activé : c'est au spectateur de les
// ouvrir, après avoir donné son accord à l'image (participant_consent.jsx).
export function useRestorePreferredDevices(active) {
  const room = useRoomContext();
  const preferences = useDevicePreferences();
  useEffect(() => {
    if (!active) return undefined;
    let cancelled = false;
    listDevices()
      .then((devices) => {
        [AUDIO_INPUT, VIDEO_INPUT].forEach((kind) => {
          if (cancelled || room.localParticipant.getTrackPublication(SOURCE_OF_KIND[kind])) return;
          const ofKind = devices.filter((device) => device.kind === kind);
          room.switchActiveDevice(kind, preferredDeviceId(ofKind, preferences.candidates(kind)), false)
            .catch((err) => room.emit(RoomEvent.MediaDevicesError, err, kind));
        });
      })
      .catch((err) => room.emit(RoomEvent.MediaDevicesError, err));
    return () => { cancelled = true; };
  }, [active, preferences, room]);
}

// Choix de la sortie son possible dans ce navigateur ? Non sous Safari
// (macOS, iPhone, iPad : pas de setSinkId) : le son suit alors le réglage
// du système, et aucun menu n'est proposé. Sondé une fois par page.
let audioOutputSelectable = null;
export function canChooseAudioOutput() {
  if (audioOutputSelectable === null) {
    try {
      audioOutputSelectable = supportsAudioOutputSelection();
    } catch (_) {
      audioOutputSelectable = false;
    }
  }
  return audioOutputSelectable;
}

// Sortie son mémorisée sur ce poste, reposée en entrant dans la salle
// (scène comme spectateur). Le son des autres participants y passe, y
// compris ceux qui arrivent ensuite (options.audioOutput de la Room).
//
// Seulement sur une liste NOMMÉE : sans autorisation micro (Chrome
// « cette fois », Firefox par défaut), le navigateur ne livre pas les
// libellés et refuse setSinkId vers une sortie non par défaut — refus que
// LiveKit ne fait que journaliser, à l'arrivée de chaque participant. Le
// menu marquerait alors une sortie qui ne reçoit rien. On ne repose donc
// rien : le son passe par la sortie du système, et le menu le montre.
// Sortie mémorisée introuvable : même chose.
export function useRestorePreferredOutput() {
  const room = useRoomContext();
  const preferences = useDevicePreferences();
  useEffect(() => {
    const candidates = preferences?.candidates(AUDIO_OUTPUT) ?? [];
    if (candidates.length === 0 || !canChooseAudioOutput()) return undefined;
    let cancelled = false;
    listDevices()
      .then((devices) => {
        const outputs = devices.filter((device) => device.kind === AUDIO_OUTPUT);
        if (cancelled || !outputs.some((device) => device.label !== "")) return undefined;
        const deviceId = preferredDeviceId(outputs, candidates);
        if (deviceId === DEFAULT_DEVICE_ID) return undefined;
        return room.switchActiveDevice(AUDIO_OUTPUT, deviceId);
      })
      .catch((err) => room.emit(RoomEvent.MediaDevicesError, err, AUDIO_OUTPUT));
    return () => { cancelled = true; };
  }, [preferences, room]);
}

// Composant sans rendu : la restauration vaut pour toute la salle, montée
// une fois à côté de RoomAudioRenderer (scène et vue spectateur).
export function RestorePreferredOutput() {
  useRestorePreferredOutput();
  return null;
}

const DevicePreferencesContext = createContext(null);

export const DevicePreferencesProvider = DevicePreferencesContext.Provider;

export function useDevicePreferences() {
  return useContext(DevicePreferencesContext);
}
