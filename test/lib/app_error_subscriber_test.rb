# frozen_string_literal: true

require "test_helper"

# L'abonné Rails.error commun écrit une ligne JSON `msg=AppError` par
# erreur rapportée, sans donnée personnelle, et ne lève jamais.
class AppErrorSubscriberTest < ActiveSupport::TestCase
  ROOT = "/rails"
  GEM_FRAME = "/usr/local/bundle/ruby/3.4.0/gems/activerecord-8.1.4/lib/active_record/core.rb:265:in 'find'"
  EMAIL = "jeanne.martin@example.com"

  class BrokenIO
    attr_reader :writes

    def initialize = @writes = 0

    def write(*)
      @writes += 1
      raise IOError, "tube fermé"
    end
  end

  class HostileError < StandardError
    def backtrace = raise("trace illisible")
  end

  test "une erreur rapportée produit une seule ligne JSON aux sept champs attendus" do
    error = error_with([ GEM_FRAME, "#{ROOT}/app/models/user.rb:42:in 'User#issue_magic_link!'" ], ArgumentError)

    output = emit(error, handled: false, severity: :error, source: "application.action_dispatch", release: "abc123")

    assert_equal 1, output.lines.size
    assert output.end_with?("\n")
    assert_equal(
      {
        "msg" => "AppError",
        "error_class" => "ArgumentError",
        "fingerprint" => "ArgumentError@app/models/user.rb#issue_magic_link!",
        "handled" => false,
        "severity" => "error",
        "source" => "application.action_dispatch",
        "release" => "abc123"
      },
      JSON.parse(output)
    )
  end

  test "l'empreinte vient de la première frame applicative, pas des gems ni de vendor/" do
    error = error_with([
      GEM_FRAME,
      "#{ROOT}/vendor/bundle/ruby/3.4.0/gems/pay-11.0/lib/pay.rb:7:in 'sync'",
      "#{ROOT}/app/jobs/sync_job.rb:12:in 'SyncJob#perform'",
      "#{ROOT}/app/models/user.rb:42:in 'User#touch'"
    ])

    assert_equal "RuntimeError@app/jobs/sync_job.rb#perform", fingerprint_of(error)
  end

  test "une édition au-dessus de la ligne fautive ne change pas l'empreinte" do
    before = fingerprint_of(error_with([ "#{ROOT}/app/models/user.rb:42:in 'User#touch'" ]))
    after = fingerprint_of(error_with([ "#{ROOT}/app/models/user.rb:52:in 'User#touch'" ]))

    assert_equal "RuntimeError@app/models/user.rb#touch", before
    assert_equal before, after
  end

  test "renommer la méthode fautive change l'empreinte" do
    before = fingerprint_of(error_with([ "#{ROOT}/app/models/user.rb:42:in 'User#touch'" ]))
    after = fingerprint_of(error_with([ "#{ROOT}/app/models/user.rb:42:in 'User#refresh'" ]))

    assert_not_equal before, after
  end

  test "bloc, rescue et ensure portent l'empreinte de la méthode englobante" do
    labels = [
      "User#touch", "block in User#touch", "block (2 levels) in User#touch", "rescue in User#touch",
      "ensure in User#touch", "rescue in block in User#touch", "User.touch", "Admin::User#touch",
      "#<Class:0x00007f3a>#touch"
    ]

    labels.each do |label|
      error = error_with([ "#{ROOT}/app/models/user.rb:42:in '#{label}'" ])
      assert_equal "RuntimeError@app/models/user.rb#touch", fingerprint_of(error), label
    end
  end

  test "l'empreinte est la même avant et après Ruby 3.4 (libellé sans receveur, accent grave)" do
    error = error_with([ "#{ROOT}/app/models/user.rb:42:in `touch'" ])

    assert_equal "RuntimeError@app/models/user.rb#touch", fingerprint_of(error)
  end

  test "les méthodes à suffixe gardent leur nom" do
    %w[valid? save! name=].each do |name|
      error = error_with([ "#{ROOT}/app/models/user.rb:42:in 'User##{name}'" ])
      assert_equal "RuntimeError@app/models/user.rb##{name}", fingerprint_of(error)
    end
  end

  test "hors de toute méthode, l'empreinte retombe sur le numéro de ligne" do
    [ "<main>", "<top (required)>", "<class:User>", "block in <class:User>", "User#[]", "relance de #{EMAIL}" ].each do |label|
      error = error_with([ "#{ROOT}/config/boot.rb:12:in '#{label}'" ])
      assert_equal "RuntimeError@config/boot.rb:12", fingerprint_of(error), label
    end

    assert_equal "RuntimeError@config/boot.rb:12", fingerprint_of(error_with([ "#{ROOT}/config/boot.rb:12" ]))
  end

  test "l'empreinte est la même quel que soit l'endroit où l'app est installée" do
    frames = ->(root) { [ GEM_FRAME, "#{root}/app/models/user.rb:42:in 'User#touch'" ] }
    in_container = fingerprint_of(error_with(frames.call("/rails")), root: "/rails")
    on_workstation = fingerprint_of(error_with(frames.call("/home/dev/Projects/tools--x")), root: "/home/dev/Projects/tools--x/")

    assert_equal "RuntimeError@app/models/user.rb#touch", in_container
    assert_equal in_container, on_workstation
  end

  test "un chemin voisin de Rails.root n'est pas pris pour du code applicatif" do
    error = error_with([ "/rails-autre/app/models/user.rb:42:in 'x'" ])

    assert_equal "RuntimeError@(hors-app)", fingerprint_of(error)
  end

  test "sans frame applicative, l'empreinte se réduit à la classe, de façon stable" do
    assert_equal "RuntimeError@(hors-app)", fingerprint_of(error_with([ GEM_FRAME ]))
    assert_equal "RuntimeError@(hors-app)", fingerprint_of(error_with([]))
    assert_equal "RuntimeError@(hors-app)", fingerprint_of(RuntimeError.new("jamais levée"))
  end

  test "une classe d'erreur anonyme reçoit un nom fixe" do
    error = Class.new(StandardError).new("x")

    assert_equal "(anonyme)@(hors-app)", fingerprint_of(error)
  end

  test "en environnement de test l'abonné est muet, sauf APP_ERROR_SIGNAL=1" do
    emit_in_test = lambda do
      io = StringIO.new
      AppErrorSubscriber.new(root: ROOT, env: "test", io: io).report(error_with([]), handled: false, severity: :error)
      io.string
    end

    with_env("APP_ERROR_SIGNAL" => nil) { assert_empty emit_in_test.call }
    with_env("APP_ERROR_SIGNAL" => "0") { assert_empty emit_in_test.call }
    with_env("APP_ERROR_SIGNAL" => "1") { assert_equal "AppError", JSON.parse(emit_in_test.call)["msg"] }
  end

  test "hors test l'abonné écrit sans aucun réglage" do
    %w[production development].each do |env|
      io = StringIO.new
      with_env("APP_ERROR_SIGNAL" => nil) do
        AppErrorSubscriber.new(root: ROOT, env: env, io: io).report(error_with([]), handled: false, severity: :error)
      end
      assert_equal "AppError", JSON.parse(io.string)["msg"], env
    end
  end

  test "ni le message ni le contexte ne sortent : aucune donnée personnelle" do
    error = error_with([ "#{ROOT}/app/models/user.rb:42:in 'x'" ], ArgumentError, "Email invalide : #{EMAIL}")
    context = { user_email: EMAIL, user_id: 4217, params: { "email" => EMAIL }, job: { arguments: [ EMAIL ] } }

    output = emit(error, context: context)

    assert_not_includes output, EMAIL
    assert_not_includes output, "example.com"
    assert_not_includes output, "4217"
    assert_not_includes output, "Email invalide"
    assert_equal %w[error_class fingerprint handled msg release severity source], JSON.parse(output).keys.sort
  end

  test "une source en texte libre est remplacée, une sévérité inconnue retombe sur error" do
    line = JSON.parse(emit(error_with([]), severity: :critique, source: "relance de #{EMAIL}"))

    assert_equal "(autre)", line["source"]
    assert_equal "error", line["severity"]
  end

  test "handled, severity et source sont recopiés tels que Rails les donne" do
    line = JSON.parse(emit(error_with([]), handled: true, severity: :warning, source: "application.solid_queue"))

    assert_equal true, line["handled"]
    assert_equal "warning", line["severity"]
    assert_equal "application.solid_queue", line["source"]
  end

  test "release vient de KAMAL_VERSION, null quand la variable est absente ou vide" do
    with_env("KAMAL_VERSION" => "0f3c9d2e") do
      io = StringIO.new
      AppErrorSubscriber.new(env: "production", io: io).report(error_with([]), handled: false, severity: :error)
      assert_equal "0f3c9d2e", JSON.parse(io.string)["release"]
    end

    [ nil, "", "  " ].each do |empty|
      assert_nil JSON.parse(emit(error_with([]), release: empty))["release"]
    end
    assert_includes emit(error_with([]), release: nil), '"release":null'
  end

  test "une sortie en panne ne fait pas lever l'abonné et n'est tentée qu'une fois" do
    io = BrokenIO.new
    broken = AppErrorSubscriber.new(root: ROOT, env: "production", io: io)

    assert_nothing_raised { broken.report(error_with([]), handled: false, severity: :error, source: "x") }
    assert_equal 1, io.writes
  end

  test "une erreur dont la trace est illisible ne fait pas lever l'abonné" do
    assert_nothing_raised do
      subscriber(io: StringIO.new).report(HostileError.new("x"), handled: false, severity: :error)
    end
  end

  test "branché sur un rapporteur sans filet, l'abonné en panne ne casse pas l'appelant" do
    # Sans logger, ActiveSupport::ErrorReporter relaie l'erreur d'un abonné à
    # l'appelant : rien ne doit donc sortir de l'abonné lui-même.
    reporter = ActiveSupport::ErrorReporter.new(logger: nil)
    io = BrokenIO.new
    reporter.subscribe(AppErrorSubscriber.new(root: ROOT, env: "production", io: io))

    assert_nothing_raised { reporter.report(error_with([]), handled: false) }
    assert_equal "ok", reporter.handle { raise "avalée" } || "ok"
    assert_equal 2, io.writes, "une écriture par erreur rapportée, aucune boucle"
  end

  private
    def with_env(overrides)
      previous = {}
      overrides.each { |k, _| previous[k] = ENV[k] }
      overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    # env production : l'abonné est muet en test (cf. tests dédiés plus haut).
    def subscriber(io: nil, release: nil, root: ROOT)
      AppErrorSubscriber.new(root: root, env: "production", release: release, io: io)
    end

    def emit(error, handled: false, severity: :error, source: "application", release: nil, context: {}, root: ROOT)
      io = StringIO.new
      subscriber(io: io, release: release, root: root).report(error, handled:, severity:, context:, source:)
      io.string
    end

    # L'empreinte se lit dans la ligne émise : c'est la seule surface publique.
    def fingerprint_of(error, root: ROOT)
      JSON.parse(emit(error, root: root))["fingerprint"]
    end

    def error_with(backtrace, klass = RuntimeError, message = "boom")
      klass.new(message).tap { |error| error.set_backtrace(backtrace) }
    end
end
