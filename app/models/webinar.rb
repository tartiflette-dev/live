class Webinar < ApplicationRecord
  # LiveKit access tokens are issued on demand and are never persisted.
  # Levée par #go_live! / #end! quand la transition est refusée (état
  # source incompatible). Le controller la transforme en HTTP 409.
  class TransitionError < StandardError; end

  # Lien d'invitation INTERVENANT PARTAGÉ :
  # un jeton opaque par webinaire que l'animateur distribue ; la personne
  # qui l'ouvre saisit son nom et obtient un Speaker nominatif.
  self.filter_attributes += [ :share_token ]
  SHARE_TOKEN_BYTES = 24

  # Plafond intervenants par webinaire — pare-feu DoS côté lien partagé.
  # Compte TOUS les Speakers (actifs + révoqués) pour que la révocation
  # ne crée pas d'évasion silencieuse. 50 = large pour un café IA
  # (expérience : 5–15 intervenants invités), étroit pour un attaquant.
  SPEAKER_LIMIT = 50

  STATES = %w[draft live ended].freeze
  enum :state, STATES.index_with(&:itself), validate: true

  # Catalogue : visibilité publique, distincte du cycle de direct (`state`).
  # prefix: true — `draft?` est déjà pris par `state`.
  VISIBILITIES = %w[draft published].freeze
  enum :visibility, VISIBILITIES.index_with(&:itself), validate: true, prefix: true

  # Formats d'émission livrés : chacun a sa durée prévue (PLANNED_DURATIONS),
  # son libellé (catalogue.kinds) et peut porter sa tonalité (Voice). Un
  # webinaire créé sans format reçoit le défaut de la colonne (`cafe_ia`,
  # db/schema.rb).
  KINDS = %w[cafe_ia bootcamp].freeze
  enum :kind, KINDS.index_with(&:itself), validate: true

  # Durée PRÉVUE par format. Le modèle ne porte pas d'heure de fin ;
  # l'agenda en a besoin pour borner un
  # événement de calendrier (DTEND .ics, lien Google Agenda). Bootcamp :
  # demi-journée par défaut, ni la spec ni les données ne fixant sa durée.
  PLANNED_DURATIONS = { "cafe_ia" => 1.hour, "bootcamp" => 3.hours }.freeze

  # Après la fin réelle — ou, si le direct n'a jamais été clos, après la
  # fin prévue — les jetons (lien partagé et liens d'intervenants) cessent
  # de résoudre. Un direct en cours n'est jamais coupé par cette borne :
  # la reprendre (`resume!`) rouvre les liens. Le délai couvre au
  # moins la fin automatique d'une salle vide (AutoEndLiveJob::AUTO_END_DELAY).
  LINK_ACCESS_GRACE = 1.day

  def self.link_access_grace_label
    count = (LINK_ACCESS_GRACE / 1.day).to_i
    "#{count} jour#{'s' unless count == 1}"
  end

  # Enregistrements egress. `dependent: :destroy` non
  # câblé : le CRUD anime n'expose pas destroy (cf. routes), et un futur
  # destroy devra décider explicitement du sort des MP4 sur disque.
  has_many :recordings, -> { recent_first }, dependent: :restrict_with_exception, inverse_of: :webinar
  # Segments de transcript multi-locuteur archivés en direct
  # (text stream LiveKit + POST signé /webhooks/transcripts). Isolation
  # par webinaire — identique au contrat Recording.
  has_many :transcript_segments, dependent: :restrict_with_exception, inverse_of: :webinar
  has_many :speakers, dependent: :restrict_with_exception, inverse_of: :webinar
  has_many :hand_raises, dependent: :restrict_with_exception
  has_many :messages, dependent: :restrict_with_exception, inverse_of: :webinar
  has_many :qa_items, dependent: :restrict_with_exception, inverse_of: :webinar
  has_many :registrations, dependent: :restrict_with_exception, inverse_of: :webinar
  # Journal de présence dans la salle (page « Présence ») : suit les
  # inscriptions, même rétention (RetentionPurgeJob).
  has_many :presence_events, dependent: :restrict_with_exception, inverse_of: :webinar
  # Accords à l'image des intervenants et spectateurs.
  has_many :participant_consents, dependent: :restrict_with_exception, inverse_of: :webinar
  # Sondages du direct : le plan, dans son ordre.
  has_many :polls, -> { in_plan_order }, dependent: :restrict_with_exception, inverse_of: :webinar
  # Mesures des émetteurs caméra (CameraSample) : journal technique purgé
  # au bout de CameraSample::RETENTION, sans valeur une fois le webinaire parti.
  has_many :camera_samples, dependent: :delete_all, inverse_of: :webinar
  # Journal des mises en avant du direct (RoomSpotlight), lu par le montage
  # du replay ; sans valeur une fois le webinaire parti.
  has_many :spotlight_changes, dependent: :delete_all, inverse_of: :webinar
  # Co-animateurs invités. Suppression autorisée au fil
  # de l'eau depuis la page webinaire → `:destroy` propage (pas d'historique
  # à préserver : la table est une liste d'accès, pas un journal).
  has_many :webinar_hosts, dependent: :destroy, inverse_of: :webinar
  # Liens animateur : jetons d'accès, sans historique
  # à préserver une fois le webinaire supprimé.
  has_many :host_invitations, dependent: :destroy, inverse_of: :webinar
  # Présence des animateurs, statut « date confirmée » (Webinar::HostPresence).
  include HostPresence
  # État du dépôt de l'épisode dans Nextcloud.
  has_one :episode_publication, dependent: :restrict_with_exception, inverse_of: :webinar
  # Replay réservé aux personnes identifiées (Replay, ReplayAccess).
  has_one :replay, dependent: :restrict_with_exception, inverse_of: :webinar
  # Chapitres proposés par le LLM local et relus par l'animation (ChapterSet).
  has_one :chapter_set, dependent: :restrict_with_exception, inverse_of: :webinar

  # Association Pack. Optional car
  # la majorité des webinaires reste hors pack (cafés IA gratuits).
  # `pack_id` est nu (pas de FK SQL) — la nullification côté Pack se
  # fait en Ruby (Pack#dependent: :nullify).
  belongs_to :pack, optional: true

  # Date, titre, description et dépublication par le propriétaire.
  include Edition
  # Sujet, intervenants annoncés et animateur du jour.
  include Program
  # Transcription absente pendant le direct : bandeau de la régie, alerte.
  include TranscriptionOutage

  validates :title,     presence: true, length: { maximum: 200 }
  validates :starts_at, presence: true
  validates :host_sub,  presence: true
  validates :slug,      presence: true, uniqueness: true, format: { with: /\A[a-z0-9][a-z0-9\-]*\z/ }
  validates :room_name, presence: true, uniqueness: true
  validates :price_cents, numericality: { greater_than_or_equal_to: 0, only_integer: true }

  # Noms de sous-dossiers réservés sous `RECORDINGS_ROOT/` (défense en
  # profondeur). Le regex de slug ci-dessus les
  # exclut déjà par construction (préfixe `_` interdit) ; cette
  # validation nommée reste si le regex venait à loosen, et verrouille
  # le sens métier : « ces noms sont la propriété de l'arborescence
  # fichiers, pas d'un webinaire ».
  RESERVED_SLUGS = %w[_participants participants].freeze
  validate :slug_not_reserved

  def slug_not_reserved
    return if slug.blank?
    return unless RESERVED_SLUGS.include?(slug.to_s)
    errors.add(:slug, :reserved, message: "est réservé (collision avec l'arborescence des fichiers)")
  end

  # Accueil public : un webinaire ne quitte pas l'accueil à son heure de
  # début. Trois groupes DISJOINTS, dans l'ordre d'affichage : en direct
  # (enum `live`), en retard (`starting_late`), à venir (`upcoming`).
  # `ended` n'entre dans aucun. Au-delà de LATE_START_WINDOW, un draft non
  # lancé est présumé annulé ou reporté et quitte l'accueil. Passer le
  # même `now` aux deux scopes : leurs intervalles se touchent sans trou.
  LATE_START_WINDOW = 3.hours
  # Avance de l'accès immédiat sur le début prévu : on
  # entre dans le direct en s'inscrivant, et dans le quart d'heure qui le
  # précède.
  INSTANT_ACCESS_LEAD = 15.minutes

  scope :hosted_by, ->(sub) { where(host_sub: sub) }
  scope :published, -> { where(visibility: "published") }
  scope :starting_late, ->(now = Time.current) {
    where(state: "draft", starts_at: (now - LATE_START_WINDOW)...now).order(starts_at: :asc)
  }
  scope :upcoming, ->(now = Time.current) { where(state: "draft", starts_at: now..).order(starts_at: :asc) }

  # Prochaines dates (/agenda/next.json) : les groupes de l'accueil dans
  # leur ordre, tronqués à `limit`. Un direct en cours suivi des dates
  # suivantes ; un direct terminé n'y est plus. Paires [groupe, webinaire] :
  # le groupe devient le `status` du JSON. À appeler sur une relation déjà
  # filtrée (publiés, format) : les scopes héritent de son périmètre.
  def self.next_dates(limit, now: Time.current)
    groups = {
      # `live` est l'enum, sans ordre propre : contrairement aux deux scopes
      # suivants, l'ordre est posé ici (comme sur l'accueil).
      "live"          => live.order(starts_at: :asc),
      "starting_late" => starting_late(now),
      "upcoming"      => upcoming(now)
    }
    groups.flat_map { |status, scope| scope.order(id: :asc).limit(limit).map { |webinar| [ status, webinar ] } }
          .first(limit)
  end

  # Webinaires sur lesquels `user` est propriétaire, co-animateur invité,
  # ou animateur du projet (scope de LISTE).
  # `project_host?` voit TOUT (droits étendus sur TOUT live).
  #
  # Convention : `none` si `user` est nil — le controller animateur a
  # déjà `authenticate_animateur!` en amont, mais la défense en
  # profondeur protège un futur appel sans auth.
  #
  # Durcissement sécurité :
  #   • un invité SANS `email_verified` ne « voit » rien par la jointure
  #     email (le scope sert aussi à trouver un webinaire pour /stage,
  #     /go_live, /end — accorder la vue sans vérification serait un
  #     fail-open). La résolution de rôle `role_for` fait le double
  #     check au moment de l'ouverture.
  #   • un invité avec `claimed_sub` posé par un AUTRE sub ne reçoit
  #     plus la jointure (défense broken-authentication, cohérent avec
  #     `role_for`).
  scope :where_animated_by, ->(user) {
    next none if user.nil?
    next all if user.project_host?
    next where(host_sub: user.oidc_sub) unless user.email_verified_and_fresh?

    # Sous-requête : webinaires où l'user figure comme invité CLAIM-safe
    # (email vérifié, claimed_sub nul ou égal à son sub).
    guest_webinar_ids = WebinarHost
      .where("LOWER(email) = ?", user.normalized_email)
      .where("claimed_sub IS NULL OR claimed_sub = ?", user.oidc_sub)
      .select(:webinar_id)

    # Pas de .to_sql : le SQL inliné, adresse comprise, finirait dans le message d'un RecordNotFound.
    where(host_sub: user.oidc_sub).or(where(id: guest_webinar_ids))
  }

  # Webinaires sur lesquels `user` peut *gérer* (lire inscrits, piloter
  # enregistrements, transcripts, intervenants, co-animateurs). Exclut
  # explicitement le `:guest_host` — invité limité à l'animation.
  scope :where_managed_by, ->(user) {
    next none if user.nil?
    next all if user.project_host?

    where(host_sub: user.oidc_sub)
  }

  before_validation :assign_slug_and_room, on: :create
  # Date déplacée ou webinaire dépublié : ses inscrits confirmés sont
  # prévenus après un délai d'apaisement (WebinarChangeNotice).
  after_update_commit -> { WebinarChangeNotice.track(self) },
                      if: -> { saved_change_to_starts_at? || saved_change_to_visibility? }

  # `free?` = webinaire gratuit ET non rattaché à un pack. Un webinaire
  # rattaché à un pack N'EST PAS gratuit même si `price_cents = 0` : le
  # prix vit alors sur le pack.
  def free?
    price_cents.zero? && pack.nil?
  end

  # Libellé prix affiché en catalogue et page avant-direct. Trois cas :
  #   • gratuit          → « Gratuit »
  #   • prix propre      → « 99,00 € »
  #   • rattaché à pack  → « Inclus dans le pack <name> »
  #
  # `ActiveSupport::NumberHelper.number_to_currency` plutôt que le view
  # helper : le modèle ne charge pas ActionView (séparer thread-aware/ignorant).
  def price_label
    return I18n.t("webinars.price.free") if free?
    return I18n.t("webinars.price.in_pack", name: pack.name) if pack

    ActiveSupport::NumberHelper.number_to_currency(
      price_cents / 100.0, unit: "€", locale: :fr
    )
  end

  def kind_label
    I18n.t("catalogue.kinds.#{kind}", default: kind.humanize)
  end

  # Tonalité de l'émission (Voice) : son `kind`.
  def voice
    kind
  end

  def planned_ends_at
    starts_at + PLANNED_DURATIONS.fetch(kind)
  end

  # Agenda : passé = complément exact des trois groupes de l'accueil (en
  # direct, en retard, à venir), pour que les deux pages disent la même
  # chose : direct terminé, ou brouillon jamais lancé au-delà de
  # LATE_START_WINDOW. Un direct en cours n'est jamais passé. Même `now`
  # que les scopes pour un même affichage.
  def past?(now = Time.current)
    ended? || (draft? && starts_at < now - LATE_START_WINDOW)
  end

  # Une inscription créée maintenant ouvre-t-elle la salle sans attendre la
  # confirmation du mail (Registration#grant_instant_access!) ? Pendant le
  # direct, ou dans le quart d'heure qui précède un début encore attendu.
  def instant_access_open?(now = Time.current)
    live? || (draft? && !past?(now) && starts_at - INSTANT_ACCESS_LEAD <= now)
  end

  # Description en texte brut pour les agendas (.ics, Google Agenda). La
  # page publique la rend via `simple_format(sanitize: true)`, donc un
  # balisage saisi par l'animateur est possible : on n'en garde que le texte
  # (`:prune` jette aussi le contenu des balises dangereuses, <script> compris).
  def description_text
    Loofah.fragment(description.to_s).scrub!(:prune).to_text(encode_special_chars: false).strip
  end

  # Rôle d'un utilisateur sur CE webinaire — autorité unique de
  # décision. Tous les autres contrôles (`can_animate?`, scopes, controllers, LiveKit
  # identity, TrackRecordingSession) dérivent de cette méthode. Ordre
  # strict (propriétaire bat le reste pour que la journalisation
  # d'« owner » reste stable même quand le propriétaire est aussi dans
  # live-animateurs) :
  #   1. :owner        → `user.oidc_sub == host_sub`
  #   2. :project_host → `user.project_host?` (groupe OIDC fresh / ENV / admin)
  #   3. :guest_host   → email dans `webinar_hosts` (case-insensitive) ET
  #                      user.email_verified ET (claimed_sub nil → le pose,
  #                      claimed_sub présent → doit égaler user.oidc_sub)
  #   4. nil           → aucun droit d'animation
  #
  # Durcissement sécurité :
  #   • broken-authentication : un simple match email NE SUFFIT PAS. Il
  #     faut un email VÉRIFIÉ côté Pocket ID, et à la PREMIÈRE résolution
  #     l'invitation se lie au `sub` du user (WebinarHost#claimed_sub) ;
  #     tout autre sub pour la MÊME invitation est ensuite refusé.
  #
  # @param user [User, nil]
  # @return [Symbol, nil]
  def role_for(user)
    return nil if user.nil?
    return :owner        if user.oidc_sub == host_sub
    return :project_host if user.project_host?

    guest_role_for(user)
  end

  # L'utilisateur a-t-il un rôle d'animation sur ce webinaire (quel qu'il
  # soit) ? Remplace littéralement l'ancien `host_sub == user.oidc_sub`.
  def animated_by?(user)
    role_for(user) != nil
  end

  # Capacités (matrice). Nommées en VERBE pour que la
  # lecture dans un controller/vue soit directe :
  #   • can_animate?            scène, go_live/end_live, mains levées,
  #                              start/stop recording EN TANT QU'ANIMATEUR
  #   • can_manage_speakers?    ajouter/retirer un intervenant
  #   • can_manage_registrations? liste des inscrits (CSV, PII)
  #   • can_manage_recordings?  lister/télécharger les enregistrements
  #                              (le pilotage temps réel reste animable)
  #   • can_manage_transcripts? télécharger le .txt transcript
  #   • can_manage_hosts?       ajouter/retirer des co-animateurs
  #   • can_edit_program?       sujet, intervenants annoncés, animateur du jour
  #
  # Un `:guest_host` ne reçoit QUE `can_animate?` et ce qui en dérive
  # (`can_edit_program?`) — invariant central : les invités sont « limités à
  # l'animation », dont l'annonce de ce qui sera animé fait partie.
  def can_animate?(user)
    role_for(user) != nil
  end

  def can_manage_speakers?(user)
    %i[owner project_host].include?(role_for(user))
  end

  def can_manage_registrations?(user)
    %i[owner project_host].include?(role_for(user))
  end

  def can_manage_recordings?(user)
    %i[owner project_host].include?(role_for(user))
  end

  def can_manage_transcripts?(user)
    %i[owner project_host].include?(role_for(user))
  end

  def can_manage_hosts?(user)
    %i[owner project_host].include?(role_for(user))
  end

  # Sujet, intervenants annoncés, animateur du jour : toute l'animation, pour
  # que les rôles tournent sans passer par le propriétaire.
  def can_edit_program?(user)
    can_animate?(user)
  end

  # Reconduction des co-animateurs : le webinaire qui
  # précède celui-ci chez le même propriétaire, par date de début.
  def previous_by_owner
    self.class.hosted_by(host_sub).where(starts_at: ...starts_at).where.not(id: id)
        .order(starts_at: :desc, id: :desc).first
  end

  # Co-animateurs du webinaire précédent absents de celui-ci : proposés à la
  # reprise, jamais repris sans le geste d'un gestionnaire. Un co-animateur
  # créé après la fin du précédent (lien accepté ou ajout à la main) n'est
  # pas proposé.
  def carryover_hosts
    previous = previous_by_owner
    return WebinarHost.none unless previous

    hosts = previous.webinar_hosts.where.not(email: webinar_hosts.select(:email))
    hosts = hosts.where(created_at: ..previous.ended_at) if previous.ended_at
    hosts.order(:created_at, :id)
  end

  # Reprend ceux des `carryover_hosts` dont l'email est coché. Le rattachement
  # au compte (`claimed_sub`) suit : c'est la même personne qui revient, pas
  # n'importe quel compte qui présenterait la même adresse.
  # @return [Array<WebinarHost>] les co-animateurs créés
  def carry_over_hosts!(emails, invited_by_sub:)
    chosen = carryover_hosts.where(email: Array(emails).map { |email| email.to_s.strip.downcase })
    transaction do
      chosen.map do |host|
        webinar_hosts.create!(email: host.email, invited_by_sub: invited_by_sub, claimed_sub: host.claimed_sub)
      end
    end
  end

  private

  # Résolution :guest_host — défense broken-authentication.
  #
  # Invariants (chacun bloquant) :
  #   • `user.email_verified?` — un email NON vérifié côté Pocket ID
  #     n'identifie personne (self-signup, typo, usurpation). Sans ce
  #     claim, aucun droit d'invité.
  #   • `claimed_sub` : à la première revendication réussie, l'invitation
  #     est COLLÉE au sub (immuable côté Pocket ID). Toute connexion
  #     ultérieure sous un AUTRE sub avec le MÊME email est refusée —
  #     même si l'email a été renommé côté Pocket ID (le sub est roi,
  #     invariant déjà posé pour `User.find_or_create_by_oidc!`).
  #
  # Mutation write-through idempotente : la première résolution pose
  # `claimed_sub` et retourne :guest_host. Deux requêtes concurrentes
  # du même user avec claimed_sub nil écrivent la même valeur ;
  # ActiveRecord::RecordInvalid est capturé par prudence (course perdue
  # → on refuse, l'appel suivant lira la valeur gagnante).
  def guest_role_for(user)
    # Durcissement sécurité (broken-authentication §1a) :
    # l'email utilisé pour matcher l'invitation DOIT être celui qui a
    # été vérifié par Pocket ID (claim `email_verified`). Si un flux
    # applicatif latéral modifie `user.email` sans refaire la paire
    # (`email_verified_for`), `email_verified_and_fresh?` retourne
    # `false` → aucun rôle d'invité accordé.
    return nil unless user.email_verified_and_fresh?

    host = webinar_hosts.where("LOWER(email) = ?", user.normalized_email).first
    return nil if host.nil?

    if host.claimed_sub.blank?
      begin
        host.update!(claimed_sub: user.oidc_sub)
      rescue ActiveRecord::RecordInvalid
        return nil
      end
      :guest_host
    elsif host.claimed_sub == user.oidc_sub
      :guest_host
    end
  end

  public

  # URL lisible : webinar_path(w) → /webinars/<slug>, jamais /webinars/42.
  # Le slug est unique (index DB) et immuable après création (aucun setter
  # exposé au controller).
  def to_param
    slug
  end

  # Transition draft → live. Pose `started_at` (utilisé par le champ
  # `live_since` du endpoint public /w/:slug/state.json). `with_lock`
  # évite qu'un double-clic host déclenche deux go_live concurrents.
  #
  # @raise [TransitionError] si state != draft
  def go_live!
    with_lock do
      raise TransitionError, "webinaire déjà #{state} (transition go_live refusée)" unless draft?

      update!(state: "live", started_at: Time.current)
    end
  end

  # Transition live → ended. Pose `ended_at`. Nommée `end!` (mot-clé
  # Ruby OK en nom de méthode grâce au `!`). Appelée par LiveEnding, le
  # chemin commun de « Terminer le direct » et de la fin automatique.
  #
  # @raise [TransitionError] si state != live
  def end!
    HandRaiseControl.new(self).end_webinar
  end

  # Transition ended → live : l'animateur reprend un
  # direct terminé. `started_at` garde le premier démarrage (live_since) ;
  # `ended_at` est effacé, le direct n'est plus terminé.
  #
  # @raise [TransitionError] si state != ended
  def resume!
    with_lock do
      raise TransitionError, "webinaire #{state} (reprise refusée : seul un direct terminé se reprend)" unless ended?

      update!(state: "live", ended_at: nil, room_empty_since: nil)
    end
  end

  # Salle LiveKit vide pendant le direct (webhook `room_finished`). Écriture
  # conditionnelle : seul un direct en cours est concerné, et la PREMIÈRE
  # vacance est gardée — un webhook rejoué ne repousse pas l'échéance de la
  # fin automatique (AutoEndLiveJob).
  #
  # @return [Boolean] true si la vacance vient d'être relevée
  def mark_room_empty!(at = Time.current)
    self.class.where(id: id, state: "live", room_empty_since: nil)
        .update_all(room_empty_since: at, updated_at: Time.current) == 1
  end

  # Un participant a rejoint la salle : la vacance relevée ne vaut plus,
  # la fin automatique programmée n'aura pas lieu.
  def mark_room_occupied!
    self.class.where(id: id).where.not(room_empty_since: nil)
        .update_all(room_empty_since: nil, updated_at: Time.current)
  end

  # Génère ou régénère le lien d'invitation partagé. L'ancien jeton
  # devient immédiatement invalide (overwrite + find_by sur share_token).
  # `with_lock` protège contre deux générations concurrentes sur la même
  # ligne (dernier gagne, mais aucun des deux ne lit l'ancien).
  def generate_share_token!
    with_lock do
      update!(share_token: SecureRandom.urlsafe_base64(SHARE_TOKEN_BYTES))
    end
    share_token
  end

  # Régénération depuis la régie, ouverte à toute l'animation (co-animateur
  # invité compris, pendant le direct seulement — contrôleur) : elle ferme une
  # porte, elle n'en ouvre jamais. Sans lien
  # actif, rien ne change : créer le lien reste à la gestion des intervenants
  # (generate_share_token!, owner et project_host).
  # @return [String, nil] le nouveau jeton ; nil sans lien actif
  def regenerate_share_token!
    with_lock do
      update!(share_token: SecureRandom.urlsafe_base64(SHARE_TOKEN_BYTES)) if share_token.present?
    end
    share_token
  end

  # Empreinte du lien partagé actif : la régie reconnaît le lien qu'elle
  # affiche (remplacé depuis par un autre animateur ?) sans que le jeton
  # voyage dans un GET. nil sans lien actif.
  def share_token_fingerprint
    share_token && Digest::SHA256.hexdigest(share_token).first(16)
  end

  # Désactive le lien partagé (NULL). Les Speakers déjà créés via ce
  # lien restent valides (chaque Speaker a son propre token nominatif).
  def disable_share_token!
    with_lock do
      update!(share_token: nil) if share_token.present?
    end
  end

  # Lookup opaque par share_token — comparaison en temps constant pour
  # neutraliser toute heuristique de timing côté client (double garantie
  # malgré le lookup B-tree qui est déjà court-circuit sur chaîne).
  # @return [Webinar, nil]
  def self.find_by_active_share_token(token)
    return nil unless token.is_a?(String) && token.present?

    candidate = where.not(share_token: nil).find_by(share_token: token)
    return nil unless candidate
    return nil unless ActiveSupport::SecurityUtils.secure_compare(candidate.share_token.to_s, token)

    candidate
  end

  # Compte des intervenants (actifs ou révoqués) utilisé par le plafond
  # côté lien partagé. Un révoqué qui compterait toujours ferme la porte
  # à un attaquant qui invite→révoque en boucle pour saturer la table.
  # Une régénération remplace une ligne par une autre : l'ancienne, marquée
  # `replaced_by`, ne compte pas une seconde fois.
  def speaker_capacity_reached?
    speakers.where(replaced_by_id: nil).count >= SPEAKER_LIMIT
  end

  # Les jetons résolvent encore ? Direct en cours : toujours. Direct
  # terminé : jusqu'à `ended_at` + LINK_ACCESS_GRACE. Jamais clos : jusqu'à
  # la fin prévue + la même grâce. Sans `starts_at` (et sans fin datée),
  # on ne coupe pas — il n'y a pas de borne à appliquer.
  def link_access_open?(now = Time.current)
    return true if live?

    deadline = link_access_deadline
    deadline.nil? || now < deadline
  end

  # Échéance affichée et appliquée. nil pendant un direct (les jetons
  # restent valables) ou quand aucune borne n'existe.
  def link_access_deadline
    return nil if live?
    return ended_at + LINK_ACCESS_GRACE if ended? && ended_at
    return planned_ends_at + LINK_ACCESS_GRACE if starts_at

    nil
  end

  # Résolution d'un lien intervenant.
  #
  # Le fallback
  # `find_signed` sur l'ancien `Webinar#speaker_token` (signed_id Rails)
  # est RETIRÉ : seul un `Speaker` nominatif ACTIF résout. Un ancien
  # lien signé envoyé encore en circulation renvoie désormais `nil`,
  # le controller rend 404 (page « lien invalide » propre).
  #
  # Rationale : la surface de legacy (identité `speaker-legacy-*`,
  # exemption dans la garde webhook, chemin spécial `identity_for`)
  # était un angle d'attaque auxiliaire — on la supprime au lieu de
  # l'exempter.
  def self.find_for_speaker(slug:, token:)
    return nil unless token.is_a?(String) && slug.is_a?(String) && token.present? && slug.present?

    speaker = Speaker.active.joins(:webinar).find_by(token: token, webinars: { slug: slug })
    return nil unless speaker&.webinar&.link_access_open?

    [ speaker.webinar, speaker ]
  end

  private

  # Génère un slug lisible depuis le titre, sinon fallback hex si titre
  # sans caractères ASCII utilisables. Collision → suffixe -2, -3, …
  # bornée par un compteur pour éviter une boucle infinie théorique.
  def assign_slug_and_room
    base = title.to_s.parameterize.presence || SecureRandom.hex(4)
    self.slug      = unique_slug_from(base) if slug.blank?
    prefix = ENV.fetch("LIVEKIT_ROOM_PREFIX", "")
    raise ArgumentError, "invalid LIVEKIT_ROOM_PREFIX" unless prefix.match?(/\A[a-z0-9-]*\z/)
    self.room_name = "#{prefix}#{slug}" if room_name.blank?
  end

  MAX_SLUG_ATTEMPTS = 50
  private_constant :MAX_SLUG_ATTEMPTS

  def unique_slug_from(base)
    candidate = base
    MAX_SLUG_ATTEMPTS.times do |i|
      break unless RESERVED_SLUGS.include?(candidate) || self.class.exists?(slug: candidate) || self.class.exists?(room_name: candidate)
      candidate = "#{base}-#{i + 2}"
    end
    candidate
  end
end
