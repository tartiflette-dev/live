require "test_helper"

class CspReportsControllerTest < ActionDispatch::IntegrationTest
  setup { @ip = "2001:db8:#{SecureRandom.hex(2)}:#{SecureRandom.hex(2)}::1" }

  test "un rapport valide : 204 et une ligne de journal assainie, sans query ni jeton" do
    report = { "csp-report" => {
      "document-uri" => "https://live.example.test/mc?t=SECRETTOKEN123#frag",
      "violated-directive" => "script-src-elem",
      "effective-directive" => "script-src-elem",
      "blocked-uri" => "inline",
      "source-file" => "https://live.example.test/r/TOKENDELIENNOMINATIF?x=1",
      "line-number" => 12,
      "original-policy" => "default-src 'self'; report-uri /csp-reports"
    } }

    log = capture_log { post_report(report) }

    assert_response :no_content
    assert_match(%r{\[csp-report\] violated-directive=script-src-elem effective-directive=script-src-elem blocked-uri=inline document-uri=https://live\.example\.test/mc }, log)
    assert_match(%r{source-file=https://live\.example\.test/r/\[FILTERED\] line-number=12}, log)
    assert_no_match(/SECRETTOKEN123|TOKENDELIENNOMINATIF|original-policy/, log)
  end

  test "jeton en chemin masqué quelle que soit la suite : slash final, segment en plus, query et fragment retirés" do
    paths = %w[/r/TOK1/ /r/TOK2/autre /r/TOK3/autre/encore /r/TOK4?x=1#f /r/TOK5]
    log = capture_log do
      paths.each do |path|
        post_report({ "csp-report" => { "violated-directive" => "img-src", "document-uri" => "https://live.example.test#{path}" } })
        assert_response :no_content
      end
    end

    assert_no_match(/TOK\d/, log)
    assert_match(%r{document-uri=https://live\.example\.test/r/\[FILTERED\]/autre/encore$}, log)
    assert_match(%r{document-uri=https://live\.example\.test/r/\[FILTERED\]$}, log)
    assert_no_match(/x=1|#f/, log)
  end

  test "jeton en chemin avec slashs répétés ou casse différente : masqué" do
    paths = %w[//r/TOK1 /r//TOK2 ///r/TOK3/x /R/TOK4 /r//TOK5//autre]
    log = capture_log do
      paths.each do |path|
        post_report({ "csp-report" => { "violated-directive" => "img-src", "document-uri" => "https://live.example.test#{path}", "blocked-uri" => "https://live.example.test#{path}?t=Q" } })
        assert_response :no_content
      end
    end

    assert_no_match(/TOK\d|t=Q/, log)
    assert_match(%r{document-uri=https://live\.example\.test/r/\[FILTERED\]/autre$}, log)
  end

  test "le corps brut n'est jamais journalisé, même posté en application/json" do
    report = { "csp-report" => { "document-uri" => "https://live.example.test/mc?t=SECRETTOKEN123", "violated-directive" => "img-src" } }

    log = capture_log do
      post csp_reports_path, params: report.to_json, headers: { "REMOTE_ADDR" => @ip, "CONTENT_TYPE" => "application/json" }
    end

    assert_response :no_content
    assert_no_match(/SECRETTOKEN123/, log.lines.grep(/Parameters/).join)
  end

  test "valeurs de champs abusives : tronquées, caractères de contrôle retirés" do
    log = capture_log { post_report({ "csp-report" => { "violated-directive" => "x" * 1000 + "\nFAUSSE LIGNE" } }) }

    assert_response :no_content
    assert_operator log[/violated-directive=(\S*)/, 1].length, :<=, CspReportsController::MAX_FIELD_LENGTH
    assert_no_match(/^FAUSSE LIGNE/, log)
  end

  test "JSON illisible ou sans rapport : 400, rien dans le journal" do
    log = capture_log do
      post csp_reports_path, params: "pas du json", headers: { "REMOTE_ADDR" => @ip, "CONTENT_TYPE" => "application/csp-report" }
      assert_response :bad_request
      post_report({ "autre" => 1 })
      assert_response :bad_request
    end

    assert_no_match(/\[csp-report\]/, log)
  end

  test "corps JSON qui n'est pas un objet (null, true, false, tableau, nombre, chaîne) : 400, jamais 500" do
    [ "null", "true", "false", "[]", "42", '"x"', '{"csp-report":null}', '{"csp-report":[1]}', '{"csp-report":"x"}' ].each do |body|
      post csp_reports_path, params: body, headers: { "REMOTE_ADDR" => @ip, "CONTENT_TYPE" => "application/csp-report" }
      assert_response :bad_request, body
    end
  end

  test "UTF-8 invalide dans un champ : 204, valeur nettoyée dans le journal, jamais 500" do
    body = "{\"csp-report\":{\"violated-directive\":\"img-src \xFF\xFE\",\"blocked-uri\":\"https://live.example.test/\xC3\x28\"}}".b
    log = capture_log do
      post csp_reports_path, params: body, headers: { "REMOTE_ADDR" => @ip, "CONTENT_TYPE" => "application/csp-report" }
    end

    assert_response :no_content
    assert_predicate log, :valid_encoding?
    assert_match(/violated-directive=img-src \?\?/, log)
  end

  test "corps trop gros : refusé" do
    post_report({ "csp-report" => { "violated-directive" => "x" * (CspReportsController::MAX_BODY_BYTES + 1) } })
    assert_response :content_too_large
  end

  test "débit borné par réseau : la 61e requête de la minute est refusée" do
    60.times { post_report({ "csp-report" => { "violated-directive" => "img-src" } }) }
    assert_response :no_content
    post_report({ "csp-report" => { "violated-directive" => "img-src" } })
    assert_response :too_many_requests
  end

  test "le débit est compté par /64 en IPv6 : changer d'adresse dans le préfixe ne le contourne pas" do
    prefix = @ip.split(":")[0, 4].join(":")
    60.times { |index| post csp_reports_path, params: { "csp-report" => { "violated-directive" => "img-src" } }.to_json, headers: { "REMOTE_ADDR" => "#{prefix}::#{index + 1}", "CONTENT_TYPE" => "application/csp-report" } }
    assert_response :no_content
    post csp_reports_path, params: { "csp-report" => { "violated-directive" => "img-src" } }.to_json, headers: { "REMOTE_ADDR" => "#{prefix}:ffff:ffff:ffff:ffff", "CONTENT_TYPE" => "application/csp-report" }
    assert_response :too_many_requests
  end

  test "aucune session ni cookie n'est posé" do
    post_report({ "csp-report" => { "violated-directive" => "img-src" } })
    assert_nil response.headers["Set-Cookie"]
  end

  private

  def post_report(report)
    post csp_reports_path, params: report.to_json,
      headers: { "REMOTE_ADDR" => @ip, "CONTENT_TYPE" => "application/csp-report" }
  end

  def capture_log
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = previous
  end
end
