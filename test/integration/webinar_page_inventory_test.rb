# frozen_string_literal: true

require "test_helper"

# Inventaire de la page d'un webinaire (webinars#show), écrit AVANT sa
# refonte par moment, dont la règle est : « Je veux pas perdre
# de lien ou de fonction, même si tu ranges différemment ».
#
# Chaque fonction est cherchée par ce qui la fait marcher (route et verbe
# d'un formulaire, cible d'un lien, URL d'un bouton « Copier le lien »,
# champ envoyé), jamais par sa place sur la page : on peut la déplacer, la
# replier ou la regrouper, pas la retirer. Les mêmes tests passent sur la
# page d'avant et sur celle d'après.
class WebinarPageInventoryTest < ActionDispatch::IntegrationTest
  include OidcSignIn
  include EpisodePublicationHelpers

  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "inventaire-owner")
    @guest = User.create!(email: "jean@partenaire.test", oidc_sub: "inventaire-guest",
                          email_verified: true, email_verified_for: "jean@partenaire.test")
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "avant le direct : liens, intervenants, co-animateurs, présence et pages annexes" do
    webinar = cafe(state: "draft", starts_at: 2.days.from_now)
    previous = cafe(state: "ended", slug: "cafe-ia-6", starts_at: 5.days.ago)
    previous.webinar_hosts.create!(email: "ancien@partenaire.test", invited_by_sub: @owner.oidc_sub)
    share_token = webinar.generate_share_token!
    speaker = webinar.speakers.create!(name: "Basile")
    webinar.speakers.create!(name: "Ancien", revoked_at: 1.hour.ago)
    host = webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    invitation = webinar.host_invitations.create!(created_by_sub: @owner.oidc_sub, max_uses: 3,
                                                  expires_at: 1.day.from_now)

    sign_in_as(@owner)
    get webinar_path(webinar)
    assert_response :success

    assert_common_navigation(webinar)
    assert_link_to webinar_edition_path(webinar)
    assert_link_to webinar_program_path(webinar)

    # Les trois liens de base, chacun copiable.
    assert_copy_button stage_webinar_url(slug: webinar.slug)
    assert_copy_button public_webinar_url(slug: webinar.slug)
    assert_copy_button invitation_url(t: share_token)
    # Lien participants privé : régénérer, désactiver.
    assert_form :post, webinar_share_link_path(webinar)
    assert_form :delete, webinar_share_link_path(webinar)

    # Intervenants : ajout (nom + email), lien personnel copiable, email
    # modifiable, régénérer, révoquer. Un lien révoqué ne se copie plus.
    assert_form :post, webinar_speakers_path(webinar), fields: %w[speaker[name] speaker[email]]
    assert_copy_button join_webinar_url(slug: webinar.slug, t: speaker.token)
    assert_form :patch, webinar_speaker_path(webinar, speaker), fields: %w[speaker[email]]
    assert_form :post, regenerate_webinar_speaker_path(webinar, speaker)
    assert_form :post, revoke_webinar_speaker_path(webinar, speaker)
    assert_select "[data-role='links-expiry']", text: /expirent le/

    # Co-animateurs : ajout par email, retrait, reprise du café précédent,
    # lien animateur (usages, expiration, Pocket ID), copie et révocation.
    assert_form :post, webinar_hosts_path(webinar), fields: %w[webinar_host[email]]
    assert_form :delete, webinar_host_path(webinar, host)
    assert_form :post, carry_over_webinar_hosts_path(webinar), fields: %w[emails[]]
    assert_form :post, webinar_host_invitations_path(webinar),
                fields: %w[host_invitation[max_uses] host_invitation[expires_at] host_invitation[signup_url]]
    assert_copy_button host_invitation_url(t: invitation.token)
    assert_form :post, revoke_webinar_host_invitation_path(webinar, invitation)

    # Présence des animateurs (café publié, à venir).
    assert_form :post, webinar_presence_path(webinar), count: 2

    # Détails techniques, jamais supprimés.
    assert_includes response.body, webinar.room_name
  end

  test "lien participants privé absent : le bouton le génère" do
    webinar = cafe(state: "draft", starts_at: 2.days.from_now)

    sign_in_as(@owner)
    get webinar_path(webinar)

    assert_form :post, webinar_share_link_path(webinar)
    assert_select "[data-role='invitation-generate']"
  end

  test "pendant le direct : scène, régie, message, enregistrements, inscrits, liens" do
    webinar = cafe(state: "live", starts_at: 10.minutes.ago, started_at: 5.minutes.ago)
    speaker = webinar.speakers.create!(name: "Basile")

    sign_in_as(@owner)
    get webinar_path(webinar)

    assert_common_navigation(webinar)
    assert_copy_button stage_webinar_url(slug: webinar.slug)
    assert_copy_button public_webinar_url(slug: webinar.slug)
    assert_copy_button join_webinar_url(slug: webinar.slug, t: speaker.token)
    assert_form :patch, webinar_speaker_path(webinar, speaker), fields: %w[speaker[email]]
  end

  test "après le direct : vidéos à valider, publication, et toutes les fonctions d'avant" do
    webinar = cafe(state: "ended", starts_at: 2.hours.ago, started_at: 2.hours.ago, ended_at: 30.minutes.ago)
    speaker = webinar.speakers.create!(name: "Basile")
    webinar.create_episode_publication!(
      status: "published", folder: "Cafe-IA/2030-01-17-cafe-ia-007", folder_url: "https://cloud.test/f/4242",
      review_folder: "Relecture/Cafe-IA/2030-01-17-cafe-ia-007", review_folder_url: "https://cloud.test/f/7777",
      started_at: 5.minutes.ago, published_at: 4.minutes.ago,
      files: [ { "name" => "README.md", "size" => 1, "zone" => "shared" },
               { "name" => "video-complete-1.mp4", "size" => 2, "zone" => "review" } ]
    )

    sign_in_as(@owner)
    with_nextcloud(FakeNextcloud.new) { get webinar_path(webinar) }

    assert_common_navigation(webinar)
    assert_form :patch, webinar_publication_path(webinar), fields: %w[names[]]
    assert_form :post, webinar_publication_path(webinar)
    assert_link_to "https://cloud.test/f/4242"
    assert_link_to "https://cloud.test/f/7777"
    assert_copy_button join_webinar_url(slug: webinar.slug, t: speaker.token)
    assert_form :patch, webinar_speaker_path(webinar, speaker), fields: %w[speaker[email]]
    assert_form :post, regenerate_webinar_speaker_path(webinar, speaker)
    assert_form :post, revoke_webinar_speaker_path(webinar, speaker)
  end

  test "co-animateur invité : scène, régie, message et programme ; ni inscrits, ni enregistrements, ni intervenants" do
    webinar = cafe(state: "draft", starts_at: 2.days.from_now)
    webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    speaker = webinar.speakers.create!(name: "Basile")
    share_token = webinar.generate_share_token!
    invitation = webinar.host_invitations.create!(created_by_sub: @owner.oidc_sub, max_uses: 3,
                                                  expires_at: 1.day.from_now)

    sign_in_as(@guest)
    get webinar_path(webinar)

    assert_link_to stage_webinar_path(slug: webinar.slug)
    assert_link_to webinar_regie_path(webinar)
    assert_link_to new_webinar_announcement_path(webinar)
    assert_link_to webinar_program_path(webinar)
    assert_copy_button stage_webinar_url(slug: webinar.slug)
    assert_copy_button public_webinar_url(slug: webinar.slug)

    assert_select "a[href='#{webinar_registrations_path(webinar)}']", count: 0
    assert_select "a[href='#{webinar_room_presence_path(webinar)}']", count: 0
    assert_select "a[href='#{webinar_recordings_path(webinar)}']", count: 0
    assert_select "a[href='#{webinar_replay_path(webinar)}']", count: 0
    assert_select "form[action='#{webinar_speakers_path(webinar)}']", count: 0
    assert_select "form[action='#{webinar_hosts_path(webinar)}']", count: 0
    assert_select "[data-role='publication']", count: 0
    [ speaker.token, share_token, invitation.token ].each { |secret| assert_not_includes response.body, secret }
  end

  private

  def cafe(state:, starts_at:, slug: "cafe-ia-7", **attributes)
    Webinar.create!(title: "Café IA #{slug[/\d+\z/]}", slug: slug, kind: "cafe_ia", visibility: "published",
                    starts_at: starts_at, host_sub: @owner.oidc_sub, state: state, **attributes)
  end

  def assert_common_navigation(webinar)
    assert_link_to stage_webinar_path(slug: webinar.slug)
    assert_link_to webinar_regie_path(webinar)
    assert_link_to new_webinar_announcement_path(webinar)
    assert_link_to webinar_recordings_path(webinar)
    assert_link_to webinar_replay_path(webinar)
    assert_link_to webinar_registrations_path(webinar)
    assert_link_to webinar_room_presence_path(webinar)
  end

  def assert_link_to(href)
    assert_select "a[href=?]", href, { minimum: 1 }, "lien vers #{href} absent"
  end

  def assert_copy_button(url)
    assert_select "button[data-copy-link=?]", url, { minimum: 1 }, "bouton « Copier le lien » pour #{url} absent"
  end

  # Un formulaire `method` vers `action`. Rails simule PATCH et DELETE par
  # un champ caché `_method` ; un POST n'en a pas.
  def assert_form(method, action, fields: [], count: nil)
    forms = css_select("form[action='#{action}'][method='post']").select do |form|
      verb = form.at_css("input[name='_method']")&.[]("value") || "post"
      verb == method.to_s
    end
    if count
      assert_equal count, forms.size, "#{method.upcase} #{action} : #{forms.size} formulaire(s), #{count} attendu(s)"
    else
      assert forms.any?, "formulaire #{method.upcase} #{action} absent"
    end
    fields.each do |name|
      assert forms.any? { |form| form.at_css("[name='#{name}']") }, "champ #{name} absent de #{method.upcase} #{action}"
    end
  end
end
