# frozen_string_literal: true

require "application_system_test_case"

# Firefox annonce H.264, et la salle publie H.264
# (`ROOM_OPTIONS.videoCodec` dans room.jsx).
#
# `driven_by :headless_firefox` précharge Selenium DriverFinder au
# chargement de classe (Rails 8.1). Le skip doit donc ENTOURER la classe :
# sinon CI Chrome sans firefox casse toute la suite `test:system`, et
# Selenium Manager peut télécharger Gecko avant le skip du setup.
FIREFOX_H264_BINARIES =
  system("command -v geckodriver >/dev/null 2>&1") &&
  system("command -v firefox >/dev/null 2>&1")

if FIREFOX_H264_BINARIES
  class FirefoxH264Test < ActionDispatch::SystemTestCase
    include ViewerRegistrationSystemHelpers

    driven_by :selenium, using: :headless_firefox, screen_size: [ 1280, 720 ]

    FAKE_KEY    = "APIfake"
    FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

    setup do
      @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
      @webinar = Webinar.create!(
        title: "Café IA",
        starts_at: 1.day.from_now,
        host_sub: @host.oidc_sub,
        visibility: "published",
        state: "live",
        started_at: Time.current
      )
      @prev = ENV.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "LIVEKIT_URL")
      ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
      ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
      ENV["LIVEKIT_URL"]        = "wss://livekit.invalid"
    end

    teardown do
      %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET LIVEKIT_URL].each { |k| ENV[k] = @prev[k] }
    end

    test "firefox advertises H264 and the live room bundle publishes h264" do
      confirm_viewer_registration(@webinar)
      visit public_webinar_path(slug: @webinar.slug)

      assert_selector "#livekit-room", visible: :all, wait: 15
      assert_no_selector "#livekit-room:empty"

      codecs = page.evaluate_script(<<~JS)
        (function () {
          if (!window.RTCRtpSender || !RTCRtpSender.getCapabilities) return [];
          var caps = RTCRtpSender.getCapabilities("video");
          if (!caps || !caps.codecs) return [];
          return caps.codecs.map(function (c) { return c.mimeType; });
        })()
      JS
      assert codecs.any? { |mime| mime.to_s.downcase == "video/h264" },
             "video/H264 absent des codecs Firefox : #{codecs.inspect}"

      loaded = page.evaluate_async_script(<<~JS)
        var done = arguments[0];
        var scripts = Array.from(document.querySelectorAll("script[src]"));
        Promise.all(scripts.map(function (s) {
          return fetch(s.src).then(function (r) { return r.text(); }).catch(function () { return ""; });
        })).then(function (texts) {
          done(texts.some(function (t) {
            return t.indexOf('videoCodec:"h264"') !== -1 ||
                   t.indexOf('videoCodec: "h264"') !== -1 ||
                   t.indexOf("videoCodec: 'h264'") !== -1;
          }));
        }).catch(function () { done(false); });
      JS
      assert loaded, "ROOM_OPTIONS.videoCodec=h264 absent du JS chargé par la salle"
    end
  end
else
  class FirefoxH264Test < ActiveSupport::TestCase
    test "skip sans firefox/geckodriver (pas de driven_by Selenium)" do
      skip "geckodriver ou firefox absent"
    end
  end
end
