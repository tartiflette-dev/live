class Registration < ApplicationRecord
  # Registration.
  #
  # Gate mail = double opt-in :
  #   1. `Registration.create!` pose un `token` opaque (jamais devinable),
  #      envoie le mail de confirmation (RegistrationMailer).
  #   2. Le lien `/r/:token` affiche un bouton (GET sans effet) ; le POST
  #      appelle `confirm!` → `confirmed_at` posé.
  #   3. `paid_confirmed_at` est réservé à la confirmation manuelle par
  #      l'animateur pour les webinaires payants — jamais
  #      posé côté public.
  #
  # `reminder_sent_at` = dictionnaire json de l'état du rappel de la veille
  # (`"j1"` = remise SMTP, verrou `"j1_starts_at"`…) — écrit par
  # RegistrationReminder seulement, qui en documente les clés.
  #
  # Cycle de vie disjoint de `User` (animateur OIDC) : PAS de concern
  # partagé, on duplique `normalize_email` — trois lignes triviales, SRP
  # respectée (deux acteurs, deux modèles).

  belongs_to :webinar, inverse_of: :registrations
  # Posé UNIQUEMENT à la création par l'API cross-origin (RegistrationRequest) :
  # une inscription existante n'est jamais rattachée après coup.
  belongs_to :registration_request, optional: true, inverse_of: :registrations
  # Intervenants du lien participants privé rattachés à cette inscription
  # (InvitationEntry) : leurs interventions (discussion, transcription
  # `speaker-<id>`) se relient à ce contact. Une inscription effacée les
  # détache (clé étrangère `on_delete: :nullify`).
  has_many :speakers, dependent: :nullify, inverse_of: :registration

  # Choix fait à l'inscription : spectateur = regarder,
  # discussion, main levée ; participant = veut intervenir en caméra et
  # micro. Sur le lien public, la main d'un participant se lève d'office à
  # son entrée (HandRaiseControl#raise_declared_hand) et l'animation
  # l'admet ; sur le lien privé, il devient un intervenant rattaché. Sans
  # rapport avec le segment CRM `participant`, que reçoit tout inscrit
  # confirmé. Une inscription retrouvée garde son choix d'origine.
  # `participation_chosen_at` date un choix FAIT par la personne (formulaire
  # qui le demande, ou entrée dans la salle) : sans lui, la salle le demande
  # avant d'entrer (`choose_participation!`).
  enum :participation, { spectator: "spectator", participant: "participant" }, default: :spectator, validate: true

  before_validation :normalize_email
  before_validation :ensure_token, on: :create
  before_validation :ensure_identity_secret, on: :create
  # Une ligne, sans caractère de contrôle : le nom s'affiche dans la salle et
  # dans le tableau des accords du dossier d'épisode.
  normalizes :name, with: ->(name) { name.gsub(/[[:cntrl:]]+/, " ").squish }

  validates :email,
    presence: true,
    format:   { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { scope: :webinar_id, case_sensitive: false }
  validates :name,  presence: true, length: { maximum: 120 }
  validates :token, presence: true, uniqueness: true
  # Secret porté par le cookie d'identité avec l'id (RoomRemoval
  # #registration_in_browser) : un cookie sans lui ne désigne personne.
  validates :identity_secret, presence: true

  # Adresse d'une pierre tombale (`retire_attributes`) : `.invalid` ne
  # délivre aucun mail (RFC 2606). Domaine RÉSERVÉ : aucune adresse saisie
  # (formulaire public, API, lien privé) n'y est acceptée, sans quoi un tiers
  # pourrait occuper d'avance l'adresse d'une pierre tombale.
  RETIRED_EMAIL_DOMAIN = "retire.invalid"
  RESERVED_EMAIL = /\.invalid\.?\z/i

  def self.reserved_email?(email)
    email.to_s.match?(RESERVED_EMAIL)
  end

  validate :email_not_reserved, unless: :retired?

  scope :confirmed, -> { where.not(confirmed_at: nil) }
  # Qui peut entrer dans la salle du direct (jeton, discussion, main levée,
  # garde webhook) : inscription confirmée ou à accès immédiat, jamais
  # retirée par l'animation. Cf. `room_access?`.
  scope :with_room_access, -> { where(room_removed_at: nil).and(confirmed.or(where.not(instant_access_at: nil))) }
  scope :removed_from_room, -> { where.not(room_removed_at: nil) }
  # Cf. `crm_sync_eligible?`.
  # `crm_sync_contact_gone_at` : fiche hors d'atteinte (Crm::ContactGoneError),
  # état terminal de la SYNCHRO — plus rien à pousser comme participant ou
  # consentement. Sans effet sur le retrait, qui a sa propre file.
  scope :crm_eligible, -> { confirmed.where.not(crm_enrolled_at: nil).where(crm_sync_contact_gone_at: nil) }
  # Ce que CrmSyncJob doit encore pousser : l'entrée du participant, ou
  # le marqueur de consentement marketing (s'il est effectif et non retiré).
  scope :crm_pending, -> {
    crm_eligible.where(pushed_to_crm_at: nil).or(
      crm_eligible.where(marketing_consent: true, marketing_consent_withdrawn_at: nil,
                         crm_marketing_consent_pushed_at: nil)
    )
  }

  # Retraits à propager sur une fiche CRM connue (CrmResyncJob).
  scope :crm_withdrawal_pending, -> {
    where.not(marketing_consent_withdrawn_at: nil).where.not(crm_contact_id: nil).where(crm_withdrawal_pushed_at: nil)
  }

  validates :marketing_consent_token, uniqueness: true, allow_nil: true
  validates :marketing_withdrawal_token, uniqueness: true, allow_nil: true

  # Fenêtre de validité du jeton de consentement marketing. 14 jours =
  # compromis utilisabilité (un mail peut rester oublié quelques jours)
  # vs. réduction du risque qu'un lien intercepté serve plus tard.
  MARKETING_CONSENT_TOKEN_TTL = 14.days

  # Double opt-in — pose `confirmed_at` UNE fois. Idempotent : un second
  # clic sur `/r/:token` (mail suivi deux fois) NE réécrit PAS le timestamp
  # (invariant journalisation : `confirmed_at` = première confirmation).
  #
  # Retourne `true` à la PREMIÈRE confirmation seulement : l'appelant
  # n'émet qu'une fois ce qui en découle (CRM). Cette confirmation est un
  # acte de la personne (POST) : elle vaut entrée au CRM (`crm_enrolled_at`).
  #
  # Jamais une inscription retirée de la salle ni une pierre tombale : sous
  # le verrou de la ligne, un retrait ou une remise concurrents gagnent
  # (sinon la pierre tombale finissait confirmée et
  # éligible au CRM).
  #
  # La boîte est prouvée : la personne reçoit son lien d'agenda personnel, si
  # elle ne l'a pas déjà (CalendarSubscription.offer_to).
  def confirm!
    confirmed_now = with_lock do
      next false if confirmed? || room_removed_at || retired?

      now = Time.current
      update!(confirmed_at: now, crm_enrolled_at: crm_enrolled_at || now)
      true
    end
    CalendarSubscription.offer_to(email, name: name, voice: webinar.voice) if confirmed_now
    confirmed_now
  end

  def confirmed?
    confirmed_at.present?
  end

  def paid_confirmed?
    paid_confirmed_at.present?
  end

  def room_access?
    (confirmed? || instant_access?) && room_removed_at.nil?
  end

  def instant_access?
    instant_access_at.present?
  end

  def participation_chosen?
    participation_chosen_at.present?
  end

  # Choix « J'observe » / « Je participe » fait à l'entrée de la salle
  # (ParticipationsController) : il remplace celui de l'inscription, et la
  # salle ne le redemande plus pour ce webinaire. Le premier choix gagne : un
  # onglet resté ouvert sur l'écran de choix ne change plus rien (changer
  # d'avis passe par la main levée). Écrit sans les validations de
  # l'inscription, la valeur étant vérifiée ici : une inscription ancienne
  # qui ne passerait plus une règle ajoutée depuis n'empêche pas d'entrer.
  # @return [Boolean] le choix est enregistré maintenant
  def choose_participation!(participation)
    raise ArgumentError, "participation inconnue : #{participation.inspect}" unless self.class.participations.key?(participation)

    with_lock do
      next false if participation_chosen?

      now = Time.current
      update_columns(participation: participation, participation_chosen_at: now, updated_at: now)
      true
    end
  end

  # Identité PROVISOIRE : ouverte par l'accès
  # immédiat, sans boîte prouvée. Elle n'est jamais promue en identité
  # confirmée d'un autre navigateur : confirmée depuis le navigateur qui la
  # porte, elle devient confirmée ; depuis un autre, `hand_over!`.
  def provisional?
    instant_access? && !confirmed?
  end

  # Pierre tombale : l'identité reste (id, retrait, interventions), l'adresse
  # est libérée. Jamais confirmable (jeton changé, jamais envoyé), jamais au
  # CRM, jamais attribuée à qui a cette adresse.
  def retired?
    retired_email_digest.present?
  end

  # Inscription provisoire confirmée depuis un AUTRE navigateur que celui qui
  # l'a ouverte (RegistrationsController#confirm_registration) : rien ne
  # prouve que ce navigateur-là soit celui de la boîte. L'identité provisoire
  # passe en pierre tombale, pour ce navigateur-là seulement ; la personne
  # qui a cliqué le lien du mail reçoit une inscription NEUVE et confirmée,
  # sous le nom et le choix qu'elle donne, sans rien hériter de l'identité
  # provisoire : ni nom, ni choix, ni discussion, ni pistes, ni consentement.
  # Seuls la suivent les intervenants rattachés (Speaker#registration) : un
  # rattachement n'existe que sur preuve de la boîte de cette adresse
  # (cookie d'une inscription confirmée, ou clic dans le mail /rattacher),
  # donc il appartient à la personne qui vient de la prouver à nouveau.
  # @return [Registration, nil] l'inscription neuve ; nil si celle-ci n'est
  #   plus provisoire (confirmée, retirée ou déjà remise entre-temps).
  def hand_over!(name:, participation: "spectator")
    with_lock do
      next nil unless provisional? && room_removed_at.nil? && !retired?

      email_to_free = email
      retire!
      fresh = webinar.registrations.create!(name: name, email: email_to_free, participation: participation,
                                            participation_chosen_at: Time.current)
      fresh.confirm!
      speakers.update_all(registration_id: fresh.id)
      fresh
    end
  end

  # Pierre tombale SANS retrait : l'identité provisoire reste au navigateur
  # qui l'a ouverte, son adresse est libérée pour la personne qui a prouvé la
  # boîte (`hand_over!`, Speaker#link_to_declared_registration!).
  def retire!
    update!(retire_attributes)
  end

  # Accès immédiat : pendant le direct ou le quart d'heure
  # qui le précède (`Webinar#instant_access_open?`), l'inscription ouvre la
  # salle tout de suite, sur l'appareil qui s'inscrit (cookie posé par
  # l'appelant). Réservé par les appelants à une inscription QU'ILS VIENNENT
  # DE CRÉER : une inscription retrouvée par son adresse ne donne jamais la
  # salle à qui la saisit. Le double opt-in ne change pas : ni
  # `confirmed_at` ni `crm_enrolled_at`, donc rien au CRM avant le clic du
  # mail.
  # @return [Boolean] l'accès est ouvert
  def grant_instant_access!(now: Time.current)
    return false unless webinar.instant_access_open?(now)

    update!(instant_access_at: now) unless instant_access?
    true
  end

  # Retrait de la salle par l'animation, pendant de
  # `Speaker#revoke!` : durable, horodaté UNE fois. Confirmée, l'inscription
  # le reste (CRM, consentements inchangés) et son adresse est retirée avec
  # elle. NON confirmée, rien ne prouve que l'adresse soit celle de la
  # personne retirée : pierre tombale, l'adresse est
  # libérée, et la trace du navigateur tient par l'id gardé (RoomRemoval).
  # Sauf si le retrait vient d'un intervenant dont la boîte de cette adresse
  # est prouvée (`mailbox_proven`, ParticipantModeration) : l'adresse est
  # alors la sienne, elle reste retirée.
  #
  # Deux étapes : le retrait d'abord, dans sa propre transaction ; la pierre
  # tombale ensuite, au PREMIER retrait seulement (un retrait relancé ne
  # libère jamais une adresse gardée retirée). Un échec de la pierre tombale
  # (collision, base) laisse l'adresse retirée, jamais la salle ouverte.
  def remove_from_room!(mailbox_proven: false)
    removed_now = with_lock { room_removed_at.nil? && update!(room_removed_at: Time.current) }
    retire_unproven_identity if removed_now && !mailbox_proven
  end

  # Consentement marketing — case facultative, distincte de l'inscription.
  # RGPD art. 6.1.a : la base légale est le consentement
  # SPÉCIFIQUE, horodaté.
  #
  # Sécurité :
  # 1. Le consentement NE PEUT PAS être validé par le `/r/:token`
  #    d'inscription — ce lien prouve la possession de l'email mais pas
  #    l'INTENTION de recevoir des sollicitations. Si A inscrit B avec la
  #    case cochée, B clique /r/:token pour s'inscrire, jamais pour
  #    autoriser la prospection. On passe par un JETON DÉDIÉ
  #    (`marketing_consent_token`), envoyé par mail à l'adresse, cliqué
  #    SÉPARÉMENT via /mc.
  # 2. Le clic GET sur /mc n'applique PAS le consentement (scanners Safe
  #    Links / antivirus suivent les GET) ; seule la validation POST
  #    (`apply_marketing_consent!`) le fait, et uniquement si le jeton
  #    n'est pas expiré.
  # 3. Usage unique horodaté : après application ou refus, le jeton est
  #    remis à NULL ; un retrait ultérieur passe par
  #    `marketing_withdrawal_token` (jeton persistant distinct).
  #
  # Exception : pour une
  # demande de l'API dont la case a été cochée, la page de confirmation
  # offre deux boutons explicites, libellés dans la tonalité de la page
  # (Voice) ; seul celui d'accord (`marketing=1`) pose le consentement
  # (`grant_marketing_consent!`, libellé affiché figé), sans jeton /mc. Le bouton porte l'intention, le lien du mail la possession
  # de la boîte.
  def marketing_consent_requested?
    marketing_consent_token.present?
  end

  # Génère (idempotent) le jeton de consentement et son expiration à la
  # soumission d'une inscription NOUVELLE avec la case cochée. Si un
  # jeton valide est déjà posé, on ne le remplace pas (une re-soumission
  # ne doit pas réinitialiser le compteur d'expiration pour autrui).
  def request_marketing_consent!(now: Time.current)
    return if marketing_consent?
    return if marketing_consent_token.present? && !marketing_consent_token_expired?(now)

    update!(
      marketing_consent_token: SecureRandom.urlsafe_base64(24),
      marketing_consent_token_expires_at: now + MARKETING_CONSENT_TOKEN_TTL
    )
  end

  def marketing_consent_token_expired?(now = Time.current)
    marketing_consent_token_expires_at.nil? || marketing_consent_token_expires_at < now
  end

  # Résolution défensive : nil sur blank/inconnu, jamais d'exception.
  def self.find_by_marketing_consent_token(token)
    return nil if token.blank?

    find_by(marketing_consent_token: token)
  end

  def self.find_by_marketing_withdrawal_token(token)
    return nil if token.blank?

    find_by(marketing_withdrawal_token: token)
  end

  # Retourne `true` SI cet appel a effectué le consentement (consentement
  # neuf), `false` sinon (déjà consenti, pas de jeton en attente, jeton
  # EXPIRÉ, ou consentement RETIRÉ — un retrait n'est jamais réversible
  # avec le même jeton : il faudrait une nouvelle inscription).
  #
  # Garantie 3 : un ancien jeton ne peut pas ré-appliquer
  # un consentement après un retrait. Le retrait invalide `marketing_consent_token`
  # côté `withdraw_marketing_consent!`, mais ici on refuse même si le
  # jeton était vivant au moment du retrait et qu'une tentative concurrente
  # arrive : `marketing_consent_withdrawn_at.present?` tranche.
  #
  # Le libellé du bouton cliqué est figé dans la preuve, tel que la page
  # /mc l'a affiché dans la tonalité de l'émission.
  def apply_marketing_consent!(now: Time.current)
    return false if marketing_consent_token.blank?
    return false if marketing_consent_token_expired?(now)

    grant_marketing_consent!(now: now, source: LIVE_SOURCE, path: "/mc", label: marketing_consent_button_label)
  end

  LIVE_SOURCE = Brand.host

  # Pose le consentement marketing, horodaté, avec son jeton de retrait et
  # sa preuve FIGÉE : provenance, page de l'acte,
  # version de la politique affichée, demande d'origine, libellé du bouton
  # cliqué. Deux actes y mènent : le POST /mc (`apply_marketing_consent!`)
  # et le bouton d'accord explicite de /confirmer, dans la tonalité de la
  # page (`RegistrationRequest#confirm!`). Même garantie 3 :
  # jamais après un retrait.
  def grant_marketing_consent!(source:, path:, request: nil, label: nil, now: Time.current)
    return false if marketing_consent?
    return false if marketing_consent_withdrawn_at.present?

    update!(
      marketing_consent: true,
      marketing_consent_at: now,
      marketing_consent_source: source,
      marketing_consent_path: path,
      marketing_consent_policy_version: PrivacyPolicy::VERSION,
      marketing_consent_request_id: request&.id,
      marketing_consent_label: label,
      crm_enrolled_at: crm_enrolled_at || now,
      marketing_consent_token: nil,
      marketing_consent_token_expires_at: nil,
      marketing_withdrawal_token: SecureRandom.urlsafe_base64(24),
      marketing_consent_withdrawn_at: nil
    )
    true
  end

  # Refus explicite ("Non merci") : le jeton est consommé sans poser le
  # consentement. Rend le lien inoffensif après coup.
  def decline_marketing_consent!(now: Time.current)
    return false if marketing_consent_token.blank?

    update!(
      marketing_consent_token: nil,
      marketing_consent_token_expires_at: nil
    )
    _ = now # noop (paramètre gardé pour symétrie et testabilité)
    true
  end

  # Retrait du consentement, via le jeton persistant émis au moment du
  # consentement. À usage unique : après retrait, le withdrawal_token est
  # consommé — un lien re-cliqué ne fait rien (idempotence utilisateur).
  #
  # Garantie 2 : si un `marketing_consent_token` était
  # encore en attente (soumission formulaire mais POST /mc jamais fait),
  # on l'INVALIDE AUSSI — un re-POST ultérieur avec cet ancien jeton
  # arrivera sur `apply_marketing_consent!` qui refusera (jeton nil).
  def withdraw_marketing_consent!(now: Time.current)
    return false unless marketing_consent?
    return false if marketing_withdrawal_token.blank?

    update!(
      marketing_consent: false,
      marketing_consent_withdrawn_at: now,
      marketing_withdrawal_token: nil,
      marketing_consent_token: nil,
      marketing_consent_token_expires_at: nil
    )
    true
  end

  def marketing_consent_withdrawn?
    marketing_consent_withdrawn_at.present?
  end

  # Le retrait vaut pour la PERSONNE : toutes ses
  # inscriptions consenties, quel que soit le café ou la demande. Le jeton
  # de retrait prouve la possession de la boîte : il ne peut toucher
  # personne d'autre. Retourne les inscriptions retirées.
  def self.withdraw_marketing_consent_of(email)
    where(email: email, marketing_consent: true).select do |registration|
      registration.with_lock { registration.withdraw_marketing_consent! }
    end
  end

  def crm_withdrawal_pushed?
    crm_withdrawal_pushed_at.present?
  end

  # Pré-condition d'une poussée au CRM : le
  # double opt-in confirmé suffit — tout inscrit confirmé entre au CRM
  # comme participant (base légale : intérêt légitime de l'organisation à suivre la
  # relation avec ses participants, RGPD art. 6.1.f, avec droit
  # d'opposition, cf. /confidentialite). La PROSPECTION reste
  # conditionnée au consentement marketing, poussé à part
  # (`crm_marketing_consent_pending?`) et retirable.
  #
  # `crm_enrolled_at` exige que cette entrée découle d'un acte de la personne
  # qui valait entrée au CRM (confirmation POST ou consentement /mc) : pas de
  # poussée rétroactive des inscrits confirmés avant que la confirmation
  # vaille entrée au CRM.
  def crm_sync_eligible?
    confirmed? && crm_enrolled_at.present? && crm_sync_contact_gone_at.nil?
  end

  def crm_pushed?
    pushed_to_crm_at.present?
  end

  def crm_marketing_consent_pending?
    marketing_consent? && !marketing_consent_withdrawn? && crm_marketing_consent_pushed_at.nil?
  end

  # Retourne `[registration, created?]` — le booléen permet à l'appelant
  # de distinguer une NOUVELLE inscription (seul cas où une intention
  # portée par la soumission peut être retenue en toute sécurité) d'une
  # inscription retrouvée, qui n'est JAMAIS modifiée (ni nom, ni demande
  # de rattachement). `email` doit être déjà normalisé.
  #
  # `find_or_create_by!` porte le double verrou (lookup + index unique)
  # qui absorbe la course entre deux soumissions concurrentes.
  # `participation` nil = le défaut de l'enum, choix jamais fait (la salle le
  # demandera) ; donné = choix de la personne, daté.
  def self.find_or_create_for(webinar, email:, name:, registration_request: nil, participation: nil)
    created = false
    record = webinar.registrations.find_or_create_by!(email: email) do |registration|
      registration.name = name
      registration.registration_request = registration_request
      registration.assign_attributes(participation: participation, participation_chosen_at: Time.current) if participation
      created = true
    end
    [ record, created ]
  rescue ActiveRecord::RecordInvalid => error
    raise unless error.record.errors.all? { |item| item.attribute == :email && item.type == :taken }

    [ webinar.registrations.find_by!(email: email), false ]
  end

  # Résolution du lien nominatif `/r/:token`. Renvoie `nil` sur token
  # blank/inconnu — JAMAIS `ActiveRecord::RecordNotFound` (le controller
  # public répond 404 générique lui-même : un spectateur non confirmé
  # n'obtient aucun token viewer).
  def self.find_by_token(token)
    return nil if token.blank?

    find_by(token: token)
  end

  # Sécurité log : redéfinit `inspect` pour masquer `token`,
  # `marketing_consent_token` ET `marketing_withdrawal_token`, en plus du
  # filtre `filter_parameter_logging.rb`. Défense en profondeur.
  def inspect
    "#<Registration id=#{id} webinar_id=#{webinar_id} email=#{email.inspect} " \
      "confirmed_at=#{confirmed_at.inspect} paid_confirmed_at=#{paid_confirmed_at.inspect} " \
      "marketing_consent=#{marketing_consent.inspect}>"
  end

  private

  # Libellé du bouton d'accord tel que la page /mc l'a affiché, dans la
  # tonalité de l'émission : calculé à l'accord, avant que le consentement
  # ne change ce que la page montre (même règle que
  # `RegistrationRequest#consent_button_label` pour /confirmer).
  def marketing_consent_button_label
    Voice.t("marketing_consents.show.accept", voice: webinar.voice)
  end

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end

  def ensure_token
    self.token = SecureRandom.urlsafe_base64(24) if token.blank?
  end

  def ensure_identity_secret
    self.identity_secret = SecureRandom.hex(24) if identity_secret.blank?
  end

  def email_not_reserved
    errors.add(:email, :invalid) if self.class.reserved_email?(email)
  end

  # Étape 2 du retrait : jamais une inscription confirmée (relue sous le
  # verrou). Journal sans donnée personnelle.
  def retire_unproven_identity
    with_lock { update!(retire_attributes) unless confirmed? }
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    reload
    Rails.logger.warn("[registration] tombstone failed registration=#{id} error=#{error.class}")
  end

  # Pierre tombale (`hand_over!`, `remove_from_room!`) : adresse remplacée
  # par une adresse imprévisible du domaine réservé (son empreinte garde
  # l'effacement possible, CrmErasure), jeton du lien changé (l'ancien lien
  # ne sert plus), demande de consentement marketing annulée. Id, secret,
  # retrait et interventions restent. Une seule fois.
  def retire_attributes
    return {} if retired?

    {
      email: "retire-#{SecureRandom.hex(16)}@#{RETIRED_EMAIL_DOMAIN}",
      retired_email_digest: CrmErasure.digest(email),
      token: SecureRandom.urlsafe_base64(24),
      marketing_consent_token: nil,
      marketing_consent_token_expires_at: nil
    }
  end
end
