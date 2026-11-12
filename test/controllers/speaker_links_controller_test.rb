require "test_helper"

# Rattachement prouvé par la personne (lien participants) :
# page à bouton sans effet, rattachement au POST, usage unique.
class SpeakerLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.day.from_now, host_sub: "host", visibility: "published")
    @registration = @webinar.registrations.create!(name: "Mathilde Courtois", email: "mathilde@example.test", confirmed_at: Time.current)
    @speaker = @webinar.speakers.create!(name: "Mathilde C.", declared_email: "mathilde@example.test")
  end

  test "la page ne rattache rien, ne pose aucun cookie, n'affiche ni nom ni adresse, et ne reste dans aucun cache" do
    get speaker_link_path(t: @speaker.link_token)

    assert_response :success
    assert_select "[data-role='speaker-link'] form[action=?][method=post]", confirm_speaker_link_path(t: @speaker.link_token)
    assert_nil @speaker.reload.registration
    assert_no_match(/Mathilde|mathilde@example/, response.body)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "strict-origin", response.headers["Referrer-Policy"]
    assert_no_match(/registration_id|share_speaker_/, response.headers["set-cookie"].to_s)
  end

  test "le bouton rattache, une seule fois" do
    token = @speaker.link_token
    post confirm_speaker_link_path(t: token)

    assert_response :success
    assert_select "[data-role='speaker-link-linked']"
    assert_equal @registration, @speaker.reload.registration
    assert_no_match(/registration_id|share_speaker_/, response.headers["set-cookie"].to_s)

    post confirm_speaker_link_path(t: token)
    assert_response :not_found
  end

  # Inscription NEUVE créée par le rattachement : sa première confirmation est
  # exemptée du total des renvois (RecipientMailThrottle, first_of).
  test "inscription neuve au rattachement : la première confirmation part même si les renvois de la boîte sont épuisés" do
    provisional = @webinar.registrations.create!(name: "Intrus", email: "victime@example.test", instant_access_at: Time.current)
    speaker = @webinar.speakers.create!(name: "Intrus", declared_email: "victime@example.test")
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      RecipientMailThrottle.default.claim("victime@example.test", "renvoi:#{index}")
    end

    assert_enqueued_email_with RegistrationMailer, :confirmation, args: ->(args) { args.first.email == "victime@example.test" && args.first != provisional } do
      post confirm_speaker_link_path(t: speaker.link_token)
    end
    assert_response :success
    assert_select "[data-role='speaker-link-linked']"
  end

  test "un lien qui a servi ne rattache plus : 404 ; un intervenant retiré entre-temps : 410" do
    token = @speaker.link_token
    @speaker.link_to_declared_registration!

    post confirm_speaker_link_path(t: token)
    assert_response :not_found
    assert_select "[data-role='speaker-link-invalid']"

    removed = @webinar.speakers.create!(name: "Retiré", declared_email: "mathilde@example.test")
    removed.remove_from_room!
    post confirm_speaker_link_path(t: removed.link_token)
    assert_response :gone
    assert_nil removed.reload.registration
  end

  test "adresse en identité provisoire : inscription neuve rattachée, mail de confirmation à l'adresse" do
    @registration.update_columns(confirmed_at: nil, instant_access_at: Time.current)

    assert_enqueued_email_with RegistrationMailer, :confirmation, args: ->(args) { args.first.email == "mathilde@example.test" && args.first != @registration } do
      post confirm_speaker_link_path(t: @speaker.link_token)
    end
    assert_response :success
    assert @registration.reload.retired?
    assert_equal "mathilde@example.test", @speaker.reload.registration.email
  end

  test "lien de plus de 14 jours : 410, rien n'est rattaché" do
    token = @speaker.link_token

    travel 15.days do
      get speaker_link_path(t: token)
      assert_response :gone
      post confirm_speaker_link_path(t: token)
      assert_response :gone
    end
    assert_nil @speaker.reload.registration
  end

  test "jeton absent ou inconnu : 404, jamais 500" do
    get speaker_link_path
    assert_response :not_found
    post confirm_speaker_link_path(t: "inconnu")
    assert_response :not_found
  end
end
