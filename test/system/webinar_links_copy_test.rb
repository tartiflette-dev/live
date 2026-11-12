require "application_system_test_case"

# Un animateur a partagé l'écran de la page animateur, les
# jetons des liens intervenants y étaient lisibles. Demande : « juste un
# bouton copier […] je n'avais pas forcément besoin de voir tout le jeton ».
# Les liens secrets s'affichent masqués et se copient par leur bouton.
class WebinarLinksCopyTest < JsSystemTestCase
  MASK = "••••••••".freeze

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @webinar = Webinar.create!(title: "Café IA #7", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    @share_token = @webinar.generate_share_token!
    @speaker = @webinar.speakers.create!(name: "Basile")
    sign_in_as(@host)
    visit webinar_path(@webinar)
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "la page ne montre aucun morceau d'un jeton secret" do
    shown = [ page.text, *all("input", visible: true).map(&:value), *all("[title]", visible: :all).map { |node| node[:title] } ]

    [ @share_token, @speaker.token ].each do |secret|
      secret.chars.each_cons(8).map(&:join).each do |fragment|
        assert shown.none? { |text| text.include?(fragment) }, "fragment de jeton visible : #{fragment}"
      end
    end
    assert_equal "#{server_authority}/i?t=#{MASK}", find("input[data-role='invitation-url']").value
    assert_no_selector "input[data-role='speaker-link']"
  end

  test "Copier le lien met l'URL complète dans le presse-papiers et l'annonce" do
    page.execute_script(<<~JS)
      window.copiedTexts = [];
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: (text) => { window.copiedTexts.push(text); return Promise.resolve(); } }
      });
    JS

    within("[data-speaker-id='#{@speaker.id}']") { click_on "Copier le lien" }
    within("[data-role='invitation-link']") { click_on "Copier le lien" }

    assert_selector "[data-speaker-id='#{@speaker.id}'] [role='status'].etat--succes", text: /lien copié/i
    assert_selector "[data-role='invitation-link'] [role='status'].etat--succes", text: /lien copié/i
    assert_equal [ "#{server_origin}/w/#{@webinar.slug}/join?t=#{@speaker.token}", "#{server_origin}/i?t=#{@share_token}" ],
                 evaluate_script("window.copiedTexts")
  end

  test "presse-papiers refusé : le repli hors écran copie l'URL complète puis disparaît" do
    page.execute_script(<<~JS)
      window.copiedTexts = [];
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: () => Promise.reject(new DOMException("refusé", "NotAllowedError")) }
      });
      document.execCommand = (command) => {
        window.copiedTexts.push([command, document.querySelector("body > textarea").value]);
        return true;
      };
    JS

    within("[data-speaker-id='#{@speaker.id}']") { click_on "Copier le lien" }

    assert_selector "[data-speaker-id='#{@speaker.id}'] [role='status']", text: /lien copié/i
    assert_equal [ [ "copy", "#{server_origin}/w/#{@webinar.slug}/join?t=#{@speaker.token}" ] ], evaluate_script("window.copiedTexts")
    assert_no_selector "textarea", visible: :all
  end

  test "aucune voie de copie : l'échec est annoncé, pas un faux succès" do
    page.execute_script(<<~JS)
      Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined });
      document.execCommand = () => false;
    JS

    within("[data-speaker-id='#{@speaker.id}']") { click_on "Copier le lien" }

    assert_selector "[data-speaker-id='#{@speaker.id}'] [role='status'].etat--ecart", text: /copie impossible/i
  end

  private

  def server_origin
    page.server.base_url
  end

  def server_authority
    server_origin.delete_prefix("http://")
  end

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id", uid: user.oidc_sub, info: { email: user.email }
    )
    visit "/auth/pocket_id/callback"
  end
end
