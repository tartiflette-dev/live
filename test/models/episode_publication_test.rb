# frozen_string_literal: true

require "test_helper"

# EpisodePublication — quand un épisode est-il publiable automatiquement ?
# Direct terminé à 10:28:30 ; NOW = 10:40, hors du délai de calme.
class EpisodePublicationTest < ActiveSupport::TestCase
  include EpisodePublicationHelpers

  NOW = Time.zone.parse("2030-01-17 10:40")

  test "configuration : une série absente du YAML (bootcamp) ou un compte Nextcloud manquant désactivent" do
    cafe = ended_cafe
    bootcamp = ended_cafe(kind: "bootcamp")

    assert_equal EpisodePublication::Series.new(folder: "Cafe-IA", review_folder: "Relecture/Cafe-IA", reviewers: [ "relecteur" ]),
                 EpisodePublication.series(cafe)
    assert_nil EpisodePublication.series(bootcamp)
    assert_not EpisodePublication.configured_for?(cafe), "en test, la factory ne construit jamais de vrai client"
    with_nextcloud(FakeNextcloud.new) do
      assert EpisodePublication.configured_for?(cafe)
      assert_not EpisodePublication.configured_for?(bootcamp)
    end
  end

  test "relecteurs hors test : lus dans EPISODE_REVIEWERS, aucun par défaut" do
    reviewers = lambda do |value|
      previous = ENV["EPISODE_REVIEWERS"]
      value.nil? ? ENV.delete("EPISODE_REVIEWERS") : ENV["EPISODE_REVIEWERS"] = value
      EpisodePublication::Series.new(**Rails.application.config_for(:episode_publication, env: "production")[:cafe_ia]).reviewers
    ensure
      previous.nil? ? ENV.delete("EPISODE_REVIEWERS") : ENV["EPISODE_REVIEWERS"] = previous
    end

    assert_equal [], reviewers.(nil)
    assert_equal [], reviewers.(" , ")
    assert_equal [ "alice" ], reviewers.("alice")
    assert_equal [ "alice", "bob" ], reviewers.(" alice, bob ,")
  end

  test "automatic_hold : rien ne retient un direct public terminé, avec contenu, hors délai de calme" do
    assert_nil EpisodePublication.automatic_hold(publishable_cafe, now: NOW)
  end

  test "automatic_hold : chaque condition retient seule le dépôt automatique" do
    assert_equal :not_ended, hold_of(publishable_cafe.tap { |w| w.update!(state: "live") })
    assert_equal :not_ended, hold_of(publishable_cafe.tap { |w| w.update_columns(ended_at: nil) })
    assert_equal :draft, hold_of(publishable_cafe(visibility: "draft"))
    assert_equal :too_old, hold_of(publishable_cafe(ended: NOW - 24.hours - 1.minute))
    assert_equal :quiet, hold_of(publishable_cafe(ended: NOW - 9.minutes))
    assert_equal :empty, hold_of(ended_cafe)
  end

  test "automatic_hold : enregistrement encore actif, puis assemblage manquant" do
    with_recordings_root do
      webinar = ended_cafe
      add_recording(webinar, kind: "composite", file: "seance.mp4", status: "stopping")
      assert_equal :recording, hold_of(webinar)

      webinar.recordings.update_all(status: "done")
      add_recording(webinar, kind: "track", identity: "speaker-1", source: "camera", file: "c.mp4")
      assert_equal :muxing, hold_of(webinar)
    end
  end

  test "assemblage : terminal et lancé après la dernière piste de la personne, celui d'une répétition ne compte pas" do
    with_recordings_root do
      webinar = ended_cafe
      add_recording(webinar, kind: "track", identity: "speaker-1", source: "camera", file: "c.mp4",
                             ended: Time.zone.parse("2030-01-17 10:27:44"))
      add_recording(webinar, kind: "track", identity: "speaker-2", source: "camera", file: "d.mp4", status: "failed")
      assert_equal [ "speaker-1" ], EpisodePublication.unmuxed_identities(webinar), "assemblage pas encore lancé"

      mux = add_recording(webinar, kind: "participant", identity: "speaker-1", file: "mux-speaker-1.mp4",
                                   started: Time.zone.parse("2030-01-17 09:09:27"), ended: Time.zone.parse("2030-01-17 09:09:32"))
      assert_equal [ "speaker-1" ], EpisodePublication.unmuxed_identities(webinar), "assemblage de la répétition"

      mux.update!(status: "starting", started_at: Time.zone.parse("2030-01-17 10:28:30"))
      assert_equal [ "speaker-1" ], EpisodePublication.unmuxed_identities(webinar), "assemblage en cours"

      mux.update!(status: "failed")
      assert_empty EpisodePublication.unmuxed_identities(webinar), "un échec est terminal ; speaker-2 n'a aucune piste terminée"
      assert_nil hold_of(webinar)
    end
  end

  test "dû : jamais publié, puis plus rien tant que rien ne change, de nouveau après un changement" do
    webinar = publishable_cafe
    with_nextcloud(FakeNextcloud.new) do
      assert EpisodePublication.due?(webinar, now: NOW)

      publication = webinar.create_episode_publication!(status: "published", started_at: NOW, queued_at: NOW)
      assert_not EpisodePublication.due?(webinar, now: NOW + 5.minutes)

      publication.update!(status: "failed")
      assert_not EpisodePublication.due?(webinar, now: NOW + 5.minutes), "un échec se relance au bouton ou par le job"

      add_segment(webinar, "Arrivé en retard.", at: NOW - 30.minutes).update_columns(updated_at: NOW + 1.minute)
      assert EpisodePublication.due?(webinar, now: NOW + 5.minutes), "un segment de transcription arrivé après le dépôt"
    end
  end

  test "dû : un enregistrement terminé après le dépôt relance la publication" do
    with_recordings_root do
      webinar = publishable_cafe
      with_nextcloud(FakeNextcloud.new) do
        webinar.create_episode_publication!(status: "published", started_at: NOW, queued_at: NOW)
        add_recording(webinar, kind: "composite", file: "reprise.mp4").update_columns(updated_at: NOW + 1.minute)

        assert EpisodePublication.due?(webinar, now: NOW + 5.minutes)
      end
    end
  end

  test "dû : un accord retiré ou redonné après le dépôt le fait refaire, même hors de la fenêtre automatique" do
    webinar = publishable_cafe
    speaker = webinar.speakers.create!(name: "Basile Delmas")
    consent = ParticipantConsent.grant!(speaker, recording: true, excerpts: true, adult: true, now: NOW - 1.hour)
    consent.update_columns(updated_at: NOW - 1.hour)
    long_after = NOW + 10.days
    with_nextcloud(FakeNextcloud.new) do
      webinar.create_episode_publication!(status: "published", started_at: NOW, queued_at: NOW)
      assert_equal :too_old, EpisodePublication.automatic_hold(webinar, now: long_after)
      assert_not EpisodePublication.due?(webinar, now: long_after)

      travel_to(long_after - 1.minute) { consent.withdraw! }
      assert EpisodePublication.due?(webinar, now: long_after), "accord retiré après le dépôt"
      assert EpisodePublication.last_change_at(webinar) > NOW

      webinar.episode_publication.update!(started_at: long_after)
      assert_not EpisodePublication.due?(webinar, now: long_after + 5.minutes), "redéposé : plus rien à refaire"
    end
  end

  test "dû : un changement d'accord ne relance pas un épisode jamais déposé, ni un direct en cours" do
    webinar = publishable_cafe
    speaker = webinar.speakers.create!(name: "Basile Delmas")
    with_nextcloud(FakeNextcloud.new) do
      webinar.create_episode_publication!(status: "published", started_at: NOW, queued_at: NOW)
      webinar.update!(state: "live")
      travel_to(NOW + 1.minute) { ParticipantConsent.grant!(speaker, recording: true, excerpts: false, adult: true) }

      assert_not EpisodePublication.due?(webinar, now: NOW + 5.minutes)
    end
  end

  test "dû : un dépôt en attente ou en cours ne se relance pas, sauf s'il est resté bloqué" do
    webinar = publishable_cafe
    stalled = NOW + EpisodePublication::STALL_AFTER + 1.minute
    with_nextcloud(FakeNextcloud.new) do
      publication = webinar.create_episode_publication!(status: "queued", queued_at: NOW)
      assert_not EpisodePublication.due?(webinar, now: NOW + 5.minutes)
      assert EpisodePublication.due?(webinar, now: stalled), "file perdue : jamais démarré"

      publication.update!(status: "publishing", started_at: NOW)
      assert_not EpisodePublication.due?(webinar, now: NOW + 5.minutes)
      assert EpisodePublication.due?(webinar, now: stalled), "processus tué pendant l'upload"
    end
  end

  test "busy? : en attente ou en cours depuis moins de STALL_AFTER" do
    publication = EpisodePublication.new(status: "publishing", started_at: NOW)

    assert publication.busy?(NOW + 1.hour)
    assert_not publication.busy?(NOW + EpisodePublication::STALL_AFTER + 1.minute)
    assert_not EpisodePublication.new(status: "published", started_at: NOW).busy?(NOW)
  end

  test "série : dossier partagé et dossier de relecture jamais emboîtés (un partage couvre les sous-dossiers)" do
    [ [ "Cafe-IA", "Cafe-IA/relecture" ], [ "Relecture/Cafe-IA", "Relecture" ], [ "Cafe-IA", "Cafe-IA" ] ].each do |folder, review|
      assert_raises(ArgumentError, "#{folder} / #{review}") { EpisodePublication::Series.new(folder: folder, review_folder: review) }
    end
    assert_equal [], EpisodePublication::Series.new(folder: "Cafe-IA", review_folder: "Cafe-IA-relecture").reviewers
    assert_raises(ArgumentError, "dossier de relecture obligatoire") { EpisodePublication::Series.new(folder: "Cafe-IA") }
  end

  test "complete! garde les intervenants prévenus si les mêmes fichiers reviennent, les oublie sur un nouveau fichier partagé" do
    publication = ended_cafe.create_episode_publication!(status: "publishing", files: [ shared("a", 1) ],
                                                         notified_emails: [ "b@example.test" ])

    publication.complete!(deposited: [ shared("a", 1) ], **links)
    assert_equal [ "b@example.test" ], publication.notified_emails

    publication.complete!(deposited: [ shared("a", 7) ], **links)
    assert_equal [ "b@example.test" ], publication.notified_emails, "même nom réécrit (transcription complétée)"

    publication.complete!(deposited: [ shared("a", 7), in_review("video-complete-1.mp4") ], **links)
    assert_equal [ "b@example.test" ], publication.notified_emails, "une vidéo arrivée en relecture n'est pas annoncée"

    publication.complete!(deposited: [], **links)
    assert_equal [ "b@example.test" ], publication.notified_emails, "un fichier disparu n'apporte rien à annoncer"

    publication.complete!(deposited: [ shared("a", 1), shared("b", 2) ], **links)
    assert_equal [], publication.notified_emails
    assert publication.published?
    assert_equal "https://cloud.test/f/7777", publication.review_folder_url
  end

  test "approve! valide les seules vidéos en relecture nommées, et dit qui les a validées" do
    publication = ended_cafe.create_episode_publication!(
      status: "published", files: [ shared("README.md", 1), in_review("video-complete-1.mp4"), in_review("pistes/marc-partage-ecran-2.mp4") ]
    )

    travel_to(NOW) do
      assert_equal 1, publication.approve!([ "video-complete-1.mp4", "README.md", "inconnu.mp4" ], by: "marc@example.test")
    end

    files = publication.reload.files.index_by { |file| file["name"] }
    assert_equal({ "name" => "video-complete-1.mp4", "size" => 9, "zone" => "approved",
                   "approved_by" => "marc@example.test", "approved_at" => NOW.iso8601 }, files.fetch("video-complete-1.mp4"))
    assert_equal "review", files.fetch("pistes/marc-partage-ecran-2.mp4")["zone"], "pas montrée : pas validée"
    assert_equal "shared", files.fetch("README.md")["zone"]
    assert_equal 0, publication.approve!([ "video-complete-1.mp4" ], by: "marc@example.test"), "déjà validée"
  end

  test "approvable? : direct terminé, une vidéo en relecture, aucun dépôt en cours" do
    webinar = ended_cafe
    publication = webinar.create_episode_publication!(status: "published", files: [ in_review("video-complete-1.mp4") ])
    assert publication.approvable?(NOW)

    publication.update!(status: "publishing", started_at: NOW - 1.minute)
    assert_not publication.approvable?(NOW), "dépôt en cours"

    publication.update!(status: "published", files: [ shared("README.md", 1) ])
    assert_not publication.approvable?(NOW), "rien en relecture"

    publication.update!(files: [ in_review("video-complete-1.mp4") ])
    webinar.update!(state: "live", ended_at: nil)
    assert_not publication.reload.approvable?(NOW), "direct repris"
  end

  test "complete! garde une validation enregistrée pendant le dépôt" do
    publication = ended_cafe.create_episode_publication!(status: "publishing", files: [ in_review("video-complete-1.mp4") ])
    deposited = [ in_review("video-complete-1.mp4") ]
    EpisodePublication.find(publication.id).approve!([ "video-complete-1.mp4" ], by: "marc@example.test")

    publication.complete!(deposited: deposited, **links)

    assert_equal [ "approved" ], publication.reload.files.pluck("zone")
  end

  private

  # Café IA public terminé, avec une transcription : rien ne le retient.
  def publishable_cafe(**options)
    ended_cafe(**options).tap { |webinar| add_segment(webinar, "Bonjour.", at: Time.zone.parse("2030-01-17 09:31:36")) }
  end

  def hold_of(webinar)
    EpisodePublication.automatic_hold(webinar.reload, now: NOW)
  end

  def shared(name, size) = { "name" => name, "size" => size, "zone" => "shared" }
  def in_review(name) = { "name" => name, "size" => 9, "zone" => "review" }
  def links = { folder_url: "https://cloud.test/f/4242", review_folder_url: "https://cloud.test/f/7777" }
end
