class AddKindToRecordings < ActiveRecord::Migration[8.1]
  def change
    add_column :recordings, :kind, :string, null: false, default: "composite"
    add_column :recordings, :participant_identity, :string
    add_column :recordings, :track_source, :string
  end
end
