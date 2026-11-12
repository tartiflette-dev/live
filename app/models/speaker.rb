class Speaker < ApplicationRecord
  belongs_to :webinar, inverse_of: :speakers
  # Inscription de l'intervenant entré par le lien participants privé : son
  # contact, celui de ses interventions (discussion, transcription
  # `speaker-<id>`), et la cible de la cascade du retrait
  # (ParticipantModeration). Posée SEULEMENT sur un lien PROUVÉ par la boîte
  # mail : cookie d'une inscription confirmée par le lien
  # de son mail (InvitationEntry), ou clic de la personne dans le mail qui
  # nomme l'intervention (`link_to_declared_registration!`). Sinon l'adresse
  # saisie reste `declared_email`, et rien n'est attribué à la fiche de
  # quiconque : ni CRM, ni interventions, ni cascade du retrait.
  # Absente aussi pour un intervenant ajouté par l'animation, et pour ceux
  # entrés par le lien partagé quand il ne demandait pas d'adresse.
  belongs_to :registration, optional: true, inverse_of: :speakers
  # Successeur créé par #replace! : même personne, nouvelle identité LiveKit.
  belongs_to :replaced_by, class_name: "Speaker", optional: true
  has_one :device_preference, as: :owner, dependent: :destroy

  attr_readonly :token, :webinar_id
  self.filter_attributes += [ :token, :link_token ]

  before_validation :normalize_name
  before_validation :normalize_email
  before_validation :ensure_token, on: :create
  before_validation :ensure_link_token, on: :create

  validates :name, presence: true, length: { maximum: 120 }
  validates :token, presence: true, uniqueness: true, format: { with: /\A[A-Za-z0-9_-]{32}\z/ }
  # Facultative : sert au seul mail de publication de l'épisode
  # (EpisodeNotification), saisie par l'animation.
  validates :email, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
  # Adresse saisie au lien privé, NON vérifiée : elle ne sert qu'à demander
  # le rattachement à la personne (RegistrationMailer#speaker_link), jamais au
  # CRM ni au mail de publication.
  validates :declared_email, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
  validates :link_token, uniqueness: true, allow_nil: true
  validate :registration_belongs_to_webinar

  scope :active, -> { where(revoked_at: nil) }
  scope :removed_from_room, -> { where.not(room_removed_at: nil) }
  scope :reachable_by_email, -> { active.where.not(email: nil) }
  # Intervenants actifs que la publication d'un épisode ne préviendra pas
  # (EpisodeNotification n'écrit qu'à `reachable_by_email`).
  scope :unreachable_by_email, -> { active.where(email: nil) }

  # Révocation (propriétaire, page du webinaire) : le lien meurt, rien de plus.
  def revoke!
    with_lock do
      update!(revoked_at: Time.current) if revoked_at.nil?
    end
  end

  # Régénère le lien d'accès. Dans une transaction : ce Speaker est révoqué
  # et un nouveau reprend la personne (nom, adresses, inscription, lien de
  # rattachement). Le jeton et l'identité LiveKit `speaker-<id>` sont neufs.
  # L'inscription ne reste pas sur l'ancien : un retrait de son identité
  # LiveKit ne doit pas retirer la personne du successeur. Le lien de
  # rattachement garde son échéance d'origine (`link_issued_at`), même
  # expiré — pas une nouvelle fenêtre de 14 jours. Les préférences de
  # périphériques restent sur l'ancien enregistrement.
  # @return [Speaker, nil] le successeur, ou nil si déjà révoqué
  def replace!
    with_lock do
      next nil if revoked_at?

      carried_link = link_token
      issued_at = carried_link ? (link_issued_at || created_at) : nil
      carried_registration = registration
      update!(link_token: nil) if carried_link
      successor = webinar.speakers.create!(successor_attributes(carried_link, issued_at, carried_registration))
      update!(revoked_at: Time.current, replaced_by: successor, registration_id: nil)
      successor
    end
  end

  # Le lien de rattachement vit 14 jours après l'entrée :
  # un mail retrouvé plus tard ne rattache plus rien.
  LINK_TTL = 14.days

  def self.find_by_link_token(token)
    return nil unless token.is_a?(String) && token.present?

    find_by(link_token: token)
  end

  # Rattachement prouvé par la personne : POST du bouton de la page ouverte
  # depuis le mail envoyé à l'adresse déclarée. Usage unique. Un intervenant
  # déjà retiré depuis la régie n'est plus rattaché : le retrait ne descend
  # pas, après coup, sur l'inscription (ParticipantModeration).
  #
  # La preuve de la boîte vaut pour cet intervenant, jamais pour l'identité
  # PROVISOIRE ouverte sous cette adresse par l'accès immédiat, peut-être par
  # un tiers : celle-ci passe en pierre tombale, sans
  # être retirée, et reste au navigateur qui l'a ouverte. L'intervenant est
  # rattaché à une inscription NEUVE et non confirmée de cette adresse (double
  # opt-in intact : mail de confirmation, SpeakerLinksController), qui porte
  # désormais son attribution et la cascade du retrait. Même chose quand
  # l'inscription de l'adresse est déjà une pierre tombale.
  # @return [Symbol, false] :linked (inscription existante), :created
  #   (inscription neuve) ; false si le lien a servi ou expiré, si
  #   l'intervenant est retiré ou si l'adresse n'a plus d'inscription ni de
  #   pierre tombale à ce webinaire (purge, effacement).
  def link_to_declared_registration!
    with_lock do
      next false unless link_token && !link_expired? && room_removed_at.nil?

      registration = webinar.registrations.find_by(email: declared_email)
      registration&.with_lock { registration.retire! if registration.provisional? }
      outcome = if registration && !registration.retired?
        :linked
      elsif registration || webinar.registrations.exists?(retired_email_digest: CrmErasure.digest(declared_email))
        registration, = Registration.find_or_create_for(webinar, email: declared_email, name: name, participation: "participant")
        :created
      end
      next false unless outcome

      update!(registration: registration, link_token: nil)
      outcome
    end
  end

  def link_expired?(now = Time.current)
    (link_issued_at || created_at) < now - LINK_TTL
  end

  # Entré par le lien participants privé (InvitationEntry) : seule voie qui
  # pose une adresse déclarée ou un rattachement à une inscription. Les
  # intervenants entrés par le lien partagé avant le mail obligatoire n'en
  # gardent pas la trace.
  def entered_by_share_link?
    declared_email.present? || registration_id.present?
  end

  # Retrait depuis la régie : le lien meurt ET la
  # personne est retirée de la salle — son navigateur avec (RoomRemoval).
  # Retirer ≠ révoquer : seul ce geste pose `room_removed_at`.
  def remove_from_room!
    with_lock do
      now = Time.current
      update!(revoked_at: revoked_at || now, room_removed_at: now) if room_removed_at.nil?
    end
  end

  private

  def registration_belongs_to_webinar
    errors.add(:registration, :invalid) if registration && registration.webinar_id != webinar_id
  end

  # Attributs de personne seulement. Pas le jeton d'accès, pas le retrait
  # de salle, pas les préférences de périphériques. `link_token` repris tel
  # quel, avec l'horloge d'origine, pour qu'ensure_link_token n'en émette
  # pas un neuf (y compris quand le lien est déjà expiré).
  def successor_attributes(carried_link, issued_at, carried_registration)
    {
      name: name,
      email: email,
      declared_email: declared_email,
      registration: carried_registration,
      link_token: carried_link,
      link_issued_at: issued_at
    }
  end

  # Une ligne, sans caractère de contrôle : le nom s'affiche dans la salle et
  # nomme les fichiers et le tableau des accords du dossier d'épisode.
  def normalize_name
    self.name = name.to_s.gsub(/[[:cntrl:]]+/, " ").squish.presence
  end

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
    self.declared_email = declared_email.to_s.strip.downcase.presence
  end

  def ensure_token
    self.token = SecureRandom.urlsafe_base64(24) if token.blank?
  end

  # Adresse déclarée sans rattachement : le lien du mail qui le demande.
  def ensure_link_token
    self.link_token = SecureRandom.urlsafe_base64(24) if declared_email && registration.nil? && link_token.blank?
  end
end
