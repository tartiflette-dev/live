# frozen_string_literal: true

require "test_helper"

# EpisodeNotification — destinataires = intervenants actifs à l'adresse
# saisie ; un mail chacun, une fois ; WhatsApp désactivé.
class EpisodeNotificationTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include EpisodePublicationHelpers

  class RecordingChannel
    attr_reader :sent

    def initialize = @sent = []
    def enabled? = true
    def deliver(speaker:, text:) = @sent << [ speaker.name, text ]
  end

  setup do
    @webinar = ended_cafe
    @publication = @webinar.create_episode_publication!(
      status: "published", folder: "Cafe-IA/2030-01-17-cafe-ia-007", folder_url: "https://cloud.test/f/4242",
      files: [ { "name" => "README.md", "size" => 10, "zone" => "shared" },
               { "name" => "pistes/basile-camera-fin-10h27-2.mp4", "size" => 20, "zone" => "shared" },
               { "name" => "video-complete-fin-10h27-1.mp4", "size" => 30, "zone" => "review" } ]
    )
    @basile = @webinar.speakers.create!(name: "Basile", email: "basile@example.test")
    @webinar.speakers.create!(name: "Révoqué", email: "revoque@example.test").revoke!
    @webinar.speakers.create!(name: "Sans adresse")
    @webinar.webinar_hosts.create!(email: "coanimateur@example.test", invited_by_sub: "x")
    @webinar.registrations.create!(name: "Spectateur", email: "spectateur@example.test", confirmed_at: Time.current)
  end

  test "après régénération le mail de publication part au nouvel intervenant, une seule fois" do
    successor = @basile.replace!
    assert_equal [ successor ], @webinar.speakers.reachable_by_email.to_a

    assert_emails(1) { EpisodeNotification.new(@publication).deliver }
    assert_equal [ "basile@example.test" ], ActionMailer::Base.deliveries.last.to
    assert_equal [ "basile@example.test" ], @publication.reload.notified_emails
  end

  test "un mail par intervenant actif joignable, ni révoqué, ni co-animateur, ni spectateur" do
    assert_emails(1) { EpisodeNotification.new(@publication).deliver }

    assert_equal [ "basile@example.test" ], ActionMailer::Base.deliveries.last.to
    assert_equal [ "basile@example.test" ], @publication.reload.notified_emails
    assert @publication.notified_at
  end

  test "un intervenant déjà prévenu ne l'est pas deux fois ; un nouveau l'est" do
    EpisodeNotification.new(@publication).deliver
    @webinar.speakers.create!(name: "Tristan", email: "tristan@example.test")

    assert_emails(1) { EpisodeNotification.new(@publication.reload).deliver }
    assert_equal [ "tristan@example.test" ], ActionMailer::Base.deliveries.last.to
  end

  test "un envoi en échec n'arrête pas les autres et reste à refaire" do
    @webinar.speakers.create!(name: "Tristan", email: "tristan@example.test")

    with_mail_refused_for("basile@example.test") do
      assert_emails(1) { EpisodeNotification.new(@publication).deliver }
    end
    assert_equal [ "tristan@example.test" ], @publication.reload.notified_emails
    assert_equal "Mail non envoyé à : basile@example.test", @publication.error_message

    assert_emails(1) { EpisodeNotification.new(@publication).deliver }
    assert_equal [ "basile@example.test" ], ActionMailer::Base.deliveries.last.to
  end

  test "WhatsApp : désactivé par défaut ; un canal actif reçoit le message, sans le lien" do
    assert_not WhatsappChannel.new.enabled?

    channel = RecordingChannel.new
    EpisodeNotification.new(@publication, whatsapp: channel).deliver

    assert_equal [ "Basile" ], channel.sent.map(&:first), "mêmes destinataires que le mail"
    assert_equal "« Café IA #7 » : les fichiers du direct (2 fichiers) sont déposés dans Nextcloud, " \
                 "dossier Cafe-IA/2030-01-17-cafe-ia-007.", channel.sent.first.last
    assert_no_match(/https?:/, channel.sent.first.last)

    EpisodeNotification.new(@publication.reload, whatsapp: channel).deliver
    assert_equal 1, channel.sent.size, "une relance ne renvoie rien"
  end

  private

  def with_mail_refused_for(email)
    original = ActionMailer::Base.delivery_method
    ActionMailer::Base.add_delivery_method(:refusing_for_test, RefusingDelivery)
    RefusingDelivery.refused = email
    ActionMailer::Base.delivery_method = :refusing_for_test
    yield
  ensure
    ActionMailer::Base.delivery_method = original
  end

  # Serveur SMTP qui refuse une adresse et accepte les autres.
  class RefusingDelivery
    cattr_accessor :refused

    def initialize(_settings) = nil

    def deliver!(mail)
      raise Errno::ECONNRESET if mail.to.include?(refused)

      ActionMailer::Base.deliveries << mail
    end
  end
end
