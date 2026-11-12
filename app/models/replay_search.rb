# Journal des recherches dans les replays : chaque requête lancée sur
# /replays, même sans résultat, avec son auteur — compte OU
# inscription, jamais les deux (contrainte en base) — et le nombre de
# passages trouvés. C'est la demande des spectateurs : l'animation y lit les
# requêtes fréquentes et celles qui ne trouvent rien (Animation::SearchesController).
#
# Part avec l'inscription (effacement `crm:erase`, rétention à 12 mois) ou le
# compte (clés étrangères en cascade), et au plus RETENTION après la recherche
# (RetentionPurgeJob).
class ReplaySearch < ApplicationRecord
  RETENTION = 12.months

  # Requête agrégée : forme la plus récente, nombre de recherches et de
  # personnes, résultats de la dernière, dernière fois.
  Summary = Data.define(:query, :normalized_query, :searches_count, :people_count, :last_results_count, :last_at)

  belongs_to :registration, optional: true
  belongs_to :user, optional: true

  # @param author [User, Registration]
  def self.record!(query:, author:, results_count:)
    create!(query: query.to_s.squish.first(ReplaySearchIndex::QUERY_LIMIT),
            normalized_query: ReplaySearchIndex.normalize(query), results_count: results_count,
            **(author.is_a?(User) ? { user: author } : { registration: author }))
  end

  # Requêtes les plus fréquentes depuis `since` ; `unanswered` : celles dont
  # la dernière recherche n'a rien trouvé.
  # @return [Array<Summary>]
  def self.summaries(since:, unanswered: false, limit: 50)
    rows = where(created_at: since..).order(:created_at).group_by(&:normalized_query).map do |key, searches|
      last = searches.last
      Summary.new(query: last.query, normalized_query: key, searches_count: searches.size,
                  people_count: searches.map { |search| [ search.user_id, search.registration_id ] }.uniq.size,
                  last_results_count: last.results_count, last_at: last.created_at)
    end
    rows = rows.select { |row| row.last_results_count.zero? } if unanswered
    rows.sort_by { |row| [ -row.searches_count, -row.last_at.to_f ] }.first(limit)
  end

  def author
    user || registration
  end
end
