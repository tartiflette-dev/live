require "test_helper"

# CSP avec nonce, EN MODE BLOQUANT depuis le 11/11/2026. Ce test fige le
# contrat : en-tête bloquant posé, jamais d'en-tête Report-Only, rapport des
# violations conservé (config/initializers/content_security_policy.rb).
class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  setup do
    @webinar = Webinar.create!(title: "Café CSP", starts_at: 2.days.from_now, host_sub: "host", visibility: "published")
    @ip = { "REMOTE_ADDR" => "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1" }
  end

  test "la politique est posée en mode bloquant, plus en Report-Only" do
    get public_webinar_path(@webinar.slug), headers: @ip

    assert_response :success
    assert_predicate response.headers["Content-Security-Policy"], :present?
    assert_nil response.headers["Content-Security-Policy-Report-Only"], "l'observation est terminée"
  end

  test "directives : source de scripts, objets, cadres, base, rapports" do
    get public_webinar_path(@webinar.slug), headers: @ip
    policy = directives(response.headers["Content-Security-Policy"])

    assert_includes policy.fetch("default-src"), "'self'"
    assert_equal [ "'none'" ], policy.fetch("object-src")
    assert_equal [ "'none'" ], policy.fetch("frame-ancestors")
    assert_equal [ "'self'" ], policy.fetch("base-uri")
    assert_equal [ "/csp-reports" ], policy.fetch("report-uri")
    assert_includes policy.fetch("script-src"), "'self'"
    assert_not_includes policy.fetch("script-src"), "'unsafe-inline'"
    assert_not_includes policy.fetch("script-src"), "'unsafe-eval'"
    assert_includes policy.fetch("connect-src"), "'self'"
  end

  test "form-action porte l'émetteur OIDC effectif, même source qu'OmniAuth et HostInvitation" do
    get public_webinar_path(@webinar.slug), headers: @ip
    policy = directives(response.headers["Content-Security-Policy"])

    assert_equal [ "'self'", OidcProvider.issuer ], policy.fetch("form-action")
  end

  test "l'émetteur est lu au même endroit par la CSP, OmniAuth et HostInvitation" do
    previous = ENV["OIDC_ISSUER"]
    ENV["OIDC_ISSUER"] = "https://auth.example.test"
    assert_equal "auth.example.test", HostInvitation.new.send(:pocket_id_issuer).host
    ENV.delete("OIDC_ISSUER")
    assert_nil HostInvitation.new.send(:pocket_id_issuer)
  ensure
    ENV["OIDC_ISSUER"] = previous
  end

  test "un nonce de script, différent à chaque réponse" do
    get public_webinar_path(@webinar.slug), headers: @ip
    first = nonce_of(response.headers["Content-Security-Policy"])
    get public_webinar_path(@webinar.slug), headers: @ip
    second = nonce_of(response.headers["Content-Security-Policy"])

    assert_match(/\A[A-Za-z0-9+\/]{22}==\z/, first)
    assert_not_equal first, second
  end

  test "la méta csp_meta_tag expose le nonce de la page et les scripts de la page le portent" do
    get public_webinar_path(@webinar.slug), headers: @ip
    header_nonce = nonce_of(response.headers["Content-Security-Policy"])

    assert_select "meta[name=csp-nonce][content=?]", header_nonce
    assert_select "script[src]" do |scripts|
      assert scripts.all? { |script| script["nonce"] == header_nonce }, "les scripts du layout portent le nonce"
    end
  end

  # L'anti-FOUC passe par app/views/theme/_anti_fouc, pour la gem
  # undust-charte (script sans nonce) comme pour le chrome par défaut.
  test "tout script en ligne de la page porte le nonce de la réponse (anti-FOUC du thème compris)" do
    get public_webinar_path(@webinar.slug), headers: @ip
    nonce = nonce_of(response.headers["Content-Security-Policy"])

    inline = css_select("script:not([src])")
    assert_predicate inline, :any?, "l'anti-FOUC est un script en ligne"
    assert inline.all? { |script| script["nonce"] == nonce }, "scripts sans nonce : #{inline.reject { |s| s['nonce'] == nonce }.map(&:to_s)}"
    assert_match(/dataset\.theme|theme/, inline.first.text)
  end

  test "le nonce ne change pas le contenu du script anti-FOUC" do
    get public_webinar_path(@webinar.slug), headers: @ip
    body = css_select("script:not([src])").first.text.strip
    assert_not_includes body, "nonce"
    assert_predicate body, :present?
  end

  test "l'attribut style en ligne est la seule permission inline, réservée aux attributs" do
    get public_webinar_path(@webinar.slug), headers: @ip
    policy = directives(response.headers["Content-Security-Policy"])

    assert_equal [ "'self'" ], policy.fetch("style-src")
    assert_equal [ "'unsafe-inline'" ], policy.fetch("style-src-attr")
  end

  private

  def directives(header)
    header.split(";").map(&:strip).reject(&:empty?).to_h do |directive|
      name, *values = directive.split(/\s+/)
      [ name, values ]
    end
  end

  def nonce_of(header)
    directives(header).fetch("script-src").grep(/\A'nonce-/).first[/'nonce-(.*)'/, 1]
  end
end
