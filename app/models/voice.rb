# Tonalité d'une émission : l'application parle
# avec une tonalité PAR DÉFAUT (vouvoiement, sobre) ; chaque émission
# (`Webinar.kind`) peut porter la sienne. Le nom d'une tonalité est le
# `kind` de l'émission ; une émission sans tonalité propre retombe sur
# le défaut. Mode d'emploi : docs/tonalites.md.
#
# Deux supports, une seule résolution :
# - libellés et pages : clés `voices.<tonalité>.<clé>`, repli CLÉ PAR CLÉ
#   sur `voices.default.<clé>` ;
# - corps des mails : variante de gabarit `<action>.<format>+<tonalité>.erb`,
#   repli sur le gabarit par défaut (RegistrationMailer).
#
# Copie en français seulement (outil mono-marché, cf. en.yml) : les clés
# se lisent toujours en `LOCALE`, quelle que soit la langue du chrome.
module Voice
  DEFAULT = "default"
  LOCALE = :fr

  # Tonalité commune à des émissions : la leur si elles n'en ont qu'une,
  # sinon le défaut (demande groupée qui mêle des émissions).
  def self.common(voices)
    distinct = voices.uniq
    distinct.one? ? distinct.first : DEFAULT
  end

  # [clé de la tonalité, clé de repli] — sans doublon pour le défaut.
  def self.keys(key, voice)
    [ "voices.#{voice.presence || DEFAULT}.#{key}", "voices.#{DEFAULT}.#{key}" ].uniq
  end

  # Hors vue (sujets de mails, messages de contrôleur). En vue : VoiceHelper.
  # Le nom de l'organisation est toujours fourni (Brand.interpolations).
  def self.t(key, voice:, **options)
    primary, *fallbacks = keys(key, voice)
    I18n.t(primary, default: fallbacks.map(&:to_sym), locale: LOCALE, **Brand.interpolations, **options)
  end
end
