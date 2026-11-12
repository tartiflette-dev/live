require "test_helper"

# Alertes à l'équipe sur une transcription interrompue en plein direct : une
# à l'entrée (quoi vérifier), une à la sortie (l'intervalle perdu).
class TranscriptionOutageMailerTest < ActionMailer::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-marc",
                               state: "live", started_at: 1.hour.ago)
  end

  test "interruption : à l'équipe, heure de Paris en H:MM, conduite à tenir et lien de la régie" do
    mail = TranscriptionOutageMailer.interrupted(@webinar, absent_since: Time.zone.parse("2026-11-10 09:31"))

    assert_equal [ "contact@example.test" ], mail.to
    assert_equal "Café IA #9 — transcription en direct interrompue depuis environ 9:31", mail.subject
    text = mail.text_part.body.to_s
    assert_includes text, "depuis environ 9:31 (heure de Paris), alors que des personnes y sont"
    assert_includes text, "sous le nom « transcriber » attendu par l'application"
    assert_includes text, "http://example.com/webinars/#{@webinar.to_param}/regie"
    assert_includes mail.html_part.body.to_s, "depuis environ 9:31"
  end

  test "transcripteur revenu : rétablie, avec l'intervalle absent du transcript" do
    mail = TranscriptionOutageMailer.ended(@webinar, absent_since: Time.zone.parse("2026-11-10 09:31"),
                                                     ended_at: Time.zone.parse("2026-11-10 14:02"), reason: "restored")

    assert_equal "Café IA #9 — transcription en direct rétablie à 14:02", mail.subject
    text = mail.text_part.body.to_s
    assert_includes text, "revenu dans la salle du direct « Café IA #9 » à 14:02"
    assert_includes text, "Ce qui s'est dit d'environ 9:31 à 14:02 n'est pas dans le transcript."
  end

  test "captation arrêtée sans retour du transcripteur : dit tel quel" do
    mail = TranscriptionOutageMailer.ended(@webinar, absent_since: Time.zone.parse("2026-11-10 09:31"),
                                                     ended_at: Time.zone.parse("2026-11-10 10:30"), reason: "capture_closed")

    assert_equal "Café IA #9 — captation arrêtée sans transcription depuis environ 9:31", mail.subject
    assert_includes mail.text_part.body.to_s, "s'est arrêtée à 10:30 (heure de Paris), le plus souvent à la fin du direct"
    assert_includes mail.html_part.body.to_s, "le plus souvent à la fin du direct"
  end
end
