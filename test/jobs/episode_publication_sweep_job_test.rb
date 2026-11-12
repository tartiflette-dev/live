# frozen_string_literal: true

require "test_helper"

# EpisodePublicationSweepJob — déclencheur automatique. Chaque webinaire
# écarté a du contenu et des enregistrements finalisés : seule la condition
# qu'il illustre le distingue du direct publié.
class EpisodePublicationSweepJobTest < ActiveJob::TestCase
  include EpisodePublicationHelpers

  NOW = Time.zone.parse("2030-01-17 10:40")

  test "publie le seul direct public, terminé depuis 10 min à 24 h, finalisé et d'une série configurée" do
    with_recordings_root do
      published = finalized_cafe
      ignored = {
        draft:      finalized_cafe(visibility: "draft"),
        too_old:    finalized_cafe(ended: NOW - 24.hours - 1.minute),
        quiet:      finalized_cafe(ended: NOW - 5.minutes),
        live:       finalized_cafe.tap { |webinar| webinar.update!(state: "live") },
        bootcamp:   finalized_cafe(kind: "bootcamp"),
        recording:  finalized_cafe.tap { |webinar| webinar.recordings.update_all(status: "stopping") }
      }

      with_nextcloud(FakeNextcloud.new) { EpisodePublicationSweepJob.perform_now(now: NOW) }

      assert_equal [ [ published.id ] ], enqueued_jobs_for(PublishEpisodeJob)
      ignored.each { |reason, webinar| assert_nil webinar.reload.episode_publication, reason }
    end
  end

  test "une seule fois : le balayage suivant ne republie pas un épisode inchangé" do
    with_recordings_root do
      webinar = finalized_cafe
      with_nextcloud(FakeNextcloud.new) do
        travel_to(NOW) { EpisodePublicationSweepJob.perform_now }
        assert webinar.reload.episode_publication.queued?

        travel_to(NOW + 5.minutes) { EpisodePublicationSweepJob.perform_now }
      end
      assert_equal 1, enqueued_jobs_for(PublishEpisodeJob).size
    end
  end

  test "direct repris avant le dépôt : la publication attend, puis repart après la nouvelle fin" do
    with_recordings_root do
      webinar = finalized_cafe
      with_nextcloud(FakeNextcloud.new) do
        travel_to(NOW) do
          EpisodePublicationSweepJob.perform_now
          webinar.update!(state: "live", ended_at: nil)
          perform_enqueued_jobs(only: PublishEpisodeJob)
        end
        assert webinar.reload.episode_publication.failed?, "l'attente ne reste pas « en file » : elle bloquerait le balayage 3 h"
        assert_equal "Direct en cours : le dépôt attend sa fin.", webinar.episode_publication.error_message

        webinar.update!(state: "ended", ended_at: NOW + 30.minutes)
        travel_to(NOW + 35.minutes) { EpisodePublicationSweepJob.perform_now }
        assert_empty enqueued_jobs_for(PublishEpisodeJob), "délai de calme après la nouvelle fin"

        travel_to(NOW + 45.minutes) { EpisodePublicationSweepJob.perform_now }
        assert_equal [ [ webinar.id ] ], enqueued_jobs_for(PublishEpisodeJob)
      end
    end
  end

  test "direct repris après un dépôt : republié après la nouvelle fin" do
    with_recordings_root do
      webinar = finalized_cafe
      webinar.create_episode_publication!(status: "published", queued_at: NOW, started_at: NOW, published_at: NOW)
      webinar.update!(ended_at: NOW + 30.minutes)

      with_nextcloud(FakeNextcloud.new) { EpisodePublicationSweepJob.perform_now(now: NOW + 45.minutes) }

      assert_equal [ [ webinar.id ] ], enqueued_jobs_for(PublishEpisodeJob)
    end
  end

  test "versions légères : le balayage les demande et retient le dépôt jusqu'à ce qu'elles soient prêtes" do
    with_recordings_root do |root|
      webinar = finalized_cafe
      composite = webinar.recordings.sole
      with_light_versions do
        with_nextcloud(FakeNextcloud.new) do
          EpisodePublicationSweepJob.perform_now(now: NOW)
          assert_empty enqueued_jobs_for(PublishEpisodeJob)
          assert_equal :lightening, EpisodePublication.automatic_hold(webinar, now: NOW)
          assert root.join("_leger/demandes/#{composite.id}.json").file?, "demande écrite pour l'hôte"

          produce_light_version(composite, "leger")
          EpisodePublicationSweepJob.perform_now(now: NOW + 5.minutes)
          assert_equal [ [ webinar.id ] ], enqueued_jobs_for(PublishEpisodeJob)
        end
      end
    end
  end

  test "versions légères pas prêtes WAIT après la demande : l'original part" do
    with_recordings_root do
      webinar = finalized_cafe
      with_light_versions do
        with_nextcloud(FakeNextcloud.new) do
          EpisodePublicationSweepJob.perform_now(now: NOW)
          EpisodePublicationSweepJob.perform_now(now: NOW + LightVersion::WAIT + 5.minutes)
        end
      end

      assert_equal [ [ webinar.id ] ], enqueued_jobs_for(PublishEpisodeJob)
    end
  end

  test "sans compte Nextcloud configuré, le balayage ne fait rien" do
    with_recordings_root do
      finalized_cafe

      EpisodePublicationSweepJob.perform_now(now: NOW)

      assert_empty enqueued_jobs_for(PublishEpisodeJob)
    end
  end

  test "câblage : tâche récurrente de production toutes les 5 minutes" do
    recurring = YAML.safe_load(Rails.root.join("config/recurring.yml").read, aliases: true)

    assert_equal({ "class" => "EpisodePublicationSweepJob", "queue" => "default", "schedule" => "every 5 minutes" },
                 recurring.dig("production", "episode_publication_sweep"))
    assert_empty recurring.fetch("test")
  end

  private

  # Direct terminé avec un composite terminé et sa transcription.
  def finalized_cafe(**options)
    ended_cafe(**options).tap do |webinar|
      add_recording(webinar, kind: "composite", file: "seance.mp4")
      add_segment(webinar, "Bonjour.", at: Time.zone.parse("2030-01-17 09:31:36"))
    end
  end

  def enqueued_jobs_for(job_class)
    enqueued_jobs.select { |job| job["job_class"] == job_class.name }.map { |job| job["arguments"] }
  end
end
