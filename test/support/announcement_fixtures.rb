# Fabriques des tests d'envoi groupé (Announcement) : un webinaire, ses
# inscriptions, les consentements et demandes « préviens-moi ».
module AnnouncementFixtures
  def announcement_webinar(host_sub: "sub-owner", **attributes)
    Webinar.create!(title: "Café IA #9", starts_at: 1.hour.from_now, host_sub: host_sub,
                    visibility: "published", kind: "cafe_ia", **attributes)
  end

  def confirmed_registration(webinar, email, **attributes)
    Registration.create!(webinar: webinar, name: email.split("@").first, email: email,
                         confirmed_at: 1.day.ago, **attributes)
  end

  def consenting_registration(webinar, email, **attributes)
    confirmed_registration(webinar, email, **attributes).tap do |registration|
      registration.grant_marketing_consent!(source: "live.example.test", path: "/mc")
    end
  end

  def confirmed_request(email, notify_next: false)
    RegistrationRequest.create!(name: email.split("@").first, email: email, notify_next: notify_next,
                                confirmed_at: 1.day.ago)
  end

  def consenting_request(email, notify_next: true)
    confirmed_request(email, notify_next: notify_next).tap(&:grant_marketing_consent!)
  end

  def build_announcement(webinar, audience, author: "owner@example.test", author_sub: "sub-owner", author_role: "owner")
    Announcement.new(webinar: webinar, audience: audience, subject: "Infos du jour", body: "Bonjour,\nRDV salle 2.",
                     author_sub: author_sub, author_email: author, author_role: author_role,
                     dispatch_token: SecureRandom.hex(8))
  end

  # Animateur du projet (`User#project_host?` par le compte admin) : seul à
  # pouvoir envoyer aux listes.
  def project_host_user(email = "projet@example.test", sub: "sub-projet")
    User.create!(email: email, oidc_sub: sub, admin: true)
  end

  def guest_user(webinar, email = "co@example.test", sub: "sub-co")
    User.create!(email: email, oidc_sub: sub, email_verified: true, email_verified_for: email).tap do |user|
      webinar.webinar_hosts.create!(email: email, invited_by_sub: webinar.host_sub)
    end
  end
end

ActiveSupport::TestCase.include(AnnouncementFixtures)
