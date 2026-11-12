# frozen_string_literal: true

require "test_helper"

# Vérification CRM en lecture seule après crm:erase : lookup seul.
class Crm::ErasureCheckTest < ActiveSupport::TestCase
  include CrmClientStubbing

  test "fiche encore présente : signalée avec son id, jamais l'email ; seul un lookup est fait" do
    client = FakeCrmClient.new(search_hit: { "id" => 78 })
    line = Crm::ErasureCheck.call("camille@example.test", client: client)

    assert_match(/existe ENCORE.*id 78.*efface-la/, line)
    assert_no_match(/camille/i, line)
    assert_equal [ :search ], client.verbs, "lecture seule"
  end

  test "aucune fiche : dit-le" do
    line = Crm::ErasureCheck.call("camille@example.test", client: FakeCrmClient.new)
    assert_equal "CRM : aucune fiche trouvée pour cette adresse.", line
  end

  test "CRM en erreur ou jeton absent : vérification manuelle demandée, sans lever" do
    failing = FakeCrmClient.new(raise_on: :search, http_status: 503)
    assert_match(/vérification impossible \(http_status=503\)/, Crm::ErasureCheck.call("a@b.example.org", client: failing))

    with_crm_env("CRM_API_TOKEN" => nil, "CRM_BASE_URL" => "https://crm.example.test") do
      assert_match(/CRM_API_TOKEN ou CRM_BASE_URL absent/, Crm::ErasureCheck.call("a@b.example.org"))
    end
  end
end
