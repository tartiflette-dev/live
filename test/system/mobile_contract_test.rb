require "application_system_test_case"
# Thème undust seulement : la gem undust-charte fournit le contrat testé ;
# sous un autre thème, les tests sont sautés (comptés), pas retirés.
require "undust/charte/testing/mobile_contract" if Theme.undust?

class MobileContractTest < ApplicationSystemTestCase
  setup { require_undust_theme! }
  include Undust::Charte::Testing::MobileContract if Theme.undust?

  # Pilote de la gem, déclaré sous le thème undust seulement : le pilote est
  # instancié même pour un test sauté.
  if Theme.undust?
    driven_by :selenium, using: :headless_chrome, screen_size: [ 412, 915 ], options: { name: :undust_charte_mobile } do |options|
      Undust::Charte::Testing::MobileContract.configure_chrome(options)
    end
  end

  test "product pages preserve their mobile contract in real locales and themes" do
    Webinar.create!(title: "Café IA — test mobile", starts_at: 3.days.from_now,
      host_sub: "mobile-contract-synthetic", visibility: "published", kind: "cafe_ia", price_cents: 0)
    each_undust_mobile_viewport do |locale, theme, width, height|
      [ root_path(locale: locale) ].each do |route|
        visit route
        assert_selector "html[lang='#{locale}']"
        assert_selector "main"
        page.execute_script("document.documentElement.setAttribute('data-theme', arguments[0]); document.documentElement.classList.toggle('dark', arguments[0] === 'dark')", theme)
        assert_selector "html[data-theme='#{theme}']"
        begin
          assert_undust_mobile
        rescue Minitest::Assertion
          page.save_screenshot(Rails.root.join("tmp/mobile-contract-#{locale}-#{theme}-#{width}x#{height}.png"))
          raise
        end
      end
    end
  end
end
