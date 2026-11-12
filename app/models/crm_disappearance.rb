# Fiche CRM DISPARUE vue par live : 404 de preuve sur un id connu, puis
# lookup par email vide. Ce n'est qu'une déduction (effacement, mais aussi
# email changé côté CRM) : elle n'autorise JAMAIS une création, et ne
# sert qu'à la visibilité (sonde). Clé = id CRM ; aucune donnée
# personnelle.
class CrmDisappearance < ApplicationRecord
  def self.record!(contact_id, now: Time.current)
    row = create_or_find_by!(contact_id: contact_id.to_s) { |r| r.first_seen_at = r.last_seen_at = now }
    where(id: row.id).where(last_seen_at: ...now).update_all(last_seen_at: now)
  end
end
