# Encrypted registration_id cookie carrying
# the registration id AND its identity secret (RoomRemoval
# #registration_in_browser); identity is valid only
# with room access (confirmed, or instant access during the live — a PROVISIONAL identity), scoped to the requested webinar, never
# removed from its room, and the browser carries no removed identity for that
# webinar (RoomRemoval).
module CurrentRegistration
  extend ActiveSupport::Concern
  include RoomRemoval

  included do
    helper_method :current_registration
  end

  def current_registration
    return unless @webinar && cookies.encrypted[:registration_id]
    return if room_removed?(@webinar)

    registration_in_browser(@webinar.registrations.with_room_access)
  end

  # Opens the room on this device, from a CSRF-protected POST only (never a
  # GET, docs/moderation.md): mail confirmation, or instant access (public
  # registration, private participants link). Persistent identity cookie
  # (RoomRemoval#identity_cookie). Callers check `room_removed?` first; a
  # removal the replaced cookie pointed to stays traced.
  # @return [Boolean] false, no cookie set, when this browser already carries
  #   ANOTHER valid registration to this webinar: it is kept, never replaced
  # (a third party's link must not hand over their identity).
  def remember_registration(registration)
    webinar = registration.webinar
    kept = registration_in_browser(webinar.registrations.with_room_access)
    return false if kept && kept != registration

    keep_room_removal_trace
    cookies.encrypted[:registration_id] = identity_cookie(registration_cookie_value(registration), webinar)
    true
  end

  # « Ce n'est pas moi » (NotMeController, CSRF-protected POST only): this
  # browser forgets the registration it carries for `webinar`. The cookie is
  # unique for all webinars: one that points to another webinar's
  # registration stays. Callers check `room_removed?` first; no removal trace
  # is ever lifted: a removal the deleted cookie pointed to stays traced — the
  # case of a signed-in animator, whom `room_removed?` lets through.
  # @return [Boolean] whether a registration was forgotten
  def forget_registration(webinar)
    return false unless registration_in_browser(webinar.registrations)

    keep_room_removal_trace
    cookies.delete(:registration_id)
    true
  end
end
