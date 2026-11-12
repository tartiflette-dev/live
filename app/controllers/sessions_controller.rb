class SessionsController < ApplicationController
  # Pages animateur (connexion OIDC) : garde navigateur :modern.
  include AnimateurBrowserPolicy

  # Écran de connexion hors-session : layout force (aucun chrome).
  layout "force"

  # Auth animateur — OpenID Connect, plus la connexion de développement
  # hors production (lib/dev_login.rb).
  #
  # Flow :
  #   GET  /sign_in                     → écran : bouton OIDC, formulaire de dev
  #   POST /auth/pocket_id              → OmniAuth request phase (CSRF-safe via
  #                                       omniauth-rails_csrf_protection)
  #   GET  /auth/pocket_id/callback     → oidc_callback : rapprochement par oidc_sub
  #   GET  /auth/failure                → oidc_failure  : redirect /sign_in + alerte
  #   POST /dev_login                   → dev_login : 404 si DevLogin est inactif
  #                                       ou l'origine non admise
  #   DELETE /sign_out                  → reset session
  #
  # Pas de magic link ni de mot de passe : en production, l'OIDC est la seule
  # voie.

  # Avant la vérification CSRF : inactive ou hors des origines admises, la
  # route répond 404 et rien d'autre.
  prepend_before_action :require_dev_login, only: :dev_login

  def new
    # Écran /sign_in — vue sessions/new (bouton POST vers /auth/pocket_id,
    # l'omniauth-rails_csrf_protection exige POST).
  end

  def destroy
    reset_session
    # Retour à l'écran de connexion : la déconnexion ne vise aucune page
    # animateur.
    redirect_to sign_in_path, notice: "Déconnecté."
  end

  # ------------------------------------------------------------
  # OIDC callback — rapprochement PAR `oidc_sub` UNIQUEMENT.
  #
  # Jamais de lookup par email. Un mail change chez le fournisseur ?
  # Le `sub` est stable, la session reste ouverte sur le MÊME user. Un
  # `sub` inconnu ? Création (l'animateur est provisionné côté fournisseur,
  # par ses groupes autorisés).
  # ------------------------------------------------------------
  def oidc_callback
    auth = request.env["omniauth.auth"]
    if auth.blank?
      redirect_to sign_in_path, alert: "Authentification Pocket ID échouée." and return
    end

    sub = auth["uid"].to_s.presence
    email = auth.dig("info", "email").to_s.strip.downcase.presence
    if sub.blank? || email.blank?
      redirect_to sign_in_path, alert: "Réponse Pocket ID incomplète (email/sub manquant)." and return
    end
    # Les comptes de la connexion de développement portent ce préfixe : un
    # fournisseur qui l'émettrait ne doit jamais les rouvrir.
    if sub.start_with?(DevLogin::SUB_PREFIX)
      Rails.logger.warn("[OIDC] refus d'un sub réservé à la connexion de développement")
      redirect_to sign_in_path, alert: "Authentification Pocket ID échouée." and return
    end

    # Claim `groups` Pocket ID — scope `groups` (cf. omniauth.rb). Omis =
    # on ne touche PAS aux groupes stockés (voir User.find_or_create_by_oidc!),
    # pour que le fallback ENV `LIVE_PROJECT_HOSTS` reste suffisant si
    # Pocket ID n'émet pas encore le claim.
    groups = extract_groups(auth)

    # Claim OIDC `email_verified` — défense broken-authentication. Un email NON vérifié n'identifie personne : la résolution
    # :guest_host (Webinar#role_for) refusera l'invitation par email.
    # Absence du claim ou valeur falsy → `false` (fail-closed).
    email_verified = extract_email_verified(auth)

    user =
      begin
        User.find_or_create_by_oidc!(sub: sub, email: email, groups: groups, email_verified: email_verified)
      rescue ActiveRecord::RecordInvalid
        # Un sub INCONNU tombe sur un email DÉJÀ pris (avec un autre sub).
        # Refuser plutôt que rapprocher par email — invariant de sécurité
        # spec (jamais de "prise de compte" par mail). Contacter l'admin
        # (le sub a probablement été réémis par le fournisseur, ou un
        # doublon y existe à investiguer).
        Rails.logger.warn("[OIDC] refus rapprochement par email (sub=#{sub})")
        redirect_to sign_in_path, alert: "Compte animateur en conflit — contactez l'administrateur." and return
      end

    sign_in_and_redirect(user)
  end

  def oidc_failure
    # Paramètres de la query, donc fournis par n'importe quel appelant :
    # tronqués et cités (`inspect` échappe retours à la ligne et caractères
    # de contrôle), ils ne peuvent pas forger une ligne de journal.
    message = params[:message].to_s.first(100).inspect
    strategy = params[:strategy].to_s.first(40).inspect
    Rails.logger.warn("[OIDC] failure: #{message} (strategy=#{strategy})")
    redirect_to sign_in_path, alert: "Authentification Pocket ID échouée."
  end

  # Connexion de développement (lib/dev_login.rb) : l'adresse saisie suffit. Le
  # compte, vérifié d'office, est administrateur pour pouvoir créer un
  # webinaire ; son `oidc_sub` porte DevLogin::SUB_PREFIX. Une adresse déjà
  # prise par un compte OIDC est refusée, comme au callback.
  def dev_login
    email = params[:email].to_s.strip.downcase
    unless email.match?(URI::MailTo::EMAIL_REGEXP)
      redirect_to sign_in_path, alert: t("chrome.login_dev_invalid") and return
    end

    user = User.find_or_create_by_oidc!(sub: "#{DevLogin::SUB_PREFIX}#{email}", email: email, email_verified: true)
    user.update!(admin: true) unless user.admin?
    sign_in_and_redirect(user)
  rescue ActiveRecord::RecordInvalid
    redirect_to sign_in_path, alert: "Compte animateur en conflit — contactez l'administrateur."
  end

  private

  def require_dev_login
    head :not_found unless DevLogin.available_to?(request.env)
  end

  def sign_in_and_redirect(user)
    # Lu AVANT `reset_session`, qui l'effacerait (Authenticatable le pose
    # avant la redirection vers /sign_in). Chemin interne seulement
    # (`request.fullpath`), donc pas de redirection ouverte.
    return_to = session[:return_to].presence
    reset_session
    session[:user_id] = user.id
    # Horodatage de la connexion — borne la fenêtre de validité d'une
    # session animateur (défense fail-open-state-drift : au-delà de
    # `User::DEFAULT_PROJECT_HOST_FRESH_WINDOW`, les droits « projet »
    # issus du groupe OIDC caché cessent de compter, cf. Authenticatable).
    session[:signed_in_at] = Time.current.to_i

    invitation_token = HostInvitationCookie.read(cookies)
    return accept_host_invitation(user, invitation_token) if invitation_token

    return redirect_to(return_to || webinars_path, notice: "Connexion réussie.") if user.animateur?

    redirect_to spectator_landing(return_to), notice: "Connexion réussie."
  end

  # Compte sans droit d'animation : il revient sur le replay d'où il s'est
  # connecté, sinon sur la liste des replays — jamais sur une page animateur
  # qui lui répondrait 404.
  def spectator_landing(return_to)
    return_to.to_s.match?(%r{\A/(replays|w/[^/?]+/replay)(\z|[/?])}) ? return_to : replays_path
  end

  # Lien animateur (/a) : la connexion partie de la page d'invitation revient
  # avec son jeton (HostInvitationCookie), effacé dans tous les cas. Email non
  # vérifié : retour sur la page du lien, d'où la personne se reconnecte une
  # fois son adresse vérifiée (l'invitation n'est pas consommée).
  def accept_host_invitation(user, token)
    HostInvitationCookie.forget(cookies)
    invitation = HostInvitation.find_by_token(token)

    case invitation ? invitation.accept(user) : :unusable
    when :accepted
      redirect_to webinar_path(invitation.webinar),
                  notice: "Tu co-animes « #{invitation.webinar.title} » : scène et régie ci-dessous."
    when :already_animator
      redirect_to webinar_path(invitation.webinar), notice: "Tu animes déjà « #{invitation.webinar.title} »."
    when :email_unverified
      redirect_to host_invitation_path(t: token),
                  alert: "Vérifie ton adresse dans ton compte #{Brand.organization} puis reconnecte-toi."
    when :claimed_by_other
      redirect_to landing_for(user),
                  alert: "Cette adresse est déjà liée à un autre compte #{Brand.organization} pour ce café : contacte l'organisateur."
    when :unusable
      redirect_to landing_for(user),
                  alert: "Ce lien animateur n'est plus valable (expiré, épuisé ou révoqué) : demande un nouveau lien à l'organisateur."
    end
  end

  # Page d'arrivée qui s'affiche pour ce compte : ses webinaires s'il anime,
  # sinon les replays (la zone animateur lui répondrait 404, alerte perdue).
  def landing_for(user)
    user.animateur? ? webinars_path : replays_path
  end

  # Extraction tolérante du claim `groups` Pocket ID.
  #
  # omniauth-openid_connect expose le JSON userinfo via `extra.raw_info`.
  # Le claim peut être un array de strings, un string unique, ou absent
  # (scope non demandé / userinfo partiel). On retourne :
  #   • Array<String> si le claim est présent (filtre les blank)
  #   • nil           si absent (préserver l'existant, cf. User.find_or_create_by_oidc!)
  def extract_groups(auth)
    raw = auth.dig("extra", "raw_info", "groups")
    return nil if raw.nil?

    Array(raw).map { |g| g.to_s.strip }.reject(&:empty?)
  end

  # Extraction stricte du claim OIDC `email_verified` (défense broken-
  # authentication). Deux emplacements possibles selon omniauth :
  # `info.email_verified` (si mappé par la stratégie) OU
  # `extra.raw_info.email_verified` (JSON userinfo brut). Absence /
  # falsy / string "false" → `false` (fail-closed).
  def extract_email_verified(auth)
    [ auth.dig("info", "email_verified"), auth.dig("extra", "raw_info", "email_verified") ]
      .any? { |v| v == true || v.to_s.downcase == "true" }
  end
end
