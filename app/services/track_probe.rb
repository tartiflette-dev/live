# frozen_string_literal: true

require "json"
require "open3"

# TrackProbe — adaptateur unique d'ffprobe pour le montage participant
# (ParticipantMux). Dit, pour un fichier de piste et un type de flux
# (« video » ou « audio »), quel codec il porte et combien de paquets il
# contient réellement : c'est ce qui décide du conteneur de sortie et de
# l'exclusion d'une piste vide (un flux sans paquet fait échouer tout
# ffmpeg, même quand l'autre piste est saine).
class TrackProbe
  # @!attribute codec [String] nom ffmpeg du codec (h264, vp8, vp9, opus…)
  # @!attribute packets [Integer] paquets réellement lus dans le fichier
  Info = Struct.new(:codec, :packets, keyword_init: true)

  # Sonde interrompue (délai dépassé, processus tué, binaire inexécutable) :
  # ce n'est PAS un fichier vide — l'appelant doit échouer, pas écarter la
  # piste, sinon un incident passager masque une piste saine.
  class Interrupted < StandardError; end

  # Code de sortie d'ffprobe pour un fichier illisible (vide, tronqué,
  # absent) ; tout autre code non nul est une interruption.
  UNREADABLE_EXIT_STATUS = 1

  # ffprobe lit tout le fichier pour compter les paquets (démuxage seul,
  # sans décodage) ; une borne dure évite d'immobiliser un worker sur un
  # fichier corrompu.
  TIMEOUT_SECONDS = Integer(ENV.fetch("PROBE_TIMEOUT_SECONDS", 60))

  STREAM_SELECTORS = { "video" => "v:0", "audio" => "a:0" }.freeze

  def initialize(ffprobe_bin: nil, timeout: TIMEOUT_SECONDS)
    @ffprobe_bin = ffprobe_bin || ENV.fetch("FFPROBE_BIN", "ffprobe")
    @timeout     = timeout
  end

  def available?
    system(@ffprobe_bin, "-version", out: File::NULL, err: File::NULL)
  end

  # @param path [Pathname, String] fichier de la piste
  # @param stream_type [String] "video" ou "audio"
  # @return [Info, nil] nil si le fichier est illisible ou sans flux de ce type
  # @raise [Interrupted] si la sonde n'a pas pu aboutir
  def call(path, stream_type)
    out, _err, status = Open3.capture3(*command(path, stream_type))
    return nil if status.exitstatus == UNREADABLE_EXIT_STATUS
    raise Interrupted, "ffprobe interrompu (#{describe(status)})" unless status.success?

    stream = JSON.parse(out).fetch("streams", []).first
    return nil if stream.nil?

    Info.new(codec: stream["codec_name"].to_s, packets: stream["nb_read_packets"].to_i)
  rescue JSON::ParserError
    nil
  end

  private

  def command(path, stream_type)
    [ "timeout", "--kill-after=2", @timeout.to_s,
      @ffprobe_bin, "-v", "error",
      "-select_streams", STREAM_SELECTORS.fetch(stream_type),
      "-count_packets", "-show_entries", "stream=codec_name,nb_read_packets",
      "-of", "json", path.to_s ]
  end

  def describe(status)
    status.signaled? ? "signal #{status.termsig}" : "rc=#{status.exitstatus}"
  end
end
