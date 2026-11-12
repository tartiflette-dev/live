# Réponse d'un participant à un sondage, au direct ou depuis le replay
# (`origin`). Les deux ne se confondent jamais : les résultats du direct
# (régie, salle) ne comptent que les réponses du direct, le replay montre
# les deux réunies et les statistiques les séparent.
#
# Au direct : une par identité LiveKit (host-/speaker-/viewer-, décidée
# serveur par RoomAuthor), remplacée tant que le sondage est ouvert
# (Poll#respond!). Depuis le replay : une par personne, inscription
# (viewer-<id>, la même identité qu'au direct) ou compte
# (account-<id>), refusée à qui a déjà répondu au direct
# (Poll#respond_from_replay!).
#
# `value` normalisée et validée par le format du sondage (Poll::Format).
class PollResponse < ApplicationRecord
  ORIGINS = %w[live replay].freeze
  IDENTITY_ROLES = (Message::AUTHOR_ROLES + %w[account]).freeze

  belongs_to :poll, inverse_of: :responses
  belongs_to :registration, optional: true
  belongs_to :user, optional: true

  enum :origin, ORIGINS.index_with(&:itself), validate: true, prefix: true, scopes: false

  scope :live, -> { where(origin: "live") }
  scope :replay, -> { where(origin: "replay") }

  before_validation :normalize_value, if: :will_save_change_to_value?

  validates :respondent_identity, presence: true, length: { maximum: 128 },
    format: { with: /\A(?:#{IDENTITY_ROLES.join("|")})-./ }
  validates :name, presence: true, length: { maximum: 120 }
  validate :value_matches_poll

  # Identité de `viewer` (Registration ou User) dans le replay.
  def self.replay_identity(viewer)
    viewer.is_a?(User) ? "account-#{viewer.id}" : "viewer-#{viewer.id}"
  end

  # Identités sous lesquelles `viewer` a pu répondre au direct : son
  # inscription, ou son compte s'il animait (host-<sub>).
  def self.live_identities(viewer)
    viewer.is_a?(User) ? [ "host-#{viewer.oidc_sub}" ] : [ "viewer-#{viewer.id}" ]
  end

  private

  def normalize_value
    self.value = poll&.format&.normalize_value(value)
  end

  def value_matches_poll
    errors.add(:value, "ne correspond pas à la question") unless poll&.format&.valid_value?(value)
  end
end
