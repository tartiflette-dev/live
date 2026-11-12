// Écran d'entrée de l'animateur et de l'intervenant : aperçu caméra, choix
// et activation du micro et de la caméra, nom affiché, « Rejoindre la
// salle ».
//
// Remplace <PreJoin> de @livekit/components-react,
// dont il garde le DOM et les classes (charte room.css,
// tests). Le prefab vendor ne pouvait pas mémoriser un périphérique :
//   - son menu ne remonte jamais un choix fait avec une piste d'aperçu
//     (cf. device_menu.jsx) : il rejoignait avec le défaut du système ;
//   - sa mémoire était coupée pour toute invitation nominative
//     (persistUserChoices={!initialName}, posé pour que le nom de
//     l'invitation l'emporte sur un nom mémorisé), et commune à tous les
//     participants du navigateur quand elle marchait.
// Ici les choix viennent des préférences du participant
// (device_preferences.js) et sont appliqués à l'aperçu. Au clic sur
// « Rejoindre », on enregistre l'état activé du micro et de la caméra, et
// le périphérique de chaque type que l'utilisateur a CHOISI ici : un repli
// sur le défaut (préférence introuvable sur ce poste) n'est pas un choix,
// il écraserait la préférence valable ailleurs.
//
// Garde fail-loud (room.jsx §FAIL-LOUD MICRO) : l'énumération du montage
// sert aussi à signaler l'absence de tout micro sans attendre le clic (cas
// Chrome orphelin PipeWire, menus vides et aperçu muet).
//
// Le nom affiché reste mémorisé par LiveKit (lk-user-choices), sauf pour
// une invitation nominative dont le nom l'emporte ; l'identité du
// participant reste décidée par le serveur.

import { useEffect, useRef, useState } from "react";
import { Track, facingModeFromLocalTrack } from "livekit-client";
import {
  ParticipantPlaceholder,
  TrackToggle,
  useMediaDevices,
  usePersistentUserChoices,
  usePreviewTracks,
} from "@livekit/components-react";
import { DeviceMenu } from "./device_menu";
import { AUDIO_INPUT, VIDEO_INPUT, listDevices, preferredDeviceId } from "./device_preferences";

const NO_MICROPHONE = { failure: "NotFound", kind: AUDIO_INPUT };
const KINDS = [AUDIO_INPUT, VIDEO_INPUT];

function devicesOfKind(devices, kind) {
  return devices.filter((device) => device.kind === kind);
}

// Le menu ne s'active qu'avec l'aperçu de son type, comme vendor : sa liste
// est alors lue AVEC l'autorisation, sans seconde invite. Une liste
// illisible passe par `onError` (bannière), comme les échecs de l'aperçu.
function PreviewDeviceMenu({ kind, ariaLabel, activeDeviceId, onSelect, onError }) {
  const devices = useMediaDevices({ kind, onError });
  return <DeviceMenu ariaLabel={ariaLabel} devices={devices} activeDeviceId={activeDeviceId} onSelect={onSelect} />;
}

export function StagePreJoin({ initialName, preferences, onSubmit, onEnumFailure, onError }) {
  const { userChoices, saveUsername } = usePersistentUserChoices({
    defaults: { username: initialName },
    preventLoad: !!initialName,
    preventSave: !!initialName,
  });
  const username = userChoices.username;
  const [audioEnabled, setAudioEnabled] = useState(() => preferences.enabled("audioEnabled"));
  const [videoEnabled, setVideoEnabled] = useState(() => preferences.enabled("videoEnabled"));
  // Identifiants retenus par type ; null tant que l'énumération du montage
  // n'a pas répondu (l'aperçu attend, il s'ouvrirait sinon sur le défaut).
  const [deviceIds, setDeviceIds] = useState(null);
  // Types dont le périphérique a été cherché AVEC les libellés visibles.
  const resolvedKinds = useRef(new Set());
  // Périphériques choisis par l'utilisateur dans ce PreJoin, par type,
  // avec leur libellé (lu dans la liste au moment du clic).
  const picked = useRef({});

  // Montage : préférences lues une fois, le PreJoin n'en réécrit qu'au
  // clic sur « Rejoindre ».
  useEffect(() => {
    let cancelled = false;
    const pick = (devices) => {
      const ids = {};
      KINDS.forEach((kind) => {
        const ofKind = devicesOfKind(devices, kind);
        ids[kind] = preferredDeviceId(ofKind, preferences.candidates(kind));
        if (ofKind.some((device) => device.label !== "")) resolvedKinds.current.add(kind);
      });
      return ids;
    };
    listDevices()
      .then((devices) => {
        if (cancelled) return;
        if (devicesOfKind(devices, AUDIO_INPUT).length === 0) onEnumFailure(NO_MICROPHONE);
        setDeviceIds(pick(devices));
      })
      .catch(() => {
        if (cancelled) return;
        onEnumFailure(NO_MICROPHONE);
        setDeviceIds(pick([]));
      });
    return () => { cancelled = true; };
  }, []);

  const tracks = usePreviewTracks(
    {
      audio: deviceIds && audioEnabled ? { deviceId: deviceIds[AUDIO_INPUT] } : false,
      video: deviceIds && videoEnabled ? { deviceId: deviceIds[VIDEO_INPUT] } : false,
    },
    onError,
  );
  const audioTrack = tracks?.find((track) => track.kind === Track.Kind.Audio);
  const videoTrack = tracks?.find((track) => track.kind === Track.Kind.Video);

  // Première autorisation accordée ici : les libellés deviennent visibles,
  // le périphérique mémorisé est alors retrouvé par son libellé (identifiant
  // d'un autre navigateur, ou renouvelé). L'aperçu suit le nouveau choix.
  useEffect(() => {
    const pending = [[AUDIO_INPUT, audioTrack], [VIDEO_INPUT, videoTrack]]
      .filter(([kind, track]) => track && !resolvedKinds.current.has(kind))
      .map(([kind]) => kind);
    if (pending.length === 0) return undefined;
    pending.forEach((kind) => resolvedKinds.current.add(kind));
    let cancelled = false;
    listDevices()
      .then((devices) => {
        if (cancelled) return;
        setDeviceIds((ids) => {
          const next = { ...ids };
          pending.forEach((kind) => {
            next[kind] = preferredDeviceId(devicesOfKind(devices, kind), preferences.candidates(kind));
          });
          return next;
        });
      })
      .catch((err) => {
        if (!cancelled) onError(err);
      });
    return () => { cancelled = true; };
  }, [audioTrack, videoTrack]);

  const videoEl = useRef(null);
  useEffect(() => {
    if (!videoEl.current || !videoTrack) return undefined;
    videoTrack.unmute();
    videoTrack.attach(videoEl.current);
    return () => { videoTrack.detach(); };
  }, [videoTrack]);

  const choose = (kind) => (device) => {
    picked.current[kind] = { deviceId: device.deviceId, label: device.label };
    setDeviceIds((ids) => ({ ...ids, [kind]: device.deviceId }));
  };

  const canJoin = username !== "" && deviceIds !== null;

  const handleSubmit = (event) => {
    event.preventDefault();
    if (!canJoin) return;
    preferences.save({ audioEnabled, videoEnabled, ...picked.current });
    onSubmit({
      username,
      audioEnabled,
      videoEnabled,
      audioDeviceId: deviceIds[AUDIO_INPUT],
      videoDeviceId: deviceIds[VIDEO_INPUT],
    });
  };

  return (
    <div className="lk-prejoin-wrapper" data-testid="prejoin" data-lk-theme="default">
      <div className="lk-prejoin">
        <div className="lk-video-container">
          {videoTrack ? (
            <video ref={videoEl} width="1280" height="720" data-lk-facing-mode={facingModeFromLocalTrack(videoTrack).facingMode} />
          ) : null}
          {!videoTrack || !videoEnabled ? (
            <div className="lk-camera-off-note">
              <ParticipantPlaceholder />
            </div>
          ) : null}
        </div>
        <div className="lk-button-group-container">
          <div className="lk-button-group audio">
            <TrackToggle initialState={audioEnabled} source={Track.Source.Microphone} onChange={setAudioEnabled}>
              Microphone
            </TrackToggle>
            <div className="lk-button-group-menu">
              {audioTrack ? (
                <PreviewDeviceMenu
                  kind={AUDIO_INPUT}
                  ariaLabel="Choisir le micro"
                  activeDeviceId={deviceIds[AUDIO_INPUT]}
                  onSelect={choose(AUDIO_INPUT)}
                  onError={onError}
                />
              ) : (
                <DeviceMenu ariaLabel="Choisir le micro" devices={[]} disabled />
              )}
            </div>
          </div>
          <div className="lk-button-group video">
            <TrackToggle initialState={videoEnabled} source={Track.Source.Camera} onChange={setVideoEnabled}>
              Caméra
            </TrackToggle>
            <div className="lk-button-group-menu">
              {videoTrack ? (
                <PreviewDeviceMenu
                  kind={VIDEO_INPUT}
                  ariaLabel="Choisir la caméra"
                  activeDeviceId={deviceIds[VIDEO_INPUT]}
                  onSelect={choose(VIDEO_INPUT)}
                  onError={onError}
                />
              ) : (
                <DeviceMenu ariaLabel="Choisir la caméra" devices={[]} disabled />
              )}
            </div>
          </div>
        </div>
        <form className="lk-username-container" onSubmit={handleSubmit}>
          <input
            className="lk-form-control"
            id="username"
            name="username"
            type="text"
            value={username}
            placeholder="Nom affiché (facultatif)"
            onChange={(event) => saveUsername(event.target.value)}
            autoComplete="off"
          />
          <button className="lk-button lk-join-button" type="submit" disabled={!canJoin}>
            Rejoindre la salle
          </button>
        </form>
      </div>
    </div>
  );
}
