# Statistiques de visionnage d'un replay, par personne, pour l'animation
# (WebinarReplaysController) : qui, combien de vues, temps regardé, part de
# la vidéo vue et passages vus.
#
# Une vue = une séance (un onglet) où au moins un passage a été lu. Le temps
# regardé cumule les séances (un passage revu compte deux fois) ; la part
# vue et les passages viennent de l'union des passages de toutes ses
# séances. Une personne = une inscription ou un compte : la même
# adresse vue par les deux voies fait deux lignes, chacune nommée par sa voie.
class ReplayStats
  Row = Data.define(:viewer, :views_count, :watched_seconds, :intervals, :ratio, :last_seen_at) do
    def name
      viewer.is_a?(User) ? viewer.chat_alias : viewer.name
    end

    def email
      viewer.email
    end

    def via_account?
      viewer.is_a?(User)
    end
  end

  def initialize(replay)
    @replay = replay
  end

  # Dernier visionnage d'abord.
  # @return [Array<Row>]
  def rows
    @rows ||= @replay.views.includes(:registration, :user).group_by(&:viewer)
                     .map { |viewer, views| self.class.row_for(@replay, viewer, views) }
                     .sort_by { |row| -row.last_seen_at.to_f }
  end

  def total_views
    rows.sum(&:views_count)
  end

  # Ligne d'une personne à partir de ses séances sur `replay` ; sert aussi à
  # la fiche d'une personne sur tous les replays (PersonActivity).
  def self.row_for(replay, viewer, views)
    intervals = ReplayView.merge_intervals(views.flat_map(&:intervals))
    covered = intervals.sum { |(start, finish)| finish - start }
    Row.new(viewer: viewer,
            views_count: views.count { |view| view.watched_seconds.positive? },
            watched_seconds: views.sum(&:watched_seconds),
            intervals: intervals,
            ratio: replay.duration.positive? ? (covered / replay.duration).clamp(0.0, 1.0) : 0.0,
            last_seen_at: views.map(&:last_seen_at).max)
  end
end
