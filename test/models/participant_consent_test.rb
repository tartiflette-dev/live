require "test_helper"

# Accord à l'image (contre) :
# une preuve figée — cases, libellés affichés, version de la politique, date —
# que seul le retrait vient compléter.
class ParticipantConsentTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-marc", visibility: "published")
    @speaker = @webinar.speakers.create!(name: "Camille Martin")
    @viewer = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
  end

  test "la preuve fige les cases, les libellés affichés, la version de la politique et la date" do
    at = Time.zone.parse("2026-11-04 10:15:00")
    consent = ParticipantConsent.grant!(@speaker, recording: true, excerpts: true, adult: true, now: at)

    assert_equal [ @webinar, @speaker ], [ consent.webinar, consent.holder ]
    assert_equal [ true, true, true ], [ consent.recording_accepted, consent.excerpts_accepted, consent.adult_declared ]
    assert_equal PrivacyPolicy::VERSION, consent.policy_version
    assert_equal "Je suis filmé·e, enregistré·e et transcrit·e, et le replay du direct est rediffusé", consent.recording_label
    assert_equal "J'accepte que des extraits soient publiés par Studio Exemple sur ses sites et réseaux sociaux",
                 consent.excerpts_label
    assert_equal "J'ai 18 ans ou plus", consent.adult_label
    assert_equal "speaker-#{@speaker.id}", consent.participant_identity
    assert_equal at, consent.consented_at
    assert_nil consent.withdrawn_at
  end

  test "la version figée est celle en vigueur au moment de l'accord, pas la suivante" do
    consent = ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)

    stub_const(PrivacyPolicy, :VERSION, "99.0") do
      assert_equal PrivacyPolicy::VERSION, "99.0"
      assert_not_equal "99.0", consent.reload.policy_version
    end
  end

  test "la case des extraits est facultative ; enregistrement et âge sont obligatoires" do
    assert_equal false, ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true).excerpts_accepted

    assert_raises(ActiveRecord::RecordInvalid) { ParticipantConsent.grant!(@viewer, recording: false, excerpts: true, adult: true) }
    assert_raises(ActiveRecord::RecordInvalid) { ParticipantConsent.grant!(@viewer, recording: true, excerpts: true, adult: false) }
    assert_nil ParticipantConsent.current_for(@viewer)
  end

  test "un accord en cours n'est jamais doublé : deux validations rendent le même" do
    first = ParticipantConsent.grant!(@viewer, recording: true, excerpts: false, adult: true)
    second = ParticipantConsent.grant!(@viewer, recording: true, excerpts: true, adult: true)

    assert_equal first, second
    assert_equal false, second.excerpts_accepted
    assert_equal 1, ParticipantConsent.count
  end

  test "le porteur doit appartenir au webinaire de l'accord" do
    other = Webinar.create!(title: "Autre", starts_at: 1.day.from_now, host_sub: "sub-marc")
    consent = ParticipantConsent.new(webinar: other, holder: @speaker, recording_accepted: true, excerpts_accepted: false,
                                     adult_declared: true, policy_version: "1", recording_label: "a", excerpts_label: "b",
                                     adult_label: "c", consented_at: Time.current)

    assert_not consent.valid?
    assert consent.errors.of_kind?(:holder, :invalid)
  end

  test "retrait horodaté une fois ; un nouvel accord ensuite est une nouvelle ligne" do
    consent = ParticipantConsent.grant!(@speaker, recording: true, excerpts: true, adult: true)
    withdrawn_at = Time.zone.parse("2026-11-04 10:40:00")

    assert consent.withdraw!(now: withdrawn_at)
    assert_not consent.withdraw!(now: withdrawn_at + 1.hour)
    assert_equal withdrawn_at, consent.reload.withdrawn_at
    assert_nil ParticipantConsent.current_for(@speaker)

    renewed = ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
    assert_not_equal consent, renewed
    assert_equal [ :withdrawn, :refused ], [ consent.reload.excerpt_status, renewed.excerpt_status ]
  end

  test "ce que la salle sait : accord donné ou non, et les libellés à afficher ; rien pour l'animation de droit" do
    assert_equal({ given: false, labels: ParticipantConsent::LABELS, contact: "contact@example.test" }, ParticipantConsent.payload_for(@webinar, @speaker))

    ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
    assert_equal true, ParticipantConsent.payload_for(@webinar, @speaker)[:given]
    assert_nil ParticipantConsent.payload_for(@webinar, User.create!(email: "marc@example.test", oidc_sub: "sub-marc"))
  end

  test "co-animateur invité : accord porté par son compte, pour CE webinaire seulement" do
    cohost = guest_host(@webinar)
    other = Webinar.create!(title: "Café IA #10", starts_at: 1.day.from_now, host_sub: "sub-marc", visibility: "published")
    other.webinar_hosts.create!(email: cohost.email, invited_by_sub: "sub-marc")

    consent = ParticipantConsent.grant!(cohost, webinar: @webinar, recording: true, excerpts: true, adult: true)

    assert_equal "host-#{cohost.oidc_sub}", consent.participant_identity
    assert_equal consent, ParticipantConsent.current_for(cohost, webinar: @webinar)
    assert_nil ParticipantConsent.current_for(cohost, webinar: other), "un accord ne vaut que pour son webinaire"
    assert ParticipantConsent.grant!(cohost, webinar: other, recording: true, excerpts: false, adult: true).persisted?
  end

  test "un compte qui n'est pas co-animateur invité du webinaire ne porte pas d'accord" do
    stranger = User.create!(email: "x@example.test", oidc_sub: "sub-x")

    assert_raises(ActiveRecord::RecordInvalid) do
      ParticipantConsent.grant!(stranger, webinar: @webinar, recording: true, excerpts: false, adult: true)
    end
  end

  test "une identité de la salle est couverte par l'animation de droit ou par un accord en cours" do
    assert ParticipantConsent.covers?(@webinar, "host-sub-marc")
    cohost = guest_host(@webinar)
    assert_not ParticipantConsent.covers?(@webinar, "host-#{cohost.oidc_sub}"), "co-animateur invité sans accord"
    ParticipantConsent.grant!(cohost, webinar: @webinar, recording: true, excerpts: false, adult: true)
    assert ParticipantConsent.covers?(@webinar, "host-#{cohost.oidc_sub}")

    assert_not ParticipantConsent.covers?(@webinar, "speaker-#{@speaker.id}")
    assert_not ParticipantConsent.covers?(@webinar, "viewer-#{@viewer.id}")

    ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
    viewer_consent = ParticipantConsent.grant!(@viewer, recording: true, excerpts: false, adult: true)
    assert ParticipantConsent.covers?(@webinar, "speaker-#{@speaker.id}")
    assert ParticipantConsent.covers?(@webinar, "viewer-#{@viewer.id}")

    viewer_consent.withdraw!
    assert_not ParticipantConsent.covers?(@webinar, "viewer-#{@viewer.id}")
    other = Webinar.create!(title: "Autre", starts_at: 1.day.from_now, host_sub: "sub-marc")
    assert_not ParticipantConsent.covers?(other, "speaker-#{@speaker.id}")
    assert_not ParticipantConsent.covers?(@webinar, "agent-AJ_x")
  end

  test "identité LiveKit de la personne, figée : elle survit à la purge de l'inscription" do
    assert_equal "speaker-#{@speaker.id}", ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true).participant_identity
    consent = ParticipantConsent.grant!(@viewer, recording: true, excerpts: false, adult: true)
    @viewer.delete
    assert_equal "viewer-#{@viewer.id}", consent.reload.participant_identity
  end

  private

  def guest_host(webinar)
    user = User.create!(email: "camille@example.test", oidc_sub: "sub-camille", email_verified: true,
                        email_verified_for: "camille@example.test")
    webinar.webinar_hosts.create!(email: user.email, invited_by_sub: "sub-marc")
    user
  end
end
