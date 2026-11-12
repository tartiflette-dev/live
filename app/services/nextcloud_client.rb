# frozen_string_literal: true

require "net/http"
require "erb"
require "json"

# Adaptateur WebDAV vers Nextcloud, seul point de
# l'application qui parle à Nextcloud.
#
# Contrat :
# - `ensure_folder(path)`        crée chaque niveau manquant (MKCOL) ;
# - `size_of(path)`              taille du fichier distant (PROPFIND), nil s'il n'existe pas ;
# - `internal_link(path)`        lien interne `/f/<fileid>` (ne s'ouvre que pour qui a déjà accès) ;
# - `put_content(path, string)`  dépose un petit fichier texte (PUT) ;
# - `upload_file(path, local)`   dépose un fichier local : PUT simple jusqu'à
#   `chunk_size`, au-delà upload par morceaux (chunking v2 : MKCOL du
#   dossier de transfert, PUT de chaque morceau lu en flux, DELETE de la
#   destination si elle existe, MOVE final) ;
# - `move(from, to)`             déplace un fichier (MOVE, remplace la destination) ;
# - `purge_old_versions(path)`   supprime les anciennes versions d'un fichier du
#   compte (historique Nextcloud), garde la courante, vérifie qu'il n'en reste pas ;
# - `shares_of(path)`            partages posés sur CE nœud (API OCS, ceux de
#   tous les comptes) — un partage d'un dossier parent n'y figure pas ;
# - `shares_under(path)`         partages des nœuds du compte posés sur ce
#   chemin ou en dessous, à toute profondeur (liste OCS du compte, filtrée) ;
# - `permissions_of(path)`       permissions WebDAV du nœud (`S` : partage
#   reçu, `M` : stockage monté), nil s'il n'existe pas.
# Les chemins sont relatifs à la racine du compte (`files/<username>/`).
#
# Erreurs : 408, 423, 429, 5xx et réseau -> TransientError (rejouable) ; le
# reste (401/403 droits, 404/409 parent absent, 507 espace) -> Error.
# Net::HTTP ne rejoue rien lui-même (`max_retries: 0`) : il renverrait un
# corps vide, le flux du fichier étant déjà lu ; c'est PublishEpisodeJob
# qui rejoue, en rouvrant le fichier.
# Suppressions : le dossier de transfert temporaire d'un upload par
# morceaux avorté, les anciennes versions d'une vidéo validée
# (`purge_old_versions`), et le fichier qu'un upload par morceaux va
# remplacer. Nextcloud 30 plante (HTTP 500, TypeError dans
# ChunkingV2Plugin::completeChunkedWrite) quand le MOVE final écrase un
# fichier existant dans un partage : la destination est donc supprimée
# juste avant (elle part dans la corbeille de son propriétaire ; l'original
# reste sur disque). Exige le droit de suppression sur le partage. MOVE ne
# sert sinon qu'à passer un fichier validé de la relecture au dossier partagé.
#
# Logs : verbe, code HTTP, durée. Jamais le mot de passe d'application,
# jamais le chemin (il porte les noms des participants).
class NextcloudClient
  class Error < StandardError; end
  class TransientError < Error; end

  USER_SHARE = 0
  # Bit OCS « peut repartager » : qui l'a peut ouvrir le nœud à d'autres.
  RESHARE_PERMISSION = 16
  SHARE_LABELS = { USER_SHARE => "partage à un utilisateur", 1 => "partage à un groupe", 3 => "lien public",
                   4 => "partage par e-mail", 6 => "partage fédéré", 7 => "partage à un cercle", 10 => "partage Talk" }.freeze

  # Partage d'un nœud : type OCS (`share_type`), destinataire (compte,
  # groupe, adresse ; vide pour un lien public), droits (`permissions`) et
  # chemin du nœud vu du compte (`/Relecture/Cafe-IA`).
  Share = Data.define(:type, :with, :permissions, :path) do
    def user? = type == USER_SHARE
    def reshare? = permissions.anybits?(RESHARE_PERMISSION)

    def label
      kind = SHARE_LABELS.fetch(type) { "partage de type #{type}" }
      reshare? ? "#{kind} avec repartage" : kind
    end
  end

  # Chunking v2 : morceaux de 5 Mio à 5 Gio (le dernier peut être plus petit).
  CHUNK_SIZE   = 64 * 1024 * 1024
  OPEN_TIMEOUT = 10
  # Le MOVE final fait assembler 1 à 2 Go côté serveur.
  READ_TIMEOUT = 600

  NAMESPACES = { "d" => "DAV:", "oc" => "http://owncloud.org/ns" }.freeze
  PROPFIND_BODY = <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:prop><d:getcontentlength/><d:getlastmodified/><oc:fileid/><oc:permissions/></d:prop>
    </d:propfind>
  XML

  # nil si l'une des trois variables manque : la publication est alors
  # désactivée (EpisodePublication.configured_for?).
  def self.from_env(env = ENV)
    url, username, app_password = env.values_at("NEXTCLOUD_URL", "NEXTCLOUD_USERNAME", "NEXTCLOUD_APP_PASSWORD")
    return nil if [ url, username, app_password ].any?(&:blank?)

    new(base_url: url, username: username, app_password: app_password)
  end

  attr_reader :base_url

  def initialize(base_url:, username:, app_password:, chunk_size: CHUNK_SIZE, logger: Rails.logger)
    @base_url     = base_url.chomp("/")
    @username     = username
    @app_password = app_password
    @chunk_size   = chunk_size
    @logger       = logger
  end

  def inspect
    "#<#{self.class.name} #{@base_url} user=#{@username}>"
  end

  def ensure_folder(path)
    segments = path.split("/")
    segments.each_index do |last|
      request(Net::HTTP::Mkcol, files_url(segments[0..last].join("/")), accept: [ 201, 405 ])
    end
  end

  def size_of(path)
    properties(path)&.fetch(:size)&.to_i
  end

  def permissions_of(path)
    properties(path)&.fetch(:permissions)
  end

  def internal_link(path)
    file_id = properties(path)&.fetch(:file_id)
    raise Error, "dossier introuvable après dépôt" if file_id.blank?

    "#{@base_url}/f/#{file_id}"
  end

  def put_content(path, content)
    request(Net::HTTP::Put, files_url(path), body: content)
  end

  def upload_file(path, local_path)
    size = File.size(local_path)
    if size <= @chunk_size
      File.open(local_path, "rb") { |file| request(Net::HTTP::Put, files_url(path), stream: ChunkReader.new(file, size)) }
    else
      upload_in_chunks(path, local_path, size)
    end
  end

  def move(from, to)
    request(Net::HTTP::Move, files_url(from), headers: { "Destination" => files_url(to), "Overwrite" => "T" },
                                              accept: [ 201, 204 ])
  end

  # Une version porte pour nom l'horodatage Unix de son écriture ; la
  # courante, celui de la dernière modification du fichier. Ce nom ne prouve
  # pas le contenu : une coupe déposée avec la date du brut (client qui
  # conserve la date locale) fait garder par Nextcloud 30 une entrée « T » à
  # la taille de la coupe dont le contenu vient du brut (sonde réelle).
  # Toutes les entrées sont donc supprimées, y
  # compris celle au nom de la courante : la suppression ne touche que
  # l'historique (files_versions), jamais le fichier vivant, et Nextcloud
  # reconstruit l'entrée courante depuis lui. Ensuite, au plus une entrée,
  # au nom et à la taille du fichier, et sans contenu stocké derrière (GET
  # 404 ; HEAD répond 200 même sans contenu, d'où le GET) ; sinon erreur,
  # et rien n'est déplacé.
  def purge_old_versions(path)
    found = properties(path)
    raise Error, "fichier introuvable (versions)" if found.nil? || found[:file_id].blank? || found[:size].blank?

    current    = version_name(found[:modified])
    collection = "#{@base_url}/remote.php/dav/versions/#{escape(@username)}/versions/#{found[:file_id]}"
    versions(collection).each do |version|
      raise Error, "nom de version inattendu" unless version[:name].match?(/\A\d+\z/)

      request(Net::HTTP::Delete, "#{collection}/#{version[:name]}", accept: [ 204, 404 ])
    end
    assert_versions_purged!(collection, current, found[:size])
  end

  def shares_of(path)
    ocs_shares(path: "/#{path}", reshares: "true")
  end

  # Sans `path`, l'API OCS liste tous les partages des nœuds du compte, y
  # compris ceux qu'un autre compte a posés (`reshares`).
  # Chemins comparés en Unicode NFC : Nextcloud peut rendre un nom accentué
  # sous une autre forme que la configuration.
  def shares_under(path)
    root = "/#{path}".unicode_normalize(:nfc)
    ocs_shares(reshares: "true").select do |share|
      node = share.path.unicode_normalize(:nfc)
      node == root || node.start_with?("#{root}/")
    end
  end

  # Lecture bornée d'un fichier ouvert : Net::HTTP copie le corps d'un
  # morceau par `read` jusqu'à nil, sans le charger en mémoire.
  class ChunkReader
    attr_reader :length

    def initialize(io, length)
      @io        = io
      @length    = length
      @remaining = length
    end

    def read(max = nil, buffer = nil)
      if @remaining <= 0
        buffer&.clear
        return max.to_i.positive? ? nil : ""
      end

      data = @io.read(max ? [ max, @remaining ].min : @remaining, buffer)
      @remaining -= data.bytesize if data
      data
    end
  end

  private

  def version_name(modified)
    Time.httpdate(modified.to_s).to_i.to_s
  rescue ArgumentError
    raise Error, "date de modification illisible (versions)"
  end

  def assert_versions_purged!(collection, current, size)
    remaining = versions(collection)
    clean = remaining.empty? || (remaining.one? && remaining.first[:name] == current && remaining.first[:size] == size)
    raise Error, "versions toujours présentes après la purge" unless clean

    remaining.each do |version|
      response = request(Net::HTTP::Get, "#{collection}/#{version[:name]}", headers: { "Range" => "bytes=0-0" },
                                                                            accept: [ 200, 206, 404 ])
      raise Error, "contenu encore stocké derrière la version courante" unless response.code == "404"
    end
  end

  # Entrées de la collection des versions : nom et taille.
  def versions(collection)
    response = request(Net::HTTP::Propfind, collection,
                       headers: { "Depth" => "1", "Content-Type" => "application/xml; charset=utf-8" },
                       body: PROPFIND_BODY, accept: [ 207 ])
    own = URI.decode_www_form_component(URI(collection).path)
    Nokogiri::XML(response.body).xpath("//d:response", NAMESPACES).filter_map do |entry|
      href = URI.decode_www_form_component(entry.at_xpath("d:href", NAMESPACES).text).chomp("/")
      next if href == own

      { name: href.split("/").last, size: entry.at_xpath(".//d:getcontentlength", NAMESPACES)&.text.presence }
    end
  end

  def ocs_shares(**params)
    query = URI.encode_www_form(**params, format: "json")
    response = request(Net::HTTP::Get, "#{@base_url}/ocs/v2.php/apps/files_sharing/api/v1/shares?#{query}",
                       headers: { "OCS-APIRequest" => "true", "Accept" => "application/json" }, accept: [ 200 ])
    shares = JSON.parse(response.body).dig("ocs", "data")
    raise Error, "réponse OCS illisible (partages)" unless shares.is_a?(Array)

    shares.map do |share|
      Share.new(type: Integer(share.fetch("share_type")), with: share["share_with"].to_s,
                permissions: Integer(share.fetch("permissions")), path: share.fetch("path").to_s)
    end
  rescue JSON::ParserError, KeyError, TypeError, ArgumentError
    raise Error, "réponse OCS illisible (partages)"
  end

  def upload_in_chunks(path, local_path, size)
    transfer = "#{@base_url}/remote.php/dav/uploads/#{escape(@username)}/undust-live-#{SecureRandom.hex(8)}"
    headers  = { "Destination" => files_url(path), "OC-Total-Length" => size.to_s }

    request(Net::HTTP::Mkcol, transfer, headers: headers.slice("Destination"))
    File.open(local_path, "rb") do |file|
      1.step do |number|
        length = [ @chunk_size, size - file.pos ].min
        break unless length.positive?

        request(Net::HTTP::Put, "#{transfer}/#{number}", headers: headers, stream: ChunkReader.new(file, length))
      end
    end
    request(Net::HTTP::Delete, files_url(path), accept: [ 204, 404 ]) if properties(path)
    request(Net::HTTP::Move, "#{transfer}/.file", headers: headers, accept: [ 201, 204 ])
  rescue Error
    discard_transfer(transfer)
    raise
  end

  def discard_transfer(transfer)
    request(Net::HTTP::Delete, transfer, accept: [ 204, 404 ])
  rescue Error
    nil # Nextcloud purge lui-même les transferts abandonnés après 24 h.
  end

  def properties(path)
    response = request(Net::HTTP::Propfind, files_url(path),
                       headers: { "Depth" => "0", "Content-Type" => "application/xml; charset=utf-8" },
                       body: PROPFIND_BODY, accept: [ 207, 404 ])
    return nil if response.code.to_i == 404

    found = Nokogiri::XML(response.body).at_xpath("//d:propstat[contains(d:status, ' 200 ')]/d:prop", NAMESPACES)
    { size: found&.at_xpath("d:getcontentlength", NAMESPACES)&.text.presence,
      file_id: found&.at_xpath("oc:fileid", NAMESPACES)&.text.presence,
      modified: found&.at_xpath("d:getlastmodified", NAMESPACES)&.text.presence,
      permissions: found&.at_xpath("oc:permissions", NAMESPACES)&.text.presence }
  end

  def files_url(path)
    "#{@base_url}/remote.php/dav/files/#{escape(@username)}/#{path.split('/').map { |segment| escape(segment) }.join('/')}"
  end

  def escape(segment)
    ERB::Util.url_encode(segment)
  end

  def request(verb, url, headers: {}, body: nil, stream: nil, accept: 200..299)
    uri = URI(url)
    req = verb.new(uri)
    req.basic_auth(@username, @app_password)
    headers.each { |name, value| req[name] = value }
    if stream
      req.body_stream = stream
      req["Content-Length"] = stream.length.to_s
    elsif body
      req.body = body
    end

    started  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = perform(uri, req)
    log(req.method, response.code, started)
    check!(response, req.method, accept)
  end

  def perform(uri, req)
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", max_retries: 0,
                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(req) }
  rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, IOError, SocketError,
         SystemCallError, OpenSSL::SSL::SSLError => e
    raise TransientError, "Nextcloud injoignable (#{req.method}, #{e.class})"
  end

  def check!(response, method, accept)
    code = response.code.to_i
    return response if accept.include?(code)

    message = "Nextcloud a répondu HTTP #{code} à #{method}"
    raise Error, "#{message} (espace insuffisant)" if code == 507
    raise TransientError, message if [ 408, 423, 429 ].include?(code) || code >= 500

    raise Error, message
  end

  def log(method, code, started)
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    @logger.info("[nextcloud] #{method} http_status=#{code} duration_ms=#{elapsed_ms}")
  end
end
