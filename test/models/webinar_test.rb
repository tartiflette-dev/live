require "test_helper"

class WebinarTest < ActiveSupport::TestCase
  # Invariants du modèle Webinar.

  def valid_attrs(**overrides)
    {
      title:     "Webinaire Alpha",
      starts_at: 1.day.from_now,
      host_sub:  "sub-marc"
    }.merge(overrides)
  end

  test "requires title, starts_at, host_sub" do
    w = Webinar.new
    assert_not w.valid?
    # Type d'erreur, pas le libellé : la locale par défaut est fr (charte).
    assert w.errors.of_kind?(:title,     :blank)
    assert w.errors.of_kind?(:starts_at, :blank)
    assert w.errors.of_kind?(:host_sub,  :blank)
  end

  test "auto-génère slug et room_name depuis le titre" do
    w = Webinar.create!(valid_attrs(title: "Ma Démo Live !"))
    assert_equal "ma-demo-live", w.slug
    assert_equal "ma-demo-live", w.room_name
  end

  # done_when spec : "Slug unique, collision gérée".
  test "collision de slug suffixée -2 -3" do
    Webinar.create!(valid_attrs(title: "Rentrée"))
    w2 = Webinar.create!(valid_attrs(title: "Rentrée"))
    w3 = Webinar.create!(valid_attrs(title: "Rentrée"))
    assert_equal "rentree",   Webinar.first.slug
    assert_equal "rentree-2", w2.slug
    assert_equal "rentree-3", w3.slug
  end

  test "fallback hex si titre sans caractères parseables" do
    w = Webinar.create!(valid_attrs(title: "!!!"))
    assert_match(/\A[a-f0-9]{8}\z/, w.slug)
  end

  # Défense en profondeur : les noms de sous-dossiers
  # réservés sous RECORDINGS_ROOT/ (ici `_participants` et `participants`,
  # réservé pour l'arborescence mux) ne peuvent pas être slugs. Le regex
  # exclut déjà `_participants` (préfixe `_`) ; `participants` est bloqué
  # par la liste nommée pour cadenasser le sens métier et résister à un
  # loosening futur du regex.
  test "slug `participants` est refusé (réservé pour l'arborescence mux)" do
    w = Webinar.new(valid_attrs(title: "x", slug: "participants"))
    assert_not w.valid?
    assert w.errors.of_kind?(:slug, :reserved)
  end

  test "un titre « Participants » reçoit un slug généré hors liste réservée" do
    w = Webinar.create!(title: "Participants", starts_at: 1.day.from_now, host_sub: "host-reserved")
    assert_equal "participants-2", w.slug
  end

  test "slug `_participants` est refusé (regex puis liste réservée)" do
    w = Webinar.new(valid_attrs(title: "x", slug: "_participants"))
    assert_not w.valid?
    # Soit :invalid (regex), soit :reserved (liste nommée) — les deux
    # verrouillent la collision, l'ordre d'évaluation Rails importe peu.
    assert w.errors.of_kind?(:slug, :invalid) || w.errors.of_kind?(:slug, :reserved)
  end

  # done_when spec : state machine draft→live→ended.
  test "state par défaut draft, transitions live/ended valides" do
    w = Webinar.create!(valid_attrs)
    assert_equal "draft", w.state

    w.state = "live"
    assert w.valid?
    w.state = "ended"
    assert w.valid?
  end

  test "state inconnu refusé (enum validate:true)" do
    w = Webinar.create!(valid_attrs)
    # Rails 8 enum(validate: true) : l'assignation NE raise plus (comme
    # Rails 7 le faisait), c'est la validation qui rejette. Contrat testé
    # ici de bout en bout.
    w.state = "wat"
    assert_not w.valid?
    assert w.errors.of_kind?(:state, :inclusion)
  end

  # Résolution via Speaker nominatif actif seulement (le chemin legacy
  # signed_id a été supprimé).
  test "find_for_speaker_resout_un_speaker_nominatif_actif" do
    w = Webinar.create!(valid_attrs)
    speaker = w.speakers.create!(name: "Basile")
    assert_equal [ w, speaker ], Webinar.find_for_speaker(slug: w.slug, token: speaker.token)
  end

  test "find_for_speaker_refuse_un_token_altere" do
    w = Webinar.create!(valid_attrs)
    speaker = w.speakers.create!(name: "Basile")
    tampered = speaker.token[0..-2] + (speaker.token[-1] == "a" ? "b" : "a")
    assert_nil Webinar.find_for_speaker(slug: w.slug, token: tampered)
  end

  test "find_for_speaker_refuse_un_token_pour_un_autre_slug" do
    a = Webinar.create!(valid_attrs(title: "A"))
    b = Webinar.create!(valid_attrs(title: "B"))
    speaker_a = a.speakers.create!(name: "Basile")
    assert_nil Webinar.find_for_speaker(slug: b.slug, token: speaker_a.token)
  end

  test "find_for_speaker_refuse_un_speaker_revoked" do
    w = Webinar.create!(valid_attrs)
    speaker = w.speakers.create!(name: "Basile")
    speaker.revoke!
    assert_nil Webinar.find_for_speaker(slug: w.slug, token: speaker.token)
  end

  # Chemin legacy signed_id (SPEAKER_PURPOSE) supprimé — tout token
  # ancien, même signé correctement, est désormais rejeté. 404 propre
  # côté caller (WebinarsController#join rend not_found).
  test "find_for_speaker_rejette_les_anciens_tokens_signed_id_legacy" do
    w = Webinar.create!(valid_attrs)
    # On reconstitue un signed_id purpose:speaker comme l'ancienne
    # implémentation en émettait — DOIT être rejeté désormais.
    legacy_token = w.signed_id(purpose: :speaker)
    assert_nil Webinar.find_for_speaker(slug: w.slug, token: legacy_token)
  end

  test "la grâce des liens couvre au moins la fin automatique d'une salle vide" do
    assert_operator Webinar::LINK_ACCESS_GRACE, :>=, AutoEndLiveJob::AUTO_END_DELAY
    assert_equal "1 jour", Webinar.link_access_grace_label
  end

  test "find_for_speaker reste ouvert pendant la grâce et se ferme après" do
    w = Webinar.create!(valid_attrs(starts_at: 3.hours.ago))
    speaker = w.speakers.create!(name: "Basile")
    w.update!(state: "live", started_at: 2.hours.ago)
    w.end!

    assert_equal [ w, speaker ], Webinar.find_for_speaker(slug: w.slug, token: speaker.token)
    deadline = w.ended_at + Webinar::LINK_ACCESS_GRACE
    assert w.link_access_open?(deadline - 1.second)
    assert_not w.link_access_open?(deadline)
    travel_to(deadline + 1.second) do
      assert_nil Webinar.find_for_speaker(slug: w.slug, token: speaker.token)
    end
    assert_equal w, Webinar.find_by_active_share_token(w.generate_share_token!),
                 "le jeton existe encore : c'est la résolution qui le ferme, pas une révocation"
  end

  test "find_for_speaker ne coupe jamais un direct en cours" do
    w = Webinar.create!(valid_attrs(starts_at: 10.days.ago, state: "live", started_at: 10.days.ago))
    speaker = w.speakers.create!(name: "Basile")
    assert w.link_access_open?
    assert_nil w.link_access_deadline
    assert_equal [ w, speaker ], Webinar.find_for_speaker(slug: w.slug, token: speaker.token)
  end

  test "un brouillon jamais clos expire à la fin prévue plus la grâce, pas sans starts_at" do
    late = Webinar.create!(valid_attrs(title: "jamais clos", starts_at: 3.days.ago))
    speaker = late.speakers.create!(name: "Basile")
    assert_equal late.planned_ends_at + Webinar::LINK_ACCESS_GRACE, late.link_access_deadline
    assert_nil Webinar.find_for_speaker(slug: late.slug, token: speaker.token)

    soon = Webinar.create!(valid_attrs(title: "bientôt", starts_at: 1.hour.ago))
    soon_speaker = soon.speakers.create!(name: "Basile")
    assert soon.link_access_open?
    assert_equal [ soon, soon_speaker ], Webinar.find_for_speaker(slug: soon.slug, token: soon_speaker.token)

    undated = Webinar.new(state: "draft", starts_at: nil, kind: "cafe_ia")
    assert_nil undated.link_access_deadline
    assert undated.link_access_open?
  end

  test "find_for_speaker(nil/blank) = nil sans exception" do
    w = Webinar.create!(valid_attrs)
    assert_nil Webinar.find_for_speaker(slug: w.slug, token: nil)
    assert_nil Webinar.find_for_speaker(slug: w.slug, token: "")
    assert_nil Webinar.find_for_speaker(slug: nil, token: "anything")
  end

  # ---- Transitions #go_live! / #end! ----

  test "go_live! passe draft → live et pose started_at" do
    w = Webinar.create!(valid_attrs)
    freeze = Time.zone.parse("2026-09-21T10:00:00")
    travel_to(freeze) { w.go_live! }
    w.reload
    assert_equal "live", w.state
    assert_equal freeze.utc, w.started_at.utc
  end

  test "go_live! refuse si déjà live (Webinar::TransitionError)" do
    w = Webinar.create!(valid_attrs)
    w.go_live!
    assert_raises(Webinar::TransitionError) { w.go_live! }
    assert_equal "live", w.reload.state
  end

  test "go_live! refuse si ended" do
    w = Webinar.create!(valid_attrs)
    w.go_live!
    w.end!
    assert_raises(Webinar::TransitionError) { w.go_live! }
    assert_equal "ended", w.reload.state
  end

  test "end! passe live → ended et pose ended_at" do
    w = Webinar.create!(valid_attrs)
    w.go_live!
    freeze = Time.zone.parse("2026-09-21T11:00:00")
    travel_to(freeze) { w.end! }
    w.reload
    assert_equal "ended", w.state
    assert_equal freeze.utc, w.ended_at.utc
  end

  test "end! refuse si draft (Webinar::TransitionError)" do
    w = Webinar.create!(valid_attrs)
    assert_raises(Webinar::TransitionError) { w.end! }
    assert_equal "draft", w.reload.state
  end

  test "end! refuse si déjà ended" do
    w = Webinar.create!(valid_attrs)
    w.go_live!
    w.end!
    assert_raises(Webinar::TransitionError) { w.end! }
  end

  # ---- Reprise et vacance de la salle ----

  test "resume! repasse ended → live, efface ended_at et garde le premier démarrage" do
    w = Webinar.create!(valid_attrs)
    started = Time.zone.parse("2026-10-30T09:31:00")
    travel_to(started) { w.go_live! }
    travel_to(started + 1.hour) { w.end! }

    w.resume!

    w.reload
    assert_equal "live", w.state
    assert_nil w.ended_at
    assert_equal started, w.started_at
  end

  test "resume! refuse un direct en brouillon ou déjà en cours" do
    w = Webinar.create!(valid_attrs)
    assert_raises(Webinar::TransitionError) { w.resume! }
    w.go_live!
    assert_raises(Webinar::TransitionError) { w.resume! }
    assert_equal "live", w.reload.state
  end

  test "mark_room_empty! ne vaut que pour un direct en cours et garde la première vacance" do
    w = Webinar.create!(valid_attrs)
    refute w.mark_room_empty!, "brouillon : pas de vacance relevée"

    w.go_live!
    first = Time.zone.parse("2026-10-30T10:28:03")
    assert w.mark_room_empty!(first)
    refute w.mark_room_empty!(first + 5.minutes), "un webhook rejoué ne repousse pas l'échéance"
    assert_equal first, w.reload.room_empty_since
  end

  test "un participant revenu, la fin ou la reprise du direct effacent la vacance" do
    w = Webinar.create!(valid_attrs)
    w.go_live!
    w.mark_room_empty!
    w.mark_room_occupied!
    assert_nil w.reload.room_empty_since

    w.mark_room_empty!
    w.end!
    assert_nil w.reload.room_empty_since

    w.update_columns(room_empty_since: 1.hour.ago)
    w.resume!
    assert_nil w.reload.room_empty_since
  end

  test "scope hosted_by isole par host_sub" do
    Webinar.create!(valid_attrs(host_sub: "sub-marc"))
    Webinar.create!(valid_attrs(title: "autre", host_sub: "sub-eve"))
    assert_equal 1, Webinar.hosted_by("sub-marc").count
    assert_equal 1, Webinar.hosted_by("sub-eve").count
  end

  test "webinar_catalogue_fields" do
    cols = Webinar.columns_hash

    assert_equal :text, cols["description"].type
    assert_equal :string, cols["visibility"].type
    assert_equal "draft", cols["visibility"].default
    assert_equal :string, cols["kind"].type
    assert_equal "cafe_ia", cols["kind"].default
    assert_equal :integer, cols["price_cents"].type
    assert_equal 0, cols["price_cents"].default.to_i
    assert_equal :integer, cols["pack_id"].type
    assert_nil cols["pack_id"].default
    assert_equal :json, cols["layout"].type
    assert_nil cols["layout"].default

    w = Webinar.create!(valid_attrs)
    assert w.valid?
    assert_equal "draft", w.visibility
    assert_equal "cafe_ia", w.kind
    assert_equal 0, w.price_cents
    assert_nil w.pack_id
    assert_nil w.layout
    assert_nil w.description
  end

  test "webinar_catalogue_scopes" do
    w = Webinar.new(valid_attrs)
    w.visibility = "secret"
    assert_not w.valid?
    assert w.errors.of_kind?(:visibility, :inclusion)

    w = Webinar.new(valid_attrs)
    w.kind = "workshop"
    assert_not w.valid?
    assert w.errors.of_kind?(:kind, :inclusion)

    w = Webinar.new(valid_attrs(price_cents: -1))
    assert_not w.valid?
    assert w.errors.of_kind?(:price_cents, :greater_than_or_equal_to)

    past  = Webinar.create!(valid_attrs(title: "passé", starts_at: 1.day.ago, visibility: "published"))
    draft = Webinar.create!(valid_attrs(title: "brouillon", starts_at: 1.day.from_now, visibility: "draft"))
    later = Webinar.create!(valid_attrs(title: "plus tard", starts_at: 2.days.from_now, visibility: "published"))
    soon  = Webinar.create!(valid_attrs(title: "bientôt", starts_at: 1.hour.from_now, visibility: "published"))

    result = Webinar.published.upcoming
    assert_equal [ soon, later ], result.to_a
    assert_not_includes result, past
    assert_not_includes result, draft
  end

  # ---- Accueil : groupes en direct / en retard / à venir (cas réel : le
  # webinaire disparaissait de l'accueil à son heure). ----

  test "starting_late : draft dont l'heure est passée depuis moins de 3 h, du plus ancien au plus récent" do
    freeze_time do
      at_window_edge = Webinar.create!(valid_attrs(title: "bord", starts_at: 3.hours.ago))
      just_late      = Webinar.create!(valid_attrs(title: "juste en retard", starts_at: 1.minute.ago))
      Webinar.create!(valid_attrs(title: "trop vieux", starts_at: 3.hours.ago - 1.second))
      Webinar.create!(valid_attrs(title: "pile à l'heure", starts_at: Time.current))
      Webinar.create!(valid_attrs(title: "lancé", starts_at: 10.minutes.ago, state: "live"))
      Webinar.create!(valid_attrs(title: "terminé", starts_at: 10.minutes.ago, state: "ended"))

      assert_equal [ at_window_edge, just_late ], Webinar.starting_late.to_a
    end
  end

  test "upcoming : un direct lancé en avance ou terminé n'est plus « à venir »" do
    freeze_time do
      on_time = Webinar.create!(valid_attrs(title: "pile à l'heure", starts_at: Time.current))
      later   = Webinar.create!(valid_attrs(title: "plus tard", starts_at: 1.day.from_now))
      Webinar.create!(valid_attrs(title: "lancé en avance", starts_at: 10.minutes.from_now, state: "live"))
      Webinar.create!(valid_attrs(title: "terminé en avance", starts_at: 10.minutes.from_now, state: "ended"))

      assert_equal [ on_time, later ], Webinar.upcoming.to_a
    end
  end

  test "starting_late et upcoming se partagent les draft autour du même instant `now`" do
    now     = 2.days.from_now
    late    = Webinar.create!(valid_attrs(title: "en retard à now", starts_at: now - 1.hour))
    on_time = Webinar.create!(valid_attrs(title: "pile à now", starts_at: now))

    assert_equal [ late ], Webinar.starting_late(now).to_a
    assert_equal [ on_time ], Webinar.upcoming(now).to_a
  end

  # ----------------------------------------------------------------
  # Lien d'invitation intervenant PARTAGÉ.
  # ----------------------------------------------------------------

  test "share_token_lifecycle generates rotates and disables" do
    w = Webinar.create!(valid_attrs)
    assert_nil w.share_token

    first = w.generate_share_token!
    assert_match(/\A[A-Za-z0-9_-]{20,}\z/, first)
    assert_equal first, w.reload.share_token

    second = w.generate_share_token!
    assert_not_equal first, second,
      "régénérer doit invalider l'ancien jeton"
    assert_nil Webinar.find_by_active_share_token(first)
    assert_equal w, Webinar.find_by_active_share_token(second)

    w.disable_share_token!
    assert_nil w.reload.share_token
    assert_nil Webinar.find_by_active_share_token(second)
  end

  # Régie : toute l'animation régénère, personne
  # n'y crée un lien absent.
  test "regenerate_share_token! remplace un lien actif et n'en crée jamais" do
    w = Webinar.create!(valid_attrs)
    assert_nil w.regenerate_share_token!
    assert_nil w.reload.share_token

    first = w.generate_share_token!
    second = w.regenerate_share_token!
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, second)
    assert_not_equal first, second
    assert_equal second, w.reload.share_token
    assert_nil Webinar.find_by_active_share_token(first)
  end

  test "share_token_fingerprint : empreinte du lien actif, jamais le jeton" do
    w = Webinar.create!(valid_attrs)
    assert_nil w.share_token_fingerprint

    token = w.generate_share_token!
    fingerprint = w.share_token_fingerprint
    assert_match(/\A\h{16}\z/, fingerprint)
    assert_not_includes token, fingerprint
    assert_equal fingerprint, w.share_token_fingerprint, "stable tant que le lien ne change pas"

    w.regenerate_share_token!
    assert_not_equal fingerprint, w.share_token_fingerprint
  end

  test "find_by_active_share_token rejects nil blank and unknown" do
    w = Webinar.create!(valid_attrs)
    w.generate_share_token!

    assert_nil Webinar.find_by_active_share_token(nil)
    assert_nil Webinar.find_by_active_share_token("")
    assert_nil Webinar.find_by_active_share_token("not-a-real-token")
    assert_nil Webinar.find_by_active_share_token(123)
    # Un jeton d'un AUTRE webinaire ne doit pas résoudre.
    other = Webinar.create!(valid_attrs(title: "autre"))
    other.generate_share_token!
    assert_equal other, Webinar.find_by_active_share_token(other.share_token)
    assert_equal w,     Webinar.find_by_active_share_token(w.share_token)
  end

  test "share_token is filtered from inspect" do
    w = Webinar.create!(valid_attrs)
    w.generate_share_token!
    assert_not_includes w.inspect, w.share_token
  end

  test "speaker_capacity_reached caps at SPEAKER_LIMIT" do
    w = Webinar.create!(valid_attrs)
    # Création en masse — on reste sous le plafond, puis on l'atteint.
    (Webinar::SPEAKER_LIMIT - 1).times { |i| w.speakers.create!(name: "N#{i}") }
    assert_not w.speaker_capacity_reached?
    w.speakers.create!(name: "last")
    assert w.speaker_capacity_reached?
    # Révoquer ne libère PAS la capacité (anti saturation table).
    w.speakers.first.revoke!
    assert w.reload.speaker_capacity_reached?
    # Régénérer remplace une ligne : ça n'en ajoute pas une au plafond.
    under = Webinar.create!(valid_attrs)
    (Webinar::SPEAKER_LIMIT - 1).times { |i| under.speakers.create!(name: "M#{i}") }
    under.speakers.first.replace!
    assert_not under.reload.speaker_capacity_reached?
    assert_equal Webinar::SPEAKER_LIMIT - 1, under.speakers.where(replaced_by_id: nil).count
  end

  # Rôle d'un user et capacités.
  #
  # L'ordre strict (owner > project_host > guest_host > nil) est posé
  # par Webinar#role_for. Les capacités d'un `guest_host` sont LIMITÉES
  # à l'animation — invariant central.

  test "role_for_nil_user_est_nil" do
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-owner")
    assert_nil w.role_for(nil)
  end

  test "role_for_proprietaire_renvoie_owner" do
    owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: owner.oidc_sub)
    assert_equal :owner, w.role_for(owner)
  end

  test "role_for_proprietaire_bat_project_host" do
    # Un propriétaire qui est aussi animateur du projet reste :owner
    # (traçabilité : la lecture d'un journal doit distinguer la
    # provenance du droit).
    owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner", admin: true)
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: owner.oidc_sub)
    assert_equal :owner, w.role_for(owner)
  end

  test "role_for_admin_project_host" do
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-someone-else")
    assert_equal :project_host, w.role_for(admin)
  end

  test "role_for_groupe_oidc_live_animateurs" do
    # Durcissement sécurité (fail-open-state-drift) : les groupes OIDC
    # ne comptent QUE dans la fenêtre de fraîcheur
    # (`oidc_groups_fetched_at`). On pose l'horodatage comme le ferait
    # un callback OIDC récent.
    user = User.create!(email: "u@example.net", oidc_sub: "sub-u",
                        oidc_groups: [ "autre", "live-animateurs" ],
                        oidc_groups_fetched_at: Time.current)
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-someone-else")
    assert_equal :project_host, w.role_for(user)
  end

  test "role_for_groupe_oidc_live_animateurs_perime_est_refuse" do
    # Même user, mais `oidc_groups_fetched_at` dépasse la fenêtre : le
    # droit « projet » tombe mécaniquement (défense fail-open-state-drift).
    user = User.create!(email: "u@example.net", oidc_sub: "sub-u",
                        oidc_groups: [ "live-animateurs" ],
                        oidc_groups_fetched_at: 13.hours.ago)
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-someone-else")
    assert_nil w.role_for(user)
  end

  test "role_for_env_fallback_project_host" do
    user = User.create!(email: "fallback@example.net", oidc_sub: "sub-f", email_verified: true, email_verified_for: "fallback@example.net")
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-someone-else")
    ClimateControl.modify(LIVE_PROJECT_HOSTS: "autre@example.net, fallback@example.net , vide@example.net") do
      assert_equal :project_host, w.role_for(user)
    end
  rescue NameError
    # ClimateControl absent — fallback stub direct.
    ENV["LIVE_PROJECT_HOSTS"] = "autre@example.net,fallback@example.net"
    assert_equal :project_host, w.role_for(user)
  ensure
    ENV.delete("LIVE_PROJECT_HOSTS")
  end

  test "role_for_guest_host_par_email_case_insensitive" do
    # Durcissement sécurité (broken-authentication) : exige
    # `email_verified` côté Pocket ID — sinon résolution :guest_host
    # refusée.
    user = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: true, email_verified_for: "jean@partenaire.example.org")
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-owner")
    w.webinar_hosts.create!(email: "JEAN@partenaire.example.org", invited_by_sub: "sub-owner")
    assert_equal :guest_host, w.role_for(user)
  end

  test "role_for_guest_host_refuse_sans_email_verified" do
    user = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: false)
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-owner")
    w.webinar_hosts.create!(email: user.email, invited_by_sub: "sub-owner")
    assert_nil w.role_for(user)
  end

  test "role_for_guest_host_colle_claimed_sub_a_la_premiere_resolution" do
    user = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: true, email_verified_for: "jean@partenaire.example.org")
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-owner")
    host = w.webinar_hosts.create!(email: user.email, invited_by_sub: "sub-owner")
    assert_nil host.claimed_sub

    assert_equal :guest_host, w.role_for(user)
    assert_equal user.oidc_sub, host.reload.claimed_sub
  end

  test "role_for_guest_host_refuse_un_autre_sub_apres_claim" do
    # Simule l'attaque : un `sub` A revendique une invitation par email ;
    # plus tard, un sub B (différent) se présente avec le même email
    # (compte Pocket ID réémis, email transféré, nouveau compte créé
    # sous le même email après suppression de A, etc.). L'app Rails doit
    # REFUSER le sub B (défense broken-authentication).
    first = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-first", email_verified: true, email_verified_for: "jean@partenaire.example.org")
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-owner")
    host = w.webinar_hosts.create!(email: first.email, invited_by_sub: "sub-owner")

    # Premier claim : sub-first colle sa marque.
    assert_equal :guest_host, w.role_for(first)
    assert_equal "sub-first", host.reload.claimed_sub

    # On construit un USER distinct en mémoire avec le MÊME email mais
    # un sub différent (contourner l'unicité DB — un modèle sans
    # persistance pour l'écriture suffit à exercer la logique du
    # Webinar).
    impostor = User.new(email: first.email, oidc_sub: "sub-impostor",
                        email_verified: true, email_verified_for: first.email)
    assert_nil w.role_for(impostor)
    # Et claimed_sub reste intouché.
    assert_equal "sub-first", host.reload.claimed_sub
  end

  test "role_for_user_sans_droits_est_nil" do
    user = User.create!(email: "inconnu@example.net", oidc_sub: "sub-inconnu")
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-owner")
    assert_nil w.role_for(user)
  end

  test "capacites_matrice_owner" do
    owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: owner.oidc_sub)
    assert w.can_animate?(owner)
    assert w.can_manage_speakers?(owner)
    assert w.can_manage_registrations?(owner)
    assert w.can_manage_recordings?(owner)
    assert w.can_manage_transcripts?(owner)
    assert w.can_manage_hosts?(owner)
  end

  test "capacites_matrice_project_host_identique_a_owner" do
    # admin: true est évalué à chaque appel — pas de cache ni de
    # dépendance à `oidc_groups_fetched_at` (c'est le fallback humain).
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-someone-else")
    assert w.can_animate?(admin)
    assert w.can_manage_speakers?(admin)
    assert w.can_manage_registrations?(admin)
    assert w.can_manage_recordings?(admin)
    assert w.can_manage_transcripts?(admin)
    assert w.can_manage_hosts?(admin)
  end

  test "capacites_matrice_guest_host_limite_animation" do
    guest = User.create!(email: "guest@example.net", oidc_sub: "sub-guest", email_verified: true, email_verified_for: "guest@example.net")
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-owner")
    w.webinar_hosts.create!(email: guest.email, invited_by_sub: "sub-owner")
    assert w.can_animate?(guest)
    assert_not w.can_manage_speakers?(guest)
    assert_not w.can_manage_registrations?(guest)
    assert_not w.can_manage_recordings?(guest)
    assert_not w.can_manage_transcripts?(guest)
    assert_not w.can_manage_hosts?(guest)
  end

  test "capacites_matrice_user_sans_role_tout_refuse" do
    user = User.create!(email: "inconnu@example.net", oidc_sub: "sub-inconnu")
    w = Webinar.create!(title: "x", starts_at: 1.day.from_now, host_sub: "sub-owner")
    assert_not w.can_animate?(user)
    assert_not w.can_manage_speakers?(user)
    assert_not w.can_manage_registrations?(user)
    assert_not w.can_manage_recordings?(user)
    assert_not w.can_manage_transcripts?(user)
    assert_not w.can_manage_hosts?(user)
  end

  test "where_animated_by_scope_owner_et_coanime" do
    # Note : le scope `where_animated_by` ne consulte PAS email_verified
    # ni claimed_sub ; c'est `role_for` qui applique ces gates. Un
    # invité listé mais pas encore verifié verra le webinaire dans sa
    # liste, mais recevra un rôle nil à l'ouverture — invariant acceptable
    # (le lien existe, l'accès est gardé par la résolution de rôle).
    user = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: true, email_verified_for: "jean@partenaire.example.org")
    mien = Webinar.create!(title: "mien", starts_at: 1.day.from_now, host_sub: user.oidc_sub)
    coan = Webinar.create!(title: "coan", starts_at: 1.day.from_now, host_sub: "sub-other")
    coan.webinar_hosts.create!(email: user.email, invited_by_sub: "sub-other")
    _solo = Webinar.create!(title: "autre", starts_at: 1.day.from_now, host_sub: "sub-other")

    result = Webinar.where_animated_by(user).pluck(:id)
    assert_includes result, mien.id
    assert_includes result, coan.id
    assert_equal 2, result.size
  end

  test "where_animated_by_scope_project_host_voit_tout" do
    admin = User.create!(email: "admin@example.net", oidc_sub: "sub-admin", admin: true)
    _a = Webinar.create!(title: "a", starts_at: 1.day.from_now, host_sub: "sub-x")
    _b = Webinar.create!(title: "b", starts_at: 1.day.from_now, host_sub: "sub-y")
    assert_equal 2, Webinar.where_animated_by(admin).count
  end

  test "where_animated_by_sans_user_est_none" do
    _a = Webinar.create!(title: "a", starts_at: 1.day.from_now, host_sub: "sub-x")
    assert_empty Webinar.where_animated_by(nil)
  end

  test "where_managed_by_exclut_guest_host" do
    guest = User.create!(email: "guest@example.net", oidc_sub: "sub-guest", email_verified: true, email_verified_for: "guest@example.net")
    coan = Webinar.create!(title: "coan", starts_at: 1.day.from_now, host_sub: "sub-other")
    coan.webinar_hosts.create!(email: guest.email, invited_by_sub: "sub-other")

    # L'invité PEUT animer…
    assert_includes Webinar.where_animated_by(guest).pluck(:id), coan.id
    # …mais ne peut PAS gérer (inscrits/enregistrements/intervenants).
    assert_not_includes Webinar.where_managed_by(guest).pluck(:id), coan.id
  end

  # ---- Agenda : fin prévue, « terminé », libellés texte ----

  test "chaque format a une durée prévue (sinon /agenda.ics tomberait en 500)" do
    assert_equal Webinar::KINDS.sort, Webinar::PLANNED_DURATIONS.keys.sort
  end

  test "fin prévue : 1 h pour un Café IA, 3 h pour un bootcamp" do
    starts_at = Time.zone.local(2026, 11, 5, 18, 0)
    assert_equal Time.zone.local(2026, 11, 5, 19, 0), Webinar.new(kind: "cafe_ia", starts_at: starts_at).planned_ends_at
    assert_equal Time.zone.local(2026, 11, 5, 21, 0), Webinar.new(kind: "bootcamp", starts_at: starts_at).planned_ends_at
  end

  test "past? : direct terminé, ou brouillon non lancé au-delà de la fenêtre de retard" do
    now = Time.zone.local(2026, 11, 5, 18, 0)

    assert Webinar.new(starts_at: now + 1.day, state: "ended").past?(now)
    assert Webinar.new(starts_at: now - 3.hours - 1.second).past?(now)
    assert_not Webinar.new(starts_at: now - 3.hours).past?(now)
    assert_not Webinar.new(starts_at: now + 1.day).past?(now)
    assert_not Webinar.new(starts_at: now - 1.day, state: "live").past?(now), "fin oubliée : reste en cours"
  end

  test "past? : complément exact des groupes de l'accueil (en direct, en retard, à venir)" do
    now = Time.zone.local(2026, 11, 5, 18, 0)
    [
      { starts_at: now - 1.day, state: "live" }, { starts_at: now - 1.day, state: "ended" },
      { starts_at: now + 1.hour, state: "ended" }, { starts_at: now - 3.hours },
      { starts_at: now - 3.hours - 1.second }, { starts_at: now }, { starts_at: now + 1.day }
    ].each_with_index { |attrs, index| Webinar.create!(valid_attrs(title: "w#{index}", **attrs)) }

    homepage = Webinar.live.to_a + Webinar.starting_late(now).to_a + Webinar.upcoming(now).to_a
    assert_equal homepage.map(&:id).sort, Webinar.all.reject { |webinar| webinar.past?(now) }.map(&:id).sort
  end

  test "kind_label : libellé du format" do
    assert_equal "Café IA", Webinar.new(kind: "cafe_ia").kind_label
    assert_equal "Bootcamp", Webinar.new(kind: "bootcamp").kind_label
  end

  test "description_text : texte brut, sans balisage ni contenu de script" do
    webinar = Webinar.new(description: "<p>Démo <b>live</b> & Q/R</p><p>Suite</p><script>alert(1)</script>Fin")
    assert_equal "Démo live & Q/R\n\nSuite\nFin", webinar.description_text
    assert_equal "", Webinar.new(description: nil).description_text
  end

  # Reconduction des co-animateurs.
  test "previous_by_owner : le webinaire qui précède, chez le même propriétaire" do
    now = Time.current
    older = Webinar.create!(valid_attrs(title: "Café 6", starts_at: now - 14.days))
    previous = Webinar.create!(valid_attrs(title: "Café 7", starts_at: now - 7.days))
    Webinar.create!(valid_attrs(title: "Autrui", starts_at: now - 1.day, host_sub: "sub-autre"))
    current = Webinar.create!(valid_attrs(title: "Café 8", starts_at: now))
    Webinar.create!(valid_attrs(title: "Café 9", starts_at: now + 7.days))

    assert_equal previous, current.previous_by_owner
    assert_equal older, previous.previous_by_owner
    assert_nil older.previous_by_owner
  end

  test "carryover_hosts : co-animateurs du précédent absents de celui-ci" do
    previous = Webinar.create!(valid_attrs(title: "Café 7", starts_at: 7.days.ago))
    current = Webinar.create!(valid_attrs(title: "Café 8", starts_at: 1.day.from_now))
    previous.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: "sub-marc", claimed_sub: "sub-jean")
    previous.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: "sub-marc")
    current.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: "sub-marc")

    assert_equal [ "jean@partenaire.example.org" ], current.carryover_hosts.map(&:email)
    assert_empty previous.carryover_hosts
  end

  test "carryover_hosts ignore un co-animateur entré après la fin du café précédent" do
    previous = Webinar.create!(valid_attrs(title: "Café 7", starts_at: 7.days.ago))
    current = Webinar.create!(valid_attrs(title: "Café 8", starts_at: 1.day.from_now))
    ended_at = 6.days.ago
    previous.update!(state: "ended", ended_at: ended_at)
    previous.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: "sub-marc", created_at: ended_at - 1.hour)
    previous.webinar_hosts.create!(email: "tardif@partenaire.example.org", invited_by_sub: "sub-marc", created_at: ended_at + 1.hour)

    assert_equal [ "jean@partenaire.example.org" ], current.carryover_hosts.map(&:email)
  end

  test "carry_over_hosts! reprend les seuls candidats cochés, rattachés au même compte" do
    previous = Webinar.create!(valid_attrs(title: "Café 7", starts_at: 7.days.ago))
    current = Webinar.create!(valid_attrs(title: "Café 8", starts_at: 1.day.from_now))
    previous.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: "sub-marc", claimed_sub: "sub-jean")
    previous.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: "sub-marc")

    created = current.carry_over_hosts!([ " JEAN@partenaire.example.org", "intrus@ailleurs.example.net" ], invited_by_sub: "sub-admin")

    assert_equal [ [ "jean@partenaire.example.org", "sub-admin", "sub-jean" ] ],
                 created.map { |host| [ host.email, host.invited_by_sub, host.claimed_sub ] }
    assert_equal [ "jean@partenaire.example.org" ], current.webinar_hosts.pluck(:email)
  end
end
