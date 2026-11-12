require "test_helper"

class TokenPathMaskTest < ActiveSupport::TestCase
  test "le segment du jeton est masqué, quelle que soit la suite du chemin" do
    {
      "/r/SECRET" => "/r/[FILTERED]",
      "/r/SECRET/" => "/r/[FILTERED]",
      "/r/SECRET/autre" => "/r/[FILTERED]/autre",
      "/r/SECRET/autre/encore" => "/r/[FILTERED]/autre/encore",
      "/r/SECRET?locale=fr" => "/r/[FILTERED]?locale=fr",
      "/r/SECRET#frag" => "/r/[FILTERED]#frag"
    }.each { |path, masked| assert_equal masked, TokenPathMask.mask(path), path }
  end

  # Le routeur normalise les slashs : ces formes atteignent /r/:token.
  test "slashs répétés : le masque s'applique à la forme normalisée, comme le routeur" do
    {
      "//r/SECRET" => "/r/[FILTERED]",
      "/r//SECRET" => "/r/[FILTERED]",
      "///r/SECRET/x" => "/r/[FILTERED]/x",
      "/r//SECRET//x?a=1" => "/r/[FILTERED]/x?a=1",
      "//r///SECRET/" => "/r/[FILTERED]"
    }.each { |path, masked| assert_equal masked, TokenPathMask.mask(path), path }
  end

  test "casse : /R/ est masqué par prudence, bien que le routeur ne le route pas" do
    assert_equal "/R/[FILTERED]", TokenPathMask.mask("/R/SECRET")
    assert_raises(ActionController::RoutingError) { Rails.application.routes.recognize_path("/R/SECRET", method: :get) }
  end

  test "Journey normalize_path rend la forme que la route reconnaît, avec le même jeton" do
    %w[//r/SECRET /r//SECRET ///r/SECRET/ /r//SECRET//].each do |path|
      normalized = ActionDispatch::Journey::Router::Utils.normalize_path(path)
      assert_equal "/r/SECRET", normalized, path
      assert_equal "SECRET", Rails.application.routes.recognize_path(path, method: :get)[:token], "la route reconnaît #{path}"
    end
  end

  test "chaque préfixe porteur de jeton est masqué" do
    TokenPathMask::PREFIXES.each do |prefix|
      assert_equal "#{prefix}/[FILTERED]/suite", TokenPathMask.mask("#{prefix}/SECRET/suite")
    end
  end

  test "les chemins sans jeton et les préfixes voisins sont inchangés" do
    %w[/ /w/cafe /w/cafe/join /rattacher /r /r/ /recordings/SECRET /i /mc/withdraw //w/cafe /w//cafe/].each do |path|
      assert_equal path, TokenPathMask.mask(path)
    end
  end

  test "nil et chaîne vide ne lèvent pas" do
    assert_equal "", TokenPathMask.mask(nil)
    assert_equal "", TokenPathMask.mask("")
  end

  # Garde d'inventaire : une route qui porte un jeton dans son chemin doit
  # avoir son préfixe dans TokenPathMask::PREFIXES.
  test "toute route à segment de jeton dans le chemin est couverte" do
    uncovered = Rails.application.routes.routes.filter_map do |route|
      spec = route.path.spec.to_s.sub("(.:format)", "")
      next unless spec.match?(/:(token|t|share_token|link_token|speaker_token)\b/)

      spec unless TokenPathMask.mask(spec.gsub(/:[a-z_]+/, "SECRET")).include?(TokenPathMask::PLACEHOLDER)
    end
    assert_empty uncovered, "routes à jeton en chemin sans masque : #{uncovered.uniq.join(', ')}"
  end

  test "les liens à jeton en query ne portent pas le jeton dans le chemin" do
    %w[/i /a /mc /mc/withdraw /rattacher /confirmer].each do |path|
      assert Rails.application.routes.recognize_path(path, method: :get), path
    end
  end
end
