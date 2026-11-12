require "test_helper"

# Alerte régie et replis (CameraSample.health_for). Les mesures arrivent
# toutes les 10 s ; une caméra n'alerte qu'émise sous 720p (petit côté) sur
# plus de 15 s entre deux mesures dégradées consécutives, et tant qu'elle
# est encore mesurée.
class CameraSampleTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-11-10T09:00:00Z")

  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.from_now, host_sub: "sub-owner")
  end

  def sample(seconds_ago, identity: "speaker-14", width: 320, height: 180, **attributes)
    @webinar.camera_samples.create!(participant_identity: identity, top_width: width, top_height: height,
                                    created_at: NOW - seconds_ago.seconds, **attributes)
  end

  def alerts
    CameraSample.health_for(@webinar, now: NOW)[:alerts]
  end

  test "sous 720p sur trois mesures (20 s) : alerte, depuis la première mesure dégradée" do
    sample(30, width: 1280, height: 720)
    sample(20, quality_limitation_reason: "none", encoder_implementation: "ExternalEncoder")
    sample(10)
    sample(0, quality_limitation_reason: "bandwidth", encoder_implementation: "OpenH264",
              capture_width: 1280, capture_height: 720, frames_per_second: 20.0)

    assert_equal [ { identity: "speaker-14", width: 320, height: 180, fps: 20.0, reason: "bandwidth", encoder: "OpenH264",
                     capture_width: 1280, capture_height: 720, since: (NOW - 20.seconds).iso8601 } ], alerts
  end

  test "deux mesures dégradées (10 s) : pas encore d'alerte" do
    sample(20, width: 1280, height: 720)
    sample(10)
    sample(0)

    assert_empty alerts
  end

  test "une chute brève puis le retour en 720p n'alerte pas" do
    sample(30)
    sample(20)
    sample(10)
    sample(0, width: 1280, height: 720)

    assert_empty alerts
  end

  test "petit côté : 720x1280 (téléphone en portrait) n'est pas dégradé, 1280x540 l'est" do
    [ 20, 10, 0 ].each { |ago| sample(ago, identity: "speaker-1", width: 720, height: 1280) }
    [ 20, 10, 0 ].each { |ago| sample(ago, identity: "speaker-2", width: 1280, height: 540) }

    assert_equal [ "speaker-2" ], alerts.pluck(:identity)
  end

  test "aucune image émise (couche haute inconnue) : dégradé" do
    [ 20, 10, 0 ].each { |ago| sample(ago, width: nil, height: nil) }

    assert_equal [ [ nil, nil ] ], alerts.map { |alert| alert.values_at(:width, :height) }
  end

  test "couches en pause par dynacast : la couche basse seule n'est pas une dégradation" do
    [ 20, 10, 0 ].each { |ago| sample(ago, paused_layers: 2) }

    assert_empty alerts
  end

  test "caméra plus mesurée depuis 25 s (coupée, partie) : plus d'alerte" do
    [ 50, 40, 30 ].each { |ago| sample(ago) }

    assert_empty alerts
  end

  test "une alerte par caméra, les mesures d'un autre webinaire ignorées" do
    other = Webinar.create!(title: "Autre", starts_at: 1.hour.from_now, host_sub: "sub-owner")
    [ 20, 10, 0 ].each do |ago|
      sample(ago, identity: "speaker-14")
      sample(ago, identity: "speaker-15", width: 640, height: 360)
      other.camera_samples.create!(participant_identity: "speaker-99", top_width: 320, top_height: 180, created_at: NOW - ago.seconds)
    end

    assert_equal %w[speaker-14 speaker-15], alerts.pluck(:identity).sort
  end

  test "mesurées : identités ayant une mesure depuis 25 s, une fois chacune" do
    sample(40, identity: "speaker-1")
    sample(20, identity: "speaker-2")
    sample(10, identity: "speaker-2")
    sample(0, identity: "host-sub-marc", width: 1280, height: 720)

    assert_equal %w[host-sub-marc speaker-2], CameraSample.health_for(@webinar, now: NOW)[:measured]
  end

  test "replis du direct (4 h), dans l'ordre, avec leur issue" do
    sample(5.hours.to_i, event: "simulcast_fallback")
    sample(3600, event: "simulcast_fallback", encoder_implementation: "ExternalEncoder")
    sample(60, identity: "speaker-15", event: "simulcast_fallback_failed")
    sample(0)

    assert_equal [ { identity: "speaker-14", outcome: "simulcast_fallback", encoder: "ExternalEncoder", at: (NOW - 1.hour).iso8601 },
                   { identity: "speaker-15", outcome: "simulcast_fallback_failed", encoder: nil, at: (NOW - 1.minute).iso8601 } ],
                 CameraSample.health_for(@webinar, now: NOW)[:fallbacks]
  end

  test "bornes : événement inconnu, dimensions et couches hors limites refusés" do
    base = { participant_identity: "speaker-14" }

    assert @webinar.camera_samples.new(base).valid?
    assert_not @webinar.camera_samples.new(base.merge(event: "autre")).valid?
    assert_not @webinar.camera_samples.new(base.merge(top_width: 9000)).valid?
    layer = { "rid" => "q", "active" => true, "width" => 320, "height" => 180, "fps" => 20.0, "reason" => "none" }
    assert @webinar.camera_samples.new(base.merge(layers: [ layer, layer.merge("rid" => nil, "width" => nil) ])).valid?
    assert_not @webinar.camera_samples.new(base.merge(layers: Array.new(5) { layer })).valid?
    assert_not @webinar.camera_samples.new(base.merge(layers: [ "q" ])).valid?
    assert_not @webinar.camera_samples.new(base.merge(layers: [ layer.merge("extra" => 1) ])).valid?
    assert_not @webinar.camera_samples.new(base.merge(layers: [ layer.except("active") ])).valid?
    assert_not @webinar.camera_samples.new(base.merge(encoder_implementation: "x" * 129)).valid?
  end

  test "purge : mesures de plus de 30 jours" do
    old = sample(31.days.to_i)
    recent = sample(29.days.to_i)

    CameraSample.expired(NOW).delete_all

    assert_not CameraSample.exists?(old.id)
    assert CameraSample.exists?(recent.id)
  end
end
