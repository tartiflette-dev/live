require "test_helper"

class DevicePreferenceTest < ActiveSupport::TestCase
  EMPTY = { "audioinput" => nil, "videoinput" => nil, "audioEnabled" => nil, "videoEnabled" => nil }.freeze

  setup do
    @user = User.create!(email: "marc@example.com", oidc_sub: "sub-marc")
    @webinar = Webinar.create!(title: "Café IA #8", starts_at: 1.day.from_now, host_sub: @user.oidc_sub)
    @speaker = @webinar.speakers.create!(name: "Camille Martin")
  end

  test "un participant qui n'a rien choisi a des préférences vides" do
    assert_equal EMPTY, DevicePreference.payload_for(@user)
  end

  test "le contrat client fait l'aller-retour à l'identique" do
    payload = {
      "audioinput" => { "deviceId" => "a1b2", "label" => "Microphone (Yeti Stereo Microphone)" },
      "videoinput" => { "deviceId" => "c3d4", "label" => "HD Webcam C270" },
      "audioEnabled" => true,
      "videoEnabled" => false
    }
    @speaker.build_device_preference.merge_payload(payload).save!

    assert_equal payload, DevicePreference.payload_for(@speaker.reload)
  end

  test "une écriture partielle ne change que ses clés" do
    preference = @user.build_device_preference.merge_payload(
      "audioinput" => { "deviceId" => "a1b2", "label" => "Yeti" }, "audioEnabled" => true
    )
    preference.save!

    preference.merge_payload("videoEnabled" => false).save!

    expected = { "audioinput" => { "deviceId" => "a1b2", "label" => "Yeti" }, "videoinput" => nil,
                 "audioEnabled" => true, "videoEnabled" => false }
    assert_equal expected, preference.reload.to_payload
  end

  test "une clé présente mais illisible efface la valeur correspondante" do
    preference = @user.build_device_preference.merge_payload(
      "audioinput" => { "deviceId" => "a1b2", "label" => "Yeti" }, "audioEnabled" => true
    )
    preference.save!

    preference.merge_payload("audioinput" => { "deviceId" => "", "label" => "Yeti" }, "audioEnabled" => "true").save!

    assert_equal EMPTY, preference.reload.to_payload
  end

  test "un libellé absent vaut un libellé vide, pas une préférence effacée" do
    preference = @user.build_device_preference.merge_payload("videoinput" => { "deviceId" => "c3d4" })

    assert_equal({ "deviceId" => "c3d4", "label" => "" }, preference.to_payload["videoinput"])
  end

  test "identifiant et libellé sont bornés" do
    preference = @user.build_device_preference.merge_payload(
      "audioinput" => { "deviceId" => "a1b2", "label" => "x" * (DevicePreference::MAX_LENGTH + 1) }
    )

    assert_not preference.valid?
    assert preference.errors.of_kind?(:audio_input_label, :too_long)
  end

  test "seuls l'animateur et l'intervenant portent des préférences" do
    registration = @webinar.registrations.create!(email: "viewer@example.test", name: "Alice")

    assert DevicePreference.ownable?(@user)
    assert DevicePreference.ownable?(@speaker)
    assert_not DevicePreference.ownable?(registration)
    assert_not DevicePreference.ownable?(nil)
    assert_not DevicePreference.new(owner: registration).valid?
  end

  test "une seule ligne par participant, retrouvée plutôt que recréée" do
    first = DevicePreference.create_or_find_by!(owner: @user)

    assert_equal first, DevicePreference.create_or_find_by!(owner: @user)
    assert_raises(ActiveRecord::RecordNotUnique) { DevicePreference.create!(owner: @user) }
  end

  test "les préférences partent avec leur participant" do
    @speaker.create_device_preference!(audio_input_device_id: "a1b2", audio_input_label: "Yeti")

    assert_difference -> { DevicePreference.count }, -1 do
      @speaker.destroy!
    end
  end
end
