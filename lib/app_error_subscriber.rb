# frozen_string_literal: true

require "json"

# Abonné Rails.error commun (option B).
#
# Chaque erreur rapportée à Rails.error — exception non gérée d'une requête ou
# d'un job, ou appel explicite Rails.error.report/handle/record — produit UNE
# ligne JSON sur stdout :
#
#   {"msg":"AppError","error_class":"…","fingerprint":"…","handled":false,
#    "severity":"error","source":"…","release":"…"}
#
# AUCUNE donnée personnelle ne sort : ni le message de l'exception, ni le
# contexte (paramètres, utilisateur, job), ni la trace complète. Seuls partent
# le nom de la classe et l'emplacement du code applicatif (fichier#méthode).
#
# En environnement de test l'abonné reste muet, pour ne pas salir la sortie
# des suites : APP_ERROR_SIGNAL=1 le fait parler.
#
# L'abonné ne lève jamais : une panne ici ne doit ni casser la requête ou le
# job en cours, ni se rapporter elle-même (pas de boucle).
class AppErrorSubscriber
  MESSAGE = "AppError"
  ANONYMOUS_CLASS = "(anonyme)"
  NO_APP_FRAME = "(hors-app)"
  OTHER_SOURCE = "(autre)"
  SEVERITIES = %w[error warning info].freeze
  # Une source est un identifiant technique (« application.action_dispatch »),
  # jamais du texte libre : tout ce qui n'y ressemble pas est remplacé.
  SOURCE_FORMAT = /\A[a-z0-9_.-]{1,80}\z/i
  # Répertoires sous Rails.root qui ne sont pas du code de l'application.
  NON_APP_PREFIXES = %w[vendor/ node_modules/ tmp/].freeze
  FRAME_FORMAT = /\A(?<path>.+?):(?<line>\d+)(?::in [`'](?<label>.*)')?\z/m
  # « block (2 levels) in », « rescue in », « ensure in » : le code appartient à
  # la méthode englobante.
  LABEL_WRAPPERS = /\A(?:(?:block(?: \(\d+ levels\))?|rescue|ensure) in )+/
  # Ruby 3.4 préfixe la méthode par son receveur (« User#touch », « Foo.bar »).
  # Seul un nom de constante ou une classe anonyme compte comme receveur.
  LABEL_RECEIVER = /\A(?:[A-Z]\w*(?:::[A-Z]\w*)*|#<[^>\s]*>)[#.]/
  # Un nom de méthode ordinaire. Tout autre libellé (« <main> », « <class:Foo> »,
  # opérateur, texte inattendu) fait retomber sur le numéro de ligne.
  METHOD_NAME = /\A[A-Za-z_][A-Za-z0-9_]{0,99}[?!=]?\z/
  TEST_SWITCH = "APP_ERROR_SIGNAL"

  # io: nil = le $stdout du moment de l'écriture (capturable en test).
  def initialize(root: Rails.root, env: Rails.env, release: ENV["KAMAL_VERSION"], io: nil)
    @root_prefix = "#{root.to_s.chomp("/")}/"
    @test_env = env.to_s == "test"
    @release = release.to_s.strip.presence
    @io = io
  end

  # Signature de l'interface d'abonné d'ActiveSupport::ErrorReporter. `context`
  # est reçu et volontairement ignoré.
  def report(error, handled:, severity:, context: nil, source: nil)
    return if muted?

    write(JSON.generate(payload(error, handled, severity, source)))
  rescue StandardError
    nil
  end

  private
    def muted?
      @test_env && ENV[TEST_SWITCH] != "1"
    end

    def payload(error, handled, severity, source)
      {
        msg: MESSAGE,
        error_class: class_name(error),
        fingerprint: fingerprint(error),
        handled: handled ? true : false,
        severity: SEVERITIES.include?(severity.to_s) ? severity.to_s : "error",
        source: SOURCE_FORMAT.match?(source.to_s) ? source.to_s : OTHER_SOURCE,
        release: @release
      }
    end

    def fingerprint(error)
      "#{class_name(error)}@#{app_location(error) || NO_APP_FRAME}"
    end

    def class_name(error)
      error.class.name || ANONYMOUS_CLASS
    end

    # Première frame située dans le code de l'application, relative à
    # Rails.root et désignée par sa méthode (« app/models/user.rb#touch ») :
    # identique d'un hôte à l'autre, et d'un déploiement à l'autre même si une
    # édition décale la ligne fautive. Hors de toute méthode (script, corps de
    # classe), repli sur le numéro de ligne (« config/boot.rb:12 »).
    def app_location(error)
      Array(error.backtrace).each do |frame|
        match = FRAME_FORMAT.match(frame.to_s)
        next unless match && match[:path].start_with?(@root_prefix)

        relative = match[:path].delete_prefix(@root_prefix)
        next if NON_APP_PREFIXES.any? { |prefix| relative.start_with?(prefix) }

        method = method_name(match[:label])
        return method ? "#{relative}##{method}" : "#{relative}:#{match[:line]}"
      end
      nil
    end

    def method_name(label)
      name = label.to_s.sub(LABEL_WRAPPERS, "").sub(LABEL_RECEIVER, "")
      name if METHOD_NAME.match?(name)
    end

    # Un seul appel d'écriture pour la ligne entière, saut de ligne compris :
    # pas de ligne entrelacée entre threads. L'initializer met stdout en mode
    # synchrone, donc cet appel part aussitôt, sans flush séparé.
    def write(line)
      (@io || $stdout).write("#{line}\n")
    end
end
