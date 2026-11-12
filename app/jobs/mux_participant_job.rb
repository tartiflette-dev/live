# frozen_string_literal: true

# MuxParticipantJob — produit les Recordings synthétiques `kind='participant'`
# d'une personne : vidéo caméra + audio micro recalés et muxés.
#
# Déclenché :
#   • par FinalizeEgressJob dès qu'une piste `track` passe en terminal
#     (done|failed) ET que TOUTES les pistes de la personne sont
#     terminales (pas d'actives résiduelles) — cas nominal webhook ;
#   • par LiveEnding (fin de direct) pour chaque participant qui a au
#     moins une piste `done` — filet (une personne dont la dernière piste
#     a `failed` sans webhook aboutit quand même) ;
#   • à la main, `bin/rails "recordings:montages[<slug>,<identité>]"`.
#
# UN MONTAGE PAR LOT : chaque
# montage retient le lot qu'il COUVRE (`source_track_ids`) — les pistes
# `done` de la personne qu'il a prises en compte. Il en assemble au plus
# une caméra et un micro (ParticipantMux : la plus récente non vide de
# chaque source) ; les autres sont couvertes sans être assemblées (piste
# vide, segment remplacé) et ne relancent pas de montage. Une personne
# qui a de nouvelles pistes `done` hors de tout lot (répétition puis
# séance, direct terminé puis repris) reçoit un NOUVEAU montage de ces
# seules pistes, sous un nom distinct ; l'ancien fichier n'est jamais
# touché. Avant, le job s'arrêtait au premier montage réussi : la séance
# de speaker-9 n'a jamais été montée.
#
# Idempotent : un lot déjà monté (fichier présent) n'est pas refait. Un
# montage non abouti (failed, fichier manquant, job mort en cours de
# route) est relancé sur SON lot, par un seul job à la fois.
#
# Reconstruction (`rebuild: true`, tâche `recordings:montages[…,refaire]`) :
# les lots déjà montés de la personne sont refaits aussi, sous le même nom
# (ParticipantMux écrit à côté puis renomme : l'ancien fichier reste en place
# jusqu'au succès, et reste sur disque si la reconstruction échoue ; le
# montage passe alors `failed` et n'est plus proposé au téléchargement ni au
# dépôt ; une copie déjà déposée dans Nextcloud y reste mais sort du README
# au dépôt suivant ;
# une relance sans `rebuild` le refait). Sert à appliquer un nouveau calage
# aux montages existants.
#
# Fail-loud : toute erreur du service est persistée (status=failed +
# error_message) sur le Recording participant — jamais avalée.
#
# Montage avec réserve : si une piste est vide, le montage se fait avec
# l'autre ; si le début réel d'un fichier est inconnu, le calage est
# approximatif. Le montage est `done` et `error_message` porte la note du
# service (cf. Recording#caveat?) ; track_source dit ce qui a réellement été
# muxé.
class MuxParticipantJob < ApplicationJob
  queue_as :default

  # Au-delà, un montage resté `starting` n'a plus de job vivant : ffmpeg est
  # tué à ParticipantMux::TIMEOUT_SECONDS ; la marge couvre vingt sondes
  # ffprobe (TrackProbe::TIMEOUT_SECONDS chacune, une par piste examinée).
  # Un job mort ne fait qu'attendre plus longtemps avant d'être relayé.
  STALE_AFTER = (ParticipantMux::TIMEOUT_SECONDS + 20 * TrackProbe::TIMEOUT_SECONDS).seconds

  # Fabrication du service — SEAM de test (le test substitue cette
  # méthode via `define_singleton_method`). En prod : constructeur réel.
  def self.build_mux(webinar:, identity:, track_ids:)
    ParticipantMux.new(webinar: webinar, identity: identity, track_ids: track_ids)
  end

  # Deux webhooks terminant presque simultanément pour la même personne
  # (caméra et micro qui s'arrêtent ensemble) planifient deux jobs. Un seul
  # assemble chaque lot : la création d'un lot est arbitrée par l'index
  # unique (webinaire, identité, lot), la relance d'un lot par `claim`.
  def perform(webinar_id, identity, rebuild: false)
    webinar = Webinar.find_by(id: webinar_id)
    return if webinar.nil?

    identity = identity.to_s
    return if identity.blank?

    # Fenêtre d'exécution : aucune piste de la personne encore active.
    tracks = webinar.recordings.tracks.where(participant_identity: identity)
    return if tracks.where(status: Recording::ACTIVE_STATUSES).exists?

    muxes = webinar.recordings.participants.where(participant_identity: identity).to_a
    muxes.each { |mux| assemble(webinar, identity, mux) if claim(mux, rebuild: rebuild) }

    new_track_ids = tracks.where(status: "done").ids - muxes.flat_map { |mux| mux.source_track_ids.to_a }
    return if new_track_ids.empty?

    mux = create_mux(webinar, identity, new_track_ids.sort)
    assemble(webinar, identity, mux) if mux
  end

  private

  # Revendique la relance d'un montage non abouti. La relecture sous verrou
  # (transaction IMMEDIATE de SQLite, qui sérialise les écritures) fait que
  # de deux jobs concurrents, le second voit le montage déjà `starting` et
  # ne lance pas un second ffmpeg sur le même lot.
  def claim(mux, rebuild:)
    mux.with_lock do
      next false unless relaunchable?(mux, rebuild: rebuild)

      mux.update!(status: :starting, started_at: Time.current, error_message: nil)
      true
    end
  end

  def relaunchable?(mux, rebuild:)
    return false if mux.downloadable? && !rebuild

    !mux.starting? || mux.started_at.nil? || mux.started_at < STALE_AFTER.ago
  end

  def assemble(webinar, identity, mux)
    result = self.class.build_mux(webinar: webinar, identity: identity, track_ids: mux.source_track_ids.to_a).call

    mux.update!(
      status:        :done,
      path:          result.relative_path,
      ended_at:      Time.current,
      track_source:  result.track_source,
      error_message: result.note
    )
  rescue ParticipantMux::Error => error
    Rails.logger.error(
      "[mux_participant] webinar=#{webinar.slug} identity=#{identity} recording=#{mux.id} err=#{error.class}: #{error.message}"
    )
    mux.update!(
      status:        :failed,
      error_message: "Mux participant échoué : #{error.message}",
      ended_at:      Time.current
    )
  end

  # nil = un job concurrent a créé ce lot à l'instant : il le monte.
  def create_mux(webinar, identity, track_ids)
    webinar.recordings.create!(
      kind:                 :participant,
      status:               :starting,
      participant_identity: identity,
      source_track_ids:     track_ids,
      started_at:           Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
