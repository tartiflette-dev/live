class HandRaise < ApplicationRecord
  belongs_to :webinar
  belongs_to :registration

  STATES = %w[waiting granting granted revoking revoked uncertain].freeze
  validates :state, inclusion: { in: STATES }
  validates :raised_at, presence: true
  validate :registration_belongs_to_webinar

  scope :active, -> { where(revoked_at: nil) }
  scope :waiting, -> { active.where(state: "waiting") }
  scope :granted, -> { active.where(state: "granted") }

  private

  def registration_belongs_to_webinar
    errors.add(:registration, :invalid) if registration && registration.webinar_id != webinar_id
  end
end
