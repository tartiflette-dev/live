# Marqueur d'un destinataire d'un envoi groupé (Announcement) : posé à la
# confirmation, il garantit UN mail par adresse et par envoi, reprise et job
# rejoué compris (index unique envoi × empreinte, remise prise par un seul job).
#
# Pas d'adresse en clair : `recipient_digest` = empreinte HMAC de l'adresse
# (CrmErasure.digest) ; l'adresse se relit sur la fiche (`holder`, inscription
# ou demande) au moment de la remise. Fiche effacée ou adresse changée (pierre
# tombale) : plus personne à qui écrire, rien ne part. crm:erase supprime les
# marqueurs de la personne (CrmErasure.erase!).
#
# États :
#   `enqueued_at`, `scheduled_at` — mis en file (posé AVANT la mise en file),
#                                   heure de remise prévue ;
#   `sending_at`   — remise prise par UN job (claim conditionnel) : un job
#                    rejoué (redémarrage, relance manuelle) ne renvoie rien ;
#   `delivered_at` — accepté par le serveur SMTP ;
#   `skipped_at`   — plus dans la cible à la remise (retrait, arrêt, fiche
#                    effacée).
# Ni remis ni écarté SILENT_AFTER après l'heure prévue = SANS NOUVELLES (job
# en échec, processus tombé) : affiché au journal, relancé par « Reprendre ».
# Résidu assumé : un mail accepté par le serveur SMTP juste avant la chute du
# processus, avant `delivered_at`, repartirait à une reprise manuelle.
class AnnouncementDelivery < ApplicationRecord
  SILENT_AFTER = 10.minutes

  Progress = Data.define(:delivered, :skipped, :in_flight, :silent, :pending) do
    def resumable?
      silent.positive? || pending.positive?
    end
  end

  belongs_to :announcement, inverse_of: :deliveries
  belongs_to :holder, polymorphic: true, optional: true

  scope :pending, -> { where(enqueued_at: nil) }
  scope :unsettled, -> { where(delivered_at: nil, skipped_at: nil) }
  scope :silent, ->(now = Time.current) {
    unsettled.where.not(enqueued_at: nil).where(scheduled_at: ...(now - SILENT_AFTER))
  }
  scope :in_flight, ->(now = Time.current) {
    unsettled.where.not(enqueued_at: nil).where(scheduled_at: (now - SILENT_AFTER)..)
  }
  scope :resumable, ->(now = Time.current) { unsettled.pending.or(silent(now)) }
  scope :delivered, -> { where.not(delivered_at: nil) }
  scope :skipped, -> { where.not(skipped_at: nil) }

  def self.digest(email)
    CrmErasure.digest(email)
  end

  # Avancement de plusieurs envois, en une requête groupée.
  # @return [Hash{Integer => Progress}] (envoi sans marqueur : tout à zéro)
  def self.progress_by_announcement(announcement_ids, now: Time.current)
    silent_before = now - SILENT_AFTER
    rows = where(announcement_id: announcement_ids).group(:announcement_id).pluck(
      :announcement_id,
      Arel.sql("SUM(CASE WHEN delivered_at IS NOT NULL THEN 1 ELSE 0 END)"),
      Arel.sql("SUM(CASE WHEN skipped_at IS NOT NULL THEN 1 ELSE 0 END)"),
      count_unsettled_sent("scheduled_at >= ?", silent_before),
      count_unsettled_sent("scheduled_at < ?", silent_before),
      Arel.sql("SUM(CASE WHEN delivered_at IS NULL AND skipped_at IS NULL AND enqueued_at IS NULL THEN 1 ELSE 0 END)")
    ).to_h { |id, *counts| [ id, Progress.new(*counts.map(&:to_i)) ] }
    announcement_ids.to_h { |id| [ id, rows.fetch(id) { Progress.new(0, 0, 0, 0, 0) } ] }
  end

  def self.count_unsettled_sent(condition, time)
    Arel.sql(sanitize_sql_array([
      "SUM(CASE WHEN delivered_at IS NULL AND skipped_at IS NULL AND enqueued_at IS NOT NULL AND #{condition} " \
      "THEN 1 ELSE 0 END)", time
    ]))
  end
  private_class_method :count_unsettled_sent

  # Mise en file, atomique : seulement un marqueur jamais mis en file, ou sans
  # nouvelles. `false` si un autre passage l'a pris entre-temps. Remet à zéro
  # la prise de remise d'un marqueur sans nouvelles (job mort).
  def claim!(now:, scheduled_at:)
    self.class.resumable(now).where(id: id)
        .update_all(enqueued_at: now, scheduled_at: scheduled_at, sending_at: nil, updated_at: now) == 1
  end

  def release!
    self.class.unsettled.where(id: id).update_all(enqueued_at: nil, scheduled_at: nil, updated_at: Time.current)
  end

  # Prise de la remise par UN job, juste avant le rendu : `false` pour un job
  # rejoué ou concurrent, ou un marqueur déjà remis ou écarté.
  def claim_sending!(now = Time.current)
    self.class.unsettled.where(id: id, sending_at: nil).update_all(sending_at: now, updated_at: now) == 1
  end

  def mark_delivered!(now = Time.current)
    update_columns(delivered_at: now, updated_at: now)
  end

  def mark_skipped!(now = Time.current)
    update_columns(skipped_at: now, updated_at: now)
  end

  # Le destinataire tel qu'il est AU MOMENT de la remise, ou nil s'il ne fait
  # plus partie de la cible. La fiche d'origine doit porter encore l'adresse
  # marquée ; la cible fournit la fiche courante (lien de retrait valide).
  def current_recipient
    email = holder&.email
    return nil unless email && self.class.digest(email) == recipient_digest

    announcement.recipient_for(email)
  end
end
