# frozen_string_literal: true

require "test_helper"

# RetentionPurgeJob — tient les engagements de
# app/views/legal/confidentialite.html.erb : inscriptions 12 mois,
# enregistrements + transcription 3 ans. Les webinars eux-mêmes ne sont jamais
# supprimés (data historique anonymisée en aval).
class RetentionPurgeJobTest < ActiveJob::TestCase
  setup do
    @recordings_root = Dir.mktmpdir("recordings_root_test")
    @prev_root = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = @recordings_root
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @prev_root
    FileUtils.remove_entry(@recordings_root) if File.directory?(@recordings_root)
  end

  # -- scénarios ------------------------------------------------------------

  test "supprime les inscriptions des webinaires de plus de 12 mois, garde les récentes" do
    old = create_webinar(starts_at: 13.months.ago, slug_hint: "cafe-vieux")
    recent = create_webinar(starts_at: 2.months.ago, slug_hint: "cafe-recent")
    old_reg = create_registration(old, email: "ancien@example.com")
    recent_reg = create_registration(recent, email: "frais@example.com")

    travel_to Time.current do
      RetentionPurgeJob.new.perform
    end

    assert_not Registration.exists?(old_reg.id), "registration > 12 mois doit être supprimée"
    assert Registration.exists?(recent_reg.id),  "registration récente doit être préservée"
    assert Webinar.exists?(old.id),              "le webinaire ancien reste (data historique)"
  end

  test "l'adresse déclarée d'un intervenant suit les inscriptions : oubliée au-delà de 12 mois, gardée en deçà" do
    old = create_webinar(starts_at: 13.months.ago, slug_hint: "cafe-declare-vieux")
    recent = create_webinar(starts_at: 2.months.ago, slug_hint: "cafe-declare-recent")
    linked = old.speakers.create!(name: "Rattaché", registration: create_registration(old, email: "lie@example.com"))
    old_declared = old.speakers.create!(name: "Ancien", declared_email: "ancien@example.com")
    recent_declared = recent.speakers.create!(name: "Récent", declared_email: "frais@example.com")

    RetentionPurgeJob.new.perform

    assert_equal [ nil, nil ], [ old_declared.reload.declared_email, old_declared.link_token ]
    assert_nil linked.reload.registration, "rattachement détaché avec l'inscription purgée"
    assert_equal "frais@example.com", recent_declared.reload.declared_email
    assert old_declared.name, "l'intervenant reste avec le webinaire"
  end

  test "supprime les HandRaise liées aux registrations purgées" do
    old = create_webinar(starts_at: 400.days.ago, slug_hint: "cafe-main")
    reg = create_registration(old, email: "main@example.com")
    hand = HandRaise.create!(webinar: old, registration: reg, raised_at: 400.days.ago)

    RetentionPurgeJob.new.perform

    assert_not HandRaise.exists?(hand.id), "HandRaise doit tomber avec la registration"
    assert_not Registration.exists?(reg.id)
  end

  test "la discussion du direct suit les inscriptions : purgée au-delà de 12 mois, gardée en deçà" do
    old = create_webinar(starts_at: 13.months.ago, slug_hint: "cafe-discussion-vieux")
    recent = create_webinar(starts_at: 2.months.ago, slug_hint: "cafe-discussion-recent")
    old_message = old.messages.create!(author_identity: "viewer-1", name: "Ancienne", body: "Bonjour")
    recent_message = recent.messages.create!(author_identity: "viewer-2", name: "Récente", body: "Bonjour")

    RetentionPurgeJob.new.perform

    assert_not Message.exists?(old_message.id), "message > 12 mois supprimé (nom et texte d'un participant)"
    assert Message.exists?(recent_message.id),  "message récent préservé"
  end

  test "le journal de présence suit les inscriptions : purgé au-delà de 12 mois, gardé en deçà" do
    old = create_webinar(starts_at: 13.months.ago, slug_hint: "cafe-presence-vieux")
    recent = create_webinar(starts_at: 2.months.ago, slug_hint: "cafe-presence-recent")
    old_event = old.presence_events.create!(kind: "joined", identity: "viewer-1", occurred_at: 13.months.ago, source: "livekit")
    recent_event = recent.presence_events.create!(kind: "joined", identity: "viewer-2", occurred_at: 2.months.ago, source: "livekit")

    RetentionPurgeJob.new.perform

    assert_not PresenceEvent.exists?(old_event.id), "qui s'est connecté quand, > 12 mois : supprimé"
    assert PresenceEvent.exists?(recent_event.id)
  end

  test "les réponses aux sondages suivent les inscriptions (FK) ; la question reste avec le webinaire" do
    old = create_webinar(starts_at: 13.months.ago, slug_hint: "cafe-sondage-vieux")
    recent = create_webinar(starts_at: 2.months.ago, slug_hint: "cafe-sondage-recent")
    old_reg = create_registration(old, email: "sondee@example.com")
    old_poll = old.polls.create!(position: 1, kind: "short_text", label: "Un mot ?")
    old_response = old_poll.responses.create!(respondent_identity: "viewer-#{old_reg.id}", registration: old_reg,
                                              name: "Sondée", value: "Curieuse")
    recent_poll = recent.polls.create!(position: 1, kind: "short_text", label: "Un mot ?")
    recent_response = recent_poll.responses.create!(respondent_identity: "host-marc", name: "marc", value: "Ravi")

    RetentionPurgeJob.new.perform

    assert_not PollResponse.exists?(old_response.id), "réponse > 12 mois supprimée (nom et réponse d'un participant)"
    assert_not Registration.exists?(old_reg.id)
    assert Poll.exists?(old_poll.id), "la question, sans donnée personnelle, reste"
    assert PollResponse.exists?(recent_response.id), "réponse récente préservée"
  end

  test "la file Q&R suit la discussion : questions et liens purgés au-delà de 12 mois, gardés en deçà" do
    old = create_webinar(starts_at: 13.months.ago, slug_hint: "cafe-qr-vieux")
    recent = create_webinar(starts_at: 2.months.ago, slug_hint: "cafe-qr-recent")
    old_item = QaItem.enqueue!(message: old.messages.create!(author_identity: "viewer-1", name: "A", body: "Q ?"),
                               label: "Ancienne question", source: "llm")
    recent_item = QaItem.enqueue!(message: recent.messages.create!(author_identity: "viewer-2", name: "B", body: "Q ?"),
                                  label: "Question récente", source: "llm")

    log = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    RetentionPurgeJob.new.perform
    Rails.logger = previous_logger

    assert_not QaItem.exists?(old_item.id), "reformulation > 12 mois supprimée"
    assert_equal 0, QaItemMessage.where(qa_item_id: old_item.id).count
    assert_equal 1, recent_item.reload.messages.count, "question récente et ses auteurs préservés"
    assert_match(/messages=1 qa_items=1 poll_responses=0 /, log.string)
  ensure
    Rails.logger = previous_logger if previous_logger
  end

  test "garde les enregistrements et transcript_segments entre 12 mois et 3 ans" do
    mid = create_webinar(starts_at: 2.years.ago, slug_hint: "cafe-mid")
    rec, abs_path = create_recording_with_file(mid, relative: "composite-abc.mp4")
    segment = create_transcript_segment(mid)

    RetentionPurgeJob.new.perform

    assert Recording.exists?(rec.id),             "recording < 3 ans doit être préservé"
    assert File.file?(abs_path),                  "fichier recording < 3 ans intact"
    assert TranscriptSegment.exists?(segment.id), "transcript_segment < 3 ans préservé"
  end

  test "supprime enregistrements, fichiers et transcription au-delà de 3 ans" do
    very_old = create_webinar(starts_at: 4.years.ago, slug_hint: "cafe-tresvieux")
    rec, abs_path = create_recording_with_file(very_old, relative: "composite-xyz.mp4")
    segment = create_transcript_segment(very_old)

    RetentionPurgeJob.new.perform

    assert_not Recording.exists?(rec.id),             "recording > 3 ans supprimé"
    assert_not File.file?(abs_path),                  "fichier recording > 3 ans supprimé sur disque"
    assert_not TranscriptSegment.exists?(segment.id), "transcript_segment > 3 ans supprimé"
    assert Webinar.exists?(very_old.id),              "webinaire conservé"
  end

  test "la preuve des accords à l'image suit les enregistrements : gardée à 2 ans, purgée au-delà de 3 ans" do
    mid = create_webinar(starts_at: 2.years.ago, slug_hint: "cafe-accord-mid")
    very_old = create_webinar(starts_at: 4.years.ago, slug_hint: "cafe-accord-vieux")
    viewer = create_registration(mid, email: "ines@example.com")
    kept = ParticipantConsent.grant!(viewer, recording: true, excerpts: true, adult: true)
    purged = ParticipantConsent.grant!(very_old.speakers.create!(name: "Lorenzo"), recording: true, excerpts: true, adult: true)

    RetentionPurgeJob.new.perform

    assert_not Registration.exists?(viewer.id), "inscription > 12 mois purgée"
    assert ParticipantConsent.exists?(kept.id), "preuve < 3 ans conservée, au-delà de l'inscription qui la portait"
    assert_not ParticipantConsent.exists?(purged.id), "preuve > 3 ans purgée avec les enregistrements"
  end

  test "les mux participants (kind participant, participants/<slug>/) sont purgés fichier + row au-delà de 3 ans" do
    very_old = create_webinar(starts_at: 4.years.ago, slug_hint: "cafe-mux")
    rel_path = "_participants/#{very_old.slug}/mux-speaker-7.mp4"
    absolute = File.join(@recordings_root, rel_path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, "mux-payload")
    mux = very_old.recordings.create!(
      kind: :participant, status: :done, path: rel_path,
      participant_identity: "speaker-7", started_at: 4.years.ago,
      ended_at: 4.years.ago + 2.minutes
    )

    RetentionPurgeJob.new.perform

    assert_not Recording.exists?(mux.id), "row participant mux supprimée"
    assert_not File.file?(absolute),      "fichier mux sous participants/<slug>/ supprimé sur disque"
  end

  test "les versions légères (dérivé, marqueur, demande) partent avec leur original au-delà de 3 ans" do
    very_old = create_webinar(starts_at: 4.years.ago, slug_hint: "cafe-leger")
    rec, = create_recording_with_file(very_old, relative: "composite-xyz.mp4")
    LightVersion.new(rec).request!
    derived = File.join(@recordings_root, "_replays/#{very_old.slug}/composite-xyz.mp4")
    FileUtils.mkdir_p(File.dirname(derived))
    File.write(derived, "leger")
    File.write("#{derived}.json", "{}")
    intact = File.join(@recordings_root, "_replays/autre/composite-xyz.mp4")
    FileUtils.mkdir_p(File.dirname(intact))
    File.write(intact, "autre webinaire")

    RetentionPurgeJob.new.perform

    assert_empty Dir.glob("#{@recordings_root}/_replays/#{very_old.slug}/*")
    assert_empty Dir.glob("#{@recordings_root}/_leger/demandes/*")
    assert File.file?(intact), "le dérivé d'un autre webinaire n'est pas touché"
  end

  test "les pistes par personne (kind track) et leurs fichiers sont purgées aussi au-delà de 3 ans" do
    very_old = create_webinar(starts_at: 4.years.ago, slug_hint: "cafe-pistes")
    rel_path = "#{very_old.slug}/speaker-1-camera-x.mp4"
    absolute = File.join(@recordings_root, rel_path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, "piste")
    track = very_old.recordings.create!(kind: :track, status: :done, path: rel_path, track_sid: "TR_x",
                                        participant_identity: "speaker-1", track_source: "camera")

    RetentionPurgeJob.new.perform

    assert_not Recording.exists?(track.id)
    assert_not File.file?(absolute)
  end

  test "replay au-delà de 3 ans : la copie de diffusion part du disque, le replay et ses séances de la base" do
    very_old = create_webinar(starts_at: 4.years.ago, slug_hint: "cafe-replay")
    FileUtils.mkdir_p(File.join(@recordings_root, very_old.slug))
    File.write(File.join(@recordings_root, very_old.slug, "composite.mp4"), "composite")
    composite = very_old.recordings.create!(kind: :composite, status: :done, path: "#{very_old.slug}/composite.mp4",
                                            started_at: 4.years.ago, ended_at: 4.years.ago + 1.hour)
    derived = "#{Replay::DERIVED_SUBDIR}/#{very_old.slug}/diffusion.mp4"
    FileUtils.mkdir_p(File.join(@recordings_root, File.dirname(derived)))
    File.write(File.join(@recordings_root, derived), "720p")
    replay = very_old.create_replay!(recording: composite, derived_path: derived, published_at: 4.years.ago)
    replay.views.create!(user: User.create!(email: "vu@example.test", oidc_sub: "sub-vu"), session_key: SecureRandom.uuid,
                         started_at: 4.years.ago, last_seen_at: 4.years.ago)

    RetentionPurgeJob.new.perform

    assert_not File.file?(File.join(@recordings_root, derived)), "copie de diffusion supprimée du disque"
    assert_not Replay.exists?(replay.id)
    assert_equal 0, ReplayView.where(replay_id: replay.id).count
  end

  test "chapitres et index de recherche suivent la transcription : gardés à 2 ans, purgés au-delà de 3 ans" do
    entries = ->(webinar) { ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM replay_search_entries WHERE webinar_id = #{webinar.id}") }
    webinars = [ 4.years.ago, 2.years.ago ].map do |starts_at|
      webinar = create_webinar(starts_at: starts_at, slug_hint: "cafe-chapitres")
      FileUtils.mkdir_p(File.join(@recordings_root, webinar.slug))
      File.write(File.join(@recordings_root, webinar.slug, "composite.mp4"), "composite")
      composite = webinar.recordings.create!(kind: :composite, status: :done, path: "#{webinar.slug}/composite.mp4",
                                             started_at: starts_at, ended_at: starts_at + 1.hour)
      webinar.create_replay!(recording: composite, published_at: starts_at)
      webinar.transcript_segments.create!(participant_identity: "speaker-1", text: "agents", started_at: starts_at + 60,
                                          ended_at: starts_at + 62, segment_id: SecureRandom.uuid)
      ChapterSet.create!(webinar: webinar, validated_at: starts_at)
                .revise!([ ChapterSet::Draft.new(starts_at: starts_at + 60, title: "Agents", themes: [ "agents" ]) ], by: nil, validate: true)
      ReplaySearchIndex.refresh(webinar)
      webinar
    end
    very_old, recent = webinars

    RetentionPurgeJob.new.perform

    assert_nil very_old.reload.chapter_set
    assert_equal 0, Chapter.joins(:chapter_set).where(chapter_sets: { webinar_id: very_old.id }).count
    assert_equal 0, entries.call(very_old)
    assert recent.reload.chapter_set
    assert_operator entries.call(recent), :>, 0
  end

  test "recherches dans les replays : gardées 11 mois, purgées au-delà de 12 mois" do
    user = User.create!(email: "chercheur@example.test", oidc_sub: "sub-chercheur")
    old = ReplaySearch.record!(query: "agents", author: user, results_count: 1)
    old.update_columns(created_at: 13.months.ago)
    kept = ReplaySearch.record!(query: "rag", author: user, results_count: 0)
    kept.update_columns(created_at: 11.months.ago)

    RetentionPurgeJob.new.perform

    assert_equal [ kept ], ReplaySearch.all.to_a
  end

  test "replay au-delà de 3 ans : montage non adopté, son marqueur et sa demande partent, le journal des mises en avant aussi" do
    very_old = create_webinar(starts_at: 4.years.ago, slug_hint: "cafe-montage")
    FileUtils.mkdir_p(File.join(@recordings_root, very_old.slug))
    File.write(File.join(@recordings_root, very_old.slug, "composite.mp4"), "composite")
    composite = very_old.recordings.create!(kind: :composite, status: :done, path: "#{very_old.slug}/composite.mp4",
                                            started_at: 4.years.ago, ended_at: 4.years.ago + 1.hour)
    replay = very_old.create_replay!(recording: composite)
    montage = ReplayMontage.new(replay)
    montage.request!
    output = File.join(@recordings_root, montage.output_relative)
    FileUtils.mkdir_p(File.dirname(output))
    File.write(output, "montage")
    File.write("#{output}.json", "{}")
    very_old.spotlight_changes.create!(identity: "speaker-1", changed_at: 4.years.ago)

    RetentionPurgeJob.new.perform

    assert_empty Dir.glob(File.join(@recordings_root, "{_replays,_montages}/**/*.*"))
    assert_equal 0, very_old.spotlight_changes.count
  end

  test "jamais de suppression de fichier hors du préfixe <slug>/" do
    very_old = create_webinar(starts_at: 4.years.ago, slug_hint: "cafe-victime")

    # On plante un path forgé qui tente de sortir du dossier du slug.
    # Recording#absolute_path doit renvoyer nil → le fichier intrus n'est
    # jamais touché, et le record est quand même delete_all en DB.
    intrus_dir = File.join(@recordings_root, "autre-webinaire")
    FileUtils.mkdir_p(intrus_dir)
    intrus = File.join(intrus_dir, "vol.mp4")
    File.write(intrus, "ne pas toucher")

    rec = very_old.recordings.create!(
      kind: :composite, status: :done, path: "../autre-webinaire/vol.mp4", egress_id: "EG_evil"
    )
    assert_nil rec.absolute_path, "préconditioning: absolute_path doit refuser le path forgé"

    RetentionPurgeJob.new.perform

    assert File.file?(intrus),         "fichier hors préfixe JAMAIS supprimé"
    assert_not Recording.exists?(rec.id), "row Recording quand même nettoyée en DB"
  ensure
    File.delete(intrus) if intrus && File.file?(intrus)
  end

  test "nom et email des intervenants : gardés à 2 ans, effacés au-delà de 3 ans, avec les adresses prévenues du dépôt" do
    mid = create_webinar(starts_at: 2.years.ago, slug_hint: "cafe-intervenant-mid")
    very_old = create_webinar(starts_at: 4.years.ago, slug_hint: "cafe-intervenant-vieux")
    kept = mid.speakers.create!(name: "Mathilde", email: "mathilde@example.com")
    purged = very_old.speakers.create!(name: "Lorenzo", email: "lorenzo@example.com")
    preference = DevicePreference.create!(owner: purged, audio_input_device_id: "micro-usb")
    publication = very_old.create_episode_publication!(status: "published", notified_emails: [ "lorenzo@example.com" ])

    RetentionPurgeJob.new.perform

    assert Speaker.exists?(kept.id), "intervenant < 3 ans conservé"
    assert_not Speaker.exists?(purged.id), "intervenant > 3 ans effacé"
    assert_not DevicePreference.exists?(preference.id), "ses préférences de périphériques partent avec lui"
    assert_empty publication.reload.notified_emails
  end

  test "l'abonnement à l'agenda suit la personne : supprimé avec sa dernière inscription ou demande, gardé sinon" do
    old = create_webinar(starts_at: 13.months.ago, slug_hint: "cafe-agenda-vieux")
    recent = create_webinar(starts_at: 2.months.ago, slug_hint: "cafe-agenda-recent")
    create_registration(old, email: "partie@example.com")
    create_registration(old, email: "revenue@example.com")
    create_registration(recent, email: "revenue@example.com")
    RegistrationRequest.create!(name: "Lou", email: "prevenue@example.com", notify_next: true, confirmed_at: Time.current)
    %w[partie@example.com revenue@example.com prevenue@example.com].each { |email| CalendarSubscription.create!(email: email) }

    RetentionPurgeJob.new.perform

    assert_equal %w[prevenue@example.com revenue@example.com], CalendarSubscription.order(:email).pluck(:email)
  end

  test "mesures des caméras : purgées au-delà de 30 jours, quel que soit l'âge du webinaire" do
    webinar = create_webinar(starts_at: 2.months.ago, slug_hint: "cafe-cameras")
    old = webinar.camera_samples.create!(participant_identity: "speaker-14", created_at: 31.days.ago)
    recent = webinar.camera_samples.create!(participant_identity: "speaker-14", created_at: 29.days.ago)

    RetentionPurgeJob.new.perform

    assert_not CameraSample.exists?(old.id)
    assert CameraSample.exists?(recent.id)
  end

  test "idempotent : relance sans effet quand il n'y a plus rien à purger" do
    old = create_webinar(starts_at: 400.days.ago, slug_hint: "cafe-idemp")
    create_registration(old, email: "idemp@example.com")

    RetentionPurgeJob.new.perform
    assert_nothing_raised { RetentionPurgeJob.new.perform }
    assert_equal 0, Registration.where(webinar_id: old.id).count
  end

  test "ne journalise ni nom ni email" do
    old = create_webinar(starts_at: 400.days.ago, slug_hint: "cafe-pii")
    create_registration(old, name: "Dupont Alice", email: "alice@example.com")

    io = StringIO.new
    old_logger = Rails.logger
    Rails.logger = Logger.new(io)

    begin
      RetentionPurgeJob.new.perform
    ensure
      Rails.logger = old_logger
    end

    log = io.string
    assert_match(/retention_purge/, log)
    assert_no_match(/alice@example\.com/, log)
    assert_no_match(/Dupont/, log)
  end

  test "demandes CONFIRMÉES : purgées 12 mois après, une fois leurs inscriptions purgées" do
    old_webinar = create_webinar(starts_at: 13.months.ago, slug_hint: "cafe-demande-vieux")
    recent_webinar = create_webinar(starts_at: 1.month.from_now, slug_hint: "cafe-demande-futur")
    travel_to 13.months.ago do
      @alone = RegistrationRequest.create!(name: "Lou", email: "lou@example.com", notify_next: true, confirmed_at: Time.current)
      @with_old = RegistrationRequest.create!(name: "Ana", email: "ana@example.com", confirmed_at: Time.current)
      @with_recent = RegistrationRequest.create!(name: "Max", email: "max@example.com", confirmed_at: Time.current)
    end
    Registration.find_or_create_for(old_webinar, email: "ana@example.com", name: "Ana", registration_request: @with_old)
    Registration.find_or_create_for(recent_webinar, email: "max@example.com", name: "Max", registration_request: @with_recent)
    fresh = RegistrationRequest.create!(name: "Zoé", email: "zoe@example.com", notify_next: true)

    RetentionPurgeJob.new.perform

    assert_not RegistrationRequest.exists?(@alone.id), "« préviens-moi » de plus de 12 mois purgé"
    assert_not RegistrationRequest.exists?(@with_old.id), "purgée avec son inscription ancienne"
    assert RegistrationRequest.exists?(@with_recent.id), "un café encore dans la fenêtre garde sa demande"
    assert RegistrationRequest.exists?(fresh.id)
  end

  test "demandes NON confirmées : effacées avec leurs inscriptions après 30 jours, pas avant" do
    webinar = create_webinar(starts_at: 2.months.from_now, slug_hint: "cafe-attente")
    travel_to 31.days.ago do
      @stale = RegistrationRequest.create!(name: "Ana", email: "ana@example.com")
      @stale_confirmed = RegistrationRequest.create!(name: "Max", email: "max@example.com", notify_next: true)
    end
    travel_to 29.days.ago do
      @recent = RegistrationRequest.create!(name: "Zoé", email: "zoe@example.com")
    end
    stale_reg, = Registration.find_or_create_for(webinar, email: "ana@example.com", name: "Ana", registration_request: @stale)
    recent_reg, = Registration.find_or_create_for(webinar, email: "zoe@example.com", name: "Zoé", registration_request: @recent)
    @stale_confirmed.confirm!

    RetentionPurgeJob.new.perform

    assert_not RegistrationRequest.exists?(@stale.id)
    assert_not Registration.exists?(stale_reg.id), "inscription non confirmée effacée avec sa demande"
    assert RegistrationRequest.exists?(@recent.id)
    assert Registration.exists?(recent_reg.id)
    assert RegistrationRequest.exists?(@stale_confirmed.id), "une demande confirmée suit la règle des 12 mois"
  end

  test "la purge des demandes non confirmées suit le `now:` reçu, comme la règle des 12 mois" do
    request = RegistrationRequest.create!(name: "Ana", email: "ana-now@example.com", created_at: 10.days.ago)

    RetentionPurgeJob.new.perform(now: Time.current)
    assert RegistrationRequest.exists?(request.id), "10 jours : gardée"

    RetentionPurgeJob.new.perform(now: 25.days.from_now)
    assert_not RegistrationRequest.exists?(request.id), "35 jours au regard de `now:` : effacée"
  end

  test "pas de webinaires anciens → no-op, aucun compteur négatif" do
    create_webinar(starts_at: 2.months.ago, slug_hint: "cafe-tout-frais")
    assert_nothing_raised { RetentionPurgeJob.new.perform }
  end

  # -- helpers --------------------------------------------------------------

  private

  def create_webinar(starts_at:, slug_hint:)
    Webinar.create!(
      title: "Café IA #{slug_hint}",
      starts_at: starts_at,
      host_sub: "sub-#{slug_hint}"
    )
  end

  def create_registration(webinar, email:, name: "Participant Test")
    Registration.create!(webinar: webinar, email: email, name: name)
  end

  # Crée un Recording composite + le fichier sur disque sous le préfixe
  # <RECORDINGS_ROOT>/<slug>/, conformément à Recording#absolute_path.
  def create_recording_with_file(webinar, relative:)
    rel_path = "#{webinar.slug}/#{relative}"
    absolute = File.join(@recordings_root, rel_path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, "mp4-fake")

    rec = webinar.recordings.create!(
      kind: :composite, status: :done, path: rel_path, egress_id: "EG_#{SecureRandom.hex(4)}"
    )
    [ rec, absolute ]
  end

  def create_transcript_segment(webinar)
    TranscriptSegment.create!(
      webinar: webinar,
      participant_identity: "speaker-1",
      speaker_name: "Alice",
      text: "Bonjour",
      started_at: webinar.starts_at,
      ended_at: webinar.starts_at + 2.seconds,
      segment_id: "seg-#{SecureRandom.hex(4)}"
    )
  end
end
