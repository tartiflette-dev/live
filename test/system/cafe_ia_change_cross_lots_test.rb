require "application_system_test_case"

# Parcours croisés des lots Café IA : le propriétaire agit depuis
# l'écran d'édition (lot D), les mails partent des callbacks des lots A
# (inscrits) et B (co-animateurs). Rack_test, jobs exécutés à la main.
class CafeIaChangeCrossLotsTest < ApplicationSystemTestCase
  include OidcSignIn
  include ActiveJob::TestHelper

  setup do
    travel_to Time.zone.local(2026, 11, 10, 10, 0)
    @owner = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.zone.local(2026, 11, 12, 18, 0),
                               host_sub: @owner.oidc_sub, visibility: "published", kind: "cafe_ia")
    @cohost = @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    @webinar.registrations.create!(name: "Alice", email: "alice@example.com").confirm!
    @webinar.registrations.create!(name: "Bob", email: "bob@example.com").confirm!
    @webinar.registrations.create!(name: "Carol", email: "carol@example.com")
    HostAttendance.for!(@webinar, @cohost).answer!("present")
    clear_enqueued_jobs
    # Un test système n'hérite pas du vidage d'ActionMailer::TestCase.
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def run_jobs(*jobs)
    perform_enqueued_jobs(only: jobs)
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob)
  end

  def recipients_of(subject_pattern)
    ActionMailer::Base.deliveries.select { |mail| mail.subject.match?(subject_pattern) }.flat_map(&:to).sort
  end

  test "nouvelle date depuis l'écran d'édition : mail aux inscrits confirmés et nouvelle demande au co-animateur" do
    sign_in_as(@owner)
    visit webinar_edition_path(@webinar)
    assert_selector "[data-role='reschedule-notice']",
                    text: "Changer la date prévient les 2 personnes inscrites et confirmées"
    fill_in "Démarre le", with: "2026-11-13T19:30"
    click_on "Enregistrer"
    assert_text "Webinaire modifié."

    # La date a bougé : le « oui » du co-animateur valait pour l'ancienne.
    visit public_webinar_path(@webinar.slug)
    assert_selector "[data-role='date-status']", text: "À confirmer"

    # Plusieurs retouches font un seul envoi : les deux annonces attendent.
    assert_enqueued_with(job: WebinarChangeNoticeJob, at: WebinarChangeNotice::QUIET_PERIOD.from_now)
    assert_enqueued_with(job: HostAttendanceRequestJob, at: Webinar::HostPresence::RESCHEDULE_REQUEST_DELAY.from_now)
    assert_empty ActionMailer::Base.deliveries

    travel [ WebinarChangeNotice::QUIET_PERIOD, Webinar::HostPresence::RESCHEDULE_REQUEST_DELAY ].max + 1.second
    run_jobs(WebinarChangeNoticeJob, HostAttendanceRequestJob)

    assert_equal %w[alice@example.com bob@example.com], recipients_of(/\ANouvelle date pour le café : Café IA #9\z/),
                 "autant de destinataires que l'écran l'annonçait, les mêmes"
    assert_equal [ "jean@partenaire.example.org" ], recipients_of(/seras-tu là le/)
    assert_equal 3, ActionMailer::Base.deliveries.size
  end

  test "annulation à H-5 depuis l'écran d'édition : mail d'annulation tout de suite, sans demande de présence" do
    travel_to Time.zone.local(2026, 11, 12, 17, 55)
    sign_in_as(@owner)
    visit webinar_edition_path(@webinar)
    check "Je confirme l’annulation : le café quitte le catalogue et l’agenda, " \
          "et les 2 personnes inscrites et confirmées seront prévenues."
    click_on "Dépublier (annuler ce café)"
    assert_text "Webinaire annulé"

    # Café imminent : pas de délai d'apaisement, et l'heure de début passée
    # au moment où le job tourne n'empêche pas l'annonce.
    job = enqueued_jobs.find { |enqueued| enqueued[:job] == WebinarChangeNoticeJob }
    assert job[:at].nil? || job[:at] <= Time.current.to_f, "annonce immédiate attendue"
    travel 6.minutes
    run_jobs(WebinarChangeNoticeJob, HostAttendanceRequestJob)

    assert_equal %w[alice@example.com bob@example.com], recipients_of(/\ACafé annulé : Café IA #9\z/)
    assert_empty recipients_of(/seras-tu là/), "un café annulé ne redemande pas la présence"
  end
end
