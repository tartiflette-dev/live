class AddTrackClaimsToRecordings < ActiveRecord::Migration[8.1]
  def change
    add_column :recordings, :track_sid, :string
    add_column :recordings, :output_prefix, :string
    add_column :recordings, :completion_received_at, :datetime
    add_index :recordings, [ :webinar_id, :track_sid ], unique: true
  end
end
