# Journal des recherches des spectateurs dans les replays (ReplaySearch) :
# requêtes les plus fréquentes, requêtes sans résultat (la demande qu'aucun
# café ne couvre encore) et dernières recherches avec leur auteur, sur une
# période au choix.
module Animation
  class SearchesController < BaseController
    PERIODS = { "30" => 30.days, "90" => 90.days, "365" => ReplaySearch::RETENTION }.freeze
    RECENT_LIMIT = 50

    def index
      @period = PERIODS.key?(params[:periode]) ? params[:periode] : "90"
      since = PERIODS.fetch(@period).ago
      @frequent = ReplaySearch.summaries(since: since)
      @unanswered = ReplaySearch.summaries(since: since, unanswered: true)
      @recent = ReplaySearch.where(created_at: since..).includes(:user, :registration)
                            .order(created_at: :desc).limit(RECENT_LIMIT)
    end
  end
end
