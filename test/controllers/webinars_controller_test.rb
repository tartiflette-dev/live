require "test_helper"

class WebinarsControllerTest < ActionDispatch::IntegrationTest
  # (CRUD) et rendu HTML salle. L'émission de
  # token LiveKit est TESTÉE dans test/controllers/api/tokens_controller_test.rb.
  # Ici, on vérifie : auth animateur, scoping host_sub, rendu HTML salle
  # (data-attrs slug + speaker-token éventuel), 404 sur altération.

  setup do
    @host   = User.create!(email: "marc@example.com",  oidc_sub: "sub-marc", admin: true)
    @other  = User.create!(email: "eve@example.com",  oidc_sub: "sub-eve")
    # Propriétaire NON-admin — l'isolation
    # standard (host_sub) ne s'applique qu'aux non-animateurs du projet ;
    # un admin voit tout par contrat. `email_verified: true` est posé
    # pour que l'invité puisse être résolu `:guest_host` quand ce user
    # est utilisé en invité (défense broken-authentication).
    @simple_host = User.create!(email: "simple@example.com", oidc_sub: "sub-simple", email_verified: true, email_verified_for: "simple@example.com")
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  # ---- Auth animateur (CRUD protégé, cf. authenticatable) ----

  test "index redirige vers sign_in si non authentifié" do
    get webinars_path
    assert_redirected_to sign_in_path
  end

  # Racine = catalogue PUBLIC :
  # les tests d'accès animateur portent désormais sur /webinars uniquement.
  # Le contrat catalogue est couvert par CatalogueControllerTest.

  test "new redirige vers sign_in si non authentifié" do
    get new_webinar_path
    assert_redirected_to sign_in_path
  end

  test "create refusé si non authentifié" do
    assert_no_difference -> { Webinar.count } do
      post webinars_path, params: { webinar: { title: "X", starts_at: 1.day.from_now } }
    end
    assert_redirected_to sign_in_path
  end

  # ---- CRUD basique ----

  test "index scope par host_sub (n'expose PAS les webinaires des autres pour un non-admin)" do
    # L'isolation stricte s'applique aux
    # propriétaires non-animateurs-du-projet. Un admin voit tout (testé
    # séparément dans index_admin_voit_tous_les_webinaires).
    _mine  = Webinar.create!(title: "à moi",   starts_at: 1.day.from_now, host_sub: @simple_host.oidc_sub)
    _other = Webinar.create!(title: "à eve",   starts_at: 1.day.from_now, host_sub: @other.oidc_sub)

    sign_in_as(@simple_host)
    get webinars_path
    assert_response :success
    assert_includes response.body, "à moi"
    assert_not_includes response.body, "à eve"
  end

  test "index_admin_voit_tous_les_webinaires" do
    _mine  = Webinar.create!(title: "à moi",   starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    _other = Webinar.create!(title: "à eve",   starts_at: 1.day.from_now, host_sub: @other.oidc_sub)

    sign_in_as(@host)
    get webinars_path
    assert_response :success
    assert_includes response.body, "à moi"
    assert_includes response.body, "à eve"
  end

  test "index : état en français et heure au format 9:30" do
    Webinar.create!(title: "fini", starts_at: Time.zone.parse("2030-01-17 09:30"), host_sub: @host.oidc_sub,
                    state: "ended", started_at: Time.zone.parse("2030-01-17 09:31"), ended_at: Time.zone.parse("2030-01-17 10:30"))

    sign_in_as(@host)
    get webinars_path

    assert_select "[data-role='webinar-state']", text: "Terminé"
    assert_select "time", text: "jeudi 17 janvier 2030, 9:30"
    assert_not_includes response.body, ">ended<"
  end

  test "index_expose_les_webinaires_coanimes_par_email" do
    coanimated = Webinar.create!(title: "à eve co-animé", starts_at: 1.day.from_now, host_sub: @other.oidc_sub)
    coanimated.webinar_hosts.create!(email: @simple_host.email, invited_by_sub: @other.oidc_sub)
    _solo = Webinar.create!(title: "pas pour simple", starts_at: 1.day.from_now, host_sub: @other.oidc_sub)

    sign_in_as(@simple_host)
    get webinars_path
    assert_response :success
    assert_includes response.body, "à eve co-animé"
    assert_not_includes response.body, "pas pour simple"
  end

  test "create pose host_sub = current_user.oidc_sub (JAMAIS depuis params)" do
    sign_in_as(@host)
    # Tentative d'injection host_sub via params — DOIT être ignorée par
    # strong params (webinar_params ne permit pas host_sub).
    post webinars_path, params: { webinar: { title: "Kick-off",
                                             starts_at: 1.day.from_now,
                                             host_sub: "sub-attaquant" } }
    assert_response :redirect
    w = Webinar.last
    assert_equal "sub-marc", w.host_sub
  end

  test "webinar_creation_with_catalogue_fields" do
    sign_in_as(@host)

    get new_webinar_path
    assert_response :success
    assert_select "textarea[name='webinar[description]']"
    assert_select "select[name='webinar[visibility]']"
    assert_select "select[name='webinar[kind]']"
    assert_select "input[name='webinar[price_cents]']"
    assert_select "input[name='webinar[slug]']", count: 0
    assert_select "input[name='webinar[state]']", count: 0
    assert_select "input[name='webinar[host_sub]']", count: 0
    assert_select "input[name='webinar[room_name]']", count: 0

    post webinars_path, params: {
      webinar: {
        title: "Bootcamp Q4",
        starts_at: 1.day.from_now,
        description: "Un bootcamp",
        visibility: "published",
        kind: "bootcamp",
        price_cents: 9900,
        state: "live",
        host_sub: "sub-attaquant",
        slug: "injected",
        room_name: "injected-room"
      }
    }
    assert_response :redirect
    w = Webinar.find_by!(title: "Bootcamp Q4")
    assert_equal "Un bootcamp", w.description
    assert_equal "published", w.visibility
    assert_equal "bootcamp", w.kind
    assert_equal 9900, w.price_cents
    assert_equal "draft", w.state
    assert_equal "sub-marc", w.host_sub
    assert_not_equal "injected", w.slug
    assert_not_equal "injected-room", w.room_name
    assert w.slug.present?
    assert w.room_name.present?
  end

  test "show d'un autre host = 404 pour un non-admin sans invitation" do
    # Un admin verrait le webinaire (droits étendus) ;
    # seul un non-animateur-du-projet reçoit 404 (sauf co-animation).
    other_w = Webinar.create!(title: "eve", starts_at: 1.day.from_now, host_sub: @other.oidc_sub)
    sign_in_as(@simple_host)
    get webinar_path(other_w)
    assert_response :not_found
  end

  test "show_d_un_webinaire_coanime_par_email_200" do
    other_w = Webinar.create!(title: "co-animé", starts_at: 1.day.from_now, host_sub: @other.oidc_sub)
    other_w.webinar_hosts.create!(email: @simple_host.email, invited_by_sub: @other.oidc_sub)
    sign_in_as(@simple_host)
    get webinar_path(other_w)
    assert_response :success
  end

  test "show expose scène, invitation nominative et spectateur" do
    sign_in_as(@host)
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    w.speakers.create!(name: "Basile")
    get webinar_path(w)
    assert_response :success
    body = response.body
    assert_match(/#{Regexp.escape(stage_webinar_url(slug: w.slug))}/, body)
    assert_match(/#{Regexp.escape(public_webinar_url(slug: w.slug))}/, body)
    assert_match(/join_webinar_url|\/w\/#{w.slug}\/join\?t=/, body)
    # 3 URLs distinctes.
    urls = body.scan(/https?:\/\/[^"'\s]+\/w\/#{w.slug}[^"'\s]*/).uniq
    assert_operator urls.size, :>=, 3, "attendu 3 URLs distinctes, vu #{urls.inspect}"
  end

  # F : « Spectateur — aucun compte requis, écoute seule » était
  # faux (inscription, discussion, main levée) et a causé une confusion.
  # Chaque lien dit à qui il sert.
  test "show nomme le lien public et le lien participants privé" do
    sign_in_as(@host)
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    w.generate_share_token!

    get webinar_path(w)

    assert_select "#link-viewer", text: "Lien public — inscription"
    assert_select "section[aria-labelledby=link-viewer] p",
      text: /Inscription publique : observer \(chat\) ou participer \(caméra et micro, après admission en régie\)/
    assert_select "#link-invitation", text: "Lien participants privé"
    assert_select "[data-role=invitation-link] p", text: /À donner à tes intervenants : caméra et micro sans admission, dès leur accord à l'image ; mail obligatoire/
    assert_select "[data-role=links-expiry]", text: /Sans direct lancé, expirent le/
    assert_not_includes response.body, "écoute seule"
  end

  # Constat en direct : un partage d'écran de cette page a montré les
  # jetons. Un jeton secret ne vit plus que dans le data-copy-link du bouton
  # « Copier le lien » — ni texte, ni valeur de champ, ni title.
  test "show ne laisse aucun jeton secret hors du data-copy-link des boutons Copier" do
    sign_in_as(@host)
    w = Webinar.create!(title: "Café IA #7", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    share_token = w.generate_share_token!
    speaker = w.speakers.create!(name: "Basile")
    host_link = w.host_invitations.create!(created_by_sub: @host.oidc_sub, max_uses: 3, expires_at: 1.day.from_now)

    get webinar_path(w)

    document = Nokogiri::HTML(response.body)
    [ share_token, speaker.token, host_link.token ].each do |secret|
      assert_not_includes document.text, secret
      carriers = document.xpath("//@*").select { |attribute| attribute.value.include?(secret) }
      assert_equal [ "button@data-copy-link" ], carriers.map { |attribute| "#{attribute.parent.name}@#{attribute.name}" }
    end
    assert_select "input[data-role='invitation-url'][value=?]", "www.example.com/i?t=••••••••"
    # Lien personnel d'un intervenant : une ligne du tableau, sans l'URL
    # affichée ; seul son bouton « Copier le lien » la porte.
    assert_select "[data-speaker-id='#{speaker.id}'] button[data-role='speaker-copy'][data-copy-link=?]",
                  join_webinar_url(slug: w.slug, t: speaker.token)
  end

  # ---- Page SCÈNE (auth animateur, rendu HTML) ----

  test "stage_requires_credentials" do
    # done_when principal : "La page scène exige l'auth ou un lien
    # intervenant signé". Anonyme → redirect login.
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    get stage_webinar_path(slug: w.slug)
    assert_redirected_to sign_in_path
  end

  test "stage refuse un animateur qui n'est pas le host" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    sign_in_as(@other)
    get stage_webinar_path(slug: w.slug)
    assert_response :not_found
  end

  test "stage rend HTML avec container #livekit-room et data-slug" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    sign_in_as(@host)
    get stage_webinar_path(slug: w.slug)
    assert_response :success
    assert_match(/id="livekit-room"/, response.body)
    assert_match(/data-slug="#{w.slug}"/, response.body)
    # Pas de speaker-token sur la page scène (host uniquement).
    assert_no_match(/data-speaker-token=/, response.body)
  end

  # Salle animateur = salle participant :
  # la scène ne pose AUCUNE commande d'animation (état du direct, pilotage
  # d'enregistrement, file des mains levées, mise en avant, modération).
  # Restent l'état public (écran de sortie), la fin du direct pour cet
  # écran de sortie hors salle, et le lien vers la régie.
  test "stage : aucune commande d'animation, lien régie et écran de sortie seulement" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    sign_in_as(@host)
    with_stubbed_recording_stack do
      get stage_webinar_path(slug: w.slug)
    end
    assert_response :success
    assert_match(%r{data-state-url="/w/#{Regexp.escape(w.slug)}/state\.json"}, response.body)
    assert_match(%r{data-end-url="/webinars/#{Regexp.escape(w.slug)}/end"}, response.body,
      "l'écran de sortie de salle garde « Terminer le direct » pour l'animation")
    assert_match(%r{data-regie-url="/webinars/#{Regexp.escape(w.slug)}/regie"}, response.body)
    %w[data-state= data-go-live-url= data-resume-url= data-recording-start-url= data-host-hand-raises-url=
       data-spotlight-url= data-message-moderation-url=].each do |attribute|
      assert_no_match(/#{attribute}/, response.body, "#{attribute} n'a plus sa place dans la salle")
    end
  end

  # ---- data-attrs recording UNIQUEMENT sur stage ----

  test "stage expose data-recording-status-url (indicateur), sans URL de démarrage" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    sign_in_as(@host)
    with_stubbed_recording_stack do
      get stage_webinar_path(slug: w.slug)
    end
    assert_response :success
    assert_match(%r{data-recording-status-url="/webinars/#{Regexp.escape(w.slug)}/recordings/status\.json"},
                 response.body,
                 "stage doit exposer l'URL de poll status recording (indicateur de consentement)")
    assert_no_match(/data-recording-start-url=/, response.body, "le pilotage est dans la régie")
  end

  test "viewer NE reçoit PAS les data-attrs recording (host-only)" do
    w = Webinar.create!(
      title: "démo", starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub, visibility: "published"
    )
    w.update!(state: "live", started_at: 1.minute.ago)
    # Registration confirmée pour entrer dans la salle spectateur.
    registration = w.registrations.find_or_create_by!(email: "v@example.test") { |r| r.name = "V" }
    post confirm_registration_path(registration.token)

    get public_webinar_path(slug: w.slug)
    assert_response :success
    assert_no_match(/data-recording-status-url=/, response.body)
    assert_no_match(/data-recording-start-url=/,  response.body)
  end

  # La salle ne pilote plus (le pilotage est dans la régie) :
  # le lien
  # intervenant garde l'indicateur, avec `?t=<token>` propagé (re-validé
  # serveur à chaque appel).
  test "join reçoit l'URL de statut d'enregistrement avec le token propagé (?t=…), sans démarrage" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    speaker = w.speakers.create!(name: "Basile")
    with_stubbed_recording_stack do
      get join_webinar_path(slug: w.slug, t: speaker.token)
    end
    assert_response :success
    escaped_token = Regexp.escape(CGI.escape(speaker.token))
    assert_match(%r{data-recording-status-url="[^"]*/recordings/status\.json\?t=#{escaped_token}"},
                 response.body,
                 "join doit exposer data-recording-status-url avec ?t=<token>")
    assert_no_match(/data-recording-start-url=/, response.body)
  end

  # ---- Le lien vers la régie suit le rôle d'animation ----

  test "régie : stage et join d'un animateur connecté exposent data-regie-url" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @simple_host.oidc_sub)
    speaker = w.speakers.create!(name: "Marc")
    sign_in_as(@simple_host)
    with_stubbed_recording_stack do
      get stage_webinar_path(slug: w.slug)
      assert_match(%r{data-regie-url="/webinars/#{Regexp.escape(w.slug)}/regie"}, response.body)

      get join_webinar_path(slug: w.slug, t: speaker.token)
      assert_match(%r{data-regie-url="/webinars/#{Regexp.escape(w.slug)}/regie"}, response.body,
        "L'animateur anime par son lien /join : il a le lien vers la régie")
      assert_no_match(/data-spotlight-url=/, response.body)
    end
  end

  test "régie : ni l'intervenant sans session animateur ni le spectateur ne reçoivent data-regie-url" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub, visibility: "published")
    speaker = w.speakers.create!(name: "Basile")
    with_stubbed_recording_stack do
      get join_webinar_path(slug: w.slug, t: speaker.token)
    end
    assert_response :success
    assert_no_match(/data-regie-url=/, response.body)

    sign_in_as(@other)
    with_stubbed_recording_stack do
      get join_webinar_path(slug: w.slug, t: speaker.token)
    end
    assert_no_match(/data-regie-url=/, response.body, "un connecté sans rôle sur ce webinaire reste intervenant")

    w.update!(state: "live", started_at: 1.minute.ago)
    registration = w.registrations.find_or_create_by!(email: "v@example.test") { |r| r.name = "V" }
    post confirm_registration_path(registration.token)
    get public_webinar_path(slug: w.slug)
    assert_response :success
    assert_no_match(/data-regie-url=/, response.body)
  end

  # ---- Scène d'un direct terminé ----
  #
  # Un animateur rechargeait /stage après la fin, rejoignait la
  # salle et en était aussitôt déconnecté. Plus de salle à rejoindre : la
  # page dit que le direct est terminé et propose de le reprendre.

  def ended_webinar
    w = Webinar.create!(title: "Café IA #7", starts_at: 2.hours.ago, host_sub: @host.oidc_sub, visibility: "published")
    # Fin récente : encore dans la grâce des liens. La date historique du
    # webinaire reste sur les enregistrements (affichage de la durée).
    w.update!(state: "ended", started_at: 2.hours.ago, ended_at: 1.hour.ago)
    w
  end

  test "stage d'un direct terminé : aucune salle, enregistrements produits et reprise du direct" do
    w = ended_webinar
    Recording.create!(webinar: w, status: "done", path: "#{w.slug}/mix.mp4",
                      started_at: Time.zone.parse("2026-10-30T09:31:00"), ended_at: Time.zone.parse("2026-10-30T10:27:44"))
    Recording.create!(webinar: w, kind: "participant", status: "done", participant_identity: "speaker-10", source_track_ids: [])
    Recording.create!(webinar: w, kind: "participant", status: "starting", participant_identity: "speaker-9", source_track_ids: [ 1 ])
    sign_in_as(@host)

    with_stubbed_recording_stack { get stage_webinar_path(slug: w.slug) }

    assert_response :success
    assert_no_match(/id="livekit-room"/, response.body, "on ne rejoint pas la salle d'un direct terminé")
    assert_select "[data-testid='ended-stage'] h2", "Direct terminé"
    assert_select "[data-testid='ended-recordings'] li", /Vue d'ensemble, démarrée à 09:31 · 56 min 44 s · prête/
    assert_select "[data-testid='ended-participant-muxes']", /1 prêt, 1 en cours/
    assert_select "a[data-testid='ended-recordings-link'][href='#{webinar_recordings_path(w)}']"
    assert_select "[data-live-state-control][data-state='ended'][data-resume-url='#{resume_webinar_path(w)}']"
    assert_select "[data-live-state-control][data-state-url='/w/#{w.slug}/state.json']"
  end

  test "stage d'un direct terminé sans enregistrement : le dit" do
    w = ended_webinar
    sign_in_as(@host)
    with_stubbed_recording_stack { get stage_webinar_path(slug: w.slug) }
    assert_select "[data-testid='ended-no-recording']", "Aucun enregistrement produit."
  end

  test "co-animateur invité sur un direct terminé : reprise oui, enregistrements non" do
    w = ended_webinar
    w.webinar_hosts.create!(email: @simple_host.email, invited_by_sub: @host.oidc_sub)
    sign_in_as(@simple_host)
    with_stubbed_recording_stack { get stage_webinar_path(slug: w.slug) }

    assert_response :success
    assert_select "[data-testid='ended-recordings']", count: 0
    assert_select "[data-testid='ended-recordings-link']", count: 0
    assert_select "[data-live-state-control]"
  end

  test "lien intervenant après la grâce : 404 avant ensure_active" do
    w = Webinar.create!(title: "Café passé", starts_at: 5.days.ago, host_sub: @host.oidc_sub, visibility: "published")
    w.update!(state: "ended", started_at: 5.days.ago, ended_at: 4.days.ago)
    speaker = w.speakers.create!(name: "Basile")

    with_stubbed_recording_stack do
      assert_no_difference -> { w.recordings.count } do
        get join_webinar_path(slug: w.slug, t: speaker.token)
      end
    end
    assert_response :not_found
  end

  test "reprise du direct dans la grâce : le lien intervenant rentre et ensure_active tourne" do
    w = Webinar.create!(title: "Reprise", starts_at: 3.hours.ago, host_sub: @host.oidc_sub, visibility: "published")
    w.update!(state: "ended", started_at: 2.hours.ago, ended_at: 30.minutes.ago)
    speaker = w.speakers.create!(name: "Basile")
    leftover = Recording.create!(webinar: w, status: "recording", egress_id: "EG_relance", started_at: 1.minute.ago)

    with_stubbed_recording_stack do
      get join_webinar_path(slug: w.slug, t: speaker.token)
      assert_response :success
      assert_select "[data-testid='ended-stage']"
      assert_equal "done", leftover.reload.status, "ensure_active réconcilie pendant la grâce"

      w.resume!
      assert_difference -> { w.recordings.active.count }, 1 do
        get join_webinar_path(slug: w.slug, t: speaker.token)
      end
    end
    assert_match(/id="livekit-room"/, response.body)
  end

  test "un direct repris après la grâce rouvre le lien intervenant" do
    w = Webinar.create!(title: "Reprise tardive", starts_at: 5.days.ago, host_sub: @host.oidc_sub, visibility: "published")
    w.update!(state: "ended", started_at: 5.days.ago, ended_at: 4.days.ago)
    speaker = w.speakers.create!(name: "Basile")

    get join_webinar_path(slug: w.slug, t: speaker.token)
    assert_response :not_found

    w.resume!
    with_stubbed_recording_stack { get join_webinar_path(slug: w.slug, t: speaker.token) }
    assert_response :success
    assert_match(/id="livekit-room"/, response.body)
  end

  test "lien intervenant d'un direct terminé : page de fin, sans reprise ni enregistrements" do
    w = ended_webinar
    speaker = w.speakers.create!(name: "Basile")
    with_stubbed_recording_stack { get join_webinar_path(slug: w.slug, t: speaker.token) }

    assert_response :success
    assert_no_match(/id="livekit-room"/, response.body)
    assert_select "[data-testid='ended-stage']", /Merci pour votre participation/
    assert_select "[data-live-state-control]", count: 0
  end

  test "la page de fin réconcilie : un enregistrement relancé avant la fin est arrêté" do
    w = ended_webinar
    leftover = Recording.create!(webinar: w, status: "recording", egress_id: "EG_relance", started_at: 1.minute.ago)
    sign_in_as(@host)
    with_stubbed_recording_stack { get stage_webinar_path(slug: w.slug) }
    assert_equal "done", leftover.reload.status
  end

  # ---- Auto-start sur stage ----

  test "stage auto-start : crée un Recording actif si aucun n'existe (idempotent)" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    sign_in_as(@host)

    with_stubbed_recording_stack do
      assert_difference -> { w.recordings.active.count }, 1 do
        get stage_webinar_path(slug: w.slug)
      end

      # Second visit → aucun doublon (invariant idempotence).
      assert_no_difference -> { w.recordings.count } do
        get stage_webinar_path(slug: w.slug)
      end
    end

    active = w.recordings.active.first
    assert_not_nil active, "un Recording actif doit exister après visite stage"
    assert active.recording? || active.starting?, "actif attendu ; vu :#{active.status}"
  end

  test "stage auto-start : réutilise l'actif existant sans doublon" do
    w = Webinar.create!(title: "déjà rec", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    Recording.create!(webinar: w, status: "recording", egress_id: "EG_manual")
    sign_in_as(@host)

    with_stubbed_recording_stack do
      assert_no_difference -> { w.recordings.count } do
        get stage_webinar_path(slug: w.slug)
      end
    end
    assert_response :success
  end

  # Auto-start sur /join, même
  # geste que sur /stage. L'animateur anime en pratique via /join?t=… (identité
  # host-<speaker> en prod). Sans auto-start sur /join,
  # la fix précédente ne couvrait pas la route réelle des animateurs.
  test "join auto-start : crée un Recording actif si aucun n'existe (idempotent)" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    speaker = w.speakers.create!(name: "Basile")
    valid_token = speaker.token
    with_stubbed_recording_stack do
      assert_difference -> { w.recordings.active.count }, 1 do
        get join_webinar_path(slug: w.slug, t: valid_token)
      end
      # Second call = idempotent (reconcile no-op sur un actif valide,
      # ensure_active retourne l'existant).
      assert_no_difference -> { w.recordings.count } do
        get join_webinar_path(slug: w.slug, t: valid_token)
      end
    end
  end

  test "join auto-start : PAS déclenché sur token invalide (404 avant ensure_active)" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    with_stubbed_recording_stack do
      assert_no_difference -> { w.recordings.count } do
        get join_webinar_path(slug: w.slug, t: "not-a-token")
      end
    end
    assert_response :not_found
  end

  test "stage auto-start : échec egress → Recording failed, PAGE STAGE REND (invariant)" do
    w = Webinar.create!(title: "egress ko", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    sign_in_as(@host)

    failing = Object.new
    failing.define_singleton_method(:start_room_composite) do |**|
      raise EgressClient::RemoteError, "egress injoignable (http://livekit:7880) : refused"
    end
    room_ok = Object.new
    def room_ok.create_room(name:); { name: name }; end

    with_stubbed_recording_stack(egress: failing, room: room_ok) do
      get stage_webinar_path(slug: w.slug)
    end

    # Invariant miroir de WebinarStatesController#go_live : la page rend
    # QUAND MÊME. La UI voit l'échec via /recordings/status.json.
    assert_response :success
    failed = w.recordings.order(:id).last
    assert_equal "failed", failed.status
    assert_match(/refused/, failed.error_message)
  end

  # ---- Page INTERVENANT (signature Rails validée AU GET) ----

  # Cas réel : un aperçu WhatsApp (`User-Agent:
  # WhatsApp/2`, `Accept: application/json`) sur /w/:slug/join provoquait
  # un 500 ActionView::MissingTemplate puis ErrorsController rendait 500.
  # Les pages salle sont HTML seulement — un format inattendu reçoit 406,
  # jamais 500.
  test "join demandé en JSON → 406, jamais 500" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    speaker = w.speakers.create!(name: "Basile")
    get join_webinar_path(slug: w.slug, t: speaker.token),
        headers: { "Accept" => "application/json" }
    assert_response :not_acceptable
  end

  test "viewer demandé en JSON → 406, jamais 500" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    get public_webinar_path(slug: w.slug),
        headers: { "Accept" => "application/json" }
    assert_response :not_acceptable
  end

  test "stage demandé en JSON → 406, jamais 500" do
    sign_in_as(@host)
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    get stage_webinar_path(slug: w.slug),
        headers: { "Accept" => "application/json" }
    assert_response :not_acceptable
  end

  test "show demandé en JSON → 406, jamais 500" do
    sign_in_as(@host)
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    get webinar_path(w),
        headers: { "Accept" => "application/json" }
    assert_response :not_acceptable
  end

  test "join sans token = 404" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    get join_webinar_path(slug: w.slug)
    assert_response :not_found
  end

  test "join token altéré = 404 (jamais 500 ni faux 200)" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    speaker = w.speakers.create!(name: "Basile")
    tampered = speaker.token[0..-2] + (speaker.token[-1] == "a" ? "b" : "a")
    get join_webinar_path(slug: w.slug, t: tampered)
    assert_response :not_found
  end

  test "join token valide → HTML avec data-speaker-token" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    speaker = w.speakers.create!(name: "Basile")
    get join_webinar_path(slug: w.slug, t: speaker.token)
    assert_response :success
    assert_match(/id="livekit-room"/, response.body)
    assert_match(/data-slug="#{w.slug}"/, response.body)
    assert_match(/data-speaker-token="#{Regexp.escape(speaker.token)}"/, response.body)
  end

  # Côté serveur :
  # les data-attrs go_live/end/resume ne DOIVENT PAS fuiter côté speaker. Un
  # attribut forgé ne donne rien (endpoints réservés), mais on garde le
  # signal côté rendu par cohérence.
  # L'état public du direct (state.json), lui, sert l'écran de sortie de
  # salle de tous les rôles.
  test "join (speaker) NE reçoit PAS data-go-live-url / data-end-url / data-resume-url" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    speaker = w.speakers.create!(name: "Basile")
    get join_webinar_path(slug: w.slug, t: speaker.token)
    assert_response :success
    assert_match(%r{data-state-url="/w/#{w.slug}/state\.json"}, response.body)
    assert_no_match(/data-go-live-url=/, response.body)
    assert_no_match(/data-end-url=/,     response.body)
    assert_no_match(/data-resume-url=/,  response.body)
    assert_no_match(/data-state=/,       response.body)
  end

  # ---- Page SPECTATEUR (trois rendus : pre_live / room / ended) ----
  #
  # done_when 1 (public_page_before_live) : hors live → :pre_live sous layout
  #   :application, aucun bundle LiveKit monté, compte à rebours branché.
  # done_when 2 (public_page_live_and_ended) : state=live → :room (layout :room),
  #   state=ended → :pre_live avec libellé « direct terminé », sans countdown.
  # Visibility=draft : 404 anonyme, 200 host propriétaire (prévisualisation).

  test "public_page_before_live rend pre_live sans bundle LiveKit et compte à rebours branché" do
    w = Webinar.create!(
      title: "Café automne",
      description: "Deux heures de démonstration.",
      starts_at: 2.hours.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published",
      kind: "cafe_ia"
    )
    get public_webinar_path(slug: w.slug)
    assert_response :success
    body = response.body
    assert_match(/Café automne/, body)
    assert_match(/Deux heures de démonstration\./, body)
    assert_no_match(/id="livekit-room"/, body, "aucun conteneur salle sur pre_live")
    assert_no_match(/data-slug=/, body, "aucun data-slug LiveKit sur pre_live")
    assert_match(/data-countdown\b/, body, "conteneur countdown attendu")
    assert_match(/data-starts-at="#{Regexp.escape(w.starts_at.iso8601)}"/, body)
    assert_match(%r{data-state-url="/w/#{w.slug}/state\.json"}, body)
    assert_match(/data-role="pre-live"/, body)
  end

  test "public_page_live_and_ended : live → salle, ended → pre_live sans countdown" do
    w = Webinar.create!(
      title: "démo live",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published"
    )
    # state=live → salle spectateur (bundle LiveKit monté).
    w.update!(state: "live", started_at: Time.current)
    registration = w.registrations.create!(email: "viewer@example.test", name: "Alice")
    post confirm_registration_path(registration.token)
    get public_webinar_path(slug: w.slug)
    assert_response :success
    assert_match(/id="livekit-room"/, response.body)
    assert_match(/data-slug="#{w.slug}"/, response.body)
    assert_no_match(/data-speaker-token=/, response.body)
    # Aucune donnée host côté spectateur (bouton d'état masqué par
    # construction dans room.jsx : goLiveUrl absent → StateButton null).
    # Seul l'état public, pour l'écran de sortie de salle.
    assert_match(%r{data-state-url="/w/#{w.slug}/state\.json"}, response.body)
    assert_no_match(/data-go-live-url=/, response.body)
    assert_no_match(/data-end-url=/,     response.body)
    assert_no_match(/data-resume-url=/,  response.body)
    assert_no_match(/data-state=/,       response.body)
    assert_no_match(/data-countdown\b/, response.body)

    # state=ended → pre_live « direct terminé », aucun countdown ni polling.
    w.update!(state: "ended", ended_at: Time.current)
    get public_webinar_path(slug: w.slug)
    assert_response :success
    assert_no_match(/id="livekit-room"/, response.body)
    assert_no_match(/data-countdown\b/, response.body)
    assert_match(/Ce café est terminé/, response.body)
    assert_match(/data-role="pre-live-ended"/, response.body)
  end

  # Consentement spectateur. La
  # vue viewer dans la salle live pose le data-attr pointant sur
  # l'endpoint public read-only ; room.jsx monte RecordingIndicator
  # dès que ce data-attr est présent.
  test "public_page_live : viewer confirmé reçoit data-recording-viewer-status-url" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now,
                        host_sub: @host.oidc_sub, visibility: "published")
    w.update!(state: "live", started_at: Time.current)
    registration = w.registrations.create!(email: "viewer@example.test", name: "Alice")
    post confirm_registration_path(registration.token)
    get public_webinar_path(slug: w.slug)
    assert_response :success
    assert_match(%r{data-recording-viewer-status-url="/w/#{w.slug}/recordings/status\.json"}, response.body)
    # Pas de start_url / status_url host-only côté spectateur.
    assert_no_match(/data-recording-status-url=/, response.body)
    assert_no_match(/data-recording-start-url=/,  response.body)
  end

  test "public_page_before_live 404 sur slug inconnu" do
    get public_webinar_path(slug: "nope")
    assert_response :not_found
  end

  test "public_page_before_live cache un webinaire draft à l'anonyme (404)" do
    w = Webinar.create!(
      title: "brouillon",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "draft"
    )
    get public_webinar_path(slug: w.slug)
    assert_response :not_found
  end

  test "public_page_before_live expose un webinaire draft à son animateur (200)" do
    w = Webinar.create!(
      title: "brouillon",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "draft"
    )
    sign_in_as(@host)
    get public_webinar_path(slug: w.slug)
    assert_response :success
    assert_match(/brouillon/, response.body)
    assert_match(/data-countdown\b/, response.body)
  end

  test "public_page_before_live 404 pour un non-admin non propriétaire d'un draft" do
    # Les animateurs du projet (admin) accèdent au
    # draft comme le propriétaire — la défense énumération ne porte que
    # sur les non-animateurs.
    w = Webinar.create!(
      title: "brouillon eve",
      starts_at: 1.day.from_now,
      host_sub: @other.oidc_sub,
      visibility: "draft"
    )
    sign_in_as(@simple_host)
    get public_webinar_path(slug: w.slug)
    assert_response :not_found
  end

  # ---- Garde navigateur :modern — pages animateur SEULEMENT ----
  #
  # Un spectateur au navigateur figé (poste d'entreprise, Chrome < 120)
  # DOIT entrer dans la salle : LiveKit v2 tourne bien en dessous du
  # plancher :modern. Les pages animateur gardent le 406 par défaut Rails.

  OLD_CHROME_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " \
                  "(KHTML, like Gecko) Chrome/100.0.4896.127 Safari/537.36".freeze

  test "viewer public servi à un navigateur ancien (pas de 406)" do
    # L'invariant : LiveKit tourne sur des Chromes < 120 ; la garde :modern
    # ne doit JAMAIS bloquer la page spectateur (peu importe le rendu :
    # salle en live, page avant-direct sinon).
    w = Webinar.create!(
      title: "démo",
      starts_at: 1.day.from_now,
      host_sub: @host.oidc_sub,
      visibility: "published"
    )
    w.update!(state: "live", started_at: Time.current)
    registration = w.registrations.create!(email: "viewer@example.test", name: "Alice")
    post confirm_registration_path(registration.token)
    get public_webinar_path(slug: w.slug), headers: { "User-Agent" => OLD_CHROME_UA }
    assert_response :success
    assert_match(/id="livekit-room"/, response.body)
  end

  test "join intervenant servi à un navigateur ancien (pas de 406)" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    speaker = w.speakers.create!(name: "Basile")
    get join_webinar_path(slug: w.slug, t: speaker.token), headers: { "User-Agent" => OLD_CHROME_UA }
    assert_response :success
  end

  test "table animateur refuse un navigateur ancien (406)" do
    sign_in_as(@host)
    get webinars_path, headers: { "User-Agent" => OLD_CHROME_UA }
    assert_response :not_acceptable
  end

  test "scène animateur refuse un navigateur ancien (406)" do
    w = Webinar.create!(title: "démo", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    sign_in_as(@host)
    get stage_webinar_path(slug: w.slug), headers: { "User-Agent" => OLD_CHROME_UA }
    assert_response :not_acceptable
  end

  test "live anonymous visitors see registration without a countdown reload loop" do
    previous_privacy_url = ENV["REGISTRATION_PRIVACY_URL"]
    ENV["REGISTRATION_PRIVACY_URL"] = "https://example.test/privacy"
    webinar = Webinar.create!(title: "En direct", starts_at: 1.hour.ago,
      host_sub: @host.oidc_sub, state: "live", visibility: "published")
    get public_webinar_path(webinar.slug)
    assert_response :success
    assert_select "body.chrome-canvas"
    assert_select "#livekit-room", count: 0
    assert_select "[data-countdown]", count: 0
    assert_select "form[action=?]", public_webinar_registrations_path(webinar.slug)
    assert_includes response.body, "Le café a commencé"
  ensure
    ENV["REGISTRATION_PRIVACY_URL"] = previous_privacy_url
  end

  test "join_named_speaker prepopulates escaped name and refuses revoked invitations" do
    webinar = Webinar.create!(title: "Names", starts_at: 1.day.from_now, host_sub: @host.oidc_sub)
    speaker = webinar.speakers.create!(name: %q{Basile "<script>alert(1)</script>})
    get join_webinar_path(slug: webinar.slug, t: speaker.token)
    assert_response :success
    assert_select "#livekit-room[data-name=?]", speaker.name
    assert_select "#livekit-room script", count: 0
    speaker.revoke!
    get join_webinar_path(slug: webinar.slug, t: speaker.token)
    assert_response :not_found
    # Un ancien signed_id (purpose:speaker) ne résout plus (chemin
    # legacy retiré).
    legacy_token = webinar.signed_id(purpose: :speaker)
    get join_webinar_path(slug: webinar.slug, t: legacy_token)
    assert_response :not_found
  end

  private

  # Stubs egress + room autour d'un bloc.
  # Le stage auto-start (WebinarsController#stage) appelle RecordingSession.
  # Sans stub, le vrai EgressClient serait construit (MissingCredentials en
  # test), la trajectoire fonctionnerait quand même (fail-loud dans le
  # Recording) mais on veut des tests DÉTERMINISTES et rapides.
  def with_stubbed_recording_stack(egress: default_stub_egress, room: default_stub_room)
    prev_egress = Rails.configuration.x.egress_client_factory
    prev_room   = Rails.configuration.x.room_service_client_factory
    Rails.configuration.x.egress_client_factory       = -> { egress }
    Rails.configuration.x.room_service_client_factory = -> { room }
    yield
  ensure
    Rails.configuration.x.egress_client_factory       = prev_egress
    Rails.configuration.x.room_service_client_factory = prev_room
  end

  def default_stub_egress
    stub = Object.new
    def stub.start_room_composite(room_name:, filepath:)
      { egress_id: "EG_auto_#{SecureRandom.hex(4)}", status: :starting, raw: nil }
    end
    def stub.stop(egress_id:)
      { egress_id: egress_id, status: :ending, raw: nil }
    end
    # ensure_active passe par
    # reconcile qui appelle list_egress. Par défaut, aucun Recording
    # existant n'est en course → aucun appel. On garde la méthode pour
    # les cas où un Recording actif préexiste (test « réutilise l'actif »).
    def stub.list_egress(egress_id:)
      { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
    stub
  end

  def default_stub_room
    stub = Object.new
    def stub.create_room(name:); { name: name }; end
    stub
  end

  # Passe par le vrai flow OIDC en test_mode (idiomatique Rails ; évite
  # tout monkey-patch d'ApplicationController). Résultat : session[:user_id]
  # posé exactement comme en prod.
  # Helper OIDC enrichi : transmet `email_verified: true`
  # par défaut — défense broken-authentication. Un test qui veut exercer
  # le chemin « email NON vérifié » passe `email_verified: false`.
  def sign_in_as(user, email_verified: true, groups: nil)
    OmniAuth.config.test_mode = true
    raw_info = { email_verified: email_verified }
    raw_info[:groups] = groups if groups
    OmniAuth.config.mock_auth[:pocket_id] = OmniAuth::AuthHash.new(
      provider: "pocket_id",
      uid: user.oidc_sub,
      info: { email: user.email, email_verified: email_verified },
      extra: { raw_info: raw_info }
    )
    Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:pocket_id]
    get "/auth/pocket_id/callback"
    Rails.application.env_config.delete("omniauth.auth")
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end
end
