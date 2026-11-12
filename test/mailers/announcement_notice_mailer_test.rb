require "test_helper"

# Avis internes : tout envoi aux listes aux animateurs du projet, tout envoi
# d'un co-animateur au propriétaire du webinaire.
class AnnouncementNoticeMailerTest < ActionMailer::TestCase
  setup do
    @owner = User.create!(email: "proprio@example.test", oidc_sub: "sub-owner")
    @webinar = announcement_webinar(host_sub: @owner.oidc_sub)
  end

  def announcement(audience, **author)
    build_announcement(@webinar, audience, **author).tap do |record|
      record.recipients_count = 42
      record.save!
    end
  end

  test "envoi aux listes : aux animateurs du projet, objet, auteur, nombre, lien vers le journal" do
    project_host_user("projet@example.test")
    project_host_user("autre-projet@example.test", sub: "sub-autre")
    mail = AnnouncementNoticeMailer.list_sent(announcement("marketing_list", author: "projet@example.test",
                                                                             author_role: "project_host"))

    assert_equal %w[autre-projet@example.test projet@example.test], mail.to.sort
    assert_equal "Envoi à une liste : Infos du jour", mail.subject
    body = mail.body.decoded
    assert_includes body, "projet@example.test vient d'envoyer"
    assert_includes body, "Destinataires : 42"
    assert_includes body, "/webinars/#{@webinar.slug}/announcements"
  end

  test "sans animateur du projet connu : l'adresse de contact de la marque" do
    mail = AnnouncementNoticeMailer.list_sent(announcement("notify_next", author_role: "project_host"))

    assert_equal [ Brand.support_email ], mail.to
  end

  test "envoi d'un co-animateur : au propriétaire du webinaire" do
    mail = AnnouncementNoticeMailer.guest_sent(announcement("webinar_registrants", author: "co@example.test",
                                                                                   author_role: "guest_host"))

    assert_equal [ "proprio@example.test" ], mail.to
    assert_includes mail.subject, "message d'un co-animateur aux inscrits"
    assert_includes mail.body.decoded, "co@example.test vient d'envoyer"
  end
end
