require "application_system_test_case"

class WebinarCreationTest < ApplicationSystemTestCase
  # — critère principal (system test Capybara) :
  # "Un animateur authentifié crée un webinaire et voit 3 liens distincts".

  FAKE_KEY    = "APIfake"
  FAKE_SECRET = "sekret-32bytes-long-enough-abcdef"

  setup do
    @host = User.create!(email: "marc@example.com", oidc_sub: "sub-marc", admin: true)
    @prev_key    = ENV["LIVEKIT_API_KEY"]
    @prev_secret = ENV["LIVEKIT_API_SECRET"]
    ENV["LIVEKIT_API_KEY"]    = FAKE_KEY
    ENV["LIVEKIT_API_SECRET"] = FAKE_SECRET
  end

  teardown do
    ENV["LIVEKIT_API_KEY"]    = @prev_key
    ENV["LIVEKIT_API_SECRET"] = @prev_secret
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  test "creates_webinar_with_links" do
    sign_in_as(@host)

    visit new_webinar_path
    fill_in "Titre", with: "Kick-off Q4"
    # datetime_local_field attend "YYYY-MM-DDTHH:MM" (pas de timezone).
    fill_in "Démarre le", with: 1.day.from_now.strftime("%Y-%m-%dT%H:%M")
    click_on "Créer le webinaire"

    # Redirect → show. Le webinaire est en base.
    w = Webinar.find_by!(title: "Kick-off Q4")
    assert_current_path webinar_path(w)

    fill_in "Nom de l’intervenant", with: "Basile"
    click_on "Ajouter un intervenant"
    assert_text "Intervenant ajouté."

    # Scène, invitation nominative et page publique ont des URLs distinctes ;
    # chacune se copie par son bouton, le lien nominatif ne s'affiche pas.
    stage_link   = find("button[data-role='stage-copy']")["data-copy-link"]
    speaker_link = find("button[data-role='speaker-copy']")["data-copy-link"]
    viewer_link  = find("button[data-role='viewer-copy']")["data-copy-link"]

    assert_equal stage_link, find("input[data-role='stage-link']").value
    assert_equal viewer_link, find("input[data-role='viewer-link']").value
    assert_no_selector "input[data-role='speaker-link']"

    assert_match %r{/w/#{w.slug}/stage\z},    stage_link
    assert_match %r{/w/#{w.slug}/join\?t=},   speaker_link
    assert_match %r{/w/#{w.slug}\z},          viewer_link

    assert_equal [ stage_link, speaker_link, viewer_link ].uniq.size, 3,
      "les 3 liens doivent être distincts (vu : #{[ stage_link, speaker_link, viewer_link ].inspect})"
  end

  test "webinar_creation_with_catalogue_fields" do
    sign_in_as(@host)

    visit new_webinar_path
    fill_in "Titre", with: "Bootcamp Q4"
    fill_in "Démarre le", with: 1.day.from_now.strftime("%Y-%m-%dT%H:%M")
    fill_in "Description", with: "Un bootcamp"
    select "Publié", from: "Visibilité"
    select "Bootcamp", from: "Format"
    fill_in "Prix (centimes)", with: "9900"
    click_on "Créer le webinaire"

    w = Webinar.find_by!(title: "Bootcamp Q4")
    assert_current_path webinar_path(w)
    assert_equal "Un bootcamp", w.description
    assert_equal "published", w.visibility
    assert_equal "bootcamp", w.kind
    assert_equal 9900, w.price_cents
    assert_equal "draft", w.state
    assert_equal "sub-marc", w.host_sub
    assert_match(/\Abootcamp-q4/, w.slug)
    assert_equal w.slug, w.room_name
  end

  test "host discovers packs and creates a webinar in a new pack" do
    sign_in_as(@host)
    click_on "Mes packs"
    assert_current_path packs_path
    click_on "Nouveau pack", match: :first
    fill_in "Nom", with: "Bootcamp découverte"
    fill_in "Prix (centimes)", with: "49000"
    click_on "Créer le pack"
    assert_text "Bootcamp découverte"

    click_on "Nouveau webinaire"
    fill_in "Titre", with: "Première session du pack"
    fill_in "Démarre le", with: 1.day.from_now.strftime("%Y-%m-%dT%H:%M")
    select "Bootcamp découverte", from: "Pack"
    click_on "Créer le webinaire"

    webinar = Webinar.find_by!(title: "Première session du pack")
    assert_current_path webinar_path(webinar)
    assert_equal "Bootcamp découverte", webinar.pack.name
    assert_equal @host.oidc_sub, webinar.pack.host_sub
  end

  test "host revokes one invitation while another speaker keeps access" do
    webinar = Webinar.create!(title: "Guests", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    sign_in_as(@host)
    visit webinar_path(webinar)
    [ "Basile", "Marc" ].each do |name|
      fill_in "Nom de l’intervenant", with: name
      click_on "Ajouter un intervenant"
    end
    basile = webinar.speakers.find_by!(name: "Basile")
    marc = webinar.speakers.find_by!(name: "Marc")
    within "[data-speaker-id='#{basile.id}']" do
      find("[data-role='speaker-menu'] summary").click
      click_on "Révoquer"
    end
    within "[data-speaker-id='#{basile.id}']" do
      assert_text "Lien révoqué"
      assert_no_selector "button[data-role='speaker-copy']"
    end
    assert_selector "[data-speaker-id='#{marc.id}'] button[data-role='speaker-copy']"

    visit join_webinar_path(slug: webinar.slug, t: basile.token)
    assert_equal 404, page.status_code
    visit join_webinar_path(slug: webinar.slug, t: marc.token)
    assert_selector "#livekit-room[data-speaker-token='#{marc.token}']"
  end

  private

  def sign_in_as(user)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email }
    )
    # `visit` déclenche le callback OIDC directement — le middleware
    # OmniAuth en test_mode court-circuite la request phase.
    visit "/auth/pocket_id/callback"
  end
end
