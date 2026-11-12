require "test_helper"

# Écran d'envoi groupé : droits par cible et quotas, confirmation explicite
# sur le nombre montré, idempotence, journal, reprise.
class WebinarAnnouncementsControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include ActiveJob::TestHelper

  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "sub-owner")
    @project = project_host_user
    @stranger = User.create!(email: "autre@example.test", oidc_sub: "sub-autre")
    # Café du jour en cours : la fenêtre du co-animateur est ouverte.
    @webinar = announcement_webinar(host_sub: @owner.oidc_sub, starts_at: 10.minutes.ago)
    @guest = guest_user(@webinar)
    confirmed_registration(@webinar, "ana@example.test")
    confirmed_registration(@webinar, "bob@example.test")
    consenting_request("liste@example.test")
    # Les fabriques publient un café et lui ajoutent un co-animateur : les
    # demandes de présence (HostAttendanceRequestJob) ne sont pas l'objet ici.
    clear_enqueued_jobs
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def message_params(audience = "webinar_registrants")
    { announcement: { audience: audience, subject: "Infos du jour", body: "RDV salle 2." } }
  end

  def confirm(audience: "webinar_registrants", count: 2, token: "tok-1", confirmed: "1")
    post webinar_announcements_path(@webinar),
         params: message_params(audience).merge(dispatch_token: token, expected_count: count, confirmed: confirmed)
  end

  def recipient_jobs
    enqueued_jobs.count { |job| job["arguments"].first == "AnnouncementMailer" }
  end

  test "anonyme : renvoyé à la connexion ; sans rôle : 404" do
    get new_webinar_announcement_path(@webinar)
    assert_redirected_to sign_in_path

    sign_in_as(@stranger)
    get new_webinar_announcement_path(@webinar)
    assert_response :not_found
    post preview_webinar_announcements_path(@webinar), params: message_params
    assert_response :not_found
  end

  test "animateur du projet : trois cibles proposées, avec leur nombre de destinataires" do
    sign_in_as(@project)
    get new_webinar_announcement_path(@webinar)

    assert_response :success
    assert_select "input[type=radio][name='announcement[audience]']", 3
    assert_select "[data-audience=webinar_registrants] [data-role=audience-count]", text: "2 destinataires"
    assert_select "[data-audience=marketing_list] [data-role=audience-count]", text: "1 destinataire"
    assert_not_includes response.body, "ana@example.test"
  end

  test "propriétaire hors animateurs du projet : les inscrits seulement, listes en 404" do
    sign_in_as(@owner)
    get new_webinar_announcement_path(@webinar)
    assert_select "input[type=radio][name='announcement[audience]']", 1

    %w[marketing_list notify_next].each do |audience|
      post preview_webinar_announcements_path(@webinar), params: message_params(audience)
      assert_response :not_found
      confirm(audience: audience, count: 1, token: "tok-#{audience}")
      assert_response :not_found
    end
    assert_equal 0, Announcement.count
  end

  test "co-animateur : seulement les inscrits de son webinaire ; les listes lui sont refusées" do
    sign_in_as(@guest)
    get new_webinar_announcement_path(@webinar)
    assert_select "input[type=radio][name='announcement[audience]']", 1
    assert_select "input[value=webinar_registrants]"

    %w[marketing_list notify_next].each do |audience|
      post preview_webinar_announcements_path(@webinar), params: message_params(audience)
      assert_response :not_found
      confirm(audience: audience, count: 1, token: "tok-#{audience}")
      assert_response :not_found
    end
    assert_equal 0, Announcement.count
  end

  test "co-animateur hors du jour du café : 404 sur l'écran d'envoi, journal toujours lisible" do
    @webinar.update!(starts_at: 3.days.from_now)
    sign_in_as(@guest)

    get new_webinar_announcement_path(@webinar)
    assert_response :not_found
    confirm(token: "tok-hors-jour")
    assert_response :not_found
    get webinar_announcements_path(@webinar)
    assert_response :success
  end

  test "co-animateur : quatrième envoi du jour refusé en 429, rien ne part" do
    sign_in_as(@guest)
    3.times { |index| confirm(token: "tok-#{index}") }
    assert_equal 3, Announcement.count
    clear_enqueued_jobs

    post preview_webinar_announcements_path(@webinar), params: message_params
    assert_response :too_many_requests
    assert_select ".etat--ecart", text: /3 envois/
    confirm(token: "tok-4")
    assert_response :too_many_requests
    assert_equal 3, Announcement.count
    assert_equal 0, recipient_jobs
  end

  test "listes : second envoi dans les 24 h refusé en 429" do
    sign_in_as(@project)
    confirm(audience: "marketing_list", count: 1, token: "tok-liste")
    assert_redirected_to webinar_announcements_path(@webinar)

    confirm(audience: "notify_next", count: 1, token: "tok-prochain")
    assert_response :too_many_requests
    assert_select ".etat--ecart", text: /un seul par 24 h/
    assert_equal 1, Announcement.count
  end

  test "aperçu : objet, corps, pied et nombre de destinataires, rien n'est envoyé" do
    sign_in_as(@owner)
    post preview_webinar_announcements_path(@webinar), params: message_params

    assert_response :success
    assert_select "[data-role=recipients-count]", text: /2 destinataires/
    assert_select "[data-role=announcement-preview]", text: /RDV salle 2\./
    assert_select "input[name=expected_count][value='2']"
    assert_select "input[name=confirmed][type=checkbox][required]"
    assert_equal 0, Announcement.count
    assert_empty enqueued_jobs
  end

  test "aperçu d'un message incomplet : retour au formulaire" do
    sign_in_as(@owner)
    post preview_webinar_announcements_path(@webinar),
         params: { announcement: { audience: "webinar_registrants", subject: "", body: "" } }

    assert_response :unprocessable_entity
    assert_select "[data-role=announcement-form]"
  end

  test "envoi : exige la case cochée" do
    sign_in_as(@owner)
    confirm(confirmed: "0")

    assert_response :unprocessable_entity
    assert_equal 0, Announcement.count
    assert_empty enqueued_jobs
  end

  test "envoi : nombre changé depuis l'aperçu → nouvel aperçu avec le nouveau nombre" do
    sign_in_as(@owner)
    confirmed_registration(@webinar, "carol@example.test")
    confirm(count: 2)

    assert_response :unprocessable_entity
    assert_select "[data-role=recipients-count]", text: /3 destinataires/
    assert_select "input[name=expected_count][value='3']"
    assert_empty enqueued_jobs
  end

  test "envoi confirmé : journal, mails en file, double clic sans second envoi" do
    sign_in_as(@owner)
    confirm
    assert_redirected_to webinar_announcements_path(@webinar)
    assert_equal 2, recipient_jobs

    announcement = Announcement.sole
    assert_equal [ "webinar_registrants", "Infos du jour", "RDV salle 2.", @owner.oidc_sub, @owner.email, "owner", 2 ],
                 [ announcement.audience, announcement.subject, announcement.body, announcement.author_sub,
                   announcement.author_email, announcement.author_role, announcement.recipients_count ]

    clear_enqueued_jobs
    confirm
    assert_redirected_to webinar_announcements_path(@webinar)
    assert_equal 1, Announcement.count
    assert_equal 0, recipient_jobs
  end

  test "double clic simultané : la seconde confirmation dit « déjà parti », pas d'erreur 500" do
    sign_in_as(@owner)
    confirm(token: "tok-course")
    clear_enqueued_jobs
    Announcement.singleton_class.define_method(:exists?) { |*| false }

    confirm(token: "tok-course")

    assert_redirected_to webinar_announcements_path(@webinar)
    assert_equal "Cet envoi est déjà parti.", flash[:notice]
    assert_equal 1, Announcement.count
    assert_equal 0, recipient_jobs
  ensure
    Announcement.singleton_class.remove_method(:exists?)
  end

  test "co-animateur : envoie aux inscrits de son webinaire, le propriétaire est avisé" do
    sign_in_as(@guest)
    confirm

    assert_equal 2, recipient_jobs
    announcement = Announcement.sole
    assert_equal [ @guest.email, "guest_host" ], [ announcement.author_email, announcement.author_role ]
    assert enqueued_jobs.any? { |job| job["arguments"].first(2) == %w[AnnouncementNoticeMailer guest_sent] }
  end

  test "journal : listes visibles aux seuls animateurs du projet ; adresses masquées au co-animateur" do
    sign_in_as(@project)
    confirm(audience: "marketing_list", count: 1, token: "tok-liste")
    confirm(token: "tok-inscrits")
    get webinar_announcements_path(@webinar)
    assert_select "[data-announcement-id]", 2
    assert_select "[data-role=journal-author]", text: @project.email

    sign_in_as(@owner)
    get webinar_announcements_path(@webinar)
    assert_select "[data-announcement-id]", 1

    sign_in_as(@guest)
    get webinar_announcements_path(@webinar)
    assert_select "[data-announcement-id]", 1
    assert_select "[data-role=journal-count]", text: "2 destinataires"
    assert_select "[data-role=journal-author]", text: "animateur du projet"
    assert_not_includes response.body, @project.email
  end

  test "journal : mails sans nouvelles signalés, « Reprendre » les relance sans doublon" do
    sign_in_as(@owner)
    confirm
    announcement = Announcement.sole
    silent = announcement.deliveries.order(:id).last
    silent.update_columns(scheduled_at: 1.hour.ago, sending_at: 1.hour.ago)
    get webinar_announcements_path(@webinar)
    assert_select "[data-role=journal-silent]", text: /1\s+sans nouvelles/
    assert_select "[data-role=announcement-resume]"
    clear_enqueued_jobs

    post resume_webinar_announcement_path(@webinar, announcement)
    assert_redirected_to webinar_announcements_path(@webinar)
    assert_equal 1, recipient_jobs
    post resume_webinar_announcement_path(@webinar, announcement)
    assert_equal 1, recipient_jobs
  end

  test "reprise d'un envoi aux listes : refusée au co-animateur et au propriétaire" do
    sign_in_as(@project)
    confirm(audience: "marketing_list", count: 1, token: "tok-liste")
    announcement = Announcement.sole

    [ @guest, @owner ].each do |user|
      sign_in_as(user)
      post resume_webinar_announcement_path(@webinar, announcement)
      assert_response :not_found
    end
  end
end
