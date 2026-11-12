require "test_helper"

# Options de la salle LiveKit (rooms/room.jsx, ROOM_OPTIONS) : garde
# mécanique de la source, le comportement ne s'observe qu'avec un vrai SFU.
#   • adaptiveStream + dynacast : le débit vers chaque spectateur suit la
#     tuile affichée et sa connexion (mesuré en direct : chacun recevait la
#     couche haute de chaque caméra) ; l'egress de piste garde la couche haute.
#   • H.264 : l'egress de piste sans transcodage démarre mal en VP8.
#   • Caméra en 1080p : capture 1920x1080, couche haute
#     1080p, couches simulcast 360p et 540p (une caméra 720p sort 360/540/720,
#     sans doublon) ; le repli sans simulcast (camera_health.jsx) ramène la
#     capture en 720p.
#   • Constante de module : un objet neuf à chaque rendu reconnecterait.
#   • La mesure caméra (CameraHealth) est montée dans la salle.
class RoomOptionsSourceTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/rooms/room.jsx").read.freeze
  CAMERA_HEALTH = Rails.root.join("app/javascript/rooms/camera_health.jsx").read.freeze

  def room_options
    options = SOURCE[/^const ROOM_OPTIONS = (\{.*?^\});$/m, 1]
    assert options, "ROOM_OPTIONS n'est plus une constante de module"
    options
  end

  test "ROOM_OPTIONS : constante de module, adaptiveStream, dynacast et H.264" do
    assert_includes room_options, "adaptiveStream: true"
    assert_includes room_options, "dynacast: true"
    assert_includes room_options, 'videoCodec: "h264"'
    assert_includes SOURCE, "options={ROOM_OPTIONS}"
  end

  test "ROOM_OPTIONS : caméra capturée et publiée en 1080p, couches 360p et 540p" do
    assert_includes room_options, "videoCaptureDefaults: { resolution: VideoPresets.h1080.resolution }"
    assert_includes room_options, "videoEncoding: VideoPresets.h1080.encoding"
    assert_includes room_options, "videoSimulcastLayers: [VideoPresets.h360, VideoPresets.h540]"
  end

  test "le repli sans simulcast ramène la capture en 720p" do
    assert_includes CAMERA_HEALTH, "const FALLBACK_CAPTURE_OPTIONS = { resolution: VideoPresets.h720.resolution };"
    assert_includes CAMERA_HEALTH, "fallbackCapture: FALLBACK_CAPTURE_OPTIONS,"
    assert_includes CAMERA_HEALTH, "videoEncoding: VideoPresets.h720.encoding,"
  end

  test "la mesure de la caméra est montée dans la salle" do
    assert_match(%r{<LiveKitRoom.*<CameraHealth slug=\{slug\} speakerToken=\{speakerToken\} />.*</LiveKitRoom>}m, SOURCE)
  end
end
