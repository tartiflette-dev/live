# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261108100000_add_community_announced_at_to_registration_requests")

# Étape de données : les inscriptions déjà confirmées ne partent à aucun des
# deux groupes, sauf les messages encore dans la file des co-organisateurs.
class AddCommunityAnnouncedAtToRegistrationRequestsTest < ActiveSupport::TestCase
  Step = AddCommunityAnnouncedAtToRegistrationRequests::RegistrationRequest

  setup do
    @cutoff = Time.utc(2026, 11, 8, 10, 0)
    @silent = request("silent@example.test", message: nil)
    @message_queued = request("queued@example.test", message: "Une question.")
    @message_relayed = request("relayed@example.test", message: "Déjà posté.", whatsapp_relayed_at: @cutoff - 1.day)
    @unconfirmed = request("attente@example.test", message: nil, confirmed_at: nil)
    @other_source = request("autre@example.test", message: nil, source: nil)
  end

  test "coupure : co-organisateurs hors file pour les confirmées sans message ; communauté hors file pour toute demande existante" do
    Step.exclude_existing!(@cutoff)

    assert_equal @cutoff, @silent.reload.whatsapp_relayed_at
    assert_nil @message_queued.reload.whatsapp_relayed_at, "déjà dans la file : le relais le poste"
    assert_equal @cutoff - 1.day, @message_relayed.reload.whatsapp_relayed_at, "date du vrai relais gardée"
    [ @silent, @message_queued, @message_relayed, @unconfirmed ].each do |row|
      assert_equal @cutoff, row.reload.community_announced_at, row.email
    end
    assert_nil @unconfirmed.whatsapp_relayed_at, "en attente : part aux co-organisateurs à sa confirmation"
    assert_nil @other_source.reload.whatsapp_relayed_at
    assert_nil @other_source.community_announced_at
    assert_equal [ @message_queued.id ], RegistrationRequest.whatsapp_relay_pending.ids
  end

  test "idempotente : un second passage ne déplace aucune date" do
    Step.exclude_existing!(@cutoff)
    Step.exclude_existing!(@cutoff + 1.hour)
    assert_equal @cutoff, @silent.reload.whatsapp_relayed_at
    assert_equal @cutoff, @silent.community_announced_at
  end

  test "demande soumise avant la coupure, confirmée après : jamais annoncée (politique v2.2)" do
    Step.exclude_existing!(@cutoff)
    webinar = Webinar.create!(title: "Café IA", starts_at: 3.days.from_now, host_sub: "h", visibility: "published")
    Registration.find_or_create_for(webinar, email: @unconfirmed.email, name: "Camille", registration_request: @unconfirmed)
    @unconfirmed.reload.confirm!
    assert_not_includes RegistrationRequest.community_announcement_pending, @unconfirmed
    assert_includes RegistrationRequest.whatsapp_relay_pending, @unconfirmed
  end

  private

  def request(email, confirmed_at: @cutoff - 2.days, **attributes)
    RegistrationRequest.create!({ name: "Camille", email: email, source: "tartiflette.dev",
                                  confirmed_at: confirmed_at }.merge(attributes))
  end
end
