# Discussion du direct. Le fil persisté fait foi : auteur, nom affiché et nature
# (chat | question) sont décidés côté serveur, jamais lus du client.
class Message < ApplicationRecord
  BODY_LIMIT = 1000

  # Un message qui COMMENCE par l'une de ces mentions est une question
  # adressée à l'animation ; `@<alias de l'animateur>` (User#chat_alias du
  # propriétaire) compte aussi, comme les mentions propres à l'instance
  # (CHAT_QUESTION_MENTIONS, séparées par des virgules). Mot complet, casse
  # indifférente.
  QUESTION_MENTIONS = %w[animateur animatrice].freeze

  def self.question_mentions
    QUESTION_MENTIONS + ENV["CHAT_QUESTION_MENTIONS"].to_s.split(",").map(&:strip).reject(&:empty?)
  end

  # Préfixes des identités LiveKit (Api::TokensController#identity_for) ;
  # un co-animateur porte aussi `host-`. Le préfixe est le rôle affiché.
  AUTHOR_ROLES = %w[host speaker viewer].freeze

  belongs_to :webinar, inverse_of: :messages

  enum :kind, { chat: "chat", question: "question" }, validate: true

  before_validation :normalize_body_and_infer_kind, if: :will_save_change_to_body?
  # File Q&R : chaque message est proposé au LLM local, après
  # commit, hors du chemin de l'envoi.
  after_create_commit :enqueue_qa_extraction

  validates :body, presence: true, length: { maximum: BODY_LIMIT }
  validates :name, presence: true, length: { maximum: 120 }
  validates :author_identity, presence: true, length: { maximum: 128 },
    format: { with: /\A(?:#{AUTHOR_ROLES.join("|")})-./ }

  # Curseur de rattrapage (updated_at, id) strictement croissant : un
  # drapeau posé sur un ANCIEN message remonte, les égalités d'horodatage
  # sont départagées par l'id. Correct tant que chaque updated_at est posé
  # SOUS le verrou d'écriture de SQLite (un seul écrivain) : Rails n'émet
  # BEGIN IMMEDIATE qu'avec la première requête de la transaction — ici le
  # SELECT de `owner_alias` (création) et celui de `with_lock`
  # (modération). Un `update!` nu pose updated_at AVANT le verrou : toute
  # nouvelle écriture passe par `with_lock`, sinon un message peut commiter
  # derrière un curseur déjà avancé et manquer au poll.
  scope :updated_after, ->(time, id) {
    where("updated_at > ? OR (updated_at = ? AND id > ?)", time, time, id)
  }
  scope :in_cursor_order, -> { order(:updated_at, :id) }

  def author_role
    author_identity.split("-", 2).first
  end

  # Seule forme qui quitte le serveur (réponse HTTP et diffusion LiveKit).
  # Jamais `author_identity` : pour un animateur elle porte son sub OIDC.
  # `updated_at` à la microseconde, en UTC : c'est la moitié du curseur.
  def public_attributes
    {
      id: id,
      kind: kind,
      author_role: author_role,
      name: name,
      body: body,
      created_at: created_at.utc.iso8601(6),
      updated_at: updated_at.utc.iso8601(6),
      answered_at: answered_at&.utc&.iso8601(6),
      pinned_at: pinned_at&.utc&.iso8601(6)
    }
  end

  private

  # Une file d'attente indisponible ne doit jamais faire échouer un message
  # déjà enregistré : la question manque à la file, le chat continue.
  def enqueue_qa_extraction
    QaExtractionJob.perform_later(id)
  rescue StandardError => error
    Rails.logger.warn("[qa_extraction] enqueue_failed webinar=#{webinar_id} message=#{id} #{error.class}")
  end

  def normalize_body_and_infer_kind
    self.body = body.to_s.strip
    mentions = self.class.question_mentions + [ owner_alias ].compact
    pattern = /\A@(?:#{mentions.map { |mention| Regexp.escape(mention) }.join("|")})(?=\z|[[:space:][:punct:]])/i
    self.kind = body.match?(pattern) ? :question : :chat
  end

  def owner_alias
    User.find_by(oidc_sub: webinar&.host_sub)&.chat_alias
  end
end
