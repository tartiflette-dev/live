# frozen_string_literal: true

require "test_helper"

# Webhook : seules les pistes de
# l'animateur et des intervenants nominatifs ACTIFS d'un webinaire live
# déclenchent un egress ; tout le reste répond sans rien lancer.
class Webhooks::LivekitControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include LivekitWebhookSigning

  setup do
    @env_backup = ENV.to_h.slice("LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "TRACK_EGRESS_ENABLED")
    ENV["LIVEKIT_API_KEY"] = WEBHOOK_KEY
    ENV["LIVEKIT_API_SECRET"] = WEBHOOK_SECRET
    ENV["TRACK_EGRESS_ENABLED"] = "true"

    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.hour.ago, host_sub: "sub-marc")
    @webinar.update!(state: "live", started_at: 1.minute.ago)
    @speaker = @webinar.speakers.create!(name: "Basile")
    ParticipantConsent.grant!(@speaker, recording: true, excerpts: false, adult: true)
  end

  teardown do
    %w[LIVEKIT_API_KEY LIVEKIT_API_SECRET TRACK_EGRESS_ENABLED].each { |k| ENV[k] = @env_backup[k] }
  end

  def deliver(body, authorization: signed_authorization(body))
    post "/webhooks/livekit", params: body,
      headers: { "Content-Type" => "application/webhook+json", "Authorization" => authorization }
  end

  def track_published(identity, sid: "TR_cam1", source: :CAMERA, room: @webinar.room_name)
    webhook_body(event: "track_published", room: room, identity: identity, track_sid: sid, source: source)
  end

  test "piste de l'animateur sur un webinaire live → job d'egress, 204" do
    assert_enqueued_with(job: StartTrackEgressJob, args: [ @webinar.id, "TR_cam1", "host-sub-marc", "camera" ]) do
      deliver(track_published("host-sub-marc"))
    end
    assert_response :no_content
  end

  test "piste d'un intervenant nominatif actif → job d'egress" do
    assert_enqueued_with(job: StartTrackEgressJob, args: [ @webinar.id, "TR_mic", "speaker-#{@speaker.id}", "microphone" ]) do
      deliver(track_published("speaker-#{@speaker.id}", sid: "TR_mic", source: :MICROPHONE))
    end
  end

  test "spectateur inscrit qui publie (main levée accordée) → job d'egress" do
    inscrit = @webinar.registrations.create!(name: "Inès", email: "ines@example.com", confirmed_at: Time.current)
    ParticipantConsent.grant!(inscrit, recording: true, excerpts: false, adult: true)
    assert_enqueued_with(job: StartTrackEgressJob, args: [ @webinar.id, "TR_cam1", "viewer-#{inscrit.id}", "camera" ]) do
      deliver(track_published("viewer-#{inscrit.id}"))
    end
  end

  test "intervenant sans accord à l'image → aucun job, et il n'est pas expulsé à son arrivée" do
    newcomer = @webinar.speakers.create!(name: "Mathilde")
    assert_no_enqueued_jobs only: StartTrackEgressJob do
      deliver(track_published("speaker-#{newcomer.id}"))
    end
    assert_response :no_content
    assert TrackRecordingSession.authorized?(@webinar, "speaker-#{newcomer.id}"),
           "la garde participant_joined ne doit pas expulser qui n'a pas encore donné son accord"
  end

  test "spectateur inconnu, intervenant révoqué, legacy ou d'un autre webinaire → rien" do
    other = Webinar.create!(title: "Autre", starts_at: 1.hour.ago, host_sub: "sub-eve")
    foreign = other.speakers.create!(name: "Eve")
    revoked = @webinar.speakers.create!(name: "Parti")
    revoked.revoke!

    [ "viewer-999999", "speaker-#{revoked.id}", "speaker-legacy-abc", "speaker-#{foreign.id}", "host-sub-eve" ].each do |identity|
      assert_no_enqueued_jobs(only: StartTrackEgressJob) { deliver(track_published(identity)) }
      assert_response :no_content
    end
  end

  test "webinaire hors direct ou room inconnue → rien" do
    @webinar.update!(state: "ended", ended_at: Time.current)
    assert_no_enqueued_jobs(only: StartTrackEgressJob) { deliver(track_published("host-sub-marc")) }
    assert_no_enqueued_jobs(only: StartTrackEgressJob) { deliver(track_published("host-sub-marc", room: "inconnue")) }
  end

  # Cas réel : track_published en draft SANS composite
  # → rien (pas de fenêtre) ; en draft AVEC composite actif → enqueue.
  test "track_published en draft sans composite → rien enqueué" do
    @webinar.update!(state: "draft", started_at: nil, ended_at: nil)
    assert_no_enqueued_jobs(only: StartTrackEgressJob) { deliver(track_published("host-sub-marc")) }
    assert_response :no_content
  end

  test "track_published en draft AVEC composite actif → enqueue (fenêtre composite seule)" do
    @webinar.update!(state: "draft", started_at: nil, ended_at: nil)
    @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_comp", started_at: Time.current)
    assert_enqueued_with(job: StartTrackEgressJob, args: [ @webinar.id, "TR_cam1", "host-sub-marc", "camera" ]) do
      deliver(track_published("host-sub-marc"))
    end
  end

  # Borne d'âge sur le composite. Un
  # fantôme (recording depuis > RECORDING_WINDOW_MAX_HOURS) ne doit
  # PAS ouvrir la fenêtre, et doit être marqué failed + cascader.
  test "track_published : composite fantôme > borne → aucun job, composite failed" do
    @webinar.update!(state: "draft", started_at: nil, ended_at: nil)
    stale = @webinar.recordings.create!(kind: "composite", status: "recording", egress_id: "EG_stale",
                                         started_at: 5.hours.ago)
    assert_no_enqueued_jobs(only: StartTrackEgressJob) { deliver(track_published("host-sub-marc")) }
    assert_response :no_content
    assert_equal "failed", stale.reload.status
    assert_match(/dépassement de durée max/, stale.error_message)
  end

  # Non-régression : webinaire ended/completed
  # sans composite → aucun job (fenêtre fermée côté live? ET côté
  # composite).
  test "track_published : webinaire ended sans composite → aucun job" do
    @webinar.update!(state: "ended", ended_at: Time.current)
    assert_no_enqueued_jobs(only: StartTrackEgressJob) { deliver(track_published("host-sub-marc")) }
    assert_response :no_content
  end

  test "drapeau TRACK_EGRESS_ENABLED absent → rien" do
    ENV["TRACK_EGRESS_ENABLED"] = nil
    assert_no_enqueued_jobs(only: StartTrackEgressJob) { deliver(track_published("host-sub-marc")) }
    assert_response :no_content
  end

  test "signature invalide → 401, aucun job" do
    body = track_published("host-sub-marc")
    assert_no_enqueued_jobs { deliver(body, authorization: signed_authorization(body, secret: "x" * 40)) }
    assert_response :unauthorized
  end

  test "corps signé illisible → 400, jamais 500" do
    deliver("{oops")
    assert_response :bad_request
  end

  test "corps > 1 Mio → 413" do
    deliver("x" * (1.megabyte + 1), authorization: "Bearer x")
    assert_response :content_too_large
  end

  test "egress_updated → job d'activation, avec l'horodatage du passage ACTIVE" do
    info = LiveKit::Proto::EgressInfo.new(egress_id: "EG_1", room_name: @webinar.room_name, status: :EGRESS_ACTIVE,
                                          updated_at: 1_793_781_217_172_051_234)
    assert_enqueued_with(job: EgressActivationJob,
                         args: ->(args) { args.first.values_at("status", "updated_at") == %w[EGRESS_ACTIVE 1793781217172051234] }) do
      deliver(webhook_body(event: "egress_updated", egress_info: info))
    end
    assert_response :no_content
  end

  test "egress_ended → job de clôture" do
    info = LiveKit::Proto::EgressInfo.new(egress_id: "EG_1", room_name: @webinar.room_name, status: :EGRESS_COMPLETE)
    assert_enqueued_with(job: FinalizeEgressJob) do
      deliver(webhook_body(event: "egress_ended", egress_info: info))
    end
    assert_response :no_content
  end

  # ---- Garde participant_joined (sécurité) ----

  class FakeRoomServiceEnforcer
    attr_reader :removed, :permissions
    def initialize(raise_on_remove: nil, raise_on_update: nil)
      @raise = raise_on_remove
      @raise_on_update = raise_on_update
      @removed = []
      @permissions = []
    end
    def remove_participant(room:, identity:)
      @removed << [ room, identity ]
      raise @raise if @raise
    end
    def update_participant(room:, identity:, can_publish:, sources: [])
      raise @raise_on_update if @raise_on_update

      @permissions << [ identity, can_publish, sources ]
      {}
    end
  end

  def stub_room_service(**opts)
    @prev_room = Rails.configuration.x.room_service_client_factory
    fake = FakeRoomServiceEnforcer.new(**opts)
    Rails.configuration.x.room_service_client_factory = -> { fake }
    fake
  end

  def restore_room_service
    Rails.configuration.x.room_service_client_factory = @prev_room if @prev_room
  end

  def joined_body(identity:, room: @webinar.room_name, kind: nil, can_publish: false)
    webhook_body(event: "participant_joined", room: room, identity: identity, kind: kind, can_publish: can_publish)
  end

  test "participant_joined expulse une identite host-sub inconnue" do
    fake = stub_room_service
    deliver(joined_body(identity: "host-sub-fantome"))
    assert_response :no_content
    assert_equal 1, fake.removed.size
    assert_equal @webinar.room_name, fake.removed.first.first
    assert_equal "host-sub-fantome", fake.removed.first.last
  ensure
    restore_room_service
  end

  test "participant_joined n_expulse_pas_le_proprietaire" do
    fake = stub_room_service
    deliver(joined_body(identity: "host-#{@webinar.host_sub}"))
    assert_response :no_content
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  test "participant_joined autorisé : le transcripteur est vérifié (salle recréée), jamais pour un direct terminé ni un expulsé" do
    stub_room_service
    deliver(joined_body(identity: "host-#{@webinar.host_sub}"))
    deliver(joined_body(identity: "host-sub-fantome"))
    assert_equal [ @webinar.id ], enqueued_jobs.select { |job| job["job_class"] == "TranscriberPresenceJob" }.map { |job| job["arguments"].first }

    clear_enqueued_jobs
    @webinar.update!(state: "ended", started_at: 1.hour.ago, ended_at: 1.minute.ago)
    deliver(joined_body(identity: "host-#{@webinar.host_sub}"))
    assert_empty enqueued_jobs.select { |job| job["job_class"] == "TranscriberPresenceJob" }
  ensure
    restore_room_service
  end

  test "participant_joined note la première arrivée d'un inscrit, jamais celle d'un expulsé" do
    stub_room_service
    viewer = @webinar.registrations.create!(name: "Ana", email: "ana@example.test", confirmed_at: 1.day.ago)
    stranger = @webinar.registrations.create!(name: "Non confirmé", email: "nc@example.test")

    deliver(joined_body(identity: "viewer-#{viewer.id}"))
    deliver(joined_body(identity: "viewer-#{stranger.id}"))
    first = viewer.reload.room_joined_at
    travel 5.minutes do
      deliver(joined_body(identity: "viewer-#{viewer.id}"))
    end

    assert_not_nil first
    assert_equal first, viewer.reload.room_joined_at
    assert_nil stranger.reload.room_joined_at
  ensure
    restore_room_service
  end

  test "participant_joined : la base refuse la note d'arrivée → publication fermée quand même, 204" do
    fake = stub_room_service
    newcomer = @webinar.speakers.create!(name: "Mathilde")
    original = RoomAttendance.method(:note_arrival)
    RoomAttendance.define_singleton_method(:note_arrival) do |*|
      raise ActiveRecord::StatementInvalid, "SQLite3::BusyException: database is locked"
    end

    begin
      deliver(joined_body(identity: "speaker-#{newcomer.id}", can_publish: true))
    ensure
      RoomAttendance.define_singleton_method(:note_arrival, original)
    end

    assert_response :no_content
    assert_equal [ [ "speaker-#{newcomer.id}", false, [] ] ], fake.permissions
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  test "participant_joined n_expulse_pas_un_speaker_actif" do
    fake = stub_room_service
    deliver(joined_body(identity: "speaker-#{@speaker.id}"))
    assert_response :no_content
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  # ---- Accord à l'image : la permission du jeton remise d'accord à l'arrivée ----

  test "participant_joined : jeton qui publie sans accord en cours → publication fermée, pas d'expulsion" do
    fake = stub_room_service
    newcomer = @webinar.speakers.create!(name: "Mathilde")

    deliver(joined_body(identity: "speaker-#{newcomer.id}", can_publish: true))

    assert_response :no_content
    assert_empty fake.removed
    assert_equal [ [ "speaker-#{newcomer.id}", false, [] ] ], fake.permissions
  ensure
    restore_room_service
  end

  test "participant_joined : LiveKit ne répond pas à la fermeture → nouvel essai en file, pas d'expulsion" do
    stub_room_service(raise_on_update: RoomServiceClient::Error.new("livekit hors ligne (test)"))
    newcomer = @webinar.speakers.create!(name: "Mathilde")

    assert_enqueued_with(job: PublishingRevocationJob, args: [ @webinar, newcomer ]) do
      deliver(joined_body(identity: "speaker-#{newcomer.id}", can_publish: true))
    end
    assert_response :no_content
  ensure
    restore_room_service
  end

  test "participant_joined : LiveKit ne répond pas à une ouverture → aucun job de retrait" do
    stub_room_service(raise_on_update: RoomServiceClient::Error.new("livekit hors ligne (test)"))

    assert_no_enqueued_jobs(only: PublishingRevocationJob) { deliver(joined_body(identity: "speaker-#{@speaker.id}")) }
  ensure
    restore_room_service
  end

  test "participant_joined : accord donné avant l'arrivée, jeton sans publication → ouverte, sources limitées" do
    fake = stub_room_service

    deliver(joined_body(identity: "speaker-#{@speaker.id}"))

    assert_equal [ [ "speaker-#{@speaker.id}", true, PublishPermission::SOURCES ] ], fake.permissions
  ensure
    restore_room_service
  end

  test "participant_joined : permission déjà conforme, ou animation de droit → rien n'est demandé à LiveKit" do
    fake = stub_room_service

    deliver(joined_body(identity: "speaker-#{@speaker.id}", can_publish: true))
    deliver(joined_body(identity: "host-#{@webinar.host_sub}", can_publish: true))
    deliver(joined_body(identity: "viewer-#{@webinar.registrations.create!(name: 'Inès', email: 'ines@example.com', confirmed_at: Time.current).id}"))

    assert_empty fake.permissions
  ensure
    restore_room_service
  end

  test "participant_joined expulse l'ancienne identité après régénération, pas la nouvelle" do
    fake = stub_room_service
    successor = @speaker.replace!
    deliver(joined_body(identity: "speaker-#{@speaker.id}"))
    deliver(joined_body(identity: "speaker-#{successor.id}"))
    assert_response :no_content
    assert_equal [ [ @webinar.room_name, "speaker-#{@speaker.id}" ] ], fake.removed
    assert_not_includes fake.removed.map(&:last), "speaker-#{successor.id}"
  ensure
    restore_room_service
  end

  test "participant_joined expulse un speaker_revoked" do
    fake = stub_room_service
    @speaker.revoke!
    deliver(joined_body(identity: "speaker-#{@speaker.id}"))
    assert_response :no_content
    assert_equal 1, fake.removed.size
    assert_equal "speaker-#{@speaker.id}", fake.removed.first.last
  ensure
    restore_room_service
  end

  test "participant_joined expulse un viewer non inscrit confirme" do
    fake = stub_room_service
    deliver(joined_body(identity: "viewer-99999"))
    assert_response :no_content
    assert_equal "viewer-99999", fake.removed.first.last
  ensure
    restore_room_service
  end

  test "participant_joined n_expulse_pas_un_viewer_inscrit_confirme" do
    # Un spectateur dont l'inscription est confirmée doit être laissé
    # tranquille (prise de parole admise via main levée — identité
    # `viewer-<registration.id>`).
    confirmed = @webinar.registrations.create!(
      email: "spec@example.net", name: "Spec",
      confirmed_at: Time.current, paid_confirmed_at: Time.current
    )
    fake = stub_room_service
    deliver(joined_body(identity: "viewer-#{confirmed.id}"))
    assert_response :no_content
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  # Retiré depuis la régie, il revient avec un jeton
  # émis avant le retrait (TTL encore valide) → expulsé à nouveau, et ses
  # pistes ne sont plus enregistrées.
  test "participant_joined expulse un viewer retire de la salle par l'animation" do
    removed = @webinar.registrations.create!(email: "intrus@example.net", name: "Intrus", confirmed_at: Time.current)
    removed.remove_from_room!
    fake = stub_room_service

    deliver(joined_body(identity: "viewer-#{removed.id}"))
    assert_response :no_content
    assert_equal [ [ @webinar.room_name, "viewer-#{removed.id}" ] ], fake.removed

    assert_no_enqueued_jobs(only: StartTrackEgressJob) { deliver(track_published("viewer-#{removed.id}")) }
  ensure
    restore_room_service
  end

  # Lien participants : un spectateur à qui l'on a donné
  # puis retiré la parole revient avec le jeton émis pendant la parole (TTL
  # encore valide, canPublish) → la salle ferme sa publication à l'entrée,
  # même avec un accord à l'image en cours (PublishPermission).
  test "participant_joined d'un spectateur avec accord dont la parole a été retirée : publication fermée" do
    viewer, hand = viewer_with_hand(state: "granted")
    hand.update!(state: "revoked", revoked_at: Time.current)
    fake = stub_room_service

    deliver(joined_body(identity: "viewer-#{viewer.id}", can_publish: true))
    assert_response :no_content
    assert_equal [ [ "viewer-#{viewer.id}", false, [] ] ], fake.permissions
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  test "participant_joined d'un spectateur avec accord qui a la parole, jeton d'avant l'accord : publication ouverte" do
    viewer, = viewer_with_hand(state: "granted")
    fake = stub_room_service

    deliver(joined_body(identity: "viewer-#{viewer.id}"))
    assert_equal [ [ "viewer-#{viewer.id}", true, PublishPermission::SOURCES ] ], fake.permissions
  ensure
    restore_room_service
  end

  test "participant_joined n_expulse_pas_un_coanimateur_toujours_autorise" do
    guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean",
                         email_verified: true, email_verified_for: "jean@partenaire.example.org")
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: @webinar.host_sub,
                                   claimed_sub: guest.oidc_sub)
    fake = stub_room_service
    deliver(joined_body(identity: "host-#{guest.oidc_sub}"))
    assert_response :no_content
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  test "participant_joined expulse un ex-coanimateur dont le WebinarHost a ete supprime" do
    # Scénario stale-authorization : le JWT :cohost a été émis, le
    # WebinarHost a ensuite été supprimé (le DELETE expulse mais LiveKit
    # peut rater — ou le co-animateur se reconnecte avec son ancien
    # token). Le webhook `participant_joined` DOIT expulser.
    guest_sub = "sub-ex-guest"
    fake = stub_room_service
    deliver(joined_body(identity: "host-#{guest_sub}"))
    assert_response :no_content
    assert_equal "host-#{guest_sub}", fake.removed.first.last
  ensure
    restore_room_service
  end

  test "participant_joined room_name inconnue → aucune expulsion" do
    fake = stub_room_service
    deliver(joined_body(identity: "host-x", room: "room-inexistante"))
    assert_response :no_content
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  # ---- Participants techniques JAMAIS expulsés ----

  test "participant_joined n_expulse_jamais_egress_meme_identite_inconnue" do
    fake = stub_room_service
    deliver(joined_body(identity: "EG_abcdef1234", kind: :EGRESS))
    assert_response :no_content
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  test "participant_joined n_expulse_jamais_agent_transcripteur" do
    fake = stub_room_service
    deliver(joined_body(identity: "agent-transcriber-xyz", kind: :AGENT))
    assert_response :no_content
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  test "participant_joined n_expulse_jamais_ingress_sip_connector_bridge" do
    fake = stub_room_service
    %i[INGRESS SIP CONNECTOR BRIDGE].each do |kind|
      deliver(joined_body(identity: "svc-#{kind.downcase}-1", kind: kind))
      assert_response :no_content
    end
    assert_empty fake.removed
  ensure
    restore_room_service
  end

  test "participant_joined expulse speaker-legacy" do
    # Le chemin legacy a été supprimé :
    # `Webinar#speaker_token`, `SPEAKER_PURPOSE` et le
    # fallback `find_signed` n'existent plus. Une identité
    # `speaker-legacy-*` qui réapparaîtrait (ancien token encore en
    # circulation côté LiveKit) est donc inconnue → expulsée (fail-closed).
    fake = stub_room_service
    deliver(joined_body(identity: "speaker-legacy-abcdef1234567890"))
    assert_response :no_content
    assert_equal 1, fake.removed.size
    assert_equal "speaker-legacy-abcdef1234567890", fake.removed.first.last
  ensure
    restore_room_service
  end

  test "participant_joined kind_standard_explicite_applique_la_garde" do
    # Robustesse : si LiveKit émet `kind: STANDARD` explicitement
    # (certaines versions / configs), la garde doit continuer à
    # fonctionner. Un host-sub inconnu avec kind STANDARD est expulsé.
    fake = stub_room_service
    deliver(joined_body(identity: "host-sub-inconnu", kind: :STANDARD))
    assert_response :no_content
    assert_equal "host-sub-inconnu", fake.removed.first.last
  ensure
    restore_room_service
  end

  test "participant_joined tolere un echec distant" do
    fake = stub_room_service(raise_on_remove: RoomServiceClient::Error.new("boom"))
    deliver(joined_body(identity: "host-sub-fantome"))
    # Pas de 500 : la garde est best-effort (log sans PII).
    assert_response :no_content
    assert_equal 1, fake.removed.size
  ensure
    restore_room_service
  end

  # ---- Fin automatique du direct ----

  test "room_finished d'un direct en cours → vacance relevée et fin automatique programmée à 15 min" do
    freeze_time do
      assert_enqueued_with(job: AutoEndLiveJob, args: [ @webinar.id ], at: 15.minutes.from_now) do
        deliver(webhook_body(event: "room_finished", room: @webinar.room_name))
      end
      assert_response :no_content
      assert_equal Time.current, @webinar.reload.room_empty_since
    end
  end

  test "room_finished hors direct ou salle inconnue → rien" do
    @webinar.update!(state: "ended", ended_at: Time.current)
    assert_no_enqueued_jobs(only: AutoEndLiveJob) do
      deliver(webhook_body(event: "room_finished", room: @webinar.room_name))
      deliver(webhook_body(event: "room_finished", room: "inconnue"))
    end
    assert_nil @webinar.reload.room_empty_since
  end

  test "participant_joined d'une personne autorisée → la fin automatique n'aura pas lieu" do
    @webinar.mark_room_empty!(3.minutes.ago)
    stub_room_service
    deliver(joined_body(identity: "speaker-#{@speaker.id}"))
    assert_nil @webinar.reload.room_empty_since
  ensure
    restore_room_service
  end

  test "participant_joined expulsé, enregistreur ou transcripteur → la vacance tient" do
    @webinar.mark_room_empty!(3.minutes.ago)
    stub_room_service
    deliver(joined_body(identity: "host-sub-fantome"))
    deliver(joined_body(identity: "EG_composite", kind: :EGRESS))
    deliver(joined_body(identity: "agent-AJ_1", kind: :AGENT))
    assert_not_nil @webinar.reload.room_empty_since
  ensure
    restore_room_service
  end

  # ---- Journal de présence (PresenceEvent) ----

  test "arrivée, départ, connexion interrompue et fermeture de salle vont au journal, à l'heure de LiveKit" do
    stub_room_service
    viewer = @webinar.registrations.create!(name: "Ana", email: "ana@example.test", confirmed_at: 1.day.ago)
    identity = "viewer-#{viewer.id}"
    t = 20.minutes.ago.change(usec: 0)

    deliver(webhook_body(event: "participant_joined", room: @webinar.room_name, identity: identity, id: "EV_j", created_at: t))
    deliver(webhook_body(event: "participant_left", room: @webinar.room_name, identity: identity, id: "EV_l", created_at: t + 60))
    deliver(webhook_body(event: "participant_connection_aborted", room: @webinar.room_name, identity: identity, id: "EV_a", created_at: t + 70))
    deliver(webhook_body(event: "room_finished", room: @webinar.room_name, id: "EV_f", created_at: t + 90))

    assert_response :no_content
    assert_equal [ [ "joined", identity, t ], [ "left", identity, t + 60 ], [ "aborted", identity, t + 70 ], [ "room_finished", nil, t + 90 ] ],
                 @webinar.presence_events.chronological.pluck(:kind, :identity, :occurred_at)
    assert_equal %w[livekit], @webinar.presence_events.distinct.pluck(:source)
    assert_equal t, viewer.reload.room_joined_at, "première arrivée à l'heure du fait, pas de la réception"
  ensure
    restore_room_service
  end

  test "journal de présence : webhook rejoué une fois, enregistreur et transcripteur ignorés, expulsé noté refusé" do
    stub_room_service
    2.times { deliver(webhook_body(event: "participant_joined", room: @webinar.room_name, identity: "speaker-#{@speaker.id}", id: "EV_1")) }
    deliver(webhook_body(event: "participant_left", room: @webinar.room_name, identity: "EG_composite", kind: :EGRESS, id: "EV_2"))
    deliver(webhook_body(event: "participant_left", room: @webinar.room_name, identity: "agent-AJ_1", kind: :AGENT, id: "EV_3"))
    deliver(webhook_body(event: "participant_joined", room: @webinar.room_name, identity: "host-sub-fantome", id: "EV_4"))
    deliver(webhook_body(event: "participant_left", room: "inconnue", identity: "speaker-#{@speaker.id}", id: "EV_5"))

    assert_equal [ [ "joined", "speaker-#{@speaker.id}" ], [ "refused", "host-sub-fantome" ] ],
                 @webinar.presence_events.chronological.pluck(:kind, :identity)
    assert_equal 2, PresenceEvent.count
  ensure
    restore_room_service
  end

  test "journal de présence indisponible : la garde tient, 204" do
    fake = stub_room_service
    original = PresenceEvent.method(:record_room!)
    PresenceEvent.define_singleton_method(:record_room!) { |*, **| raise ActiveRecord::StatementInvalid, "database is locked" }

    begin
      deliver(joined_body(identity: "host-sub-fantome"))
      deliver(webhook_body(event: "participant_left", room: @webinar.room_name, identity: "speaker-#{@speaker.id}"))
    ensure
      PresenceEvent.define_singleton_method(:record_room!, original)
    end

    assert_response :no_content
    assert_equal [ [ @webinar.room_name, "host-sub-fantome" ] ], fake.removed
  ensure
    restore_room_service
  end

  test "refus : l'expulsion part avant l'écriture au journal" do
    order = []
    fake = stub_room_service
    fake.define_singleton_method(:remove_participant) { |room:, identity:| order << :removed }
    original = PresenceEvent.method(:record_room!)
    PresenceEvent.define_singleton_method(:record_room!) { |*args, **kwargs| order << :noted; original.call(*args, **kwargs) }

    begin
      deliver(joined_body(identity: "host-sub-fantome"))
    ensure
      PresenceEvent.define_singleton_method(:record_room!, original)
    end

    assert_equal %i[removed noted], order
  ensure
    restore_room_service
  end

  private

  # Spectateur sous accord à l'image en cours, avec une main dans `state`.
  def viewer_with_hand(state:)
    @webinar.update!(visibility: "published")
    viewer = @webinar.registrations.create!(email: "parole-#{SecureRandom.hex(3)}@example.net", name: "Parole", confirmed_at: Time.current)
    ParticipantConsent.grant!(viewer, recording: true, excerpts: false, adult: true)
    hand = @webinar.hand_raises.create!(registration: viewer, raised_at: Time.current, state: state,
                                        granted_at: (Time.current if state == "granted"))
    [ viewer, hand ]
  end
end
