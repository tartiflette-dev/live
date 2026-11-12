require "test_helper"

# Qui peut figurer dans les extraits et shorts :
# le dernier accord de chaque personne fait foi ; l'animation de droit est
# couverte par la politique ; une personne enregistrée sans accord ne l'est pas.
class ExcerptConsentsTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-marc", visibility: "published")
    @allowed = @webinar.speakers.create!(name: "Camille")
    @refused = @webinar.speakers.create!(name: "Mathilde")
    @withdrawn = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)
    ParticipantConsent.grant!(@allowed, recording: true, excerpts: true, adult: true)
    ParticipantConsent.grant!(@refused, recording: true, excerpts: false, adult: true)
    ParticipantConsent.grant!(@withdrawn, recording: true, excerpts: true, adult: true).withdraw!
  end

  test "état de chaque personne : autorisée, non autorisée, retirée, sans accord, animation" do
    silent = @webinar.speakers.create!(name: "Lorenzo")
    @webinar.recordings.create!(kind: :track, status: :done, track_sid: "TR_l", participant_identity: "speaker-#{silent.id}",
                                track_source: "camera", output_prefix: "#{@webinar.slug}/l")
    @webinar.transcript_segments.create!(participant_identity: "host-sub-marc", text: "Bonjour", segment_id: "s1",
                                         started_at: 1.minute.ago, ended_at: Time.current)
    consents = ExcerptConsents.new(@webinar)

    assert_equal({ "host-sub-marc" => :animation, "speaker-#{@allowed.id}" => :allowed, "speaker-#{@refused.id}" => :refused,
                   "speaker-#{silent.id}" => :missing, "viewer-#{@withdrawn.id}" => :withdrawn },
                 consents.identities.index_with { |identity| consents.status(identity) })
    assert_equal "aucun accord : extraits non autorisés", consents.label("speaker-#{silent.id}")
  end

  test "le dernier accord fait foi : retiré puis redonné sans la case des extraits" do
    ParticipantConsent.current_for(@allowed).withdraw!
    ParticipantConsent.grant!(@allowed, recording: true, excerpts: false, adult: true)
    regained = ParticipantConsent.grant!(@withdrawn, recording: true, excerpts: true, adult: true)
    consents = ExcerptConsents.new(@webinar)

    assert_equal :refused, consents.status("speaker-#{@allowed.id}")
    assert_equal :allowed, consents.status(regained.participant_identity)
  end

  test "accord retiré puis redonné : l'historique reste dans le libellé" do
    camille = ParticipantConsent.current_for(@allowed)
    camille.update_columns(consented_at: Time.zone.parse("2026-11-04 9:30"))
    camille.withdraw!(now: Time.zone.parse("2026-11-04 9:45"))
    ParticipantConsent.grant!(@allowed, recording: true, excerpts: true, adult: true, now: Time.zone.parse("2026-11-04 10:05"))
    consents = ExcerptConsents.new(@webinar)

    assert_equal 2, consents.history("speaker-#{@allowed.id}").size
    assert_equal "extraits autorisés (retiré le 04/11/2026 à 9:45, redonné le 04/11/2026 à 10:05)",
                 consents.label("speaker-#{@allowed.id}")
    assert_equal "accord retiré", consents.label("viewer-#{@withdrawn.id}"), "un seul accord : pas d'historique à dérouler"
  end

  test "co-animateur invité : son accord fait foi, comme pour un intervenant ; le propriétaire reste couvert" do
    cohost = User.create!(email: "camille@example.test", oidc_sub: "sub-camille", email_verified: true,
                          email_verified_for: "camille@example.test")
    @webinar.webinar_hosts.create!(email: cohost.email, invited_by_sub: "sub-marc")
    @webinar.transcript_segments.create!(participant_identity: "host-sub-camille", text: "Bonjour", segment_id: "s2",
                                         started_at: 1.minute.ago, ended_at: Time.current)

    assert_equal :missing, ExcerptConsents.new(@webinar).status("host-sub-camille")

    ParticipantConsent.grant!(cohost, webinar: @webinar, recording: true, excerpts: false, adult: true)
    assert_equal :refused, ExcerptConsents.new(@webinar).status("host-sub-camille")
    assert_equal :animation, ExcerptConsents.new(@webinar).status("host-sub-marc")
  end

  test "les accords d'un autre webinaire ne comptent pas" do
    other = Webinar.create!(title: "Autre", starts_at: 1.day.from_now, host_sub: "sub-marc")
    ParticipantConsent.grant!(other.speakers.create!(name: "Eve"), recording: true, excerpts: true, adult: true)

    assert_equal 3, ExcerptConsents.new(@webinar).identities.size
  end
end
