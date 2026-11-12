# frozen_string_literal: true

module Crm
  # Entrée d'une personne au CRM comme participant : fiche retrouvée par email ou créée (son id est
  # l'identifiant unique de la personne dans le CRM), puis segment
  # `participant` (realm `professional`). Partagé par les jobs qui font
  # entrer quelqu'un au CRM (CrmSyncJob, CrmNotifyNextJob) ; `on_contact`
  # sert aussi au retrait (CrmMarketingWithdrawalJob).
  #
  # Aucune journalisation ici : le client logue sans PII, les jobs logent
  # par identifiant local.
  class ParticipantSync
    # Fiche visée. `borrowed` : l'id vient d'une AUTRE ligne locale au même
    # email (Crm.known_contact_id), pas de la ligne poussée.
    Target = Data.define(:id, :borrowed)

    def initialize(client)
      @client = client
    end

    # La fiche ne porte que nom et email (contrat HTTP du CRM) : le
    # contexte de l'inscription va dans les notes des interactions.
    # Ordre : l'id de la ligne (`own_id`), puis celui d'une autre ligne au
    # même email (sans lookup, que le CRM compte dans son quota), puis
    # lookup, puis création. Un id périmé est relocalisé par `on_contact`.
    # `consented_at` : confirmation de la ligne poussée ; confirmée avant un
    # effacement explicite de cet email (CrmErasure), elle ne crée ni ne se
    # rattache à rien.
    def find_or_create_contact(email:, name:, consented_at:, own_id: nil)
      ensure_consent_after_erasure!(email, consented_at)
      return Target.new(id: own_id.to_i, borrowed: false) if own_id.present?

      borrowed_id = Crm.known_contact_id(email)
      return Target.new(id: borrowed_id.to_i, borrowed: true) if borrowed_id

      contact = @client.search_by_email(email) || create_contact(email: email, name: name)
      Target.new(id: contact["id"], borrowed: false)
    end

    # `email` = preuve exigée par le CRM : celui de la fiche visée.
    def tag_participant(contact_id, email:)
      @client.add_segment(contact_id, email: email, **HttpContactsClient::PARTICIPANT_SEGMENT)
    end

    # Exécute le bloc sur la fiche `contact_id`. Sur 404 (fiche introuvable
    # ou email non concordant, ex. id local périmé après une fusion dans
    # le CRM) : nouveau lookup par email, `relocated` reçoit le nouvel id (à
    # persister), puis UN seul nouvel essai. Second 404 sur le même id :
    # ContactNotFoundError (permanente).
    #
    # Lookup vide = disparition DÉDUITE : enregistrée (CrmDisappearance) et
    # JAMAIS de création — ContactGoneError(:missing). Ligne confirmée avant
    # un effacement explicite (`consented_at`) : aucune écriture, ni sur sa
    # fiche ni par relocalisation, ContactGoneError(:erased) — ses données
    # ne se rattachent pas à une fiche recréée depuis.
    def on_contact(contact_id, email:, relocated:, consented_at: nil)
      ensure_consent_after_erasure!(email, consented_at) if consented_at
      yield contact_id
    rescue ContactNotFoundError
      fresh = @client.search_by_email(email)
      unless fresh
        CrmDisappearance.record!(contact_id)
        raise ContactGoneError.new(:missing)
      end
      raise if fresh["id"].to_s == contact_id.to_s

      relocated.call(fresh["id"])
      yield fresh["id"]
    end

    private

    def ensure_consent_after_erasure!(email, consented_at)
      raise ContactGoneError.new(:erased) unless CrmErasure.consent_after?(email, consented_at)
    end

    def create_contact(email:, name:)
      first_name, last_name = split_name(name)
      @client.create_contact(first_name: first_name, last_name: last_name, email: email)
    end

    # Split naïf « Prénom Nom » : premier mot = prénom, le reste = nom.
    # Un seul mot (tartiflette.dev : le prénom suffit) est un prénom —
    # `first_name` est le champ obligatoire côté CRM.
    def split_name(full_name)
      full_name.to_s.strip.split(/\s+/, 2)
    end
  end
end
