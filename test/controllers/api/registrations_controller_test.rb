require "test_helper"

# POST /api/registrations (docs/registrations-api.md).
class Api::RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  ORIGIN = "https://site.example.test".freeze

  setup do
    @saved_env = ENV.to_h.slice("REGISTRATION_PRIVACY_URL", "REGISTRATION_API_ORIGINS")
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/privacy"
    ENV["REGISTRATION_API_ORIGINS"] = ORIGIN
    @first = Webinar.create!(title: "Café IA de novembre", starts_at: 3.days.from_now, host_sub: "h", visibility: "published")
    @second = Webinar.create!(title: "Café IA de décembre", starts_at: 30.days.from_now, host_sub: "h", visibility: "published")
    @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
    @payload = {
      name: "Camille", email: "camille@example.test", slugs: [ @first.slug ],
      notify_next: false, profile: "dev", message: "Hâte d'y être.", source: "tartiflette.dev"
    }
  end

  teardown do
    %w[REGISTRATION_PRIVACY_URL REGISTRATION_API_ORIGINS].each { |key| ENV[key] = @saved_env[key] }
  end

  # ---- CORS -------------------------------------------------------------

  test "préflight d'une origine autorisée : 204 et en-têtes CORS, sans credentials" do
    options api_registrations_path, headers: { "Origin" => ORIGIN, "Access-Control-Request-Method" => "POST" }
    assert_response :no_content
    assert_equal ORIGIN, response.headers["Access-Control-Allow-Origin"]
    assert_equal "POST", response.headers["Access-Control-Allow-Methods"]
    assert_equal "Content-Type", response.headers["Access-Control-Allow-Headers"]
    assert_equal "Origin", response.headers["Vary"]
    assert_nil response.headers["Access-Control-Allow-Credentials"]
  end

  test "préflight d'une origine inconnue : 403 sans en-tête CORS" do
    options api_registrations_path, headers: { "Origin" => "https://evil.example" }
    assert_response :forbidden
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "chaque origine de la liste est servie avec son propre en-tête CORS" do
    ENV["REGISTRATION_API_ORIGINS"] = "#{ORIGIN},https://www.site.example.test"
    post_registration(@payload, origin: "https://www.site.example.test")
    assert_response :accepted
    assert_equal "https://www.site.example.test", response.headers["Access-Control-Allow-Origin"]
  end

  test "POST d'une origine inconnue ou sans origine : 403, aucun effet" do
    [ "https://evil.example", "https://site.example.test.evil.example", nil ].each do |origin|
      assert_no_difference [ "Registration.count", "RegistrationRequest.count" ] do
        assert_no_enqueued_jobs { post_registration(@payload, origin: origin) }
      end
      assert_response :forbidden
      assert_nil response.headers["Access-Control-Allow-Origin"]
    end
  end

  test "Origin null, casse différente ou slash final : 403" do
    [ "null", "https://Site.example.test", "https://site.example.test/", "http://site.example.test" ].each do |origin|
      assert_no_difference "RegistrationRequest.count", origin do
        post_registration(@payload, origin: origin)
      end
      assert_response :forbidden, origin
    end
  end

  test "JSON mal formé : 400 lisible par le site, aucun effet" do
    assert_no_difference "RegistrationRequest.count" do
      post api_registrations_path, params: '{"name": "Camille",',
        headers: { "Origin" => ORIGIN, "REMOTE_ADDR" => @ip, "CONTENT_TYPE" => "application/json" }
    end
    assert_response :bad_request
    assert_equal({ "status" => "invalid", "errors" => { "body" => [ "malformed_json" ] } }, response.parsed_body)
    assert_equal ORIGIN, response.headers["Access-Control-Allow-Origin"]
  end

  test "REGISTRATION_API_ORIGINS : liste séparée par des virgules, seules ses origines passent" do
    ENV["REGISTRATION_API_ORIGINS"] = "https://autre.example, https://encore.example"
    post_registration(@payload, origin: ORIGIN)
    assert_response :forbidden
    post_registration(@payload, origin: "https://encore.example")
    assert_response :accepted
  end

  test "sans REGISTRATION_API_ORIGINS, l'API est fermée : aucune origine par défaut" do
    ENV.delete("REGISTRATION_API_ORIGINS")
    assert_no_difference -> { RegistrationRequest.count } do
      post_registration(@payload, origin: "https://tartiflette.dev")
    end
    assert_response :forbidden
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end

  test "réponse sans cookie ni session" do
    post_registration(@payload)
    assert_response :accepted
    assert_nil response.headers["Set-Cookie"]
  end

  test "corps non JSON : 415, aucun effet" do
    assert_no_difference "Registration.count" do
      post api_registrations_path, params: @payload,
        headers: { "Origin" => ORIGIN, "REMOTE_ADDR" => @ip }
    end
    assert_response :unsupported_media_type
  end

  # ---- Effets -----------------------------------------------------------

  test "inscription à deux cafés : une demande, deux inscriptions, UN mail" do
    assert_difference -> { Registration.count } => 2, -> { RegistrationRequest.count } => 1 do
      assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
        post_registration(@payload.merge(slugs: [ @second.slug, @first.slug ]))
      end
    end
    assert_response :accepted
    assert_equal({ "status" => "pending_confirmation", "webinars" => [ @second.slug, @first.slug ] }, response.parsed_body)

    request = RegistrationRequest.last
    assert_equal [ @first, @second ].map(&:id).sort, request.registrations.map(&:webinar_id).sort
    assert_equal "tartiflette.dev", request.source
    assert_equal "dev", request.profile
    assert_equal "Hâte d'y être.", request.message
    assert_not request.confirmed?
    assert request.registrations.none?(&:confirmed?)
    assert request.registrations.all? { |registration| registration.name == "Camille" }
  end

  test "cafés terminés, présumés annulés, en brouillon ou inconnus : ignorés" do
    ended = Webinar.create!(title: "Fini", starts_at: 1.day.ago, host_sub: "h", visibility: "published", state: "ended")
    late = Webinar.create!(title: "Jamais lancé", starts_at: 5.hours.ago, host_sub: "h", visibility: "published")
    draft = Webinar.create!(title: "Brouillon", starts_at: 2.days.from_now, host_sub: "h", visibility: "draft")
    assert_difference "Registration.count", 2 do
      post_registration(@payload.merge(slugs: [ ended.slug, late.slug, @first.slug ]))
      assert_equal [ @first.slug ], response.parsed_body["webinars"]
      post_registration(@payload.merge(slugs: [ draft.slug, "inconnu", @second.slug ]))
      assert_equal [ @second.slug ], response.parsed_body["webinars"]
    end
    assert_response :accepted
  end

  test "aucun café ouvert et pas de « préviens-moi » : 422 sur slugs" do
    ended = Webinar.create!(title: "Fini", starts_at: 1.day.ago, host_sub: "h", visibility: "published", state: "ended")
    assert_no_difference [ "Registration.count", "RegistrationRequest.count" ] do
      post_registration(@payload.merge(slugs: [ ended.slug ]))
    end
    assert_response :unprocessable_entity
    assert_equal({ "slugs" => [ "no_open_webinar" ] }, response.parsed_body["errors"])
  end

  test "« préviens-moi » seul : une demande sans inscription, un mail, webinars vide" do
    assert_difference -> { RegistrationRequest.count } => 1, -> { Registration.count } => 0 do
      assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
        post_registration(@payload.merge(slugs: [], notify_next: true))
      end
    end
    assert_response :accepted
    assert_equal [], response.parsed_body["webinars"]
    assert RegistrationRequest.last.notify_next?
  end

  test "champ piège rempli : même réponse, aucun effet" do
    assert_no_difference [ "Registration.count", "RegistrationRequest.count" ] do
      assert_no_enqueued_jobs { post_registration(@payload.merge(website: "http://spam.example")) }
    end
    assert_response :accepted
    assert_equal [ @first.slug ], response.parsed_body["webinars"]
  end

  # ---- Pas d'oracle d'existence d'email ---------------------------------

  test "SÉCURITÉ : inscription existante confirmée — même réponse, rien n'est modifié ni envoyé" do
    post_registration(@payload)
    fresh_body = response.parsed_body
    existing = @first.registrations.create!(name: "Bob", email: "bob@example.test", confirmed_at: Time.current)

    assert_no_difference [ "Registration.count", "RegistrationRequest.count" ] do
      assert_no_enqueued_jobs do
        post_registration(@payload.merge(name: "Mallory", email: " BOB@example.test "))
      end
    end
    assert_response :accepted
    assert_equal fresh_body, response.parsed_body
    existing.reload
    assert_equal "Bob", existing.name
    assert_nil existing.registration_request, "une inscription existante n'est jamais rattachée"
  end

  test "SÉCURITÉ : inscription existante en attente — même réponse, son propre lien est renvoyé" do
    existing = @first.registrations.create!(name: "Bob", email: "bob@example.test")
    assert_no_difference [ "Registration.count", "RegistrationRequest.count" ] do
      assert_enqueued_jobs 1, only: ActionMailer::MailDeliveryJob do
        post_registration(@payload.merge(name: "Mallory", email: "bob@example.test"))
      end
    end
    assert_response :accepted
    assert_equal "Bob", existing.reload.name
    assert_nil existing.registration_request
  end

  test "SÉCURITÉ : mélange existante + nouvelle — seule la nouvelle entre dans la demande" do
    existing = @first.registrations.create!(name: "Bob", email: "bob@example.test", confirmed_at: Time.current)
    post_registration(@payload.merge(email: "bob@example.test", slugs: [ @first.slug, @second.slug ]))
    assert_response :accepted
    assert_equal [ @first.slug, @second.slug ], response.parsed_body["webinars"]
    request = RegistrationRequest.last
    assert_equal [ @second.id ], request.registrations.map(&:webinar_id)
    assert_nil existing.reload.registration_request
  end

  # ---- Validations ------------------------------------------------------

  test "entrées invalides : 422 avec les champs fautifs, aucun effet" do
    cases = {
      { marketing_consent: "true" } => { "marketing_consent" => [ "invalid" ] },
      { marketing_consent: "no" } => { "marketing_consent" => [ "invalid" ] },
      { marketing_consent: 1 } => { "marketing_consent" => [ "invalid" ] },
      { email: "pas-une-adresse" } => { "email" => [ "invalid" ] },
      { email: "#{"a" * 250}@example.test" } => { "email" => [ "too_long" ] },
      { name: "  " } => { "name" => [ "blank" ] },
      { name: "x" * 121 } => { "name" => [ "too_long" ] },
      { profile: "astronaute" } => { "profile" => [ "inclusion" ] },
      { message: "x" * 2001 } => { "message" => [ "too_long" ] },
      { source: "evil.example" } => { "source" => [ "inclusion" ] },
      { slugs: "#{@first.slug}" } => { "slugs" => [ "invalid" ] },
      { slugs: [ { "slug" => @first.slug } ] } => { "slugs" => [ "invalid" ] },
      { slugs: %w[a b c d] } => { "slugs" => [ "too_many" ] },
      { participation: "host" } => { "participation" => [ "inclusion" ] },
      { participation: true } => { "participation" => [ "inclusion" ] }
    }
    cases.each do |override, expected|
      @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
      assert_no_difference [ "Registration.count", "RegistrationRequest.count" ], override.inspect do
        assert_no_enqueued_jobs { post_registration(@payload.merge(override)) }
      end
      assert_response :unprocessable_entity, override.inspect
      assert_equal "invalid", response.parsed_body["status"]
      assert_equal expected, response.parsed_body["errors"].slice(*expected.keys), override.inspect
      assert_equal ORIGIN, response.headers["Access-Control-Allow-Origin"], "erreur lisible par le site"
    end
  end

  # Politique v1.6 : plus de case d'inscription. Le
  # `consent: true` de l'ancienne version du site reste accepté et ignoré.
  test "sans case d'inscription : 202 ; l'ancien `consent: true` est accepté et ignoré" do
    [ @payload, @payload.merge(consent: true), @payload.merge(consent: false) ].each do |payload|
      @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
      assert_difference "RegistrationRequest.count", 1, payload.inspect do
        post_registration(payload.merge(email: "camille+#{SecureRandom.hex(2)}@example.test"))
      end
      assert_response :accepted, payload.inspect
    end
  end

  test "case de recontact : retenue sur la demande, sans aucun consentement avant confirmation" do
    post_registration(@payload.merge(marketing_consent: true))
    assert_response :accepted
    request = RegistrationRequest.last
    assert request.marketing_box_checked?
    assert request.registrations.none?(&:marketing_consent?)

    [ @payload, @payload.merge(marketing_consent: false) ].each do |payload|
      post_registration(payload.merge(email: "lou+#{SecureRandom.hex(2)}@example.test"))
      assert_response :accepted
      assert_not RegistrationRequest.last.marketing_box_checked?
    end
  end

  test "SÉCURITÉ : case de recontact cochée avec l'email d'un inscrit existant — rien ne lui est rattaché" do
    existing = @first.registrations.create!(name: "Bob", email: "bob@example.test")
    post_registration(@payload.merge(email: "bob@example.test", marketing_consent: true))
    assert_response :accepted
    assert_nil existing.reload.registration_request
    assert_not existing.marketing_consent?
  end

  # Champ additif : absent ou null = spectateur, rien ne
  # change pour une version du site qui l'ignore. Sans lui, le choix n'est pas
  # fait : la salle le demandera à l'entrée.
  test "choix spectateur / participant facultatif, spectateur par défaut, porté par chaque café de la demande" do
    { nil => "spectator", "spectator" => "spectator", "participant" => "participant" }.each do |participation, expected|
      @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
      email = "camille+#{SecureRandom.hex(2)}@example.test"
      payload = @payload.merge(email: email, slugs: [ @first.slug, @second.slug ])
      payload[:participation] = participation if participation

      post_registration(payload)

      assert_response :accepted
      assert_equal [ expected, expected ], Registration.where(email: email).pluck(:participation), participation.inspect
      assert_equal [ !participation.nil? ] * 2, Registration.where(email: email).map(&:participation_chosen?),
                   "choix daté seulement s'il est transmis (#{participation.inspect})"
    end

    @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
    post_registration(@payload.merge(email: "null@example.test", participation: nil))
    assert_response :accepted
    assert Registration.find_by!(email: "null@example.test").spectator?
    assert_not Registration.find_by!(email: "null@example.test").participation_chosen?
  end

  test "SÉCURITÉ : le choix d'une soumission ne modifie pas une inscription existante" do
    existing = @first.registrations.create!(name: "Bob", email: "bob@example.test")

    post_registration(@payload.merge(email: "bob@example.test", participation: "participant"))

    assert_response :accepted
    assert existing.reload.spectator?
  end

  test "profil, message et source sont facultatifs" do
    post_registration(@payload.except(:profile, :message, :source))
    assert_response :accepted
    request = RegistrationRequest.last
    assert_nil request.profile
    assert_nil request.message
    assert_nil request.source
  end

  test "trois cafés au plus, doublons comptés une fois" do
    post_registration(@payload.merge(slugs: [ @first.slug, @first.slug, @second.slug ]))
    assert_response :accepted
    assert_equal [ @first.slug, @second.slug ], response.parsed_body["webinars"]
  end

  test "politique de confidentialité non configurée : 503, aucun effet" do
    ENV.delete("REGISTRATION_PRIVACY_URL")
    assert_no_difference "Registration.count" do
      post_registration(@payload)
    end
    assert_response :service_unavailable
  end

  # ---- Journaux ---------------------------------------------------------

  test "SÉCURITÉ : prénom, email, profil et message ne partent jamais en clair dans les logs" do
    io = StringIO.new
    # La ligne « Parameters: » passe par le logger d'ActionController.
    originals = [ Rails.logger, ActionController::Base.logger ]
    Rails.logger = ActionController::Base.logger = ActiveSupport::Logger.new(io)
    begin
      post_registration(@payload.merge(name: "Zéphyrine", message: "Message très personnel", profile: "design"))
      post public_webinar_registrations_path(@first.slug),
        params: { registration: { name: "Zéphyrine", email: "z@example.test" } },
        headers: { "REMOTE_ADDR" => @ip }
    ensure
      Rails.logger, ActionController::Base.logger = originals
    end
    log = io.string
    assert_match(/Parameters:/, log)
    assert_no_match(/Zéphyrine/, log)
    assert_no_match(/Message très personnel/, log)
    assert_no_match(/"profile" ?=> ?"design"/, log)
    assert_no_match(/camille@example\.test|z@example\.test/, log)
  end

  # ---- Rate limit -------------------------------------------------------

  test "rate limit : la 11e requête d'une IP est refusée en 429 lisible, puis repart après une minute" do
    10.times { post_registration(@payload.merge(email: "camille+#{SecureRandom.hex(2)}@example.test")) }
    assert_response :accepted
    assert_no_difference "Registration.count" do
      post_registration(@payload)
    end
    assert_response :too_many_requests
    assert_equal({ "status" => "rate_limited" }, response.parsed_body)
    assert_equal ORIGIN, response.headers["Access-Control-Allow-Origin"]
    travel 61.seconds do
      post_registration(@payload)
      assert_response :accepted
    end
  end

  test "rate limit : compteur COMMUN avec le formulaire HTML (6 HTML + 5 API → 429)" do
    6.times do
      post public_webinar_registrations_path(@first.slug),
        params: { registration: { name: "Camille", email: "camille@example.test" } },
        headers: { "REMOTE_ADDR" => @ip }
    end
    4.times { post_registration(@payload) }
    assert_response :accepted
    post_registration(@payload)
    assert_response :too_many_requests

    post public_webinar_registrations_path(@first.slug),
      params: { registration: { name: "Camille", email: "camille@example.test" } },
      headers: { "REMOTE_ADDR" => @ip }
    assert_response :too_many_requests, "le formulaire HTML voit le même compteur"
  end

  # ---- Mail bombing ------------------------

  test "la même adresse soumise depuis 30 réseaux différents ne reçoit qu'un seul mail" do
    assert_enqueued_emails 1 do
      30.times do |index|
        @ip = "2001:db8:#{index.to_s(16)}:#{SecureRandom.hex(2)}::1"
        post_registration(@payload.merge(slugs: [ @first.slug, @second.slug ], name: "Mallory #{index}"))
        assert_response :accepted
      end
    end
  end

  test "des renvois épuisés n'empêchent pas la première confirmation d'inscriptions neuves" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      RecipientMailThrottle.default.claim("victime@example.test", "confirmation:ancien-#{index}")
    end

    assert_enqueued_emails 1 do
      post_registration(@payload.merge(email: "victime@example.test"))
    end
    assert_response :accepted
  end

  test "la même adresse soumise sur plusieurs webinaires, renvois compris, reste sous la borne annoncée" do
    perform_enqueued_jobs do
      40.times do |index|
        @ip = "2001:db8:#{index.to_s(16)}:#{SecureRandom.hex(2)}::1"
        travel(index * (RecipientMailThrottle::INTERVAL + 1.minute)) do
          post_registration(@payload.merge(slugs: [ @first.slug, @second.slug ], email: "victime@example.test", notify_next: index.odd?))
        end
      end
    end
    sent = ActionMailer::Base.deliveries.count { |mail| mail.to == [ "victime@example.test" ] }
    # 1 première confirmation (les deux webinaires neufs, un seul mail) +
    # au plus DAILY_TOTAL_CAP renvois et « préviens-moi ».
    assert_operator sent, :<=, 1 + RecipientMailThrottle::DAILY_TOTAL_CAP
  end

  # Le « préviens-moi » d'un tiers ne bloque pas
  # la première confirmation de l'inscription neuve de la victime.
  test "un « préviens-moi » seul d'un tiers ne bloque pas la première confirmation d'une inscription neuve avec « préviens-moi »" do
    post_registration(@payload.merge(slugs: [], notify_next: true, email: "victime@example.test"))
    assert_response :accepted
    @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
    travel 1.minute do
      assert_enqueued_emails 1 do
        post_registration(@payload.merge(slugs: [ @first.slug ], notify_next: true, email: "victime@example.test"))
      end
      assert_equal 1, @first.registrations.where(email: "victime@example.test").count
    end
  end

  # P1b : six « préviens-moi » espacés épuisent leur flux, pas la première
  # confirmation d'une inscription neuve.
  test "six « préviens-moi » espacés ne bloquent pas la première confirmation pendant 24 h" do
    6.times do |index|
      travel(index * (RecipientMailThrottle::INTERVAL + 1.minute)) do
        @ip = "2001:db8:#{SecureRandom.hex(2)}::1"
        post_registration(@payload.merge(slugs: [], notify_next: true, email: "victime@example.test"))
      end
    end
    travel(6 * (RecipientMailThrottle::INTERVAL + 1.minute) + 30.minutes) do
      @ip = "2001:db8:#{SecureRandom.hex(2)}::1"
      assert_enqueued_emails 1 do
        post_registration(@payload.merge(slugs: [ @first.slug ], notify_next: true, email: "victime@example.test"))
      end
    end
  end

  # P3 : les variantes +N d'une même boîte ne sont jamais exemptées : elles
  # comptent dans :unproven, donc au plus son total.
  test "vingt variantes +N pour un même webinaire : aucune exemptée, le total :unproven est respecté" do
    sent = 0
    20.times do |index|
      @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
      before = enqueued_jobs.size
      post_registration(@payload.merge(slugs: [ @first.slug ], email: "victime+#{index}@example.test"))
      sent += 1 if enqueued_jobs.size > before
    end
    assert_equal RecipientMailThrottle::DAILY_TOTAL_CAP, sent
  end

  # Préemption : un tiers inscrit victime+x@ avant la victime ne lui prend pas
  # son exemption.
  test "victime+x@ puis victime@ pour le même webinaire : la première confirmation de la victime part" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
      post_registration(@payload.merge(slugs: [ @first.slug ], email: "victime+#{index}@example.test"))
    end
    @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
    assert_enqueued_emails 1 do
      post_registration(@payload.merge(slugs: [ @first.slug ], email: "victime@example.test"))
    end
  end

  test "la victime avec un +tag légitime reçoit son mail tant que :unproven n'est pas plein" do
    assert_enqueued_emails 1 do
      post_registration(@payload.merge(slugs: [ @first.slug ], email: "victime+cafe@example.test"))
    end
  end

  # Boîtes gmail fictives : Gmail refuse le « _ » dans un nom d'utilisateur.
  test "variantes gmail à points : l'adresse saisie est stockée telle quelle, une inscription par variante" do
    %w[f.i.c.t.i.f_v@gmail.com fictif_v+a@googlemail.com fic.tif_v@gmail.com fictif_v@gmail.com].each_with_index do |address, index|
      @ip = "2001:db8:#{SecureRandom.hex(2)}:#{index}::1"
      post_registration(@payload.merge(slugs: [ @first.slug ], email: address))
    end
    assert_equal 4, @first.registrations.count
    assert_equal %w[f.i.c.t.i.f_v@gmail.com fictif_v+a@googlemail.com fic.tif_v@gmail.com fictif_v@gmail.com].sort, @first.registrations.pluck(:email).sort
  end

  test "« préviens-moi » répété pour la même adresse : une seule demande par fenêtre, un seul mail" do
    victim = @payload.merge(slugs: [], notify_next: true, email: "victime@example.test")
    assert_enqueued_emails 1 do
      12.times do |index|
        @ip = "2001:db8:#{index.to_s(16)}:#{SecureRandom.hex(2)}::1"
        post_registration(victim)
        assert_response :accepted
      end
    end
  end

  test "le nom saisi par un tiers n'est jamais recopié dans le mail envoyé à l'adresse" do
    perform_enqueued_jobs do
      post_registration(@payload.merge(name: "Offre à cliquer http://evil.example", email: "victime@example.test"))
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "victime@example.test" ], mail.to
    [ mail.text_part, mail.html_part ].each do |part|
      assert_no_match(/evil\.example|Offre à cliquer/, part.body.to_s)
    end
  end

  test "la réponse est la même, mail parti ou non (pas d'oracle sur la limite)" do
    post_registration(@payload)
    first = [ response.status, response.parsed_body ]
    @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
    post_registration(@payload)
    assert_equal first, [ response.status, response.parsed_body ]
  end

  test "rate limit IPv6 : le compteur est par /64, changer d'adresse dans son préfixe ne le contourne pas" do
    prefix = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}"
    10.times do |index|
      @ip = "#{prefix}::#{index + 1}"
      post_registration(@payload.merge(email: "camille+#{SecureRandom.hex(3)}@example.test"))
      assert_response :accepted
    end
    @ip = "#{prefix}:ffff:ffff:ffff:ffff"
    post_registration(@payload.merge(email: "camille+#{SecureRandom.hex(3)}@example.test"))
    assert_response :too_many_requests

    @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1"
    post_registration(@payload.merge(email: "camille+#{SecureRandom.hex(3)}@example.test"))
    assert_response :accepted
  end

  private

  def post_registration(payload, origin: ORIGIN)
    headers = { "REMOTE_ADDR" => @ip }
    headers["Origin"] = origin if origin
    post api_registrations_path, params: payload.to_json,
      headers: headers.merge("CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json")
  end
end
