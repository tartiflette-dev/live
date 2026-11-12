require "test_helper"

# Nouvelle date (événement joint, même UID, SEQUENCE croissante) et
# annulation, dans la tonalité de l'émission.
class WebinarChangeMailerTest < ActionMailer::TestCase
  PARIS = Time.find_zone("Europe/Paris")

  setup do
    travel_to PARIS.parse("2026-11-02 10:00")
    @cafe = Webinar.create!(title: "Café IA #9", kind: "cafe_ia", starts_at: PARIS.parse("2026-11-10 09:30"),
                            host_sub: "host", visibility: "published")
    @registration = @cafe.registrations.create!(name: "Bob", email: "bob@example.test")
    @registration.confirm!
  end

  def bodies(mail)
    [ mail.html_part.body.to_s, mail.text_part.body.to_s ]
  end

  test "nouvelle date d'un Café IA : tutoiement, nouvelle date, lien d'accès, .ics même UID et SEQUENCE plus haute" do
    sequence_before = (@cafe.updated_at - @cafe.created_at).to_i
    travel 1.hour
    @cafe.update!(starts_at: PARIS.parse("2026-11-12 09:30"))

    mail = WebinarChangeMailer.rescheduled(@registration.reload)

    assert_equal [ "bob@example.test" ], mail.to
    assert_equal "Nouvelle date pour le café : Café IA #9", mail.subject
    bodies(mail).each do |body|
      assert_match(/Salut Bob/, body)
      assert_match(/aura lieu\s+jeudi 12 novembre à 9 h 30 \(heure de Paris\)/, body)
      assert_match(%r{http://example\.com/r/#{Regexp.escape(@registration.token)}}, body)
      assert_no_match(%r{/mc}, body)
      assert_no_match(/\b(vous|votre|vos)\b/i, body)
    end
    ics = mail.attachments.find { |attachment| attachment.filename == "#{@cafe.slug}.ics" }
    event = Icalendar::Parser.new(ics.body.to_s, true).parse.sole.events.sole
    assert_equal "#{@cafe.slug}@#{WebinarCalendar::UID_DOMAIN}", event.uid.to_s
    assert_equal Time.utc(2026, 11, 12, 8, 30), event.dtstart.to_time.utc
    assert_operator event.sequence.to_i, :>, sequence_before
  end

  test "nouvelle date d'un bootcamp : tonalité par défaut" do
    bootcamp = Webinar.create!(title: "Bootcamp #1", kind: "bootcamp", starts_at: PARIS.parse("2026-11-20 09:30"),
                               host_sub: "host", visibility: "published")
    registration = bootcamp.registrations.create!(name: "Bob", email: "bob@example.test")

    mail = WebinarChangeMailer.rescheduled(registration)

    assert_equal "Changement de date — Bootcamp #1", mail.subject
    bodies(mail).each do |body|
      assert_match(/Bonjour Bob/, body)
      assert_match(/aura lieu\s+le vendredi 20 novembre 2026 09h30 \(heure de Paris\)/, body)
    end
  end

  test "annulation d'un Café IA : la date annoncée, sans pièce jointe ni lien d'accès" do
    announced = @cafe.starts_at
    @cafe.update!(visibility: "draft", starts_at: PARIS.parse("2026-11-17 09:30"))

    mail = WebinarChangeMailer.cancelled(@registration, starts_at: announced)

    assert_equal "Café annulé : Café IA #9", mail.subject
    assert_empty mail.attachments
    bodies(mail).each do |body|
      assert_match(/prévu\s+mardi 10 novembre à 9 h 30 \(heure de Paris\), est annulé/, body)
      assert_match(%r{http://example\.com/agenda}, body, "sans site de série : l'agenda de l'instance")
      assert_match(/Le Café IA · example\.com/, body)
      assert_no_match(%r{/r/}, body)
      assert_no_match(/\b(vous|votre|vos)\b/i, body)
    end
  end

  test "Café IA d'une série qui a son site : le mail y renvoie et le signe de son hôte" do
    mail = with_brand("BRAND_SERIES_URL" => "https://serie.example.org") do
      WebinarChangeMailer.cancelled(@registration, starts_at: @cafe.starts_at).tap(&:body)
    end

    assert_includes mail.html_part.body.to_s, %(Les prochains cafés sont sur <a href="https://serie.example.org">serie.example.org</a>.)
    assert_includes mail.text_part.body.to_s, "Les prochains cafés sont sur https://serie.example.org"
    bodies(mail).each { |body| assert_match(/— Le Café IA · serie\.example\.org/, body) }
  end

  test "annulation d'un bootcamp : tonalité par défaut, renvoi vers l'agenda" do
    bootcamp = Webinar.create!(title: "Bootcamp #1", kind: "bootcamp", starts_at: PARIS.parse("2026-11-20 09:30"),
                               host_sub: "host", visibility: "draft")
    registration = bootcamp.registrations.create!(name: "Bob", email: "bob@example.test")

    mail = WebinarChangeMailer.cancelled(registration, starts_at: bootcamp.starts_at)

    assert_equal "Annulation — Bootcamp #1", mail.subject
    assert_includes mail.text_part.body.to_s, "http://example.com/agenda"
  end
end
