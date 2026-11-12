require "test_helper"

# Règle unique du retrait (RoomRemoval ; modèle de menace :
# docs/moderation.md) : un navigateur qui porte, pour CE webinaire, une
# identité RETIRÉE depuis la régie (`room_removed_at`) est retiré de ce
# webinaire, quel que soit le rôle qu'il demande.
#
# Matrice : chaque navigateur retiré × chaque entrée de la salle → 403, rien de
# créé ; y compris après fermeture du navigateur (session vidée, cookies
# persistants gardés). Témoins admis : spectateur non retiré, intervenant
# seulement RÉVOQUÉ par le propriétaire (retirer ≠ révoquer), animation.
# Liens de tiers : aucune entrée GET ne pose de cookie d'identité, un lien d'un
# tiers retiré ne bannit pas la victime.
#
# Chaque navigateur est construit par les vrais parcours (confirmation
# d'inscription, lien partagé), qui posent les vrais cookies.
class RoomRemovalTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "fake_secret_for_tests_only_aaaaaaaaaaaaaaaaaaaa"

  # Navigateur retiré → méthode qui le construit et rend le jeton
  # d'intervenant qu'il présente (ou nil).
  REMOVED_BROWSERS = {
    "spectateur retiré" => :removed_viewer,
    "spectateur retiré, navigateur fermé puis rouvert" => :removed_viewer_after_restart,
    "intervenant du lien partagé retiré, avec sa propre inscription" => :removed_shared_speaker,
    "intervenant du lien partagé retiré, navigateur fermé puis rouvert" => :removed_shared_speaker_after_restart,
    "spectateur retiré puis inscrit à un autre webinaire" => :removed_viewer_registered_elsewhere,
    "spectateur entré par l'accès immédiat puis retiré" => :removed_instant_viewer,
    "spectateur du lien participants privé retiré" => :removed_private_link_viewer,
    "participant du lien privé retiré depuis la régie" => :removed_private_link_speaker,
    "spectateur retiré, cookie d'inscription à l'ancien format (id seul)" => :removed_legacy_viewer
  }.freeze

  # Navigateur témoin → méthode qui le construit (même contrat).
  ADMITTED_BROWSERS = {
    "spectateur inscrit non retiré" => :confirmed_viewer_token,
    "spectateur inscrit non retiré, navigateur fermé puis rouvert" => :confirmed_viewer_after_restart,
    "intervenant du lien partagé seulement révoqué par le propriétaire, avec sa propre inscription" =>
      :revoked_shared_speaker,
    "spectateur entré par l'accès immédiat, non retiré" => :instant_viewer_token,
    "inscrite dont un intrus retiré avait saisi l'adresse au lien privé" => :victim_of_removed_intruder,
    "victime dont un intrus retiré avait saisi l'adresse NEUVE, puis qui confirme" => :new_address_victim_of_removed_intruder
  }.freeze

  # Entrée de la salle → méthode qui l'appelle (avec le jeton d'intervenant
  # que présente le navigateur, ou nil).
  ENTRIES = {
    "jeton LiveKit" => :api_token,
    "préférences de périphériques" => :device_preferences,
    "lien partagé, page" => :invitation_show,
    "lien partagé, envoi du nom" => :invitation_create,
    "lien participants privé, spectateur" => :invitation_create_spectator,
    "inscription publique pendant le direct (accès immédiat)" => :register_during_live,
    "main levée pré-déclarée (jeton d'un inscrit participant)" => :declared_hand,
    "lien personnel d'un autre intervenant" => :join_other_speaker,
    "confirmation d'une nouvelle inscription" => :confirm_new_registration,
    "discussion, lecture" => :messages_index,
    "discussion, envoi" => :messages_create,
    "main levée" => :hand_raise_create,
    "état de sa main" => :hand_raise_status,
    "sondage en cours" => :poll_current,
    "question affichée" => :qa_current,
    "indicateur d'enregistrement" => :recording_status,
    "accord à l'image, don (parole accordée)" => :participant_consent_create,
    "accord à l'image, retrait" => :participant_consent_destroy
  }.freeze

  # Un spectateur n'a pas de préférences de périphériques côté serveur.
  REFUSED_TO_ANY_VIEWER = %i[device_preferences].freeze

  setup do
    @saved_env = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "REGISTRATION_PRIVACY_URL")
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
    # Le lien participants privé et l'inscription recueillent une adresse.
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/confidentialite"
    # Salle simulée partagée : le lien personnel ouvre la page sans attendre
    # d'enregistrement (create_room échoue tout de suite), la discussion
    # diffuse sans réseau.
    @saved_factory = Rails.configuration.x.room_service_client_factory
    room = LivekitPacketDelivery::RoomRecorder.new
    Rails.configuration.x.room_service_client_factory = -> { room }

    @owner = User.create!(email: "marc@example.test", oidc_sub: "sub-marc-#{SecureRandom.hex(4)}")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: @owner.oidc_sub,
                               visibility: "published", state: "live", started_at: Time.current)
    @share_token = @webinar.generate_share_token!
    @other_speaker = @webinar.speakers.create!(name: "Mathilde")
    # IP propre au test : le débit du lien partagé (10/min/IP) est compté par processus.
    @ip = "10.#{rand(0..255)}.#{rand(0..255)}.#{rand(1..254)}"
  end

  teardown do
    Rails.configuration.x.room_service_client_factory = @saved_factory
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET REGISTRATION_PRIVACY_URL].each { |key| ENV[key] = @saved_env[key] }
  end

  REMOVED_BROWSERS.each do |browser_label, browser|
    ENTRIES.each do |entry_label, entry|
      test "#{browser_label} × #{entry_label} : refusé" do
        speaker_token = send(browser)

        # Mains en attente seulement : l'accord à l'image accorde d'abord la
        # parole à chaque inscription du navigateur (participant_consent_create).
        assert_no_difference [ -> { Speaker.count }, -> { HandRaise.where(state: "waiting").count },
                               -> { Registration.where.not(instant_access_at: nil).count } ] do
          send(entry, speaker_token)
        end
        assert_response :forbidden
      end
    end
  end

  ADMITTED_BROWSERS.each do |browser_label, browser|
    ENTRIES.each do |entry_label, entry|
      verdict = REFUSED_TO_ANY_VIEWER.include?(entry) ? "refusé à tout spectateur" : "admis"
      test "témoin, #{browser_label} × #{entry_label} : #{verdict}" do
        speaker_token = send(browser)

        send(entry, speaker_token)

        if REFUSED_TO_ANY_VIEWER.include?(entry)
          assert_response :forbidden
        else
          assert_not_equal 403, response.status, "#{entry} refusé à un navigateur non retiré"
        end
      end
    end
  end

  test "témoin : l'animation n'est jamais retirée par cette voie, même avec une inscription retirée dans le navigateur" do
    removed_viewer
    sign_in_as(@owner)

    api_token(nil)
    assert_response :success
    assert_equal "host", response.parsed_body.fetch("role")
    messages_index(nil)
    assert_response :success
  end

  # Le nom ne se modifie pas : le propriétaire révoque puis
  # recrée le lien ; le même navigateur entre avec le nouveau.
  test "révocation : révoquer puis recréer un intervenant, même navigateur : accès rétabli" do
    first = shared_speaker("Basile Delmas")
    first.revoke!
    second = @webinar.speakers.create!(name: "Basile Delmas")

    request_as(:get, invitation_path(t: @share_token))
    assert_response :success, "le lien partagé redonne le formulaire, comme avant"
    request_as(:get, join_webinar_path(slug: @webinar.slug, t: second.token))
    assert_response :success
    api_token(second.token)
    assert_response :success
    assert_equal "speaker-#{second.id}", response.parsed_body.fetch("identity")
  end

  # Fermer le navigateur n'efface pas les cookies d'identité.
  test "persistance : cookies d'identité persistants, jusqu'au lendemain de la fin prévue, 30 jours au plus" do
    confirmed_viewer
    shared_speaker("Intrus")
    planned_expiry = @webinar.planned_ends_at + 1.day

    %W[registration_id share_speaker_#{@webinar.id}].each do |name|
      assert_in_delta planned_expiry, cookies.get_cookie(name).expires, 1.second, name
    end

    far = Webinar.create!(title: "Café IA #12", starts_at: 3.months.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    confirmed_viewer(webinar: far)
    assert_in_delta 30.days.from_now, cookies.get_cookie("registration_id").expires, 5.seconds
  end

  # Un direct lancé ou repris après la date prévue ne doit
  # pas poser un cookie déjà expiré (le spectateur recevait 403).
  test "persistance : direct repris 3 jours après la date prévue, le spectateur inscrit entre" do
    @webinar.update!(starts_at: 3.days.ago, started_at: 3.days.ago, state: "live")
    confirmed_viewer

    assert_operator cookies.get_cookie("registration_id").expires, :>, 23.hours.from_now
    api_token(nil)
    assert_response :success
    assert_equal "viewer", response.parsed_body.fetch("role")
  end

  test "persistance : l'accès immédiat pose le cookie d'inscription par son POST, persistant comme les autres" do
    register_during_live(nil)
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert_in_delta @webinar.planned_ends_at + 1.day, cookies.get_cookie("registration_id").expires, 1.second

    cookies.delete("registration_id")
    request_as(:post, invitation_create_path(t: @share_token), params: private_link_params("Inès", "spectator"))
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert_in_delta @webinar.planned_ends_at + 1.day, cookies.get_cookie("registration_id").expires, 1.second
  end

  # Un navigateur inscrit garde son inscription. L'accès immédiat
  # d'une autre adresse (inscription publique, lien privé) ne la remplace pas.
  test "accès immédiat d'une autre adresse : l'inscription valide du navigateur est gardée (409)" do
    kept = confirmed_viewer

    register_during_live(nil)
    assert_response :conflict
    request_as(:post, invitation_create_path(t: @share_token), params: private_link_params("Autre", "spectator"))
    assert_response :conflict
    assert_select "[data-role='registration-already-registered']"

    api_token(nil)
    assert_equal "viewer-#{kept.id}", response.parsed_body.fetch("identity")
  end

  test "persistance : la trace du retrait est posée dès que l'identité retirée est vue, pour 30 jours" do
    removed_viewer
    assert_nil cookies.get_cookie("room_removed_#{@webinar.id}")

    api_token(nil)
    assert_response :forbidden
    assert_in_delta 30.days.from_now, cookies.get_cookie("room_removed_#{@webinar.id}").expires, 5.seconds
  end

  # Lien d'un tiers : un participant retiré envoie à sa victime son
  # lien GET ; le navigateur de la victime ne doit pas adopter son identité.
  test "lien d'un tiers : le GET /r/<jeton> d'une inscription retirée ne pose aucun cookie et ne bannit pas la victime" do
    attacker = @webinar.registrations.create!(name: "Intrus", email: "intrus@example.test", confirmed_at: Time.current)
    attacker.remove_from_room!
    confirmed_viewer

    request_as(:get, confirm_registration_path(attacker.token))
    assert_response :forbidden
    assert_nil response.headers["set-cookie"]

    request_as(:post, confirm_registration_path(attacker.token))
    assert_response :forbidden, "le bouton non plus n'adopte une identité retirée"
    assert_nil response.headers["set-cookie"]

    api_token(nil)
    assert_response :success
    assert_equal "viewer", response.parsed_body.fetch("role")
  end

  # Chemin POST : la victime inscrite clique le bouton
  # d'accès du lien d'un attaquant ; elle garde sa propre inscription et le
  # retrait de l'attaquant ne la touche pas.
  test "lien d'un tiers : le bouton d'accès d'un tiers ne remplace pas l'inscription valide du navigateur" do
    victim = confirmed_viewer
    attacker = @webinar.registrations.create!(name: "Intrus", email: "intrus@example.test", confirmed_at: Time.current)

    request_as(:post, confirm_registration_path(attacker.token))
    assert_response :conflict
    assert_select "[data-role='registration-already-registered']"
    assert_not_includes response.body, "Intrus"
    # « Ce n'est pas moi » nomme l'inscription qu'il oublie : la sienne.
    assert_select "[data-role='registration-not-me']", text: /au nom de «\u00a0#{victim.name}\u00a0»/
    assert_no_match(/registration_id/, response.headers["set-cookie"].to_s)

    attacker.remove_from_room!
    api_token(nil)
    assert_response :success
    assert_equal "viewer-#{victim.id}", response.parsed_body.fetch("identity")
  end

  test "lien d'un tiers : le bouton de sa propre inscription redonne l'accès, l'inscription d'un autre webinaire n'empêche rien" do
    victim = confirmed_viewer
    request_as(:post, confirm_registration_path(victim.token))
    assert_redirected_to public_webinar_path(@webinar.slug)

    other = Webinar.create!(title: "Café IA #11", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    confirmed_viewer(webinar: other, email: "ines.autre@example.test")
    assert_response :redirect
  end

  test "lien d'un tiers : le GET /join?t=<jeton retiré> ne pose aucun cookie et ne bannit pas la victime" do
    attacker = @webinar.speakers.create!(name: "Intrus")
    attacker.remove_from_room!
    confirmed_viewer

    request_as(:get, join_webinar_path(slug: @webinar.slug, t: attacker.token))
    assert_response :not_found
    assert_nil response.headers["set-cookie"]

    api_token(nil)
    assert_response :success
    request_as(:get, invitation_path(t: @share_token))
    assert_response :success
  end

  test "lien d'un tiers : aucune entrée GET ne pose de cookie d'identité, même sur un lien valide" do
    active = @webinar.speakers.create!(name: "Mathilde B.")
    confirmed = @webinar.registrations.create!(name: "Léa", email: "lea@example.test", confirmed_at: Time.current)

    [ join_webinar_path(slug: @webinar.slug, t: active.token), confirm_registration_path(confirmed.token),
      invitation_path(t: @share_token), public_webinar_path(@webinar.slug) ].each do |path|
      request_as(:get, path)
      assert_response :success, path
      assert_no_match(/registration_id|share_speaker_|room_removed_/, response.headers["set-cookie"].to_s, path)
    end
  end

  # Intervenant entré par son lien personnel : aucun cookie (aucun GET n'en
  # pose). Son jeton retiré ferme chaque requête qui le présente, sans repli
  # spectateur ; sans son jeton, il revient comme spectateur avec sa propre
  # inscription (limite déclarée, docs/moderation.md).
  test "intervenant nominatif retiré : son jeton présenté ferme la requête, sans repli spectateur" do
    confirmed_viewer
    speaker = @webinar.speakers.create!(name: "Basile")
    speaker.remove_from_room!

    %i[api_token device_preferences messages_index messages_create poll_current qa_current].each do |entry|
      send(entry, speaker.token)
      assert_response :forbidden, entry
    end
  end

  test "limite déclarée : l'intervenant nominatif retiré revient comme spectateur sans son jeton" do
    confirmed_viewer
    @webinar.speakers.create!(name: "Basile").remove_from_room!

    api_token(nil)
    assert_response :success
    assert_equal "viewer", response.parsed_body.fetch("role")
  end

  # ---- « Ce n'est pas moi » (NotMeController) ----
  # Le cookie d'inscription est persistant et un navigateur garde sa première
  # inscription valide (409 sur une autre) : « Ce n'est pas moi » la fait
  # oublier à ce navigateur, sans jamais lever un retrait.

  # Ordinateur partagé : la personne suivante trouve la salle ouverte sous le
  # nom de la précédente ; elle la fait oublier, s'inscrit et entre sous le sien.
  test "Ce n'est pas moi : ordinateur partagé, oubli puis nouvelle inscription sous son nom" do
    previous = confirmed_viewer
    request_as(:get, public_webinar_path(@webinar.slug))
    assert_select "#livekit-room"
    assert_select "[data-role='registration-not-me']", text: /«\u00a0Inès\u00a0»/
    assert_not_me_button

    not_me
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert cookies["registration_id"].blank?, "ce navigateur ne porte plus d'inscription"
    follow_redirect!(env: { "REMOTE_ADDR" => @ip })
    assert_select "[data-role='pre-live']"
    assert_select "[data-role='registration-not-me']", count: 0
    assert_select ".etat--succes", text: Voice.t("registrations.not_me.forgotten", voice: @webinar.voice)

    request_as(:post, public_webinar_registrations_path(@webinar.slug),
      params: { registration: { name: "Basile", email: "basile@example.test" } })
    assert_redirected_to public_webinar_path(@webinar.slug)
    api_token(nil)
    assert_response :success
    basile = @webinar.registrations.find_by!(email: "basile@example.test")
    assert_equal "viewer-#{basile.id}", response.parsed_body.fetch("identity")
    assert previous.reload.confirmed?, "l'inscription oubliée reste en base, intacte"
    assert_nil previous.room_removed_at
  end

  # Deux adresses dans un même navigateur : 409 sur la deuxième, qui entre
  # après l'oubli de la première (le bouton de son lien, rouvert).
  test "Ce n'est pas moi : deux adresses dans un même navigateur, la deuxième entre après l'oubli" do
    first = confirmed_viewer
    second = @webinar.registrations.create!(name: "Inès pro", email: "ines.pro@example.test")

    request_as(:post, confirm_registration_path(second.token))
    assert_response :conflict
    assert_select "[data-role='registration-already-registered'] [data-role='registration-not-me']",
                  text: /au nom de «\u00a0Inès\u00a0»/
    assert_not_includes response.body, "Inès pro", "jamais le nom de l'inscription du lien ouvert"
    assert_not_me_button

    # Chemin proposé pour une deuxième adresse : la page du webinaire (ici la
    # salle), qui nomme l'inscription gardée et propose l'oubli.
    request_as(:get, public_webinar_path(@webinar.slug))
    assert_select "[data-role='registration-not-me']", text: /«\u00a0Inès\u00a0»/
    assert_not_me_button
    not_me
    assert_redirected_to public_webinar_path(@webinar.slug)
    request_as(:post, confirm_registration_path(second.token))
    assert_redirected_to public_webinar_path(@webinar.slug)
    api_token(nil)
    assert_equal "viewer-#{second.id}", response.parsed_body.fetch("identity")

    # Retour à la première : même geste, dans l'autre sens.
    not_me
    request_as(:post, confirm_registration_path(first.token))
    assert_redirected_to public_webinar_path(@webinar.slug)
    api_token(nil)
    assert_equal "viewer-#{first.id}", response.parsed_body.fetch("identity")
  end

  # Avant le direct, la page du webinaire nomme l'inscription du navigateur :
  # « Ce n'est pas moi » y est aussi.
  test "Ce n'est pas moi : avant le direct, la page nomme l'inscription et propose l'oubli" do
    upcoming = Webinar.create!(title: "Café IA #13", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    confirmed_viewer(webinar: upcoming, email: "ines.demain@example.test")
    request_as(:get, public_webinar_path(upcoming.slug))
    assert_select "[data-role='registration-cta'] .etat--info", text: /Inès/
    assert_not_me_button(upcoming)

    not_me(upcoming)
    assert_redirected_to public_webinar_path(upcoming.slug)
    request_as(:get, public_webinar_path(upcoming.slug))
    assert_select "[data-role='registration-cta'] form[action='#{public_webinar_registrations_path(upcoming.slug)}']"
  end

  test "Ce n'est pas moi n'oublie que l'inscription de ce webinaire" do
    other = Webinar.create!(title: "Café IA #12", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    confirmed_viewer(webinar: other, email: "ines.ailleurs@example.test")
    kept = cookies["registration_id"]

    not_me
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert_equal kept, cookies["registration_id"], "le cookie d'inscription d'un autre webinaire reste"
    request_as(:get, public_webinar_path(other.slug))
    assert_select "[data-role='registration-cta'] .etat--info", text: /Inès/
  end

  test "Ce n'est pas moi : webinaire inconnu ou brouillon → 404, rien d'oublié" do
    draft = Webinar.create!(title: "Brouillon", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub)
    confirmed_viewer
    kept = cookies["registration_id"]

    [ "inconnu-#{SecureRandom.hex(3)}", draft.slug ].each do |slug|
      request_as(:post, public_webinar_not_me_path(slug))
      assert_response :not_found, slug
    end
    assert_equal kept, cookies["registration_id"]
  end

  # La garde ne doit pas être contournée : un navigateur retiré reçoit
  # « Accès retiré », aucun cookie d'identité n'est effacé ni modifié, la trace
  # du retrait est posée (jamais levée), et il reste retiré partout ensuite.
  REMOVED_BROWSERS.each do |browser_label, browser|
    test "#{browser_label} : reste retiré après « Ce n'est pas moi »" do
      speaker_token = send(browser)
      before = identity_cookies

      not_me
      assert_response :forbidden
      assert_equal before, identity_cookies.slice(*before.keys), "aucun cookie d'identité effacé ni modifié"
      assert cookies["room_removed_#{@webinar.id}"].present?, "la trace du retrait est posée, jamais levée"

      ENTRIES.each_value do |entry|
        send(entry, speaker_token)
        assert_response :forbidden, entry
      end
      assert cookies["room_removed_#{@webinar.id}"].present?
    end
  end

  # Un animateur connecté n'est jamais retiré (RoomRemoval) : sa règle le
  # laisse passer. S'il porte une inscription retirée et la fait oublier, le
  # retrait reste tracé et ce navigateur reste retiré une fois la session finie.
  test "Ce n'est pas moi d'un animateur connecté : le retrait de l'inscription oubliée reste tracé" do
    removed_viewer
    sign_in_as(@owner)
    assert_nil cookies["room_removed_#{@webinar.id}"]

    not_me
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert cookies["registration_id"].blank?
    assert cookies["room_removed_#{@webinar.id}"].present?, "le retrait de l'inscription oubliée reste tracé"

    restart_browser
    register_during_live(nil)
    assert_response :forbidden
  end

  test "Ce n'est pas moi sans inscription à oublier : aucun message d'oubli" do
    not_me
    assert_redirected_to public_webinar_path(@webinar.slug)
    assert_nil flash[:notice]
  end

  test "Ce n'est pas moi : la trace d'un retrait que désignait un ancien cookie reste" do
    removed_viewer_registered_elsewhere
    trace = cookies["room_removed_#{@webinar.id}"]
    assert trace.present?

    other = Webinar.find_by!(title: "Café IA #10")
    not_me(other)
    assert_redirected_to public_webinar_path(other.slug)
    assert cookies["registration_id"].blank?
    assert_equal trace, cookies["room_removed_#{@webinar.id}"], "la trace du retrait n'est jamais levée"
    api_token(nil)
    assert_response :forbidden
    register_during_live(nil)
    assert_response :forbidden
  end

  private

  # ---- navigateurs ----

  def confirmed_viewer(email: "ines@example.test", webinar: @webinar)
    registration = webinar.registrations.create!(name: "Inès", email: email)
    request_as(:post, confirm_registration_path(registration.token))
    assert_response :redirect
    registration
  end

  def confirmed_viewer_token
    confirmed_viewer
    nil
  end

  def confirmed_viewer_after_restart
    confirmed_viewer
    restart_browser
    nil
  end

  def shared_speaker(name)
    request_as(:post, invitation_create_path(t: @share_token), params: private_link_params(name, "participant"))
    assert_response :see_other
    @webinar.speakers.find_by!(name: name)
  end

  def removed_viewer
    confirmed_viewer.remove_from_room!
    nil
  end

  def removed_viewer_after_restart
    removed_viewer
    restart_browser
    nil
  end

  def removed_shared_speaker
    confirmed_viewer
    speaker = shared_speaker("Intrus")
    speaker.remove_from_room!
    speaker.token
  end

  def removed_shared_speaker_after_restart
    speaker = shared_speaker("Intrus")
    speaker.remove_from_room!
    restart_browser
    speaker.token
  end

  def revoked_shared_speaker
    confirmed_viewer
    speaker = shared_speaker("Révoqué")
    speaker.revoke!
    speaker.token
  end

  def instant_viewer_token
    register_during_live(nil)
    assert_redirected_to public_webinar_path(@webinar.slug)
    nil
  end

  def removed_instant_viewer
    request_as(:post, public_webinar_registrations_path(@webinar.slug),
      params: { registration: { name: "Inès", email: "ines-direct@example.test" } })
    assert_redirected_to public_webinar_path(@webinar.slug)
    @webinar.registrations.find_by!(email: "ines-direct@example.test").remove_from_room!
    nil
  end

  def removed_private_link_viewer
    request_as(:post, invitation_create_path(t: @share_token), params: private_link_params("Intrus", "spectator"))
    assert_redirected_to public_webinar_path(@webinar.slug)
    @webinar.registrations.find_by!(name: "Intrus").remove_from_room!
    nil
  end

  # Retiré comme on retire depuis la régie (ParticipantModeration). Son
  # adresse neuve n'est pas prouvée : seul l'intervenant est retiré, et son
  # cookie ferme ce navigateur.
  def removed_private_link_speaker
    speaker = shared_speaker("Intrus")
    ParticipantModeration.new(@webinar, "speaker-#{speaker.id}").remove
    speaker.token
  end

  # L'intrus n'est pas rattaché à l'inscription de la
  # victime (lien non prouvé) ; le retirer ne la retire pas.
  def victim_of_removed_intruder
    victim = confirmed_viewer
    intruder_browser = open_session
    intruder_browser.post invitation_create_path(t: @share_token),
      params: { invitation: { name: "Intrus", email: victim.email, participation: "participant" } },
      env: { "REMOTE_ADDR" => @ip }
    ParticipantModeration.new(@webinar, "speaker-#{@webinar.speakers.find_by!(name: "Intrus").id}").remove
    nil
  end

  # L'inscription créée par l'intrus pour
  # l'adresse neuve de la victime ne lui est pas rattachée ; le retirer ne la
  # retire pas, et la victime entre après avoir confirmé.
  def new_address_victim_of_removed_intruder
    intruder_browser = open_session
    intruder_browser.post invitation_create_path(t: @share_token),
      params: { invitation: { name: "Intrus", email: "victime-neuve@example.test", participation: "participant" } },
      env: { "REMOTE_ADDR" => @ip }
    ParticipantModeration.new(@webinar, "speaker-#{@webinar.speakers.find_by!(name: "Intrus").id}").remove
    victim = @webinar.registrations.find_by!(email: "victime-neuve@example.test")
    request_as(:post, confirm_registration_path(victim.token))
    assert_redirected_to public_webinar_path(@webinar.slug)
    nil
  end

  # Format d'avant le secret d'identité (id seul, chiffré, posé par un POST
  # de l'époque) : il désigne encore une inscription retirée, jamais un accès.
  def removed_legacy_viewer
    registration = @webinar.registrations.create!(name: "Ancien", email: "ancien@example.test", confirmed_at: Time.current)
    registration.remove_from_room!
    jar = ActionDispatch::Request.new(Rails.application.env_config.deep_dup).cookie_jar
    jar.encrypted[:registration_id] = registration.id
    cookies[:registration_id] = jar[:registration_id]
    nil
  end

  def removed_viewer_registered_elsewhere
    removed_viewer
    other = Webinar.create!(title: "Café IA #10", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    confirmed_viewer(webinar: other)
    nil
  end

  # Fermeture du navigateur : les cookies de session disparaissent (session
  # Rails comprise), les cookies persistants restent.
  def restart_browser
    cookies.to_hash.each_key { |name| cookies.delete(name) unless cookies.get_cookie(name).expires }
  end

  # ---- entrées ----

  def api_token(speaker_token)
    request_as(:post, "/api/token", params: { slug: @webinar.slug, speaker_token: speaker_token }, as: :json)
  end

  def device_preferences(speaker_token)
    request_as(:patch, "/api/device_preferences", as: :json,
      params: { slug: @webinar.slug, speaker_token: speaker_token, device_preferences: { audioEnabled: true } })
  end

  def invitation_show(_speaker_token)
    request_as(:get, invitation_path(t: @share_token))
  end

  def invitation_create(_speaker_token)
    request_as(:post, invitation_create_path(t: @share_token), params: private_link_params("Nouveau nom", "participant"))
  end

  def invitation_create_spectator(_speaker_token)
    request_as(:post, invitation_create_path(t: @share_token), params: private_link_params("Nouveau nom", "spectator"))
  end

  def register_during_live(_speaker_token)
    request_as(:post, public_webinar_registrations_path(@webinar.slug),
      params: { registration: { name: "Autre adresse", email: "autre-#{SecureRandom.hex(3)}@example.test" } })
  end

  # Le navigateur présente son inscription comme « participante » : son
  # entrée (jeton) lèverait sa main d'office.
  def declared_hand(speaker_token)
    @webinar.registrations.update_all(participation: "participant")
    api_token(speaker_token)
  end

  def join_other_speaker(_speaker_token)
    request_as(:get, join_webinar_path(slug: @webinar.slug, t: @other_speaker.token))
  end

  def confirm_new_registration(_speaker_token)
    registration = @webinar.registrations.create!(name: "Autre adresse", email: "autre-#{SecureRandom.hex(3)}@example.test")
    request_as(:post, confirm_registration_path(registration.token))
  end

  def messages_index(speaker_token)
    request_as(:get, public_webinar_messages_path(@webinar.slug), as: :json, headers: speaker_header(speaker_token))
  end

  def messages_create(speaker_token)
    request_as(:post, public_webinar_messages_path(@webinar.slug), params: { body: "Bonjour" }, as: :json,
      headers: speaker_header(speaker_token))
  end

  def hand_raise_create(_speaker_token)
    request_as(:post, public_hand_raises_path(@webinar.slug), as: :json)
  end

  def hand_raise_status(_speaker_token)
    request_as(:get, public_hand_raises_path(@webinar.slug), as: :json)
  end

  def poll_current(speaker_token)
    request_as(:get, current_public_webinar_poll_path(@webinar.slug), as: :json, headers: speaker_header(speaker_token))
  end

  def qa_current(speaker_token)
    request_as(:get, public_qa_display_path(@webinar.slug), as: :json, headers: speaker_header(speaker_token))
  end

  def recording_status(_speaker_token)
    request_as(:get, public_webinar_recording_status_path(@webinar.slug), as: :json)
  end

  # La parole est accordée à toute inscription du navigateur, retirée ou
  # non : seule la garde du retrait peut refuser.
  def participant_consent_create(speaker_token)
    @webinar.registrations.find_each do |registration|
      next if @webinar.hand_raises.active.exists?(registration: registration)

      HandRaise.create!(webinar: @webinar, registration: registration, state: "granted", raised_at: Time.current)
    end
    request_as(:post, "/api/participant_consent", as: :json,
      params: { slug: @webinar.slug, speaker_token: speaker_token, recording: true, excerpts: true, adult: true })
  end

  def participant_consent_destroy(speaker_token)
    request_as(:delete, "/api/participant_consent", as: :json, params: { slug: @webinar.slug, speaker_token: speaker_token })
  end

  # Une adresse neuve à chaque envoi : jamais l'inscription d'un autre navigateur.
  def private_link_params(name, participation)
    { invitation: { name: name, email: "#{name.parameterize}-#{SecureRandom.hex(3)}@example.test", participation: participation } }
  end

  def speaker_header(speaker_token)
    speaker_token ? { "X-Speaker-Token" => speaker_token } : {}
  end

  # « Ce n'est pas moi » : POST du bouton (CSRF coupé en test ; le vrai
  # navigateur est rejoué par TokenPageButtonsOriginTest).
  def not_me(webinar = @webinar)
    request_as(:post, public_webinar_not_me_path(webinar.slug))
  end

  def assert_not_me_button(webinar = @webinar)
    assert_select "[data-role='registration-not-me'] form[method='post'][action='#{public_webinar_not_me_path(webinar.slug)}']" do
      assert_select "button", text: "Ce n'est pas moi"
    end
  end

  # Cookies d'identité et traces de retrait du navigateur (nom → valeur).
  def identity_cookies
    cookies.to_hash.select { |name, _| name.match?(/\A(registration_id|share_speaker_\d+|room_removed_\d+)\z/) }
  end

  def request_as(verb, path, **options)
    public_send(verb, path, **options, env: { "REMOTE_ADDR" => @ip })
  end
end
