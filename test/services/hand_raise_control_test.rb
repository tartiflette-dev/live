require "test_helper"

# Main pré-déclarée et ré-accord d'une main accordée.
class HandRaiseControlTest < ActiveSupport::TestCase
  class PermissionRecorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def update_participant(**arguments)
      @calls << arguments
      {}
    end
  end

  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: Time.current, host_sub: "host",
                               visibility: "published", state: "live", started_at: Time.current)
    @client = PermissionRecorder.new
    @control = HandRaiseControl.new(@webinar, client: @client)
  end

  test "un inscrit participant entre main levée, en attente de l'animation" do
    participant = registration("participant")

    hand = @control.raise_declared_hand(participant)

    assert_equal [ "waiting", participant ], [ hand.state, hand.registration ]
    assert_empty @client.calls, "la publication attend l'admission"
  end

  test "un spectateur n'entre jamais main levée" do
    assert_nil @control.raise_declared_hand(registration("spectator"))
    assert_empty @webinar.hand_raises
  end

  test "la main pré-déclarée ne se lève qu'à la première entrée : baissée, refusée ou rendue, elle le reste" do
    participant = registration("participant")
    @control.raise_declared_hand(participant)
    @control.lower_hand(participant)

    assert_nil @control.raise_declared_hand(participant)
    assert_empty @webinar.hand_raises.active
    assert_equal 1, @webinar.hand_raises.count
  end

  test "pas de main pré-déclarée hors direct, sans accès à la salle ou sans paiement" do
    removed = registration("participant")
    removed.remove_from_room!
    unconfirmed = @webinar.registrations.create!(name: "Sans accès", email: "pending@example.test", participation: "participant")
    paid = Webinar.create!(title: "Payant", starts_at: Time.current, host_sub: "host", visibility: "published",
                           state: "live", started_at: Time.current, price_cents: 1000)
    unpaid = paid.registrations.create!(name: "Non payé", email: "unpaid@example.test", participation: "participant",
                                        confirmed_at: Time.current)
    draft = Webinar.create!(title: "Pas encore", starts_at: 10.minutes.from_now, host_sub: "host", visibility: "published")
    early = draft.registrations.create!(name: "En avance", email: "early@example.test", participation: "participant",
                                        instant_access_at: Time.current)

    assert_nil @control.raise_declared_hand(removed)
    assert_nil @control.raise_declared_hand(unconfirmed)
    assert_nil HandRaiseControl.new(paid, client: @client).raise_declared_hand(unpaid)
    assert_nil HandRaiseControl.new(draft, client: @client).raise_declared_hand(early)
    assert_equal 0, HandRaise.count
  end

  test "un inscrit à accès immédiat, non confirmé, entre main levée" do
    participant = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", participation: "participant",
                                                 instant_access_at: Time.current)

    assert_equal "waiting", @control.raise_declared_hand(participant).state
  end

  test "avec un accord à l'image, ré-accorder une main accordée repousse la permission à LiveKit" do
    participant = registration("participant")
    ParticipantConsent.grant!(participant, recording: true, excerpts: false, adult: true)
    hand = @control.raise_declared_hand(participant)
    @control.grant(hand.id)
    @control.grant(hand.id)

    assert_equal [ true, true ], @client.calls.map { |call| call.fetch(:can_publish) }
    assert_equal "granted", hand.reload.state
  end

  # Participant du lien public admis sans accord : la main passe accordée,
  # rien ne s'ouvre ; la salle lui montre la fenêtre d'accord.
  test "admettre une main pré-déclarée sans accord à l'image : accordée, aucune publication ouverte" do
    hand = @control.raise_declared_hand(registration("participant"))
    @control.grant(hand.id)
    @control.grant(hand.id)

    assert_empty @client.calls
    assert_equal "granted", hand.reload.state
  end

  test "choisir « Je participe » à l'entrée lève la main, même après une main baissée" do
    participant = registration("participant")
    @control.raise_declared_hand(participant)
    @control.lower_hand(participant)

    hand = @control.follow_participation(participant)

    assert_equal [ "waiting", participant ], [ hand.state, hand.registration ]
    assert_equal 1, @webinar.hand_raises.active.count
    assert_equal hand, @control.follow_participation(participant), "un second choix ne double pas la main"
    assert_empty @client.calls
  end

  test "choisir « J'observe » baisse la main en attente, jamais une parole accordée" do
    waiting = registration("participant")
    @control.raise_declared_hand(waiting)
    waiting.update!(participation: "spectator")

    @control.follow_participation(waiting)
    assert_empty @webinar.hand_raises.active.where(registration: waiting)

    speaking = registration("participant")
    hand = @control.raise_declared_hand(speaking)
    @control.grant(hand.id)
    speaking.update!(participation: "spectator")
    @control.follow_participation(speaking)

    assert_equal "granted", hand.reload.state
    assert_empty @client.calls, "baisser une main en attente ne passe pas par LiveKit"
  end

  test "le choix d'entrée ne lève pas de main hors direct" do
    draft = Webinar.create!(title: "Pas encore", starts_at: 10.minutes.from_now, host_sub: "host", visibility: "published")
    early = draft.registrations.create!(name: "En avance", email: "early@example.test", participation: "participant",
                                        confirmed_at: Time.current)

    assert_nil HandRaiseControl.new(draft, client: @client).follow_participation(early)
    assert_equal 0, HandRaise.count
  end

  private

  def registration(participation)
    @webinar.registrations.create!(name: "Mathilde", email: "#{participation}-#{SecureRandom.hex(3)}@example.test",
                                   participation: participation, confirmed_at: Time.current)
  end
end
