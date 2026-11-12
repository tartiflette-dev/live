# Changement de mise en avant pendant le direct, journalisé par RoomSpotlight
# (l'état courant vit dans les métadonnées LiveKit, sans historique). Lu par
# le montage du replay : une mise en avant explicite de l'animation l'emporte
# sur la parole (MontagePlan). `identity` nil = mise en avant retirée.
class SpotlightChange < ApplicationRecord
  belongs_to :webinar, inverse_of: :spotlight_changes

  validates :identity, length: { maximum: 256 }, allow_nil: true
  validates :changed_at, presence: true

  scope :chronological, -> { order(:changed_at, :id) }
end
