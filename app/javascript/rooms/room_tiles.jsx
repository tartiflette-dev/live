// This file adapts the ParticipantTile component of @livekit/components-react 2.9
// (Copyright 2023 LiveKit, Inc., Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0).
// Changes: the screen-share label is localised, and spotlight and consent markers are
// rendered by a portal into the root node of a camera tile. The Apache-2.0 terms apply to
// the parts that derive from the original. Licence of the file (REUSE.toml):
// AGPL-3.0-only WITH LicenseRef-Live-AGPL-3.0-Terms AND Apache-2.0; additional terms
// under AGPL-3.0 section 7 apply: see ADDITIONAL_TERMS.md.
//
// Tuiles, mosaïque et mode focus de la salle (scène et spectateur).
//
// MosaicGrid remplace GridLayout vendor : ses dispositions ne dépendent que
// du nombre de pistes (3 caméras en 2×2 dans une fenêtre large et basse,
// case vide, vidéos minuscules).
// Ici la zone est mesurée et mosaic_layout.js choisit colonnes et rangées.
//
// FocusStage remplace FocusLayoutContainer + CarouselLayout vendor : leur
// grille 1fr/5fr posait la vignette caméra en haut d'une colonne large,
// avec un grand vide dessous, et laissait le partage d'écran dans ce qui
// restait (partage en cours). Ici : une grande
// tuile qui remplit la zone, et une bande compacte de vignettes — à
// droite par défaut, en bas quand la zone vidéo est au plus en 3:2
// (room.css, `.lk-focus-stage`).

import { useCallback, useLayoutEffect, useState } from "react";
import { createPortal } from "react-dom";
import {
  ConnectionQualityIndicator,
  ParticipantPlaceholder,
  ParticipantTile,
  ScreenShareIcon,
  TrackLoop,
  VideoTrack,
  isTrackReference,
  useEnsureTrackRef,
  useParticipantInfo,
} from "@livekit/components-react";
import { Track } from "livekit-client";
import { SpotlightMarker } from "./spotlight";
import { ConsentPendingMarker } from "./participant_consent";
import { MOSAIC_MODES, mosaicLayout } from "./mosaic_layout";

// Préférence d'affichage mémorisée par appareil, propre à la personne :
// elle ne change rien chez les autres. Valeur absente ou inconnue :
// `values[0]`. Stockage refusé (mode privé) : le choix vaut pour la session.
function useDevicePreference(key, values) {
  const [value, setValue] = useState(() => {
    try {
      const stored = window.localStorage?.getItem(key);
      return values.includes(stored) ? stored : values[0];
    } catch (_err) {
      return values[0];
    }
  });
  const choose = useCallback((next) => {
    setValue(next);
    try {
      window.localStorage?.setItem(key, next);
    } catch (_err) {
      // Mode privé / stockage refusé : le choix vaut pour la session.
    }
  }, [key]);
  return [value, choose];
}

// Côté de la bande de vignettes sur la scène. Droite par défaut : l'animateur se
// regarde du côté où est sa caméra.
const STRIP_SIDES = ["right", "left"];

export function useStripSide() {
  const [side, setSide] = useDevicePreference("undust-live:focus-strip-side", STRIP_SIDES);
  const toggle = useCallback(() => setSide(side === "left" ? "right" : "left"), [side, setSide]);
  return [side, toggle];
}

// Disposition de la mosaïque choisie sur la scène (MOSAIC_MODES), « Auto »
// par défaut.
const MOSAIC_MODE_IDS = MOSAIC_MODES.map((mode) => mode.id);

export function useMosaicMode() {
  return useDevicePreference("undust-live:mosaic-mode", MOSAIC_MODE_IDS);
}

// Tuile de la salle : la tuile LiveKit standard, avec deux ajouts.
//   - Partage d'écran : libellé « Écran de <nom> » (vendor écrit
//     « <nom>'s screen » en dur). Contenu repris de ParticipantTile 2.9,
//     mêmes éléments dans le même ordre ; seul le libellé change.
//   - Caméra, quand `spotlight` est fourni (scène) : marqueurs de mise en
//     avant et d'attente d'accord à l'image, rendus DANS la tuile par un
//     portail sur son nœud racine (ref publique de ParticipantTile). La
//     structure de la tuile ne change pas, ni les règles de room.css qui
//     comptent ses div.
export function RoomTile({ trackRef, spotlight }) {
  const track = useEnsureTrackRef(trackRef);
  const [tileElement, setTileElement] = useState(null);
  if (track.source === Track.Source.ScreenShare) {
    return (
      <ParticipantTile trackRef={trackRef}>
        <ScreenShareContent track={track} />
      </ParticipantTile>
    );
  }
  const marker = spotlight && track.source === Track.Source.Camera ? (
    <>
      <SpotlightMarker participant={track.participant} spotlight={spotlight} />
      <ConsentPendingMarker participant={track.participant} />
    </>
  ) : null;
  return (
    <>
      <ParticipantTile trackRef={trackRef} ref={setTileElement} />
      {marker && tileElement ? createPortal(marker, tileElement) : null}
    </>
  );
}

// Jamais l'identité technique à l'écran (elle porte l'identifiant OIDC) :
// sans nom affiché, « Partage d'écran ».
function ScreenShareContent({ track }) {
  const { name } = useParticipantInfo({ participant: track.participant });
  return (
    <>
      {isTrackReference(track) ? <VideoTrack trackRef={track} /> : null}
      <div className="lk-participant-placeholder">
        <ParticipantPlaceholder />
      </div>
      <div className="lk-participant-metadata">
        <div className="lk-participant-metadata-item">
          <ScreenShareIcon className="lk-room-tile__share-icon" />
          <span className="lk-participant-name">{name ? `Écran de ${name}` : "Partage d'écran"}</span>
        </div>
        <ConnectionQualityIndicator className="lk-participant-metadata-item" />
      </div>
    </>
  );
}

// Mode focus : `focusTrack` en grand, `otherTracks` en vignettes dans la
// bande. `onToggleSide` absent (spectateur) : pas de bascule, bande à
// droite comme sur la scène par défaut.
export function FocusStage({ focusTrack, otherTracks, spotlight, side = "right", onToggleSide }) {
  const otherSide = side === "left" ? "droite" : "gauche";
  return (
    <div className="lk-focus-stage" data-side={side} data-testid="focus-stage">
      <div className="lk-focus-stage__main">
        <RoomTile trackRef={focusTrack} spotlight={spotlight} />
      </div>
      <div className="lk-focus-stage__strip" data-testid="focus-strip">
        <TrackLoop tracks={otherTracks}>
          <RoomTile spotlight={spotlight} />
        </TrackLoop>
        {onToggleSide ? (
          <button
            type="button"
            className="lk-focus-stage__side"
            data-testid="strip-side-toggle"
            aria-label={`Placer les vignettes à ${otherSide}`}
            title={`Vignettes à ${otherSide}`}
            onClick={onToggleSide}
          >
            <svg viewBox="0 0 16 16" aria-hidden="true">
              <path d="M2 5h10M9 2l3 3-3 3M14 11H4M7 8l-3 3 3 3" />
            </svg>
          </button>
        ) : null}
      </div>
    </div>
  );
}

// Espace entre les tuiles, avec les bords de la zone et avec le sélecteur,
// en px : le calcul et la feuille de style (`--mosaic-gap`) lisent cette
// seule valeur.
const MOSAIC_GAP = 8;

// Taille intérieure d'un élément (clientWidth × clientHeight : marges
// internes comprises : la place réservée au sélecteur ne la change donc
// pas ; bordure exclue), suivie au redimensionnement ; undefined tant que
// l'élément n'est pas monté. Renvoie [ref à poser sur l'élément, taille].
// Ref callback : un élément monté ou remplacé après coup est observé.
// Première mesure avant l'affichage (useLayoutEffect) : pas d'image sans
// tuiles au montage.
function useElementSize() {
  const [element, setElement] = useState(null);
  const [size, setSize] = useState();
  useLayoutEffect(() => {
    if (!element) {
      setSize(undefined);
      return undefined;
    }
    const measure = () => {
      const width = element.clientWidth;
      const height = element.clientHeight;
      setSize((previous) => (previous?.width === width && previous?.height === height ? previous : { width, height }));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [element]);
  return [setElement, size];
}

// Mosaïque (mode grille) : toutes les tuiles visibles, à la même taille
// 16:9, la plus grande que permet la zone ; aucune pagination, aucun
// défilement. La dernière rangée incomplète est centrée (room.css).
//
// `onModeChange` fourni (scène) : sélecteur « Mosaïque » en haut à droite
// de la zone, dans la marge des tuiles quand elle suffit, sinon au-dessus
// ou à côté d'elles (mosaic_layout.js, `corner`) — jamais sur une tuile.
// Il n'existe qu'en mode grille : le mode focus ne monte pas MosaicGrid.
export function MosaicGrid({ tracks, mode, onModeChange, spotlight }) {
  const [zoneRef, zone] = useElementSize();
  const [pickerRef, picker] = useElementSize();
  const layout = zone && mosaicLayout({
    count: tracks.length,
    width: zone.width,
    height: zone.height,
    gap: MOSAIC_GAP,
    mode,
    corner: picker,
  });
  return (
    <div
      ref={zoneRef}
      className="lk-mosaic"
      data-testid="mosaic"
      data-columns={layout?.columns}
      data-rows={layout?.rows}
      style={{ "--mosaic-top": `${layout?.top ?? 0}px`, "--mosaic-right": `${layout?.right ?? 0}px` }}
    >
      {onModeChange ? <MosaicPicker ref={pickerRef} mode={mode} onChange={onModeChange} /> : null}
      {layout ? (
        <div
          className="lk-mosaic__tiles"
          style={{
            "--mosaic-gap": `${MOSAIC_GAP}px`,
            "--mosaic-columns": layout.columns,
            "--mosaic-tile-width": `${layout.tileWidth}px`,
            "--mosaic-tile-height": `${layout.tileHeight}px`,
          }}
        >
          <TrackLoop tracks={tracks}>
            <RoomTile spotlight={spotlight} />
          </TrackLoop>
        </div>
      ) : null}
    </div>
  );
}

// Liste déroulante native : clavier et lecteur d'écran sans code en plus,
// une seule commande compacte. Le choix est LOCAL à la personne et
// mémorisé sur son appareil (useMosaicMode).
function MosaicPicker({ ref, mode, onChange }) {
  return (
    <label ref={ref} className="lk-mosaic-picker" data-testid="mosaic-picker">
      <span>Mosaïque</span>
      <select
        className="lk-mosaic-picker__select"
        value={mode}
        onChange={(event) => onChange(event.target.value)}
      >
        {MOSAIC_MODES.map(({ id, label }) => (
          <option key={id} value={id}>{label}</option>
        ))}
      </select>
    </label>
  );
}
