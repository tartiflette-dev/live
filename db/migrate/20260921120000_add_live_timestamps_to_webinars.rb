class AddLiveTimestampsToWebinars < ActiveRecord::Migration[8.1]
  # Timestamps du cycle direct.
  #
  # started_at : posé par Webinar#go_live! (draft → live) — sert au
  #              champ `live_since` du endpoint public /w/:slug/state.json.
  # ended_at   : posé par Webinar#end! (live → ended).
  #
  # Additive SQLite (doctrine — jamais de suppression de colonne).
  # Datetime nullable : un webinaire draft n'a ni started_at ni ended_at.
  def change
    add_column :webinars, :started_at, :datetime
    add_column :webinars, :ended_at,   :datetime
  end
end
