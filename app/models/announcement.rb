# Envoi groupé — un message (objet + corps texte) qu'un HUMAIN connecté
# envoie depuis l'écran d'envoi d'un webinaire (WebinarAnnouncementsController),
# après aperçu et confirmation du nombre de destinataires
# (docs/announcements.md). La ligne est aussi le journal : cible, objet, corps,
# auteur, nombre de destinataires, horodatage.
#
# Communication sortante vers des tiers, irréversible une fois partie :
# AUCUNE autre voie ne
# crée ni ne met en file un envoi — ni API, ni job récurrent, ni agent. Les
# seuls appelants de `dispatch!` et `enqueue_pending!` sont les actions POST
# de ce contrôleur, derrière la session Pocket ID et le jeton CSRF. Qui peut
# viser quelle cible, et les quotas : AnnouncementPermission. Chaque envoi aux
# listes prévient les animateurs du projet ; chaque envoi d'un co-animateur
# prévient le propriétaire du webinaire (AnnouncementNoticeMailer).
#
# Cibles (AnnouncementAudience) :
#   • webinar_registrants — inscrits confirmés de CE webinaire, lien d'accès ;
#   • marketing_list      — consentement marketing actif, lien de retrait ;
#   • notify_next         — « préviens-moi du prochain Café IA », lien d'arrêt.
class Announcement < ApplicationRecord
  AUDIENCES = %w[webinar_registrants marketing_list notify_next].freeze
  # Écart entre deux mails d'un même envoi (deliver_later étalé) : 20 mails
  # par minute, 300 destinataires en un quart d'heure.
  SPACING = 3.seconds
  SUBJECT_MAX_LENGTH = 150
  BODY_MAX_LENGTH = 10_000

  enum :audience, AUDIENCES.index_with(&:itself), validate: true

  belongs_to :webinar
  has_many :deliveries, class_name: "AnnouncementDelivery", dependent: :restrict_with_exception,
                        inverse_of: :announcement

  # L'objet devient un en-tête de mail : une ligne, sans caractère de contrôle.
  normalizes :subject, with: ->(subject) { subject.gsub(/[[:cntrl:]]+/, " ").squish }
  normalizes :body, with: ->(body) { body.gsub("\r\n", "\n").strip }

  validates :subject, presence: true, length: { maximum: SUBJECT_MAX_LENGTH }
  validates :body, presence: true, length: { maximum: BODY_MAX_LENGTH }
  validates :author_sub, :author_email, presence: true
  validates :author_role, inclusion: { in: %w[owner project_host guest_host] }
  # Unicité portée par l'index : seule garde sûre sous un double clic simultané.
  validates :dispatch_token, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  class Refused < StandardError; end

  # Envois du journal qu'un utilisateur voit : ceux aux inscrits pour toute
  # l'animation, ceux aux listes pour les animateurs du projet.
  def self.visible_to(webinar, user)
    return none unless webinar.role_for(user)

    where(webinar: webinar, audience: user.project_host? ? AUDIENCES : %w[webinar_registrants])
  end

  delegate :recipients, :recipient_for, :stop_link?, :voice, to: :target

  # Lien personnel du pied pour la fiche d'un destinataire (`routes` : le
  # générateur d'URL, le mailer).
  def footer_url(holder, routes)
    target.footer_url(holder, routes)
  end

  # Pied ajouté au texte de l'auteur (mail et aperçu), dans la tonalité de
  # l'envoi, et le libellé du lien personnel qui le suit.
  def footer_text
    Voice.t("announcement_mailer.footer.#{audience}", voice: voice, title: webinar.title)
  end

  def footer_link_label
    Voice.t("announcement_mailer.link.#{audience}", voice: voice)
  end

  # Réponse : à l'auteur, ou au propriétaire du webinaire quand l'auteur est
  # un co-animateur (ses destinataires ne lui donnent pas leur adresse).
  def reply_to_email
    guest_author? ? owner_email : author_email
  end

  def guest_author?
    author_role == "guest_host"
  end

  def owner_email
    User.find_by(oidc_sub: webinar.host_sub)&.email.presence || Brand.support_email
  end

  def list?
    AnnouncementPermission::LIST_AUDIENCES.include?(audience)
  end

  # Confirmation humaine : enregistre l'envoi et fige ses destinataires (un
  # marqueur par adresse), dans UNE transaction d'écriture (SQLite IMMEDIATE :
  # deux confirmations simultanées se suivent), puis met en file et prévient
  # les superviseurs. Le bloc, évalué sous ce verrou, relit les quotas et lève
  # Refused. Un second envoi au même `dispatch_token` (double clic simultané)
  # lève ActiveRecord::RecordNotUnique avant toute mise en file.
  # @param recipients [Array<AnnouncementAudience::Recipient>] ceux dont le
  #   nombre a été montré et confirmé
  # @return [Integer] mails mis en file
  def dispatch!(recipients, now: Time.current)
    transaction do
      yield if block_given?
      update!(recipients_count: recipients.size)
      AnnouncementDelivery.insert_all!(recipients.map { |recipient| delivery_row(recipient, now) }) if recipients.any?
    end
    enqueue_pending!(now: now).tap { notify_supervisors }
  end

  # Met en file, un toutes les SPACING, les destinataires jamais mis en file
  # et ceux restés SANS NOUVELLES (mis en file, ni remis ni écartés
  # AnnouncementDelivery::SILENT_AFTER après l'heure prévue : job en échec,
  # processus tombé). Premier passage comme reprise. L'étalement continue
  # après le dernier mail déjà programmé : une reprise pendant l'envoi ne
  # double pas le débit. Le marqueur est pris AVANT la mise en file (la file
  # vit dans une autre base) ; un échec de mise en file le rend et
  # interrompt. Un mail remis ne repart jamais : la remise est prise par un
  # seul job (AnnouncementDelivery#claim_sending!).
  # @return [Integer] mails mis en file par cet appel
  def enqueue_pending!(now: Time.current)
    first_slot = [ now, deliveries.maximum(:scheduled_at)&.+(SPACING) ].compact.max
    deliveries.resumable(now).order(:id).each_with_index.count do |delivery, position|
      slot = first_slot + SPACING * position
      next false unless delivery.claim!(now: now, scheduled_at: slot)

      begin
        AnnouncementMailer.announcement(delivery).deliver_later(wait_until: slot)
      rescue StandardError
        delivery.release!
        raise
      end
      true
    end
  end

  # Avancement par envoi, pour le journal, en une requête.
  # @return [Hash{Integer => AnnouncementDelivery::Progress}]
  def self.progress_of(announcements, now: Time.current)
    AnnouncementDelivery.progress_by_announcement(announcements.map(&:id), now: now)
  end

  private

  def target
    @target ||= AnnouncementAudience.for(self)
  end

  def notify_supervisors
    AnnouncementNoticeMailer.list_sent(self).deliver_later if list?
    AnnouncementNoticeMailer.guest_sent(self).deliver_later if guest_author?
  end

  def delivery_row(recipient, now)
    { announcement_id: id, recipient_digest: AnnouncementDelivery.digest(recipient.email),
      holder_type: recipient.holder.class.name, holder_id: recipient.holder.id, created_at: now, updated_at: now }
  end
end
