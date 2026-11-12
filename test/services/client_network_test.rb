require "test_helper"

class ClientNetworkTest < ActiveSupport::TestCase
  test "une adresse IPv4 reste telle quelle" do
    assert_equal "203.0.113.7", ClientNetwork.key("203.0.113.7")
  end

  test "une IPv4 écrite en IPv6 donne la clé de l'IPv4" do
    assert_equal "203.0.113.7", ClientNetwork.key("::ffff:203.0.113.7")
  end

  test "deux adresses IPv6 du même /64 donnent la même clé" do
    assert_equal ClientNetwork.key("2001:db8:1:2::1"), ClientNetwork.key("2001:db8:1:2:ffff:ffff:ffff:ffff")
    assert_equal "2001:db8:1:2::", ClientNetwork.key("2001:db8:1:2:abcd:1234:5678:9abc")
  end

  test "deux /64 différents donnent deux clés" do
    assert_not_equal ClientNetwork.key("2001:db8:1:2::1"), ClientNetwork.key("2001:db8:1:3::1")
  end

  test "une entrée qui n'est pas une adresse est rendue telle quelle, jamais d'exception" do
    assert_equal "pas-une-ip", ClientNetwork.key("pas-une-ip")
    assert_equal "", ClientNetwork.key(nil)
  end
end
