# frozen_string_literal: true

require "test_helper"

# Registration.
#
# Trois critères :
#   • registration_schema     — colonnes + unicité (webinar_id, email)
#   • registration_lifecycle  — normalisation email, token, confirm!, scope
#   • registration_lookup     — find_by_token défensif + has_many restrict
#
# Suit le pattern de RecordingTest (setup `Webinar.create!` — pas de fixture
# YAML dans ce repo, tous les tests créent leurs webinaires en mémoire).
class RegistrationTest < ActiveSupport::TestCase
  # ---- Identité provisoire -------------------------

  test "chaque inscription a son propre secret d'identité" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    first = webinar.registrations.create!(name: "A", email: "a@example.test")
    second = webinar.registrations.create!(name: "B", email: "b@example.test")

    assert_match(/\A\h{48}\z/, first.identity_secret)
    assert_not_equal first.identity_secret, second.identity_secret
  end

  test "retirer une inscription NON confirmée : pierre tombale, l'adresse est libérée, l'id et le retrait restent" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    provisional = webinar.registrations.create!(name: "Intrus", email: "victime@example.test", instant_access_at: Time.current,
                                                marketing_consent_token: "MC", marketing_consent_token_expires_at: 1.day.from_now)
    token = provisional.token

    provisional.remove_from_room!

    provisional.reload
    assert provisional.room_removed_at
    assert provisional.retired?
    assert_match(/\Aretire-\h{32}@retire\.invalid\z/, provisional.email, "adresse imprévisible du domaine réservé")
    assert_equal CrmErasure.digest("victime@example.test"), provisional.retired_email_digest
    assert_not_equal token, provisional.token
    assert_nil provisional.marketing_consent_token
    assert_equal "Intrus", provisional.name, "l'identité reste, pour ce navigateur"

    fresh, created = Registration.find_or_create_for(webinar, email: "victime@example.test", name: "Victime")
    assert created, "l'adresse n'est pas bannie"
    assert_nil fresh.room_removed_at
  end

  # Une adresse de pierre tombale occupée
  # d'avance ne doit jamais annuler le retrait.
  test "collision provoquée sur l'adresse de pierre tombale : le retrait tient, l'adresse reste retirée" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    provisional = webinar.registrations.create!(name: "Intrus", email: "victime@example.test", instant_access_at: Time.current)
    squatter = webinar.registrations.create!(name: "Squatteur", email: "squat@example.test")
    colliding = "retire-#{"a" * 32}@retire.invalid"
    squatter.update_columns(email: colliding)
    planned = provisional.method(:retire_attributes)
    provisional.define_singleton_method(:retire_attributes) { planned.call.merge(email: colliding) }

    provisional.remove_from_room!

    provisional.reload
    assert provisional.room_removed_at, "le retrait n'est jamais annulé"
    assert_not provisional.retired?
    assert_equal "victime@example.test", provisional.email, "échec de la pierre tombale : l'adresse reste retirée"
  end

  test "le domaine réservé .invalid est refusé à la saisie ; seule une pierre tombale le porte" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")

    assert_not webinar.registrations.new(name: "X", email: "retire-1@retire.invalid").valid?
    assert_not webinar.registrations.new(name: "X", email: "x@quelque.INVALID").valid?
    assert Registration.reserved_email?("a@b.invalid.")
    assert_not Registration.reserved_email?("a@invalid.example.test")
  end

  test "confirmer refuse, sous le verrou, une inscription retirée ou en pierre tombale" do
    webinar = Webinar.create!(title: "Café", starts_at: Time.current, host_sub: "h", visibility: "published", state: "live", started_at: Time.current)
    raced = webinar.registrations.create!(name: "Intrus", email: "a@example.test", instant_access_at: Time.current)
    Registration.find(raced.id).remove_from_room!
    assert_not raced.confirm!, "état relu sous le verrou : le retrait concurrent gagne"
    assert_not raced.reload.confirmed?

    handed = webinar.registrations.create!(name: "Intrus", email: "b@example.test", instant_access_at: Time.current)
    Registration.find(handed.id).hand_over!(name: "Victime")
    assert_not handed.confirm!
    assert_not handed.reload.crm_sync_eligible?

    proven = webinar.registrations.create!(name: "Basile", email: "c@example.test")
    proven.remove_from_room!(mailbox_proven: true)
    assert_not proven.confirm!
  end

  test "retrait par un intervenant à la boîte prouvée : l'inscription non confirmée garde son adresse, retirée" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    registration = webinar.registrations.create!(name: "Basile", email: "basile@example.test")

    registration.remove_from_room!(mailbox_proven: true)
    registration.remove_from_room!

    assert registration.reload.room_removed_at
    assert_not registration.retired?, "un retrait relancé ne libère pas l'adresse"
    _, created = Registration.find_or_create_for(webinar, email: "basile@example.test", name: "Basile")
    assert_not created, "pas de réinscription sous la même adresse"
  end

  test "retirer une inscription confirmée : l'adresse est retirée avec elle" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    confirmed = webinar.registrations.create!(name: "Inès", email: "ines@example.test", confirmed_at: Time.current)

    confirmed.remove_from_room!
    confirmed.remove_from_room!

    assert_equal [ "ines@example.test", false ], [ confirmed.reload.email, confirmed.retired? ]
    _, created = Registration.find_or_create_for(webinar, email: "ines@example.test", name: "Inès")
    assert_not created
  end

  test "remettre une identité provisoire : pierre tombale et inscription neuve, confirmée, qui n'hérite de rien" do
    webinar = Webinar.create!(title: "Café", starts_at: Time.current, host_sub: "h", visibility: "published", state: "live", started_at: Time.current)
    provisional = webinar.registrations.create!(name: "Intrus", email: "victime@example.test", participation: "participant",
                                                instant_access_at: Time.current)
    webinar.messages.create!(author_identity: "viewer-#{provisional.id}", name: "Intrus", body: "Bonjour")

    # Rattachement prouvé antérieur (le clic de /rattacher rattache désormais
    # à une inscription neuve, Speaker#link_to_declared_registration!).
    linked = webinar.speakers.create!(name: "Victime au micro", registration: provisional)
    declared = webinar.speakers.create!(name: "Intrus au micro", declared_email: "victime@example.test")

    fresh = provisional.hand_over!(name: "Victime")

    assert_equal [ "Victime", "victime@example.test", "spectator" ], [ fresh.name, fresh.email, fresh.participation ]
    assert_equal fresh, linked.reload.registration, "un rattachement prouvé suit la personne qui a prouvé la boîte"
    assert_nil declared.reload.registration, "un intervenant non rattaché le reste"
    assert_equal "participant", webinar.registrations.create!(name: "P", email: "p@example.test", instant_access_at: Time.current)
                                       .hand_over!(name: "P", participation: "participant").participation
    assert fresh.participation_chosen?, "le choix du formulaire de confirmation n'est pas redemandé dans la salle"
    assert fresh.confirmed?
    assert fresh.crm_sync_eligible?
    assert_not_equal provisional.identity_secret, fresh.identity_secret
    assert provisional.reload.retired?
    assert_not provisional.confirmed?
    assert_not provisional.crm_sync_eligible?
    assert provisional.room_access?, "le navigateur qui l'a ouverte garde son identité provisoire"
    assert_nil provisional.hand_over!(name: "Encore"), "une seule fois"
  end

  test "rien à remettre : inscription confirmée, sans accès immédiat, ou retirée" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    confirmed = webinar.registrations.create!(name: "A", email: "a@example.test", instant_access_at: Time.current, confirmed_at: Time.current)
    pending = webinar.registrations.create!(name: "B", email: "b@example.test")

    assert_nil confirmed.hand_over!(name: "X")
    assert_nil pending.hand_over!(name: "X")
    assert_not pending.provisional?
    assert_equal 2, webinar.registrations.count
  end

  setup do
    @webinar = Webinar.create!(
      title: "Café IA test", starts_at: 1.day.from_now, host_sub: "sub-marc"
    )
  end

  test "le nom tient sur une ligne : caractères de contrôle remplacés par un espace" do
    registration = @webinar.registrations.create!(email: "ines@example.test", name: " Inès\r\n| Extraits autorisés |\u0007")

    assert_equal "Inès | Extraits autorisés |", registration.name
  end

  # ---- registration_schema --------------------------------------------------

  test "table registrations expose les colonnes attendues" do
    cols = Registration.columns_hash
    %w[webinar_id email name token confirmed_at paid_confirmed_at reminder_sent_at created_at updated_at
       marketing_consent marketing_consent_at
       marketing_consent_token marketing_consent_token_expires_at
       marketing_withdrawal_token marketing_consent_withdrawn_at
       pushed_to_crm_at crm_contact_id crm_sync_attempts crm_last_error_code
       registration_request_id crm_marketing_consent_pushed_at].each do |c|
      assert cols.key?(c), "colonne #{c} manquante dans le schéma"
    end
    # `reminder_sent_at` est un dictionnaire d'envois — json, pas text.
    assert_equal "json", cols["reminder_sent_at"].sql_type
    # Default {} côté DB : évite tout `NULL.dig("j1")` côté job.
    r = Registration.create!(webinar: @webinar, email: "a@example.org", name: "A")
    assert_equal({}, r.reload.reminder_sent_at)
  end

  test "deuxième inscription même email/même webinaire = validation, pas d'exception DB" do
    Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    dup = Registration.new(webinar: @webinar, email: "marc@example.org", name: "Marc bis")
    assert_not dup.valid?
    # Symbole (pas de libellé) — indépendant de la locale.
    assert dup.errors.of_kind?(:email, :taken)
  end

  test "même email autorisé sur DEUX webinaires distincts" do
    other = Webinar.create!(title: "Autre", starts_at: 2.days.from_now, host_sub: "sub-marc")
    Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    assert Registration.new(webinar: other, email: "marc@example.org", name: "Marc").valid?
  end

  # ---- registration_lifecycle -----------------------------------------------

  test "normalise l'email (strip + downcase) AVANT persistance" do
    r = Registration.create!(webinar: @webinar, email: " Marc@Example.org ", name: "Marc")
    assert_equal "marc@example.org", r.reload.email
  end

  test "génère un token opaque non vide et unique à la création" do
    r1 = Registration.create!(webinar: @webinar, email: "a@example.org", name: "A")
    r2 = Registration.create!(webinar: @webinar, email: "b@example.org", name: "B")
    # SecureRandom.urlsafe_base64(24) → 32 chars [A-Za-z0-9_-].
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, r1.token)
    assert_not_equal r1.token, r2.token
  end

  test "token présent respecté à la création (pas d'écrasement)" do
    r = Registration.create!(
      webinar: @webinar, email: "a@example.org", name: "A", token: "token-pre-fourni-1234567890abcdef"
    )
    assert_equal "token-pre-fourni-1234567890abcdef", r.reload.token
  end

  test "token non réassigné après création (update d'un autre champ)" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    original = r.token
    r.update!(name: "Marc bis")
    assert_equal original, r.reload.token
  end

  test "confirm! pose confirmed_at et rend confirmed?" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    assert_not r.confirmed?
    r.confirm!
    assert r.confirmed?
    assert_not_nil r.reload.confirmed_at
  end

  test "confirm! est idempotent — deuxième appel ne réécrit pas confirmed_at" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    t1 = Time.zone.parse("2026-09-21T10:00:00")
    travel_to(t1) { r.confirm! }
    first = r.reload.confirmed_at
    t2 = Time.zone.parse("2026-09-21T11:00:00")
    travel_to(t2) { r.confirm! }
    assert_equal first, r.reload.confirmed_at
  end

  test "scope confirmed filtre les inscriptions ayant confirmed_at posé" do
    a = Registration.create!(webinar: @webinar, email: "a@example.org", name: "A")
    b = Registration.create!(webinar: @webinar, email: "b@example.org", name: "B")
    a.confirm!
    assert_includes Registration.confirmed, a
    assert_not_includes Registration.confirmed, b
  end

  # Retrait de la salle par l'animation.
  test "remove_from_room! ferme la salle durablement, une seule fois, sans toucher à l'inscription" do
    removed = Registration.create!(webinar: @webinar, email: "intrus@example.org", name: "Intrus", confirmed_at: Time.current)
    kept = Registration.create!(webinar: @webinar, email: "ines@example.org", name: "Inès", confirmed_at: Time.current)
    pending = Registration.create!(webinar: @webinar, email: "attente@example.org", name: "En attente")

    removed.remove_from_room!
    removed_at = removed.room_removed_at
    travel 1.hour do
      removed.remove_from_room!
    end

    assert_equal removed_at, removed.reload.room_removed_at
    assert removed.confirmed?
    assert_not removed.room_access?
    assert kept.room_access?
    assert_not pending.room_access?
    assert_equal [ kept ], @webinar.registrations.with_room_access.to_a
  end

  test "paid_confirmed? false par défaut, true après pose du timestamp" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    assert_not r.paid_confirmed?
    r.update!(paid_confirmed_at: Time.current)
    assert r.paid_confirmed?
  end

  # ---- registration_marketing_consent --------------------------------------

  test "marketing_consent défaut false, marketing_consent_at NULL" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    assert_not r.marketing_consent
    assert_nil r.marketing_consent_at
    assert_not r.crm_sync_eligible?
  end

  test "request_marketing_consent! pose jeton + expiration, idempotent" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    t = Time.zone.parse("2026-10-07T09:00:00")
    travel_to(t) { r.request_marketing_consent! }
    r.reload
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, r.marketing_consent_token)
    assert_equal t + Registration::MARKETING_CONSENT_TOKEN_TTL,
                 r.marketing_consent_token_expires_at
    # Idempotent : un second appel sans expiration ne régénère pas.
    first_token = r.marketing_consent_token
    travel_to(t + 1.hour) { r.request_marketing_consent! }
    assert_equal first_token, r.reload.marketing_consent_token
  end

  test "apply_marketing_consent! horodate, consomme le jeton, pose le withdrawal_token" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    r.request_marketing_consent!
    t = Time.zone.parse("2026-10-08T09:00:00")
    travel_to(t) { assert_equal true, r.apply_marketing_consent!(now: t) }
    r.reload
    assert r.marketing_consent
    assert_equal t, r.marketing_consent_at
    assert_nil r.marketing_consent_token, "jeton consommé"
    assert_nil r.marketing_consent_token_expires_at
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, r.marketing_withdrawal_token)
    assert_equal "Oui, j'accepte d'être recontacté·e", r.marketing_consent_label,
                 "libellé du bouton /mc affiché, figé à l'accord"
    # Rejeu : plus de jeton de consentement → false.
    assert_equal false, r.apply_marketing_consent!
    assert_equal t, r.reload.marketing_consent_at
  end

  test "apply_marketing_consent! fige le libellé de la TONALITÉ quand elle réécrit la clé" do
    I18n.backend.store_translations(:fr, voices: { bootcamp: { marketing_consents: { show: { accept: "Oui, je veux les nouvelles du bootcamp" } } } })
    bootcamp = Webinar.create!(title: "Bootcamp T", kind: "bootcamp", starts_at: 3.days.from_now, host_sub: "h")
    r = Registration.create!(webinar: bootcamp, email: "kay@example.test", name: "Kay")
    r.request_marketing_consent!
    assert_equal true, r.apply_marketing_consent!
    assert_equal "Oui, je veux les nouvelles du bootcamp", r.reload.marketing_consent_label,
                 "le libellé figé est celui de la tonalité de l'émission, pas une constante"
  ensure
    I18n.reload!
  end

  test "apply_marketing_consent! REFUSE un jeton expiré" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    r.request_marketing_consent!
    expired_at = r.marketing_consent_token_expires_at + 1.second
    assert_equal false, r.apply_marketing_consent!(now: expired_at),
                 "un jeton expiré ne doit JAMAIS poser le consentement"
    r.reload
    assert_not r.marketing_consent
    assert_nil r.marketing_consent_at
    # Le jeton reste présent côté DB jusqu'à nettoyage explicite (le controller
    # peut rendre la page « expiré »), mais il est inutile.
    assert r.marketing_consent_token_expired?(expired_at)
  end

  test "apply_marketing_consent! sans jeton : aucun effet" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    assert_equal false, r.apply_marketing_consent!
    assert_not r.marketing_consent
  end

  test "decline_marketing_consent! consomme le jeton sans poser le consentement" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    r.request_marketing_consent!
    assert_equal true, r.decline_marketing_consent!
    r.reload
    assert_not r.marketing_consent
    assert_nil r.marketing_consent_token
    assert_nil r.marketing_consent_token_expires_at
  end

  test "SÉCURITÉ : withdraw invalide AUSSI un marketing_consent_token en attente" do
    # Scénario de course : B soumet avec case cochée, puis se ravise avant
    # de cliquer sur /mc, et retire via le lien de retrait d'une inscription
    # antérieure. L'ancien jeton de consentement doit être invalidé.
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    r.request_marketing_consent!
    r.apply_marketing_consent!       # pose withdrawal_token
    pending_token = SecureRandom.urlsafe_base64(24)
    r.update!(marketing_consent_token: pending_token,
              marketing_consent_token_expires_at: 1.day.from_now)
    r.withdraw_marketing_consent!
    r.reload
    assert_nil r.marketing_consent_token, "l'ancien jeton de consentement doit être invalidé au retrait"
    assert_nil r.marketing_consent_token_expires_at
  end

  test "SÉCURITÉ : apply_marketing_consent! REFUSE après un retrait" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    r.request_marketing_consent!
    r.apply_marketing_consent!
    r.withdraw_marketing_consent!
    r.reload
    # Simule une tentative concurrente avec un ancien jeton encore nommé
    # (en vrai le withdraw l'a mis à nil, mais on force la condition pour
    # vérifier le garde-fou `marketing_consent_withdrawn_at`).
    r.update_columns(marketing_consent_token: "ancien-jeton",
                     marketing_consent_token_expires_at: 1.day.from_now)
    assert_equal false, r.apply_marketing_consent!,
                 "un retrait doit interdire toute ré-application"
  end

  test "withdraw_marketing_consent! retire + consomme le withdrawal_token" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    r.request_marketing_consent!
    r.apply_marketing_consent!
    withdrawal_token = r.reload.marketing_withdrawal_token
    assert_not_nil withdrawal_token
    t = Time.zone.parse("2026-11-01T10:00:00")
    assert_equal true, r.withdraw_marketing_consent!(now: t)
    r.reload
    assert_not r.marketing_consent
    assert_equal t, r.marketing_consent_withdrawn_at
    assert_nil r.marketing_withdrawal_token, "jeton de retrait à usage unique"
    # Rejeu : plus de jeton → false (idempotence utilisateur).
    assert_equal false, r.withdraw_marketing_consent!
  end

  test "find_by_marketing_consent_token défensif (nil/blank/inconnu → nil)" do
    assert_nil Registration.find_by_marketing_consent_token(nil)
    assert_nil Registration.find_by_marketing_consent_token("")
    assert_nil Registration.find_by_marketing_consent_token("   ")
    assert_nil Registration.find_by_marketing_consent_token("inconnu")
  end

  test "find_by_marketing_withdrawal_token défensif" do
    assert_nil Registration.find_by_marketing_withdrawal_token(nil)
    assert_nil Registration.find_by_marketing_withdrawal_token("inconnu")
  end

  test "crm_sync_eligible? : la confirmation suffit, le consentement marketing n'est plus requis" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    assert_not r.crm_sync_eligible?, "sans double opt-in, rien ne part au CRM"
    assert r.confirm!, "première confirmation"
    assert r.crm_sync_eligible?, "tout inscrit confirmé entre au CRM"
    assert_not r.confirm!, "seconde confirmation : rien ne découle à nouveau"
  end

  test "crm_sync_eligible? : confirmé sans entrée au CRM = non ; consentement /mc posé ensuite = oui" do
    r = Registration.create!(webinar: @webinar, email: "old@example.org", name: "Old", confirmed_at: 1.month.ago)
    assert_not r.crm_sync_eligible?
    r.request_marketing_consent!
    r.apply_marketing_consent!
    assert r.reload.crm_sync_eligible?, "un consentement /mc vaut entrée au CRM"
  end

  test "crm_marketing_consent_pending? : consentement effectif, non retiré, pas encore poussé" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc", confirmed_at: Time.current)
    assert_not r.crm_marketing_consent_pending?
    r.request_marketing_consent!
    assert_not r.crm_marketing_consent_pending?, "jeton en attente ≠ consentement"
    r.apply_marketing_consent!
    assert r.crm_marketing_consent_pending?
    r.update!(crm_marketing_consent_pushed_at: Time.current)
    assert_not r.crm_marketing_consent_pending?
    r.update!(crm_marketing_consent_pushed_at: nil)
    r.withdraw_marketing_consent!
    assert_not r.crm_marketing_consent_pending?, "un retrait gagne toujours"
  end

  test "SÉCURITÉ : le jeton marketing est DISTINCT du token d'inscription" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    r.request_marketing_consent!
    assert_not_equal r.token, r.marketing_consent_token
  end

  test "SÉCURITÉ : inspect masque AUSSI les jetons marketing" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    r.request_marketing_consent!
    r.apply_marketing_consent!
    r.reload
    inspected = r.inspect
    assert_no_match(/\A[A-Za-z0-9_-]{32}\z/, inspected, "pas de jeton nu dans inspect")
    assert_no_match(/marketing_consent_token/i, inspected)
    assert_no_match(/marketing_withdrawal_token/i, inspected)
  end

  test "scope crm_pending : participants confirmés non poussés, ou consentement à pousser" do
    attrs = { webinar: @webinar, confirmed_at: Time.current, crm_enrolled_at: Time.current }
    participant = Registration.create!(attrs.merge(email: "a@example.org", name: "A"))
    pushed = Registration.create!(attrs.merge(email: "b@example.org", name: "B", pushed_to_crm_at: Time.current))
    consent_to_push = Registration.create!(attrs.merge(
      email: "c@example.org", name: "C", pushed_to_crm_at: Time.current,
      marketing_consent: true, marketing_consent_at: Time.current
    ))
    withdrawn = Registration.create!(attrs.merge(
      email: "d@example.org", name: "D", pushed_to_crm_at: Time.current,
      marketing_consent: false, marketing_consent_withdrawn_at: Time.current
    ))
    unconfirmed = Registration.create!(webinar: @webinar, email: "e@example.org", name: "E")
    legacy_v10 = Registration.create!(webinar: @webinar, email: "f@example.org", name: "F", confirmed_at: Time.current)

    pending = Registration.crm_pending
    assert_includes pending, participant
    assert_includes pending, consent_to_push
    assert_not_includes pending, pushed
    assert_not_includes pending, withdrawn
    assert_not_includes pending, unconfirmed
    assert_not_includes pending, legacy_v10, "pas de poussée rétroactive des confirmés sans entrée au CRM"
  end

  test "find_or_create_for : crée avec la demande, ne touche JAMAIS une inscription existante" do
    request = RegistrationRequest.create!(name: "Alice", email: "alice@example.org", notify_next: true)
    created, was_created = Registration.find_or_create_for(@webinar, email: "alice@example.org", name: "Alice",
                                                           registration_request: request)
    assert was_created
    assert_equal request, created.registration_request

    other = RegistrationRequest.create!(name: "Mallory", email: "alice@example.org", notify_next: true)
    found, was_created = Registration.find_or_create_for(@webinar, email: "alice@example.org", name: "Mallory",
                                                         registration_request: other)
    assert_not was_created
    assert_equal created, found
    assert_equal "Alice", found.reload.name
    assert_equal request, found.registration_request, "jamais rattachée à une autre demande"
  end

  test "participation choisie : datée quand la personne la donne, jamais quand un site ne la transmet pas" do
    chosen, = Registration.find_or_create_for(@webinar, email: "ines@example.org", name: "Inès", participation: "spectator")
    silent, = Registration.find_or_create_for(@webinar, email: "paul@example.org", name: "Paul")
    found, = Registration.find_or_create_for(@webinar, email: "paul@example.org", name: "Paul", participation: "participant")

    assert chosen.participation_chosen?
    assert_not silent.participation_chosen?
    assert_not found.reload.participation_chosen?, "une inscription retrouvée garde son état"
    assert found.spectator?

    assert silent.choose_participation!("participant")
    assert silent.reload.participant?
    assert silent.participation_chosen?
    assert_not silent.choose_participation!("spectator"), "le premier choix gagne"
    assert silent.reload.participant?
    assert_raises(ArgumentError) { chosen.choose_participation!("host") }
  end

  test "validation name : présence + longueur ≤ 120" do
    r = Registration.new(webinar: @webinar, email: "x@example.org", name: nil)
    assert_not r.valid?
    assert r.errors.of_kind?(:name, :blank)

    r.name = "a" * 121
    assert_not r.valid?
    assert r.errors.of_kind?(:name, :too_long)
  end

  test "validation email : format invalide rejeté" do
    r = Registration.new(webinar: @webinar, email: "pas-un-email", name: "Marc")
    assert_not r.valid?
    assert r.errors.of_kind?(:email, :invalid)
  end

  test "inspect masque le token (défense en profondeur logs)" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    assert_no_match(/#{Regexp.escape(r.token)}/, r.inspect)
  end

  # ---- registration_lookup --------------------------------------------------

  test "find_by_token(nil / blank / inconnu) = nil sans exception" do
    assert_nil Registration.find_by_token(nil)
    assert_nil Registration.find_by_token("")
    assert_nil Registration.find_by_token("   ")
    assert_nil Registration.find_by_token("token-fantome-inexistant")
  end

  test "find_by_token(existant) retourne l'inscription" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    assert_equal r, Registration.find_by_token(r.token)
  end

  # ---- lien participants : choix et accès immédiat ----------

  test "le choix vaut spectateur par défaut et n'accepte que spectateur ou participant" do
    assert Registration.create!(webinar: @webinar, email: "a@example.org", name: "A").spectator?
    assert Registration.create!(webinar: @webinar, email: "b@example.org", name: "B", participation: "participant").participant?
    invalid = Registration.new(webinar: @webinar, email: "c@example.org", name: "C", participation: "host")
    assert_not invalid.valid?
    assert invalid.errors.of_kind?(:participation, :inclusion)
  end

  test "find_or_create_for pose le choix d'une inscription créée, jamais celui d'une inscription retrouvée" do
    created, was_created = Registration.find_or_create_for(@webinar, email: "marc@example.org", name: "Marc", participation: "participant")
    assert was_created
    assert created.participant?

    found, was_created = Registration.find_or_create_for(@webinar, email: "marc@example.org", name: "Autre", participation: "spectator")
    assert_not was_created
    assert_equal [ created, "participant", "Marc" ], [ found, found.participation, found.name ]

    default, = Registration.find_or_create_for(@webinar, email: "sans@example.org", name: "Sans")
    assert default.spectator?
  end

  test "accès immédiat ouvert pendant le direct et le quart d'heure qui le précède, horodaté une fois" do
    now = Time.current
    { { state: "live", started_at: now } => true,
      { starts_at: now + 10.minutes } => true,
      { starts_at: now + 20.minutes } => false,
      { starts_at: now - 4.hours } => false,
      { state: "ended", started_at: now - 2.hours, ended_at: now - 1.hour } => false }.each_with_index do |(attributes, open), index|
      webinar = Webinar.create!(title: "Fenêtre #{index}", starts_at: now, host_sub: "sub-marc", **attributes)
      registration = webinar.registrations.create!(email: "w#{index}@example.org", name: "W")

      assert_equal open, registration.grant_instant_access!(now: now), attributes.inspect
      assert_equal open, registration.reload.instant_access?, attributes.inspect
    end

    live = Webinar.create!(title: "Une fois", starts_at: now, host_sub: "sub-marc", state: "live", started_at: now)
    registration = live.registrations.create!(email: "once@example.org", name: "O")
    registration.grant_instant_access!(now: now - 1.minute)
    registration.grant_instant_access!(now: now)
    assert_in_delta (now - 1.minute).to_f, registration.reload.instant_access_at.to_f, 1
  end

  test "salle : accès par confirmation ou accès immédiat, jamais une fois retiré ; CRM : confirmation seule" do
    pending = Registration.create!(webinar: @webinar, email: "p@example.org", name: "P")
    instant = Registration.create!(webinar: @webinar, email: "i@example.org", name: "I", instant_access_at: Time.current)
    confirmed = Registration.create!(webinar: @webinar, email: "c@example.org", name: "C")
    confirmed.confirm!
    removed = Registration.create!(webinar: @webinar, email: "r@example.org", name: "R", instant_access_at: Time.current)
    removed.remove_from_room!

    assert_equal [ instant, confirmed ].sort, Registration.with_room_access.sort
    assert_equal [ false, true, true, false ], [ pending, instant, confirmed, removed ].map(&:room_access?)
    assert_equal [ confirmed ], Registration.crm_pending.to_a
    assert_not instant.crm_sync_eligible?
    assert_nil instant.crm_enrolled_at
  end

  test "Webinar has_many :registrations avec dependent: restrict_with_exception" do
    r = Registration.create!(webinar: @webinar, email: "marc@example.org", name: "Marc")
    assert_includes @webinar.registrations.reload, r
    assert_raises(ActiveRecord::DeleteRestrictionError) { @webinar.destroy }
  end
end
