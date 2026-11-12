module Authenticatable
  extend ActiveSupport::Concern

  included do
    helper_method :current_user, :user_signed_in?, :animateur_signed_in?
  end

  # Fenêtre maximale d'une session animateur. Défense fail-open-state-drift :
  # au-delà, la session est purgée et l'utilisateur doit
  # se reconnecter — ce qui rafraîchit nécessairement les groupes OIDC
  # (sinon le droit « animateur du projet » tombe par péremption de
  # `oidc_groups_fetched_at`). Alignée sur
  # `User::DEFAULT_PROJECT_HOST_FRESH_WINDOW` par défaut, overridable
  # par ENV `LIVE_SESSION_MAX_AGE_SECONDS`.
  def session_max_age
    seconds = ENV["LIVE_SESSION_MAX_AGE_SECONDS"].to_i
    seconds.positive? ? seconds.seconds : User::DEFAULT_PROJECT_HOST_FRESH_WINDOW
  end

  # Compte Pocket ID connecté, animateur ou spectateur des replays
  # (`animateur_signed_in?` les distingue) ; nil sans session valide.
  # N'exécute AUCUN lookup si `session[:user_id]` est absent — sur les pages
  # de la salle (aucune auth requise) le controller ne touche
  # jamais la table `users`. Purge la session si elle dépasse la fenêtre
  # maximale (voir `session_max_age`) — fail-closed.
  def current_user
    return @current_user if defined?(@current_user)

    if session[:user_id] && session_fresh?
      @current_user = User.find_by(id: session[:user_id])
    else
      reset_session if session[:user_id]
      @current_user = nil
    end
  end

  def session_fresh?
    ts = session[:signed_in_at]
    return false if ts.blank?

    Time.at(ts.to_i) > session_max_age.ago
  rescue ArgumentError, TypeError
    false
  end

  def user_signed_in?
    current_user.present?
  end

  # Compte connecté qui a un droit d'animation (User#animateur?). Lu une fois
  # par requête : le chrome et le filtre le consultent sur la même page.
  def animateur_signed_in?
    return @animateur_signed_in if defined?(@animateur_signed_in)

    @animateur_signed_in = user_signed_in? && current_user.animateur?
  end

  # Animateur du projet : droits étendus sur TOUT
  # live. Utilisé en garde des actions qui n'ont de sens que pour un
  # animateur du projet (créer un webinaire). Un invité (`guest_host`)
  # connecté reçoit 404 — jamais 403, cohérent avec le reste de l'app
  # (défense énumération).
  def authorize_project_host!
    authenticate_animateur!
    return if performed?

    head :not_found unless current_user.project_host?
  end

  # À appeler dans un `before_action` sur les controllers animateur.
  # Ce filtre ne doit JAMAIS être posé sur les controllers
  # de la salle — le spectateur du direct est anonyme par contrat.
  #
  # Compte connecté SANS droit d'animation (spectateur des replays, compte
  # arrivé sans groupe) : 404, jamais 403 ni redirection vers la connexion
  # (même défense énumération que `authorize_project_host!`).
  def authenticate_animateur!
    return head(:not_found) if user_signed_in? && !animateur_signed_in?
    return if user_signed_in?

    # Requête de fond (sondage JSON d'un onglet resté ouvert, fetch,
    # XHR) : redirection vers la connexion conservée (les clients JS
    # lisent l'`opaqueredirect` comme « session animateur expirée »),
    # mais sans `return_to` ni flash. Avec `return_to`, la connexion
    # suivante atterrissait sur ce JSON ; avec le flash, l'alerte
    # « Connexion animateur requise » s'affichait sur la prochaine page
    # vue, même publique.
    return redirect_to(sign_in_path) if background_request?

    # GET/HEAD = requêtes sûres et idempotentes → on capture pour renvoyer
    # l'user après login. On EXCLUT POST/PUT/DELETE/PATCH (rejouer un
    # side-effect après OIDC round-trip = anti-pattern). Traiter HEAD
    # comme GET satisfait aussi `brakeman VerbConfusion` (HEAD est routé
    # comme GET par Rails ; `request.get?` seul retourne false).
    if request.get? || request.head?
      session[:return_to] = request.fullpath
    end
    # Redirection VERS LE LOGIN OIDC (critère : "route animateur
    # sans session redirige vers le login OIDC"). La request phase
    # OmniAuth est en POST (omniauth-rails_csrf_protection) donc on
    # renvoie sur `/sign_in` qui affiche le bouton `button_to /auth/pocket_id`.
    redirect_to sign_in_path, alert: "Connexion animateur requise."
  end

  # Le navigateur dit lui-même s'il navigue : `Sec-Fetch-Mode: navigate`
  # pour un lien ou un formulaire, `cors`/`same-origin`/`no-cors` pour un
  # fetch (l'app ne charge pas Turbo : tout fetch est un appel de fond).
  # Sans l'en-tête (vieux client, curl, tests), seul XHR compte.
  def background_request?
    return true if request.xhr?

    mode = request.headers["Sec-Fetch-Mode"].presence
    mode.present? && mode != "navigate"
  end
end
