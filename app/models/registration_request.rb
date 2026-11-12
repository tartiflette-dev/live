# Demande d'inscription — une soumission de l'API cross-origin
# (docs/registrations-api.md, Api::RegistrationsController).
#
# Elle regroupe les inscriptions CRÉÉES par la même soumission (0..3
# cafés) et porte ce qui appartient à la soumission, pas à un café :
# source, profil, message, « préviens-moi du prochain café ». Un seul
# mail, un seul lien `/confirmer?t=<token>` confirme le tout (double
# opt-in) ; le lien reste ensuite la page d'accès personnelle aux cafés.
#
# Invariant de sécurité : une inscription EXISTANTE
# n'est jamais rattachée à une demande — une soumission anonyme ne
# modifie jamais ce qu'une autre personne a déjà déposé.
class RegistrationRequest < ApplicationRecord
  TARTIFLETTE_SOURCE = "tartiflette.dev"
  SOURCES  = [ TARTIFLETTE_SOURCE ].freeze
  PROFILES = %w[conception fabrication design dev autre].freeze
  MESSAGE_MAX_LENGTH = 2000
  # Prénom publiable au groupe ouvert de la communauté, même règle que le
  # relais WhatsApp : des lettres de l'alphabet latin (accentuées comprises),
  # avec apostrophe ou trait d'union entre deux lettres, 30 au plus. Ni chiffre, ni `@`, ni lien,
  # ni caractère de formatage WhatsApp (`*_~` et l'accent grave), ni emoji, ni
  # caractère de remplissage invisible, ni sosie d'un autre alphabet.
  ANNOUNCEABLE_FIRST_NAME = /\A\p{Latin}(?:[\p{Latin}'’-]{0,28}\p{Latin})?\z/
  # Sans confirmation, la demande (et ses inscriptions) est effacée au bout
  # de ce délai (RetentionPurgeJob) ; son lien cesse de fonctionner au même
  # terme. Annoncé dans le mail, la page de confirmation et /confidentialite.
  CONFIRMATION_WINDOW = 30.days

  has_many :registrations, dependent: :restrict_with_exception, inverse_of: :registration_request

  before_validation :normalize_email
  before_validation :ensure_token, on: :create

  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  # Domaine réservé aux pierres tombales (Registration::RESERVED_EMAIL).
  validate { errors.add(:email, :invalid) if Registration.reserved_email?(email) }
  validates :name, presence: true, length: { maximum: 120 }
  validates :token, presence: true, uniqueness: true
  validates :source, inclusion: { in: SOURCES }, allow_nil: true
  validates :profile, inclusion: { in: PROFILES }, allow_nil: true
  validates :message, length: { maximum: MESSAGE_MAX_LENGTH }

  scope :unconfirmed_expired, ->(now = Time.current) {
    where(confirmed_at: nil, created_at: ...(now - CONFIRMATION_WINDOW))
  }

  # « Préviens-moi » confirmés dont il reste à pousser (CrmResyncJob,
  # CrmNotifyNextJob) : l'entrée du participant, le consentement marketing
  # porté par la demande, ou son retrait une fois le consentement poussé.
  scope :crm_pending, -> {
    base = where.not(confirmed_at: nil).where(notify_next: true, crm_contact_gone_at: nil)
    base.where(pushed_to_crm_at: nil)
        .or(base.where(marketing_consent: true, crm_marketing_consent_pushed_at: nil))
        .or(base.where.not(marketing_consent_withdrawn_at: nil).where(crm_withdrawal_pushed_at: nil))
  }

  # Inscriptions Café IA confirmées, transmises à l'équipe : toutes sur
  # WhatsApp (groupe des co-organisateurs, relais WhatsApp,
  # Internal::RegistrationMessagesController) ; celles qui portent un message,
  # aussi par mail (`notify_team!`). La confirmation (double opt-in) est la
  # garde anti-spam : rien ne part d'une demande non confirmée.
  # Un canal = une colonne d'horodatage, une file et son acquittement.
  scope :team_signups, -> { where(source: TARTIFLETTE_SOURCE).where.not(confirmed_at: nil) }
  scope :team_messages, -> { team_signups.where.not(message: [ nil, "" ]) }
  scope :team_notification_pending, -> { team_messages.where(team_notified_at: nil) }
  scope :whatsapp_relay_pending, -> { team_signups.where(whatsapp_relayed_at: nil) }
  # Annonce au groupe de la communauté Tartiflette (prénom et cafés, rien
  # d'autre) : seulement une inscription à au moins un café publié, car un
  # « préviens-moi » seul n'a rien à annoncer. Le groupe est ouvert : jamais
  # une inscription de test de bout en bout (adresse en `+cafe-test-`), ni un
  # prénom retenu à la confirmation (`community_announcement_withheld_at`,
  # voir ANNOUNCEABLE_FIRST_NAME). Les demandes soumises avant la politique
  # v2.3, qui n'annonçait pas ce canal, sont marquées par la migration
  # 20261108100000.
  scope :community_announceable, -> {
    team_signups.where(community_announcement_withheld_at: nil).where.not("email LIKE ?", "%+cafe-test-%")
                .where(id: Registration.joins(:webinar).merge(Webinar.published).select(:registration_request_id))
  }
  scope :community_announcement_pending, -> { community_announceable.where(community_announced_at: nil) }

  validates :marketing_withdrawal_token, uniqueness: true, allow_nil: true

  def self.find_by_token(token)
    return nil if token.blank?

    find_by(token: token)
  end

  def self.find_by_marketing_withdrawal_token(token)
    return nil if token.blank?

    find_by(marketing_withdrawal_token: token)
  end

  # Retrait pour la PERSONNE (cf. Registration.withdraw_marketing_consent_of).
  def self.withdraw_marketing_consent_of(email)
    where(email: email, marketing_consent: true).select do |request|
      request.with_lock { request.withdraw_marketing_consent! }
    end
  end

  # Lien « ne plus être prévenu·e » des envois groupés « préviens-moi »
  # (AnnouncementMailer, NotifyNextStopsController) : jeton signé, sans
  # colonne, qui cesse de valoir une fois l'arrêt posé.
  generates_token_for(:notify_next_stop) { notify_next_stopped_at }

  # Arrêt du « préviens-moi » pour la PERSONNE : toutes ses demandes
  # confirmées, comme un retrait. Ni ses inscriptions ni son consentement
  # marketing ne changent ; `notify_next` garde ce qu'elle a demandé.
  # Retourne le nombre de demandes arrêtées par cet appel.
  def self.stop_notify_next_of(email, now: Time.current)
    where(email: email, notify_next: true, notify_next_stopped_at: nil).where.not(confirmed_at: nil)
      .update_all(notify_next_stopped_at: now, updated_at: now)
  end

  def confirmation_expired?(now = Time.current)
    !confirmed? && created_at < now - CONFIRMATION_WINDOW
  end

  # Confirme la demande ET ses inscriptions dans une seule transaction.
  # Retourne `true` à la PREMIÈRE confirmation seulement : l'appelant
  # n'émet qu'une fois ce qui en découle (CRM, mail aux co-organisateurs).
  #
  # `marketing_consent: true` = la personne a cliqué « Confirmer et
  # accepter d'être recontacté·e » (politique v1.6). Défaut `false` : un
  # appel sans choix explicite n'accorde jamais rien.
  # Sans choix offert (`marketing_choice_offered?`), sans effet.
  # L'accord va aux cafés affichés ; sans café, à la demande « préviens-moi ».
  # Le lien d'agenda personnel part dans la tonalité de la demande, avant
  # que les inscriptions ne le proposent dans celle de leur café.
  def confirm!(marketing_consent: false)
    with_lock do
      next false if confirmed?

      now = Time.current
      consenting = marketing_consent && marketing_choice_offered?
      label = consent_button_label if consenting
      shown_ids = published_registrations.ids
      update!(confirmed_at: now, community_announcement_withheld_at: (now unless announceable_first_name?))
      CalendarSubscription.offer_to(email, name: name, voice: voice)
      registrations.each(&:confirm!)
      grant_marketing_consents(registrations.select { |registration| shown_ids.include?(registration.id) }, label, now) if consenting
      true
    end
  end

  # La case a été cochée ET la page a de quoi la porter : des cafés
  # affichés (`published_registrations`, ceux que la personne voit) ou,
  # à défaut, le « préviens-moi ».
  def marketing_choice_offered?
    marketing_box_checked? && (published_registrations.exists? || notify_next?)
  end

  # Accord porté par la demande elle-même (« préviens-moi » sans café).
  # Preuve figée : date, version de la politique et libellé du bouton ; la
  # provenance (`source`) et la page (/confirmer) sont celles, immuables, de
  # la demande.
  def grant_marketing_consent!(label: nil, now: Time.current)
    return false if marketing_consent? || marketing_consent_withdrawn?

    update!(marketing_consent: true, marketing_consent_at: now,
            marketing_consent_policy_version: PrivacyPolicy::VERSION, marketing_consent_label: label,
            marketing_withdrawal_token: SecureRandom.urlsafe_base64(24))
  end

  # Mail du message aux co-organisateurs, UNE fois par demande : la
  # confirmation et la tâche de rattrapage peuvent l'appeler sans doublon.
  # Sans destinataire configuré ou sans message à transmettre, sans effet.
  # La date est posée AVANT la mise en file : la file vit dans une autre base,
  # hors de cette transaction ; dans l'autre ordre, un échec de l'écriture
  # laisserait un mail parti et une demande que le rattrapage renverrait.
  def notify_team!
    recipient = CoOrganizerMailer.recipient
    return false unless recipient

    with_lock do
      next false if team_notified_at? || !team_message?

      update!(team_notified_at: Time.current)
      CoOrganizerMailer.message_received(self, to: recipient).deliver_later
      true
    end
  end

  # Le relais WhatsApp a posté le message : idempotent, la première date reste.
  def mark_whatsapp_relayed!(now: Time.current)
    with_lock { update!(whatsapp_relayed_at: now) unless whatsapp_relayed_at? }
  end

  def mark_community_announced!(now: Time.current)
    with_lock { update!(community_announced_at: now) unless community_announced_at? }
  end

  # Ce que l'annonce à la communauté dit de la personne : le premier mot du
  # nom saisi, pour ne jamais publier un nom de famille (le champ porte le
  # plus souvent un prénom seul ; « Jean-Pierre » reste entier). Normalisé
  # NFKC : un accent décomposé redevient une lettre, une forme pleine chasse
  # sa lettre ordinaire.
  def first_name
    name.to_s.unicode_normalize(:nfkc).split.first
  end

  # Faux = prénom retenu : l'inscription n'est pas annoncée à la communauté,
  # le groupe des co-organisateurs la reçoit comme les autres.
  def announceable_first_name?
    ANNOUNCEABLE_FIRST_NAME.match?(first_name.to_s)
  end

  def team_message?
    from_tartiflette? && confirmed? && message.present?
  end

  def withdraw_marketing_consent!(now: Time.current)
    return false unless marketing_consent?

    update!(marketing_consent: false, marketing_consent_withdrawn_at: now, marketing_withdrawal_token: nil)
  end

  # Jeton du lien « ne plus être recontacté·e » de la page confirmée : celui
  # de la demande, ou d'un de ses cafés consentis (le retrait vaut pour la
  # personne entière).
  def marketing_withdrawal_token_for_page
    return marketing_withdrawal_token if marketing_consent?

    registrations.find(&:marketing_consent?)&.marketing_withdrawal_token
  end

  def marketing_consent_withdrawn?
    marketing_consent_withdrawn_at.present?
  end

  def crm_marketing_consent_pending?
    marketing_consent? && crm_marketing_consent_pushed_at.nil?
  end

  # Le retrait part dès qu'un consentement a existé, qu'il ait été marqué
  # poussé ou non : le CRM a pu l'enregistrer puis
  # répondre 502. Comme pour les inscriptions, un retrait sans consentement
  # côté CRM n'est qu'une trace de plus.
  def crm_withdrawal_pending?
    marketing_consent_withdrawn? && crm_withdrawal_pushed_at.nil?
  end

  def crm_work_pending?
    !crm_pushed? || crm_marketing_consent_pending? || crm_withdrawal_pending?
  end

  def confirmed?
    confirmed_at.present?
  end

  def crm_pushed?
    pushed_to_crm_at.present?
  end

  def from_tartiflette?
    source == TARTIFLETTE_SOURCE
  end

  # Ce que la soumission a dit d'elle-même, pour les notes CRM.
  def detail_lines
    [
      ("Provenance : #{source}" if source),
      ("Profil : #{profile}" if profile),
      ("Message : #{message}" if message)
    ].compact
  end

  # Inscriptions aux cafés encore publiés, dans l'ordre des dates.
  def published_registrations
    registrations.joins(:webinar).merge(Webinar.published).order("webinars.starts_at").includes(:webinar)
  end

  # Tonalité du mail et des pages de la demande : celle de l'émission si
  # tous les cafés en sont, sinon le défaut. « Préviens-moi du prochain »
  # vise le prochain Café IA : il compte comme une inscription à un café.
  def voice
    voices = published_registrations.map { |registration| registration.webinar.voice }
    voices << "cafe_ia" if notify_next?
    Voice.common(voices)
  end

  def inspect
    "#<RegistrationRequest id=#{id} email=#{email.inspect} source=#{source.inspect} " \
      "notify_next=#{notify_next.inspect} confirmed_at=#{confirmed_at.inspect} " \
      "marketing_consent=#{marketing_consent.inspect}>"
  end

  private

  # Provenance figée dans la preuve : `api` si la soumission ne l'a pas dite.
  def grant_marketing_consents(shown, label, now)
    return grant_marketing_consent!(label: label, now: now) if shown.empty?

    shown.each do |registration|
      registration.grant_marketing_consent!(source: source || "api", path: "/confirmer", request: self,
                                            label: label, now: now)
    end
  end

  # Libellé du bouton d'accord tel que la page /confirmer l'a affiché, dans
  # la tonalité de la demande : calculé à l'accord,
  # avant que la confirmation ne change ce que la page montre.
  def consent_button_label
    Voice.t("registration_requests.show.button_with_marketing", voice: voice)
  end

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end

  def ensure_token
    self.token = SecureRandom.urlsafe_base64(24) if token.blank?
  end
end
