class Pack < ApplicationRecord
  # Pack : formule payante (paiement MODÉLISÉ,
  # jamais encaissé). Un Pack regroupe N webinaires ; l'accès payant se
  # débloque manuellement (`Registration#paid_confirmed_at`).
  #
  # `dependent: :nullify` : détruire un Pack laisse ses webinaires en
  # place, `pack_id` remis à NULL. Aucun destroy n'est exposé aujourd'hui : le jour où un destroy sera légitime, aucun
  # webinaire ne sera arraché avec le pack.
  has_many :webinars, dependent: :nullify

  validates :name,        presence: true, length: { maximum: 100 }
  validates :price_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :host_sub,    presence: true

  # Isolation par host_sub (invariant repo : mêmes règles que Webinar).
  scope :hosted_by, ->(sub) { where(host_sub: sub) }
end
