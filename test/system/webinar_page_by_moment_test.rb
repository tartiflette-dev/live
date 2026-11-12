# frozen_string_literal: true

require "application_system_test_case"

# Page d'un webinaire rangée par moment : le bouton
# principal suit le moment, l'état est en français, les liens de base sont
# ensemble, les intervenants en tableau, le lien animateur et le jargon
# repliés. Chaque fonction déplacée reste
# atteignable : on la cherche là où elle est rangée, et on s'en sert.
class WebinarPageByMomentTest < ApplicationSystemTestCase
  include OidcSignIn
  include EpisodePublicationHelpers

  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "moment-owner")
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "avant le direct : « Programmé », bouton principal « Copier le lien public », heure au format 9:30" do
    webinar = cafe(starts_at: Time.zone.parse("2030-01-17 09:30"))
    sign_in_as(@owner)
    visit webinar_path(webinar)

    assert_selector "[data-role='webinar-state']", text: "Programmé"
    within("[data-role='webinar-actions']") do
      primary = find("button.btn:not(.btn--secondary)")
      assert_equal "Copier le lien public", primary.text
      assert_equal public_webinar_url(slug: webinar.slug, host: "www.example.com"), primary["data-copy-link"]
      assert_selector "a.btn.btn--secondary", text: "Ouvrir la scène"
      assert_selector "a.btn.btn--secondary", text: "Ouvrir la régie"
    end
    assert_selector "time", text: "jeudi 17 janvier 2030, 9:30"
    assert_no_text "09h30"
  end

  test "brouillon pas encore publié au catalogue : « Brouillon »" do
    webinar = cafe(starts_at: 2.days.from_now, visibility: "draft")
    sign_in_as(@owner)
    visit webinar_path(webinar)

    assert_selector "[data-role='webinar-state']", text: "Brouillon"
  end

  test "pendant le direct : « En direct », la régie est le bouton principal" do
    webinar = cafe(starts_at: 10.minutes.ago, state: "live", started_at: 5.minutes.ago)
    sign_in_as(@owner)
    visit webinar_path(webinar)

    assert_selector "[data-role='webinar-state']", text: "En direct"
    within("[data-role='webinar-actions']") do
      assert_selector "a.btn:not(.btn--secondary)", count: 1
      assert_link "Ouvrir la régie", href: webinar_regie_path(webinar), class: "btn"
      assert_no_selector "a.btn--secondary", text: "Ouvrir la régie"
    end
  end

  test "les trois liens de base sont ensemble, chacun avec « Copier le lien »" do
    webinar = cafe(starts_at: 2.days.from_now)
    share_token = webinar.generate_share_token!
    sign_in_as(@owner)
    visit webinar_path(webinar)

    within("#liens") do
      assert_selector "button[data-copy-link='#{stage_webinar_url(slug: webinar.slug, host: "www.example.com")}']", text: "Copier le lien"
      assert_selector "button[data-copy-link='#{public_webinar_url(slug: webinar.slug, host: "www.example.com")}']", text: "Copier le lien"
      assert_selector "button[data-copy-link='#{invitation_url(t: share_token, host: "www.example.com")}']", text: "Copier le lien"
      # Régénérer et Désactiver : dans le menu « … », pas au premier plan.
      [ "Désactiver", "Régénérer (invalide l’ancien)" ].each do |label|
        assert_selector "details[data-role='invitation-menu']:not([open]) button", text: label, visible: :all
      end
    end
  end

  test "lien participants privé : Régénérer puis Désactiver depuis le menu « … »" do
    webinar = cafe(starts_at: 2.days.from_now)
    old_token = webinar.generate_share_token!
    sign_in_as(@owner)
    visit webinar_path(webinar)

    within("[data-role='invitation-link']") do
      find("summary[aria-label='Autres actions : lien participants privé']").click
      click_button "Régénérer (invalide l’ancien)"
    end
    assert_not_equal old_token, webinar.reload.share_token

    within("[data-role='invitation-link']") do
      find("[data-role='invitation-menu'] summary").click
      click_button "Désactiver"
    end
    assert_nil webinar.reload.share_token
    assert_button "Générer le lien participants privé"
  end

  test "intervenants en tableau : email modifié en ligne, ajout en bas, Régénérer et Révoquer dans « … »" do
    webinar = cafe(starts_at: 2.days.from_now)
    basile = webinar.speakers.create!(name: "Basile")
    marc = webinar.speakers.create!(name: "Marc")
    sign_in_as(@owner)
    visit webinar_path(webinar)

    within("#intervenants table") do
      assert_selector "thead th", text: "Nom"
      assert_selector "tbody tr[data-speaker-id]", count: 2
      within("tr[data-speaker-id='#{basile.id}']") do
        assert_selector "th", text: "Basile"
        assert_selector "button[data-role='speaker-copy']", text: "Copier le lien"
        fill_in "Email de Basile", with: "basile@example.test"
        click_button "Enregistrer"
      end
    end
    assert_text "Adresse de l'intervenant enregistrée."
    assert_equal "basile@example.test", basile.reload.email
    assert_field "Email de Basile", with: "basile@example.test"

    # Ligne d'ajout : après le tableau.
    assert page.body.index("speaker-add-form") > page.body.index("table-intervenants"), "l'ajout doit suivre le tableau"
    within("[data-role='speaker-add-form']") do
      fill_in "Nom de l’intervenant", with: "Zoé"
      fill_in "Email (facultatif)", with: "zoe@example.test"
      click_button "Ajouter un intervenant"
    end
    assert_text "Intervenant ajouté."
    assert_equal "zoe@example.test", webinar.speakers.find_by!(name: "Zoé").email

    within("tr[data-speaker-id='#{basile.id}']") do
      find("summary[aria-label='Autres actions : Basile']").click
      click_button "Régénérer (invalide l’ancien)"
    end
    assert basile.reload.replaced_by_id?
    assert_selector "tr[data-speaker-id='#{basile.id}'] [data-role='speaker-replaced']", text: "Remplacé"
    assert_selector "tr[data-speaker-id='#{basile.replaced_by_id}'] button[data-role='speaker-copy']"

    within("tr[data-speaker-id='#{marc.id}']") do
      find("[data-role='speaker-menu'] summary").click
      click_button "Révoquer"
    end
    assert marc.reload.revoked_at?
    within("tr[data-speaker-id='#{marc.id}']") do
      assert_text "Lien révoqué"
      assert_no_selector "button[data-role='speaker-copy']"
      assert_no_selector "[data-role='speaker-menu']"
    end
  end

  test "co-animateurs : email et « Ajouter » visibles, lien animateur replié sous « Avancé »" do
    webinar = cafe(starts_at: 2.days.from_now)
    sign_in_as(@owner)
    visit webinar_path(webinar)

    assert_not_includes text_outside_closed_details, "Nombre d’usages", "le lien animateur doit être replié"
    within("[data-role='co-animateurs']") do
      fill_in "Email du co-animateur", with: "jean@partenaire.test"
      click_button "Ajouter un co-animateur"
    end
    assert_equal [ "jean@partenaire.test" ], webinar.webinar_hosts.pluck(:email)

    within("[data-role='co-animateurs']") do
      assert_selector "[data-role='co-animateur-list'] li", text: "jean@partenaire.test"
      find("summary", text: "Avancé : lien animateur").click
      assert_field "Nombre d’usages"
      assert_field "Expire le"
      assert_field "Lien d’inscription Pocket ID"
      fill_in "Nombre d’usages", with: "4"
      click_button "Créer un lien animateur"
    end
    invitation = webinar.host_invitations.sole
    assert_equal 4, invitation.max_uses

    within("[data-role='co-animateurs']") do
      find("summary", text: "Avancé : lien animateur").click
      within("[data-host-invitation-id='#{invitation.id}']") do
        assert_selector "button[data-role='host-invitation-copy']"
        find("[data-role='host-invitation-menu'] summary").click
        click_button "Révoquer"
      end
    end
    assert invitation.reload.revoked_at?
  end

  test "le jargon (Room LiveKit, token re-signé, live-invites) est sous « Détails techniques », replié" do
    webinar = cafe(starts_at: 2.days.from_now)
    sign_in_as(@owner)
    visit webinar_path(webinar)

    unfolded = text_outside_closed_details
    [ "Room LiveKit", "re-signé", "live-invites", webinar.room_name ].each do |jargon|
      assert_not_includes unfolded, jargon, "« #{jargon} » doit rester replié"
    end

    find("summary", text: "Détails techniques").click
    within("[data-role='technical-details']") do
      assert_text "Room LiveKit"
      assert_text webinar.room_name
      assert_text "Token re-signé à chaque accès"
      assert_text "live-invites"
    end
  end

  test "après le direct : « Terminé », fichiers en tête, « Valider les vidéos » en bouton principal, heures et durée de chaque vidéo" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      composite = add_recording(webinar, kind: "composite", file: "seance.mp4")
      webinar.speakers.create!(name: "thomas")
      laurent = webinar.speakers.create!(name: "laurent")
      webinar.speakers.create!(name: "Ancien", revoked_at: 1.hour.ago)
      publish_for_review(webinar, "video-complete-fin-10h27-#{composite.id}.mp4")
      host = User.find_by!(oidc_sub: "publication-host")

      with_nextcloud(FakeNextcloud.new) do
        sign_in_as(host)
        visit webinar_path(webinar)

        assert_selector "[data-role='webinar-state']", text: "Terminé"
        assert_no_text "ended"
        assert_operator page.body.index("data-role=\"publication\""), :<, page.body.index("id=\"liens\""),
                        "après le direct, les fichiers passent avant les liens"
        within("[data-role='webinar-actions']") do
          assert_link "Valider les vidéos", href: "#publication-review", class: "btn"
          assert_selector "a.btn--secondary", text: "Ouvrir la scène"
        end

        within("#publication-review") do
          assert_selector "[data-role='publication-review-file']", text: "video-complete-fin-10h27-#{composite.id}.mp4"
          assert_selector "[data-role='publication-review-timing']", text: "9:31-10:27 · 57 min"
          # L'alerte est juste avant « Valider et partager ».
          alert = find("[data-role='speakers-without-email']")
          assert_includes alert.text, "2 intervenants sans adresse : ils ne seront pas prévenus."
          assert_link "Compléter les adresses", href: "#intervenants"
          assert_button "Valider et partager"
        end
        assert_selector "#intervenants"

        within("tr[data-speaker-id='#{laurent.id}']") do
          fill_in "Email de laurent", with: "laurent@example.test"
          click_button "Enregistrer"
        end
        assert_selector "#publication-review [data-role='speakers-without-email']",
                        text: "1 intervenant sans adresse : il ne sera pas prévenu."
      end
    end
  end

  test "après le direct, tous les intervenants ont une adresse : pas d'alerte" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      composite = add_recording(webinar, kind: "composite", file: "seance.mp4")
      webinar.speakers.create!(name: "thomas", email: "thomas@example.test")
      publish_for_review(webinar, "video-complete-fin-10h27-#{composite.id}.mp4")

      with_nextcloud(FakeNextcloud.new) do
        sign_in_as(User.find_by!(oidc_sub: "publication-host"))
        visit webinar_path(webinar)

        assert_button "Valider et partager"
        assert_no_selector "[data-role='speakers-without-email']"
      end
    end
  end

  test "co-animateur invité après le direct : aucun bouton principal, ni vidéos ni intervenants" do
    guest = User.create!(email: "jean@partenaire.test", oidc_sub: "moment-guest",
                         email_verified: true, email_verified_for: "jean@partenaire.test")
    webinar = cafe(starts_at: 2.hours.ago, state: "ended", started_at: 2.hours.ago, ended_at: 1.hour.ago)
    webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @owner.oidc_sub)
    sign_in_as(guest)
    visit webinar_path(webinar)

    assert_selector "[data-role='webinar-state']", text: "Terminé"
    within("[data-role='webinar-actions']") do
      assert_no_selector ".btn:not(.btn--secondary)"
      assert_link "Ouvrir la scène"
      assert_link "Ouvrir la régie"
    end
    assert_no_selector "[data-role='publication']"
    assert_no_selector "#intervenants"
    assert_no_selector "[data-role='co-animateurs']"
  end

  private

  # Texte de la page sans le contenu des blocs repliés (`details` fermés, à
  # part leur `summary`) : ce que l'animateur lit sans rien déplier.
  def text_outside_closed_details
    document = Nokogiri::HTML(page.html)
    document.css("details:not([open]) > :not(summary)").each(&:remove)
    document.at_css("main").text
  end

  def cafe(starts_at:, visibility: "published", **attributes)
    Webinar.create!(title: "Café IA 9", slug: "cafe-ia-9", kind: "cafe_ia", visibility: visibility,
                    starts_at: starts_at, host_sub: @owner.oidc_sub, **attributes)
  end

  def publish_for_review(webinar, name)
    webinar.create_episode_publication!(
      status: "published", folder: "Cafe-IA/2030-01-17-cafe-ia-007", folder_url: "https://cloud.test/f/4242",
      review_folder: "Relecture/Cafe-IA/2030-01-17-cafe-ia-007", review_folder_url: "https://cloud.test/f/7777",
      started_at: 5.minutes.ago, published_at: 4.minutes.ago,
      files: [ { "name" => "README.md", "size" => 1, "zone" => "shared" },
               { "name" => name, "size" => 2, "zone" => "review" } ]
    )
  end
end
