# frozen_string_literal: true

# EpisodeManifest — ce que la publication dépose pour un webinaire :
# les dossiers d'épisode et leurs fichiers,
# sur le modèle d'un premier dépôt fait à la main :
#
#   <dossier partagé>/<date>-<slug>/
#     README.md                          contenu et tableau des fichiers
#     video-complete-fin-10h27-64.srt    sous-titres (+ .vtt) du composite principal
#     <date>-<slug>-transcript.md        transcription horodatée par personne
#     <date>-<slug>-extraits.json        accord de chaque personne pour les extraits
#     assemblages/<personne>-73.mp4         caméra + micro recalés
#     pistes/<personne>-micro-fin-10h27-66.ogg
#     pistes/<personne>-camera-fin-10h27-65.mp4  seulement si aucun assemblage déposé ne la monte
#   <dossier de relecture>/<date>-<slug>/          à relire avant partage
#     video-complete-fin-10h27-64.mp4    composite
#     pistes/<personne>-partage-ecran-fin-10h13-71.mp4
#
# Une vidéo à relire (`review?`) garde le même nom relatif dans les deux
# dossiers : la valider, c'est la déplacer à la même place côté partagé.
#
# `fin-HHhMM` = heure de fin à Paris, fixée une fois la piste terminée ; le
# nombre final = id du Recording, il rend chaque nom unique et stable d'un
# dépôt à l'autre. Un assemblage ne porte que son id : il peut être refait
# (relance après échec) et son heure de fin changerait son nom, laissant
# l'ancien fichier en double. Seuls les enregistrements téléchargeables
# (terminés, fichier présent) sont déposés.
class EpisodeManifest
  SOURCE_NAMES = { "camera" => "camera", "microphone" => "micro",
                   "screen_share" => "partage-ecran", "screen_share_audio" => "son-ecran" }.freeze
  KIND_ORDER = { "composite" => 0, "participant" => 1, "track" => 2 }.freeze
  # Pistes partagées sans relecture ; toute autre source est relue.
  SHARED_SOURCES = %w[camera microphone].freeze

  # Fichier d'un enregistrement, déposé tel quel ou en version légère ;
  # terminé, il ne change plus (`immutable?`) : présent à la même taille, il
  # est déjà déposé.
  # Exception : un assemblage peut être refait sous le même nom (nouveau
  # calage, `recordings:montages[…,refaire]`), parfois à la même taille
  # (vidéo copiée, mêmes trames audio). Sa `version` (fin de son dernier
  # montage) est notée dès son dépôt vérifié (EpisodePublication#deposited_versions),
  # à défaut au dernier dépôt abouti : sans version notée ou d'une autre, il
  # est redéposé (EpisodePublisher#already_deposited?).
  # `path` : le fichier envoyé, sa version légère si elle est prête
  # (LightVersion), sinon l'original. Choisi une fois : taille et envoi
  # portent sur le même fichier.
  MediaFile = Data.define(:name, :recording, :path) do
    def immutable? = true
    def version = recording.participant? ? recording.ended_at&.utc&.iso8601(6) : nil

    # À relire avant partage : ce qui peut montrer un écran partagé. Le
    # composite le montre ; un assemblage n'a que caméra et micro
    # (ParticipantMux) ; une piste n'est partagée d'office que caméra ou micro.
    def review?
      return false if recording.participant?

      recording.composite? || !SHARED_SOURCES.include?(recording.track_source)
    end

    def size = File.size(path)
    def duration = recording.started_at && recording.ended_at && (recording.ended_at - recording.started_at)
    def upload_to(client, remote) = client.upload_file(remote, path.to_s)
  end

  # Fichier texte produit au moment du dépôt, réécrit à chaque dépôt.
  TextFile = Data.define(:name, :content) do
    def immutable? = false
    def version = nil
    def review? = false
    def size = content.bytesize
    def duration = nil
    def upload_to(client, path) = client.put_content(path, content)
  end

  # Accord d'une personne pour les extraits et shorts (ExcerptConsents).
  Consent = Data.define(:identity, :name, :status, :label, :history)

  attr_reader :webinar, :episode_name, :folder, :review_folder

  # Id du Recording dont un fichier déposé est tiré, lu dans son nom
  # (`media_name` finit toujours par `-<id><extension>`, les sous-titres
  # reprennent le nom de leur vidéo) ; nil pour la transcription, le README,
  # les accords.
  def self.recording_id(name)
    name[/-(\d+)\.[a-z0-9]+\z/i, 1]&.to_i
  end

  def initialize(webinar, series:)
    @webinar       = webinar
    @episode_name  = "#{webinar.starts_at.in_time_zone.to_date.iso8601}-#{numbered_slug}"
    @folder        = "#{series.folder}/#{@episode_name}"
    @review_folder = "#{series.review_folder}/#{@episode_name}"
  end

  # Ordre de dépôt : vidéos, puis transcription. Le README vient après
  # (`readme`) : il décrit ce qui est effectivement partagé.
  def files
    @files ||= media_files + transcript_files
  end

  # `shared` : fichiers de `files` présents dans le dossier partagé ;
  # `in_review` : des vidéos attendent la relecture.
  def readme(shared, in_review:)
    TextFile.new(name: "README.md", content: EpisodeReadme.new(self, shared, in_review: in_review).to_s)
  end

  # Versions légères des vidéos déposées (sans les caméras qu'un assemblage
  # déposé contient déjà) : ce que le dépôt automatique attend.
  def light_versions
    media_files.filter_map { |file| LightVersion.for(file.recording) }
  end

  def subfolders
    files.map { |file| File.dirname(file.name) }.uniq - [ "." ]
  end

  def live_duration
    webinar.ended_at - webinar.started_at if webinar.started_at && webinar.ended_at
  end

  # Enregistrements non déposés : en échec, encore en cours, fichier absent.
  # Une caméra écartée parce que son assemblage la contient n'en est pas une.
  def undeposited_count
    recordings.count { |recording| !recording.downloadable? }
  end

  def transcript_name
    "#{episode_name}-transcript.md"
  end

  # Source structurée des outils de montage, déposée avec le README qui en
  # donne la version lisible : une entrée par personne, rattachée par son
  # identité LiveKit à ses fichiers (pistes, assemblage), avec l'historique
  # de ses accords. nil sans personne à décrire.
  def excerpt_consents_file
    return if excerpt_consents.empty?

    files = media_files.group_by { |file| file.recording.participant_identity }
    people = excerpt_consents.map do |consent|
      { identity: consent.identity, name: consent.name, excerpts: consent.status, label: consent.label,
        history: consent.history.map do |given|
          { consented_at: given.consented_at.iso8601, withdrawn_at: given.withdrawn_at&.iso8601, excerpts: given.excerpts_accepted }
        end,
        files: files.fetch(consent.identity, []).map(&:name) }
    end
    TextFile.new(name: "#{episode_name}-extraits.json", content: "#{JSON.pretty_generate(webinar: webinar.slug, people: people)}\n")
  end

  # Accord de chaque personne de l'épisode pour les extraits et shorts : le
  # montage en exclut qui ne l'a pas donné, ou l'a retiré.
  def excerpt_consents
    @excerpt_consents ||= begin
      consents = ExcerptConsents.new(webinar)
      consents.identities.map do |identity|
        Consent.new(identity: identity, name: display_name(identity), status: consents.status(identity),
                    label: consents.label(identity), history: consents.history(identity))
      end
    end
  end

  private

  # Convention du dossier Cafe-IA : numéro d'épisode sur 3 chiffres
  # (`cafe-ia-7` → `cafe-ia-007`) ; tout autre slug reste tel quel.
  def numbered_slug
    prefix = webinar.kind.dasherize
    number = webinar.slug[/\A#{Regexp.escape(prefix)}-(\d+)\z/, 1]
    number ? format("%s-%03d", prefix, number.to_i) : webinar.slug
  end

  def recordings
    @recordings ||= webinar.recordings.unscope(:order).order(:started_at, :id).to_a
  end

  def media_files
    @media_files ||= recordings.select(&:downloadable?)
                               .reject { |recording| camera_in_deposited_mux?(recording) }
                               .map { |recording| media_file(recording) }
                               .sort_by { |file| [ KIND_ORDER.fetch(file.recording.kind), file.name ] }
  end

  # Une piste caméra montée dans un assemblage déposable n'est pas déposée en
  # plus : l'assemblage en recopie la vidéo à l'identique (ParticipantMux,
  # -c:v copy), recalée sur le micro. Montée = l'assemblage a gardé une image
  # (`track_source` contient camera) et son lot (`source_track_ids`) ne cite
  # que cette caméra : d'un lot à plusieurs caméras, ParticipantMux n'en
  # monte qu'une, sans dire laquelle, et toutes restent déposées. Le micro
  # reste déposé (son seul, léger). Si l'assemblage cesse d'être déposable
  # (refait puis en échec), la caméra revient au dépôt suivant.
  def camera_in_deposited_mux?(recording)
    recording.track? && recording.track_source == "camera" && mounted_camera_ids.include?(recording.id)
  end

  def mounted_camera_ids
    @mounted_camera_ids ||= recordings.select { |recording| recording.participant? && recording.downloadable? }
                                      .filter_map { |mux| sole_camera_of(mux) }.to_set
  end

  # L'id de la seule caméra du lot d'un assemblage qui a gardé une image ;
  # nil si l'assemblage est sans image ou si son lot cite plusieurs caméras.
  def sole_camera_of(mux)
    return unless mux.track_source.to_s.split("+").include?("camera")

    cameras = mux.source_track_ids.to_a.select { |id| camera_ids.include?(id) }
    cameras.first if cameras.one?
  end

  def camera_ids
    @camera_ids ||= recordings.select { |recording| recording.track? && recording.track_source == "camera" }.to_set(&:id)
  end

  def media_file(recording)
    light = LightVersion.for(recording) if LightVersion.enabled?
    MediaFile.new(name: media_name(recording), recording: recording, path: light&.file || recording.absolute_path)
  end

  def media_name(recording)
    return "assemblages/#{person(recording.participant_identity)}-#{recording.id}#{recording.extension}" if recording.participant?

    ending = "fin-#{(recording.ended_at || recording.updated_at).in_time_zone.strftime('%Hh%M')}-#{recording.id}#{recording.extension}"
    return "video-complete-#{ending}" if recording.composite?

    "pistes/#{person(recording.participant_identity)}-#{source_name(recording.track_source)}-#{ending}"
  end

  def source_name(source)
    SOURCE_NAMES.fetch(source.to_s) { source.to_s.parameterize.presence || "piste" }
  end

  def transcript_files
    segments = webinar.transcript_segments.chronological
    return [] unless segments.exists?

    export = TranscriptExport.new(segments)
    markdown = TextFile.new(name: transcript_name, content: export.markdown(title: webinar.title))
    video = main_video
    return [ markdown ] unless video

    stem   = video.name.delete_suffix(File.extname(video.name))
    window = { origin: video.recording.started_at, finish: video.recording.ended_at }
    [ markdown,
      TextFile.new(name: "#{stem}.srt", content: export.srt(**window)),
      TextFile.new(name: "#{stem}.vtt", content: export.vtt(**window)) ]
  end

  # Le composite le plus long : la séance, pas la répétition ni un reliquat.
  def main_video
    media_files.select { |file| file.recording.composite? && file.duration }.max_by(&:duration)
  end

  def person(identity)
    (@people ||= {})[identity] ||= display_name(identity.to_s).to_s.parameterize.presence || "inconnu"
  end

  # Intervenant ou spectateur à qui la parole a été donnée : son nom, suivi
  # de « non vérifié » pour une inscription jamais confirmée (identité
  # provisoire de l'accès immédiat, pierre tombale : nom saisi, adresse non
  # prouvée) ; animateur : la partie locale de son adresse (« camille ») ; sinon
  # le nom vu par le transcripteur, à défaut l'identité LiveKit.
  def display_name(identity)
    if (speaker_id = identity[/\Aspeaker-(\d+)\z/, 1])
      name = webinar.speakers.find_by(id: speaker_id)&.name
    elsif (registration_id = identity[/\Aviewer-(\d+)\z/, 1])
      registration = webinar.registrations.find_by(id: registration_id)
      name = registration && (registration.confirmed? ? registration.name : "#{registration.name} non vérifié")
    elsif (sub = identity[/\Ahost-(.+)\z/, 1])
      name = User.find_by(oidc_sub: sub)&.email&.split("@")&.first
    end
    name.presence || transcript_names[identity].presence || identity
  end

  def transcript_names
    @transcript_names ||= webinar.transcript_segments.where.not(speaker_name: [ nil, "" ])
                                 .group(:participant_identity).maximum(:speaker_name)
  end
end
