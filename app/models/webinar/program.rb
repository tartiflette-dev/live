# Programme annoncé d'un café : le sujet (un titre court, une ou deux phrases
# qui le présentent), les intervenants annoncés (des noms affichés, pas des
# comptes : un habitué peut intervenir) et l'animateur du jour, celui qui mène,
# distinct du propriétaire pour que les rôles tournent.
#
# Saisi par toute l'animation (WebinarProgramsController), formulaire repris
# dans l'écran d'édition du propriétaire. Affiché sur la page publique
# et l'inscription, l'agenda, /agenda/next.json et le rappel de la veille.
# Tout est facultatif : un café sans programme s'affiche comme avant.
module Webinar::Program
  extend ActiveSupport::Concern

  # 2 ou 3 intervenants par café.
  ANNOUNCED_SPEAKERS_MAX = 3
  TOPIC_MAX = 120
  TOPIC_SUMMARY_MAX = 400
  NAME_MAX = 80

  # Validations du geste de saisie seulement (contexte `:edition` de
  # Webinar::Edition#revise) : un programme hors bornes, écrit en console ou
  # resté d'un plafond plus large, ne fait jamais échouer le lancement du direct.
  included do
    normalizes :topic, :topic_summary, :lead_host_name, with: ->(value) { value.strip.presence }

    with_options on: :edition do
      validates :topic, length: { maximum: TOPIC_MAX }
      validates :topic, presence: { message: "doit être renseigné pour accompagner sa présentation" },
                        if: -> { topic_summary.present? }
      validates :topic_summary, length: { maximum: TOPIC_SUMMARY_MAX }
      validates :lead_host_name, length: { maximum: NAME_MAX }
      validate :announced_speakers_within_limits
    end
  end

  # Le formulaire envoie toujours ANNOUNCED_SPEAKERS_MAX champs : les vides
  # tombent, l'ordre de saisie est l'ordre affiché.
  def announced_speakers=(names)
    super(Array(names).map { |name| name.to_s.strip }.compact_blank)
  end

  def program_announced?
    topic.present? || announced_speakers.any? || lead_host_name.present?
  end

  private

  def announced_speakers_within_limits
    if announced_speakers.size > ANNOUNCED_SPEAKERS_MAX
      errors.add(:announced_speakers, :too_many, message: "#{ANNOUNCED_SPEAKERS_MAX} au plus")
    end
    return unless announced_speakers.any? { |name| name.length > NAME_MAX }

    errors.add(:announced_speakers, :name_too_long, message: "#{NAME_MAX} caractères au plus par nom")
  end
end
