# Thèmes abordés à travers les cafés (ThemeCatalog) et, avec `?q=`, les
# passages de transcription de tous les replays — publiés ou non — qui en
# parlent (ReplaySearchIndex) : « les jours où on a parlé de X ». Les
# recherches de l'animation ne vont pas au journal des recherches, qui
# mesure la demande des spectateurs.
module Animation
  class ThemesController < BaseController
    def index
      @query = params[:q].is_a?(String) ? params[:q].squish.first(ReplaySearchIndex::QUERY_LIMIT) : ""
      @themes = ThemeCatalog.themes(filter: @query.presence)
      @search = ReplaySearchIndex.search(@query, Replay.includes(:webinar, :recording).to_a) if @query.present?
    end
  end
end
