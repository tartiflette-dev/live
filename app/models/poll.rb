# Sondage du direct. Une question du plan d'un
# webinaire (prévue à une minute du direct, ou créée à la volée), lancée en
# pop-up chez tous les participants, animation comprise.
#
# Types de question : choice (+ multiple), scale, short_text. Tout ce qui dépend du type
# (options, valeur de réponse, agrégat, noms par réponse) vit dans un objet
# Poll::Format, choisi une fois par `format`.
#
# Cycle : prévu → ouvert → fermé, jamais rouvert. Les transitions et les
# réponses passent toutes par le verrou du webinaire (`webinar.with_lock`,
# BEGIN IMMEDIATE sous SQLite) : un seul sondage ouvert par webinaire (index
# partiel en dernier rempart), un seul résultat affiché, aucune réponse
# acceptée après la fermeture ou la fin du direct. Un sondage déjà ouvert
# n'est plus modifiable ni supprimable (`edit!`, `remove!`, sous le même
# verrou) : ses réponses portent sur ce texte.
#
# Ce qui est à l'écran des participants (`Poll.current_for`) : le sondage
# ouvert, sinon celui dont l'animation montre le résultat. Montrer un
# résultat pendant qu'un AUTRE sondage est ouvert est refusé, et ouvrir un
# sondage masque les résultats montrés : l'écran n'a jamais deux sondages.
#
# Replay : un sondage lancé au direct reparaît dans le lecteur
# (ReplayPoll) et le spectateur du replay y répond (`respond_from_replay!`).
# Ces réponses portent leur origine (PollResponse#origin) : tout ce que
# voient la salle et la régie (`results`, `public_attributes`,
# `host_attributes`) ne compte QUE le direct.
class Poll < ApplicationRecord
  KINDS = %w[choice scale short_text].freeze
  LABEL_LIMIT = 300
  OPTION_LIMIT = 120
  TEXT_LIMIT = 200
  PLANNED_MINUTE = (0..600)
  CONTENT_ATTRIBUTES = %w[kind multiple label options planned_minute note].freeze

  # Refus d'une transition ou d'une réponse ; `code` est rendu tel quel au
  # client (HTTP 409).
  class Refused < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code.to_s)
    end
  end

  belongs_to :webinar, inverse_of: :polls
  has_many :responses, class_name: "PollResponse", inverse_of: :poll, dependent: :restrict_with_exception

  enum :kind, KINDS.index_with(&:itself), validate: true

  before_validation :normalize_content

  validates :label, presence: true, length: { maximum: LABEL_LIMIT }
  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validates :planned_minute, numericality: { only_integer: true, in: PLANNED_MINUTE }, allow_nil: true
  validates :note, length: { maximum: 1000 }
  validate :options_match_format
  validate :content_frozen_once_opened, on: :update

  before_destroy :refuse_destroy_once_opened, prepend: true

  scope :in_plan_order, -> { order(:position, :id) }
  scope :opened, -> { where.not(opened_at: nil).where(closed_at: nil) }

  # @return [Poll, nil] le sondage à l'écran des participants. Une seule
  # ligne au plus par construction : ouvrir masque les autres résultats, et
  # montrer un résultat est refusé pendant qu'un autre sondage est ouvert.
  def self.current_for(webinar)
    webinar.polls.where("(opened_at IS NOT NULL AND closed_at IS NULL) OR results_shown_at IS NOT NULL").first
  end

  # Fin du direct (LiveEnding) : le sondage resté ouvert est fermé.
  # @return [Boolean] true si un sondage a été fermé
  def self.close_open_for(webinar)
    webinar.with_lock do
      now = Time.current
      webinar.polls.opened.update_all(closed_at: now, updated_at: now).positive?
    end
  end

  def format
    Poll::Format.for(self)
  end

  def open?
    opened_at.present? && closed_at.nil?
  end

  def editable?
    opened_at.nil?
  end

  def state
    return "planned" if opened_at.nil?

    closed_at ? "closed" : "open"
  end

  def results_shown?
    results_shown_at.present?
  end

  def results_showable?
    !open? || format.results_showable_while_open?
  end

  # Ferme le sondage ouvert du webinaire et masque les résultats montrés.
  # @raise [Refused] :webinar_not_live, :already_opened
  def open!
    webinar.with_lock do
      reload
      raise Refused, :webinar_not_live unless webinar.live?
      raise Refused, :already_opened unless editable?

      now = Time.current
      siblings = webinar.polls.where.not(id: id)
      siblings.opened.update_all(closed_at: now, updated_at: now)
      siblings.where.not(results_shown_at: nil).update_all(results_shown_at: nil, updated_at: now)
      update!(opened_at: now)
    end
  end

  # @return [Boolean] false si déjà fermé (idempotent)
  def close!
    webinar.with_lock do
      reload
      raise Refused, :never_opened if editable?
      next false if closed_at

      update!(closed_at: Time.current)
    end
  end

  # @return [Boolean] false si le résultat était déjà montré
  # @raise [Refused] :never_opened, :other_poll_open, :poll_open (réponses
  #   courtes : seulement une fois fermé)
  def show_results!
    webinar.with_lock do
      reload
      raise Refused, :never_opened if editable?
      raise Refused, :other_poll_open if webinar.polls.opened.where.not(id: id).exists?
      raise Refused, :poll_open unless results_showable?
      next false if results_shown?

      now = Time.current
      webinar.polls.where.not(id: id).where.not(results_shown_at: nil).update_all(results_shown_at: nil, updated_at: now)
      update!(results_shown_at: now)
    end
  end

  # @return [Boolean] false si le résultat n'était pas montré
  def hide_results!
    webinar.with_lock do
      reload
      next false unless results_shown?

      update!(results_shown_at: nil)
    end
  end

  # Modifie le contenu d'un sondage relu sous le verrou : jamais après son
  # lancement, même si l'ouverture se glisse entre le chargement et l'écriture.
  # @raise [Refused] :already_opened ; [ActiveRecord::RecordInvalid]
  def edit!(attributes)
    webinar.with_lock do
      reload
      raise Refused, :already_opened unless editable?

      update!(attributes)
    end
  end

  # @raise [Refused] :already_opened
  def remove!
    webinar.with_lock do
      reload
      raise Refused, :already_opened unless editable?

      destroy!
    end
  end

  # Crée ou remplace la réponse du participant tant que le sondage est
  # ouvert et le direct en cours. Une réponse donnée auparavant depuis le
  # replay (direct repris) devient une réponse du direct.
  # @raise [Refused] :webinar_not_live, :poll_closed
  # @raise [ActiveRecord::RecordInvalid] réponse hors format
  def respond!(identity:, name:, value:, registration: nil)
    webinar.with_lock do
      reload
      raise Refused, :webinar_not_live unless webinar.live?
      raise Refused, :poll_closed unless open?

      response = responses.find_or_initialize_by(respondent_identity: identity)
      response.update!(name: name, registration: registration, value: value, origin: "live")
      response
    end
  end

  # Réponse de `viewer` (Registration ou User) depuis le replay : créée ou
  # remplacée, jamais à la place d'une réponse du direct. Relit la personne
  # sous le verrou : une inscription effacée entre-temps (crm:erase) ne
  # répond plus.
  # @raise [Refused] :not_in_replay (sondage jamais lancé), :answered_live,
  #   :viewer_gone
  # @raise [ActiveRecord::RecordInvalid] réponse hors format
  def respond_from_replay!(viewer:, value:)
    webinar.with_lock do
      reload
      raise Refused, :not_in_replay if editable?
      raise Refused, :viewer_gone unless viewer.class.exists?(viewer.id)
      raise Refused, :answered_live if responses.live.exists?(respondent_identity: PollResponse.live_identities(viewer))

      response = responses.find_or_initialize_by(respondent_identity: PollResponse.replay_identity(viewer))
      account = viewer.is_a?(User)
      response.update!(origin: "replay", value: value, name: account ? viewer.chat_alias : viewer.name,
                       user: (viewer if account), registration: (viewer unless account))
      response
    end
  end

  # Agrégat SQL des réponses (sans nom), du direct seul par défaut. Les
  # pourcentages sont calculés par le client sur `respondents` : en choix
  # multiple, la somme dépasse 100 %.
  def results(scope = responses.live)
    { respondents: scope.count }.merge(format.tally(scope))
  end

  # Ce que voient les participants (poll HTTP et data channel) : la
  # question, le compteur, et le résultat SEULEMENT quand l'animation le
  # montre — réponses texte anonymes, bornées en octets (Format::ShortText).
  def public_attributes
    shown = results_shown? ? format.public_results(results) : nil
    {
      id: id, kind: kind, multiple: multiple, label: label, options: options,
      open: open?, responses_count: shown ? shown[:respondents] : responses.live.count, results: shown
    }
  end

  # Ce que voit l'animation (régie), réponses du direct seulement.
  # `respondents: true` ajoute les noms : par option (choix), par valeur
  # (échelle), avec le texte (réponse courte).
  # Un sondage prévu n'a pas de réponse : aucune requête.
  def host_attributes(respondents: false)
    attributes = slice(:id, :position, :kind, :multiple, :label, :options, :planned_minute, :note).symbolize_keys
    tally = editable? ? nil : results
    attributes.merge!(
      state: state, editable: editable?, results_shown: results_shown?, results_showable: results_showable?,
      opened_at: opened_at&.utc&.iso8601, closed_at: closed_at&.utc&.iso8601,
      responses_count: tally ? tally[:respondents] : 0, results: tally
    )
    attributes[:respondents] = format.respondents(responses.live.order(:updated_at, :id).pluck(:name, :value)) if respondents
    attributes
  end

  private

  def normalize_content
    self.label = label.to_s.strip
    self.note = note.to_s.strip.presence
    self.multiple = false unless format&.multiple_allowed?
    self.options = format&.normalize_options(options)
  end

  def options_match_format
    format&.validate_options(errors)
  end

  def content_frozen_once_opened
    return if opened_at_in_database.nil?
    return unless (changed & CONTENT_ATTRIBUTES).any?

    errors.add(:base, "un sondage déjà lancé n'est plus modifiable")
  end

  def refuse_destroy_once_opened
    raise Refused, :already_opened unless editable?
  end
end
