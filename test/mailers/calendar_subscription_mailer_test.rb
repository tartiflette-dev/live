require "test_helper"

# « Ajoute le Café IA à ton agenda » : toutes les portes d'entrée visent le
# flux personnel, restreint à l'émission de la tonalité.
class CalendarSubscriptionMailerTest < ActionMailer::TestCase
  setup do
    @subscription = CalendarSubscription.create!(email: "alice@example.test")
    @feed = "http://example.com/agenda/#{@subscription.token}.ics"
  end

  def bodies(mail)
    [ mail.html_part.body.to_s, mail.text_part.body.to_s ]
  end

  test "Café IA : tutoiement, liens webcal, Google, Outlook et téléchargement vers le flux personnel du Café IA" do
    mail = CalendarSubscriptionMailer.feed_link(@subscription, name: "Alice", voice: "cafe_ia")
    feed = "#{@feed}?kind=cafe_ia"
    webcal = feed.sub("http://", "webcal://")

    assert_equal [ "alice@example.test" ], mail.to
    assert_equal "Ajoute le Café IA à ton agenda", mail.subject
    html = mail.html_part.body.to_s
    assert_includes html, %(href="#{CGI.escapeHTML(webcal)}")
    assert_includes html, CGI.escapeHTML("https://calendar.google.com/calendar/r?cid=#{CGI.escape(webcal)}")
    assert_includes html, CGI.escapeHTML("https://outlook.office.com/calendar/0/addfromweb?" \
                                         "#{{ name: WebinarCalendar.feed_name("cafe_ia"), url: feed }.to_query}")
    assert_includes html, "https://outlook.live.com/calendar/0/addfromweb?"
    assert_includes html, %(href="#{CGI.escapeHTML(feed)}")
    bodies(mail).each do |body|
      assert_match(/Salut Alice/, body)
      assert_match(/Ce lien est à toi : ne le fais pas tourner/, body)
      assert_match(/parce que tu as confirmé ton inscription/, body)
      assert_no_match(%r{/agenda\.ics}, body, "jamais l'ancien flux public")
      assert_no_match(%r{/mc}, body, "ce n'est pas de la prospection")
      assert_no_match(/\b(vous|votre|vos)\b/i, body)
    end
  end

  test "tonalité par défaut : vouvoiement, flux complet sans filtre" do
    mail = CalendarSubscriptionMailer.feed_link(@subscription, name: "Alice", voice: Voice::DEFAULT)

    assert_equal "Votre lien d'agenda personnel", mail.subject
    bodies(mail).each do |body|
      assert_match(/Bonjour Alice/, body)
      assert_match(/Ce lien vous est propre/, body)
      assert_includes body, @feed
      assert_no_match(/kind=/, body)
    end
  end

  test "bootcamp : tonalité par défaut, flux restreint aux bootcamps" do
    mail = CalendarSubscriptionMailer.feed_link(@subscription, name: "Alice", voice: "bootcamp")

    assert_equal "Votre lien d'agenda personnel", mail.subject
    assert_includes mail.text_part.body.to_s, "#{@feed}?kind=bootcamp"
  end
end
