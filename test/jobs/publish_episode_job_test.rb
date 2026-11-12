# frozen_string_literal: true

require "test_helper"

# PublishEpisodeJob + EpisodePublisher — dépôt vérifié, idempotent,
# reprise après échec, puis un mail par intervenant joignable. Les vidéos
# qui peuvent montrer un écran partagé ne vont qu'en relecture, jusqu'à
# leur validation.
class PublishEpisodeJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper
  include EpisodePublicationHelpers

  setup do
    @tmp = Dir.mktmpdir("publish-episode")
    @previous_root = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = @tmp

    @webinar = ended_cafe(slug: "cafe-ia-7")
    @basile = @webinar.speakers.create!(name: "Basile Delmas", email: "basile@example.test")
    @tristan = @webinar.speakers.create!(name: "Tristan Lemaire", email: "tristan@example.test")
    @webinar.speakers.create!(name: "Sans adresse")
    @webinar.registrations.create!(name: "Spectatrice", email: "spectatrice@example.test", confirmed_at: Time.current)
    @composite = add_recording(@webinar, kind: "composite", file: "seance.mp4", bytes: "v" * 200)
    @camera = add_recording(@webinar, kind: "track", identity: "speaker-#{@basile.id}", source: "camera",
                                      file: "camera.mp4", bytes: "c" * 100)
    add_segment(@webinar, "Bonjour.", at: Time.zone.parse("2030-01-17 09:31:36"))
    @folder = "Cafe-IA/2030-01-17-cafe-ia-007"
    @review = "Relecture/Cafe-IA/2030-01-17-cafe-ia-007"
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
  end

  # La liste OCS des partages du compte ne voit rien : seule la vérification
  # nœud par nœud (dossier visé et ses parents) peut arrêter le dépôt.
  def blind_below(cloud)
    cloud.define_singleton_method(:shares_under) { |_path| [] }
    cloud
  end

  def share(type, with, permissions: 1)
    NextcloudClient::Share.new(type: type, with: with, permissions: permissions, path: "/peu-importe")
  end

  test "dépose tout le contenu vérifié, le composite en relecture, trace la publication, prévient les seuls intervenants joignables" do
    cloud = FakeNextcloud.new

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    stem = "video-complete-fin-10h27-#{@composite.id}"
    shared = [ "pistes/basile-delmas-camera-fin-10h27-#{@camera.id}.mp4",
               "2030-01-17-cafe-ia-007-transcript.md", "#{stem}.srt", "#{stem}.vtt",
               "2030-01-17-cafe-ia-007-extraits.json", "README.md" ]
    assert_equal [ "#{@review}/#{stem}.mp4" ] + shared.map { |name| "#{@folder}/#{name}" }, cloud.uploads
    assert_equal "v" * 200, cloud.stored.fetch("#{@review}/#{stem}.mp4")
    assert_equal [ "Cafe-IA", @folder, "#{@folder}/pistes" ], cloud.folders.select { |folder| folder.start_with?("Cafe-IA") }.uniq.sort

    publication = @webinar.reload.episode_publication
    assert publication.published?
    assert_equal [ @folder, @review ], [ publication.folder, publication.review_folder ]
    assert_equal [ "https://cloud.test/f/4242", "https://cloud.test/f/7777" ], [ publication.folder_url, publication.review_folder_url ]
    assert_equal [ "#{stem}.mp4" ], publication.files_in("review").pluck("name")
    assert_equal shared, publication.files_in("shared").pluck("name")
    assert_equal 1, publication.attempts

    mails = ActionMailer::Base.deliveries.last(2)
    assert_equal [ [ "basile@example.test" ], [ "tristan@example.test" ] ], mails.map(&:to)
    assert_equal [ "basile@example.test", "tristan@example.test" ], publication.notified_emails
    assert_not_includes ActionMailer::Base.deliveries.flat_map(&:to), "spectatrice@example.test"
  end

  test "versions légères prêtes : déposées à la place des originaux, laissés intacts ; l'écran part en original" do
    screen = add_recording(@webinar, kind: "track", identity: "host-publication-host", source: "screen_share", file: "ecran.mp4")
    produce_light_version(@composite, "composite leger")
    produce_light_version(@camera, "camera legere")
    cloud = FakeNextcloud.new

    with_light_versions { with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) } }

    assert_equal "composite leger", cloud.stored.fetch("#{@review}/video-complete-fin-10h27-#{@composite.id}.mp4")
    assert_equal "camera legere", cloud.stored.fetch("#{@folder}/pistes/basile-delmas-camera-fin-10h27-#{@camera.id}.mp4")
    assert_equal "x" * 32, cloud.stored.fetch("#{@review}/pistes/marc-partage-ecran-fin-10h27-#{screen.id}.mp4")
    assert_equal [ "v" * 200, "c" * 100 ], [ File.binread(@composite.absolute_path), File.binread(@camera.absolute_path) ]
    assert_includes cloud.stored.fetch("#{@folder}/README.md"), "13 octets"
  end

  test "version légère prête après un dépôt de l'original : le dépôt suivant la met à la place dans le partagé" do
    cloud = FakeNextcloud.new
    camera = "#{@folder}/pistes/basile-delmas-camera-fin-10h27-#{@camera.id}.mp4"
    with_light_versions do
      with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
      assert_equal "c" * 100, cloud.stored.fetch(camera)

      produce_light_version(@camera, "camera legere")
      with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    end

    assert_equal "camera legere", cloud.stored.fetch(camera)
    assert_equal 1, cloud.uploads.count { |path| path.end_with?("video-complete-fin-10h27-#{@composite.id}.mp4") },
                 "la vidéo en relecture appartient au relecteur : jamais remplacée"
  end

  test "versions légères désactivées : les originaux partent, même si une version légère est prête" do
    produce_light_version(@camera, "camera legere")
    cloud = FakeNextcloud.new

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert_equal "c" * 100, cloud.stored.fetch("#{@folder}/pistes/basile-delmas-camera-fin-10h27-#{@camera.id}.mp4")
  end

  test "aucune piste d'écran ni composite dans le dossier partagé sans validation, même rejoué ; le mail ne les nomme ni ne les lie" do
    screen = add_recording(@webinar, kind: "track", identity: "host-publication-host", source: "screen_share", file: "ecran.mp4")
    sound = add_recording(@webinar, kind: "track", identity: "host-publication-host", source: "screen_share_audio", file: "son.ogg")
    add_recording(@webinar, kind: "participant", identity: "speaker-#{@basile.id}", file: "mux.mp4")
    cloud = FakeNextcloud.new

    2.times { with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) } }

    sensitive = [ "video-complete-fin-10h27-#{@composite.id}.mp4", "pistes/marc-partage-ecran-fin-10h27-#{screen.id}.mp4",
                  "pistes/marc-son-ecran-fin-10h27-#{sound.id}.ogg" ]
    assert_equal sensitive.map { |name| "#{@review}/#{name}" }.sort, cloud.stored.keys.grep(/\A#{@review}/).sort
    assert_empty cloud.stored.keys.grep(%r{\A#{@folder}/(video-complete-.*\.mp4|.*-ecran-)}), "rien d'écran dans le dossier partagé"
    assert_empty cloud.uploads.grep(%r{\A#{@folder}/(video-complete-.*\.mp4|.*-ecran-)})
    assert_includes cloud.stored.keys, "#{@folder}/assemblages/basile-delmas-#{@webinar.recordings.participants.last.id}.mp4"

    readme = cloud.stored.fetch("#{@folder}/README.md")
    assert_includes readme, EpisodePublication::IN_REVIEW_NOTICE
    text = ActionMailer::Base.deliveries.last.text_part.body.to_s
    html = ActionMailer::Base.deliveries.last.html_part.body.to_s
    assert_includes text, EpisodePublication::IN_REVIEW_NOTICE
    [ readme, text, html ].each do |body|
      sensitive.each { |name| assert_not_includes body, File.basename(name) }
      assert_no_match(/7777|Relecture/, body)
    end
  end

  test "Valider et partager : la vidéo validée est déplacée, annoncée, puis plus jamais redéposée" do
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    name = "video-complete-fin-10h27-#{@composite.id}.mp4"
    @webinar.episode_publication.approve!([ name ], by: "marc@example.test")

    assert_emails 2 do
      with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    end

    assert_equal [ [ "#{@review}/#{name}", "#{@folder}/#{name}" ] ], cloud.moves
    assert_equal "v" * 200, cloud.stored.fetch("#{@folder}/#{name}")
    assert_not cloud.stored.key?("#{@review}/#{name}")
    file = @webinar.reload.episode_publication.files.find { |entry| entry["name"] == name }
    assert_equal [ "shared", 200, "marc@example.test" ], file.values_at("zone", "size", "approved_by")
    assert_includes ActionMailer::Base.deliveries.last.text_part.body.to_s, "- #{name} (200 octets)"
    assert_not_includes ActionMailer::Base.deliveries.last.text_part.body.to_s, EpisodePublication::IN_REVIEW_NOTICE
    assert_includes cloud.stored.fetch("#{@folder}/README.md"), "| #{name} |"

    cloud.stored["#{@folder}/#{name}"] = "coupée"
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    cloud.stored.delete("#{@folder}/#{name}")
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    assert_equal 1, cloud.uploads.count { |path| path.end_with?(name) }, "ni la version coupée ni son absence ne la font renvoyer"
  end

  test "validation reprise : déjà déplacée, elle est reconnue ; supprimée de la relecture, elle n'est jamais partagée" do
    screen = add_recording(@webinar, kind: "track", identity: "host-publication-host", source: "screen_share", file: "ecran.mp4")
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    video = "video-complete-fin-10h27-#{@composite.id}.mp4"
    shown = "pistes/marc-partage-ecran-fin-10h27-#{screen.id}.mp4"
    @webinar.episode_publication.approve!([ video, shown ], by: "marc@example.test")
    cloud.stored["#{@folder}/#{video}"] = cloud.stored.delete("#{@review}/#{video}")
    cloud.stored.delete("#{@review}/#{shown}")

    2.times { with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) } }

    assert_empty cloud.moves
    zones = @webinar.reload.episode_publication.files.to_h { |file| file.values_at("name", "zone") }
    assert_equal [ "shared", "withdrawn" ], zones.values_at(video, shown)
    assert_not cloud.stored.key?("#{@folder}/#{shown}")
    assert_equal 1, cloud.uploads.count { |path| path.end_with?(shown) }, "jamais redéposée"
  end

  test "une vidéo arrivée après une validation va en relecture, pas dans le dossier partagé" do
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    @webinar.episode_publication.approve!([ "video-complete-fin-10h27-#{@composite.id}.mp4" ], by: "marc@example.test")
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    later = add_recording(@webinar, kind: "composite", file: "reprise.mp4", ended: Time.zone.parse("2030-01-17 10:41:02"))

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert cloud.stored.key?("#{@review}/video-complete-fin-10h41-#{later.id}.mp4")
    assert_empty cloud.stored.keys.grep(%r{\A#{@folder}/.*-#{later.id}\.mp4})
  end

  test "dossier de relecture exposé (partage sur lui ou un parent, relecteur qui peut repartager, partage reçu, stockage monté) : rien n'est déposé" do
    exposures = { { shares: { "Relecture" => [ share(6, "quelqu-un@cloud.test") ] } } => "Relecture : partage fédéré",
                  { shares: { @review => [ share(3, "") ] } } => "#{@review} : lien public",
                  { shares: { "Relecture/Cafe-IA" => [ share(0, "tristan") ] } } => "Relecture/Cafe-IA : partage à un utilisateur",
                  { shares: { "Relecture/Cafe-IA" => [ share(1, "relecteur") ] } } => "Relecture/Cafe-IA : partage à un groupe",
                  { shares: { "Relecture/Cafe-IA" => [ share(0, "relecteur", permissions: 31) ] } } =>
                    "Relecture/Cafe-IA : partage à un utilisateur avec repartage",
                  { permissions: "SRGDNVCK" } => "hors de l'espace du compte",
                  { permissions: nil } => "hors de l'espace du compte",
                  { permissions: "RGDNVCKM" } => "hors de l'espace du compte" }

    exposures.each do |options, reason|
      cloud = FakeNextcloud.new(**options)
      error = with_nextcloud(cloud) { assert_raises(EpisodePublisher::ReviewFolderExposed) { PublishEpisodeJob.perform_now(@webinar.id) } }

      assert_includes error.message, reason
      assert_empty cloud.uploads, reason
      assert_empty cloud.folders.grep(/\ACafe-IA/), "le dossier partagé n'est pas touché (#{reason})"
      assert @webinar.reload.episode_publication.failed?
      assert_match(/\Adossier de relecture .* : dépôt arrêté\z/, @webinar.episode_publication.error_message)
    end
    assert_no_enqueued_jobs only: PublishEpisodeJob
  end

  test "partage posé sous le dossier de relecture (sous-dossier, fichier déjà déposé) : rien n'est déposé" do
    add_recording(@webinar, kind: "track", identity: "host-publication-host", source: "screen_share", file: "ecran.mp4")
    [ blind_below(FakeNextcloud.new(shares: { "#{@review}/pistes" => [ share(3, "") ] })),
      FakeNextcloud.new(shares: { "#{@review}/pistes" => [ share(3, "") ] }) ].zip(
      [ "#{@review}/pistes : lien public", "sous #{@review} : lien public" ]
    ).each do |subfolder, where|
      error = with_nextcloud(subfolder) { assert_raises(EpisodePublisher::ReviewFolderExposed) { PublishEpisodeJob.perform_now(@webinar.id) } }

      assert_equal "dossier de relecture partagé (#{where}) : dépôt arrêté", error.message
      assert_empty subfolder.uploads
      assert_empty subfolder.folders.grep(/\ACafe-IA/)
    end

    shares = {}
    cloud = FakeNextcloud.new(shares: shares)
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    shares["#{@review}/video-complete-fin-10h27-#{@composite.id}.mp4"] = [ share(6, "quelqu-un@cloud.test") ]
    deposited = cloud.uploads.size

    error = with_nextcloud(cloud) { assert_raises(EpisodePublisher::ReviewFolderExposed) { PublishEpisodeJob.perform_now(@webinar.id) } }

    assert_equal "dossier de relecture partagé (sous #{@review} : partage fédéré) : dépôt arrêté", error.message
    assert_equal deposited, cloud.uploads.size, "rien de plus n'est déposé"
  end

  test "un partage utilisateur du dossier de relecture à un relecteur nommé (EPISODE_REVIEWERS), sans repartage, est permis" do
    cloud = FakeNextcloud.new(shares: { "Relecture/Cafe-IA" => [ share(0, "relecteur", permissions: 15) ] })

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert @webinar.reload.episode_publication.published?
  end

  test "dossier de relecture partagé en cours de dépôt : la garde refaite après chaque envoi et sur le dossier de la vidéo suivante arrête le dépôt" do
    screen = add_recording(@webinar, kind: "track", identity: "host-publication-host", source: "screen_share", file: "ecran.mp4")
    composite = "video-complete-fin-10h27-#{@composite.id}.mp4"
    { "Relecture" => "#{composite} : dossier de relecture partagé (Relecture : lien public)",
      "#{@review}/pistes" => "pistes/marc-partage-ecran-fin-10h27-#{screen.id}.mp4 : dossier de relecture partagé (#{@review}/pistes : lien public)" }
      .each do |opened, message|
      @webinar.episode_publication&.destroy
      shares = {}
      cloud = blind_below(FakeNextcloud.new(shares: shares, after_store: ->(path) { shares[opened] = [ share(3, "") ] if path.start_with?("Relecture/") }))

      with_nextcloud(cloud) { assert_raises(EpisodePublisher::ReviewFolderExposed) { PublishEpisodeJob.perform_now(@webinar.id) } }

      assert_equal [ "#{@review}/#{composite}" ], cloud.uploads.grep(/\ARelecture/)
      assert_empty cloud.uploads.grep(/-#{screen.id}\.mp4\z/), "la piste d'écran n'est pas déposée dans un dossier ouvert"
      assert_equal "#{message} : dépôt arrêté", @webinar.reload.episode_publication.error_message
    end
  end

  test "dossier exposé juste après l'envoi en relecture : la vidéo est notée avant la garde, la reprise n'écrase pas la coupe" do
    name = "video-complete-fin-10h27-#{@composite.id}.mp4"
    shares = {}
    cloud = blind_below(FakeNextcloud.new(shares: shares, after_store: ->(path) { shares[@review] = [ share(3, "") ] if path.end_with?(name) }))

    with_nextcloud(cloud) { assert_raises(EpisodePublisher::ReviewFolderExposed) { PublishEpisodeJob.perform_now(@webinar.id) } }
    assert_equal [ name ], @webinar.reload.episode_publication.files_in("review").pluck("name"), "notée malgré la garde"

    shares.clear
    cloud.stored["#{@review}/#{name}"] = "v" * 120
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert_equal "v" * 120, cloud.stored.fetch("#{@review}/#{name}")
    assert_equal 1, cloud.uploads.count { |path| path.end_with?(name) }
  end

  test "la vidéo en relecture n'est jamais réécrite : coupée par le relecteur puis un dépôt, c'est la coupe, sans le brut en version, qui est validée et partagée" do
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    name = "video-complete-fin-10h27-#{@composite.id}.mp4"
    cloud.replace_as_reviewer("#{@review}/#{name}", "v" * 120)

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    assert_equal 120, @webinar.reload.episode_publication.files.find { |file| file["name"] == name }["size"], "taille relue de la coupe"
    @webinar.episode_publication.approve!([ name ], by: "marc@example.test")
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert_equal "v" * 120, cloud.stored.fetch("#{@folder}/#{name}")
    assert_empty cloud.versions["#{@folder}/#{name}"], "le brut ne suit pas la vidéo en version"
    assert_equal 1, cloud.uploads.count { |path| path.end_with?(name) }
  end

  test "versions de la coupe impossibles à purger : rien n'est déplacé, la vidéo reste en relecture" do
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    name = "video-complete-fin-10h27-#{@composite.id}.mp4"
    cloud.replace_as_reviewer("#{@review}/#{name}", "v" * 120)
    @webinar.episode_publication.approve!([ name ], by: "marc@example.test")
    def cloud.purge_old_versions(_path) = raise(NextcloudClient::Error, "versions toujours présentes après la purge")

    with_nextcloud(cloud) { assert_raises(NextcloudClient::Error) { PublishEpisodeJob.perform_now(@webinar.id) } }

    assert_empty cloud.moves
    assert_not cloud.stored.key?("#{@folder}/#{name}")
    publication = @webinar.reload.episode_publication
    assert publication.failed?
    assert_equal "#{name} : versions toujours présentes après la purge", publication.error_message
    assert_equal [ name ], publication.files_in("approved").pluck("name"), "la validation attend la relance"
  end

  test "la vidéo supprimée du dossier de relecture puis un dépôt : retirée, jamais redéposée, une validation ne la partage pas" do
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    name = "video-complete-fin-10h27-#{@composite.id}.mp4"
    cloud.stored.delete("#{@review}/#{name}")

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    publication = @webinar.reload.episode_publication
    assert_equal [ name ], publication.files_in("withdrawn").pluck("name")
    assert_equal 0, publication.approve!([ name ], by: "marc@example.test")
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert_not cloud.stored.key?("#{@folder}/#{name}")
    assert_not cloud.stored.key?("#{@review}/#{name}")
    assert_equal 1, cloud.uploads.count { |path| path.end_with?(name) }
  end

  test "dépôt interrompu après l'envoi d'une vidéo en relecture : notée aussitôt, la reprise ne l'envoie pas par-dessus la coupe" do
    cloud = FakeNextcloud.new(fail_once_on: "pistes/")
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    name = "video-complete-fin-10h27-#{@composite.id}.mp4"
    assert_equal [ name ], @webinar.reload.episode_publication.files_in("review").pluck("name"), "notée malgré l'échec"
    cloud.stored["#{@review}/#{name}"] = "v" * 120

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert @webinar.reload.episode_publication.published?
    assert_equal "v" * 120, cloud.stored.fetch("#{@review}/#{name}")
    assert_equal 1, cloud.uploads.count { |path| path.end_with?(name) }
  end

  test "accord retiré après le dépôt, des jours plus tard : le balayage redépose le JSON et le README des accords" do
    consent = ParticipantConsent.grant!(@basile, recording: true, excerpts: true, adult: true, now: @webinar.ended_at - 30.minutes)
    consent.update_columns(updated_at: @webinar.ended_at - 30.minutes)
    cloud = FakeNextcloud.new
    json = "#{@folder}/2030-01-17-cafe-ia-007-extraits.json"
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    assert_equal "allowed", JSON.parse(cloud.stored.fetch(json)).fetch("people").find { |p| p["name"] == "Basile Delmas" }["excerpts"]

    later = @webinar.ended_at + 5.days
    travel_to(later) do
      ConsentWithdrawal.new(@webinar, @basile, client: Class.new { def update_participant(**) = {} }.new).call
      with_nextcloud(cloud) do
        assert_no_emails { perform_enqueued_jobs(only: [ PublishEpisodeJob ]) { EpisodePublicationSweepJob.perform_now(now: later + 5.minutes) } }
      end
    end

    person = JSON.parse(cloud.stored.fetch(json)).fetch("people").find { |p| p["name"] == "Basile Delmas" }
    assert_equal "withdrawn", person.fetch("excerpts")
    assert_includes cloud.stored.fetch("#{@folder}/README.md"), "| Basile Delmas | speaker-#{@basile.id} | accord retiré |"
  end

  test "rejoué : aucune vidéo renvoyée, textes réécrits, personne prévenu deux fois" do
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    first = cloud.uploads.dup

    assert_no_emails do
      with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    end
    resent = cloud.uploads.drop(first.size)
    assert_equal first.grep(/\.(md|srt|vtt|json)\z/), resent
    assert_equal 2, @webinar.reload.episode_publication.attempts
  end

  # Nouveau calage (recordings:montages[…,refaire]) : l'assemblage refait
  # garde son nom et peut garder sa taille.
  test "un assemblage refait à la même taille est redéposé une fois, puis plus renvoyé" do
    mux = add_recording(@webinar, kind: "participant", identity: "speaker-#{@basile.id}", file: "mux.mp4",
                                  bytes: "m" * 120, ended: Time.zone.parse("2030-01-17 10:29:35"))
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    mux_path = cloud.uploads.grep(%r{/assemblages/}).sole

    File.binwrite(mux.absolute_path, "n" * 120)
    mux.update!(ended_at: Time.zone.parse("2030-01-18 08:00:00"))
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert_equal [ mux_path, mux_path ], cloud.uploads.grep(%r{/assemblages/})
    assert_equal "n" * 120, cloud.stored.fetch(mux_path)
  end

  # Reconstruction échouée (assemblage hors du dépôt), puis relancée : plus
  # d'entrée au dernier dépôt, le fichier refait est renvoyé à taille égale.
  test "un assemblage refait sans entrée au dernier dépôt est renvoyé, même à la même taille" do
    mux = add_recording(@webinar, kind: "participant", identity: "speaker-#{@basile.id}", file: "mux.mp4",
                                  bytes: "m" * 120, ended: Time.zone.parse("2030-01-17 10:29:35"))
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    mux_path = cloud.uploads.grep(%r{/assemblages/}).sole

    mux.update!(status: "failed")
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    File.binwrite(mux.absolute_path, "n" * 120)
    mux.update!(status: "done", ended_at: Time.zone.parse("2030-01-18 08:00:00"))
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert_equal [ mux_path, mux_path ], cloud.uploads.grep(%r{/assemblages/})
    assert_equal "n" * 120, cloud.stored.fetch(mux_path)
  end

  # La version d'un assemblage est notée dès son dépôt vérifié, pas à la fin
  # du dépôt : une panne plus loin ne le fait pas renvoyer (cas réel :
  # chaque reprise réécrasait l'assemblage déjà déposé, et l'écrasement par
  # morceaux plantait dans Nextcloud 30).
  test "assemblage refait et panne plus loin dans le dépôt : renvoyé une seule fois, pas à la reprise" do
    mux = add_recording(@webinar, kind: "participant", identity: "speaker-#{@basile.id}", file: "mux.mp4",
                                  bytes: "m" * 120, ended: Time.zone.parse("2030-01-17 10:29:35"))
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    mux.update!(ended_at: Time.zone.parse("2030-01-18 08:00:00"))

    cloud.fail_once_on = "README.md"
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    assert @webinar.reload.episode_publication.failed?
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    publication = @webinar.reload.episode_publication
    assert publication.published?
    assert_equal 2, cloud.uploads.count { |path| path.include?("/assemblages/") }
    assert_equal({}, publication.deposited_versions, "vidées au dépôt abouti : la version est dans `files`")
    assert_equal mux.ended_at.utc.iso8601(6), publication.files.find { |file| file["name"].include?("assemblages/") }["version"]
  end

  test "premier dépôt interrompu après l'assemblage : la reprise ne le renvoie pas" do
    add_recording(@webinar, kind: "participant", identity: "speaker-#{@basile.id}", file: "mux.mp4",
                            bytes: "m" * 120, ended: Time.zone.parse("2030-01-17 10:29:35"))
    cloud = FakeNextcloud.new(fail_once_on: "README.md")

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    publication = @webinar.reload.episode_publication
    assert publication.failed?
    assert_equal 1, publication.deposited_versions.size, "assemblage noté dès son dépôt vérifié"
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert @webinar.reload.episode_publication.published?
    assert_equal 1, cloud.uploads.count { |path| path.include?("/assemblages/") }
  end

  test "assemblage refait entre deux tentatives : renvoyé à la reprise, sa nouvelle version notée" do
    mux = add_recording(@webinar, kind: "participant", identity: "speaker-#{@basile.id}", file: "mux.mp4",
                                  bytes: "m" * 120, ended: Time.zone.parse("2030-01-17 10:29:35"))
    cloud = FakeNextcloud.new(fail_once_on: "README.md")
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    File.binwrite(mux.absolute_path, "n" * 120)
    mux.update!(ended_at: Time.zone.parse("2030-01-18 08:00:00"))
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    mux_path = cloud.uploads.grep(%r{/assemblages/}).uniq.sole
    assert_equal [ mux_path, mux_path ], cloud.uploads.grep(%r{/assemblages/})
    assert_equal "n" * 120, cloud.stored.fetch(mux_path)
  end

  test "une transcription complétée après le dépôt est republiée sans prévenir de nouveau" do
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    add_segment(@webinar, "Arrivé en retard.", at: Time.zone.parse("2030-01-17 10:20"))

    assert_no_emails { with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) } }
    assert_includes cloud.stored.fetch("#{@folder}/2030-01-17-cafe-ia-007-transcript.md"), "Arrivé en retard."
  end

  test "le README est réécrit à chaque dépôt, même quand sa taille ne change pas" do
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    readme = "#{@folder}/README.md"
    cloud.stored[readme] = cloud.stored[readme].tr("a-z", "*")

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }

    assert_includes cloud.stored.fetch(readme), "# Café IA #7 — 17 janvier 2030"
  end

  test "reprise après une panne : échec tracé, nouvelle tentative prévue, seuls les fichiers manquants repartent" do
    cloud = FakeNextcloud.new(fail_once_on: "pistes/")

    assert_no_emails do
      with_nextcloud(cloud) do
        assert_enqueued_with(job: PublishEpisodeJob, args: [ @webinar.id ]) { PublishEpisodeJob.perform_now(@webinar.id) }
      end
    end
    publication = @webinar.reload.episode_publication
    assert publication.failed?
    assert_match %r{\Apistes/basile-delmas-camera-.* : Nextcloud a répondu HTTP 503 à PUT\z}, publication.error_message
    assert_equal [ "#{@review}/video-complete-fin-10h27-#{@composite.id}.mp4" ], cloud.uploads

    assert_emails 2 do
      with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    end
    assert @webinar.reload.episode_publication.published?
    assert_nil @webinar.episode_publication.error_message
    assert_equal 1, cloud.uploads.count { |path| path.end_with?(".mp4") && path.include?("video-complete") }
  end

  test "une taille relue différente n'est pas un dépôt : échec rejouable, aucun mail" do
    cloud = FakeNextcloud.new(truncate_on: "README.md")

    assert_no_emails do
      with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    end
    publication = @webinar.reload.episode_publication
    assert publication.failed?
    assert_match(/\AREADME\.md : taille relue \d+, attendue \d+\z/, publication.error_message)
    assert_enqueued_jobs 1, only: PublishEpisodeJob
  end

  test "le nom du fichier en cause est sur la page, pas dans l'exception (journaux des jobs)" do
    cloud = FakeNextcloud.new
    def cloud.upload_file(path, local)
      raise NextcloudClient::Error, "Nextcloud a répondu HTTP 409 à PUT" if path.include?("pistes/")

      super
    end

    error = with_nextcloud(cloud) { assert_raises(NextcloudClient::Error) { PublishEpisodeJob.perform_now(@webinar.id) } }

    assert_equal "Nextcloud a répondu HTTP 409 à PUT", error.message
    assert_match(/\Apistes\/basile-delmas-camera-fin-10h27-\d+\.mp4 : /, @webinar.reload.episode_publication.error_message)
  end

  test "échec : marqueur d'alerte écrit sans le nom du fichier, retiré quand le dépôt aboutit" do
    cloud = FakeNextcloud.new(fail_once_on: "pistes/")
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    publication = @webinar.reload.episode_publication
    marker = PublicationFailureMarker.new(publication).path

    content = JSON.parse(marker.read)
    assert_equal "Nextcloud a répondu HTTP 503 à PUT", content["reason"]
    assert_equal Digest::SHA256.hexdigest(content["reason"])[0, 16], content["digest"]
    assert_equal [ publication.id, @webinar.id, "Café IA #7" ], content.values_at("publication_id", "webinar_id", "webinar")
    assert_no_match(/basile/i, marker.read)

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    assert @webinar.reload.episode_publication.published?
    assert_not marker.exist?
  end

  test "une erreur inattendue (fichier disparu pendant le dépôt) marque la publication en échec, sans la laisser « en cours »" do
    cloud = FakeNextcloud.new
    def cloud.upload_file(_path, local) = raise(Errno::ENOENT, local)

    with_nextcloud(cloud) { assert_raises(Errno::ENOENT) { PublishEpisodeJob.perform_now(@webinar.id) } }

    publication = @webinar.reload.episode_publication
    assert publication.failed?
    assert_match(/erreur inattendue \(Errno::ENOENT\)\z/, publication.error_message)
    assert_no_match(/#{Regexp.escape(@tmp)}/, publication.error_message)
  end

  test "direct repris avant l'exécution : rien n'est déposé, la publication attend la fin" do
    @webinar.create_episode_publication!(status: "queued", queued_at: Time.current)
    @webinar.update!(state: "live", ended_at: nil)
    cloud = FakeNextcloud.new

    assert_no_emails { with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) } }

    assert_empty cloud.uploads
    assert_equal "Direct en cours : le dépôt attend sa fin.", @webinar.reload.episode_publication.error_message
  end

  test "direct repris pendant le dépôt : fichiers déposés, mail reporté au dépôt qui suit la fin" do
    webinar = @webinar
    cloud = FakeNextcloud.new(after_store: ->(path) { webinar.update_columns(state: "live", ended_at: nil) if path.end_with?("README.md") })

    assert_no_emails { with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) } }
    assert @webinar.reload.episode_publication.published?

    @webinar.update_columns(state: "ended", ended_at: Time.zone.parse("2030-01-17 11:00"))
    assert_emails(2) { with_nextcloud(FakeNextcloud.new) { PublishEpisodeJob.perform_now(@webinar.id) } }
  end

  test "une erreur définitive (droits, espace) échoue sans nouvelle tentative" do
    cloud = FakeNextcloud.new
    def cloud.ensure_folder(_path) = raise(NextcloudClient::Error, "Nextcloud a répondu HTTP 403 à MKCOL")

    with_nextcloud(cloud) do
      assert_raises(NextcloudClient::Error) { PublishEpisodeJob.perform_now(@webinar.id) }
    end
    assert_equal "Nextcloud a répondu HTTP 403 à MKCOL", @webinar.reload.episode_publication.error_message
    assert_no_enqueued_jobs only: PublishEpisodeJob
  end

  test "configuration retirée entre l'enfilage et l'exécution : rien n'est déposé, la publication le dit" do
    @webinar.create_episode_publication!(status: "queued", queued_at: Time.current)

    assert_no_emails { PublishEpisodeJob.perform_now(@webinar.id) }

    publication = @webinar.reload.episode_publication
    assert publication.failed?
    assert_match(/non configurée/, publication.error_message)
  end

  test "un bootcamp n'est pas configuré : aucun dépôt" do
    bootcamp = ended_cafe(slug: "bootcamp-1", kind: "bootcamp")
    cloud = FakeNextcloud.new

    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(bootcamp.id) }

    assert_empty cloud.uploads
    assert_nil bootcamp.reload.episode_publication
  end

  test "un fichier ajouté après le dépôt (assemblage arrivé plus tard) : chacun reçoit la liste à jour" do
    cloud = FakeNextcloud.new
    with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    add_recording(@webinar, kind: "participant", identity: "speaker-#{@basile.id}", file: "mux.mp4",
                            ended: Time.zone.parse("2030-01-17 10:29:35"))

    assert_emails 2 do
      with_nextcloud(cloud) { PublishEpisodeJob.perform_now(@webinar.id) }
    end
    assert_match %r{assemblages/basile-delmas-\d+\.mp4}, ActionMailer::Base.deliveries.last.text_part.body.to_s
  end
end
