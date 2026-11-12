require "test_helper"

# Chaque page du parcours d'inscription parle dans la tonalité de son
# émission (Voice) : Café IA = tutoiement de
# tartiflette.dev ; bootcamp et pages sans émission = tonalité par défaut,
# au mot près. Aucune page ne laisse passer une clé manquante.
class VoicePagesTest < ActionDispatch::IntegrationTest
  setup do
    @privacy_url = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/privacy"
  end

  teardown { ENV["REGISTRATION_PRIVACY_URL"] = @privacy_url }

  # [chemin de la page, texte café, texte par défaut] pour une inscription
  # fraîche avec un jeton de consentement en attente.
  PAGES = {
    "/r/:token (à confirmer)" => [
      ->(registration) { "/r/#{registration.token}" },
      "C'est bien toi ? Clique sur le bouton.",
      "Si c'est bien vous, cliquez sur le bouton ci-dessous."
    ],
    "/mc (consentement à confirmer)" => [
      ->(registration) { "/mc?t=#{registration.marketing_consent_token}" },
      "Tu veux que Studio Exemple te recontacte ?",
      "Confirmer votre consentement"
    ]
  }.freeze

  PAGES.each do |page, (path, cafe_text, default_text)|
    test "#{page} : Café IA tutoie, bootcamp garde le défaut" do
      get path.call(pending_registration("cafe_ia"))
      assert_voice cafe_text

      get path.call(pending_registration("bootcamp"))
      assert_voice default_text, cafe: false
    end
  end

  test "page de l'émission et bloc d'inscription" do
    get "/w/#{webinar('cafe_ia').slug}"
    assert_voice "Tu viens ?"
    assert_select "label", "Ton prénom"
    assert_select "input[type=submit][value=?]", "Je viens"
    assert_voice "Ton prénom et ton mail servent à ton inscription"

    get "/w/#{webinar('bootcamp').slug}"
    assert_voice "S'inscrire au webinaire", cafe: false
    assert_select "label", "Nom"
    assert_select "input[type=submit][value=?]", "M'inscrire"
    assert_voice "Votre nom et votre email servent à votre inscription", cafe: false
    assert_select "[data-role=registration-cta] h2 + p", count: 0, message: "le défaut n'a pas d'accroche"
  end

  test "lien participants privé (/i) : Café IA tutoie, bootcamp garde le défaut" do
    get "/i?t=#{webinar('cafe_ia').generate_share_token!}"
    assert_voice "Rejoins le café"
    assert_select "label", "Ton mail"
    assert_select "legend", "Tu viens comment ?"
    assert_select "input[type=submit][value=?]", "J'entre"

    get "/i?t=#{webinar('bootcamp').generate_share_token!}"
    assert_voice "Rejoindre le direct", cafe: false
    assert_select "label", "Adresse email"
    assert_select "legend", "Comment souhaitez-vous participer ?"
    assert_select "input[type=submit][value=?]", "Rejoindre"
  end

  test "page de l'émission en direct puis terminée" do
    { "cafe_ia" => [ "Le café a commencé ! Inscris-toi pour entrer tout de suite", "Ce café est terminé. À la prochaine !" ],
      "bootcamp" => [ "Le direct a commencé. Inscrivez-vous pour entrer tout de suite", "Ce direct est terminé." ] }
      .each do |kind, (live, ended)|
        page = webinar(kind)
        page.update!(state: "live")
        get "/w/#{page.slug}"
        assert_voice live, cafe: kind == "cafe_ia"
        page.update!(state: "ended", ended_at: Time.current)
        get "/w/#{page.slug}"
        assert_voice ended, cafe: kind == "cafe_ia"
      end
  end

  test "formulaire incomplet : le message d'erreur suit la tonalité" do
    post "/w/#{webinar('cafe_ia').slug}/registrations", params: { registration: { name: "", email: "x" } }
    assert_response :unprocessable_entity
    assert_voice "Il manque quelque chose : ton prénom ou un mail valide."

    post "/w/#{webinar('bootcamp').slug}/registrations", params: { registration: { name: "", email: "x" } }
    assert_voice "Renseignez votre nom et une adresse email valide.", cafe: false
  end

  test "après l'envoi du formulaire : page d'attente" do
    params = { registration: { name: "Alice", email: "alice@example.test" } }
    post "/w/#{webinar('cafe_ia').slug}/registrations", params: params
    assert_voice "Revenir au café"

    post "/w/#{webinar('bootcamp').slug}/registrations", params: params
    assert_voice "Revenir au webinaire", cafe: false
  end

  test "/mc : refus, consentement, déjà consenti, retrait — dans les deux tonalités" do
    { "cafe_ia" => [ "Ton inscription à", "Merci, c'est noté !", "C'est déjà noté",
                     "Tu ne veux plus que Studio Exemple te recontacte ?", "C'est fait, ton accord est retiré",
                     "C'est déjà fait" ],
      "bootcamp" => [ "Votre inscription au webinaire", "Merci — votre consentement est enregistré",
                      "Consentement déjà enregistré", "Retirer votre consentement au recontact",
                      "Votre retrait est enregistré", "Consentement déjà retiré" ] }.each do |kind, texts|
      declined, created, already, withdraw, withdrawn, already_withdrawn = texts
      cafe = kind == "cafe_ia"

      post "/mc/decline?t=#{pending_registration(kind).marketing_consent_token}"
      assert_voice declined, cafe: cafe

      registration = pending_registration(kind)
      post "/mc?t=#{registration.marketing_consent_token}"
      assert_voice created, cafe: cafe
      # Jeton consommé par le POST : « déjà consenti » vient d'un jeton
      # resté posé sur une inscription déjà consentante.
      consenting = pending_registration(kind)
      consenting.update_columns(marketing_consent: true)
      get "/mc?t=#{consenting.marketing_consent_token}"
      assert_voice already, cafe: cafe

      withdrawal = "/mc/withdraw?t=#{registration.reload.marketing_withdrawal_token}"
      get withdrawal
      assert_voice withdraw, cafe: cafe
      # Retrait déjà passé par un autre canal, jeton encore posé.
      registration.update_columns(marketing_consent: false)
      get withdrawal
      assert_voice already_withdrawn, cafe: cafe
      registration.update_columns(marketing_consent: true)
      post withdrawal
      assert_voice withdrawn, cafe: cafe
    end
  end

  test "/mc : lien expiré, dans les deux tonalités" do
    { "cafe_ia" => "Ce lien marche 14 jours", "bootcamp" => "est valide 14 jours" }.each do |kind, text|
      registration = pending_registration(kind)
      registration.update!(marketing_consent_token_expires_at: 1.minute.ago)
      get "/mc?t=#{registration.marketing_consent_token}"
      assert_response :gone
      assert_voice text, cafe: kind == "cafe_ia"
    end
  end

  test "/confirmer : demande de cafés = Café IA ; demande mêlée = défaut" do
    cafe_request = registration_request(webinar("cafe_ia"))
    get "/confirmer?t=#{cafe_request.token}"
    assert_voice "Tu viens à :"
    post "/confirmer?t=#{cafe_request.token}"
    assert_voice "C'est confirmé, à très vite !"

    mixed = registration_request(webinar("cafe_ia"), webinar("bootcamp"))
    get "/confirmer?t=#{mixed.token}"
    assert_voice "Cette demande porte sur :", cafe: false
    post "/confirmer?t=#{mixed.token}"
    assert_voice "Gardez le mail reçu", cafe: false
  end

  # Case de recontact cochée (politique v1.6) : deux boutons
  # qui disent ce qu'ils accordent, l'annonce « a été cochée lors de cette
  # demande », et le lien de retrait une fois l'accord donné.
  test "/confirmer Café IA, case cochée : annonce, deux boutons explicites, lien de retrait" do
    request = registration_request(webinar("cafe_ia"), marketing_box_checked: true)
    get "/confirmer?t=#{request.token}"
    assert_voice "a été cochée lors de cette demande. Choisis ci-dessous si Studio Exemple peut te recontacter"
    assert_no_match(/Tu as coché|Vous avez coché/, response.body)
    assert_select "form button[data-role=confirm-with-marketing]", "Je confirme, et Studio Exemple peut me recontacter"
    assert_select "form button[data-role=confirm-without-marketing]", "Je confirme, sans être recontacté·e"
    assert_select "form:has(button[data-role=confirm-with-marketing]) input[name=marketing][value='1']"
    assert_select "form:has(button[data-role=confirm-without-marketing]) input[name=marketing][value='0']"

    post "/confirmer?t=#{request.token}", params: { marketing: "1" }
    assert_voice "C'est noté aussi : Studio Exemple pourra te recontacter au sujet de ses activités. Pour dire stop : ne plus être recontacté·e, ou écris à contact@example.test."
    assert_select "[data-role=marketing-consent-given] a[href^=?]", "/mc/withdraw", text: "ne plus être recontacté·e"
  end

  test "/confirmer Café IA, « préviens-moi » seul et case cochée : les deux boutons, au tutoiement" do
    request = RegistrationRequest.create!(name: "Lou", email: "lou-#{SecureRandom.hex(4)}@example.test",
                                          notify_next: true, marketing_box_checked: true)
    get "/confirmer?t=#{request.token}"
    assert_voice "Tu as demandé qu'on te prévienne du prochain Café IA."
    assert_select "button[data-role=confirm-with-marketing]", "Je confirme, et Studio Exemple peut me recontacter"
    assert_select "button[data-role=confirm-without-marketing]", "Je confirme, sans être recontacté·e"

    post "/confirmer?t=#{request.token}", params: { marketing: "1" }
    assert_voice "Studio Exemple pourra te recontacter"

    get "/mc/withdraw?t=#{request.reload.marketing_withdrawal_token}"
    assert_voice "Tu ne veux plus que Studio Exemple te recontacte ?"
    post "/mc/withdraw?t=#{request.marketing_withdrawal_token}"
    assert_voice "C'est fait, ton accord est retiré"
  end

  test "/confirmer bootcamp, case cochée : libellés par défaut, inchangés" do
    request = registration_request(webinar("bootcamp"), marketing_box_checked: true)
    get "/confirmer?t=#{request.token}"
    assert_voice "a été cochée lors de cette demande. Choisissez ci-dessous si vous acceptez que Studio Exemple vous recontacte", cafe: false
    assert_select "button[data-role=confirm-with-marketing]", "Confirmer et accepter d'être recontacté·e"
    assert_select "button[data-role=confirm-without-marketing]", "Confirmer sans être recontacté·e"
    post "/confirmer?t=#{request.token}", params: { marketing: "1" }
    assert_voice "C'est noté aussi : Studio Exemple pourra vous recontacter", cafe: false
  end

  test "dates des pages : format des mails de l'émission (café), format long par défaut" do
    paris = Time.find_zone("Europe/Paris")
    cafe = webinar("cafe_ia")
    cafe.update!(starts_at: paris.parse("2026-11-04 09:30"))
    bootcamp = webinar("bootcamp")
    bootcamp.update!(starts_at: paris.parse("2026-11-04 09:30"))

    get "/w/#{cafe.slug}"
    assert_voice "mercredi 4 novembre à 9 h 30"
    get "/confirmer?t=#{registration_request(cafe).token}"
    assert_voice "mercredi 4 novembre à 9 h 30"
    get "/r/#{cafe.registrations.create!(name: 'Alice', email: 'alice@example.test').token}"
    assert_voice "mercredi 4 novembre à 9 h 30"

    get "/w/#{bootcamp.slug}"
    assert_voice "mercredi 04 novembre 2026 09h30", cafe: false
    get "/confirmer?t=#{registration_request(bootcamp).token}"
    assert_voice "mercredi 04 novembre 2026 09h30", cafe: false
  end

  test "pages sans émission (lien invalide) : tonalité par défaut" do
    get "/confirmer?t=inconnu"
    assert_voice "Ce lien n'est pas (ou n'est plus) valide.", cafe: false
    get "/mc?t=inconnu"
    assert_voice "Ce lien n'est pas (ou n'est plus) valide.", cafe: false
  end

  private

  def webinar(kind)
    Webinar.create!(title: "Rencontre #{kind.dasherize}", kind: kind, starts_at: 2.days.from_now,
                    host_sub: "host", visibility: "published")
  end

  def pending_registration(kind)
    registration = webinar(kind).registrations.create!(name: "Alice", email: "alice@example.test")
    registration.request_marketing_consent!
    registration
  end

  def registration_request(*webinars, **attributes)
    request = RegistrationRequest.create!(name: "Camille", email: "camille-#{SecureRandom.hex(4)}@example.test",
                                          source: "tartiflette.dev", **attributes)
    webinars.each do |webinar|
      Registration.find_or_create_for(webinar, email: request.email, name: request.name, registration_request: request)
    end
    request
  end

  # Texte attendu dans le <main>, aucune clé manquante ; en Café IA, aucun
  # vouvoiement dans le contenu de la page (le chrome n'en fait pas partie).
  def assert_voice(text, cafe: true)
    content = Nokogiri::HTML(response.body).at_css("main")&.text.to_s.squish
    assert_includes content, text
    assert_no_match(/translation missing|translation_missing/i, response.body)
    assert_no_match(/\b(vous|votre|vos)\b/i, content, "tonalité Café IA : tutoiement") if cafe
  end
end
