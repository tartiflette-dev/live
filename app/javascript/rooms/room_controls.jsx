// Barre de contrôle de la salle, en français.
//
// Remplace <ControlBar> de @livekit/components-react, dont les libellés
// sont figés en anglais (« Microphone / Camera / Share screen / Leave »,
// aucune prop de traduction en 2.9). La composition est celle du prefab
// vendor : mêmes primitives TrackToggle / DisconnectButton /
// StartMediaButton, mêmes règles de permission ; la publication reste
// entièrement celle de LiveKit. Deux écarts :
//   - le menu des périphériques est RoomDeviceMenu (device_menu.jsx : un
//     seul périphérique marqué, choix signalé au seul clic) ;
//   - la mémorisation des choix passe par les préférences du participant
//     (device_preferences.js) : un clic sur un périphérique, un micro ou
//     une caméra coupé ou rétabli par l'utilisateur. Un changement venu du
//     système (périphérique débranché) n'est pas mémorisé ;
//   - « Son » choisit la sortie son (AudioOutputMenu), absente du prefab.
// Tant que l'accord à l'image manque (intervenant, co-animateur invité,
// spectateur à qui la parole est donnée), Micro et Caméra ouvrent la
// fenêtre de consentement au lieu de s'allumer (participant_consent.jsx) :
// ils s'affichent sans permission de publier, que la salle n'ouvre qu'après
// l'accord ; le partage d'écran attend l'accord.
//
// Les libellés restent dans le DOM à toute largeur : en barre étroite,
// room.css les masque visuellement (container query) sans retirer le nom
// accessible des boutons.

import { useCallback, useState } from "react";
import { Track } from "livekit-client";
import {
  DisconnectButton,
  LeaveIcon,
  StartMediaButton,
  TrackToggle,
  useLocalParticipantPermissions,
} from "@livekit/components-react";
import { AudioOutputMenu, RoomDeviceMenu } from "./device_menu";
import { ConsentGatedToggle, useParticipantConsent } from "./participant_consent";
import { AUDIO_INPUT, VIDEO_INPUT, useDevicePreferences } from "./device_preferences";

// Codes protobuf TrackSource de `canPublishSources` (même table que le
// prefab vendor). Liste vide = toutes les sources autorisées.
const TRACK_SOURCE_CODE = {
  [Track.Source.Camera]: 1,
  [Track.Source.Microphone]: 2,
  [Track.Source.ScreenShare]: 3,
};

function canPublishSource(permissions, source) {
  if (!permissions?.canPublish) return false;
  const allowed = permissions.canPublishSources || [];
  return allowed.length === 0 || allowed.includes(TRACK_SOURCE_CODE[source]);
}

// Partage d'écran : Chrome présélectionne « Onglet » (Firefox ignore
// l'option). Un onglet partagé ne montre ni la barre d'adresse — où un
// intervenant a son lien /join?t=… — ni les autres onglets (constat en
// direct). `displaySurface` n'est lu que sous `video` par livekit-client.
const SCREEN_SHARE_CAPTURE = { audio: true, selfBrowserSurface: "include", video: { displaySurface: "browser" } };

function supportsScreenSharing() {
  return !!navigator.mediaDevices?.getDisplayMedia;
}

function Label({ children }) {
  return <span className="lk-room-controls__label">{children}</span>;
}

// `controls` : `{ microphone, camera, audioOutput, screenShare, leave }`,
// chaque clé à `false` masque le bouton (sémantique du prefab vendor). Sans
// permission de publier, restent « Son », « Quitter » et le déblocage média.
export function RoomControls({ controls = {} }) {
  const permissions = useLocalParticipantPermissions();
  const preferences = useDevicePreferences();
  const consentNeeded = !!useParticipantConsent()?.needed;
  const [sharingScreen, setSharingScreen] = useState(false);

  const handleMicrophoneChange = useCallback(
    (enabled, isUserInitiated) => (isUserInitiated ? preferences.save({ audioEnabled: enabled }) : null),
    [preferences],
  );
  const handleCameraChange = useCallback(
    (enabled, isUserInitiated) => (isUserInitiated ? preferences.save({ videoEnabled: enabled }) : null),
    [preferences],
  );
  const handleDeviceChoice = useCallback((kind, device) => preferences.save({ [kind]: device }), [preferences]);

  const permitted = (source) => (consentNeeded ? source !== Track.Source.ScreenShare : canPublishSource(permissions, source));
  const shows = (key, source) => controls[key] !== false && permitted(source);
  const showMicrophone = shows("microphone", Track.Source.Microphone);
  const showCamera = shows("camera", Track.Source.Camera);
  const showScreenShare = shows("screenShare", Track.Source.ScreenShare) && supportsScreenSharing();
  const showLeave = controls.leave !== false;

  return (
    <div className="lk-control-bar lk-room-controls" data-testid="room-controls">
      {showMicrophone ? (
        <div className="lk-button-group">
          {consentNeeded ? (
            <ConsentGatedToggle source={Track.Source.Microphone}><Label>Micro</Label></ConsentGatedToggle>
          ) : (
            <TrackToggle source={Track.Source.Microphone} showIcon onChange={handleMicrophoneChange}>
              <Label>Micro</Label>
            </TrackToggle>
          )}
          <div className="lk-button-group-menu">
            <RoomDeviceMenu kind={AUDIO_INPUT} ariaLabel="Choisir le micro" onChoose={handleDeviceChoice} />
          </div>
        </div>
      ) : null}
      {showCamera ? (
        <div className="lk-button-group">
          {consentNeeded ? (
            <ConsentGatedToggle source={Track.Source.Camera}><Label>Caméra</Label></ConsentGatedToggle>
          ) : (
            <TrackToggle source={Track.Source.Camera} showIcon onChange={handleCameraChange}>
              <Label>Caméra</Label>
            </TrackToggle>
          )}
          <div className="lk-button-group-menu">
            <RoomDeviceMenu kind={VIDEO_INPUT} ariaLabel="Choisir la caméra" onChoose={handleDeviceChoice} />
          </div>
        </div>
      ) : null}
      {controls.audioOutput !== false ? <AudioOutputMenu labelClassName="lk-room-controls__label" /> : null}
      {showScreenShare ? (
        <TrackToggle
          source={Track.Source.ScreenShare}
          captureOptions={SCREEN_SHARE_CAPTURE}
          showIcon
          onChange={setSharingScreen}
        >
          <Label>{sharingScreen ? "Arrêter le partage" : "Partager l'écran"}</Label>
        </TrackToggle>
      ) : null}
      {showLeave ? (
        <DisconnectButton className="lk-room-controls__leave">
          <LeaveIcon />
          <Label>Quitter</Label>
        </DisconnectButton>
      ) : null}
      <StartMediaButton label="Activer le son et la vidéo" />
    </div>
  );
}
