# frozen_string_literal: true

require "test_helper"
require "open3"

class InstanceSettingsTest < ActiveSupport::TestCase
  Marque = Struct.new(:support_email, :organization)

  test "rien ne manque avec un nom d'instance, LiveKit, une adresse de contact et une organisation" do
    assert_empty InstanceSettings.missing(vars: { "APP_HOST" => "live.example.test", "LIVEKIT_URL" => "wss://media.example.test" },
                                          brand: Marque.new("contact@example.test", "Acme"))
  end

  test "nomme chaque réglage absent" do
    assert_equal %w[APP_HOST LIVEKIT_URL BRAND_SUPPORT_EMAIL BRAND_ORGANIZATION],
                 InstanceSettings.missing(vars: { "APP_HOST" => "", "LIVEKIT_URL" => " " }, brand: Marque.new(nil, " "))
  end

  test "refuse avec un message qui nomme les réglages" do
    error = assert_raises(InstanceSettings::Missing) do
      InstanceSettings.assert_complete!(vars: {}, brand: Marque.new("contact@example.test", "Acme"))
    end
    assert_includes error.message, "LIVEKIT_URL"
  end

  # Boot réel : une instance de production sans ses réglages ne démarre pas ;
  # avec eux, elle démarre. La compilation des assets n'est pas concernée.
  test "production : démarrage refusé sans réglages d'instance, accepté avec" do
    output, status = production_boot({})
    assert_not status.success?
    assert_includes output, "Instance settings missing in production: LIVEKIT_URL, BRAND_SUPPORT_EMAIL, BRAND_ORGANIZATION"

    complete = { "LIVEKIT_URL" => "wss://media.example.test", "BRAND_SUPPORT_EMAIL" => "contact@example.test",
                 "BRAND_ORGANIZATION" => "Acme" }
    output, status = production_boot(complete.except("BRAND_ORGANIZATION"))
    assert_not status.success?
    assert_includes output, "Instance settings missing in production: BRAND_ORGANIZATION"

    output, status = production_boot(complete)
    assert status.success?, output

    # APP_HOST vide : config.hosts serait vide, et la protection Host coupée.
    output, status = production_boot(complete.merge("APP_HOST" => ""))
    assert_not status.success?
    assert_includes output, "Instance settings missing in production: APP_HOST"

    output, status = production_boot({ "SECRET_KEY_BASE_DUMMY" => "1" })
    assert status.success?, output
  end

  private

  def production_boot(vars)
    Open3.capture2e(
      {
        "RAILS_ENV" => "production", "SECRET_KEY_BASE" => "x" * 64, "SECRET_KEY_BASE_DUMMY" => nil,
        "APP_HOST" => "live.example.test", "MAIL_FROM" => "noreply@example.test", "SMTP_ADDRESS" => "smtp.example.test",
        "LIVEKIT_URL" => nil, "BRAND_SUPPORT_EMAIL" => nil, "BRAND_ORGANIZATION" => nil, "SOLID_QUEUE_IN_PUMA" => nil
      }.merge(vars),
      RbConfig.ruby, "-r", Rails.root.join("config/environment").to_s, "-e", "puts :booted",
      chdir: Rails.root.to_s
    )
  end
end
