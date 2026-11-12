# Abonnement d'une PERSONNE (adresse normalisée) au flux d'agenda personnel
# /agenda/<jeton>.ics (CalendarFeedsController) : toutes les dates publiées,
# mises à jour à chaque rafraîchissement de son agenda.
#
# Jamais avant preuve de la boîte : il naît à la première confirmation d'une
# inscription (Registration#confirm!) ou d'une demande de l'API
# (RegistrationRequest#confirm!), qui appellent `offer_to`. Le mail qui porte
# le lien part une seule fois par personne, ou à nouveau après une
# révocation (nouveau jeton).
#
# Le jeton est opaque et ne se devine pas ; il ne donne accès qu'à des dates
# déjà publiques. Le fermer : `revoke!` (le flux répond alors 404). Effacer la
# personne (CrmErasure) supprime la ligne.
class CalendarSubscription < ApplicationRecord
  self.filter_attributes += [ :token ]

  before_validation :normalize_email
  before_validation :ensure_token, on: :create

  validates :email, presence: true, uniqueness: true
  validates :token, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  # Abonne la personne si elle ne l'est pas, ou plus (révoquée) ; le mail du
  # lien part alors, APRÈS la transaction de l'appelant (confirmation sous
  # verrou) : un mail ne part jamais pour un abonnement annulé par un
  # rollback. `voice` = tonalité du mail (Voice) ; `name` = prénom saisi.
  # @return [Boolean] un lien vient d'être émis
  def self.offer_to(email, name:, voice:)
    email = email.to_s.strip.downcase
    subscription = find_by(email: email) || create_or_find_by!(email: email)
    return false unless subscription.previously_new_record? || subscription.reissue_if_revoked!

    ActiveRecord.after_all_transactions_commit do
      CalendarSubscriptionMailer.feed_link(subscription, name: name, voice: voice).deliver_later
    end
    true
  end

  # Résolution du flux : jeton inconnu, vide ou révoqué → nil.
  def self.find_active_by_token(token)
    return nil if token.blank?

    active.find_by(token: token)
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!(now: Time.current)
    update!(revoked_at: now) unless revoked?
  end

  # Révoqué : nouveau jeton, l'ancien lien reste mort.
  # @return [Boolean] un jeton neuf a été émis
  def reissue_if_revoked!
    with_lock do
      next false unless revoked?

      update!(token: self.class.generate_token, revoked_at: nil)
      true
    end
  end

  # Un agenda est venu chercher le flux. Écriture atomique, sans toucher
  # `updated_at` : deux rafraîchissements concurrents comptent deux fois.
  def record_fetch!(now: Time.current)
    self.class.where(id: id).update_all([ "fetch_count = fetch_count + 1, last_fetched_at = ?", now ])
  end

  def self.generate_token
    SecureRandom.urlsafe_base64(24)
  end

  def inspect
    "#<CalendarSubscription id=#{id} email=#{email.inspect} revoked_at=#{revoked_at.inspect} " \
      "fetch_count=#{fetch_count.inspect} last_fetched_at=#{last_fetched_at.inspect}>"
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end

  def ensure_token
    self.token = self.class.generate_token if token.blank?
  end
end
