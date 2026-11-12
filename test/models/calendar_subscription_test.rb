require "test_helper"

# Abonnement au flux d'agenda personnel : né de la preuve de la boîte, un
# seul lien par personne, révocable.
class CalendarSubscriptionTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @cafe = Webinar.create!(title: "Café IA", starts_at: 3.days.from_now, host_sub: "sub-marc",
                            visibility: "published", kind: "cafe_ia")
    @bootcamp = Webinar.create!(title: "Bootcamp", starts_at: 10.days.from_now, host_sub: "sub-marc",
                                visibility: "published", kind: "bootcamp")
  end

  def feed_mails
    enqueued_jobs.select { |job| job[:job] == ActionMailer::MailDeliveryJob && job[:args].first == "CalendarSubscriptionMailer" }
  end

  test "une inscription créée ne s'abonne pas : il faut la confirmer" do
    registration = @cafe.registrations.create!(name: "Alice", email: "Alice@Example.test")

    assert_not CalendarSubscription.exists?
    assert_empty feed_mails

    assert registration.confirm!

    subscription = CalendarSubscription.sole
    assert_equal "alice@example.test", subscription.email
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, subscription.token)
    assert_equal 1, feed_mails.size
  end

  test "un seul lien par personne : une seconde confirmation, ailleurs ou à nouveau, n'envoie rien" do
    @cafe.registrations.create!(name: "Alice", email: "alice@example.test").confirm!
    token = CalendarSubscription.sole.token

    @bootcamp.registrations.create!(name: "Alice", email: "ALICE@example.test").confirm!
    @cafe.registrations.find_by!(email: "alice@example.test").confirm!

    assert_equal token, CalendarSubscription.sole.token
    assert_equal 1, feed_mails.size
  end

  test "le mail part dans la tonalité du café confirmé, avec le prénom" do
    @cafe.registrations.create!(name: "Alice", email: "alice@example.test").confirm!

    assert_enqueued_email_with CalendarSubscriptionMailer, :feed_link,
                               args: [ CalendarSubscription.sole, { name: "Alice", voice: "cafe_ia" } ]
  end

  test "une demande de l'API confirmée : un seul lien, dans la tonalité de la demande" do
    request = RegistrationRequest.create!(name: "Lou", email: "lou@example.test")
    [ @cafe, @bootcamp ].each { |webinar| webinar.registrations.create!(name: "Lou", email: "lou@example.test", registration_request: request) }

    request.confirm!

    assert_equal 1, feed_mails.size
    assert_enqueued_email_with CalendarSubscriptionMailer, :feed_link,
                               args: [ CalendarSubscription.sole, { name: "Lou", voice: Voice::DEFAULT } ]
  end

  test "« préviens-moi » seul : la demande confirmée suffit" do
    RegistrationRequest.create!(name: "Lou", email: "lou@example.test", notify_next: true).confirm!

    assert_equal "lou@example.test", CalendarSubscription.sole.email
    assert_equal 1, feed_mails.size
  end

  test "une confirmation annulée par un rollback n'abonne personne et n'envoie rien" do
    registration = @cafe.registrations.create!(name: "Alice", email: "alice@example.test")

    ActiveRecord::Base.transaction do
      registration.confirm!
      raise ActiveRecord::Rollback
    end

    assert_not CalendarSubscription.exists?
    assert_empty feed_mails
  end

  test "une confirmation refusée (retirée de la salle) n'abonne personne" do
    registration = @cafe.registrations.create!(name: "Alice", email: "alice@example.test")
    registration.update!(room_removed_at: Time.current)

    assert_not registration.confirm!
    assert_not CalendarSubscription.exists?
  end

  test "révoqué : le jeton ne résout plus ; une nouvelle confirmation émet un jeton neuf et un nouveau mail" do
    @cafe.registrations.create!(name: "Alice", email: "alice@example.test").confirm!
    subscription = CalendarSubscription.sole
    old_token = subscription.token

    subscription.revoke!
    assert_nil CalendarSubscription.find_active_by_token(old_token)

    @bootcamp.registrations.create!(name: "Alice", email: "alice@example.test").confirm!

    subscription.reload
    assert_not subscription.revoked?
    assert_not_equal old_token, subscription.token
    assert_equal subscription, CalendarSubscription.find_active_by_token(subscription.token)
    assert_nil CalendarSubscription.find_active_by_token(old_token)
    assert_equal 2, feed_mails.size
  end

  test "jeton vide ou inconnu : nil" do
    CalendarSubscription.create!(email: "alice@example.test")

    assert_nil CalendarSubscription.find_active_by_token(nil)
    assert_nil CalendarSubscription.find_active_by_token("")
    assert_nil CalendarSubscription.find_active_by_token("inconnu")
  end

  test "l'effacement d'une personne supprime son abonnement" do
    @cafe.registrations.create!(name: "Alice", email: "alice@example.test").confirm!
    token = CalendarSubscription.sole.token

    counts = CrmErasure.erase!("ALICE@example.test")

    assert_equal 1, counts[:calendar_subscriptions]
    assert_nil CalendarSubscription.find_active_by_token(token)
  end

  test "inspect ne montre pas le jeton" do
    subscription = CalendarSubscription.create!(email: "alice@example.test")

    assert_not_includes subscription.inspect, subscription.token
  end
end
