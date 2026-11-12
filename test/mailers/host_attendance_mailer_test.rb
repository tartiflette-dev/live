require "test_helper"

class HostAttendanceMailerTest < ActionMailer::TestCase
  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @webinar = Webinar.create!(title: "Café IA 12", starts_at: 10.days.from_now, host_sub: @owner.oidc_sub, visibility: "published")
    @host = @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    @attendance = HostAttendance.for!(@webinar, @host)
    @starts_at = I18n.l(@webinar.starts_at, format: :long)
  end

  test "demande : deux liens personnels vers une page sans effet, réponse au propriétaire" do
    mail = HostAttendanceMailer.presence_request(@attendance)

    assert_equal [ "jean@partenaire.example.org" ], mail.to
    assert_equal [ "owner@example.net" ], mail.reply_to
    assert_equal "Café IA 12 — seras-tu là le #{@starts_at} ?", mail.subject
    { mail.text_part => :itself.to_proc, mail.html_part => CGI.method(:escapeHTML) }.each do |part, escape|
      body = part.body.decoded
      assert_includes body, "Je serai là"
      assert_includes body, "Je ne serai pas là"
      assert_includes body, escape.call("http://example.com/presence?reponse=oui&t=#{@attendance.token}")
      assert_includes body, escape.call("http://example.com/presence?reponse=non&t=#{@attendance.token}")
      assert_includes body, "http://example.com/webinars/#{@webinar.slug}"
    end
  end

  test "relance : même liens, objet « Rappel »" do
    mail = HostAttendanceMailer.presence_reminder(@attendance)

    assert_equal "Rappel — Café IA 12 : seras-tu là le #{@starts_at} ?", mail.subject
    assert_includes mail.text_part.body.decoded, "pas encore dit si tu seras là"
    assert_includes mail.text_part.body.decoded, "t=#{@attendance.token}"
  end

  test "absence : au propriétaire, qui décide ; réponse vers le co-animateur, sans lien de réponse" do
    mail = HostAttendanceMailer.absence_notice(@attendance)

    assert_equal [ "owner@example.net" ], mail.to
    assert_equal [ "jean@partenaire.example.org" ], mail.reply_to
    assert_equal "Café IA 12 — jean@partenaire.example.org ne sera pas là le #{@starts_at}", mail.subject
    body = mail.text_part.body.decoded
    assert_includes body, "à toi de décider"
    assert_includes body, "« à confirmer »"
    assert_not_includes body, @attendance.token
  end

  test "propriétaire introuvable : pas d'avis d'absence" do
    @owner.destroy!

    assert_emails(0) { HostAttendanceMailer.absence_notice(@attendance).deliver_now }
  end
end
