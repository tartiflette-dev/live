# frozen_string_literal: true

require "test_helper"

# RecordingSession — cas limites non couvrables via le contrôleur seul
# (échec au niveau `recordings.create!`).
#
# Le test contrôleur `webinar_states_controller_test.rb` couvre déjà les
# chemins nominaux + fail-loud egress ; ici on force un ActiveRecord::
# RecordInvalid pour vérifier que le service renvoie une CreationFailure
# duck-typée et NE laisse PAS remonter l'exception (aucune 500).
class RecordingSessionTest < ActiveSupport::TestCase
  # Relation-like qui lève à create! comme le ferait une contrainte DB
  # inattendue. Volontairement minimaliste : le service ne consomme que
  # `create!(status:, started_at:, path:)`.
  class ThrowingRelation
    def create!(**)
      invalid = Recording.new
      invalid.errors.add(:base, "forced db failure")
      raise ActiveRecord::RecordInvalid.new(invalid)
    end
  end

  # Webinar-like : le service consomme #slug, #room_name, #recordings.
  # Duck-typing suffit — pas de dépendance à la DB pour ce test.
  class FakeWebinar
    def slug;      "fake-slug";       end
    def room_name; "fake-room";       end
    def recordings; ThrowingRelation.new; end
  end

  class StubClient
    attr_reader :calls

    def initialize(start_status: :starting)
      @calls = []
      @start_status = start_status
    end

    def start_room_composite(room_name:, filepath:)
      @calls << [ :start, room_name, filepath ]
      { egress_id: "EG_never_called_expected", status: @start_status, raw: nil }
    end

    # ensure_active appelle
    # reconcile qui consomme list_egress. Défaut :active (no-op).
    def list_egress(egress_id:)
      @calls << [ :list_egress, egress_id ]
      { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
  end

  test "start_composite: RecordInvalid sur create! → CreationFailure (failed? true), aucun appel egress" do
    stub = StubClient.new
    result = RecordingSession.start_composite(FakeWebinar.new, client: stub)

    assert_kind_of RecordingSession::CreationFailure, result
    assert result.failed?, "CreationFailure doit répondre failed? = true"
    assert result.error_message.present?, "error_message présent"
    assert_match(/création Recording refusée/i, result.error_message)
    assert_match(/forced db failure/i,           result.error_message)

    # Court-circuit : si Recording.create! échoue, on n'a rien à
    # démarrer côté egress — le client ne doit pas avoir été appelé.
    assert_empty stub.calls, "aucun appel egress attendu quand create! échoue"
  end

  class StubRoomClient
    def initialize(calls, failure: nil)
      @calls = calls
      @failure = failure
    end

    def create_room(name:)
      @calls << [ :create_room, name ]
      raise @failure if @failure

      { name: name }
    end
  end

  test "start creates the room before requesting egress when nobody has joined" do
    webinar = Webinar.create!(title: "Empty room", starts_at: 1.hour.from_now, host_sub: "host")
    client = StubClient.new
    room_client = StubRoomClient.new(client.calls)

    recording = RecordingSession.start_composite(webinar, client: client, room_client: room_client)

    assert recording.starting?
    assert_equal [ :create_room, webinar.room_name ], client.calls.first
    assert_equal :start, client.calls.second.first
    assert_equal webinar.room_name, client.calls.second[1]
    assert_equal "EG_never_called_expected", recording.egress_id
  end

  test "start_composite: egress déjà ACTIF dans la réponse de start → recording d'emblée" do
    webinar = Webinar.create!(title: "Déjà actif", starts_at: 1.hour.from_now, host_sub: "host")
    client = StubClient.new(start_status: :active)

    recording = RecordingSession.start_composite(webinar, client: client, room_client: StubRoomClient.new(client.calls))

    assert recording.recording?
  end

  # ---- ensure_active ----

  test "ensure_active: retourne l'actif existant sans démarrer un nouveau composite" do
    webinar = Webinar.create!(title: "déjà en cours", starts_at: 1.hour.from_now, host_sub: "host")
    existing = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_existing")

    client = StubClient.new
    room_client = StubRoomClient.new(client.calls)

    result = RecordingSession.ensure_active(webinar, client: client, room_client: room_client)

    assert_equal existing.id, result.id
    # reconcile appelle list_egress :
    # OK, mais AUCUN start_room_composite ne doit avoir été invoqué.
    refute(client.calls.any? { |c| c[0] == :start },
           "aucun start egress attendu quand un actif existe déjà ; calls=#{client.calls.inspect}")
  end

  test "ensure_active: démarre un nouveau Recording quand aucun actif" do
    webinar = Webinar.create!(title: "à démarrer", starts_at: 1.hour.from_now, host_sub: "host")
    client = StubClient.new
    room_client = StubRoomClient.new(client.calls)

    result = RecordingSession.ensure_active(webinar, client: client, room_client: room_client)

    assert result.persisted?
    assert result.starting?, "attendu :starting (egress pas encore actif), vu :#{result.status}"
    assert_equal 1, webinar.recordings.active.count
  end

  test "ensure_active: idempotent sur deux appels séquentiels (reload/2 onglets)" do
    webinar = Webinar.create!(title: "double clic", starts_at: 1.hour.from_now, host_sub: "host")
    client = StubClient.new
    room_client = StubRoomClient.new(client.calls)

    r1 = RecordingSession.ensure_active(webinar, client: client, room_client: room_client)
    r2 = RecordingSession.ensure_active(webinar, client: client, room_client: room_client)

    assert_equal r1.id, r2.id, "le 2e appel doit retourner le 1er, pas un doublon"
    assert_equal 1, webinar.recordings.active.count, "un seul actif attendu"
  end

  # Le comportement race RecordNotUnique est désormais testé au niveau
  # de start_composite (cf. plus bas
  # « start_composite: race RecordNotUnique → retourne l'actif existant »).
  # ensure_active hérite naturellement de la garantie sans double rescue.

  # ---- reconcile ----
  #
  # Un egress peut se terminer côté livekit-server (« Source closed » —
  # départ hôte + departure_timeout room) alors que le Recording reste
  # `recording` en DB. L'auto-start suivant voit alors un actif fantôme et
  # se tait ; le voyant REC UI ment. Ces tests attestent la convergence
  # DB → réel.

  # Stub list_egress uniquement (autres méthodes non consommées ici).
  class ListEgressStub
    def initialize(mapping = {})
      @mapping = mapping # egress_id → payload | :not_found | Exception
      @calls = []
    end

    attr_reader :calls

    def list_egress(egress_id:)
      @calls << [ :list_egress, egress_id ]
      entry = @mapping[egress_id]
      raise entry if entry.is_a?(Exception)
      return nil  if entry == :not_found
      entry
    end
  end

  test "reconcile: egress :complete côté serveur → Recording done + ended_at" do
    webinar = Webinar.create!(title: "cafe-ia-1", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_done",
                             started_at: 5.minutes.ago)
    client = ListEgressStub.new("EG_done" => { egress_id: "EG_done", status: :complete, ended_at: 1_690_000_000_000, error: nil, raw: nil })

    transitioned = RecordingSession.reconcile(webinar, client: client)
    assert_equal 1, transitioned
    rec.reload
    assert_equal "done", rec.status
    assert_not_nil rec.ended_at
  end

  test "reconcile: piste :complete côté serveur → stopping, done réservé au webhook (fichier vérifié)" do
    webinar = Webinar.create!(title: "w-track", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, kind: "track", status: "recording", egress_id: "EG_tr",
                            track_sid: "TR_1", participant_identity: "speaker-1", track_source: "camera",
                            output_prefix: "#{webinar.slug}/p", started_at: 5.minutes.ago)
    client = ListEgressStub.new("EG_tr" => { egress_id: "EG_tr", status: :complete, ended_at: 1, error: nil, raw: nil })

    assert_equal 1, RecordingSession.reconcile(webinar, client: client)
    assert_equal "stopping", rec.reload.status
    assert_nil rec.path
    assert_equal 0, RecordingSession.reconcile(webinar, client: client)

    FinalizeEgressJob.perform_now("egress_id" => "EG_tr", "room_name" => webinar.room_name,
      "status" => "EGRESS_COMPLETE", "file_results" => [ { "filename" => "/data/#{webinar.slug}/p.webm" } ])
    assert_equal [ "done", "#{webinar.slug}/p.webm" ], [ rec.reload.status, rec.path ]
  end

  test "reconcile: egress :failed côté serveur → Recording failed + error_message capté" do
    webinar = Webinar.create!(title: "w-failed", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_ko",
                             started_at: 1.minute.ago)
    client = ListEgressStub.new("EG_ko" => { egress_id: "EG_ko", status: :failed, ended_at: 1_690_000_000_000, error: "Source closed", raw: nil })

    RecordingSession.reconcile(webinar, client: client)
    rec.reload
    assert_equal "failed", rec.status
    assert_match(/Source closed/, rec.error_message)
    assert_not_nil rec.ended_at
  end

  test "reconcile: egress :aborted → Recording failed avec message par défaut si error vide" do
    webinar = Webinar.create!(title: "w-aborted", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_ab", started_at: 1.minute.ago)
    client = ListEgressStub.new("EG_ab" => { egress_id: "EG_ab", status: :aborted, ended_at: 1_690_000_000_000, error: nil, raw: nil })

    RecordingSession.reconcile(webinar, client: client)
    rec.reload
    assert_equal "failed", rec.status
    assert_match(/aborted/i, rec.error_message)
  end

  test "reconcile: egress inconnu (nil) → Recording failed avec message explicite" do
    webinar = Webinar.create!(title: "w-gc", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_gc_gone", started_at: 1.hour.ago)
    client = ListEgressStub.new("EG_gc_gone" => :not_found)

    RecordingSession.reconcile(webinar, client: client)
    rec.reload
    assert_equal "failed", rec.status
    assert_match(/introuvable/i, rec.error_message)
  end

  test "reconcile: egress :active ou :starting → Recording INCHANGÉ" do
    webinar = Webinar.create!(title: "w-active", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_live", started_at: 1.minute.ago)
    client = ListEgressStub.new("EG_live" => { egress_id: "EG_live", status: :active, ended_at: 0, error: nil, raw: nil })

    transitioned = RecordingSession.reconcile(webinar, client: client)
    assert_equal 0, transitioned
    assert_equal "recording", rec.reload.status
  end

  # La scène n'affiche « REC » qu'une fois
  # l'egress ACTIF ; tant que livekit dit STARTING, le composite reste
  # `starting` (constat en direct : 15 s de faux « REC » avant chaque abort).
  test "reconcile: composite starting + egress :active → recording" do
    webinar = Webinar.create!(title: "w-promote", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "starting", egress_id: "EG_up", started_at: 3.seconds.ago)
    client = ListEgressStub.new("EG_up" => { egress_id: "EG_up", status: :active, ended_at: 0, error: nil, raw: nil })

    assert_equal 1, RecordingSession.reconcile(webinar, client: client)
    assert_equal "recording", rec.reload.status
  end

  test "reconcile: composite starting + egress :starting → reste starting" do
    webinar = Webinar.create!(title: "w-wait", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "starting", egress_id: "EG_wait", started_at: 3.seconds.ago)
    client = ListEgressStub.new("EG_wait" => { egress_id: "EG_wait", status: :starting, ended_at: 0, error: nil, raw: nil })

    assert_equal 0, RecordingSession.reconcile(webinar, client: client)
    assert_equal "starting", rec.reload.status
  end

  test "reconcile: démarrage sans egress_id depuis plus de 2 min → failed (jamais « Démarrage… » à vie)" do
    webinar = Webinar.create!(title: "w-orphan", starts_at: 1.hour.from_now, host_sub: "host")
    orphan = Recording.create!(webinar: webinar, status: "starting", started_at: 3.minutes.ago)
    client = ListEgressStub.new

    assert_equal 1, RecordingSession.reconcile(webinar, client: client)
    orphan.reload
    assert_equal "failed", orphan.status
    assert_match(/sans réponse/, orphan.error_message)
    assert_not_nil orphan.ended_at
    assert_empty client.calls, "aucun list_egress sans egress_id"
  end

  test "reconcile: piste restée starting sans egress_id (job tué) → failed après 2 min" do
    webinar = Webinar.create!(title: "w-track-orphan", starts_at: 1.hour.from_now, host_sub: "host")
    track = Recording.create!(webinar: webinar, kind: "track", status: "starting", track_sid: "TR_orphan",
                              participant_identity: "speaker-1", track_source: "camera",
                              output_prefix: "#{webinar.slug}/orphan", started_at: 5.minutes.ago)

    assert_equal 1, RecordingSession.reconcile(webinar, client: ListEgressStub.new)
    assert_equal "failed", track.reload.status
  end

  test "reconcile: egress ACTIF mais composite déjà en arrêt → pas réécrit en recording" do
    webinar = Webinar.create!(title: "w-race", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "starting", egress_id: "EG_race", started_at: 3.seconds.ago)
    stale = Recording.find(rec.id)
    rec.update!(status: :stopping)

    RecordingSession.reconcile_recording(stale, client: ListEgressStub.new(
      "EG_race" => { egress_id: "EG_race", status: :active, ended_at: 0, error: nil, raw: nil }
    ))

    assert_equal "stopping", rec.reload.status
  end

  test "reconcile: montage participant en cours (sans egress par nature) → jamais expiré" do
    webinar = Webinar.create!(title: "w-mux", starts_at: 1.hour.from_now, host_sub: "host")
    mux = Recording.create!(webinar: webinar, kind: "participant", status: "starting",
                            participant_identity: "speaker-1", started_at: 10.minutes.ago)

    assert_equal 0, RecordingSession.reconcile(webinar, client: ListEgressStub.new)
    assert_equal "starting", mux.reload.status
  end

  test "reconcile: erreur réseau/twirp → log warning + Recording laissé en l'état (fail-safe)" do
    webinar = Webinar.create!(title: "w-net", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_net", started_at: 1.minute.ago)
    client = ListEgressStub.new("EG_net" => EgressClient::RemoteError.new("egress injoignable"))

    transitioned = RecordingSession.reconcile(webinar, client: client)
    assert_equal 0, transitioned
    # Recording INCHANGÉ — jamais corrompre l'état sur une panne
    # transitoire (la prochaine réconciliation retentera).
    assert_equal "recording", rec.reload.status
  end

  test "reconcile: no-op quand aucun Recording actif" do
    webinar = Webinar.create!(title: "w-vide", starts_at: 1.hour.from_now, host_sub: "host")
    client = ListEgressStub.new
    assert_equal 0, RecordingSession.reconcile(webinar, client: client)
    assert_empty client.calls
  end

  test "reconcile: n'appelle PAS list_egress sur un Recording sans egress_id (starting sans réponse)" do
    webinar = Webinar.create!(title: "w-nogress", starts_at: 1.hour.from_now, host_sub: "host")
    rec = Recording.create!(webinar: webinar, status: "starting", started_at: 1.second.ago) # egress_id nil
    client = ListEgressStub.new
    RecordingSession.reconcile(webinar, client: client)
    assert_empty client.calls, "aucun list_egress sans egress_id"
    assert_equal "starting", rec.reload.status, "démarrage récent : la requête peut encore répondre"
  end

  # ---- ensure_active × reconcile — scénario du direct lancé sans egress ----

  # Stub combinant list_egress (pour reconcile) + start_room_composite
  # (pour le redémarrage). Défini AU NIVEAU CLASSE — pas dans un `test`
  # (Ruby : `class` dans une méthode redéfinit la constante à chaque
  # invocation, warnings + partagé entre workers parallélisés).
  class ReconcileThenStartStub
    attr_reader :calls
    def initialize(reconcile_status:, new_egress_id: "EG_new")
      @reconcile_status = reconcile_status
      @new_egress_id    = new_egress_id
      @calls = []
    end
    def list_egress(egress_id:)
      @calls << [ :list_egress, egress_id ]
      { egress_id: egress_id, status: @reconcile_status, ended_at: 1_690_000_000_000, error: "Source closed", raw: nil }
    end
    def start_room_composite(room_name:, filepath:)
      @calls << [ :start_room_composite, room_name, filepath ]
      { egress_id: @new_egress_id, status: :starting, raw: nil }
    end
  end

  test "ensure_active: reliquat DB `recording` + egress complete côté serveur → recycle et redémarre" do
    webinar = Webinar.create!(title: "cafe-ia-1", starts_at: 1.hour.from_now, host_sub: "host")
    stale = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_stale", started_at: 30.minutes.ago)

    client      = ReconcileThenStartStub.new(reconcile_status: :complete)
    room_client = StubRoomClient.new(client.calls)

    fresh = RecordingSession.ensure_active(webinar, client: client, room_client: room_client)

    # Le vieux Recording a été transitionné à `done`, un nouveau a été
    # démarré côté egress et posé en `starting` (egress pas encore actif).
    assert_equal "done", stale.reload.status
    assert fresh.starting?
    assert_equal "EG_new", fresh.egress_id
    assert(client.calls.any? { |c| c[0] == :list_egress && c[1] == "EG_stale" })
    assert(client.calls.any? { |c| c[0] == :start_room_composite })
  end

  # ---- Race sur start_composite et garde d'état ----

  test "start_composite: race RecordNotUnique → retourne l'actif existant (jamais 500)" do
    # Bloquant #3 : la garde RecordNotUnique doit vivre DANS start_composite
    # pour que TOUS les callers (ensure_active, RecordingsController#create,
    # WebinarStatesController#go_live) soient protégés du 500 sur race.
    webinar = Webinar.create!(title: "race", starts_at: 1.hour.from_now, host_sub: "host")
    winner  = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_winner")

    client = StubClient.new
    room_client = StubRoomClient.new(client.calls)

    # On force `create!` à lever RecordNotUnique (mimique de la course DB).
    webinar.recordings.define_singleton_method(:create!) do |*|
      raise ActiveRecord::RecordNotUnique.new("SQLite: partial unique index violation")
    end

    result = RecordingSession.start_composite(webinar, client: client, room_client: room_client)
    assert_equal winner.id, result.id, "start_composite doit retourner l'actif existant sur RecordNotUnique"
    assert_empty client.calls, "egress ne doit pas être appelé quand start est court-circuité"
  end

  test "ensure_active: state=ended → nil (aucun démarrage), mais reconcile est appliqué" do
    # Bloquant #4 : pas d'auto-start sur un webinaire ended (direct clos).
    # Une réconciliation reste utile (fermer un reliquat), mais on ne crée
    # PAS de nouveau Recording.
    webinar = Webinar.create!(title: "clôturé", starts_at: 2.hours.ago, host_sub: "host",
                              state: "ended", started_at: 90.minutes.ago, ended_at: 30.minutes.ago)
    stale = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_stale_ended",
                              started_at: 90.minutes.ago)

    client = ReconcileThenStartStub.new(reconcile_status: :complete)
    room_client = StubRoomClient.new(client.calls)

    result = RecordingSession.ensure_active(webinar, client: client, room_client: room_client)
    assert_nil result, "aucun Recording nouveau ni existant retourné sur state=ended"
    assert_equal "done", stale.reload.status, "reconcile doit AVOIR tourné (reliquat fermé)"
    refute(client.calls.any? { |c| c[0] == :start_room_composite },
           "aucun start egress attendu sur state=ended")
  end

  test "ensure_active: state=draft → auto-start AUTORISÉ (un direct a déjà été animé en draft)" do
    # Justification : draft NE bloque PAS. Contre-exemple en production :
    # webinaire animé alors qu'il était encore
    # techniquement en draft (visibility=published mais state=draft avant
    # go_live). L'auto-start doit fonctionner.
    webinar = Webinar.create!(title: "cafe-ia-1", starts_at: 1.hour.from_now, host_sub: "host")
    assert_equal "draft", webinar.state
    client = StubClient.new
    room_client = StubRoomClient.new(client.calls)

    result = RecordingSession.ensure_active(webinar, client: client, room_client: room_client)
    assert result, "auto-start doit fonctionner en draft"
    assert result.starting?
  end

  test "ensure_active: state=live → auto-start AUTORISÉ (nominal)" do
    webinar = Webinar.create!(title: "live-webinar", starts_at: 1.minute.ago, host_sub: "host",
                              state: "live", started_at: 30.seconds.ago)
    client = StubClient.new
    room_client = StubRoomClient.new(client.calls)

    result = RecordingSession.ensure_active(webinar, client: client, room_client: room_client)
    assert result.starting?
  end

  test "room failure is persisted and prevents egress from starting" do
    webinar = Webinar.create!(title: "Unavailable room", starts_at: 1.hour.from_now, host_sub: "host")
    client = StubClient.new
    room_client = StubRoomClient.new(client.calls, failure: RoomServiceClient::RemoteError.new("room unavailable"))

    recording = RecordingSession.start_composite(webinar, client: client, room_client: room_client)

    assert recording.failed?
    assert_equal "room unavailable", recording.error_message
    assert recording.ended_at
    assert_equal [ [ :create_room, webinar.room_name ] ], client.calls
  end

  # ---- Rien ne capte après la fin du direct ----

  # Stub complet (start, stop, list_egress) qui peut terminer le direct au
  # moment de l'appel distant, comme une fin concurrente d'un auto-démarrage.
  class EndRaceStub
    attr_reader :calls

    def initialize(on_start: nil)
      @calls = []
      @on_start = on_start
    end

    def start_room_composite(room_name:, filepath:)
      @calls << [ :start ]
      @on_start&.call
      { egress_id: "EG_late", status: :active, raw: nil }
    end

    def stop(egress_id:)
      @calls << [ :stop, egress_id ]
      { egress_id: egress_id, status: :ending, raw: nil }
    end

    def list_egress(egress_id:)
      { egress_id: egress_id, status: :active, ended_at: 0, error: nil, raw: nil }
    end
  end

  test "reconcile: webinaire terminé → tout Recording encore en captation est arrêté" do
    webinar = Webinar.create!(title: "Café IA #7", starts_at: 2.hours.ago, host_sub: "host",
                              state: "ended", started_at: 1.hour.ago, ended_at: 1.minute.ago)
    composite = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_relaunched", started_at: 2.minutes.ago)
    track = Recording.create!(webinar: webinar, kind: "track", status: "recording", egress_id: "EG_track",
                              track_sid: "TR_relaunched", participant_identity: "host-marc", track_source: "camera",
                              started_at: 2.minutes.ago)
    client = EndRaceStub.new

    assert_error_reported(RecordingSession::CapturingAfterEnd) do
      assert_equal 2, RecordingSession.reconcile(webinar, client: client)
    end

    assert_equal "done", composite.reload.status
    assert_equal "stopping", track.reload.status, "une piste ne passe done qu'au webhook egress_ended"
    assert_equal [ [ :stop, "EG_relaunched" ], [ :stop, "EG_track" ] ], client.calls.select { |c| c[0] == :stop }.sort
    assert_equal 0, RecordingSession.reconcile(webinar, client: client), "rien de plus à arrêter"
  end

  test "reconcile: direct en cours → les enregistrements actifs continuent" do
    webinar = Webinar.create!(title: "En cours", starts_at: 1.hour.ago, host_sub: "host", state: "live", started_at: 1.hour.ago)
    composite = Recording.create!(webinar: webinar, status: "recording", egress_id: "EG_live", started_at: 1.hour.ago)
    client = EndRaceStub.new

    assert_no_error_reported { RecordingSession.reconcile(webinar, client: client) }

    assert_equal "recording", composite.reload.status
    assert_empty client.calls.select { |c| c[0] == :stop }
  end

  test "reconcile: piste séparée d'une personne sans accord à l'image en cours → arrêtée, direct en cours" do
    webinar = Webinar.create!(title: "En cours", starts_at: 1.hour.ago, host_sub: "host", state: "live", started_at: 1.hour.ago)
    consenting, withdrawn = %w[Basile Inès].map { |name| webinar.speakers.create!(name: name) }
    ParticipantConsent.grant!(consenting, recording: true, excerpts: false, adult: true)
    ParticipantConsent.grant!(withdrawn, recording: true, excerpts: false, adult: true).withdraw!
    kept, stopped, host = [ [ consenting, "speaker-#{consenting.id}" ], [ withdrawn, "speaker-#{withdrawn.id}" ],
                           [ nil, "host-host" ] ].map do |_, identity|
      Recording.create!(webinar: webinar, kind: "track", status: "recording", egress_id: "EG_#{identity}",
                        track_sid: "TR_#{identity}", participant_identity: identity, track_source: "camera",
                        started_at: 1.minute.ago)
    end
    client = EndRaceStub.new

    assert_equal 1, RecordingSession.reconcile(webinar, client: client)

    assert_equal [ "recording", "stopping", "recording" ], [ kept, stopped, host ].map { |rec| rec.reload.status }
    assert_equal [ [ :stop, "EG_speaker-#{withdrawn.id}" ] ], client.calls.select { |c| c[0] == :stop }
  end

  test "stop_all et réconciliation d'un direct terminé laissent finir un montage participant" do
    webinar = Webinar.create!(title: "Repris", starts_at: 2.hours.ago, host_sub: "host", state: "ended",
                              started_at: 2.hours.ago, ended_at: 1.minute.ago)
    mux = Recording.create!(webinar: webinar, kind: "participant", status: "starting", participant_identity: "speaker-9",
                            started_at: 1.minute.ago)
    client = EndRaceStub.new

    assert_empty RecordingSession.stop_all(webinar, client: client)
    RecordingSession.reconcile(webinar, client: client)

    assert_equal "starting", mux.reload.status
  end

  test "start_composite: direct terminé pendant l'appel distant → l'egress lancé est arrêté aussitôt" do
    webinar = Webinar.create!(title: "Rechargée", starts_at: 1.hour.ago, host_sub: "host", state: "live", started_at: 1.hour.ago)
    client = EndRaceStub.new(on_start: -> { Webinar.where(id: webinar.id).update_all(state: "ended", ended_at: Time.current) })

    recording = RecordingSession.start_composite(webinar, client: client, room_client: StubRoomClient.new(client.calls))

    assert_equal "done", recording.reload.status
    assert_includes client.calls, [ :stop, "EG_late" ]
  end
end
