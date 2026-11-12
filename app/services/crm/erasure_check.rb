# frozen_string_literal: true

module Crm
  # Après `crm:erase` : une fiche existe-t-elle encore dans le CRM pour cet
  # email ? Lookup seul (le contrat n'offre pas d'autre lecture : segments
  # et interactions exigent une preuve et ÉCRIVENT) — rien n'est modifié.
  # Rend une ligne lisible, jamais l'email ; le lookup compte dans le quota
  # du CRM, une seule requête.
  class ErasureCheck
    def self.call(email, client: nil)
      contact = (client || HttpContactsClient.new).search_by_email(email)
      return "CRM : aucune fiche trouvée pour cette adresse." unless contact

      "CRM : une fiche existe ENCORE pour cette adresse (id #{contact["id"]}) — efface-la dans le CRM."
    rescue ArgumentError
      "CRM : vérification impossible (CRM_API_TOKEN ou CRM_BASE_URL absent) — vérifie à la main dans le CRM."
    rescue TransientError, PermanentError => error
      "CRM : vérification impossible (http_status=#{error.http_status.to_i}) — vérifie à la main dans le CRM."
    end
  end
end
