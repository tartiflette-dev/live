require "test_helper"

# ConsentMailer — l'animateur propriétaire apprend un retrait d'accord à
# l'image avec les échéances de dépublication, ou que la salle n'a pas
# retiré le droit de publier.
class ConsentMailerTest < ActionMailer::TestCase
  setup do
    @owner = User.create!(email: "marc@example.test", oidc_sub: "sub-marc")
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: @owner.oidc_sub, visibility: "published")
    @speaker = @webinar.speakers.create!(name: "Camille Martin")
  end

  test "retrait : au propriétaire, avec la personne, l'heure et les deux échéances (7 jours, 30 jours)" do
    consent = ParticipantConsent.grant!(@speaker, recording: true, excerpts: true, adult: true)
    consent.withdraw!(now: Time.zone.parse("2026-11-04 10:40"))

    mail = ConsentMailer.withdrawn(consent)

    assert_equal [ "marc@example.test" ], mail.to
    assert_equal "Café IA #9 — accord à l'image retiré : Camille Martin (speaker-#{@speaker.id})", mail.subject
    text = mail.text_part.body.to_s
    assert_includes text, "le 4 novembre 2026 à 10:40, depuis la salle."
    assert_includes text, "d'ici le 11 novembre 2026 : retirer les extraits et shorts"
    assert_includes text, "d'ici le 4 décembre 2026 : retirer ses passages du replay publié"
    assert_includes text, "http://example.com/webinars/#{@webinar.to_param}/recordings"
  end

  test "retrait : demander aux co-organisateurs de la série d'en faire autant, s'il y en a" do
    consent = ParticipantConsent.grant!(@speaker, recording: true, excerpts: true, adult: true)
    consent.withdraw!

    alone = ConsentMailer.withdrawn(consent)
    assert_includes alone.text_part.body.to_s, "où cette personne apparaît ;"
    assert_includes alone.html_part.body.to_s, "où cette personne apparaît ;</li>"

    shared = with_brand("BRAND_SERIES_CO_ORGANIZERS" => "Collectif Exemple") { ConsentMailer.withdrawn(consent).tap(&:body) }
    [ shared.text_part.body.to_s, shared.html_part.body.to_s ].each do |body|
      assert_match(/apparaît, et demander aux\s+co-organisateurs de la série \(Collectif Exemple\) d'en faire autant ;/, body)
    end
  end

  test "propriétaire sans compte : le mail part à contact@example.test" do
    @owner.destroy!
    consent = ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
    consent.withdraw!

    assert_equal [ "contact@example.test" ], ConsentMailer.withdrawn(consent).to
  end

  test "droit de publier non retiré sans accord : la conduite à tenir depuis la régie" do
    mail = ConsentMailer.revocation_failed(@webinar, @speaker)

    assert_equal [ "marc@example.test" ], mail.to
    text = mail.text_part.body.to_s
    assert_includes text, "Camille Martin (speaker-#{@speaker.id}) n'a pas (ou plus) d'accord à l'image"
    assert_includes text, "la retirer de la salle depuis la régie"
  end
end
