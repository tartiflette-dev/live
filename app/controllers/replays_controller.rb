# Pages des replays (ReplayAccess décide qui regarde quoi).
#
#   GET  /replays                → compte : tous les replays publiés ;
#                                  inscrit sans compte : les replays ouverts
#                                  par ce navigateur, et l'invitation à créer
#                                  un compte ; sinon la page de connexion.
#   GET  /replays?q=…            → recherche dans ces replays (transcription,
#                                  chapitres validés, thèmes : ReplaySearchIndex),
#                                  journalisée avec son auteur (ReplaySearch).
#   GET  /w/:slug/replay         → le lecteur, avec ses chapitres validés ;
#                                  `?instant=<secondes>` l'ouvre à cet instant ;
#                                  sans accès, la page de connexion (replay
#                                  publié) ou 404.
#   GET  /w/:slug/replay?t=…     → lien personnel d'un inscrit : page à
#                                  bouton, SANS effet (scanners de liens) ;
#                                  ce navigateur l'a déjà ouvert : lecteur.
#   POST /w/:slug/replay/acces   → ouvre le replay à ce navigateur (cookie),
#                                  puis le lecteur, sans jeton dans l'URL.
#
# Un replay non publié n'existe pour personne d'autre que l'animation du
# webinaire (404). La page de connexion renvoie ensuite ici
# (`session[:return_to]`, SessionsController#spectator_landing).
class ReplaysController < ApplicationController
  include ReplayAccess
  include TokenLinkPage

  SEARCH_RATE_LIMIT_STORE = RegistrationRateLimitStore.new(name: "replay_search_rate_limits")

  before_action :set_replay, only: %i[show access]

  # Une recherche coûte une requête FTS5 et une ligne de journal : 30 par
  # minute laissent largement taper, pas boucler.
  rate_limit to: 30, within: 1.minute, name: "replay-search", only: :index, if: -> { params[:q].present? },
    by: -> { current_user ? "user-#{current_user.id}" : request.remote_ip }, store: SEARCH_RATE_LIMIT_STORE,
    with: -> { head :too_many_requests }

  def index
    if user_signed_in?
      @replays = Replay.published.joins(:webinar).includes(:recording, webinar: { chapter_set: :chapters })
                       .order("webinars.starts_at DESC").to_a
    else
      @replays = Replay.published.where(webinar_id: replay_cookie_webinar_ids).includes(:recording, webinar: { chapter_set: :chapters })
                       .select { |replay| replay_registration(replay.webinar) }
                       .sort_by { |replay| -replay.webinar.starts_at.to_i }
      return render_sign_in(replays_path) if @replays.empty?

      session[:return_to] = replays_path
    end
    search if params[:q].is_a?(String) && params[:q].present?
  end

  def show
    return render_not_found unless @replay&.published? || replay_open_to?(@replay, current_user)
    return show_personal_link if params.key?(:t)

    @viewer = replay_viewer(@webinar)
    unless replay_open_to?(@replay, @viewer)
      return render_sign_in(public_webinar_replay_path(@webinar.slug, instant: start_offset&.round))
    end

    # Invitation à créer un compte : la connexion mène à tous les replays.
    session[:return_to] = replays_path if @viewer.is_a?(Registration)
    @heartbeat_url = public_webinar_replay_beats_path(@webinar.slug)
    @chapters = @webinar.chapter_set&.validated? ? @webinar.chapter_set.chapters.to_a : []
    @start_offset = start_offset
  end

  def access
    registration = @replay&.published? && replay_registration_for_token(@webinar, params[:t])
    return render_not_found unless registration

    unless remember_replay_registration(registration)
      flash[:alert] = "Ce navigateur ouvre déjà ce replay avec une autre inscription : il la garde."
    end
    redirect_to public_webinar_replay_path(@webinar.slug), status: :see_other
  end

  private

  def set_replay
    @webinar = Webinar.find_by(slug: params[:slug])
    @replay = @webinar&.replay
  end

  # Lien personnel : le jeton désigne-t-il une inscription qui ouvre ce
  # replay ? Déjà ouvert par ce navigateur : le lecteur, sans le jeton.
  def show_personal_link
    registration = replay_registration_for_token(@webinar, params[:t])
    return render_sign_in(public_webinar_replay_path(@webinar.slug), status: :not_found, invalid_link: true) unless registration
    return redirect_to(public_webinar_replay_path(@webinar.slug)) if replay_registration(@webinar) == registration

    @token = params[:t]
    render :access
  end

  # Recherche dans les replays de cette page, journalisée avec son auteur :
  # le compte connecté, sinon l'inscription du café le plus récent ouvert par
  # ce navigateur.
  def search
    @query = params[:q].squish.first(ReplaySearchIndex::QUERY_LIMIT)
    @search = ReplaySearchIndex.search(@query, @replays)
    return if @search.nil?

    author = current_user || replay_registration(@replays.first.webinar)
    ReplaySearch.record!(query: @query, author: author, results_count: @search.count) if author
  end

  # Instant demandé (`?instant=`, secondes), borné à la vidéo ; nil sans lui.
  def start_offset
    seconds = Float(params[:instant], exception: false) if params[:instant].is_a?(String)
    seconds&.clamp(0.0, @replay.duration.to_f)
  end

  # Page de connexion des replays ; la connexion Pocket ID revient sur `path`.
  def render_sign_in(path, status: :ok, invalid_link: false)
    session[:return_to] = path
    @invalid_link = invalid_link
    render :sign_in, status: status
  end

  # Page 404 de l'application (exceptions_app).
  def render_not_found
    raise ActiveRecord::RecordNotFound
  end
end
