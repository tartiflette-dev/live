class User < ApplicationRecord
  # Compte Pocket ID OIDC : animateur (`animateur?`) ou spectateur des
  # replays.
  #
  # Rapprochement OIDC : PAR `oidc_sub` UNIQUEMENT.
  # Le sub est immuable côté Pocket ID ; l'email peut changer (mail pro
  # renommé, correction typo) sans casser la session — voir
  # `SessionsController#oidc_callback`.
  #
  # `email` est présent et unique (unicité case-insensitive via l'index
  # `index_users_on_lower_email`), mais il ne sert JAMAIS de clé de
  # rapprochement OIDC. L'email reste la clé des *invitations* de
  # co-animateur (WebinarHost) : l'animateur du projet désigne qui il
  # veut par email, le rattachement User se fait au login.
  #
  # Groupes OIDC : rafraîchis à chaque callback,
  # servent à décider le rôle `:project_host` (droits étendus sur TOUT
  # live). Fallback liste d'emails ENV géré par `User#project_host?`.
  #
  # Durcissement sécurité : les groupes ont une FENÊTRE
  # DE FRAÎCHEUR (`oidc_groups_fetched_at`, défaut 12 h, ENV
  # `LIVE_PROJECT_HOSTS_FRESH_WINDOW_SECONDS`). Un retrait du groupe
  # `live-animateurs` côté Pocket ID expire mécaniquement les droits
  # au plus tard après cette fenêtre, sans attendre un redémarrage ni
  # une purge manuelle (défense fail-open-state-drift). `admin?` et
  # `LIVE_PROJECT_HOSTS` restent lus À CHAQUE requête (pas de cache
  # Ruby : `current_user` recharge l'User à chaque hit).
  #
  # `email_verified` est le claim OIDC du même nom — exigé par la
  # résolution `:guest_host` (défense broken-authentication : sinon un
  # compte dont l'email égale celui d'un invité hériterait des droits
  # par simple collision d'adresse).
  DEFAULT_PROJECT_HOST_FRESH_WINDOW = 12.hours

  has_one :device_preference, as: :owner, dependent: :destroy

  before_validation :normalize_email

  validates :email,
    presence: true,
    uniqueness: { case_sensitive: false },
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :oidc_sub, presence: true, uniqueness: true

  scope :admins, -> { where(admin: true) }

  # Retrouve OU crée l'user pour un `sub` OIDC donné, sans jamais consulter
  # l'email comme clé. Idempotent — si le même sub revient avec un email
  # différent, on met à jour l'email LOCAL (le sub reste roi) mais on ne
  # crée aucun doublon.
  #
  # `groups` est passé facultativement : si Pocket ID n'émet pas le claim,
  # ou si le scope n'inclut pas `groups`, on garde la valeur existante
  # plutôt que de l'effacer (évite qu'un déploiement sans claim coupe
  # soudain les droits project_host).
  #
  # @return [User]
  #
  # Invariant d'identité : le `sub` OIDC est la clé UNIQUE. L'email
  # peut être renommé côté Pocket ID (`user.update!(email:)`) mais ce
  # changement NE RATTACHE JAMAIS un nouveau sub à un user existant
  # — l'index unique `LOWER(email)` fait péter en RecordInvalid si on
  # tentait un `create!` avec un email déjà pris par un autre sub
  # (défense broken-authentication : un sub étranger ne s'empare jamais
  # d'un compte par son email).
  def self.find_or_create_by_oidc!(sub:, email:, groups: nil, email_verified: nil)
    user = find_by(oidc_sub: sub)
    if user
      # Le mail Pocket ID peut avoir changé — on l'actualise localement,
      # mais ce n'est PAS ce qui identifie l'user. On remet aussi
      # `email_verified_for` en phase pour que la paire reste
      # auto-cohérente (sinon un changement d'email côté Pocket ID
      # garderait l'ancien `email_verified_for` et bloquerait l'invité).
      if email.present? && user.email.casecmp(email) != 0
        user.update!(email: email)
      end
      if groups.is_a?(Array)
        # Horodatage de fraîcheur systématiquement rafraîchi QUAND les
        # groupes nous parviennent — critère anti fail-open-state-drift.
        user.update!(oidc_groups: groups, oidc_groups_fetched_at: Time.current)
      end
      unless email_verified.nil?
        user.update!(
          email_verified: email_verified == true,
          email_verified_for: email_verified == true ? user.email : nil
        )
      end
      user
    else
      attrs = { email: email, oidc_sub: sub }
      if groups.is_a?(Array)
        attrs[:oidc_groups] = groups
        attrs[:oidc_groups_fetched_at] = Time.current
      end
      unless email_verified.nil?
        attrs[:email_verified] = (email_verified == true)
        attrs[:email_verified_for] = email_verified == true ? email : nil
      end
      create!(**attrs)
    end
  end

  # Rôle « animateur du projet » :
  # droits étendus sur TOUT live (créer, voir/gérer tous les webinaires,
  # scène, enregistrements, transcripts, inscrits).
  #
  # Trois voies de désignation, par priorité :
  #   1. appartenance au groupe OIDC nommé par ENV `LIVE_ANIMATEURS_GROUP`,
  #      sans défaut : un nom connu d'avance serait le premier revendiqué
  #      sur un fournisseur qui laisse ses comptes choisir leurs groupes.
  #      Sans cette variable, aucun groupe ne donne ce rôle. Le claim
  #      `groups` doit être demandé côté client OIDC (scope groups) ET
  #      autorisé par le fournisseur (allowed_user_groups sur le client
  #      Pocket ID).
  #   2. email dans ENV `LIVE_PROJECT_HOSTS` (séparé par virgule) — voie
  #      de SECOURS si Pocket ID n'émet pas le claim groupe (geste
  #      opérateur immédiat, pas de redémarrage de session OIDC). Exige une
  #      adresse vérifiée et actuelle (`email_verified_and_fresh?`).
  #   3. `admin: true` (compte de secours historique, inchangé).
  #
  # Les co-animateurs INVITÉS (WebinarHost) ne passent PAS par ce
  # prédicat — leur droit est PORTÉ par le webinaire (voir
  # Webinar#role_for).
  #
  # Évalué à CHAQUE appel (pas de memoization) — `current_user` recharge
  # l'User à chaque requête, ENV et `admin?` sont lus en direct.
  def project_host?
    admin? || in_project_host_env_allowlist? || in_project_host_group_fresh?
  end

  # Un droit d'animation, quel qu'il soit : animateur du projet, ou
  # propriétaire ou co-animateur invité (WebinarHost, email vérifié) d'au
  # moins un webinaire — les mêmes voies que `Webinar.where_animated_by`.
  # Tout autre compte est un SPECTATEUR : il voit les replays, rien d'autre
  # (Authenticatable#authenticate_animateur!). Un compte arrivé sans aucun
  # groupe OIDC est donc spectateur, jamais animateur. Évalué à chaque appel.
  def animateur?
    project_host? || Webinar.where_animated_by(self).exists?
  end

  # Packs (index, new, create) : animateur du projet, ou propriétaire d'au
  # moins un webinaire. Un compte connecté sans autre rôle (co-animateur
  # invité, compte `live-invites` du lien animateur) n'y a pas accès.
  def can_manage_packs?
    project_host? || Webinar.hosted_by(oidc_sub).exists?
  end

  # Nom de l'animateur dans la discussion du direct (Message), faute de
  # nom affiché sur User : la partie locale de son email Pocket ID, jamais
  # l'adresse complète.
  def chat_alias
    normalized_email.split("@").first
  end

  # Email downcase utilisé pour la comparaison WebinarHost.
  def normalized_email
    email.to_s.strip.downcase
  end

  # Email réellement VÉRIFIÉ (claim OIDC) ET actuel. Si `email_verified`
  # est posé mais `email_verified_for` ne correspond plus à `email`
  # (changement latéral de l'email en DB sans refresh OIDC), on
  # considère que l'email N'EST PAS vérifié pour la session courante
  # — défense contre la broken-authentication.
  def email_verified_and_fresh?
    return false unless email_verified?

    stored_for = email_verified_for.to_s.strip.downcase
    stored_for.present? && stored_for == normalized_email
  end

  # Les groupes OIDC sont-ils encore dans la fenêtre de fraîcheur ?
  # Mécanique DRIFT : si le user a été retiré du groupe `live-animateurs`
  # sur Pocket ID, ses droits « projet » cessent au plus tard après
  # expiration de la fenêtre (sans redéploiement ni purge manuelle).
  def oidc_groups_fresh?
    return false if oidc_groups_fetched_at.blank?

    oidc_groups_fetched_at > project_host_fresh_window.ago
  end

  private

  def project_host_fresh_window
    seconds = ENV["LIVE_PROJECT_HOSTS_FRESH_WINDOW_SECONDS"].to_i
    seconds.positive? ? seconds.seconds : DEFAULT_PROJECT_HOST_FRESH_WINDOW
  end

  def in_project_host_group_fresh?
    return false unless oidc_groups_fresh?

    group = ENV["LIVE_ANIMATEURS_GROUP"].to_s.strip
    return false if group.empty?

    Array(oidc_groups).any? { |g| g.to_s == group }
  end

  # Liste de secours : l'adresse seule ne suffit pas, le compte doit porter
  # une adresse vérifiée par Pocket ID et toujours actuelle
  # (`email_verified_and_fresh?`) — sans quoi un compte dont l'adresse a été
  # éditée prendrait les droits « projet » d'une adresse qu'il ne possède pas.
  def in_project_host_env_allowlist?
    return false unless email_verified_and_fresh?

    list = ENV["LIVE_PROJECT_HOSTS"].to_s.split(",").map { |e| e.strip.downcase }.reject(&:empty?)
    list.include?(normalized_email)
  end

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end
end
