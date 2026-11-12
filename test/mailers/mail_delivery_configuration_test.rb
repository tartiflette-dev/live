require "test_helper"
require "open3"

class MailDeliveryConfigurationTest < ActiveSupport::TestCase
  test "production defaults to SMTP without sending a message" do
    output, status = production_probe(nil, "puts ActionMailer::Base.delivery_method")
    assert status.success?, output
    assert_equal "smtp", output.lines.last.strip
  end

  # Valeur posée par le déploiement d'une instance de pré-production.
  test "MAIL_DELIVERY_METHOD=test captures a delivered mail without contacting SMTP" do
    output, status = production_probe("test", <<~RUBY)
      require "net/smtp"
      class << Net::SMTP
        def new(*)
          raise "SMTP must not be contacted by staging"
        end
      end
      class StagingIsolationProbeMailer < ApplicationMailer
        def probe
          mail(to: "recipient@example.invalid", subject: "Isolation", body: "Captured")
        end
      end
      StagingIsolationProbeMailer.probe.deliver_now
      abort "message not captured" unless ActionMailer::Base.deliveries.one?
      abort "delivery disabled" unless ActionMailer::Base.perform_deliveries
      puts ActionMailer::Base.deliveries.first.subject
    RUBY
    assert status.success?, output
    assert_equal "Isolation", output.lines.last.strip
  end

  test "unknown transport prevents application boot" do
    output, status = production_probe("smpt", "abort 'boot unexpectedly succeeded'")
    assert_not status.success?
    assert_includes output, "MAIL_DELIVERY_METHOD must be smtp or test"
  end

  private

  def production_probe(method, script)
    Open3.capture2e(
      {
        "RAILS_ENV" => "production", "SECRET_KEY_BASE_DUMMY" => "1",
        "APP_HOST" => "staging.example.invalid", "MAIL_FROM" => "sender@example.invalid",
        "MAIL_DELIVERY_METHOD" => method, "SMTP_ADDRESS" => "smtp.example.invalid",
        "SOLID_QUEUE_IN_PUMA" => nil
      },
      RbConfig.ruby, "-r", Rails.root.join("config/environment").to_s, "-e", script,
      chdir: Rails.root.to_s
    )
  end
end
