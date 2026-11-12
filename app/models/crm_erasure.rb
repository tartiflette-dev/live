# Effacement EXPLICITE d'une personne (`bin/rails crm:erase`, lancé quand
# une demande d'effacement est traitée) — la seule source qui autorise de
# recréer une fiche CRM pour cet email : une ligne confirmée STRICTEMENT
# après `erased_at` est un nouveau consentement ; une ligne confirmée avant
# ne crée ni ne se rattache à rien (et a de toute façon été purgée).
#
# Une disparition DÉDUITE (404 + lookup vide) n'est pas un effacement :
# voir CrmDisappearance.
#
# Pas d'email en clair : `email_digest` = HMAC-SHA256 de l'email normalisé,
# clé dérivée de `secret_key_base` à usage dédié (une rotation de
# secret_key_base rend les empreintes inopérantes : à reporter avant).
# Conservation : tant que le service existe — nécessaire pour respecter
# l'effacement (politique de confidentialité).
class CrmErasure < ApplicationRecord
  KEY_PURPOSE = "crm-erasure-email-digest"
  ERASED_NAME = "Participant·e (effacé·e)"
  ERASED_BODY = "[message retiré]"

  def self.digest(email)
    key = Rails.application.key_generator.generate_key(KEY_PURPOSE, 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, normalize(email))
  end

  def self.normalize(email)
    email.to_s.strip.downcase
  end

  def self.erased_at(email)
    where(email_digest: digest(email)).pick(:erased_at)
  end

  # Aucune trace d'effacement, ou confirmation strictement postérieure.
  def self.consent_after?(email, consented_at)
    erased = erased_at(email)
    erased.nil? || (consented_at.present? && consented_at > erased)
  end

  # Enregistre l'effacement (date du DERNIER, jamais en recul) et efface les
  # données live de cet email : inscriptions (et mains levées), demandes ;
  # les messages de chat de ces inscriptions sont neutralisés (nom ET texte
  # remplacés par des marqueurs : le fil de discussion garde sa forme) et
  # retirés de la file Q&R ; une question qui n'a plus d'auteur disparaît,
  # une question dont le libellé venait de leur texte est réécrite depuis un
  # autre auteur (QaItem#forget_erased!) ; leurs questions posées depuis le
  # replay sont supprimées. Même transaction : un
  # QaExtractionJob concurrent relit le message sous verrou (QaItem.enqueue!).
  # Après commit, les salles dont la question affichée a été touchée reçoivent
  # le nouvel état du bandeau (retiré). Leurs réponses aux sondages, du direct
  # comme du replay (même identité viewer-<id>), sont supprimées. Une adresse
  # déclarée au lien participants privé (intervenant non rattaché) est oubliée avec son lien de rattachement ; un intervenant
  # rattaché perd son rattachement avec l'inscription (FK nullify). Son
  # abonnement à l'agenda personnel disparaît : le lien répond 404. Les
  # marqueurs d'envoi groupé de l'adresse (AnnouncementDelivery, par empreinte)
  # sont supprimés : un mail encore en file ne part plus.
  # Retourne des compteurs, jamais d'identité. Ne touche pas le CRM.
  def self.erase!(email, now: Time.current)
    email = normalize(email)
    counts, displayed_webinar_ids = transaction do
      erasure = create_or_find_by!(email_digest: digest(email)) { |row| row.erased_at = now }
      where(id: erasure.id).where(erased_at: ...now).update_all(erased_at: now, updated_at: now)

      # Pierres tombales de cette adresse (Registration#retire_attributes) :
      # retrouvées par l'empreinte, leur adresse ayant été libérée.
      registration_ids = Registration.where(email: email).or(Registration.where(retired_email_digest: digest(email))).ids
      messages = Message.where(author_identity: registration_ids.map { |id| "viewer-#{id}" })
      qa_count, displayed_webinar_ids = erase_from_qa_queue(messages, registration_ids)
      [ {
        qa_items: qa_count,
        messages: messages.update_all(name: ERASED_NAME, body: ERASED_BODY),
        hand_raises: HandRaise.where(registration_id: registration_ids).delete_all,
        poll_responses: PollResponse.where(respondent_identity: registration_ids.map { |id| "viewer-#{id}" }).delete_all,
        registrations: Registration.where(id: registration_ids).delete_all,
        registration_requests: RegistrationRequest.where(email: email).delete_all,
        declared_speakers: Speaker.where(declared_email: email).update_all(declared_email: nil, link_token: nil),
        calendar_subscriptions: CalendarSubscription.where(email: email).delete_all,
        announcement_deliveries: AnnouncementDelivery.where(recipient_digest: digest(email)).delete_all
      }, displayed_webinar_ids ]
    end
    Webinar.where(id: displayed_webinar_ids).find_each { |webinar| QaBroadcast.new.deliver(webinar) }
    counts
  end

  # @return [Array(Integer, Array<Integer>)] questions supprimées ou réécrites,
  #   webinaires dont la question affichée en faisait partie
  def self.erase_from_qa_queue(messages, registration_ids)
    erased_ids = messages.ids
    links = QaItemMessage.where(message_id: erased_ids)
    items = QaItem.where(id: links.select(:qa_item_id)).to_a
    links.delete_all
    displayed = items.select(&:displayed_at)
    changed = items.select { |item| item.forget_erased!(erased_ids) }

    replay_items = QaItem.where(registration_id: registration_ids)
    replay_displayed_webinar_ids = replay_items.displayed.distinct.pluck(:webinar_id)
    replay_count = replay_items.delete_all
    [ changed.size + replay_count, ((changed & displayed).map(&:webinar_id) + replay_displayed_webinar_ids).uniq ]
  end
  private_class_method :erase_from_qa_queue
end
