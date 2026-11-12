# Replay d'un direct terminé, réservé aux personnes identifiées
# (ReplayAccess) : un compte voit tous les replays publiés, une
# inscription confirmée celui de son webinaire.
#
# `recording` = la vidéo de référence, le composite de la séance : son
# horloge (started_at → ended_at) cale les sous-titres et borne les
# positions des battements du lecteur. Choisie à la publication, comme le
# dépôt Nextcloud choisit sa vidéo principale : le composite terminé le plus
# long, pas la répétition ni un reliquat.
#
# `derived_path` = copie de diffusion facultative (720p, produite hors de
# l'application), relative à RECORDINGS_ROOT et rangée sous
# `_replays/<slug>/` : le montage piloté par la parole (ReplayMontage), dont
# le temps 0 est le `started_at` de la vidéo de référence. Présente sur
# disque, elle remplace le composite à la lecture ; absente, le composite est
# servi. Les sous-titres et les statistiques gardent la même horloge.
#
# Publication = geste de l'animation (WebinarReplaysController) : le
# composite peut montrer un écran partagé, il est relu avant d'être ouvert.
class Replay < ApplicationRecord
  DERIVED_SUBDIR = "_replays"
  DERIVED_EXTENSIONS = %w[.mp4].freeze

  belongs_to :webinar, inverse_of: :replay
  belongs_to :recording
  has_many :views, class_name: "ReplayView", dependent: :delete_all, inverse_of: :replay

  validates :webinar_id, uniqueness: true
  validate :recording_is_the_webinar_composite
  validate :derived_path_under_replays_root, if: -> { derived_path.present? }

  scope :published, -> { where.not(published_at: nil) }

  # Le composite terminé, au fichier présent, le plus long ; nil sans lui.
  def self.reference_recording_for(webinar)
    webinar.recordings.composite.done.select(&:downloadable?)
           .select { |recording| recording.started_at && recording.ended_at }
           .max_by { |recording| recording.ended_at - recording.started_at }
  end

  # Replay de `webinar`, créé non publié sur sa vidéo de référence s'il
  # n'existe pas encore (publication, montage).
  # @return [Replay, nil] nil si le webinaire n'a pas de composite lisible
  def self.prepare!(webinar)
    replay = webinar.replay || webinar.build_replay(recording: reference_recording_for(webinar))
    return nil if replay.recording.nil? || !replay.recording.downloadable?

    replay.save! if replay.new_record?
    replay
  end

  # Publie (ou republie) le replay de `webinar`, sur sa vidéo de référence.
  # Une republication garde la vidéo déjà choisie et la copie de diffusion.
  # @return [Replay, nil] nil si le webinaire n'a pas de composite lisible
  def self.publish!(webinar, now: Time.current)
    replay = prepare!(webinar)
    replay&.update!(published_at: replay.published_at || now)
    replay
  end

  def unpublish!
    update!(published_at: nil)
  end

  def published?
    published_at.present?
  end

  # Durée de la vidéo de référence, en secondes.
  def duration
    recording.ended_at - recording.started_at
  end

  # Instant de la vidéo, en secondes, d'un horodatage du direct (négatif
  # avant le début du composite) : l'horloge des sous-titres, des sondages
  # (ReplayPoll) et des questions posées depuis le replay.
  def video_second(time)
    (time - recording.started_at).to_f
  end

  # Même instant, borné à la vidéo : où placer un chapitre, un résultat de
  # recherche ou le départ demandé par `?instant=`.
  def offset_of(time)
    video_second(time).clamp(0.0, duration.to_f)
  end

  # Fichier lu par le lecteur : la copie de diffusion si elle est sur
  # disque, sinon le composite. nil si aucun des deux n'est lisible.
  # @return [Pathname, nil]
  def video_file
    derived = derived_file
    return derived if derived&.file?

    source = recording.absolute_path
    source if source&.file?
  end

  # Sous-titres WebVTT de la transcription, calés sur la vidéo de référence.
  def subtitles_vtt
    TranscriptExport.new(webinar.transcript_segments.chronological)
                    .vtt(origin: recording.started_at, finish: recording.ended_at)
  end

  def subtitles?
    webinar.transcript_segments.exists?
  end

  # Chemin absolu de la copie de diffusion, présente ou non sur disque ; nil
  # sans copie annoncée, hors de `_replays/<slug>/` ou d'une autre extension
  # que DERIVED_EXTENSIONS. Même défense que
  # Recording#absolute_path : le chemin stocké est relatif, résolu puis
  # revérifié. Lu par la lecture, la validation de `derived_path` et la purge
  # de rétention.
  # @return [Pathname, nil]
  def derived_file
    return nil if derived_path.blank?

    resolved = Recording.recordings_root.join(derived_path).cleanpath
    resolved if resolved.to_s.start_with?("#{derived_root}/") && DERIVED_EXTENSIONS.include?(resolved.extname)
  end

  private

  def derived_root
    Recording.recordings_root.join(DERIVED_SUBDIR, webinar.slug).cleanpath
  end

  def recording_is_the_webinar_composite
    return if recording.nil?

    errors.add(:recording, :not_composite, message: "doit être un composite de ce webinaire") unless
      recording.composite? && recording.webinar_id == webinar_id
  end

  def derived_path_under_replays_root
    return if derived_file

    errors.add(:derived_path, :outside_root,
               message: "doit être une vidéo .mp4 sous #{DERIVED_SUBDIR}/#{webinar.slug}/")
  end
end
