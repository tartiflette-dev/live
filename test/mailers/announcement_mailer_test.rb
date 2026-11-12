require "test_helper"

# Mail d'un envoi groupé : texte de l'auteur + pied de la cible ; lien de
# retrait obligatoire pour la liste, lien d'arrêt pour les « préviens-moi »,
# aucun des deux dans le message aux inscrits ; exclusion à la remise.
class AnnouncementMailerTest < ActionMailer::TestCase
  include ActiveJob::TestHelper

  setup do
    @webinar = announcement_webinar
  end

  def dispatch(audience)
    build_announcement(@webinar, audience).tap { |announcement| announcement.dispatch!(announcement.recipients) }
  end

  # Mails aux destinataires seulement (les avis internes ont leur test).
  def deliver_all
    perform_enqueued_jobs
    ActionMailer::Base.deliveries.select { |mail| mail.subject == "Infos du jour" }
  end

  test "inscrits du webinaire : texte de l'auteur, lien d'accès personnel, AUCUN lien de retrait" do
    registration = confirmed_registration(@webinar, "ana@example.test")
    announcement = dispatch("webinar_registrants")

    mail = deliver_all.sole
    assert_equal [ "ana@example.test" ], mail.to
    assert_equal [ "owner@example.test" ], mail.reply_to
    assert_equal "Infos du jour", mail.subject
    text = mail.text_part.decoded
    assert_includes text, "RDV salle 2."
    assert_includes text, "/r/#{registration.token}"
    assert_includes text, "inscrit·e à « Café IA #9 »"
    assert_not_includes text, "/mc/withdraw"
    assert_not_includes mail.html_part.decoded, "/mc/withdraw"
    assert_nil mail["List-Unsubscribe"]
    assert announcement.deliveries.sole.delivered_at
  end

  test "inscrits d'un café dont le replay est publié : leur lien personnel ouvre le replay" do
    registration = confirmed_registration(@webinar, "ana@example.test")
    recording = @webinar.recordings.create!(kind: "composite", status: "done", path: "#{@webinar.slug}/c.mp4",
                                            started_at: 2.hours.ago, ended_at: 1.hour.ago)
    @webinar.create_replay!(recording: recording, published_at: Time.current)
    dispatch("webinar_registrants")

    text = deliver_all.sole.text_part.decoded
    assert_includes text, "/w/#{@webinar.slug}/replay?t=#{registration.token}"
    assert_not_includes text, "/r/#{registration.token}"
  end

  test "la liste : lien de retrait dans le texte, le HTML et l'en-tête List-Unsubscribe" do
    registration = consenting_registration(@webinar, "ana@example.test")
    dispatch("marketing_list")

    mail = deliver_all.sole
    url = "http://example.com/mc/withdraw?t=#{registration.marketing_withdrawal_token}"
    assert_includes mail.text_part.decoded, url
    assert_includes mail.html_part.decoded, "Je retire mon accord"
    assert_equal "<#{url}>", mail["List-Unsubscribe"].value
    assert_not_includes mail.text_part.decoded, "/r/#{registration.token}"
  end

  test "la liste : un retrait entre la confirmation et la remise exclut la personne" do
    consenting_registration(@webinar, "ana@example.test")
    consenting_registration(@webinar, "bob@example.test")
    announcement = dispatch("marketing_list")

    Registration.withdraw_marketing_consent_of("ana@example.test")

    assert_equal [ [ "bob@example.test" ] ], deliver_all.map(&:to)
    assert_equal 1, announcement.deliveries.skipped.count
    assert_equal 1, announcement.deliveries.delivered.count
  end

  test "fiche effacée ou devenue pierre tombale avant la remise : rien ne part" do
    confirmed_registration(@webinar, "ana@example.test")
    tomb = confirmed_registration(@webinar, "bob@example.test")
    announcement = dispatch("webinar_registrants")

    CrmErasure.erase!("ana@example.test")
    tomb.update_columns(email: "retire-x@retire.invalid")

    assert_empty deliver_all
    assert_equal 1, announcement.deliveries.count, "crm:erase supprime le marqueur de la personne"
    assert_equal 1, announcement.deliveries.skipped.count
  end

  test "préviens-moi : tonalité Café IA, lien d'arrêt dans le texte, le HTML et List-Unsubscribe" do
    request = confirmed_request("ana@example.test", notify_next: true)
    dispatch("notify_next")

    mail = deliver_all.sole
    text = mail.text_part.decoded
    assert_includes text, "tu as demandé à être prévenu·e du prochain Café IA"
    url = text[%r{http://example\.com/prochain/stop\?t=\S+}]
    assert url, "lien d'arrêt absent du texte"
    token = Rack::Utils.parse_query(URI(url).query).fetch("t")
    assert_equal request, RegistrationRequest.find_by_token_for(:notify_next_stop, token)
    assert_includes mail.html_part.decoded, "Ne plus être prévenu·e"
    assert_equal "<#{url}>", mail["List-Unsubscribe"].value
    assert_not_includes text, "/mc/withdraw"
  end

  test "préviens-moi : un arrêt entre la confirmation et la remise exclut la personne" do
    confirmed_request("ana@example.test", notify_next: true)
    confirmed_request("bob@example.test", notify_next: true)
    announcement = dispatch("notify_next")

    RegistrationRequest.stop_notify_next_of("ana@example.test")

    assert_equal [ [ "bob@example.test" ] ], deliver_all.map(&:to)
    assert_equal 1, announcement.deliveries.skipped.count
  end

  test "HTML : le texte de l'auteur est échappé, jamais interprété" do
    confirmed_registration(@webinar, "ana@example.test")
    announcement = build_announcement(@webinar, "webinar_registrants")
    announcement.body = "<script>alert(1)</script>\nSalut"
    announcement.dispatch!(announcement.recipients)

    html = deliver_all.sole.html_part.decoded
    assert_includes html, "&lt;script&gt;"
    assert_not_includes html, "<script>"
  end

  test "tonalité par défaut (bootcamp) : vouvoiement" do
    @webinar.update!(kind: "bootcamp")
    confirmed_registration(@webinar, "ana@example.test")
    dispatch("webinar_registrants")

    assert_includes deliver_all.sole.text_part.decoded, "Vous recevez ce message en tant qu'inscrit·e"
  end
  test "job rejoué (redémarrage, relance manuelle) : même marqueur remis deux fois → un seul mail" do
    confirmed_registration(@webinar, "ana@example.test")
    announcement = dispatch("webinar_registrants")
    delivery = announcement.deliveries.sole

    assert_equal 1, deliver_all.size
    AnnouncementMailer.announcement(delivery.reload).deliver_now
    AnnouncementMailer.announcement(delivery.reload).deliver_now

    assert_equal 1, ActionMailer::Base.deliveries.count { |mail| mail.subject == "Infos du jour" }
    assert delivery.reload.delivered_at
  end

  test "deux jobs du même marqueur avant toute remise : un seul prend la remise" do
    confirmed_registration(@webinar, "ana@example.test")
    announcement = dispatch("webinar_registrants")
    delivery = announcement.deliveries.sole
    clear_enqueued_jobs

    2.times { AnnouncementMailer.announcement(AnnouncementDelivery.find(delivery.id)).deliver_now }

    assert_equal 1, ActionMailer::Base.deliveries.count { |mail| mail.subject == "Infos du jour" }
  end

  test "envoi d'un co-animateur : réponses au propriétaire, jamais au co-animateur" do
    User.create!(email: "proprio@example.test", oidc_sub: @webinar.host_sub)
    confirmed_registration(@webinar, "ana@example.test")
    announcement = build_announcement(@webinar, "webinar_registrants", author: "co@example.test", author_sub: "sub-co",
                                                                       author_role: "guest_host")
    announcement.dispatch!(announcement.recipients)

    assert_equal [ "proprio@example.test" ], deliver_all.sole.reply_to
  end
end
