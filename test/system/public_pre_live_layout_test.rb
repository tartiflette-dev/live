require "application_system_test_case"

# Cas réel : sur la page publique d'un café, les boutons radio
# « Tu viens comment ? » et la case de consentement étaient centrés seuls
# sur leur ligne, au-dessus de leur libellé (pleine largeur héritée des
# champs de saisie), et la carte restait à 420px dans une page de 1400px.
class PublicPreLiveLayoutTest < JsSystemTestCase
  setup do
    require_undust_theme!
    @privacy_url = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/privacy"
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.day.from_now,
      host_sub: "host", visibility: "published", kind: "cafe_ia")
  end

  teardown do
    ENV["REGISTRATION_PRIVACY_URL"] = @privacy_url
  end

  test "radios et case de consentement à gauche de leur libellé, carte à la largeur de lecture" do
    visit public_webinar_path(@webinar.slug)
    assert_selector "[data-role=registration-participation]"

    boites = page.evaluate_script(<<~JS)
      (() => {
        const r = (sel) => document.querySelector(sel).getBoundingClientRect();
        const box = (b) => ({ left: b.left, right: b.right, top: b.top, bottom: b.bottom, width: b.width });
        return {
          radio: box(r("#registration_participation_spectator")),
          radioLabel: box(r("label[for=registration_participation_spectator] > span")),
          check: box(r("#registration_marketing_consent")),
          checkLabel: box(r("label[for=registration_marketing_consent] > span")),
          carte: box(r("[data-role=pre-live]")),
        };
      })()
    JS

    [ %w[radio radioLabel], %w[check checkLabel] ].each do |input, label|
      i = boites[input]
      l = boites[label]
      assert_operator i["width"], :<, 40, "#{input} ne doit pas prendre toute la largeur"
      assert_operator i["right"], :<=, l["left"], "#{input} à gauche de son libellé"
      assert_operator i["top"], :<, l["bottom"], "#{input} sur la même ligne que son libellé"
    end
    assert_operator boites["carte"]["width"], :>, 600, "la carte n'est plus bloquée à 420px"
  end
end
