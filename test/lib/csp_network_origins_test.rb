require "test_helper"

# CspNetworkOrigins : origines réseau de `connect-src`
# (config/initializers/content_security_policy.rb). Le schéma suit la valeur
# d'origine — une URL en clair (`ws://`, quickstart local) reste `ws:`/`http:`.
class CspNetworkOriginsTest < ActiveSupport::TestCase
  test "une URL wss donne ses schémas sécurisés (signal + repli HTTP)" do
    assert_equal [ "wss://live.example.test", "https://live.example.test" ],
      CspNetworkOrigins.for("wss://live.example.test/rtc")
  end

  test "une URL ws garde ses schémas en clair (quickstart local)" do
    assert_equal [ "ws://localhost:7880", "http://localhost:7880" ],
      CspNetworkOrigins.for("ws://localhost:7880")
  end

  test "un hôte http garde ses schémas en clair" do
    assert_equal [ "ws://live.example.test", "http://live.example.test" ],
      CspNetworkOrigins.for("http://live.example.test")
  end

  test "un APP_HOST sans schéma donne la paire sécurisée" do
    assert_equal [ "wss://edge.live.example.test", "https://edge.live.example.test" ],
      CspNetworkOrigins.for("edge.live.example.test")
  end

  test "valeurs absentes ignorées, origines dédupliquées" do
    assert_equal [ "wss://live.example.test", "https://live.example.test" ],
      CspNetworkOrigins.for("wss://live.example.test", nil, "https://live.example.test/rtc/validate")
  end

  test "une valeur vide ne donne rien" do
    assert_equal [], CspNetworkOrigins.for("")
  end
end
