# Politique de confidentialité servie par /confidentialite, et sa version : la
# même valeur est figée dans la preuve de chaque consentement marketing
# (`marketing_consent_policy_version`) et de chaque accord à l'image
# (`participant_consents.policy_version`).
#
# Le logiciel livre une page générique (legal/confidentialite), qui décrit
# les données qu'il traite. L'opérateur d'une instance fournit sa propre
# politique : le gabarit legal/instance/confidentialite.html.erb, avec sa
# version et sa date dans legal/instance/confidentialite.yml (`version:`,
# `date:`, en texte). Présente, elle remplace la page générique.
module PrivacyPolicy
  Policy = Data.define(:template, :version, :date)

  GENERIC = Policy.new(template: "legal/confidentialite", version: "1.0", date: "12 novembre 2026")
  INSTANCE_TEMPLATE = "legal/instance/confidentialite".freeze

  # Un gabarit sans version (ou l'inverse) refuse le démarrage : une preuve
  # ne doit jamais figer la version d'un autre texte que celui affiché.
  def self.resolve(views = Rails.root.join("app/views"))
    page = Pathname(views).join("#{INSTANCE_TEMPLATE}.html.erb")
    meta = Pathname(views).join("#{INSTANCE_TEMPLATE}.yml")
    return GENERIC unless page.exist? || meta.exist?
    raise ArgumentError, "#{INSTANCE_TEMPLATE} : le gabarit et sa version (.yml) vont ensemble" unless page.exist? && meta.exist?

    version, date = YAML.safe_load_file(meta).values_at("version", "date")
    unless [ version, date ].all? { |value| value.is_a?(String) && value.present? }
      raise ArgumentError, "#{meta} : `version` et `date` en texte (version: \"2.0\")"
    end

    Policy.new(template: INSTANCE_TEMPLATE, version: version.freeze, date: date.freeze)
  end

  CURRENT = resolve
  TEMPLATE = CURRENT.template
  VERSION = CURRENT.version
  DATE = CURRENT.date
end
