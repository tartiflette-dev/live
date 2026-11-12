require "test_helper"

class CatalogueControllerTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  # (face publique).
  # Vérifie : (a) la racine est publique et liste les webinaires publiés en
  # direct, en retard puis à venir, (b) draft/passé/terminé filtrés,
  # (c) /webinars reste animateur (garde inchangée).

  setup do
    @sub = "sub-host-#{SecureRandom.hex(4)}"
    @published_soon = Webinar.create!(
      title: "Café IA — septembre",
      starts_at: 2.days.from_now,
      host_sub: @sub,
      visibility: "published",
      kind: "cafe_ia",
      price_cents: 0
    )
    @published_later = Webinar.create!(
      title: "Bootcamp octobre",
      starts_at: 10.days.from_now,
      host_sub: @sub,
      visibility: "published",
      kind: "bootcamp",
      price_cents: 9900
    )
    @draft_future = Webinar.create!(
      title: "Draft à venir — invisible",
      starts_at: 5.days.from_now,
      host_sub: @sub,
      visibility: "draft",
      kind: "cafe_ia"
    )
    @published_past = Webinar.create!(
      title: "Café IA — passé (invisible)",
      starts_at: 2.days.ago,
      host_sub: @sub,
      visibility: "published",
      kind: "cafe_ia"
    )
  end

  test "public_index_lists_published" do
    # done_when 1 : anonyme, 200, cartes triées starts_at asc, titre +
    # date/heure (Europe/Paris via l fr) + kind + prix/Gratuit + lien /w/:slug.
    get root_path
    assert_response :success

    body = response.body
    assert_match(/Café IA — septembre/, body)
    assert_match(/Bootcamp octobre/, body)
    # Lien spectateur vers /w/<slug>
    assert_match %r{/w/#{@published_soon.slug}(?!/)}, body
    assert_match %r{/w/#{@published_later.slug}(?!/)}, body
    # Libellé kind localisé fr.
    assert_match(/Café IA/, body)
    assert_match(/Bootcamp/, body)
    # Prix : gratuit + montant formaté fr.
    assert_match(/Gratuit/, body)
    assert_match(/99,00\s*€/, body)
    # Ordre asc : @published_soon (2 j) avant @published_later (10 j).
    assert_operator body.index("Café IA — septembre"), :<, body.index("Bootcamp octobre"),
      "les cartes doivent être triées par starts_at asc"

    # La page publique ne DOIT exposer aucun
    # contrôle animateur à un anonyme (chrome-bas-centre « Mes webinaires »
    # + chrome-bas-droite « Nouveau webinaire »). Bug latent tant que la
    # racine redirigeait vers /sign_in — s'expose une fois `/` public.
    # Le chrome de la gem rend toujours les slots centre/droite : ils
    # doivent rester VIDES pour un anonyme.
    assert_select ".chrome-bas-centre > *", count: 0
    assert_select ".chrome-bas-droite > *", count: 0
    assert_no_match(/chrome-geste|chrome-deconnexion/, body,
      "la page publique ne doit pas exposer de contrôle animateur à un anonyme")
    assert_no_match(/aria-current="page"[^>]*>[^<]*Mes webinaires/, body,
      "la page publique ne doit pas marquer « Mes webinaires » comme page active")
  end

  test "public_index_hides_draft_and_past" do
    # done_when 2 : draft + passé absents ; GET / ne redirige plus vers /sign_in.
    get root_path
    assert_response :success
    assert_no_match(/Draft à venir — invisible/, response.body)
    assert_no_match(/Café IA — passé/, response.body)
  end

  test "animateur_index_still_protected" do
    # done_when 3 : /webinars (index animateur) reste derrière authenticate_animateur!.
    get webinars_path
    assert_redirected_to sign_in_path
  end

  # ---- done_when 3 : « paid_webinar_shows_notice » ----

  test "paid_webinar_shows_notice" do
    # Catalogue : un webinaire payant (price_cents > 0) affiche
    # « Sur inscription — accès après confirmation » en plus du prix.
    get root_path
    assert_response :success
    body = response.body

    # @published_later : price_cents=9900 → payant, notice attendue.
    # @published_soon  : price_cents=0    → gratuit, aucune notice.
    assert_match(/Sur inscription — accès après confirmation/, body)

    # Page avant-direct : un webinaire draft n'est pas listé au catalogue,
    # mais son propriétaire peut le voir. On teste le rendu public sur
    # un webinaire payant published (@published_later).
    get public_webinar_path(slug: @published_later.slug)
    assert_response :success
    assert_match(/Sur inscription — accès après confirmation/, response.body)

    # Le webinaire gratuit (@published_soon) n'affiche PAS la notice.
    get public_webinar_path(slug: @published_soon.slug)
    assert_response :success
    assert_no_match(/Sur inscription — accès après confirmation/, response.body)
  end

  test "paid_webinar_in_pack_shows_pack_label" do
    # « Inclus dans le pack <name> » remplace le prix nu quand le webinaire
    # est rattaché à un pack.
    pack = Pack.create!(name: "Bootcamp IA", price_cents: 49000, host_sub: @sub)
    @published_soon.update!(pack: pack)

    get root_path
    assert_response :success
    assert_match(/Inclus dans le pack Bootcamp IA/, response.body)
  end

  # ---- Cas réel : le webinaire quittait l'accueil à
  # son heure de début, direct en cours ou pas encore lancé. ----

  test "accueil : en direct, puis en retard, puis à venir ; terminé et draft périmé absents" do
    # Créé en premier : sans tri explicite du groupe, il passerait devant.
    Webinar.create!(title: "Café IA — lancé en avance", starts_at: 5.minutes.from_now, state: "live",
                    started_at: 2.minutes.ago, host_sub: @sub, visibility: "published")
    live = Webinar.create!(title: "Café IA — en direct", starts_at: 20.minutes.ago, state: "live",
                           started_at: 18.minutes.ago, host_sub: @sub, visibility: "published")
    late = Webinar.create!(title: "Café IA — en retard", starts_at: 15.minutes.ago,
                           host_sub: @sub, visibility: "published")
    Webinar.create!(title: "Café IA — terminé", starts_at: 1.hour.ago, state: "ended",
                    host_sub: @sub, visibility: "published")
    Webinar.create!(title: "Café IA — jamais lancé", starts_at: 4.hours.ago,
                    host_sub: @sub, visibility: "published")
    Webinar.create!(title: "Répétition privée en direct", starts_at: 5.minutes.ago, state: "live",
                    host_sub: @sub, visibility: "draft")

    get root_path
    assert_response :success

    titles = css_select("[data-role='catalogue'] > li h3").map { |h| h.text.strip }
    assert_equal [ "Café IA — en direct", "Café IA — lancé en avance", "Café IA — en retard",
                   "Café IA — septembre", "Bootcamp octobre" ], titles

    assert_select "[data-role='catalogue'] > li:nth-child(1)" do
      assert_select "[data-role='catalogue-status'].etat--en-cours", text: "En direct"
      assert_select "a[href=?]", public_webinar_path(slug: live.slug)
    end
    assert_select "[data-role='catalogue'] > li:nth-child(2) [data-role='catalogue-status']", text: "En direct"
    assert_select "[data-role='catalogue'] > li:nth-child(3)" do
      assert_select "[data-role='catalogue-status'].etat--alerte", text: "Va commencer"
      assert_select "a[href=?]", public_webinar_path(slug: late.slug)
    end
    assert_select "[data-role='catalogue-status']", count: 3,
      message: "les webinaires à venir ne portent pas de pastille de statut"
    assert_select "[data-role='catalogue-vide']", count: 0
  end

  test "accueil : un direct en cours suffit à sortir de l'état vide" do
    Webinar.destroy_all
    Webinar.create!(title: "Café IA #7", starts_at: 5.minutes.ago, state: "live",
                    host_sub: @sub, visibility: "published")

    get root_path
    assert_response :success
    assert_select "[data-role='catalogue-status']", text: "En direct"
    assert_no_match(/Aucun événement à venir/, response.body)
  end

  test "public_index_empty_state" do
    # État vide : 200 avec le message d'état vide (aucun webinaire publié en
    # direct, en retard ou à venir).
    Webinar.destroy_all
    get root_path
    assert_response :success
    assert_match(/Aucun événement à venir/, response.body)
  end

  # ---- Entrée animateur : le monogramme du chrome renvoie à la racine ;
  # sans ce lien, un anonyme n'a aucun chemin vers /sign_in. ----

  test "anonyme : le chrome du catalogue porte le lien de connexion animateur" do
    get root_path
    assert_response :success
    assert_select ".chrome-haut-droite a[href=?]", sign_in_path, text: "Connexion animateur"
  end

  test "connecté : le chrome du catalogue ne porte aucun lien de connexion" do
    sign_in_as(User.create!(email: "anim@example.com", oidc_sub: "sub-anim"))
    get root_path
    assert_response :success
    assert_select ".chrome-deconnexion", count: 1
    assert_select "a[href=?]", sign_in_path, count: 0
    assert_select ".chrome-haut-droite > *", count: 0
  end

  OLD_CHROME_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " \
                  "(KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36".freeze

  test "public_index_servi_a_un_navigateur_ancien" do
    # Preuve d'absence de garde navigateur :modern (page publique, cf.
    # AnimateurBrowserPolicy) — un poste d'entreprise figé doit voir le catalogue.
    get root_path, headers: { "User-Agent" => OLD_CHROME_UA }
    assert_response :success
  end
end
