# frozen_string_literal: true

require "test_helper"

class ThemeTest < ActiveSupport::TestCase
  setup { @root = Pathname(Dir.mktmpdir("pack")) }
  teardown { FileUtils.rm_rf(@root) }

  test "BRAND_THEME absent ou vide : undust si la gem est dans le bundle, tartiflette sinon" do
    with_gem = { Theme::UNDUST_GEM => Gem::Specification.new }

    assert_equal [ "undust", "undust", "tartiflette" ], [ nil, "  ", "tartiflette" ].map { |value| Theme.name_from(value, with_gem) }
    assert_equal [ "tartiflette", "tartiflette" ], [ nil, "  " ].map { |value| Theme.name_from(value, {}) }
  end

  test "BRAND_THEME=undust sans la gem : refus au boot qui nomme la gem" do
    error = assert_raises(ArgumentError) { Theme.name_from("undust", {}) }

    assert_match Theme::UNDUST_GEM, error.message
  end

  test "BRAND_THEME : nom simple seulement, ni chemin ni remontée" do
    [ "/tmp/x", "../config", "themes/x", "Tartiflette", "-x", "a b", "x." ].each do |value|
      error = assert_raises(ArgumentError, value) { Theme.name_from(value) }
      assert_match "nom de thème attendu", error.message
    end
  end

  test "le thème est figé au démarrage" do
    selected = Theme.selected
    previous = ENV["BRAND_THEME"]
    ENV["BRAND_THEME"] = selected == "undust" ? "tartiflette" : "undust"

    assert_equal selected, Theme.selected
  ensure
    previous.nil? ? ENV.delete("BRAND_THEME") : ENV["BRAND_THEME"] = previous
  end

  test "un pack sans theme.yml est refusé au boot, avec le chemin attendu" do
    error = assert_raises(ArgumentError) { Theme::Pack.new(@root.join("absent")) }

    assert_match "BRAND_THEME=absent", error.message
    assert_match "theme.yml", error.message
  end

  test "pack : identité du theme.yml, favicon et mode par défaut" do
    pack = write_pack("product_name: Prod\ncredit: { label: Par Org, url: https://org.example }\ntheme_color: \"#000\"\n")

    assert_equal({ favicon: Theme::Pack::NEUTRAL_FAVICON, product_name: "Prod",
                   credit: { label: "Par Org", url: "https://org.example" } }, pack.brand)
    assert_equal [ "#000", "light" ], [ pack.theme_color, pack.default_mode ]
  end

  test "pack : URL de crédit ou de lien hors http(s) refusée" do
    pack = write_pack("credit: { label: X, url: \"javascript:alert(1)\" }\nlinks: { site: \"https://ok.example\", git: \"data:x\" }\ntheme_color: \"#000\"\n")

    error = assert_raises(ArgumentError) { pack.brand }
    assert_match "javascript:alert(1), data:x", error.message
  end

  test "pack : feuille d'entrée Tailwind, chrome.css seulement s'il existe" do
    pack = write_pack("theme_color: \"#000\"\n")
    @root.join("pack/tokens.css").write("")
    assert_equal %(@import "../../../themes/pack/tokens.css";\n@import "./theme_default.css";\n), pack.stylesheet

    @root.join("pack/chrome.css").write("")
    assert_match %(@import "../../../themes/pack/chrome.css";), pack.stylesheet
  end

  test "pack sans tokens.css, logo ni favicon : substituts neutres de l'app" do
    pack = write_pack("theme_color: \"#000\"\n")

    assert_equal %(@import "../../../themes/neutre_tokens.css";\n@import "./theme_default.css";\n), pack.stylesheet
    assert_equal Theme::Pack::NEUTRAL_FAVICON, pack.brand.fetch(:favicon)
    assert_match %r{\A<svg class="m" aria-hidden="true"}, pack.monogramme(nil, classe: "m")
    assert Rails.application.assets.load_path.find(Theme::Pack::NEUTRAL_FAVICON), "favicon neutre non servi"
    assert Theme.root.join("neutre_tokens.css").file?
  end

  test "pack avec favicon : le sien, pas le neutre" do
    pack = write_pack("theme_color: \"#000\"\n")
    @root.join("pack/assets").mkpath
    @root.join("pack/assets/favicon.svg").write("<svg/>")

    assert_equal "favicon.svg", pack.brand.fetch(:favicon)
  end

  test "pack : le logo en ligne est décoratif, classe échappée, attributs d'accessibilité remplacés" do
    pack = write_pack("theme_color: \"#000\"\n")
    @root.join("pack/assets").mkpath
    @root.join("pack/assets/logo.svg").write(%(<svg viewBox="0 0 1 1" role="img" aria-label="Org"><title>Org</title><path/></svg>))

    assert_equal %(<svg class="a&quot;b" aria-hidden="true" focusable="false" viewBox="0 0 1 1"><path/></svg>),
                 pack.monogramme(nil, classe: %(a"b))
  end

  test "pack : seuls les fichiers de assets/ sont publiés" do
    pack = write_pack("theme_color: \"#000\"\n")
    { "tokens.css" => "", "chrome.css" => "", "README.md" => "", "preview/x.png" => "",
      "assets/logo.svg" => "<svg/>", "assets/fonts/f.woff2" => "" }.each do |file, body|
      @root.join("pack", file).dirname.mkpath
      @root.join("pack", file).write(body)
    end

    assert_equal %w[fonts/f.woff2 logo.svg], published(pack)
  end

  test "chaque pack du dépôt se charge, déclare son identité et ne publie que assets/" do
    packs.each do |dir|
      pack = Theme::Pack.new(dir)
      assert pack.brand[:product_name].present?, dir.to_s
      assert Theme::Pack::MODES.include?(pack.default_mode), dir.to_s
      assert_match(/\A<svg /, pack.monogramme(nil, classe: "m"), dir.to_s)
      favicon = pack.brand.fetch(:favicon)
      assert_includes published(pack), favicon, dir.to_s unless favicon == Theme::Pack::NEUTRAL_FAVICON

      expected = dir.join("assets").glob("**/*").select(&:file?).map { |file| file.relative_path_from(dir.join("assets")).to_s }.sort
      assert_equal expected, published(pack), dir.to_s
    end
  end

  test "chaque url() des feuilles d'un pack désigne un fichier de assets/" do
    packs.each do |dir|
      dir.glob("{tokens,chrome}.css").each do |css|
        css.read.gsub(%r{/\*.*?\*/}m, "").scan(/url\(\s*["']?([^"')]+)["']?\s*\)/).flatten.reject { |url| url.start_with?("data:", "#") }.each do |url|
          assert dir.join("assets", url).file?, "#{css.relative_path_from(Rails.root)} : url(#{url}) absent de assets/"
        end
      end
    end
  end

  private

  def packs
    Theme.root.children.select(&:directory?).reject { |dir| dir.basename.to_s == Theme::UNDUST }
  end

  # Ce que Propshaft publierait pour ce pack : logical paths des chemins d'assets.
  def published(pack)
    Propshaft::LoadPath.new(pack.asset_paths, compilers: Propshaft::Compilers.new(Rails.application.assets.config))
                       .assets.map { |asset| asset.logical_path.to_s }.sort
  end

  def write_pack(yaml)
    @root.join("pack").mkpath
    @root.join("pack/theme.yml").write(yaml)
    Theme::Pack.new(@root.join("pack"))
  end
end
