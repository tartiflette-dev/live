class HostInvitation < ApplicationRecord
  # Lien animateur : un lien à partager qui fait d'une personne un co-animateur
  # du webinaire après sa connexion Pocket ID, email vérifié. L'URL publique
  # est /a?t=<token> (HostInvitationsController) ; l'acceptation a lieu au
  # retour de Pocket ID (SessionsController#oidc_callback).
  #
  # Usages limités, expiration (30 jours au plus), révocation : un lien qui
  # circule ne donne pas un droit qui court sans fin. Chaque acceptation crée un WebinarHost
  # verrouillé sur le `sub` du compte qui l'a accepté : c'est lui, et lui
  # seul, qui porte le droit d'animer. Révoquer le lien ne retire
  # pas les co-animateurs déjà entrés (même règle que le lien intervenant
  # partagé) : on les retire un par un dans la liste.
  #
  # `signup_url` : lien d'un jeton d'inscription Pocket ID, créé à la main par
  # l'administrateur dans l'admin Pocket ID (aucun appel à l'API admin depuis live). Seul
  # un lien vers l'émetteur OIDC de live est accepté.
  self.filter_attributes += [ :token, :signup_url ]

  DEFAULT_MAX_USES = 3
  MAX_USES_RANGE = 1..20
  # Expiration par défaut : lendemain de la fin prévue du webinaire, au plus
  # tard dans 7 jours. Expiration choisie : 30 jours au plus après la création.
  GRACE_AFTER_PLANNED_END = 1.day
  MAX_DEFAULT_LIFETIME = 7.days
  MAX_LIFETIME = 30.days

  belongs_to :webinar

  before_validation :normalize_signup_url
  before_validation :assign_token_and_expiry, on: :create

  validates :token, presence: true, uniqueness: true
  validates :created_by_sub, presence: true
  validates :max_uses, numericality: { only_integer: true, in: MAX_USES_RANGE }
  validates :expires_at, presence: true
  # Règles de SAISIE : vérifiées quand la valeur change, pas à chaque
  # écriture. Un changement d'OIDC_ISSUER, ou le temps qui passe,
  # ne rend pas invalide un lien déjà créé.
  validate :expiry_within_window, if: :will_save_change_to_expires_at?
  validates :signup_url, length: { maximum: 2048 }
  validate :signup_url_on_pocket_id, if: :will_save_change_to_signup_url?

  def self.default_expiry_for(webinar, now: Time.current)
    [ webinar.planned_ends_at + GRACE_AFTER_PLANNED_END, now + MAX_DEFAULT_LIFETIME ].min
  end

  # Lookup par jeton opaque. C'est l'index unique (find_by) qui compare, et
  # pas en temps constant : la protection contre la devinette tient aux
  # 192 bits aléatoires du jeton. Le secure_compare revérifie seulement
  # l'égalité exacte côté Ruby, indépendamment de la collation de la base
  # (même forme que Webinar.find_by_active_share_token). Ne filtre PAS les
  # liens inutilisables : la page publique distingue « inconnu » (404) de
  # « plus valable » (410).
  # @return [HostInvitation, nil]
  def self.find_by_token(token)
    return nil unless token.is_a?(String) && token.present?

    candidate = find_by(token: token)
    return nil unless candidate && ActiveSupport::SecurityUtils.secure_compare(candidate.token, token)

    candidate
  end

  def remaining_uses
    max_uses - uses_count
  end

  # @return [Symbol] :revoked, :exhausted, :expired, :ended ou :active
  def status(now = Time.current)
    if revoked_at? then :revoked
    elsif remaining_uses <= 0 then :exhausted
    elsif expires_at <= now then :expired
    elsif webinar.ended? then :ended
    else :active
    end
  end

  def usable?(now = Time.current)
    status(now) == :active
  end

  # Sans revalidation : couper un lien ne doit jamais échouer parce qu'une
  # règle de saisie a changé depuis sa création.
  def revoke!
    update_columns(revoked_at: Time.current, updated_at: Time.current) unless revoked_at?
  end

  # Accepte l'invitation pour `user`, qui vient de se connecter.
  #
  # Résultats :
  #   :accepted          WebinarHost créé, verrouillé sur le sub du compte ;
  #                      un usage consommé
  #   :already_animator  le compte anime déjà ce webinaire (propriétaire,
  #                      animateur du projet, co-animateur) : rien n'est
  #                      consommé. Une désignation par email encore libre est
  #                      rattachée au compte au passage (Webinar#role_for, ou
  #                      sous le verrou si elle vient d'être posée).
  #   :email_unverified  email non vérifié côté Pocket ID : rien n'est consommé
  #   :claimed_by_other  l'adresse est déjà liée à un AUTRE compte sur ce
  #                      webinaire (invariant claimed_sub)
  #   :unusable          lien révoqué, expiré, épuisé, ou direct déjà terminé
  #
  # Le contrôle des usages et leur incrément ont lieu sous le verrou de la
  # ligne (transaction IMMEDIATE sous SQLite) : deux acceptations simultanées
  # ne dépassent jamais `max_uses`.
  def accept(user)
    return :already_animator if webinar.animated_by?(user)
    return :email_unverified unless user.email_verified_and_fresh?

    with_lock do
      next :unusable unless usable?

      host = webinar.webinar_hosts.find_by("LOWER(email) = ?", user.normalized_email)
      next claim_designation(host, user) if host

      webinar.webinar_hosts.create!(email: user.normalized_email, invited_by_sub: created_by_sub,
                                    claimed_sub: user.oidc_sub)
      increment!(:uses_count)
      :accepted
    end
  end

  private

  # Désignation par email trouvée sous le verrou : un gestionnaire l'a posée
  # entre la vérification des rôles et le verrou. Libre, elle revient à ce
  # compte, comme le ferait Webinar#role_for ; liée à un autre compte, elle
  # lui reste.
  def claim_designation(host, user)
    return :claimed_by_other if host.claimed_sub.present? && host.claimed_sub != user.oidc_sub

    host.update!(claimed_sub: user.oidc_sub) if host.claimed_sub.blank?
    :already_animator
  end

  def assign_token_and_expiry
    self.token ||= SecureRandom.urlsafe_base64(24)
    self.expires_at ||= self.class.default_expiry_for(webinar) if webinar
  end

  def expiry_within_window
    return if expires_at.nil?

    if !expires_at.future?
      errors.add(:expires_at, :not_in_future, message: "doit être dans le futur")
    elsif expires_at > (created_at || Time.current) + MAX_LIFETIME
      errors.add(:expires_at, :too_far, message: "doit être dans les 30 jours")
    end
  end

  def normalize_signup_url
    self.signup_url = signup_url.to_s.strip.presence
  end

  def signup_url_on_pocket_id
    return if signup_url.blank?

    issuer = pocket_id_issuer
    if issuer.nil?
      errors.add(:signup_url, :no_oidc_provider, message: "exige un fournisseur OIDC configuré (OIDC_ISSUER)")
    elsif !OidcProvider.link?(signup_url)
      errors.add(:signup_url, :not_pocket_id, message: "doit être un lien de #{issuer.host}")
    end
  end

  # Lu à chaque validation (OidcProvider, source unique avec OmniAuth et la
  # CSP) ; nil sans fournisseur configuré.
  def pocket_id_issuer
    issuer = OidcProvider.issuer
    URI.parse(issuer) if issuer
  end
end
