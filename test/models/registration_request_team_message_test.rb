require "test_helper"

# Message laissé à une inscription Café IA : mail aux co-organisateurs
# (`notify_team!`) et file du relais WhatsApp (`whatsapp_relay_pending`).
class RegistrationRequestTeamMessageTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @saved_recipient = ENV["CO_ORGANIZERS_NOTIFY_TO"]
    ENV["CO_ORGANIZERS_NOTIFY_TO"] = "orga@tartiflette.test"
    @request = team_request("camille@example.test")
  end

  teardown { ENV["CO_ORGANIZERS_NOTIFY_TO"] = @saved_recipient }

  test "files : mail pour les seules demandes avec message ; WhatsApp co-organisateurs pour toutes les confirmées" do
    unconfirmed = team_request("a@example.test", confirmed_at: nil)
    without_message = team_request("b@example.test", message: nil)
    blank_message = team_request("c@example.test")
    blank_message.update_column(:message, "")
    other_source = team_request("d@example.test", source: nil)

    assert_equal [ @request ], RegistrationRequest.team_messages.to_a
    assert_equal [ @request ], RegistrationRequest.team_notification_pending.to_a
    assert_equal [ @request, without_message, blank_message ].map(&:id).sort, RegistrationRequest.whatsapp_relay_pending.ids.sort
    [ unconfirmed, without_message, blank_message, other_source ].each do |request|
      assert_not request.team_message?, request.email
    end
  end

  test "notify_team! : un mail aux co-organisateurs, UNE fois" do
    assert_enqueued_email_with CoOrganizerMailer, :message_received, args: [ @request, { to: "orga@tartiflette.test" } ] do
      assert @request.notify_team!
    end
    assert_not_nil @request.reload.team_notified_at
    assert_empty RegistrationRequest.team_notification_pending

    assert_no_enqueued_emails do
      assert_not @request.notify_team!, "rejoué : rien ne repart"
    end
  end

  test "notify_team! : sans destinataire configuré, rien, et la demande reste à transmettre" do
    ENV.delete("CO_ORGANIZERS_NOTIFY_TO")
    assert_no_enqueued_emails { assert_not @request.notify_team! }
    assert_nil @request.reload.team_notified_at
  end

  test "notify_team! : demande non confirmée ou sans message, rien" do
    [ team_request("a@example.test", confirmed_at: nil), team_request("b@example.test", message: nil) ].each do |request|
      assert_no_enqueued_emails { assert_not request.notify_team! }
      assert_nil request.reload.team_notified_at
    end
  end

  test "mark_whatsapp_relayed! : sort de la file, idempotent (la première date reste)" do
    first = 1.hour.ago.change(usec: 0)
    @request.mark_whatsapp_relayed!(now: first)
    @request.mark_whatsapp_relayed!(now: Time.current)
    assert_equal first, @request.reload.whatsapp_relayed_at
    assert_empty RegistrationRequest.whatsapp_relay_pending
    assert_includes RegistrationRequest.team_notification_pending, @request, "les deux canaux sont indépendants"
  end

  test "non-régression : « Pierre Martin » est annoncé « Pierre », publiable" do
    request = RegistrationRequest.new(name: "Pierre Martin")
    assert_equal "Pierre", request.first_name
    assert request.announceable_first_name?
  end

  test "first_name : le premier mot du nom saisi, jamais le nom de famille" do
    { "Pierre" => "Pierre", "Pierre Martin" => "Pierre", "  Jean-Pierre  Durand " => "Jean-Pierre" }.each do |name, first|
      assert_equal first, RegistrationRequest.new(name: name).first_name, name
    end
  end

  test "announceable_first_name? : lettres latines, apostrophe, trait d'union, 30 au plus ; NFKC" do
    [ *%w[Pierre Jean-Pierre Zoé D'Arcy D’Arcy Anaïs Łucja Ñandú Ægir A], "a" * 30 ].each do |name|
      assert RegistrationRequest.new(name: name).announceable_first_name?, name
    end
    assert RegistrationRequest.new(name: "Zoe\u0301").announceable_first_name?, "accent décomposé, recomposé"
    assert_equal "Zoé", RegistrationRequest.new(name: "Zoe\u0301 Martin").first_name
    assert_equal "Pierre", RegistrationRequest.new(name: "Ｐｉｅｒｒｅ").first_name, "pleine chasse ramenée par NFKC"
    [ "P1erre", "pierre@x.fr", "http://x.fr", "www.x.fr", "*Pierre*", "_Pierre_", "~Pierre~", "`Pierre`",
      "Pierre🎉", "🎉", "-Pierre", "'Pierre", "Pierre-", "D'", "D’", "Jean--", "#{"a" * 31}", "", "   ",
      "Pi\u3164erre", "\u3164", "Pi\u115Ferre", "Pi\u1160erre", "Pi\uFFA0erre", "Pi\uA4F8erre",
      "Pіerre", "Пьер", "ピエール" ].each do |name|
      assert_not RegistrationRequest.new(name: name).announceable_first_name?, name.inspect
    end
  end

  test "confirm! : prénom non publiable retenu pour la communauté, toujours relayé aux co-organisateurs" do
    webinar = Webinar.create!(title: "Café IA", starts_at: 3.days.from_now, host_sub: "h", visibility: "published")
    clean, unsafe = [ "Pierre Martin", "*Promo* www.spam.example" ].map do |name|
      request = RegistrationRequest.create!(name: name, email: "#{name.hash.abs}@example.test", source: "tartiflette.dev")
      Registration.find_or_create_for(webinar, email: request.email, name: name, registration_request: request)
      request.confirm!
      request.reload
    end

    assert_nil clean.community_announcement_withheld_at
    assert_equal unsafe.confirmed_at, unsafe.community_announcement_withheld_at
    assert_equal [ clean ], RegistrationRequest.community_announcement_pending.to_a
    assert_not_includes RegistrationRequest.community_announceable, unsafe
    assert_equal [ @request, clean, unsafe ].map(&:id).sort, RegistrationRequest.whatsapp_relay_pending.ids.sort
  end

  test "mark_community_announced! : idempotent, sans toucher au groupe des co-organisateurs" do
    first = 1.hour.ago.change(usec: 0)
    @request.mark_community_announced!(now: first)
    @request.mark_community_announced!
    assert_equal first, @request.reload.community_announced_at
    assert_nil @request.whatsapp_relayed_at
  end

  private

  def team_request(email, **attributes)
    RegistrationRequest.create!({ name: "Camille", email: email, source: "tartiflette.dev",
                                  message: "Je propose une présentation.", confirmed_at: Time.current }.merge(attributes))
  end
end
