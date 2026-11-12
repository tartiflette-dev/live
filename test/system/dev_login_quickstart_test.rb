# frozen_string_literal: true

require "application_system_test_case"

# Parcours du quickstart (docs/quickstart.md) : connexion de développement,
# création d'un webinaire, scène de l'animateur.
class DevLoginQuickstartTest < ApplicationSystemTestCase
  setup do
    @previous = ENV.to_h.slice("LIVE_DEV_LOGIN", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET")
    ENV["LIVE_DEV_LOGIN"] = "1"
    ENV["LIVEKIT_API_KEY"] = "APIfake"
    ENV["LIVEKIT_API_SECRET"] = "sekret-32bytes-long-enough-abcdef"
  end

  teardown do
    %w[LIVE_DEV_LOGIN LIVEKIT_API_KEY LIVEKIT_API_SECRET].each do |name|
      @previous.key?(name) ? ENV[name] = @previous[name] : ENV.delete(name)
    end
  end

  test "connexion de dev, création d'un webinaire, scène" do
    visit sign_in_path
    within("form[data-role='dev-login']") do
      fill_in "Adresse e-mail", with: "host@example.test"
      click_on "Se connecter (développement)"
    end
    assert_current_path webinars_path

    visit new_webinar_path
    fill_in "Titre", with: "Quickstart"
    fill_in "Démarre le", with: 1.day.from_now.strftime("%Y-%m-%dT%H:%M")
    click_on "Créer le webinaire"

    webinar = Webinar.find_by!(title: "Quickstart")
    assert_equal "#{DevLogin::SUB_PREFIX}host@example.test", webinar.host_sub

    visit stage_webinar_path(slug: webinar.slug)
    assert_current_path stage_webinar_path(slug: webinar.slug)
    assert_selector "#livekit-room[data-slug='#{webinar.slug}']", visible: :all
  end
end
