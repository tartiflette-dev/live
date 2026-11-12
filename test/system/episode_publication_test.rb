# frozen_string_literal: true

require "application_system_test_case"

# Parcours de l'animation : saisir l'adresse d'un intervenant, publier
# l'épisode depuis la page du webinaire, voir l'état du dépôt, relire puis
# valider et partager la vidéo complète.
class EpisodePublicationSystemTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include EpisodePublicationHelpers

  setup do
    @tmp = Dir.mktmpdir("publication-system")
    @previous_root = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = @tmp
    @webinar = ended_cafe(slug: "cafe-ia-7")
    @speaker = @webinar.speakers.create!(name: "Basile Delmas")
    @composite = add_recording(@webinar, kind: "composite", file: "seance.mp4")
    @cloud = FakeNextcloud.new
    @previous_factory = Rails.configuration.x.nextcloud_client_factory
    cloud = @cloud
    Rails.configuration.x.nextcloud_client_factory = -> { cloud }
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: "publication-host", info: { email: "marc@example.test" }
    )
  end

  teardown do
    Rails.configuration.x.nextcloud_client_factory = @previous_factory
    ENV["RECORDINGS_ROOT"] = @previous_root
    FileUtils.remove_entry(@tmp)
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "l'animateur saisit l'adresse de l'intervenant, publie, et voit le dépôt et le mail envoyé" do
    User.find_by!(oidc_sub: "publication-host").update!(admin: true)
    visit "/auth/pocket_id/callback"
    visit webinar_path(@webinar)
    assert_text "Pas encore publiée."

    within("[data-speaker-id='#{@speaker.id}']") do
      fill_in "Email de Basile Delmas", with: "basile@example.test"
      click_on "Enregistrer"
    end
    assert_text "Adresse de l'intervenant enregistrée."

    click_on "Publier dans Nextcloud"
    assert_text "Publication dans Nextcloud lancée."
    assert_text "En attente"

    perform_enqueued_jobs(only: PublishEpisodeJob)
    visit webinar_path(@webinar)
    within("[data-role='publication']") do
      assert_text "Publiée"
      assert_link "Cafe-IA/2030-01-17-cafe-ia-007", href: "https://cloud.test/f/4242"
      assert_text "Mail envoyé à : basile@example.test."
      assert_button "Relancer la publication"
    end
    assert_includes @cloud.stored.keys, "Cafe-IA/2030-01-17-cafe-ia-007/README.md"
  end

  test "versions légères en préparation : la page le dit, le bouton dépose tout de suite l'original" do
    @webinar.update!(started_at: 90.minutes.ago, ended_at: 30.minutes.ago)
    visit "/auth/pocket_id/callback"
    with_light_versions do
      visit webinar_path(@webinar)
      assert_text "Versions légères des vidéos en préparation (1 fichier), au plus 6 h"

      click_on "Publier dans Nextcloud"
      perform_enqueued_jobs(only: PublishEpisodeJob)
    end

    assert_equal "x" * 32, @cloud.stored.fetch("Relecture/Cafe-IA/2030-01-17-cafe-ia-007/video-complete-fin-10h27-#{@composite.id}.mp4")
  end

  test "la vidéo complète attend la relecture ; « Valider et partager » la déplace et prévient l'intervenant" do
    @speaker.update!(email: "basile@example.test")
    video = "video-complete-fin-10h27-#{@composite.id}.mp4"
    visit "/auth/pocket_id/callback"
    visit webinar_path(@webinar)
    click_on "Publier dans Nextcloud"
    perform_enqueued_jobs(only: PublishEpisodeJob)
    visit webinar_path(@webinar)

    within("[data-role='publication-review']") do
      assert_link "Relecture/Cafe-IA/2030-01-17-cafe-ia-007", href: "https://cloud.test/f/7777"
      assert_text video
    end
    assert_not @cloud.stored.key?("Cafe-IA/2030-01-17-cafe-ia-007/#{video}")
    assert_no_match(/#{video}/, ActionMailer::Base.deliveries.last.text_part.body.to_s)

    click_on "Valider et partager"
    assert_text "1 vidéo validée : déplacement vers le dossier partagé lancé."
    assert_text "validée par marc@example.test, déplacement au prochain dépôt"

    perform_enqueued_jobs(only: PublishEpisodeJob)
    visit webinar_path(@webinar)
    assert_no_selector "[data-role='publication-review']"
    assert_text "2 fichiers partagés dans"
    assert @cloud.stored.key?("Cafe-IA/2030-01-17-cafe-ia-007/#{video}")
    assert_includes ActionMailer::Base.deliveries.last.text_part.body.to_s, "- #{video}"
  end
end
