require "test_helper"

class VoiceTest < ActiveSupport::TestCase
  teardown { I18n.reload! }

  test "une émission avec sa tonalité : sa clé" do
    assert_equal "Je viens", Voice.t("webinars.registration_cta.submit", voice: "cafe_ia")
  end

  test "une clé que la tonalité n'écrit pas retombe sur le défaut, clé par clé" do
    store(default: { probe: { both: "défaut", only_default: "défaut seul" } }, cafe_ia: { probe: { both: "café" } })

    assert_equal "café", Voice.t("probe.both", voice: "cafe_ia")
    assert_equal "défaut seul", Voice.t("probe.only_default", voice: "cafe_ia")
  end

  test "une émission sans tonalité propre (bootcamp), ou aucune émission : le défaut" do
    assert_equal "M'inscrire", Voice.t("webinars.registration_cta.submit", voice: "bootcamp")
    assert_equal "M'inscrire", Voice.t("webinars.registration_cta.submit", voice: nil)
    assert_equal "M'inscrire", Voice.t("webinars.registration_cta.submit", voice: Voice::DEFAULT)
  end

  test "la copie se lit en français quelle que soit la langue du chrome" do
    I18n.with_locale(:en) do
      assert_equal "Je viens", Voice.t("webinars.registration_cta.submit", voice: "cafe_ia")
    end
  end

  test "mention d'enregistrement de la salle : vouvoiement par défaut, tutoiement café" do
    assert_match(/votre image et votre voix/,
                 Voice.t("webinars.participation_choice.recording_notice", voice: Voice::DEFAULT))
    assert_match(/ton image et ta voix/,
                 Voice.t("webinars.participation_choice.recording_notice", voice: "cafe_ia"))
  end

  test "interpolation" do
    assert_equal "Tu es inscrit·e, Lou. À très vite !",
                 Voice.t("webinars.registration_cta.registered", voice: "cafe_ia", name: "Lou")
  end

  test "clé absente partout : signalée comme manquante, pas de texte inventé" do
    assert_match(/translation missing/i, Voice.t("probe.nowhere", voice: "cafe_ia"))
  end

  test "tonalité commune : la seule présente, sinon le défaut" do
    assert_equal "cafe_ia", Voice.common(%w[cafe_ia cafe_ia])
    assert_equal Voice::DEFAULT, Voice.common(%w[cafe_ia bootcamp])
    assert_equal Voice::DEFAULT, Voice.common([])
  end

  test "Webinar#voice : la tonalité de son émission" do
    assert_equal "cafe_ia", Webinar.new(kind: "cafe_ia").voice
    assert_equal "bootcamp", Webinar.new(kind: "bootcamp").voice
  end

  test "RegistrationRequest#voice : émission commune, « préviens-moi » compte comme un café" do
    cafe = Webinar.create!(title: "Café", starts_at: 2.days.from_now, host_sub: "h", visibility: "published")
    bootcamp = Webinar.create!(title: "Bootcamp", kind: "bootcamp", starts_at: 3.days.from_now,
                               host_sub: "h", visibility: "published")

    assert_equal "cafe_ia", request_with(cafe).voice
    assert_equal "bootcamp", request_with(bootcamp).voice
    assert_equal Voice::DEFAULT, request_with(cafe, bootcamp).voice
    assert_equal Voice::DEFAULT, request_with(bootcamp, notify_next: true).voice
    assert_equal "cafe_ia", request_with(notify_next: true).voice
  end

  private

  def store(voices)
    I18n.backend.store_translations(:fr, voices: voices)
  end

  def request_with(*webinars, notify_next: false)
    request = RegistrationRequest.create!(name: "Lou", email: "lou-#{SecureRandom.hex(4)}@example.test",
                                          notify_next: notify_next)
    webinars.each do |webinar|
      Registration.find_or_create_for(webinar, email: request.email, name: request.name, registration_request: request)
    end
    request
  end
end
