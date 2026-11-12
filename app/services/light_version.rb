# frozen_string_literal: true

# LightVersion — version légère d'un enregistrement (H.264 réencodé), déposée
# dans Nextcloud à la place de l'original. L'original reste sur disque, jamais
# modifié.
#
# Produite HORS de l'application (mémoire du conteneur, Puma) par un moteur
# externe, non distribué avec l'application, lancé hors direct sur l'hôte
# des enregistrements (docs/replays.md, « Rendus hors de l'application »).
# Contrat par fichiers, relatifs à RECORDINGS_ROOT :
#   _leger/demandes/<recording id>.json   demande, écrite ici (`request!`) ;
#   <output>                              version légère, n'apparaît que vérifiée ;
#   <output>.json                         marqueur du moteur : `done`, ou
#                                         `original` (gain trop faible, contrôle
#                                         raté : on dépose l'original ; `cause`
#                                         `gain_insuffisant` ou `erreur`, cette
#                                         dernière à signaler).
# Demande et marqueur portent la taille de l'original : un assemblage refait
# (autre taille) périme les deux, et la version légère est refaite.
#
# Seules les vidéos H.264 (.mp4) sans écran partagé sont réencodées : le
# composite (CRF 26), les assemblages et les caméras (CRF 23). Le composite
# n'a qu'un dérivé, rangé sous `_replays/<slug>/` : c'est aussi la copie de
# diffusion du replay (Replay#derived_path), pas une seconde copie.
#
# Activé par PUBLICATION_LIGHT_VERSIONS=1 ; sans lui, tout est déposé en
# original, comme avant.
class LightVersion
  QUEUE_DIR = "_leger/demandes"
  LIGHT_DIR = "_leger"
  REPLAY_DIR = "_replays"
  # Au-delà, une version légère pas encore prête ne retient plus le dépôt
  # automatique : l'original part (EpisodePublication.automatic_hold).
  WAIT = 6.hours
  MAX_HEIGHT = 1080
  COMPOSITE_CRF = 26
  CAMERA_CRF = 23

  def self.enabled?
    ENV["PUBLICATION_LIGHT_VERSIONS"] == "1"
  end

  # nil si l'enregistrement ne se réencode pas (écran partagé, son seul, VP8).
  def self.for(recording)
    new(recording) if eligible?(recording)
  end

  def self.eligible?(recording)
    return false unless recording.downloadable? && recording.extension == ".mp4"

    recording.composite? || recording.participant? || (recording.track? && recording.track_source == "camera")
  end

  attr_reader :recording

  def initialize(recording)
    @recording = recording
  end

  # Chemin de la version légère vérifiée ; nil tant qu'elle n'est pas prête.
  # @return [Pathname, nil]
  def file
    output if ready?
  end

  def ready?
    marker["status"] == "done" && current?(marker) && output.file? && output.size == marker["output_size"]
  end

  # Réglée : prête, ou écartée par le moteur (l'original sera déposé).
  def settled?
    current?(marker) && %w[done original].include?(marker["status"])
  end

  # Le dépôt automatique l'attend : ni réglée, ni demandée depuis plus de WAIT.
  def waiting?(now = Time.current)
    return false if settled?

    requested_at = Time.zone.parse(request["requested_at"].to_s) if current?(request)
    requested_at.nil? || requested_at > now - WAIT
  end

  # Écrit la demande (remplacement atomique) ; une demande à jour est gardée.
  def request!(now = Time.current)
    return if output.nil? || current?(request)

    write_json(request_path, recording_id: recording.id, source: recording.path, output: output_relative,
                             crf: recording.composite? ? COMPOSITE_CRF : CAMERA_CRF, max_height: MAX_HEIGHT,
                             source_size: source_size, requested_at: now.utc.iso8601)
  end

  # Purge de rétention : version légère, marqueur et demande. Rend le nombre
  # de fichiers supprimés.
  def purge!
    [ output, marker_path, request_path ].count do |path|
      File.delete(path) if path&.file?
    rescue Errno::ENOENT
      false
    end
  end

  private

  def root
    Recording.recordings_root.cleanpath
  end

  def output_relative
    return if recording.path.blank?
    return "#{REPLAY_DIR}/#{recording.webinar.slug}/#{File.basename(recording.path)}" if recording.composite?

    "#{LIGHT_DIR}/#{recording.path}"
  end

  # Résolu puis revérifié sous `_leger/` ou `_replays/<slug>/`, comme
  # Recording#absolute_path : un chemin forgé ne sort pas de ces dossiers.
  def output
    relative = output_relative
    return if relative.nil? || recording.absolute_path.nil?

    resolved = root.join(relative).cleanpath
    allowed = [ root.join(LIGHT_DIR), root.join(REPLAY_DIR, recording.webinar.slug) ]
    resolved if allowed.any? { |dir| resolved.to_s.start_with?("#{dir.cleanpath}/") }
  end

  def marker_path
    output&.then { |path| path.sub_ext("#{path.extname}.json") }
  end

  def request_path
    root.join(QUEUE_DIR, "#{recording.id}.json")
  end

  def source_size
    @source_size ||= recording.size_on_disk
  end

  def current?(entry)
    entry["source_size"].present? && entry["source_size"] == source_size
  end

  def marker
    @marker ||= read_json(marker_path)
  end

  def request
    @request ||= read_json(request_path)
  end

  def read_json(path)
    return {} unless path&.file?

    JSON.parse(path.read)
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def write_json(path, data)
    FileUtils.mkdir_p(path.dirname)
    tmp = path.dirname.join(".#{path.basename}.#{SecureRandom.hex(4)}.tmp")
    tmp.write("#{JSON.generate(data)}\n")
    File.rename(tmp, path)
    @request = nil
  end
end
