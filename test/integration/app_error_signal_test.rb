# frozen_string_literal: true

require "test_helper"

# De bout en bout, avec l'abonné réellement posé par l'initializer —
# une exception non gérée d'une requête ou d'un job sort en une ligne
# `msg=AppError` sur stdout, sans le message ni les paramètres.
class AppErrorSignalTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  EMAIL = "jeanne.martin@example.com"

  class BoomController < ActionController::Base
    def show
      raise ArgumentError, "Compte introuvable pour #{params[:email]}"
    end
  end

  class BoomJob < ApplicationJob
    def perform(email)
      raise KeyError, "Relance impossible pour #{email}"
    end
  end

  test "l'initializer pose un abonné, et un seul" do
    # Pas d'API publique pour lister les abonnés en Rails 8.1 : variable interne
    # d'ActiveSupport::ErrorReporter, à réévaluer à chaque montée de version.
    subscribers = Rails.error.instance_variable_get(:@subscribers)

    assert_equal 1, subscribers.count { |subscriber| subscriber.is_a?(AppErrorSubscriber) }
  end

  test "une exception non gérée dans une requête sort en une ligne AppError" do
    output = capture_stdout do
      with_routing do |routes|
        routes.draw { get "/boom", to: "app_error_signal_test/boom#show" }
        assert_raises(ArgumentError) { get "/boom", params: { email: EMAIL } }
      end
    end

    line = only_app_error_line(output)
    assert_equal "ArgumentError", line["error_class"]
    assert_equal "ArgumentError@test/integration/app_error_signal_test.rb#show", line["fingerprint"]
    assert_equal false, line["handled"]
    assert_equal "error", line["severity"]
    assert_equal "application.action_dispatch", line["source"]
    assert_not_includes output, EMAIL
    assert_not_includes output, "Compte introuvable"
  end

  test "une réponse 404 ordinaire n'est pas une erreur applicative" do
    output = capture_stdout do
      get "/cette-page-n-existe-pas"
    end

    assert_empty app_error_lines(output)
  end

  test "une exception dans un job sort en une ligne AppError" do
    output = capture_stdout do
      # Hors de l'exécuteur ouvert par le test, comme dans un worker Solid Queue :
      # c'est l'exécuteur qui entoure le job qui rapporte l'exception.
      outside_test_executor do
        perform_enqueued_jobs { assert_raises(KeyError) { BoomJob.perform_later(EMAIL) } }
      end
    end

    line = only_app_error_line(output)
    assert_equal "KeyError", line["error_class"]
    assert_equal "KeyError@test/integration/app_error_signal_test.rb#perform", line["fingerprint"]
    assert_equal false, line["handled"]
    assert_match(/\Aapplication\./, line["source"])
    assert_not_includes output, EMAIL
    assert_not_includes output, "Relance impossible"
  end

  test "en test, sans APP_ERROR_SIGNAL, l'abonné posé reste muet" do
    output = capture_io do
      with_env("APP_ERROR_SIGNAL" => nil) { Rails.error.report(ArgumentError.new("x"), handled: false) }
    end.first

    assert_empty app_error_lines(output)
  end

  test "une erreur avalée par Rails.error.handle sort aussi, marquée handled" do
    output = capture_stdout do
      Rails.error.handle(ArgumentError, context: { user_email: EMAIL }) { raise ArgumentError, EMAIL }
    end

    line = only_app_error_line(output)
    assert_equal true, line["handled"]
    assert_equal "warning", line["severity"]
    assert_not_includes output, EMAIL
  end

  private
    def with_env(overrides)
      previous = {}
      overrides.each { |k, _| previous[k] = ENV[k] }
      overrides.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    # L'abonné posé par l'initializer est muet en test : on le fait parler.
    def capture_stdout(&block)
      capture_io { with_env("APP_ERROR_SIGNAL" => "1", &block) }.first
    end

    def app_error_lines(output)
      output.lines.filter_map do |line|
        parsed = JSON.parse(line) rescue nil
        parsed if parsed.is_a?(Hash) && parsed["msg"] == "AppError"
      end
    end

    def only_app_error_line(output)
      lines = app_error_lines(output)
      assert_equal 1, lines.size, "sortie : #{output.inspect}"
      lines.first
    end

    def outside_test_executor
      Thread.new { yield }.join
    end
end
