# Fichiers du lecteur de replay, avec le contrôle d'accès de la page
# (ReplayAccess) : jamais un fichier public.
#
#   GET /w/:slug/replay/video            → la vidéo (Replay#video_file),
#                                          requêtes Range comprises ;
#   GET /w/:slug/replay/sous-titres.vtt  → sous-titres WebVTT de la
#                                          transcription.
#
# La vidéo ne doit pas occuper un fil Puma pendant toute une lecture (trois
# fils, partagés avec le direct) : derrière Thruster, qui l'annonce par
# l'en-tête de requête `X-Sendfile-Type: X-Sendfile`, l'application répond
# par l'en-tête `X-Sendfile` et Thruster sert le fichier lui-même, requêtes
# Range comprises. Sans Thruster (développement, tests), Rack::Files sert
# le fichier et ses plages.
#
# L'en-tête n'est cru que d'un pair TCP loopback (REMOTE_ADDR, jamais une
# adresse transférée) : Thruster tourne dans le même conteneur, se connecte
# à l'application par la boucle locale et remplace toute valeur posée par le
# client. Derrière un autre proxy, un spectateur qui poserait lui-même
# l'en-tête recevrait sinon le chemin absolu du fichier au lieu de la vidéo.
class ReplayMediaController < ApplicationController
  include ReplayAccess

  SENDFILE_TYPE = "X-Sendfile".freeze

  before_action :set_open_replay

  def video
    path = @replay.video_file
    return head(:not_found) unless path

    response.headers["Cache-Control"] = "private, no-store"
    thruster_sendfile? ? delegate_to_thruster(path) : serve_ranges(path)
  end

  def subtitles
    response.headers["Cache-Control"] = "private, no-store"
    send_data @replay.subtitles_vtt, type: "text/vtt; charset=utf-8", disposition: "inline",
                                     filename: "#{@webinar.slug}.vtt"
  end

  private

  def set_open_replay
    @webinar = Webinar.find_by(slug: params[:slug])
    @replay = @webinar&.replay
    head :not_found unless replay_open_to?(@replay, @webinar && replay_viewer(@webinar))
  end

  def thruster_sendfile?
    request.headers["X-Sendfile-Type"].to_s.casecmp?(SENDFILE_TYPE) && loopback_peer?
  end

  def loopback_peer?
    IPAddr.new(request.remote_addr.to_s).native.loopback?
  rescue IPAddr::Error
    false
  end

  def delegate_to_thruster(path)
    response.headers[SENDFILE_TYPE] = path.to_s
    head :ok, content_type: Rack::Mime.mime_type(path.extname)
  end

  # `x-cascade` (plage impossible, 416) ferait chercher une autre route au
  # routeur, qui répondrait 404 : il n'est pas recopié.
  def serve_ranges(path)
    status, headers, body = Rack::Files.new(nil).serving(request, path.to_s)
    headers.except("x-cascade").each { |name, value| response.headers[name] = value }
    self.status = status
    self.response_body = body
  end
end
