# frozen_string_literal: true

require "test_helper"

# NextcloudClient — contrat WebDAV. Pas de
# WebMock dans ce dépôt : Net::HTTP.start est remplacé par une fausse
# connexion qui garde chaque requête (et le corps lu en flux) et répond
# selon une table « verbe + fin d'URL → code ». Le protocole réel a été
# éprouvé contre une instance réelle (dossier jetable).
class NextcloudClientTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body)
  Sent = Struct.new(:method, :path, :headers, :body)

  class FakeHttp
    attr_reader :sent

    def initialize(routes)
      @routes = routes
      @sent = []
    end

    def request(req)
      body = req.body_stream ? req.body_stream.read : req.body
      @sent << Sent.new(req.method, URI.decode_www_form_component(req.path), req.each_header.to_h, body)
      _, response = @routes.find { |(method, suffix), _| req.method == method && req.path.end_with?(suffix) }
      response || FakeResponse.new("201", "")
    end
  end

  setup do
    @log = StringIO.new
    @client = NextcloudClient.new(base_url: "https://cloud.test/", username: "compte-test",
                                  app_password: "app-secret", chunk_size: 5, logger: Logger.new(@log))
  end

  test "from_env : nil dès qu'une des trois variables manque" do
    complete = { "NEXTCLOUD_URL" => "https://cloud.test", "NEXTCLOUD_USERNAME" => "u", "NEXTCLOUD_APP_PASSWORD" => "p" }

    assert_kind_of NextcloudClient, NextcloudClient.from_env(complete)
    complete.each_key { |key| assert_nil NextcloudClient.from_env(complete.merge(key => "")), key }
  end

  test "ensure_folder crée chaque niveau, un dossier existant (405) n'est pas une erreur" do
    http = stub_http({ [ "MKCOL", "/Cafe-IA" ] => FakeResponse.new("405", "") }) do
      @client.ensure_folder("Cafe-IA/2030-01-17-cafe-ia-007")
    end

    assert_equal [ "/remote.php/dav/files/compte-test/Cafe-IA", "/remote.php/dav/files/compte-test/Cafe-IA/2030-01-17-cafe-ia-007" ],
                 http.sent.map(&:path)
    assert_equal [ "MKCOL" ], http.sent.map(&:method).uniq
    assert_equal "Basic #{Base64.strict_encode64('compte-test:app-secret')}", http.sent.first.headers["authorization"]
  end

  test "size_of lit getcontentlength du propstat 200, nil si le fichier n'existe pas" do
    http = stub_http({ [ "PROPFIND", "/a.mp4" ] => FakeResponse.new("207", multistatus(size: 1291968609, file_id: 19400)),
                       [ "PROPFIND", "/absent.mp4" ] => FakeResponse.new("404", "") }) do
      assert_equal 1291968609, @client.size_of("Cafe-IA/a.mp4")
      assert_nil @client.size_of("Cafe-IA/absent.mp4")
    end

    assert_equal "0", http.sent.first.headers["depth"]
  end

  test "internal_link = /f/<fileid> du dossier" do
    stub_http({ [ "PROPFIND", "/2030-01-17-cafe-ia-007" ] => FakeResponse.new("207", multistatus(size: nil, file_id: 19400)) }) do
      assert_equal "https://cloud.test/f/19400", @client.internal_link("Cafe-IA/2030-01-17-cafe-ia-007")
    end
  end

  test "permissions_of lit oc:permissions (S : partage reçu, M : stockage monté), nil si le nœud n'existe pas" do
    stub_http({ [ "PROPFIND", "/Relecture" ] => FakeResponse.new("207", multistatus(size: nil, file_id: 7, permissions: "RGDNVCK")),
                [ "PROPFIND", "/Absent" ] => FakeResponse.new("404", "") }) do
      assert_equal "RGDNVCK", @client.permissions_of("Relecture")
      assert_nil @client.permissions_of("Absent")
    end
  end

  test "shares_of : partages OCS de ce nœud par tous les comptes, type et destinataire" do
    body = { ocs: { meta: { statuscode: 200 },
                    data: [ { share_type: 6, share_with: "bdelmas@cloud.test", path: "/Cafe-IA", permissions: 15 },
                            { share_type: 3, share_with: nil, path: "/Cafe-IA", permissions: 1 },
                            { share_type: 0, share_with: "marc", path: "/Cafe-IA", permissions: 31 } ] } }.to_json
    http = stub_http({ [ "GET", "format=json" ] => FakeResponse.new("200", body) }) do
      shares = @client.shares_of("Relecture/Café IA")

      assert_equal [ [ 6, "bdelmas@cloud.test", 15, "/Cafe-IA" ], [ 3, "", 1, "/Cafe-IA" ], [ 0, "marc", 31, "/Cafe-IA" ] ],
                   shares.map { |share| [ share.type, share.with, share.permissions, share.path ] }
      assert_equal [ "partage fédéré", "lien public", "partage à un utilisateur avec repartage" ], shares.map(&:label)
      assert_equal [ false, false, true ], shares.map(&:user?)
      assert_equal [ false, false, true ], shares.map(&:reshare?), "bit 16 : peut repartager"
    end

    get = http.sent.sole
    assert_equal "/ocs/v2.php/apps/files_sharing/api/v1/shares?path=/Relecture/Café IA&reshares=true&format=json", get.path
    assert_equal "true", get.headers["ocs-apirequest"]
  end

  test "shares_under : tous les partages du compte, gardés s'ils portent sur le chemin ou en dessous, à toute profondeur" do
    data = [ "/Relecture/Cafe-IA/e", "/Relecture/Cafe-IA/e/pistes/marc-partage-ecran-71.mp4", "/Relecture/Cafe-IA/e-2",
             "/Relecture/Cafe-IA", "/Cafe-IA" ].map { |path| { share_type: 3, share_with: nil, permissions: 1, path: path } }
    http = stub_http({ [ "GET", "format=json" ] => FakeResponse.new("200", { ocs: { data: data } }.to_json) }) do
      assert_equal [ "/Relecture/Cafe-IA/e", "/Relecture/Cafe-IA/e/pistes/marc-partage-ecran-71.mp4" ],
                   @client.shares_under("Relecture/Cafe-IA/e").map(&:path)
    end

    assert_equal "/ocs/v2.php/apps/files_sharing/api/v1/shares?reshares=true&format=json", http.sent.sole.path
  end

  test "shares_under compare les chemins en Unicode NFC (nom accentué rendu décomposé par Nextcloud)" do
    decomposed = "/Relecture/Cafe\u0301-IA/e".unicode_normalize(:nfd)
    data = [ { share_type: 3, share_with: nil, permissions: 1, path: decomposed } ]
    stub_http({ [ "GET", "format=json" ] => FakeResponse.new("200", { ocs: { data: data } }.to_json) }) do
      assert_equal 1, @client.shares_under("Relecture/Café-IA".unicode_normalize(:nfc)).size
    end
  end

  test "shares_of : nœud absent ou réponse illisible, c'est une erreur (jamais « aucun partage »)" do
    stub_http({ [ "GET", "format=json" ] => FakeResponse.new("404", { ocs: { data: [] } }.to_json) }) do
      assert_raises(NextcloudClient::Error) { @client.shares_of("Relecture") }
    end
    [ "<html>", { ocs: { data: {} } }.to_json, { ocs: { data: [ { share_with: "x", permissions: 1, path: "/R" } ] } }.to_json,
      { ocs: { data: [ { share_type: 0, share_with: "marc", path: "/R" } ] } }.to_json,
      { ocs: { data: [ { share_type: 0, share_with: "marc", permissions: 1 } ] } }.to_json ].each do |body|
      stub_http({ [ "GET", "format=json" ] => FakeResponse.new("200", body) }) do
        error = assert_raises(NextcloudClient::Error) { @client.shares_of("Relecture") }
        assert_equal "réponse OCS illisible (partages)", error.message
      end
    end
  end

  test "move : MOVE vers l'URL WebDAV de la destination, qui est remplacée" do
    http = stub_http({ [ "MOVE", "/video.mp4" ] => FakeResponse.new("201", "") }) do
      @client.move("Relecture/Cafe-IA/e/video.mp4", "Cafe-IA/e/video.mp4")
    end

    move = http.sent.sole
    assert_equal [ "MOVE", "/remote.php/dav/files/compte-test/Relecture/Cafe-IA/e/video.mp4" ], [ move.method, move.path ]
    assert_equal [ "https://cloud.test/remote.php/dav/files/compte-test/Cafe-IA/e/video.mp4", "T" ],
                 move.headers.values_at("destination", "overwrite")

    stub_http({ [ "MOVE", "/video.mp4" ] => FakeResponse.new("404", "") }) do
      assert_raises(NextcloudClient::Error) { @client.move("Relecture/Cafe-IA/e/video.mp4", "Cafe-IA/e/video.mp4") }
    end
  end

  test "purge_old_versions : supprime toutes les entrées, puis vérifie la courante reconstruite (nom, taille, aucun contenu)" do
    file = multistatus(size: 300, file_id: 19658, modified: "Fri, 30 Oct 2026 12:44:22 GMT")
    listing = versions_listing(19658, %w[1793364257 1793364260 1793364262])
    after = versions_listing(19658, %w[1793364262])
    calls = 0
    http = FakeHttp.new({ [ "PROPFIND", "/a.mp4" ] => FakeResponse.new("207", file), [ "DELETE", "" ] => FakeResponse.new("204", ""),
                          [ "GET", "/19658/1793364262" ] => FakeResponse.new("404", "") })
    http.define_singleton_method(:request) do |req|
      next super(req) unless req.method == "PROPFIND" && req.path.end_with?("/19658")

      @sent << NextcloudClientTest::Sent.new(req.method, req.path, req.each_header.to_h, req.body)
      calls += 1
      NextcloudClientTest::FakeResponse.new("207", calls == 1 ? listing : after)
    end
    with_net_http_start(->(*, **, &block) { block.call(http) }) { @client.purge_old_versions("Relecture/a.mp4") }

    assert_equal %w[1793364257 1793364260 1793364262].map { |name| "/remote.php/dav/versions/compte-test/versions/19658/#{name}" },
                 http.sent.select { |sent| sent.method == "DELETE" }.map(&:path), "y compris l'entrée au nom de la courante"
    assert_equal 2, calls, "relu après la purge"
    assert_equal "bytes=0-0", http.sent.find { |sent| sent.method == "GET" }.headers["range"], "aucun contenu derrière la courante"
  end

  test "purge_old_versions : une ancienne version restée, ou une date illisible, est une erreur" do
    file = multistatus(size: 300, file_id: 19658, modified: "Fri, 30 Oct 2026 12:44:22 GMT")
    stub_http({ [ "PROPFIND", "/a.mp4" ] => FakeResponse.new("207", file),
                [ "PROPFIND", "/19658" ] => FakeResponse.new("207", versions_listing(19658, %w[1793364257 1793364262])),
                [ "DELETE", "" ] => FakeResponse.new("204", "") }) do
      error = assert_raises(NextcloudClient::Error) { @client.purge_old_versions("Relecture/a.mp4") }
      assert_equal "versions toujours présentes après la purge", error.message
    end
    stub_http({ [ "PROPFIND", "/a.mp4" ] => FakeResponse.new("207", multistatus(size: 300, file_id: 19658, modified: "hier")) }) do
      error = assert_raises(NextcloudClient::Error) { @client.purge_old_versions("Relecture/a.mp4") }
      assert_equal "date de modification illisible (versions)", error.message
    end
  end

  # Sonde rejouée sur le serveur Nextcloud : première coupe
  # déposée avec la date du brut, une seule entrée « T » à la taille de la
  # coupe, contenu venu du brut.
  test "coupe datée comme le brut — l'entrée au nom de la courante est supprimée, puis vérifiée vide" do
    file = multistatus(size: 300, file_id: 19658, modified: "Fri, 30 Oct 2026 12:44:22 GMT")
    routes = { [ "PROPFIND", "/a.mp4" ] => FakeResponse.new("207", file),
               [ "PROPFIND", "/19658" ] => FakeResponse.new("207", versions_listing(19658, %w[1793364262])),
               [ "DELETE", "" ] => FakeResponse.new("204", "") }
    http = stub_http(routes.merge([ "GET", "/19658/1793364262" ] => FakeResponse.new("404", ""))) { @client.purge_old_versions("Relecture/a.mp4") }
    assert_equal [ "/remote.php/dav/versions/compte-test/versions/19658/1793364262" ], http.sent.select { |sent| sent.method == "DELETE" }.map(&:path)

    # Contenu toujours servi derrière l'entrée après la purge : erreur.
    stub_http(routes.merge([ "GET", "/19658/1793364262" ] => FakeResponse.new("206", "x"))) do
      error = assert_raises(NextcloudClient::Error) { @client.purge_old_versions("Relecture/a.mp4") }
      assert_equal "contenu encore stocké derrière la version courante", error.message
    end
  end

  test "purge_old_versions : entrée restante d'une autre taille, nom non numérique, collection absente : erreur" do
    file = multistatus(size: 300, file_id: 19658, modified: "Fri, 30 Oct 2026 12:44:22 GMT")
    { versions_listing(19658, [ [ "1793364262", 900 ] ]) => "versions toujours présentes après la purge",
      versions_listing(19658, %w[../a.mp4]) => "nom de version inattendu" }.each do |listing, message|
      stub_http({ [ "PROPFIND", "/a.mp4" ] => FakeResponse.new("207", file), [ "PROPFIND", "/19658" ] => FakeResponse.new("207", listing),
                  [ "DELETE", "" ] => FakeResponse.new("204", "") }) do
        assert_equal message, assert_raises(NextcloudClient::Error) { @client.purge_old_versions("Relecture/a.mp4") }.message
      end
    end
    stub_http({ [ "PROPFIND", "/a.mp4" ] => FakeResponse.new("207", file), [ "PROPFIND", "/19658" ] => FakeResponse.new("404", "") }) do
      assert_raises(NextcloudClient::Error) { @client.purge_old_versions("Relecture/a.mp4") }
    end
  end

  test "purge_old_versions : une version sans taille n'est pas tolérée" do
    file = multistatus(size: 300, file_id: 19658, modified: "Fri, 30 Oct 2026 12:44:22 GMT")
    listing = %(<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/remote.php/dav/versions/compte-test/versions/19658/</d:href></d:response>) +
              %(<d:response><d:href>/remote.php/dav/versions/compte-test/versions/19658/1793364262</d:href></d:response></d:multistatus>)
    stub_http({ [ "PROPFIND", "/a.mp4" ] => FakeResponse.new("207", file), [ "PROPFIND", "/19658" ] => FakeResponse.new("207", listing) }) do
      assert_raises(NextcloudClient::Error) { @client.purge_old_versions("Relecture/a.mp4") }
    end
  end

  test "un fichier jusqu'à chunk_size part en un seul PUT, lu en flux" do
    with_file("12345") do |path|
      http = stub_http({}) { @client.upload_file("Cafe-IA/pistes/marc micro.ogg", path) }

      put = http.sent.sole
      assert_equal [ "PUT", "/remote.php/dav/files/compte-test/Cafe-IA/pistes/marc micro.ogg", "12345", "5" ],
                   [ put.method, put.path, put.body, put.headers["content-length"] ]
    end
  end

  test "au-delà de chunk_size : chunking v2 (MKCOL du transfert, morceaux numérotés, MOVE .file)" do
    with_file("abcdefghijkl") do |path|
      http = stub_http({ [ "MOVE", "/.file" ] => FakeResponse.new("201", ""),
                         [ "PROPFIND", "/Cafe-IA/v.mp4" ] => FakeResponse.new("404", "") }) do
        @client.upload_file("Cafe-IA/v.mp4", path)
      end

      destination = "https://cloud.test/remote.php/dav/files/compte-test/Cafe-IA/v.mp4"
      mkcol, *chunks, probe, move = http.sent
      assert_equal [ "PROPFIND", "/remote.php/dav/files/compte-test/Cafe-IA/v.mp4" ], [ probe.method, probe.path ]
      assert_equal "MKCOL", mkcol.method
      assert_match %r{\A/remote.php/dav/uploads/compte-test/undust-live-\h{16}\z}, mkcol.path
      assert_equal destination, mkcol.headers["destination"]
      assert_equal [ "#{mkcol.path}/1", "#{mkcol.path}/2", "#{mkcol.path}/3" ], chunks.map(&:path)
      assert_equal %w[abcde fghij kl], chunks.map(&:body)
      assert(chunks.all? { |chunk| chunk.headers["oc-total-length"] == "12" && chunk.headers["destination"] == destination })
      assert_equal [ "MOVE", "#{mkcol.path}/.file", destination ], [ move.method, move.path, move.headers["destination"] ]
    end
  end

  # Nextcloud 30 : le MOVE final qui écrase un fichier existant dans un
  # partage plante (HTTP 500, ChunkingV2Plugin). Ce faux serveur le reproduit.
  class OverwriteCrashHttp < FakeHttp
    def request(req)
      super
      path = URI.decode_www_form_component(req.path)
      @deleted = true if req.method == "DELETE" && path.end_with?("/Cafe-IA/v.mp4")
      return FakeResponse.new(@deleted ? "404" : "207", @deleted ? "" : @routes.fetch(:file)) if req.method == "PROPFIND"
      return FakeResponse.new(@deleted ? "201" : "500", "") if req.method == "MOVE"

      FakeResponse.new(req.method == "DELETE" ? "204" : "201", "")
    end
  end

  test "remplacer un fichier déjà déposé : DELETE de la destination puis MOVE neuf (Nextcloud 30 plante sinon)" do
    http = OverwriteCrashHttp.new({ file: multistatus(size: 300, file_id: 19400) })
    with_net_http_start(->(*, **, &block) { block.call(http) }) do
      with_file("abcdefghijkl") { |path| @client.upload_file("Cafe-IA/v.mp4", path) }
    end

    assert_equal %w[MKCOL PUT PUT PUT PROPFIND DELETE MOVE], http.sent.map(&:method)
    assert_equal "/remote.php/dav/files/compte-test/Cafe-IA/v.mp4", http.sent[5].path
  end

  test "un morceau refusé abandonne le transfert (DELETE du dossier temporaire) et remonte l'erreur" do
    with_file("abcdefghijkl") do |path|
      http = stub_http({ [ "PUT", "/2" ] => FakeResponse.new("503", "") }) do
        assert_raises(NextcloudClient::TransientError) { @client.upload_file("Cafe-IA/v.mp4", path) }
      end

      assert_equal %w[MKCOL PUT PUT DELETE], http.sent.map(&:method)
      assert_equal http.sent.first.path, http.sent.last.path
    end
  end

  test "codes HTTP : 423/429/5xx et réseau rejouables, droits et espace définitifs" do
    { "503" => NextcloudClient::TransientError, "423" => NextcloudClient::TransientError,
      "408" => NextcloudClient::TransientError,
      "429" => NextcloudClient::TransientError, "401" => NextcloudClient::Error,
      "409" => NextcloudClient::Error, "507" => NextcloudClient::Error }.each do |code, error_class|
      stub_http({ [ "PUT", "/x.md" ] => FakeResponse.new(code, "") }) do
        error = assert_raises(NextcloudClient::Error) { @client.put_content("x.md", "x") }
        assert_instance_of error_class, error, code
      end
    end

    with_net_http_start(->(*, **) { raise Errno::ECONNREFUSED }) do
      assert_raises(NextcloudClient::TransientError) { @client.put_content("x.md", "x") }
    end
  end

  test "Net::HTTP ne rejoue rien lui-même : un corps en flux déjà lu repartirait vide" do
    options = nil
    http = FakeHttp.new({})
    with_net_http_start(->(*, **given, &block) { options = given; block.call(http) }) do
      with_file("12345") { |path| @client.upload_file("Cafe-IA/a.ogg", path) }
    end

    assert_equal 0, options.fetch(:max_retries)
    assert options.fetch(:use_ssl)
  end

  test "le mot de passe d'application n'apparaît ni dans les logs ni dans inspect" do
    stub_http({}) { @client.put_content("Cafe-IA/pistes/basile.md", "x") }

    assert_match(/\[nextcloud\] PUT http_status=201 duration_ms=\d+/, @log.string)
    assert_no_match(/app-secret|basile/, @log.string)
    assert_no_match(/app-secret/, @client.inspect)
  end

  test "ChunkReader borne la lecture à sa longueur, quel que soit le découpage" do
    io = StringIO.new("0123456789")
    io.read(2)
    copy = StringIO.new
    IO.copy_stream(NextcloudClient::ChunkReader.new(io, 5), copy)

    assert_equal "23456", copy.string
    assert_equal 7, io.pos
  end

  private

  def stub_http(routes)
    http = FakeHttp.new(routes)
    with_net_http_start(->(*, **, &block) { block.call(http) }) { yield }
    http
  end

  # Même patron que Crm::HttpContactsClientTest : pas de minitest/mock (minitest 6).
  def with_net_http_start(stub)
    original = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*args, **options, &block| stub.call(*args, **options, &block) }
    yield
  ensure
    Net::HTTP.define_singleton_method(:start, original)
  end

  def with_file(content)
    Tempfile.create("nextcloud") do |file|
      file.binmode
      file.write(content)
      file.flush
      yield file.path
    end
  end

  def multistatus(size:, file_id:, permissions: nil, modified: nil)
    found = [ size && "<d:getcontentlength>#{size}</d:getcontentlength>", "<oc:fileid>#{file_id}</oc:fileid>",
              permissions && "<oc:permissions>#{permissions}</oc:permissions>",
              modified && "<d:getlastmodified>#{modified}</d:getlastmodified>" ].compact.join
    <<~XML
      <?xml version="1.0"?>
      <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
        <d:response><d:href>/remote.php/dav/files/compte-test/x</d:href>
          <d:propstat><d:prop>#{found}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
          <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat>
        </d:response>
      </d:multistatus>
    XML
  end

  # Collection des versions telle que la rend Nextcloud 30 : elle-même, puis
  # une entrée par version, la courante comprise.
  # `names` : noms seuls (taille 300, celle du fichier courant des tests) ou
  # paires [nom, taille].
  def versions_listing(file_id, names)
    entries = ([ "" ] + names).map do |name, size = 300|
      href = "/remote.php/dav/versions/compte-test/versions/#{file_id}/#{name}".chomp("/")
      prop = name.empty? ? "" : "<d:propstat><d:prop><d:getcontentlength>#{size}</d:getcontentlength></d:prop>" \
                                "<d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
      "<d:response><d:href>#{href}#{'/' if name.empty?}</d:href>#{prop}</d:response>"
    end
    %(<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">#{entries.join}</d:multistatus>)
  end
end
