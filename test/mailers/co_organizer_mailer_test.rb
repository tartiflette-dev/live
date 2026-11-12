require "test_helper"

class CoOrganizerMailerTest < ActionMailer::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA de novembre", starts_at: 3.days.from_now, host_sub: "h", visibility: "published")
    @request = RegistrationRequest.create!(
      name: "Camille", email: "camille@example.test", source: "tartiflette.dev", profile: "design",
      message: "Je viendrai avec deux collègues.", notify_next: true, confirmed_at: Time.current
    )
    Registration.find_or_create_for(@webinar, email: @request.email, name: @request.name, registration_request: @request)
  end

  test "message : texte intégral, prénom, email, cafés, profil, « préviens-moi », dates ; réponse vers la personne" do
    @request.update_columns(created_at: Time.zone.local(2026, 11, 2, 9, 30), confirmed_at: Time.zone.local(2026, 11, 2, 9, 45))
    mail = CoOrganizerMailer.message_received(@request, to: "orga@tartiflette.test")
    body = mail.body.to_s

    assert_equal [ "orga@tartiflette.test" ], mail.to
    assert_equal [ "camille@example.test" ], mail.reply_to
    assert_equal "Café IA — message d'une inscription confirmée", mail.subject
    assert_match(/Prénom : Camille/, body)
    assert_match(/Email : camille@example\.test/, body)
    assert_match(/Café IA de novembre/, body)
    assert_match(/Profil : design/, body)
    assert_match(/Je viendrai avec deux collègues\./, body)
    assert_match(/Prévenir du prochain Café IA : oui/, body)
    assert_match(/Demande reçue le #{Regexp.escape(I18n.l(@request.created_at, format: :long))}/, body)
    assert_match(/confirmée le #{Regexp.escape(I18n.l(@request.confirmed_at, format: :long))}/, body)
  end

  test "message de plusieurs lignes : transmis en entier" do
    @request.update!(message: "Bonjour,\nje propose une présentation sur les agents.\nÀ bientôt")
    body = CoOrganizerMailer.message_received(@request, to: "orga@tartiflette.test").body.to_s
    assert_includes body, "Bonjour,\nje propose une présentation sur les agents.\nÀ bientôt"
  end

  test "SÉCURITÉ : le sujet ne reprend aucun texte saisi par la personne" do
    @request.update!(name: "Camille\r\nBcc: victime@example.test")
    mail = CoOrganizerMailer.message_received(@request, to: "orga@tartiflette.test")
    assert_no_match(/Camille|Bcc/, mail.subject)
    assert_nil mail.bcc
  end

  test "hors Café IA, la tonalité par défaut ne nomme aucune émission" do
    other = Webinar.create!(title: "Atelier de décembre", kind: "bootcamp", starts_at: 5.days.from_now, host_sub: "h",
                            visibility: "published")
    request = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", source: "tartiflette.dev",
                                          message: "Bonjour", notify_next: false, confirmed_at: Time.current)
    Registration.find_or_create_for(other, email: request.email, name: request.name, registration_request: request)

    mail = CoOrganizerMailer.message_received(request, to: "orga@tartiflette.test")
    body = mail.body.to_s
    assert_equal "Message d'une inscription confirmée", mail.subject
    assert_match(/Webinaire\(s\) :\n- Atelier de décembre/, body)
    assert_match(/Prévenir du prochain webinaire : non/, body)
    assert_no_match(/Café/, mail.subject + body)
  end

  test "profil absent, sans « préviens-moi » : mentions explicites" do
    @request.update!(profile: nil, notify_next: false)
    body = CoOrganizerMailer.message_received(@request, to: "orga@tartiflette.test").body.to_s
    assert_match(/Profil : non renseigné/, body)
    assert_match(/Prévenir du prochain Café IA : non/, body)
  end
end
