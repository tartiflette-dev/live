require "test_helper"

class HandRaiseTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Live", starts_at: Time.current, host_sub: "host", visibility: "published", state: "live")
    @registration = @webinar.registrations.create!(name: "Alice", email: "alice@example.test", confirmed_at: Time.current)
  end

  test "database permits only one active hand and keeps revoked history" do
    hand = HandRaise.create!(webinar: @webinar, registration: @registration, raised_at: Time.current)
    assert_includes HandRaise.waiting, hand
    assert_raises(ActiveRecord::RecordNotUnique) do
      HandRaise.create!(webinar: @webinar, registration: @registration, raised_at: Time.current)
    end
    hand.update!(state: "revoked", revoked_at: Time.current)
    replacement = HandRaise.create!(webinar: @webinar, registration: @registration, raised_at: Time.current)
    assert_equal [ replacement ], HandRaise.active.to_a
  end

  test "registration cannot be attached to another webinar" do
    other = Webinar.create!(title: "Other", starts_at: Time.current, host_sub: "host")
    hand = HandRaise.new(webinar: other, registration: @registration, raised_at: Time.current)
    refute hand.valid?
    assert hand.errors.of_kind?(:registration, :invalid)
  end
end
