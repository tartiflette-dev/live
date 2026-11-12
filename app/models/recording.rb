class Recording < ApplicationRecord
  # Recording.
  #
  # Machine d'état :
  #
  #   starting → recording → stopping → done
  #          ↘ failed (à toute étape)
  #
  # `starting` = démarrage demandé, egress pas encore confirmé. Un COMPOSITE
  # y reste tant que livekit répond EGRESS_STARTING (egress_id posé dès la
  # réponse de start, le temps que Chrome rejoigne la salle) et ne passe
  # `recording` qu'une fois l'egress ACTIF constaté, dans la réponse de start
  # ou par la réconciliation (poll de statut, ensure_active, create) : la
  # scène n'affiche « REC » qu'à ce moment. Une PISTE passe `recording` dès
  # la réponse de start (EgressCompletion). `stopping` = stop_egress appelé, retour attendu.
  # `done` = fichier écrit sur disque (path posé). `failed` = TOUT chemin
  # d'erreur (invariant fail-loud : jamais un Recording ne reste ambigu).
  #
  # Pas d'AASM — 3-4 transitions triviales, Rails omakase.

  belongs_to :webinar

  # `participant` = Recording synthétique mixé par MuxParticipantJob —
  # caméra (H.264 → mp4, VP8/VP9 → webm) + micro d'une personne, recalés sur
  # started_at. UN par lot de pistes couvert (`source_track_ids`, migration
  # 20261030110100) : répétition, séance et reprise du direct ont chacune
  # leur montage. Le lot couvert est l'ensemble des pistes `done` prises en
  # compte ; le montage en assemble au plus une caméra et un micro.
  KINDS = %w[composite track participant].freeze
  enum :kind, KINDS.index_with(&:itself), validate: true, scopes: false
  scope :composite, -> { where(kind: "composite") }
  scope :tracks, -> { where(kind: "track") }
  scope :participants, -> { where(kind: "participant") }
  # Enregistrements portés par un egress LiveKit — les seuls qu'un arrêt
  # concerne. Un montage participant est produit par Rails (ffmpeg), sans
  # egress : l'« arrêter » le marquerait fini sans fichier.
  scope :from_egress, -> { where(kind: %w[composite track]) }

  STATUSES = %w[starting recording stopping done failed].freeze
  enum :status, STATUSES.index_with(&:itself), validate: true

  # Unicité egress_id : gardé côté DB (index unique) ET côté validation Rails
  # pour un feedback lisible. `allow_nil` car le chemin `starting → failed`
  # peut se produire AVANT le retour livekit-server (aucun egress_id à ce
  # moment). Deux Recording.status=starting avec egress_id=nil = OK (SQLite
  # autorise plusieurs NULL dans un index UNIQUE — cohérent).
  validates :egress_id, uniqueness: true, allow_nil: true

  # Un « recording actif » = start posé mais pas encore terminé (succès
  # OU échec). Utilisé par le controller pour empêcher deux enregistrements
  # concurrents sur le même webinaire (garde métier).
  ACTIVE_STATUSES = %w[starting recording stopping].freeze
  scope :active, -> { where(status: ACTIVE_STATUSES) }

  # En captation : egress lancé et pas encore en arrêt — seuls états où un
  # stop a un sens.
  CAPTURING_STATUSES = %w[starting recording].freeze
  scope :capturing, -> { where(status: CAPTURING_STATUSES) }

  # Un seul Recording COMPOSITE actif par webinaire — INVARIANT doublé côté
  # DB par un index unique partiel (cf. migration 20260924143739). La
  # validation applicative donne un message lisible ; la contrainte DB
  # attrape la race que la validation seule laisse passer (SELECT/INSERT
  # non atomique entre deux onglets host ou reload concurrent).
  #
  # SCOPE au kind='composite' : les tracks (un par participant/
  # source) coexistent ; seul le direct composite est unique.
  validate :only_one_active_composite_recording_per_webinar

  private

  def only_one_active_composite_recording_per_webinar
    return unless webinar_id.present? && status.present?
    return unless ACTIVE_STATUSES.include?(status.to_s)
    return unless kind.to_s == "composite"

    scope = self.class.active.composite.where(webinar_id: webinar_id)
    scope = scope.where.not(id: id) if persisted?
    return unless scope.exists?

    errors.add(:base, :active_composite_recording_exists,
               message: "un enregistrement composite actif existe déjà pour ce webinaire")
  end

  public

  # Rendu chronologique inverse pour l'index animateur.
  scope :recent_first, -> { order(started_at: :desc, created_at: :desc) }

  # Recording désigné par l'EgressInfo d'un webhook (egress_updated,
  # egress_ended) : par egress_id ; à défaut — réponse de démarrage perdue —
  # par piste ET préfixe exact. Une piste peut avoir plusieurs Recordings
  # (enregistrée de nouveau après une reprise du direct) : le préfixe désigne
  # le bon.
  def self.for_egress_info(webinar, info)
    found = webinar.recordings.find_by(egress_id: info["egress_id"])
    return found if found

    track_id = info.dig("track", "track_id")
    filepath = info.dig("track", "file", "filepath").to_s
    return if track_id.blank? || !filepath.start_with?("/data/")

    webinar.recordings.tracks.find_by(track_sid: track_id, egress_id: nil, output_prefix: filepath.delete_prefix("/data/"))
  end

  # Instant du premier échantillon écrit par l'egress de cette piste
  # (`media_started_at`, cf. migration 20261110071054). Le plus tôt reçu
  # l'emporte : un webhook rejoué, en double ou traité en retard ne le
  # recule pas. Rend le nombre de lignes modifiées (0 ou 1).
  def note_media_start(at)
    return 0 unless track?

    self.class.where(id: id).where("media_started_at IS NULL OR media_started_at > ?", at)
              .update_all(media_started_at: at)
  end

  # Relative output intent, unique per attempt. Track egress chooses
  # its extension from the actual codec; persist its returned filename later.
  # Pour kind=participant, l'extension est portée par l'appelant (mp4, webm
  # ou m4a selon ce qu'on a muxé — MuxParticipantJob).
  def filename_for(kind:, identity:, source:)
    raise ArgumentError, "unknown recording kind" unless KINDS.include?(kind.to_s)
    raise ArgumentError, "unsafe webinar slug" unless webinar.slug.to_s.match?(/\A[a-z0-9-]+\z/)

    segments = [ safe_filename_segment(identity), safe_filename_segment(source), SecureRandom.uuid ]
    extension = kind.to_s == "composite" ? ".mp4" : ""
    "#{webinar.slug}/#{segments.join('-')}#{extension}"
  end

  # Racine des fichiers — configurable via `RECORDINGS_ROOT`, posée par le
  # déploiement (le dossier partagé avec l'egress). Par défaut en dev/test =
  # `tmp/recordings` (jamais dans le repo, jamais dans un dossier système).
  def self.recordings_root
    Pathname.new(ENV.fetch("RECORDINGS_ROOT", Rails.root.join("tmp/recordings").to_s))
  end

  # Sous-arbre réservé aux Recording synthétiques `kind=participant`.
  # PRODUIT PAR RAILS (UID 1000, mode
  # 0750), JAMAIS par l'egress LiveKit : évite l'ACL mask r-x du dossier
  # <slug>/ créé par l'egress (UID 1001 mkdir 0750) qui bloquait l'écriture
  # ffmpeg (preuve de bout en bout : rc=243 EACCES). Même root volume,
  # arborescence distincte.
  #
  # SÉCURITÉ (revue post-commit) : le nom commence par `_` DÉLIBÉRÉMENT.
  # Le regex de slug Webinar (`\A[a-z0-9][a-z0-9\-]*\z`) refuse par
  # construction tout slug commençant par `_` → aucun webinaire ne peut
  # avoir un slug qui collisionnerait avec cette racine. L'autorisation
  # de téléchargement reste par Recording.id scopé à @webinar
  # (RecordingsController#set_recording), le chemin stocké est
  # revalidé sous `<root>/_participants/<webinar.slug>/` (controller +
  # modèle, double vérification). Une validation Webinar explicite
  # (`reserved_slugs`) empêche aussi tout contournement si le regex
  # venait à loosen.
  PARTICIPANTS_SUBDIR = "_participants"

  # Dossier parent des mux participants, sous `recordings_root/_participants/`.
  # Appelé par ParticipantMux pour mkdir_p : la racine `_participants/` et
  # le sous-dossier `<slug>/` sont tous deux créés PAR RAILS (owner UID
  # 1000) → pas d'héritage ACL de l'egress.
  def self.participants_root
    recordings_root.join(PARTICIPANTS_SUBDIR)
  end

  # Préfixe relatif attendu dans `Recording.path` selon le kind. Les
  # pistes/composite sont posés par l'egress sous `<slug>/`, les
  # participants mux sous `_participants/<slug>/`.
  def expected_path_prefix
    kind.to_s == "participant" ? "#{self.class::PARTICIPANTS_SUBDIR}/#{webinar.slug}/" : "#{webinar.slug}/"
  end

  # Chemin absolu du fichier sur disque, RÉSOLU depuis `path` (relatif) et
  # `recordings_root`. Retourne `nil` si `path` est vide (recording pas
  # encore terminé, ou failed sans fichier).
  #
  # DÉFENSE TRAVERSAL : `Pathname#cleanpath` normalise `..` ; on vérifie
  # ensuite que la résolution reste SOUS la racine scopée ET que `path`
  # commence exactement par le préfixe attendu (`<slug>/` pour
  # composite/track, `_participants/<slug>/` pour participant). Un path
  # forgé qui sortirait de ce préfixe → nil (téléchargement 404, testé).
  #
  # @return [Pathname, nil]
  def absolute_path
    return nil if path.blank?

    root     = self.class.recordings_root.cleanpath
    prefix   = expected_path_prefix
    scoped   = root.join(prefix).cleanpath
    resolved = root.join(path).cleanpath

    # (1) doit être sous <root>/<prefix>
    return nil unless resolved.to_s.start_with?("#{scoped}/")
    # (2) doit correspondre au préfixe attendu dans le path stocké
    return nil unless path.to_s.start_with?(prefix)

    resolved
  end
  # Fichier présent sur disque ET statut terminal → le lien de téléchargement
  # est légitime. Extrait de la vue (la vue ne lit plus le disque, elle
  # décrit). Un seul lecteur = `_table.html.erb`.
  def downloadable?
    return false unless done?
    full = absolute_path
    full.present? && File.file?(full)
  end

  # Montage participant terminé avec une réserve, que `error_message` énonce
  # (MuxParticipantJob) : piste vide écartée, ou calage lèvres/voix
  # approximatif faute de début de fichier connu (ParticipantMux#note).
  def caveat?
    done? && error_message.present?
  end

  # Début du lot couvert par un montage participant (pistes écartées
  # comprises, comme le nom du fichier) : distingue, pour une même
  # personne, le montage de la répétition de celui de la séance.
  def sources_started_at
    webinar.recordings.tracks.where(id: source_track_ids.to_a).minimum(:started_at)
  end

  # Extension (incluant le `.`), dérivée du path persisté.
  def extension
    File.extname(path.to_s)
  end

  # Taille en octets du fichier résolu ; nil si introuvable (jamais levé).
  # Pendant du `downloadable?` : la vue n'ouvre plus de File directement.
  def size_on_disk
    full = absolute_path
    return nil if full.blank?
    File.size(full)
  rescue Errno::ENOENT
    nil
  end

  private

  def safe_filename_segment(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 60].presence || "unknown"
  end
end
