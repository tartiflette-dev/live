require "test_helper"
require "open3"

# En production, l'application ne répond qu'aux noms de l'instance (APP_HOST,
# plus STAGING_HOSTS sur une pré-production) ; le contrôle de santé /up reste
# joignable sous n'importe quel nom, le proxy l'interroge sans le nom public.
class ProductionHostAuthorizationTest < ActiveSupport::TestCase
  # Statut de la réponse de l'application démarrée en production, dans un
  # processus à part, pour chaque couple « hôte chemin » donné.
  PROBE = <<~RUBY.freeze
    ARGV.each_slice(2) do |host, path|
      request = Rack::MockRequest.env_for("https://\#{host}\#{path}", "HTTP_HOST" => host)
      puts "\#{host}\#{path} \#{Rails.application.call(request).first}"
    end
  RUBY

  test "un nom étranger est refusé, APP_HOST est servi, /up répond à tous" do
    statuses = probe({ "APP_HOST" => "live.example.invalid" },
                     "evil.example.invalid", "/400.html",
                     "live.example.invalid", "/400.html",
                     "live.example.invalid:443", "/400.html",
                     "evil.example.invalid", "/up")

    assert_equal "403", statuses.fetch("evil.example.invalid/400.html")
    assert_equal "200", statuses.fetch("live.example.invalid/400.html")
    assert_equal "200", statuses.fetch("live.example.invalid:443/400.html")
    assert_equal "200", statuses.fetch("evil.example.invalid/up")
  end

  test "pré-production : chaque nom de STAGING_HOSTS est servi" do
    statuses = probe({ "APP_HOST" => "edge.example.invalid", "STAGING_HOSTS" => "edge.example.invalid,old.example.invalid" },
                     "old.example.invalid", "/sign_in",
                     "edge.example.invalid", "/400.html",
                     "evil.example.invalid", "/400.html")

    assert_equal "301", statuses.fetch("old.example.invalid/sign_in"), "l'ancien nom atteint LegacyHostRedirect"
    assert_equal "200", statuses.fetch("edge.example.invalid/400.html")
    assert_equal "403", statuses.fetch("evil.example.invalid/400.html")
  end

  private

  def probe(variables, *requests)
    output, status = Open3.capture2e(
      { "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1", "STAGING_HOSTS" => nil,
        "SOLID_QUEUE_IN_PUMA" => nil }.merge(variables),
      RbConfig.ruby, "-r", Rails.root.join("config/environment").to_s, "-e", PROBE, *requests,
      chdir: Rails.root.to_s
    )
    assert status.success?, output
    output.lines.filter_map { |line| line.split if line.match?(%r{\A\S+/\S* \d{3}$}) }.to_h
  end
end
