require "test_helper"

class UserTest < ActiveSupport::TestCase
  # Invariants du rapprochement OIDC.

  test "requires email, oidc_sub" do
    user = User.new
    assert_not user.valid?
    # Type d'erreur, pas le libellé : la locale par défaut est fr (charte).
    assert user.errors.of_kind?(:email, :blank)
    assert user.errors.of_kind?(:oidc_sub, :blank)
  end

  test "email is normalized (downcase + strip)" do
    u = User.create!(email: "  Alice@Example.COM  ", oidc_sub: "sub-1")
    assert_equal "alice@example.com", u.email
  end

  test "oidc_sub uniqueness is strict" do
    User.create!(email: "a@example.net", oidc_sub: "sub-dup")
    dup = User.new(email: "b@example.net", oidc_sub: "sub-dup")
    assert_not dup.valid?
    assert dup.errors.of_kind?(:oidc_sub, :taken)
  end

  # done_when : "Le callback OIDC retrouve/lie l'user par oidc_sub,
  # jamais par simple email" — cœur de l'invariant côté modèle.
  test "find_or_create_by_oidc_uses_sub_only_never_email" do
    # Un user existe avec sub X et email A. On rappelle avec sub X et
    # un email B — on doit RETROUVER le même record (par sub), et
    # actualiser l'email localement. AUCUNE création en doublon.
    existing = User.create!(email: "old@example.com", oidc_sub: "sub-42")

    assert_no_difference -> { User.count } do
      found = User.find_or_create_by_oidc!(sub: "sub-42", email: "new@example.com")
      assert_equal existing.id, found.id
      assert_equal "new@example.com", found.email
    end

    # Symétrie : un email connu MAIS un sub INCONNU doit péter (unicité
    # email violée) plutôt que créer un doublon silencieusement.
    User.create!(email: "bob@example.com", oidc_sub: "sub-bob")
    assert_raises(ActiveRecord::RecordInvalid) do
      User.find_or_create_by_oidc!(sub: "sub-brand-new", email: "bob@example.com")
    end
  end

  # Groupes OIDC + prédicat project_host?

  test "find_or_create_by_oidc_rafraichit_oidc_groups_et_horodatage_si_fourni" do
    user = User.create!(email: "u@example.net", oidc_sub: "sub-u", oidc_groups: [ "stale" ])
    assert_nil user.oidc_groups_fetched_at
    before = Time.current
    User.find_or_create_by_oidc!(sub: "sub-u", email: "u@example.net", groups: [ "live-animateurs" ])
    user.reload
    assert_equal [ "live-animateurs" ], user.oidc_groups
    assert_in_delta before.to_f, user.oidc_groups_fetched_at.to_f, 10.0
  end

  test "find_or_create_by_oidc_preserve_oidc_groups_si_nil" do
    user = User.create!(email: "u@example.net", oidc_sub: "sub-u",
                        oidc_groups: [ "live-animateurs" ],
                        oidc_groups_fetched_at: 1.minute.ago)
    frozen_at = user.oidc_groups_fetched_at
    User.find_or_create_by_oidc!(sub: "sub-u", email: "u@example.net", groups: nil)
    assert_equal [ "live-animateurs" ], user.reload.oidc_groups
    assert_equal frozen_at.to_i, user.oidc_groups_fetched_at.to_i
  end

  test "find_or_create_by_oidc_persiste_email_verified_true_et_colle_email_verified_for" do
    User.find_or_create_by_oidc!(sub: "sub-v", email: "v@example.net", email_verified: true)
    user = User.find_by(oidc_sub: "sub-v")
    assert user.email_verified
    assert_equal "v@example.net", user.email_verified_for
    assert user.email_verified_and_fresh?
  end

  test "find_or_create_by_oidc_persiste_email_verified_false_par_defaut" do
    # Pas de claim → `email_verified: nil` → on NE touche PAS la colonne
    # existante ; sur un nouveau user, défaut DB `false`.
    User.find_or_create_by_oidc!(sub: "sub-nv", email: "nv@example.net")
    user = User.find_by(oidc_sub: "sub-nv")
    assert_not user.email_verified
    assert_nil user.email_verified_for
  end

  test "find_or_create_by_oidc_rafraichit_email_verified_for_quand_email_change" do
    # Un user se reconnecte avec un email DIFFÉRENT côté Pocket ID — le
    # claim arrive avec email_verified=true POUR LE NOUVEAU email. La
    # paire doit être cohérente (sinon l'ancien `email_verified_for`
    # bloquerait la résolution :guest_host alors que l'email est bien
    # vérifié).
    User.find_or_create_by_oidc!(sub: "sub-ch", email: "old@example.net", email_verified: true)
    User.find_or_create_by_oidc!(sub: "sub-ch", email: "new@example.net", email_verified: true)
    user = User.find_by(oidc_sub: "sub-ch")
    assert_equal "new@example.net", user.email
    assert_equal "new@example.net", user.email_verified_for
    assert user.email_verified_and_fresh?
  end

  test "find_or_create_by_oidc_ne_rattache_jamais_un_sub_different_a_un_email_existant" do
    # Défense broken-authentication §1c. Un attaquant
    # qui contrôle un sub DIFFÉRENT avec le MÊME email ne peut pas
    # usurper le User existant — l'index unique sur LOWER(email) fait
    # péter en RecordInvalid.
    User.find_or_create_by_oidc!(sub: "sub-legit", email: "shared@example.net", email_verified: true)
    assert_raises(ActiveRecord::RecordInvalid) do
      User.find_or_create_by_oidc!(sub: "sub-attacker", email: "shared@example.net", email_verified: true)
    end
    # Le user légitime reste inchangé.
    legit = User.find_by(oidc_sub: "sub-legit")
    assert_equal "shared@example.net", legit.email
  end

  test "email_verified_and_fresh_false_si_email_change_sans_rafraichir_verified_for" do
    # Simule un chemin latéral : `user.update!(email: ...)` sans
    # callback OIDC. `email_verified_for` reste à l'ancienne valeur →
    # `email_verified_and_fresh?` tombe à false.
    user = User.create!(email: "verif@example.net", oidc_sub: "sub-v",
                        email_verified: true, email_verified_for: "verif@example.net")
    assert user.email_verified_and_fresh?
    user.update!(email: "autre@example.net")
    assert_not user.email_verified_and_fresh?
  end

  test "project_host_true_si_admin_sans_horodatage" do
    # admin: true seul = fallback humain, pas lié aux groupes OIDC.
    assert User.create!(email: "a@example.net", oidc_sub: "sub-a", admin: true).project_host?
  end

  test "project_host_true_si_groupe_live_animateurs_et_horodatage_frais" do
    user = User.create!(email: "a@example.net", oidc_sub: "sub-a",
                        oidc_groups: [ "x", "live-animateurs" ],
                        oidc_groups_fetched_at: 1.minute.ago)
    assert user.project_host?
  end

  # Lien animateur : le groupe Pocket ID `live-invites`
  # porté par les comptes créés par jeton d'inscription n'ouvre que la
  # connexion à live. Aucun droit d'animation sans WebinarHost.
  test "project_host_false_pour_le_groupe_live_invites" do
    user = User.create!(email: "invite@partenaire.example.org", oidc_sub: "sub-invite",
                        oidc_groups: [ "live-invites" ],
                        oidc_groups_fetched_at: 1.minute.ago,
                        email_verified: true, email_verified_for: "invite@partenaire.example.org")
    webinar = Webinar.create!(title: "demo", starts_at: 1.day.from_now, host_sub: "sub-owner")

    assert_not user.project_host?
    assert_not user.can_manage_packs?
    assert_nil webinar.role_for(user)
    assert_empty Webinar.where_animated_by(user)
  end

  test "can_manage_packs : animateur du projet ou propriétaire d'un webinaire, pas un co-animateur invité" do
    admin = User.create!(email: "a@example.net", oidc_sub: "sub-a", admin: true)
    owner = User.create!(email: "o@example.net", oidc_sub: "sub-o")
    guest = User.create!(email: "g@example.net", oidc_sub: "sub-g", email_verified: true, email_verified_for: "g@example.net")
    webinar = Webinar.create!(title: "demo", starts_at: 1.day.from_now, host_sub: owner.oidc_sub)
    webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: owner.oidc_sub, claimed_sub: guest.oidc_sub)

    assert admin.can_manage_packs?
    assert owner.can_manage_packs?
    assert_equal :guest_host, webinar.role_for(guest)
    assert_not guest.can_manage_packs?
  end

  test "project_host_false_si_groupe_live_animateurs_mais_horodatage_perime" do
    # Défense fail-open-state-drift : retrait du groupe côté Pocket ID
    # → au prochain refresh les droits tombent ; mais même sans refresh,
    # dès que la fenêtre expire, le droit ne compte plus.
    user = User.create!(email: "a@example.net", oidc_sub: "sub-a",
                        oidc_groups: [ "live-animateurs" ],
                        oidc_groups_fetched_at: 13.hours.ago)
    assert_not user.project_host?
  end

  test "project_host_false_si_oidc_groups_fetched_at_nil" do
    # Groupes présents en DB mais sans horodatage (reliquat, import, migration)
    # → traités comme périmés (fail-closed).
    user = User.create!(email: "a@example.net", oidc_sub: "sub-a",
                        oidc_groups: [ "live-animateurs" ],
                        oidc_groups_fetched_at: nil)
    assert_not user.project_host?
  end

  test "project_host_fenetre_configurable_via_env" do
    user = User.create!(email: "a@example.net", oidc_sub: "sub-a",
                        oidc_groups: [ "live-animateurs" ],
                        oidc_groups_fetched_at: 2.hours.ago)
    ENV["LIVE_PROJECT_HOSTS_FRESH_WINDOW_SECONDS"] = "3600"
    assert_not user.project_host?
    ENV["LIVE_PROJECT_HOSTS_FRESH_WINDOW_SECONDS"] = "86400"
    assert user.project_host?
  ensure
    ENV.delete("LIVE_PROJECT_HOSTS_FRESH_WINDOW_SECONDS")
  end

  test "project_host_true_si_env_fallback_contient_email_verifie" do
    user = User.create!(email: "fallback@example.net", oidc_sub: "sub-f", email_verified: true, email_verified_for: "fallback@example.net")
    ENV["LIVE_PROJECT_HOSTS"] = "autre@example.net,fallback@example.net"
    assert user.project_host?
  ensure
    ENV.delete("LIVE_PROJECT_HOSTS")
  end

  test "project_host_false_si_env_fallback_contient_un_email_non_verifie" do
    user = User.create!(email: "fallback@example.net", oidc_sub: "sub-f", email_verified: false)
    ENV["LIVE_PROJECT_HOSTS"] = "fallback@example.net"
    assert_not user.project_host?
  ensure
    ENV.delete("LIVE_PROJECT_HOSTS")
  end

  test "project_host_false_si_l_email_verifie_n_est_plus_celui_du_compte" do
    user = User.create!(email: "fallback@example.net", oidc_sub: "sub-f", email_verified: true, email_verified_for: "ancien@example.net")
    ENV["LIVE_PROJECT_HOSTS"] = "fallback@example.net"
    assert_not user.project_host?
  ensure
    ENV.delete("LIVE_PROJECT_HOSTS")
  end

  test "project_host_false_si_env_fallback_vide" do
    user = User.create!(email: "fallback@example.net", oidc_sub: "sub-f")
    ENV["LIVE_PROJECT_HOSTS"] = ""
    assert_not user.project_host?
    ENV["LIVE_PROJECT_HOSTS"] = "   , ,   "
    assert_not user.project_host?
  ensure
    ENV.delete("LIVE_PROJECT_HOSTS")
  end

  test "project_host_false_si_email_different_de_env_fallback" do
    user = User.create!(email: "a@example.net", oidc_sub: "sub-a")
    ENV["LIVE_PROJECT_HOSTS"] = "autre@example.net, encore@example.net"
    assert_not user.project_host?
  ensure
    ENV.delete("LIVE_PROJECT_HOSTS")
  end

  test "project_host_respecte_env_live_animateurs_group" do
    previous = ENV["LIVE_ANIMATEURS_GROUP"]
    user = User.create!(email: "a@example.net", oidc_sub: "sub-a",
                        oidc_groups: [ "custom-group" ],
                        oidc_groups_fetched_at: Time.current)
    ENV["LIVE_ANIMATEURS_GROUP"] = "custom-group"
    assert user.project_host?
  ensure
    ENV["LIVE_ANIMATEURS_GROUP"] = previous
  end

  test "sans LIVE_ANIMATEURS_GROUP, aucun groupe ne donne le rôle" do
    previous = ENV["LIVE_ANIMATEURS_GROUP"]
    user = User.create!(email: "a@example.net", oidc_sub: "sub-a",
                        oidc_groups: [ "live-animateurs", "" ],
                        oidc_groups_fetched_at: Time.current)
    [ nil, "", " " ].each do |value|
      ENV["LIVE_ANIMATEURS_GROUP"] = value
      assert_not user.project_host?, "LIVE_ANIMATEURS_GROUP=#{value.inspect}"
    end
  ensure
    ENV["LIVE_ANIMATEURS_GROUP"] = previous
  end

  test "project_host_false_par_defaut" do
    user = User.create!(email: "a@example.net", oidc_sub: "sub-a")
    assert_not user.project_host?
  end
end
