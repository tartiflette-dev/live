# Flux d'agenda personnel (/agenda/<jeton>.ics) : un abonnement par adresse,
# créé à la première confirmation d'une inscription (CalendarSubscription).
# Les compteurs mesurent les abonnés sans dépendre des journaux du proxy.
class CreateCalendarSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :calendar_subscriptions do |t|
      t.string :email, null: false
      t.string :token, null: false
      t.datetime :revoked_at
      t.datetime :last_fetched_at
      t.integer :fetch_count, null: false, default: 0
      t.timestamps
    end
    add_index :calendar_subscriptions, :email, unique: true
    add_index :calendar_subscriptions, :token, unique: true
  end
end
