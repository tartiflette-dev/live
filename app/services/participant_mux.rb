# frozen_string_literal: true

# ParticipantMux — recale et mixe les pistes d'un participant en UN
# fichier prêt au montage :
#   • caméra H.264 + micro → .mp4  (vidéo copiée, Opus → AAC) ;
#   • caméra VP8/VP9 + micro → .webm (vidéo ET Opus copiés) ;
#   • micro seul → .m4a (AAC).
#
# Pur objet de calcul : prend des Recordings `kind='track'` terminaux
# `done` (les `failed` sont IGNORÉS), sonde leur contenu
# (TrackProbe), construit une commande ffmpeg, et l'exécute sous Open3.
# Appelé par MuxParticipantJob (fallback webhook + fin de webinaire).
#
# Conteneur : il suit le codec VIDÉO réellement enregistré. L'egress
# écrit H.264 en .mp4 et VP8/VP9 en .webm (le H.264 imposé côté salle ne
# couvre pas tous les navigateurs) ; mp4 refuse VP8 (« Could not find tag
# for codec vp8 »). Le .webm accepte VP8/VP9 + Opus tels quels : aucun
# réencodage (pas de perte, 0 CPU — le job tourne dans le conteneur web
# plafonné, un transcodage d'une heure de VP8 n'y tiendrait pas), et le
# type `video/webm` est déjà servi par RecordingsController.
#
# Piste vide : une piste sans aucun paquet (ou illisible) est écartée,
# le montage se fait avec l'autre piste et le Result porte une `note`.
# Une sonde interrompue (délai, kill) n'écarte rien : le montage échoue
# (ProbeFailed) et reste relançable.
#
# Durée : pas de `-shortest`. Une piste plus courte que l'autre (caméra
# brève, micro d'une heure) ne doit jamais tronquer le montage.
#
# Recalage : chaque piste est placée à l'instant où commence SON FICHIER.
# L'egress de piste rebase le fichier à 0 sur le premier échantillon écrit :
# l'audio au premier paquet, la vidéo à la première image clé, de 0,09 à
# 1,64 s plus tard (mesuré sur deux directs). Cet instant est `media_started_at`
# (passage EGRESS_ACTIVE, EgressActivationJob), corrigé pour la vidéo de
# VIDEO_ACTIVATION_LAG (cf. la constante). t0 = le plus tôt des débuts ;
# chaque piste reçoit `-itsoffset <début - t0>` AVANT son `-i <path>`.
#
# Sans `media_started_at` pour l'une des deux pistes (webhook perdu, piste
# antérieure non reprise par `recordings:activations`), le recalage retombe
# sur `started_at` (heure de la demande d'egress, même horloge pour les
# deux) : la vidéo y est en avance du délai de première image clé ; le
# montage est produit et sa `note` le dit. On ne mélange jamais les deux
# horloges.
#
# Vidéo : toujours `-c:v copy`. Audio : Opus → AAC `-c:a aac -b:a 128k`
# dans mp4/m4a (corridor lecteurs Safari/QuickTime), Opus copié en webm.
#
# Pas d'AASM, pas de hexagone : Rails omakase — service POJO consommé par le job.
class ParticipantMux
  # Sources LiveKit retenues. On IGNORE `screen_share` et
  # `screen_share_audio` pour le montage (« vidéo caméra + audio
  # micro »). Un futur mux « écran » sera un job distinct si besoin.
  VIDEO_SOURCE = "camera"
  AUDIO_SOURCE = "microphone"

  # Erreurs levées PAR LE SERVICE (jamais avalées — le job les
  # transforme en Recording.failed, invariant fail-loud).
  class Error             < StandardError; end
  class MissingBinary     < Error; end # ffmpeg absent
  class NothingToMux      < Error; end # aucune piste exploitable
  class SourceMissing     < Error; end # un fichier source est absent du disque
  class FfmpegFailed      < Error; end # ffmpeg a retourné rc != 0
  class ProbeFailed       < Error; end # ffprobe interrompu : état d'une piste inconnu

  # Codecs vidéo que mp4 accepte tels quels ; tout autre va en webm
  # (VP8, VP9, AV1 ; un codec que webm refuse — HEVC — échoue visiblement
  # dans ffmpeg, le Recording passe `failed` avec le message).
  MP4_VIDEO_CODECS = %w[h264].freeze
  # Codecs audio que webm accepte tels quels (sinon réencodage en Opus).
  WEBM_AUDIO_CODECS = %w[opus vorbis].freeze

  CONTENT_TYPES = { ".mp4" => "video/mp4", ".webm" => "video/webm", ".m4a" => "audio/mp4" }.freeze

  # Correction résiduelle de la vidéo, la seule constante du recalage. Calé
  # sur les passages ACTIVE seuls, le montage garde un écart propre à chaque
  # personne (chaîne de capture du poste, image clé reçue après l'instant que
  # le fichier lui attribue) : vidéo en retard de +2 à +115 ms selon la
  # personne (SyncNet, lèvres contre voix, deux directs, mesures de
  # confiance ≥ 2), stable d'une session à l'autre pour une même personne
  # (hôte : +110 ms au #7, +115 ms au #8). Un son en avance se remarque dès
  # 45 ms, un son en retard à partir de 125 ms (UIT-R BT.1359) : 100 ms met
  # tous ces écarts dans cette fenêtre. Réglable sans changer le code
  # (MUX_VIDEO_ACTIVATION_LAG_MS).
  VIDEO_ACTIVATION_LAG = Integer(ENV.fetch("MUX_VIDEO_ACTIVATION_LAG_MS", "100")) / 1000.0

  # Résultat du mux — struct value immuable, consommée par le job
  # pour écrire le Recording participant. `track_source` dit ce qui a
  # été réellement muxé ("camera+microphone", "camera", "microphone") ;
  # `note` (nil si rien à signaler) explique les pistes écartées ou le
  # calage approximatif.
  Result = Struct.new(:relative_path, :extension, :duration_seconds, :content_type,
                      :track_source, :note, keyword_init: true)

  # Piste retenue pour le montage : l'enregistrement et le codec sondé.
  Retained = Struct.new(:recording, :codec)

  # @param webinar [Webinar]
  # @param identity [String] participant_identity
  # @param track_ids [Array<Integer>, nil] lot couvert par le montage
  #   (MuxParticipantJob, `source_track_ids`) : les pistes `done` parmi
  #   lesquelles il retient au plus une caméra et un micro ; nil = toutes
  #   les pistes `done` de la personne
  # @param now [Time] (test seam, défaut Time.current)
  # @param ffmpeg_bin [String] (test seam, défaut `ffmpeg`)
  # @param prober [#call(path, stream_type)] (test seam, défaut TrackProbe)
  def initialize(webinar:, identity:, track_ids: nil, now: Time.current, ffmpeg_bin: nil, prober: nil)
    @webinar    = webinar
    @identity   = identity.to_s
    @track_ids  = track_ids
    @now        = now
    @ffmpeg_bin = ffmpeg_bin || ENV.fetch("FFMPEG_BIN", "ffmpeg")
    @prober     = prober || TrackProbe.new
  end

  # Piste caméra retenue : la `done` la plus récente QUI CONTIENT DES
  # PAQUETS (une personne peut relancer sa caméra ; on prend la DERNIÈRE
  # pour correspondre au geste final, mais une piste vide est écartée au
  # profit de la précédente). Même règle pour micro. Un futur raffinement
  # « concat » peut recoller plusieurs segments ; ici on vise le cas
  # nominal 1-caméra + 1-micro par personne.
  def video_recording
    plan.video&.recording
  end

  def audio_recording
    plan.audio&.recording
  end

  def tracks
    [ video_recording, audio_recording ].compact
  end

  # "camera+microphone", "camera" ou "microphone" : ce qui est muxé.
  def track_source
    tracks.map { |rec| rec.track_source.to_s }.join("+")
  end

  # Réserves sur le montage : pistes écartées (vides ou illisibles), une
  # phrase par piste, ou calage approximatif (`unanchored`) ; nil sinon.
  def note
    notes = plan.skipped.dup
    notes << "calage lèvres/voix approximatif : instant de début de fichier inconnu (#{unanchored})" if unanchored
    notes.join(" ; ").presence
  end

  # Décalages à poser via `-itsoffset` AVANT chaque `-i`.
  # @return [Hash{Recording => Float}] offset en secondes (≥ 0)
  def offsets
    starts = tracks.index_with { |rec| file_start(rec) }
    t0 = starts.values.min
    starts.transform_values { |at| (at - t0).to_f.round(3) }
  end

  # Chemin relatif de sortie SOUS Recording.recordings_root. Nom horodaté
  # du début du lot couvert (UTC, comme les fichiers egress), pistes
  # écartées comprises — même date que Recording#sources_started_at : une
  # relance du même lot écrase son propre fichier, un autre lot de la même
  # personne (répétition, séance, reprise du direct) a le sien — l'ancien
  # n'est jamais touché.
  #
  # Sous-arbre `participants/<slug>/` RÉSERVÉ aux mux, créé par Rails (UID 1000, mode 0750), jamais par
  # l'egress (UID 1001). Le dossier `<slug>/` posé par l'egress hérite
  # d'un mask ACL r-x qui bloquait l'écriture ffmpeg (rc=243 EACCES).
  def relative_output_path
    "#{Recording::PARTICIPANTS_SUBDIR}/#{@webinar.slug}/mux-#{safe(@identity)}-#{lot_stamp}#{extension}"
  end

  # `.mp4` si la vidéo est H.264, `.webm` pour tout autre codec vidéo
  # (VP8, VP9…), `.m4a` sans vidéo exploitable (audio seul).
  def extension
    return ".m4a" unless video_recording
    MP4_VIDEO_CODECS.include?(plan.video.codec) ? ".mp4" : ".webm"
  end

  def content_type
    CONTENT_TYPES.fetch(extension)
  end

  # Construit la commande ffmpeg prête à `Open3.capture3`. Testable
  # SANS exécuter ffmpeg (test unitaire).
  #
  # @return [Array<String>] argv complet
  def ffmpeg_command(output_absolute:)
    ensure_tracks!
    picked = tracks

    off = offsets
    args = [ @ffmpeg_bin, "-nostdin", "-hide_banner", "-loglevel", "error", "-y" ]

    picked.each do |rec|
      args.concat([ "-itsoffset", format("%.3f", off.fetch(rec)) ])
      args.concat([ "-i", source_path!(rec).to_s ])
    end

    if video_recording && audio_recording
      args.concat([ "-map", "0:v:0", "-map", "1:a:0" ])
    elsif video_recording
      args.concat([ "-map", "0:v:0" ])
    else # audio seul
      args.concat([ "-map", "0:a:0" ])
    end

    # Vidéo toujours copiée (jamais de réencodage). Audio : AAC dans
    # mp4/m4a (Opus-dans-mp4 est muxable par ffmpeg 4.1+ mais sort du
    # corridor de compatibilité Safari/QuickTime), Opus copié en webm.
    #
    # `-threads 1` : le job tourne DANS le conteneur web (solid_queue
    # in-puma) plafonné à 512 Mo, dont ~440 Mo déjà consommés au repos
    # — ~70 Mo de marge. Pic RSS ffmpeg mesuré pour un 60 s H.264 720p
    # copie + AAC 128k = 62 Mo (62020 KiB, trixie-slim ffmpeg 7.1, cf.
    # bench PR) ; ça tient. `-threads 1` est une borne défensive (le mux
    # ne reencode PAS la vidéo : copy coûte 0 CPU, AAC seul suffit à un
    # thread) qui empêche les bouffées parallèles si on ouvrait un jour
    # le réencodage vidéo.
    args.concat([ "-c:v", "copy" ]) if video_recording
    args.concat(audio_codec_args) if audio_recording
    args.concat([ "-threads", "1" ])
    args.concat([ "-movflags", "+faststart" ]) if extension == ".mp4"
    args << output_absolute.to_s
    args
  end

  # Exécute ffmpeg. Lève sur rc != 0 (fail-loud).
  #
  # Écriture atomique : ffmpeg sort dans un fichier
  # `<name>.part-<pid>-<rand>` du MÊME dossier (rename ≡ atomique sur
  # même filesystem), puis `File.rename` en cas de succès. Sur échec ou
  # timeout, le `.part` est supprimé → pas de fichier partiel servi par
  # `downloadable?` ni par le download controller. Une relance du même lot
  # retombe sur le même nom final.
  #
  # Les dossiers `participants/` et `participants/<slug>/` sont CRÉÉS
  # ICI par Rails (UID 1000, mode 0750) — jamais par l'egress LiveKit.
  # @return [Result]
  def call
    ensure_binaries!
    ensure_tracks!
    output_rel = relative_output_path
    output_abs = Recording.recordings_root.join(output_rel)
    FileUtils.mkdir_p(output_abs.dirname, mode: 0o750)
    # L'extension finale reste en suffixe : ffmpeg déduit le format de sortie
    # du nom de fichier (« .part-… » seul → « Unable to find a suitable output format »).
    partial_abs = output_abs.dirname.join(
      ".#{output_abs.basename(output_abs.extname)}.part-#{Process.pid}-#{SecureRandom.hex(4)}#{output_abs.extname}"
    )
    cmd = ffmpeg_command(output_absolute: partial_abs)
    Rails.logger.warn("[mux_participant] webinar=#{@webinar.slug} identity=#{@identity} calage approximatif : #{unanchored}") if unanchored

    begin
      err, status = run_with_deadline(cmd)
    rescue StandardError
      File.delete(partial_abs) if File.file?(partial_abs)
      raise
    end
    unless status.success?
      File.delete(partial_abs) if File.file?(partial_abs)
      raise FfmpegFailed, "ffmpeg rc=#{status.exitstatus} : #{err.to_s.strip[0, 2000]}"
    end

    File.rename(partial_abs, output_abs)

    Result.new(
      relative_path:    output_rel,
      extension:        extension,
      duration_seconds: computed_duration,
      content_type:     content_type,
      track_source:     track_source,
      note:             note
    )
  end

  private

  # ffmpeg tourne dans un worker solid_queue in-puma (peu de RAM en prod) :
  # au-delà de TIMEOUT_SECONDS il est tué (TERM puis KILL) et le montage passe
  # en échec explicite, plutôt que d'immobiliser le worker.
  TIMEOUT_SECONDS = Integer(ENV.fetch("MUX_TIMEOUT_SECONDS", 900))

  def run_with_deadline(cmd, timeout: TIMEOUT_SECONDS)
    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }
      unless wait.join(timeout)
        terminate(wait.pid)
        raise FfmpegFailed, "ffmpeg interrompu après #{timeout} s"
      end
      out_reader.join
      [ err_reader.value, wait.value ]
    end
  end

  def terminate(pid)
    Process.kill("TERM", pid)
    sleep 2
    Process.kill("KILL", pid)
  rescue Errno::ESRCH
    nil
  end

  # Instant (horloge du serveur) du temps 0 du fichier de la piste ; cf.
  # « Recalage » en tête.
  def file_start(rec)
    return rec.started_at unless tracks.all?(&:media_started_at)

    rec.media_started_at - (rec == video_recording ? VIDEO_ACTIVATION_LAG : 0)
  end

  # Pistes sans `media_started_at` quand caméra ET micro sont montés
  # (« caméra (piste 12), micro (piste 13) ») ; nil si le calage est exact
  # ou s'il n'y a qu'une piste, qui n'a rien à recaler.
  def unanchored
    return unless video_recording && audio_recording

    tracks.reject(&:media_started_at)
          .map { |rec| "#{SOURCE_LABELS.fetch(rec.track_source.to_s)} (piste #{rec.id})" }
          .join(", ").presence
  end

  Plan = Struct.new(:video, :audio, :skipped)

  SOURCE_LABELS = { VIDEO_SOURCE => "caméra", AUDIO_SOURCE => "micro" }.freeze
  EMPTY_STREAM_REASONS = { "video" => "aucune image exploitable", "audio" => "aucun son exploitable" }.freeze

  # Sondage mémoïsé des pistes : retenues (Retained) + phrases sur les
  # pistes écartées. Un seul passage ffprobe par piste et par mux.
  def plan
    @plan ||= begin
      video, video_skipped = retain(VIDEO_SOURCE, "video")
      audio, audio_skipped = retain(AUDIO_SOURCE, "audio")
      Plan.new(video, audio, video_skipped + audio_skipped)
    end
  end

  # Première piste `done` (la plus récente d'abord) de `source` qui
  # contient au moins un paquet du type voulu.
  # @return [Array(Retained|nil, Array<String>)] piste retenue, notes des pistes écartées
  def retain(source, stream_type)
    skipped = []
    terminal_tracks.select { |rec| rec.track_source.to_s == source }.each do |rec|
      info = probe(rec, stream_type)
      return [ Retained.new(rec, info.codec), skipped ] if info && info.packets.positive?

      skipped << "#{SOURCE_LABELS.fetch(source)} (piste #{rec.id}) écartée : #{EMPTY_STREAM_REASONS.fetch(stream_type)}"
    end
    [ nil, skipped ]
  end

  def probe(rec, stream_type)
    @prober.call(source_path!(rec), stream_type)
  rescue TrackProbe::Interrupted => error
    raise ProbeFailed, "piste #{rec.id} : #{error.message}"
  end

  def ensure_tracks!
    return unless tracks.empty?

    reasons = plan.skipped.presence || [ "aucune piste terminale" ]
    raise NothingToMux, "aucune piste exploitable pour #{@identity} (#{reasons.join(' ; ')})"
  end

  # webm : Opus/Vorbis copiés ; tout autre codec audio est réencodé en
  # Opus. mp4/m4a : AAC.
  def audio_codec_args
    return [ "-c:a", "aac", "-b:a", "128k" ] unless extension == ".webm"
    return [ "-c:a", "copy" ] if WEBM_AUDIO_CODECS.include?(plan.audio.codec)

    [ "-c:a", "libopus", "-b:a", "128k" ]
  end

  def terminal_tracks
    @terminal_tracks ||= begin
      scope = @webinar.recordings.tracks.where(participant_identity: @identity, status: "done")
      scope = scope.where(id: @track_ids) if @track_ids
      scope.order(started_at: :desc).to_a
    end
  end

  def lot_stamp
    (terminal_tracks.filter_map(&:started_at).min || @now).utc.strftime("%Y%m%d-%H%M%S")
  end

  # Résout le chemin absolu d'une piste source, lève SourceMissing si
  # introuvable (défense traversal déjà portée par Recording#absolute_path).
  def source_path!(rec)
    full = rec.absolute_path
    raise SourceMissing, "piste source introuvable (id=#{rec.id})" if full.nil?
    raise SourceMissing, "piste source absente du disque (id=#{rec.id})" unless File.file?(full)
    full
  end

  # Durée théorique = fin la plus tardive – t0. Une sonde du fichier
  # produit donnerait la durée réelle mais recommencerait de l'I/O —
  # ici on est au niveau du contrat recording, pas du fichier fini (le
  # job rafraîchit `size_on_disk` lui-même).
  def computed_duration
    endings = tracks.map { |r| r.ended_at || r.started_at }.compact
    starts  = tracks.map(&:started_at).compact
    return nil if endings.empty? || starts.empty?
    (endings.max - starts.min).to_f.round(3)
  end

  def safe(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 60].presence || "unknown"
  end

  def ensure_binaries!
    unless system(@ffmpeg_bin, "-version", out: File::NULL, err: File::NULL)
      raise MissingBinary, "ffmpeg introuvable (#{@ffmpeg_bin})"
    end
    raise MissingBinary, "ffprobe introuvable" unless @prober.available?
  end
end
