require "test_helper"

class PrivacyPolicyTest < ActiveSupport::TestCase
  INSTANCE_VIEWS = Rails.root.join("test/fixtures/files/privacy_policy")

  test "sans politique d'instance : la page générique et sa version" do
    Dir.mktmpdir do |views|
      assert_equal PrivacyPolicy::GENERIC, PrivacyPolicy.resolve(views)
    end
    assert_equal "legal/confidentialite", PrivacyPolicy::GENERIC.template
  end

  test "politique d'instance : son gabarit, sa version et sa date" do
    policy = PrivacyPolicy.resolve(INSTANCE_VIEWS)

    assert_equal [ "legal/instance/confidentialite", "3.1", "1er mars 2027" ],
                 [ policy.template, policy.version, policy.date ]
  end

  test "un gabarit d'instance sans sa version refuse le démarrage, et l'inverse" do
    %w[confidentialite.html.erb confidentialite.yml].each do |present|
      Dir.mktmpdir do |views|
        FileUtils.mkdir_p(File.join(views, "legal/instance"))
        FileUtils.cp(INSTANCE_VIEWS.join("legal/instance", present), File.join(views, "legal/instance"))

        assert_raises(ArgumentError) { PrivacyPolicy.resolve(views) }
      end
    end
  end

  test "une version lue comme un nombre est refusée : 2.10 deviendrait 2.1" do
    Dir.mktmpdir do |views|
      FileUtils.cp_r(INSTANCE_VIEWS.join("legal"), views)
      File.write(File.join(views, "legal/instance/confidentialite.yml"), "version: 2.10\ndate: \"1er mars 2027\"\n")

      error = assert_raises(ArgumentError) { PrivacyPolicy.resolve(views) }
      assert_match(/en texte/, error.message)
    end
  end
end
