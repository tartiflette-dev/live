# frozen_string_literal: true

# EpisodePublisher — dépose l'épisode d'un webinaire dans Nextcloud puis
# prévient les intervenants. Appelé par
# PublishEpisodeJob.
#
# Deux dossiers (EpisodeManifest) : les vidéos qui peuvent montrer un écran
# partagé (`review?`) vont dans le dossier de RELECTURE, le reste dans le
# dossier PARTAGÉ. Une vidéo à relire n'atteint le dossier partagé que par
# un déplacement (MOVE), une fois validée par l'animation (zone
# `approved`) ; aucun autre chemin ne l'y écrit.
#
# Une vidéo à relire n'est envoyée qu'UNE fois, et notée dès son dépôt
# vérifié : ensuite, le fichier appartient au relecteur. Coupé (taille
# changée), il est gardé tel quel ; supprimé, il est « retiré » (zone
# `withdrawn`) et n'est plus jamais redéposé. Ce qui est déplacé à la
# validation est donc toujours la version relue, sans son historique de
# versions Nextcloud (purgé avant le déplacement, voir `share_approved`).
#
# Avant tout dépôt (chaque dossier de l'arborescence de relecture), puis de
# nouveau juste avant chaque vidéo déposée en relecture (le dossier qui la
# reçoit), la garde vérifie : aucun partage sur ce dossier ni sur aucun de
# ses parents (un partage de dossier couvre ses sous-dossiers), ni sur rien
# en dessous du dossier de relecture de l'épisode, hors partage utilisateur
# SANS droit de repartage à un relecteur nommé ; et le dossier est dans
# l'espace du compte (ni partage reçu ni stockage monté). Sinon rien n'est
# déposé (ou plus rien, s'il s'ouvre en cours de dépôt).
#
# Idempotent : une piste ou un composite déjà présent à la taille attendue
# n'est pas renvoyé (son fichier ne change plus) ; un assemblage l'est si sa
# version (fin de son dernier montage, cf. EpisodeManifest::MediaFile)
# diffère de celle notée à son dernier dépôt vérifié, ou si aucune ne l'est.
# Elle est notée dès ce dépôt vérifié (`deposited_versions`), pas à la fin :
# un dépôt interrompu plus loin ne le fait pas renvoyer. Une version légère
# prête après le dépôt de son original (LightVersion) n'a pas sa taille :
# elle le remplace au dépôt suivant, dans le dossier partagé seulement (une
# vidéo en relecture n'est envoyée qu'une fois). Les fichiers texte (README,
# transcription, sous-titres : quelques ko) sont réécrits à chaque dépôt.
# Chaque fichier déposé est relu (PROPFIND) et sa taille comparée à celle
# du fichier envoyé avant de compter comme déposé : un envoi tronqué repart
# à la reprise.
#
# Les intervenants ne sont prévenus qu'une fois le dépôt entier vérifié, et
# seulement si le direct est toujours terminé (une reprise pendant le dépôt
# reporte le mail au dépôt suivant).
#
# Toute erreur marque la publication en échec. Le message enregistré nomme
# le fichier en cause (page du webinaire) ; l'exception relancée ne le
# nomme pas : les noms de fichiers portent ceux des participants, et les
# exceptions finissent dans les journaux des jobs.
class EpisodePublisher
  # La taille relue ne correspond pas : rejoué comme une panne passagère.
  class SizeMismatch < NextcloudClient::TransientError; end
  # Le dossier de relecture est visible d'un autre compte : définitif.
  class ReviewFolderExposed < NextcloudClient::Error; end

  def initialize(webinar, client:, series:)
    @webinar = webinar
    @client  = client
    @series  = series
  end

  def call
    publication = EpisodePublication.create_or_find_by!(webinar: @webinar) { |created| created.status = "queued" }
    manifest = EpisodeManifest.new(@webinar, series: @series)
    publication.start!(folder: manifest.folder, review_folder: manifest.review_folder)

    prepare_folders(manifest)
    previous = publication.files.index_by { |file| file["name"] }
    previous.merge!(share_approved(manifest, previous.values))
    deposited = manifest.files.map { |file| deposit(manifest, publication, file, previous[file.name]) }
    # Accords pour les extraits : réécrits à chaque dépôt, comme le README.
    deposited += [ manifest.excerpt_consents_file ].compact.map { |file| deposit(manifest, publication, file, nil) }
    deposited << deposit(manifest, publication, readme(manifest, deposited), nil)
    @current_file = nil

    publication.complete!(deposited: deposited, folder_url: @client.internal_link(manifest.folder),
                          review_folder_url: @client.internal_link(manifest.review_folder))
    EpisodeNotification.new(publication).deliver if @webinar.reload.ended?
  rescue StandardError => error
    publication&.fail!(failure_message(error), reason: failure_reason(error))
    raise
  end

  private

  # Relecture d'abord : un dossier de relecture exposé arrête tout avant
  # que le dossier partagé ne soit touché.
  def prepare_folders(manifest)
    ensure_tree(manifest.review_folder, manifest).each { |folder| assert_private!(folder, manifest) }
    ensure_tree(manifest.folder, manifest)
  end

  # Crée le dossier et ses sous-dossiers ; rend leurs chemins.
  def ensure_tree(root, manifest)
    folders = [ root, *manifest.subfolders.map { |subfolder| "#{root}/#{subfolder}" } ]
    folders.each { |folder| @client.ensure_folder(folder) }
    folders
  end

  # `folder` : un dossier de l'arborescence de relecture de l'épisode. Le
  # message ne cite que des dossiers : un nom de fichier porte celui d'un
  # participant, et le message finit aussi dans les journaux des jobs.
  def assert_private!(folder, manifest)
    segments = folder.split("/")
    segments.each_index do |last|
      level = segments[0..last].join("/")
      refuse_exposed!(level, @client.shares_of(level))
    end
    refuse_exposed!("sous #{manifest.review_folder}", @client.shares_under(manifest.review_folder))
    permissions = @client.permissions_of(folder)
    return if permissions && !permissions.match?(/[SM]/)

    raise ReviewFolderExposed, "dossier de relecture hors de l'espace du compte (partage reçu ou stockage monté) : dépôt arrêté"
  end

  def refuse_exposed!(where, shares)
    exposed = shares.reject { |share| reviewer_only?(share) }
    return if exposed.empty?

    raise ReviewFolderExposed, "dossier de relecture partagé (#{where} : #{exposed.map(&:label).uniq.join(', ')}) : dépôt arrêté"
  end

  # Un relecteur nommé, par partage utilisateur, sans pouvoir le repartager.
  def reviewer_only?(share)
    share.user? && !share.reshare? && @series.reviewers.include?(share.with)
  end

  # Fichiers validés : déplacés de la relecture au dossier partagé. Déjà
  # déplacé (dépôt interrompu après le MOVE), il est reconnu à sa présence
  # côté partagé ; absent des deux côtés, il a été retiré pendant la relecture.
  #
  # Une coupe faite en remplaçant le fichier laisse le brut dans
  # l'historique des versions Nextcloud, et le MOVE emporte cet historique
  # (vérifié sur une instance Nextcloud). Datée comme le brut, la coupe
  # cache même ce brut derrière l'entrée de la version courante. Toutes les
  # entrées de l'historique sont donc purgées dans le dossier de relecture,
  # privé, avant le déplacement (NextcloudClient#purge_old_versions) ; s'il
  # reste une entrée ou un contenu, rien n'est déplacé. Le brut d'origine
  # reste dans les enregistrements de l'application.
  def share_approved(manifest, files)
    files.select { |file| file["zone"] == "approved" }.to_h do |file|
      @current_file = file["name"]
      from = "#{manifest.review_folder}/#{file['name']}"
      to   = "#{manifest.folder}/#{file['name']}"
      if @client.size_of(from)
        @client.purge_old_versions(from)
        @client.move(from, to)
      end
      size = @client.size_of(to)
      [ file["name"], file.merge("zone" => size ? "shared" : "withdrawn", "size" => size || file["size"]) ]
    end
  end

  def deposit(manifest, publication, file, previous)
    @current_file = file.name
    return deposit_for_review(manifest, publication, file, previous) if file.review?

    noted = publication.deposited_versions.fetch(file.name) { previous&.dig("version") }
    size = deposit_file("#{manifest.folder}/#{file.name}", file, noted)
    publication.record_deposited_version!(file.name, file.version) if file.version && file.version != noted
    { "name" => file.name, "size" => size, "zone" => "shared", "version" => file.version }.compact
  end

  # `previous` : la vidéo telle que notée par un dépôt précédent (zone
  # review, shared ou withdrawn ; les validées sont déjà déplacées).
  # Garde avant l'envoi, puis après : un partage posé pendant l'envoi d'un
  # gros fichier arrête le dépôt, et une validation ne sera pas déplacée
  # tant que le dossier reste exposé (garde de `prepare_folders`).
  def deposit_for_review(manifest, publication, file, previous)
    path = "#{manifest.review_folder}/#{file.name}"
    return keep_reviewer_version(path, previous) if previous

    assert_private!(File.dirname(path), manifest)
    entry = { "name" => file.name, "size" => deposit_file(path, file), "zone" => "review" }
    publication.record_review_deposit!(entry)
    assert_private!(File.dirname(path), manifest)
    entry
  end

  def keep_reviewer_version(path, previous)
    return previous unless previous["zone"] == "review"

    size = @client.size_of(path)
    size ? previous.merge("size" => size) : previous.merge("zone" => "withdrawn")
  end

  def deposit_file(path, file, noted_version = nil)
    expected = file.size
    unless already_deposited?(path, file, noted_version)
      file.upload_to(@client, path)
      found = @client.size_of(path)
      raise SizeMismatch, "taille relue #{found.inspect}, attendue #{expected}" unless found == expected
    end
    expected
  end

  # Fichier qui ne change plus, présent à la taille attendue. Un fichier
  # versionné (assemblage, qui peut être refait sous le même nom) doit en
  # outre porter la version notée à son dernier dépôt vérifié
  # (`noted_version` : EpisodePublication#deposited_versions, sinon le
  # dernier dépôt abouti) : sans version notée, ou d'une autre, il est
  # renvoyé même à taille égale.
  def already_deposited?(path, file, noted_version)
    file.immutable? && (file.version.nil? || noted_version == file.version) &&
      @client.size_of(path) == file.size
  end

  def readme(manifest, deposited)
    zones = deposited.to_h { |file| [ file["name"], file["zone"] ] }
    manifest.readme(manifest.files.select { |file| zones[file.name] == "shared" },
                    in_review: zones.value?("review"))
  end

  def failure_message(error)
    [ @current_file, failure_reason(error) ].compact.join(" : ")
  end

  def failure_reason(error)
    error.is_a?(NextcloudClient::Error) ? error.message : "erreur inattendue (#{error.class.name})"
  end
end
