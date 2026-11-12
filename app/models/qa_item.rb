# File Q&R d'un webinaire. Une question à traiter par
# l'animation, extraite du chat : reformulée par le LLM local (source llm),
# texte brut d'un message (source mention : une mention @animateur quand le
# LLM est coupé ou en panne, ou le message d'un autre auteur repris après
# effacement), ou ajoutée à la main depuis un message (source manual).
# Le libellé est TIRÉ d'un message (`label_message`) : son effacement
# (crm:erase) le fait réécrire ou disparaître (#forget_erased!).
#
# Les AUTEURS sont les messages liés (QaItemMessage) : plusieurs personnes
# peuvent poser la même question, un seul item. Le nom, le rôle et
# l'inscription viennent du message ; l'identité LiveKit d'un animateur (son
# sub OIDC) ne sort jamais.
#
# Question posée depuis le replay (source replay, `ask_from_replay!`) : le
# texte de la personne tel quel, l'instant de la vidéo (`video_position`) et
# son auteur, inscription OU compte (contrainte en base), sans
# message. Elle part avec l'inscription (crm:erase, rétention) ou le compte.
# Le rapprochement des doublons par le LLM ne vise que les questions du
# direct (`from_live`) : aucune question du replay ne reçoit de message.
#
# Écritures sous verrou : `with_lock` (SQLite : BEGIN IMMEDIATE à la première
# requête, cf. Message) sérialise création, rattachement et affichage. Au
# plus une question affichée à l'écran par webinaire (index partiel unique).
class QaItem < ApplicationRecord
  LABEL_LIMIT = 500
  STATUSES = %w[open answered dismissed].freeze
  SOURCES = %w[llm mention manual replay].freeze

  class NotDisplayable < StandardError; end

  # Issue du dernier `enqueue!` sur cet objet (non persistée) : :created,
  # :attached (rattaché à une question ouverte) ou :existing (message déjà
  # rangé), décidée SOUS le verrou.
  attr_accessor :enqueued

  belongs_to :webinar, inverse_of: :qa_items
  belongs_to :label_message, class_name: "Message", optional: true
  belongs_to :registration, optional: true
  belongs_to :user, optional: true
  has_many :qa_item_messages, -> { order(:id) }, dependent: :delete_all, inverse_of: :qa_item
  has_many :messages, through: :qa_item_messages

  enum :status, STATUSES.index_with(&:itself), validate: true
  enum :source, SOURCES.index_with(&:itself), validate: true, prefix: true

  before_validation { self.label = label.to_s.squish }
  validates :label, presence: true, length: { maximum: LABEL_LIMIT }

  scope :queue_order, -> { in_order_of(:status, STATUSES).order(:created_at, :id) }
  scope :displayed, -> { where.not(displayed_at: nil) }
  scope :from_live, -> { where.not(source: "replay") }

  # Range `message` dans la file : rattaché à `duplicate_of` s'il désigne
  # encore une question OUVERTE du même webinaire, sinon nouvel item.
  # Idempotent : un message déjà rangé rend son item, rien n'est créé.
  #
  # Le message est RELU sous le verrou : l'appel au LLM dure des secondes, un
  # `crm:erase` a pu passer entre-temps (SQLite : un seul écrivain, l'effacement
  # est soit commité avant, soit après). Disparu ou effacé → rien, nil : son
  # texte (ou une reformulation de son texte) ne revient jamais dans la file.
  # @return [QaItem, nil]
  def self.enqueue!(message:, label:, source:, llm_model: nil, duplicate_of: nil)
    webinar = message.webinar
    webinar.with_lock do
      message = Message.find_by(id: message.id)
      next if message.nil? || message.body == CrmErasure::ERASED_BODY

      existing = QaItemMessage.find_by(message_id: message.id)
      next existing.qa_item.tap { |item| item.enqueued = :existing } if existing

      item = webinar.qa_items.open.from_live.find_by(id: duplicate_of) if duplicate_of
      item&.enqueued = :attached
      item ||= webinar.qa_items.create!(label: label.to_s.squish.truncate(LABEL_LIMIT), source: source, llm_model: llm_model,
                                        label_message: message).tap { |created| created.enqueued = :created }
      item.qa_item_messages.create!(message: message)
      item.touch
      item
    end
  end

  # Question de `viewer` (Registration ou User) posée depuis le replay, à
  # l'instant `at` de la vidéo (borné à sa durée). La personne est relue
  # sous le verrou : une inscription effacée entre-temps (crm:erase) ne pose
  # plus rien.
  # @return [QaItem, nil] nil si la personne a disparu
  # @raise [ActiveRecord::RecordInvalid] libellé vide ou trop long
  def self.ask_from_replay!(replay:, viewer:, label:, at:)
    webinar = replay.webinar
    webinar.with_lock do
      next unless viewer.class.exists?(viewer.id)

      account = viewer.is_a?(User)
      webinar.qa_items.create!(source: "replay", label: label, video_position: at.to_f.clamp(0.0, replay.duration),
                               user: (viewer if account), registration: (viewer unless account))
    end
  end

  # Transitions de l'animation. Chacune rend `true` si l'item a changé
  # (à rediffuser), `false` s'il était déjà dans l'état demandé.
  def answer!(now = Time.current)
    transition!(status: "answered", answered_at: answered_at || now, displayed_at: nil)
  end

  def dismiss!
    transition!(status: "dismissed", displayed_at: nil)
  end

  def reopen!
    transition!(status: "open", answered_at: nil)
  end

  def relabel!(label)
    transition!(label: label.to_s.squish)
  end

  def hide!
    transition!(displayed_at: nil)
  end

  # Effacement d'une personne (CrmErasure.erase!, même transaction), APRÈS
  # retrait des liens de ses messages `erased_message_ids` : sans autre
  # auteur, la question disparaît ; si son libellé venait d'un message effacé,
  # il est réécrit depuis le premier auteur restant (texte brut, source
  # mention : aucune reformulation ne survit à son message) et retiré de
  # l'écran — un texte brut que l'animation n'a pas relu ne s'y affiche pas.
  # @return [Boolean] true si la question a été supprimée ou réécrite
  def forget_erased!(erased_message_ids)
    remaining = qa_item_messages.reload.first&.message
    return destroy!.destroyed? if remaining.nil?
    return false unless erased_message_ids.include?(label_message_id)

    update!(label: remaining.body.squish.truncate(LABEL_LIMIT), label_message: remaining, source: "mention", llm_model: nil,
            displayed_at: nil)
  end

  # Affiche CETTE question à l'écran de tous ; celle qui l'était cède la
  # place. Seule une question ouverte s'affiche.
  def display!(now = Time.current)
    webinar.with_lock do
      reload
      raise NotDisplayable, "seule une question ouverte s'affiche" unless open?
      next false if displayed_at

      webinar.qa_items.displayed.update_all(displayed_at: nil, updated_at: now)
      update!(displayed_at: now)
    end
  end

  # Auteurs distincts, dans l'ordre où ils ont posé la question. Nom et rôle
  # seulement : l'inscription reste côté serveur (récap / CRM, Lot 2).
  # Question du replay : son auteur, rôle `account` pour un compte.
  def authors
    return [ replay_author ] if source_replay?

    messages.uniq(&:author_identity).map { |message| { name: message.name, role: message.author_role } }
  end

  # Ce que voient TOUS les participants (bandeau « question en cours ») :
  # le libellé seul, jamais les auteurs.
  def public_attributes
    { id: id, label: label, displayed_at: displayed_at&.utc&.iso8601(6) }
  end

  # Ce que voit l'animation (console de régie).
  def console_attributes
    {
      id: id,
      label: label,
      status: status,
      source: source,
      llm_model: llm_model,
      created_at: created_at.utc.iso8601(6),
      updated_at: updated_at.utc.iso8601(6),
      answered_at: answered_at&.utc&.iso8601(6),
      displayed_at: displayed_at&.utc&.iso8601(6),
      video_position: video_position,
      authors: authors,
      messages: messages.map do |message|
        { id: message.id, author_role: message.author_role, name: message.name, body: message.body,
          created_at: message.created_at.utc.iso8601(6) }
      end
    }
  end

  private

  def replay_author
    user ? { name: user.chat_alias, role: "account" } : { name: registration.name, role: "viewer" }
  end

  def transition!(attributes)
    with_lock do
      assign_attributes(attributes)
      next false unless changed?

      save!
    end
  rescue ActiveRecord::RecordInvalid
    # Refusé : l'objet revient à l'état enregistré (un `with_lock` suivant
    # refuserait des changements non persistés).
    restore_attributes
    raise
  end
end
