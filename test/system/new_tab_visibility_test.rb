require "application_system_test_case"

# « (nouvel onglet) » masqué à l'écran, dans le thème courant. Les deux
# thèmes doivent le cacher : undust via la gem, tartiflette via
# theme_default.css. Relancer après `bin/rails tailwindcss:build` dans
# chaque thème (BRAND_THEME=tartiflette puis undust).
class NewTabVisibilityTest < JsSystemTestCase
  test "« (nouvel onglet) » n'est pas visible à l'écran (thème #{Theme.selected})" do
    webinar = Webinar.create!(title: "Café visibilité", starts_at: 2.hours.from_now,
                              host_sub: "sub-vis-#{SecureRandom.hex(4)}", visibility: "published")
    visit public_webinar_path(webinar.slug)

    assert_selector "[data-role='add-to-calendar-google'] .visually-hidden",
                    text: "(nouvel onglet)", visible: :all
    box = evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-role='add-to-calendar-google'] .visually-hidden");
        const s = getComputedStyle(el);
        const r = el.getBoundingClientRect();
        return { clip: s.clip, position: s.position, width: r.width, height: r.height };
      })()
    JS
    assert_equal "absolute", box["position"], "thème #{Theme.selected} : position"
    assert_match(/rect\(\s*0/, box["clip"].to_s, "thème #{Theme.selected} : clip #{box["clip"].inspect}")
    assert_operator box["width"], :<=, 1, "thème #{Theme.selected} : largeur #{box["width"]}"
    assert_operator box["height"], :<=, 1, "thème #{Theme.selected} : hauteur #{box["height"]}"
  end
end
