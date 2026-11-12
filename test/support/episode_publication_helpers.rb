# frozen_string_literal: true

# Publication Nextcloud des épisodes : faux
# client en mémoire (même contrat que NextcloudClient) et fabrique d'un
# épisode terminé avec ses fichiers sur disque. Les épisodes de test sont
# datés du 17/01/2030 : aucun dossier réel ne porte ce nom.
class FakeNextcloud
  attr_reader :folders, :stored, :uploads, :moves, :versions
  attr_writer :fail_once_on

  # `fail_once_on` : le premier dépôt dont le chemin contient ce texte lève
  # une panne passagère. `truncate_on` : ce dépôt est tronqué d'un octet
  # (taille relue fausse). `after_store` : appelé après chaque dépôt.
  # `shares` : partages par chemin de nœud ; `permissions` : celles de
  # chaque dossier (WebDAV `oc:permissions`).
  def initialize(fail_once_on: nil, truncate_on: nil, after_store: nil, shares: {}, permissions: "RGDNVCK")
    @folders = []
    @stored = {}
    @uploads = []
    @moves = []
    @versions = Hash.new { |hash, path| hash[path] = [] }
    @fail_once_on = fail_once_on
    @truncate_on = truncate_on
    @after_store = after_store
    @shares = shares
    @permissions = permissions
  end

  def ensure_folder(path)
    segments = path.split("/")
    segments.each_index { |last| @folders |= [ segments[0..last].join("/") ] }
  end

  def size_of(path)
    @stored[path]&.bytesize
  end

  def permissions_of(path)
    @permissions if @folders.include?(path)
  end

  def shares_of(path)
    @shares.fetch(path, [])
  end

  def shares_under(path)
    @shares.select { |node, _| node == path || node.start_with?("#{path}/") }.values.flatten
  end

  def move(from, to)
    raise NextcloudClient::Error, "Nextcloud a répondu HTTP 404 à MOVE" unless @stored.key?(from)
    raise NextcloudClient::Error, "Nextcloud a répondu HTTP 409 à MOVE" unless @folders.include?(File.dirname(to))

    @moves << [ from, to ]
    @stored[to] = @stored.delete(from)
    @versions[to] = @versions.delete(from) || []
  end

  def purge_old_versions(path)
    @versions.delete(path)
  end

  # Le relecteur remplace le fichier sous le même nom (coupe) : Nextcloud
  # garde l'ancien contenu en version.
  def replace_as_reviewer(path, content)
    @versions[path] << @stored.fetch(path)
    @stored[path] = content
  end

  def internal_link(path)
    raise NextcloudClient::Error, "dossier introuvable après dépôt" unless @folders.include?(path)

    path.start_with?("Relecture/") ? "https://cloud.test/f/7777" : "https://cloud.test/f/4242"
  end

  def put_content(path, content)
    store(path, content)
  end

  def upload_file(path, local_path)
    store(path, File.binread(local_path))
  end

  private

  def store(path, content)
    if @fail_once_on && path.include?(@fail_once_on)
      @fail_once_on = nil
      raise NextcloudClient::TransientError, "Nextcloud a répondu HTTP 503 à PUT"
    end
    raise NextcloudClient::Error, "Nextcloud a répondu HTTP 409 à PUT" unless @folders.include?(File.dirname(path))

    @uploads << path
    @stored[path] = @truncate_on && path.include?(@truncate_on) ? content[0...-1] : content.dup
    @after_store&.call(path)
  end
end

module EpisodePublicationHelpers
  def with_nextcloud(client)
    previous = Rails.configuration.x.nextcloud_client_factory
    Rails.configuration.x.nextcloud_client_factory = -> { client }
    yield
  ensure
    Rails.configuration.x.nextcloud_client_factory = previous
  end

  def with_recordings_root
    previous = ENV["RECORDINGS_ROOT"]
    root = Dir.mktmpdir("episode-publication")
    ENV["RECORDINGS_ROOT"] = root
    yield Pathname.new(root)
  ensure
    ENV["RECORDINGS_ROOT"] = previous
    FileUtils.remove_entry(root) if root && File.directory?(root)
  end

  # Café IA terminé (sans enregistrement : add_recording les ajoute, fichier
  # écrit sur disque sous RECORDINGS_ROOT).
  def ended_cafe(slug: next_episode_slug, visibility: "published", kind: "cafe_ia",
                 started: Time.zone.parse("2030-01-17 09:40:47"), ended: Time.zone.parse("2030-01-17 10:28:30"))
    host = User.find_or_create_by!(oidc_sub: "publication-host") { |user| user.email = "marc@example.test" }
    Webinar.create!(title: "Café IA #7", slug: slug, room_name: slug, kind: kind, visibility: visibility,
                    starts_at: Time.zone.parse("2030-01-17 09:30"), host_sub: host.oidc_sub,
                    state: "ended", started_at: started, ended_at: ended)
  end

  def add_recording(webinar, kind:, file:, bytes: "x" * 32, status: "done", identity: nil, source: nil,
                    started: Time.zone.parse("2030-01-17 09:31:06"), ended: Time.zone.parse("2030-01-17 10:27:44"))
    prefix = kind == "participant" ? "#{Recording::PARTICIPANTS_SUBDIR}/#{webinar.slug}" : webinar.slug
    path = "#{prefix}/#{file}"
    absolute = Recording.recordings_root.join(path)
    FileUtils.mkdir_p(absolute.dirname)
    File.binwrite(absolute, bytes) if bytes
    webinar.recordings.create!(kind: kind, status: status, path: path, participant_identity: identity,
                               track_source: source, started_at: started, ended_at: ended)
  end

  def with_light_versions
    previous = ENV["PUBLICATION_LIGHT_VERSIONS"]
    ENV["PUBLICATION_LIGHT_VERSIONS"] = "1"
    yield
  ensure
    ENV["PUBLICATION_LIGHT_VERSIONS"] = previous
  end

  # Fait ce que fait le moteur externe des versions légères pour la demande de
  # `recording` (écrite au besoin) : version légère `content`, puis marqueur.
  def produce_light_version(recording, content)
    LightVersion.new(recording).request!
    request = JSON.parse(Recording.recordings_root.join("_leger/demandes/#{recording.id}.json").read)
    output = Recording.recordings_root.join(request.fetch("output"))
    FileUtils.mkdir_p(output.dirname)
    File.binwrite(output, content)
    File.write("#{output}.json", { status: "done", source_size: request.fetch("source_size"),
                                   output_size: content.bytesize }.to_json)
  end

  def next_episode_slug
    @episode_sequence = (@episode_sequence || 0) + 1
    "cafe-ia-#{@episode_sequence}"
  end

  def add_segment(webinar, text, at:, identity: "speaker-1", name: "Basile Delmas", seconds: 3)
    webinar.transcript_segments.create!(participant_identity: identity, speaker_name: name, text: text,
                                        started_at: at, ended_at: at + seconds, segment_id: SecureRandom.hex(6))
  end
end
