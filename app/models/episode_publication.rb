# Publication d'un épisode dans Nextcloud : à la fin d'un direct, une fois les enregistrements
# finalisés et les assemblages faits, le contenu de l'épisode est déposé,
# puis les intervenants sont prévenus.
#
#   queued → publishing → published
#                       ↘ failed (rejouable : relance automatique ou bouton)
#
# Deux dossiers par épisode (des jetons et e-mails de
# clients ont été vus dans un partage d'écran) : ce qui peut montrer un écran
# partagé — composite, pistes d'écran — va dans le dossier de RELECTURE,
# hors de tout partage ; le reste (caméras, micros, assemblages,
# transcription) va dans le dossier PARTAGÉ de la série. Une vidéo à
# relire n'arrive dans le dossier partagé que par « Valider et partager »
# (`approve!`), qui la fait déplacer au dépôt suivant.
#
# Une ligne par webinaire : l'état du DERNIER dépôt. Le dépôt est
# idempotent (une piste ou un composite déjà présent à la bonne taille
# n'est pas renvoyé ; un assemblage refait l'est, cf. EpisodePublisher) et
# une relance ne renvoie jamais deux fois le même mail
# (`notified_emails`, vidé seulement quand un nouveau fichier est partagé).
#
# Un passage en échec laisse un marqueur pour la supervision de l'hôte
# (PublicationFailureMarker), qui peut alerter une fois par publication et par
# raison.
#
# Déclencheurs : EpisodePublicationSweepJob (automatique, `due?`) et les
# boutons de la page du webinaire (WebinarPublicationsController).
class EpisodePublication < ApplicationRecord
  STATUSES = %w[queued publishing published failed].freeze
  enum :status, STATUSES.index_with(&:itself), validate: true

  # Au-delà, un dépôt resté « en cours » est présumé interrompu (processus
  # tué pendant l'upload) : il peut être relancé.
  STALL_AFTER = 3.hours
  # Le dépôt automatique ne vise que les directs terminés depuis moins de
  # AUTOMATIC_WINDOW (un direct plus ancien se publie au bouton), et pas
  # avant QUIET_PERIOD : une reprise juste après la fin (fin automatique
  # d'une salle vide, clic par erreur) ne doit rien envoyer aux intervenants.
  AUTOMATIC_WINDOW = 24.hours
  QUIET_PERIOD = 10.minutes

  # Zone de chaque fichier déposé (`files[]["zone"]`) :
  #   shared     dans le dossier partagé de la série ;
  #   review     dans le dossier de relecture, en attente de validation ; le job
  #              ne le réécrit jamais (le relecteur peut le couper sur place) ;
  #   approved   validé par l'animation, déplacé au dépôt suivant ;
  #   withdrawn  absent du dossier de relecture avant validation : jamais partagé.
  #              Aussi si ce dossier est renommé ou si la configuration change ;
  #              pour qu'une vidéo soit redéposée, retirer son entrée de `files`.
  # Des vidéos en relecture, les intervenants (README, mail) ne lisent que
  # cette phrase : ni nom ni lien.
  IN_REVIEW_NOTICE = "D'autres vidéos du direct (vidéo complète, partage d'écran) sont en relecture : " \
                     "elles seront ajoutées au dossier une fois validées."

  # Une série publiée (config/episode_publication.yml). Les deux dossiers
  # ne s'emboîtent jamais : un partage de dossier couvre ses sous-dossiers.
  Series = Data.define(:folder, :review_folder, :reviewers) do
    def initialize(folder:, review_folder:, reviewers: [])
      nested = [ [ folder, review_folder ], [ review_folder, folder ] ].any? do |inner, outer|
        inner == outer || inner.start_with?("#{outer}/")
      end
      raise ArgumentError, "dossiers partagé et de relecture emboîtés : #{folder}, #{review_folder}" if nested

      super(folder: folder, review_folder: review_folder, reviewers: Array(reviewers).map(&:to_s).freeze)
    end
  end

  SERIES = Rails.application.config_for(:episode_publication)
                .to_h { |kind, settings| [ kind.to_s, Series.new(**settings) ] }.freeze

  belongs_to :webinar, inverse_of: :episode_publication

  def self.series(webinar)
    SERIES[webinar.kind]
  end

  def self.client
    Rails.configuration.x.nextcloud_client_factory.call
  end

  def self.configured_for?(webinar)
    series(webinar).present? && client.present?
  end

  # Publication automatique : la série est configurée, rien ne la retient
  # (`automatic_hold`), et l'épisode n'a jamais été déposé, ou un dépôt est
  # resté bloqué, ou l'épisode a changé depuis le dernier dépôt (direct
  # repris, assemblage, transcription ou accord à l'image arrivés après un
  # dépôt manuel). Un dépôt en échec n'est pas relancé ici tant que rien ne
  # change : la relance automatique est celle de PublishEpisodeJob
  # (retry_on), puis le bouton. Un accord donné ou retiré après le dernier
  # dépôt le fait refaire même hors fenêtre (`consents_changed?`).
  def self.due?(webinar, now: Time.current)
    return false unless configured_for?(webinar)

    publication = webinar.episode_publication
    return true if consents_changed?(webinar, publication, now)
    return false unless automatic_hold(webinar, now: now).nil?
    return true if publication.nil?
    return false if publication.busy?(now)
    return true if publication.queued? || publication.publishing?

    publication.started_at.nil? || publication.started_at < last_change_at(webinar)
  end

  # Ce qui retient le dépôt automatique (nil : rien), affiché sur la page du
  # webinaire. Seul endroit où ces conditions sont écrites.
  #   :not_ended  direct pas terminé
  #   :draft      brouillon (essais, recettes) : jamais publié seul
  #   :too_old    terminé depuis plus de AUTOMATIC_WINDOW
  #   :quiet      terminé depuis moins de QUIET_PERIOD
  #   :recording  un enregistrement capte ou s'arrête encore
  #   :empty      ni enregistrement terminé ni transcription
  #   :muxing     un assemblage manque, est en cours ou date d'avant la dernière piste
  #   :lightening une version légère se prépare (LightVersion), au plus WAIT
  #               après sa demande ; le balayage écrit les demandes
  def self.automatic_hold(webinar, now: Time.current)
    return :not_ended unless webinar.ended? && webinar.ended_at
    return :draft if webinar.visibility_draft?
    return :too_old if webinar.ended_at < now - AUTOMATIC_WINDOW
    return :quiet if webinar.ended_at > now - QUIET_PERIOD
    return :recording if webinar.recordings.active.exists?
    return :empty unless content?(webinar)

    return :muxing if unmuxed_identities(webinar).any?

    :lightening if waiting_light_versions(webinar, now).any?
  end

  # Versions légères que le dépôt automatique attend ; vide si elles sont
  # désactivées ou la publication non configurée.
  def self.waiting_light_versions(webinar, now = Time.current)
    return [] unless LightVersion.enabled? && configured_for?(webinar)

    EpisodeManifest.new(webinar, series: series(webinar)).light_versions.select { |light| light.waiting?(now) }
  end

  # Personnes dont une piste terminée n'est couverte par aucun assemblage
  # terminal (fait ou en échec) lancé APRÈS la fin de leur dernière piste :
  # un assemblage de répétition ne couvre pas la séance.
  def self.unmuxed_identities(webinar)
    recordings = webinar.recordings.unscope(:order)
    last_track_end = recordings.tracks.done.where.not(participant_identity: [ nil, "" ])
                               .group(:participant_identity).maximum(:ended_at)
    last_mux_start = recordings.participants.where(status: %w[done failed])
                               .group(:participant_identity).maximum(:started_at)
    last_track_end.filter_map do |identity, track_end|
      mux_start = last_mux_start[identity]
      identity unless mux_start.present? && (track_end.nil? || mux_start >= track_end)
    end
  end

  def self.content?(webinar)
    webinar.recordings.done.exists? || webinar.transcript_segments.exists?
  end

  def self.last_change_at(webinar)
    [ webinar.ended_at,
      webinar.recordings.unscope(:order).done.maximum(:updated_at),
      webinar.transcript_segments.maximum(:updated_at),
      webinar.participant_consents.maximum(:updated_at) ].compact.max
  end

  # Un accord à l'image donné ou retiré (`updated_at`) après le dernier
  # dépôt : le tableau des accords du README et `<épisode>-extraits.json`,
  # sur lesquels le montage décide, sont périmés. Redéposés quel que soit
  # l'âge du direct, mais jamais pendant un direct, pendant qu'un
  # enregistrement capte encore, ni par-dessus un dépôt en cours, ni pour un
  # épisode jamais déposé (la publication normale s'en charge).
  def self.consents_changed?(webinar, publication, now)
    return false if publication&.started_at.nil? || publication.busy?(now)
    return false unless webinar.ended? && !webinar.recordings.active.exists?

    changed_at = webinar.participant_consents.maximum(:updated_at)
    changed_at.present? && publication.started_at < changed_at
  end

  def self.enqueue!(webinar)
    publication = create_or_find_by!(webinar: webinar) { |created| created.status = "queued" }
    publication.update!(status: "queued", queued_at: Time.current)
    PublishEpisodeJob.perform_later(webinar.id)
    publication
  end

  def busy?(now = Time.current)
    since = publishing? ? started_at : queued_at
    (queued? || publishing?) && since.present? && since > now - STALL_AFTER
  end

  def start!(folder:, review_folder:)
    update!(status: "publishing", folder: folder, review_folder: review_folder, started_at: Time.current,
            attempts: attempts + 1, error_message: nil)
  end

  # `deposited` = fichiers déposés et vérifiés ({ "name", "size", "zone" },
  # plus "version" pour un assemblage : ce qui décide de son renvoi).
  # Un nouveau fichier PARTAGÉ rouvre la notification : chaque intervenant
  # reçoit la liste à jour. Un fichier réécrit sous le même nom
  # (transcription complétée, README) ou arrivé en relecture ne prévient
  # personne. Une validation enregistrée pendant le dépôt (après sa
  # lecture des zones) est gardée : le dépôt suivant la traitera.
  def complete!(deposited:, folder_url:, review_folder_url:)
    with_lock do
      late = files_in("approved").index_by { |file| file["name"] }
      kept = deposited.map { |file| file["zone"] == "review" ? late.fetch(file["name"], file) : file }
      new_file = (shared_names(kept) - shared_names(files)).any?
      update!(status: "published", files: kept, folder_url: folder_url, review_folder_url: review_folder_url,
              published_at: Time.current, notified_emails: new_file ? [] : notified_emails, deposited_versions: {})
    end
    PublicationFailureMarker.new(self).clear!
  end

  # Assemblage déposé et vérifié dans le dossier partagé, noté aussitôt (avant
  # la fin du dépôt) : sa version, sous son nom. Une reprise après un échec ne
  # le renvoie pas tant qu'il n'est pas refait. Hors de `files`, qui reste
  # l'état du dernier dépôt ABOUTI (`complete!` y compare les fichiers
  # partagés pour rouvrir la notification) ; vidé par `complete!`.
  def record_deposited_version!(name, version)
    with_lock { update!(deposited_versions: deposited_versions.merge(name => version)) }
  end

  # Vidéo déposée en relecture, notée dès son dépôt vérifié (avant la fin
  # du dépôt) : une reprise après un échec ne la renverra pas par-dessus la
  # version que le relecteur aurait déjà coupée ou supprimée.
  def record_review_deposit!(entry)
    with_lock { update!(files: files.reject { |file| file["name"] == entry["name"] } + [ entry ]) }
  end

  # « Valider et partager » : l'animation valide les fichiers en relecture
  # qu'elle a vus (`names`, ceux affichés sur sa page : un fichier arrivé
  # depuis n'est pas validé). Rend le nombre de fichiers validés.
  def approve!(names, by:)
    with_lock do
      approved = files.map do |file|
        next file unless file["zone"] == "review" && names.include?(file["name"])

        file.merge("zone" => "approved", "approved_by" => by, "approved_at" => Time.current.iso8601)
      end
      count = files_in("review").size - approved.count { |file| file["zone"] == "review" }
      update!(files: approved) if count.positive?
      count
    end
  end

  # « Valider et partager » est proposé : direct terminé, des vidéos en
  # relecture, aucun dépôt en cours. La configuration de la série, que
  # WebinarPublicationsController refuse aussi, reste à vérifier par l'appelant.
  def approvable?(now = Time.current)
    webinar.ended? && files_in("review").any? && !busy?(now)
  end

  def files_in(*zones)
    files.select { |file| zones.include?(file["zone"]) }
  end

  # Passage en échec : message sur la page du webinaire, et marqueur pour
  # la supervision de l'hôte (PublicationFailureMarker). `reason` : ce que dit
  # l'alerte, sans le nom du fichier en cause (il porte celui d'un
  # participant) ; par défaut, le message. `alert: false` : une attente qui
  # n'est pas une panne (direct repris), sans alerte.
  def fail!(message, reason: nil, alert: true)
    update!(status: "failed", error_message: message.to_s.truncate(500))
    PublicationFailureMarker.new(self).write!(reason || error_message) if alert
  end

  def notified?(email)
    notified_emails.include?(email)
  end

  def record_notification!(email)
    update!(notified_emails: notified_emails | [ email ], notified_at: Time.current)
  end

  private

  def shared_names(list)
    list.select { |file| file["zone"] == "shared" }.pluck("name")
  end
end
