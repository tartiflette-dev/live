require "test_helper"

# Écran d'édition /webinars/:slug/edition : propriétaire seulement. Le
# co-animateur, l'animateur du projet et l'utilisateur sans rôle reçoivent 404
# (défense énumération, comme WebinarHostsController). Temps figé une semaine
# avant le passage à l'heure d'été (28/03/2027) : aucun test ne dépend de
# l'heure à laquelle la suite tourne.
class WebinarEditionsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  STARTS_AT = Time.zone.local(2027, 3, 22, 18, 0)

  setup do
    travel_to Time.zone.local(2027, 3, 20, 10, 0)
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @other = User.create!(email: "autre@example.net", oidc_sub: "sub-autre")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: STARTS_AT,
                               host_sub: @owner.oidc_sub, visibility: "published")
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "anonyme renvoyé vers la connexion" do
    get webinar_edition_path(@webinar)
    assert_redirected_to sign_in_path
  end

  test "le propriétaire voit le formulaire, date en heure de Paris" do
    sign_in_as(@owner)
    get webinar_edition_path(@webinar)

    assert_response :success
    assert_select "input[name='webinar[starts_at]'][value=?]", "2027-03-22T18:00:00"
  end

  test "le propriétaire déplace la date, saisie en heure de Paris" do
    sign_in_as(@owner)

    patch webinar_edition_path(@webinar), params: { webinar: { starts_at: "2027-03-23T19:30",
                                                               title: "Café IA #9 bis", state: "ended",
                                                               visibility: "draft", host_sub: "sub-pirate" } }

    assert_redirected_to webinar_path(@webinar)
    @webinar.reload
    assert_equal Time.zone.local(2027, 3, 23, 19, 30), @webinar.starts_at
    assert_equal "Café IA #9 bis", @webinar.title
    assert_equal [ "draft", "published", @owner.oidc_sub ], [ @webinar.state, @webinar.visibility, @webinar.host_sub ],
                 "seuls titre, date et description sont modifiables"
  end

  # Le programme a son propre formulaire, envoyé à l'écran du programme :
  # corriger le titre n'écrase pas un programme saisi entre-temps par un
  # co-animateur.
  test "l'écran d'édition porte le formulaire du programme, envoyé à part" do
    sign_in_as(@owner)
    get webinar_edition_path(@webinar)

    assert_select "[data-role='webinar-edition'] input[name='webinar[topic]']", count: 0
    assert_select "[data-role='webinar-edition-program'] form[action=?]", webinar_program_path(@webinar) do
      assert_select "input[name='webinar[topic]']"
      assert_select "textarea[name='webinar[topic_summary]']"
      assert_select "input[name='webinar[announced_speakers][]']", count: Webinar::Program::ANNOUNCED_SPEAKERS_MAX
      assert_select "input[name='webinar[lead_host_name]']"
    end
  end

  test "enregistrer l'édition ne touche pas le programme" do
    @webinar.update!(topic: "Sujet du co-animateur", announced_speakers: [ "Karim" ])
    sign_in_as(@owner)

    patch webinar_edition_path(@webinar), params: { webinar: { title: "Café IA #9 bis", topic: "",
                                                               announced_speakers: [ "" ] } }

    assert_redirected_to webinar_path(@webinar)
    @webinar.reload
    assert_equal [ "Café IA #9 bis", "Sujet du co-animateur", [ "Karim" ] ],
                 [ @webinar.title, @webinar.topic, @webinar.announced_speakers ]
  end

  test "changement d'heure : 18:00 saisi après le passage à l'heure d'été reste 18:00 à Paris" do
    sign_in_as(@owner)
    patch webinar_edition_path(@webinar), params: { webinar: { starts_at: "2027-03-29T18:00" } }

    assert_redirected_to webinar_path(@webinar)
    starts_at = @webinar.reload.starts_at
    assert_equal Time.utc(2027, 3, 29, 16, 0), starts_at.utc, "+02:00 après le 28/03"
    assert_equal Time.utc(2027, 3, 22, 17, 0), STARTS_AT.utc, "+01:00 avant le 28/03"
    assert_equal "18:00", starts_at.in_time_zone("Europe/Paris").strftime("%H:%M")
  end

  test "date passée : 422, rien n'est écrit" do
    sign_in_as(@owner)
    patch webinar_edition_path(@webinar), params: { webinar: { starts_at: "2027-03-19T18:00" } }

    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /doit être au moins 15 minutes après maintenant/
    assert_equal STARTS_AT, @webinar.reload.starts_at
  end

  test "co-animateur, animateur du projet et utilisateur sans rôle : 404 sur chaque action" do
    [ @guest, @admin, @other ].each do |user|
      sign_in_as(user)

      get webinar_edition_path(@webinar)
      assert_response :not_found, user.email
      patch webinar_edition_path(@webinar), params: { webinar: { title: "Piraté" } }
      assert_response :not_found, user.email
      post unpublish_webinar_edition_path(@webinar), params: { confirmation: "1" }
      assert_response :not_found, user.email
    end

    @webinar.reload
    assert_equal "Café IA #9", @webinar.title
    assert @webinar.visibility_published?
  end

  test "dépublier exige la case de confirmation" do
    sign_in_as(@owner)
    post unpublish_webinar_edition_path(@webinar)

    assert_response :unprocessable_entity
    assert @webinar.reload.visibility_published?
  end

  test "dépublier avec confirmation retire le webinaire du catalogue" do
    sign_in_as(@owner)
    post unpublish_webinar_edition_path(@webinar), params: { confirmation: "1" }

    assert_redirected_to webinar_path(@webinar)
    assert @webinar.reload.visibility_draft?
  end

  test "webinaire en direct : écran, modification et dépublication refusés" do
    @webinar.update!(state: "live", started_at: Time.current)
    sign_in_as(@owner)

    get webinar_edition_path(@webinar)
    assert_redirected_to webinar_path(@webinar)
    patch webinar_edition_path(@webinar), params: { webinar: { starts_at: "2027-03-25T18:00", title: "Déplacé" } }
    assert_redirected_to webinar_path(@webinar)
    post unpublish_webinar_edition_path(@webinar), params: { confirmation: "1" }
    assert_redirected_to webinar_path(@webinar)

    @webinar.reload
    assert_equal [ STARTS_AT, "Café IA #9", "published" ], [ @webinar.starts_at, @webinar.title, @webinar.visibility ]
  end
end
