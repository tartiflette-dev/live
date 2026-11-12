# frozen_string_literal: true

# Namespace du couloir d'intégration CRM.
# Garde ici les types partagés (erreurs taxonomiques) pour que Zeitwerk
# autoload `Crm::TransientError` et `Crm::PermanentError` sans forcer un
# fichier par classe de deux lignes (anti sur-décomposition).
module Crm
  # Port de code HTTP pour les erreurs — exploité par le journaliseur sans
  # jamais exposer le corps de la réponse (qui peut porter nom/email dans
  # une 422 du CRM).
  module HttpStatusCarrier
    attr_accessor :http_status
  end

  # Erreur transiente : à retenter (5xx, 429, timeout réseau, DNS).
  class TransientError < StandardError
    include HttpStatusCarrier
  end

  # 429 du CRM (quota de requêtes du jeton). Pas de retry
  # immédiat : le job s'arrête, la ligne attend `defer_for` dans
  # Crm::Backlog, sans compter comme échec.
  class RateLimitedError < TransientError
    # Au-delà d'une fenêtre d'une minute, c'est un quota long (journalier) : son
    # Retry-After peut tomber juste avant la bascule, on attend au moins 1 h.
    MINUTE_WINDOW = 60
    DAILY_QUOTA_FLOOR = 1.hour

    attr_reader :retry_after

    def initialize(message = nil, retry_after: MINUTE_WINDOW)
      super(message)
      self.http_status = 429
      @retry_after = retry_after
    end

    def defer_for
      return retry_after.seconds if retry_after <= MINUTE_WINDOW

      [ retry_after.seconds, DAILY_QUOTA_FLOOR ].max
    end
  end

  # Erreur permanente : abandon (4xx hors 429, payload refusé).
  class PermanentError < StandardError
    include HttpStatusCarrier
  end

  # 404 sur une écriture visant une fiche (segment, interaction) : fiche
  # introuvable ou email-preuve non concordant (id local périmé après une
  # fusion côté CRM). Permanente si elle persiste après un nouveau lookup.
  class ContactNotFoundError < PermanentError; end

  # Retrait sur une fiche introuvable (404 de preuve puis lookup vide).
  # L'effacement n'est qu'INFÉRÉ (un email changé côté CRM donne la même
  # réponse) : un retrait ne se clôt jamais en succès sur une inférence.
  # Permanente, code 404, comptée sur le compteur du retrait : la sonde
  # passe en 503 et un humain vérifie la fiche dans le CRM.
  class WithdrawalContactNotFoundError < PermanentError
    CODE = "withdrawal_contact_not_found"

    def initialize(message = "crm:#{CODE}")
      super
      self.http_status = 404
    end
  end

  # Fiche hors d'atteinte pour la ligne poussée — PAS un échec : un état
  # terminal attendu de la file, rattrapé par le job (Crm::Backlog.close_gone),
  # ni nouvel essai ni 503. Volontairement hors de PermanentError.
  # `reason` : :missing (disparition déduite, 404 + lookup vide) ou :erased
  # (ligne confirmée avant un effacement explicite, CrmErasure).
  class ContactGoneError < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("crm:contact_gone_#{reason}")
    end
  end

  # Fiche CRM déjà connue localement pour cet email (inscription ou
  # demande déjà poussée, la plus récemment mise à jour) : évite un lookup,
  # que le CRM compte dans le quota. Un id périmé (fusion, effacement) est
  # relocalisé par le 404 de preuve (ParticipantSync#on_contact).
  def self.known_contact_id(email)
    [ Registration, RegistrationRequest ].lazy.filter_map do |model|
      model.where(email: email).where.not(crm_contact_id: nil).order(updated_at: :desc).pick(:crm_contact_id)
    end.first
  end

  # Libellé du bouton d'accord de /confirmer avant que la page ne parle dans
  # la tonalité de son émission : celui d'une preuve sans libellé figé.
  LEGACY_CONFIRM_LABEL = "Confirmer et accepter d'être recontacté·e".freeze

  # Acte cité par la note : le bouton et sa page. `label` vide = preuve
  # antérieure au figement du libellé (sur /confirmer comme sur /mc) : la
  # note cite la constante de l'époque, jamais un libellé recalculé.
  def self.marketing_consent_act(path, label)
    if path == "/confirmer"
      return "bouton « #{label || LEGACY_CONFIRM_LABEL} » de la page /confirmer " \
             "(lien personnel reçu par mail ; case cochée lors d'une demande au formulaire public)"
    end
    return "bouton « #{label} » de la page /mc (lien à usage unique reçu par mail)" if label.present?

    "lien dédié /mc (jeton à usage unique)"
  end

  # Notes de l'interaction « Consentement marketing », tirées de la preuve
  # FIGÉE à l'accord, jamais recalculée : `label`
  # est le libellé du bouton affiché. `path` nil =
  # consentement antérieur à la preuve figée, posé par /mc.
  def self.marketing_consent_note(at:, path:, source:, policy_version:, label: nil, request: nil)
    proof = [
      ("provenance #{source}" if source),
      ("politique v#{policy_version}" if policy_version),
      ("demande n°#{request.id} du #{request.created_at.iso8601}" if request)
    ].compact
    "Consentement explicite au recontact par #{Brand.organization}, posé le #{at.iso8601} " \
      "via #{marketing_consent_act(path, label)}#{" ; #{proof.join(", ")}" if proof.any?}."
  end

  # Défaut de programmation : un corps hors du contrat HTTP du CRM
  # (refusé par lui), détecté AVANT l'envoi. Permanente, code 422 (le
  # refus que le CRM aurait renvoyé) : le `discard_on` des
  # jobs la compte comme une tentative datée et la sonde
  # /internal/crm_status la voit tout de suite comme échec permanent.
  class ContractError < PermanentError
    def initialize(message = nil)
      super
      self.http_status = 422
    end
  end

  # Client CRM sans sa configuration : jeton ou URL absents. ArgumentError,
  # pour que les appelants (`rescue ArgumentError`, `discard_on`) la traitent
  # sans changement ; `variable` nomme la variable à poser.
  class UnconfiguredError < ArgumentError
    attr_reader :variable

    def initialize(variable)
      @variable = variable
      super("#{variable} manquant")
    end
  end

  # Raison journalisée par un job CRM qui jette une ArgumentError : la
  # variable à poser si le client n'est pas configuré, une raison générique
  # sinon. Jamais le message d'une autre ArgumentError, qui peut porter une
  # donnée personnelle (une adresse refusée par exemple).
  def self.discard_reason(error)
    return "crm_unconfigured variable=#{error.variable}" if error.is_a?(UnconfiguredError)

    "argument_error"
  end

  # Les jobs CRM d'une même personne s'exécutent un par un (Solid Queue
  # `limits_concurrency`, groupe partagé) : une soumission de trois cafés
  # confirmée d'un clic enqueue trois jobs, qui créeraient trois fiches
  # CRM en parallèle (search_by_email ne voit pas encore la création
  # voisine). Clé = empreinte de l'email, jamais l'email (tables de file).
  CONTACT_CONCURRENCY_GROUP = "crm_contact"

  def self.contact_concurrency_key(email)
    "crm-contact-#{Digest::SHA256.hexdigest(email.to_s)[0, 32]}"
  end
end
