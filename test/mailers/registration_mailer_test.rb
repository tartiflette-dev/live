require "test_helper"

# Les invariants (destinataire, liens, mentions obligatoires, absence de
# bloc marketing) valent pour TOUTES les tonalités : ils sont vérifiés sur
# un Café IA (tonalité propre, tutoiement) ET sur un bootcamp (tonalité
# par défaut). Les textes propres à chaque tonalité ont leurs tests.
class RegistrationMailerTest < ActionMailer::TestCase
  KINDS = %w[cafe_ia bootcamp].freeze

  setup do
    @webinar = create_webinar("cafe_ia", title: "Café IA public")
    @registration = @webinar.registrations.create!(name: "Bob", email: "bob@example.test")
  end

  # ---- Demande groupée de l'API (docs/registrations-api.md) ---------------

  KINDS.each do |kind|
    test "request_confirmation (#{kind}) : UN lien /confirmer?t= pour tous les webinaires de la demande" do
      first = create_webinar(kind, title: "Premier rendez-vous")
      other = create_webinar(kind, title: "Rendez-vous suivant", starts_at: 8.days.from_now)
      request = request_for(first, other)

      mail = RegistrationMailer.request_confirmation(request)

      assert_equal [ "camille@example.test" ], mail.to
      bodies(mail).each do |body|
        assert_match(/Premier rendez-vous/, body)
        assert_match(/Rendez-vous suivant/, body)
        assert_match(%r{http://[^"\s]+/confirmer\?t=#{Regexp.escape(request.token)}}, body)
        assert_no_match(%r{/r/}, body, "pas de lien d'inscription par café : un seul lien pour la demande")
        assert_no_match(/recontacte/, body, "case de recontact non cochée : aucune mention")
        assert_match(/sans confirmation, (elle|la demande) est effacée sous 30 jours/, body)
        assert_no_match(/rien ne sera enregistré/, body, "la demande est stockée dès la soumission")
      end
    end
  end

  # Case de recontact cochée (politique v1.6) : l'annonce
  # dit que la case « a été cochée lors de cette demande » (un tiers a pu la
  # cocher) et cite les DEUX boutons de la page, dans la tonalité de la page.
  BOX_CHECKED = /La case « Ok pour que Studio Exemple me recontacte au sujet de ses activités\. Je peux dire stop quand je veux\. » a été\s+cochée lors de cette demande/
  CHOICES = {
    "cafe_ia" => [ /« Je confirme, et Studio Exemple peut\s+me recontacter »/, /« Je confirme, sans être recontacté·e »/ ],
    "bootcamp" => [ /« Confirmer et accepter d'être\s+recontacté·e »/, /« Confirmer sans être recontacté·e »/ ]
  }.freeze

  CHOICES.each do |kind, choices|
    test "request_confirmation (#{kind}), case de recontact cochée : les deux choix, et comment dire stop" do
      request = request_for(create_webinar(kind), marketing_box_checked: true)

      bodies(RegistrationMailer.request_confirmation(request)).each do |body|
        assert_match(BOX_CHECKED, body)
        assert_no_match(/(Vous avez|Tu as) coché/, body, "la case a pu être cochée par un tiers (B1)")
        choices.each { |choice| assert_match(choice, body, "le mail cite les libellés exacts des boutons") }
        assert_match(/« ne plus être recontacté·e »/, body)
        assert_match(/contact@example\.test/, body)
        assert_no_match(%r{/mc\?t=}, body, "pas de second lien de validation")
      end
    end
  end

  test "request_confirmation Café IA, « préviens-moi » seul et case cochée : annonce et deux choix, au tutoiement" do
    request = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", notify_next: true,
                                          marketing_box_checked: true)

    bodies(RegistrationMailer.request_confirmation(request)).each do |body|
      assert_match(/\ASalut,|<p>Salut,<\/p>/, body)
      assert_no_match(/Lou/, body, "le nom saisi n'est pas repris avant la confirmation de l'adresse")
      assert_match(BOX_CHECKED, body)
      CHOICES.fetch("cafe_ia").each { |choice| assert_match(choice, body) }
      assert_no_vouvoiement(body)
    end
  end

  test "request_confirmation d'une demande de cafés : tutoiement de tartiflette.dev" do
    mail = RegistrationMailer.request_confirmation(request_for(@webinar))

    assert_equal "Confirme ton inscription au Café IA", mail.subject
    bodies(mail).each do |body|
      assert_match(/\ASalut,|<p>Salut,<\/p>/, body)
      assert_no_match(/Camille/, body, "le nom saisi n'est pas repris avant la confirmation de l'adresse")
      assert_match(/Tu viens à :/, body)
      assert_match(/Garde ce mail : le même lien t'ouvrira le café le jour J/, body)
      assert_match(/Ce n'est pas toi \? Ignore ce mail : sans confirmation, la demande est effacée sous 30 jours/, body)
      assert_no_vouvoiement(body)
    end
  end

  test "request_confirmation d'une demande de bootcamps : tonalité par défaut, sans nommer d'émission" do
    mail = RegistrationMailer.request_confirmation(request_for(create_webinar("bootcamp")))

    assert_equal "Confirmez votre inscription", mail.subject
    bodies(mail).each do |body|
      assert_match(/\ABonjour,|<p>Bonjour,<\/p>/, body)
      assert_no_match(/Camille/, body, "le nom saisi n'est pas repris avant la confirmation de l'adresse")
      assert_match(/Merci pour votre inscription :/, body)
      assert_match(/Gardez ce message : le même lien vous permettra de rejoindre le direct/, body)
    end
  end

  test "request_confirmation qui mêle un café et un bootcamp : tonalité par défaut" do
    mail = RegistrationMailer.request_confirmation(request_for(@webinar, create_webinar("bootcamp")))

    assert_equal "Confirmez votre inscription", mail.subject
    assert_match(/\ABonjour,/, mail.text_part.body.to_s)
    assert_no_match(/Camille/, mail.text_part.body.to_s)
  end

  test "request_confirmation : « préviens-moi » seul, sans café — c'est un Café IA, il tutoie" do
    request = RegistrationRequest.create!(name: "Lou", email: "lou@example.test", notify_next: true)
    text = RegistrationMailer.request_confirmation(request).text_part.body.to_s

    assert_match(/Tu as demandé qu'on te prévienne du prochain Café IA/, text)
    assert_no_match(/Tu viens à :/, text)
    assert_no_match(/Garde ce mail/, text, "aucun café : pas de lien d'accès à garder")
    assert_match(%r{/confirmer\?t=#{Regexp.escape(request.token)}}, text)
  end

  # ---- Bloc marketing dans le mail de confirmation d'inscription ----------

  KINDS.each do |kind|
    test "confirmation (#{kind}) sans jeton marketing : AUCUN bloc marketing dans l'email" do
      mail = RegistrationMailer.confirmation(registration_for(kind))

      assert_match(%r{/r/}, mail.html_part.body.to_s)
      bodies(mail).each do |body|
        assert_no_match(/J'accepte que Studio Exemple me recontacte/, body)
        assert_no_match(%r{/mc\?t=}, body)
      end
    end

    test "confirmation (#{kind}) AVEC jeton marketing : bloc explicite + lien SÉPARÉ /mc?t=..." do
      registration = registration_for(kind)
      registration.request_marketing_consent!
      mail = RegistrationMailer.confirmation(registration)

      bodies(mail).each do |body|
        assert_match(/J'accepte que Studio Exemple me recontacte/, body)
        assert_match(%r{http://[^"\s]+/mc\?t=#{Regexp.escape(registration.marketing_consent_token)}}, body)
        # Avertissement clair : ne pas cliquer si pas voulu.
        assert_match(/ne clique[sz]? .*pas.* (sur )?ce second lien/im, body)
      end
    end

    test "confirmation (#{kind}) après consentement effectif : bloc marketing retiré" do
      registration = registration_for(kind)
      registration.request_marketing_consent!
      registration.apply_marketing_consent!
      mail = RegistrationMailer.confirmation(registration)
      assert_no_match(/J'accepte que Studio Exemple me recontacte/, mail.html_part.body.to_s)
    end
  end

  test "confirmation d'un Café IA : tutoiement, lien de la page du café" do
    mail = RegistrationMailer.confirmation(@registration)

    assert_equal "Confirme ton inscription — Café IA public", mail.subject
    assert_match(/>Je confirme</, mail.html_part.body.to_s)
    bodies(mail).each do |body|
      assert_match(/\ASalut,|<p>Salut,<\/p>/, body)
      assert_no_match(/Bob/, body, "le nom saisi n'est pas repris avant la confirmation de l'adresse")
      assert_match(/on t'envoie le lien du café la veille/, body)
      assert_match(%r{http://example\.com/w/#{Regexp.escape(@webinar.slug)}}, body)
      assert_no_vouvoiement(body)
    end
  end

  test "confirmation d'un bootcamp : tonalité par défaut, inchangée" do
    mail = RegistrationMailer.confirmation(registration_for("bootcamp"))

    assert_equal "Confirmez votre inscription — Bootcamp", mail.subject
    assert_match(/>Confirmer mon inscription</, mail.html_part.body.to_s)
    assert_match(/Confirmez votre adresse pour recevoir le lien du direct/, mail.text_part.body.to_s)
  end

  # ---- Mail de confirmation du consentement (avec lien de retrait) --------

  KINDS.each do |kind|
    test "marketing_consent_confirmed (#{kind}) : lien de retrait /mc/withdraw?t=... présent" do
      registration = registration_for(kind)
      registration.request_marketing_consent!
      registration.apply_marketing_consent!
      mail = RegistrationMailer.marketing_consent_confirmed(registration)

      assert_equal [ "bob@example.test" ], mail.to
      bodies(mail).each do |body|
        assert_match(%r{http://[^"\s]+/mc/withdraw\?t=#{Regexp.escape(registration.marketing_withdrawal_token)}}, body)
        assert_match(/contact@example\.test/, body)
      end
    end
  end

  test "marketing_consent_confirmed : sujet dans la tonalité de l'émission" do
    @registration.request_marketing_consent!
    @registration.apply_marketing_consent!
    assert_equal "Merci, c'est noté : Studio Exemple peut te recontacter",
                 RegistrationMailer.marketing_consent_confirmed(@registration).subject

    bootcamp = registration_for("bootcamp")
    bootcamp.request_marketing_consent!
    bootcamp.apply_marketing_consent!
    assert_equal "Merci — consentement enregistré", RegistrationMailer.marketing_consent_confirmed(bootcamp).subject
  end

  # ---- Confirmation d'un accès immédiat (identité provisoire) -------

  KINDS.each do |kind|
    test "confirmation (#{kind}) d'un accès immédiat : sans le nom saisi, dit de confirmer depuis le même navigateur" do
      registration = registration_for(kind)
      registration.update!(name: "Intrus", instant_access_at: Time.current)

      bodies(RegistrationMailer.confirmation(registration)).each do |body|
        assert_match(/Quelqu'un est entré/, body)
        assert_no_match(/Intrus/, body, "le nom saisi par un tiers n'est pas recopié dans un mail à une adresse non prouvée")
        assert_match(/même navigateur/, body)
      end
    end
  end

  test "confirmation sans accès immédiat : aucune mention de personne entrée" do
    bodies(RegistrationMailer.confirmation(@registration)).each { |body| assert_no_match(/est entré/, body) }
  end

  # ---- Demande de rattachement d'une intervention (lien participants) ------

  KINDS.each do |kind|
    test "speaker_link (#{kind}) : à l'adresse inscrite, sans le nom saisi, lien /rattacher?t=, et « ignorez »" do
      registration = registration_for(kind)
      speaker = registration.webinar.speakers.create!(name: "Intrus", declared_email: registration.email)
      mail = RegistrationMailer.speaker_link(speaker, registration)

      assert_equal [ "bob@example.test" ], mail.to
      bodies(mail).each do |body|
        assert_no_match(/Intrus/, body, "le nom saisi par un tiers n'est pas recopié dans un mail à une adresse non prouvée")
        assert_match(%r{http://example\.com/rattacher\?t=#{Regexp.escape(speaker.link_token)}}, body)
        assert_match(/rien ne sera rattaché/, body)
        assert_match(/14 jours/, body)
        assert_no_match(%r{/r/|/mc}, body, "ni accès au direct, ni consentement")
      end
    end
  end

  test "speaker_link d'un Café IA : tutoiement" do
    speaker = @webinar.speakers.create!(name: "Intrus", declared_email: @registration.email)
    mail = RegistrationMailer.speaker_link(speaker, @registration)

    assert_equal "C'est toi ? — Café IA public", mail.subject
    bodies(mail).each { |body| assert_no_vouvoiement(body) }
  end

  # ---- Accès de l'inscription neuve créée par la reprise ----------

  KINDS.each do |kind|
    test "access (#{kind}) : lien personnel /r/:token, à l'adresse de l'inscription" do
      registration = registration_for(kind)
      mail = RegistrationMailer.access(registration)

      assert_equal [ "bob@example.test" ], mail.to
      bodies(mail).each do |body|
        assert_match(%r{http://example\.com/r/#{Regexp.escape(registration.token)}}, body)
        assert_match(/n'importe quel navigateur/, body)
      end
    end
  end

  # ---- Rappel de la veille (RegistrationReminder) --------------------------

  KINDS.each do |kind|
    test "reminder (#{kind}) : lien personnel /r/:token, ni consentement ni retrait marketing" do
      registration = registration_for(kind)
      registration.confirm!
      mail = RegistrationMailer.reminder(registration)

      assert_equal [ "bob@example.test" ], mail.to
      bodies(mail).each do |body|
        assert_match(%r{http://example\.com/r/#{Regexp.escape(registration.token)}}, body)
        assert_match(/\(heure de Paris\)/, body)
        assert_no_match(%r{/mc}, body, "ce n'est pas de la prospection")
      end
    end
  end

  test "reminder d'un Café IA : tutoiement, « Prépare ton café »" do
    @webinar.update!(title: "Café IA #8", starts_at: Time.find_zone("Europe/Paris").parse("2026-11-04 09:30"))
    @registration.confirm!

    mail = RegistrationMailer.reminder(@registration)

    assert_equal "C'est demain, 9 h 30 : Café IA #8", mail.subject
    assert_match(/>Rejoindre le café</, mail.html_part.body.to_s)
    bodies(mail).each do |body|
      assert_match(/Salut Bob/, body)
      assert_match(/C'est demain ! .*Café IA #8.*,\s+mercredi 4 novembre à 9 h 30 \(heure de Paris\)/m, body)
      assert_match(/Ce lien est à toi : ne le fais pas tourner/, body)
      assert_match(/Prépare ton café/, body)
      assert_no_vouvoiement(body)
    end
  end

  test "reminder d'un bootcamp : tonalité par défaut, inchangée" do
    bootcamp = create_webinar("bootcamp", title: "Bootcamp #1", starts_at: Time.find_zone("Europe/Paris").parse("2026-11-04 09:30"))
    registration = bootcamp.registrations.create!(name: "Bob", email: "bob@example.test")

    mail = RegistrationMailer.reminder(registration)

    assert_equal "Rappel — Bootcamp #1, demain à 09h30", mail.subject
    bodies(mail).each do |body|
      assert_match(/Bonjour Bob/, body)
      assert_match(/mercredi 04 novembre 2026 09h30 \(heure de Paris\)/, body)
      assert_match(/ouvrez votre lien personnel/, body)
    end
  end

  KINDS.each do |kind|
    test "reminder (#{kind}) : le sujet annoncé, ses intervenants et sa présentation" do
      registration = registration_for(kind)
      registration.webinar.update!(topic: "Agents IA : ce qui marche", topic_summary: "Deux retours de terrain.",
                                   announced_speakers: [ "Anne", "Karim" ], lead_host_name: "Marc")

      mail = RegistrationMailer.reminder(registration)

      assert_match(%r{Au programme : <strong>Agents IA : ce qui marche</strong>\s*<br>Avec Anne et Karim},
                   mail.html_part.body.to_s)
      assert_match(/^Au programme : Agents IA : ce qui marche\r?\nAvec Anne et Karim\r?\n\r?\nDeux retours de terrain\.\r?\n\r?\n/,
                   mail.text_part.body.to_s)
      bodies(mail).each { |body| assert_match(/Deux retours de terrain\./, body) }
    end
  end

  test "reminder : sujet et noms échappés dans le HTML" do
    @webinar.update!(topic: "<script>x</script>", announced_speakers: [ "<i>Anne</i>" ])

    html = RegistrationMailer.reminder(@registration).html_part.body.to_s

    assert_no_match(/<script>|<i>/, html)
    assert_includes html, "&lt;script&gt;x&lt;/script&gt;"
    assert_includes html, "&lt;i&gt;Anne&lt;/i&gt;"
  end

  test "reminder sans sujet : rien n'est annoncé, même avec des intervenants" do
    @webinar.update!(announced_speakers: [ "Anne" ])

    mail = RegistrationMailer.reminder(@registration)

    bodies(mail).each { |body| assert_no_match(/Au programme|Anne/, body) }
    assert_match(/\(heure de Paris\)\.\r?\n\r?\nTon lien pour entrer/, mail.text_part.body.to_s)
  end

  test "reminder : événement .ics joint, sans jeton ni email" do
    mail = RegistrationMailer.reminder(@registration)

    ics = mail.attachments.find { |attachment| attachment.filename == "#{@webinar.slug}.ics" }
    assert ics, "pièce jointe .ics"
    assert_equal "text/calendar", ics.mime_type
    calendar = ics.decoded
    assert_match(/^UID:#{Regexp.escape(@webinar.slug)}@/, calendar)
    assert_match(/^SUMMARY:Café IA public/, calendar)
    assert_match(%r{^URL;VALUE=URI:http://example\.com/w/#{Regexp.escape(@webinar.slug)}$}, calendar)
    assert_no_match(/#{Regexp.escape(@registration.token)}/, calendar)
    assert_no_match(/bob@example/, calendar)
  end

  private

  def create_webinar(kind, title: kind.humanize, starts_at: 1.day.from_now)
    Webinar.create!(title: title, kind: kind, starts_at: starts_at, host_sub: "host", visibility: "published")
  end

  def registration_for(kind)
    return @registration if kind == "cafe_ia"

    create_webinar(kind).registrations.create!(name: "Bob", email: "bob@example.test")
  end

  def request_for(*webinars, **attributes)
    request = RegistrationRequest.create!(name: "Camille", email: "camille@example.test", source: "tartiflette.dev",
                                          **attributes)
    webinars.each do |webinar|
      Registration.find_or_create_for(webinar, email: request.email, name: request.name, registration_request: request)
    end
    request
  end

  def bodies(mail)
    [ mail.html_part.body.to_s, mail.text_part.body.to_s ]
  end

  def assert_no_vouvoiement(body)
    assert_no_match(/\b(vous|votre|vos)\b/i, body, "tonalité Café IA : tutoiement")
  end
end
