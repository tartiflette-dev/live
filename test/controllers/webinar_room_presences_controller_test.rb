require "test_helper"

# Page « Présence » : consultation seule, réservée à qui voit déjà la liste
# des inscrits (propriétaire, animateurs du projet).
class WebinarRoomPresencesControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.zone.parse("2026-11-10 9:30"), host_sub: @host.oidc_sub)
    @webinar.update!(state: "ended", started_at: Time.zone.parse("2026-11-10 9:32"), ended_at: Time.zone.parse("2026-11-10 10:51"))
    @alice = @webinar.registrations.create!(name: "Alice", email: "alice@example.com", confirmed_at: 2.days.ago)
    @webinar.registrations.create!(name: "Bruno", email: "bruno@example.com", confirmed_at: 2.days.ago)
  end

  def log(clock, kind, identity)
    @webinar.presence_events.create!(kind: kind, identity: identity, occurred_at: Time.zone.parse("2026-11-10 #{clock}"), source: "livekit")
  end

  test "anonyme → connexion ; co-animateur invité et animateur d'un autre webinaire → 404" do
    get webinar_room_presence_path(@webinar)
    assert_redirected_to sign_in_path

    guest = User.create!(email: "co@partenaire.test", oidc_sub: "sub-co", email_verified: true)
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @host.oidc_sub)
    sign_in_as(guest)
    get webinar_room_presence_path(@webinar)
    assert_response :not_found

    sign_in_as(User.create!(email: "eve@example.com", oidc_sub: "sub-eve"))
    get webinar_room_presence_path(@webinar)
    assert_response :not_found
  end

  test "propriétaire : courbe, chronologie, jamais venus, heures au format 9:30" do
    log("9:30:08", "joined", "host-sub-marc")
    log("9:32:54", "joined", "viewer-#{@alice.id}")
    log("9:36:34", "aborted", "viewer-#{@alice.id}")
    log("10:30:10", "left", "viewer-#{@alice.id}")
    log("10:51:42", "left", "host-sub-marc")
    sign_in_as(@host)

    get webinar_room_presence_path(@webinar)

    assert_response :success
    assert_select "h1", "Présence — Café IA #9"
    assert_select "[data-role=presence-curve] svg path.presence-courbe[d^=M]"
    assert_select "[data-role=presence-summary]", /1 inscrit venu sur 2 attendus/
    assert_select "[data-role=presence-person]", 2
    assert_select "[data-role=presence-person]", /Alice.*Inscrit.*9:32 → 10:30.*57 min.*connexion interrompue à 9:36/m
    assert_select "[data-role=presence-never-came] li", "Bruno"
    assert_select "[data-role=presence-provenance]", /webhooks LiveKit reçus en direct/
    assert_select "[data-role=presence-provenance]", /pages ouvertes et les accès à la salle délivrés n'étaient pas encore relevés/
  end

  test "rien de relevé : la page le dit, sans graphique" do
    sign_in_as(@host)

    get webinar_room_presence_path(@webinar)

    assert_response :success
    assert_select "[data-role=presence-provenance]", /Aucune présence relevée/
    assert_select ".presence-svg", 0
    assert_select "[data-role=presence-never-came] li", 2
  end

  test "tentatives seules : la page s'affiche sans graphique, l'inscrit reste à venir" do
    log("9:10", "page_opened", "viewer-#{@alice.id}")
    sign_in_as(@host)

    get webinar_room_presence_path(@webinar)

    assert_response :success
    assert_select ".presence-svg", 0
    assert_select "[data-role=presence-tried]", /Alice.*page ouverte à 9:10/m
    assert_select "[data-role=presence-never-came] li", /Alice \(a essayé/
    assert_select "[data-role=presence-never-came]", text: /Tous les inscrits attendus sont venus/, count: 0
  end

  test "départ sans arrivée relevée : la personne est venue, arrivée inconnue" do
    log("9:30", "joined", "host-sub-marc")
    log("10:30", "left", "viewer-#{@alice.id}")
    log("10:51", "left", "host-sub-marc")
    sign_in_as(@host)

    get webinar_room_presence_path(@webinar)

    assert_select "[data-role=presence-person]", /Alice.*arrivée non relevée → 10:30.*inconnue/m
    assert_select "[data-role=presence-summary]", /1 inscrit venu sur 2 attendus/
  end

  test "sans journal, arrivée notée sur l'inscription : venu, sans prétendre à ce qui n'a pas été relevé" do
    @alice.update!(room_joined_at: Time.zone.parse("2026-11-10 9:35"))
    sign_in_as(@host)

    get webinar_room_presence_path(@webinar)

    assert_select "[data-role=presence-person]", /Alice.*9:35 → départ non relevé/m
    assert_select "[data-role=presence-summary]", text: /animation comprise/, count: 0
    assert_select "[data-role=presence-tried]", 0
    assert_select "[data-role=presence-never-came] li", "Bruno"
  end
end
