# frozen_string_literal: true

require "test_helper"

# Recording. Tests centrés sur les invariants qui
# supporteraient un debugging à froid : machine d'état, scope actif,
# résolution de path (défense traversal).
class RecordingTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(
      title: "démo", starts_at: 1.day.from_now, host_sub: "sub-marc"
    )
    @root = Dir.mktmpdir("recordings-root-")
    @prev_root = ENV["RECORDINGS_ROOT"]
    ENV["RECORDINGS_ROOT"] = @root
  end

  teardown do
    ENV["RECORDINGS_ROOT"] = @prev_root
    FileUtils.remove_entry(@root) if File.directory?(@root)
  end

  test "recording kinds keep composites as default and separate track scope" do
    composite = Recording.create!(webinar: @webinar)
    track = Recording.create!(webinar: @webinar, kind: "track", participant_identity: "speaker", track_source: "camera")
    assert_equal "composite", composite.kind
    assert_equal [ composite ], Recording.composite.to_a
    assert_equal [ track ], Recording.tracks.to_a
    assert_not Recording.new(webinar: @webinar, kind: "unknown").valid?
  end

  test "track filenames contain sanitized bounded segments and no guessed extension" do
    recording = Recording.new(webinar: @webinar)
    filename = recording.filename_for(kind: :track, identity: "../../Etc", source: "screen_share")
    assert_match %r{\A#{@webinar.slug}/etc-screen-share-[a-f0-9-]{36}\z}, filename
    assert_equal "", File.extname(filename)
    assert_not_includes filename, ".."

    long_name = recording.filename_for(kind: :track, identity: "x" * 500, source: "y" * 500)
    assert_operator File.basename(long_name).bytesize, :<=, 158
    blank_name = recording.filename_for(kind: :track, identity: "/", source: "\x00")
    assert_match %r{/unknown-unknown-}, blank_name
  end

  test "restarts and colliding sanitized identities generate distinct filenames" do
    recording = Recording.new(webinar: @webinar)
    names = [ "a/b", "a-b", "a/b" ].map do |identity|
      recording.filename_for(kind: :track, identity: identity, source: "camera")
    end
    assert_equal 3, names.uniq.size
  end

  test "composite keeps MP4 and unsafe slug or unknown kind is rejected" do
    recording = Recording.new(webinar: @webinar)
    assert_equal ".mp4", File.extname(recording.filename_for(kind: :composite, identity: "host", source: "room"))
    assert_raises(ArgumentError) { recording.filename_for(kind: :unknown, identity: "host", source: "room") }
    @webinar.slug = "../escape"
    assert_raises(ArgumentError) { recording.filename_for(kind: :track, identity: "host", source: "camera") }
  end

  # ---- Machine d'état ----

  test "status defaults to starting via migration default" do
    r = Recording.create!(webinar: @webinar, started_at: Time.current)
    assert_equal "starting", r.status
  end

  test "unknown status is rejected by enum validation" do
    r = Recording.new(webinar: @webinar, status: "unknown")
    assert_not r.valid?
    assert r.errors[:status].any?
  end

  # ---- Scope actif ----

  test "active scope includes starting/recording/stopping only" do
    # L'invariant « un seul composite actif par webinaire »
    # contraint le composite ; les tracks
    # coexistent → on utilise trois kinds/webinars distincts pour tenir
    # 3 actives simultanées sans violer la validation.
    other1 = Webinar.create!(title: "w2", starts_at: 1.day.from_now, host_sub: "sub-marc")
    other2 = Webinar.create!(title: "w3", starts_at: 1.day.from_now, host_sub: "sub-marc")

    starting  = Recording.create!(webinar: @webinar, status: "starting")
    recording = Recording.create!(webinar: other1,   status: "recording", egress_id: "eg1")
    stopping  = Recording.create!(webinar: other2,   status: "stopping",  egress_id: "eg2")
    done      = Recording.create!(webinar: @webinar, status: "done",      egress_id: "eg3",
                                  path: "#{@webinar.slug}/x.mp4", ended_at: Time.current)
    failed    = Recording.create!(webinar: @webinar, status: "failed",    error_message: "boom")

    active_ids = Recording.active.pluck(:id)
    assert_includes active_ids, starting.id
    assert_includes active_ids, recording.id
    assert_includes active_ids, stopping.id
    assert_not_includes active_ids, done.id
    assert_not_includes active_ids, failed.id
  end

  # ---- egress_id unicité ----

  test "egress_id must be unique when present" do
    Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_shared")
    dup = Recording.new(webinar: @webinar, status: "recording", egress_id: "EG_shared")
    assert_not dup.valid? # unique index remonte via AR uniqueness OR insert conflict
    # On tente le save pour couvrir aussi l'index DB (SQLite UNIQUE).
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end

  test "multiple recordings with nil egress_id are allowed only in NON active statuses (SQLite semantics)" do
    # Deux Recordings :failed (hors ACTIVE_STATUSES) sur le même webinaire
    # → OK côté index unique partiel et OK
    # côté unicité egress_id (deux NULL autorisés en SQLite).
    Recording.create!(webinar: @webinar, status: "failed", error_message: "boom 1")
    Recording.create!(webinar: @webinar, status: "failed", error_message: "boom 2")
    assert_equal 2, Recording.where(egress_id: nil, status: "failed").count
  end

  # ---- Un seul Recording actif par webinaire ----

  test "only_one_active_recording_per_webinar: validation refuse un 2e actif (message lisible)" do
    Recording.create!(webinar: @webinar, status: "recording", egress_id: "EG_a")
    dup = Recording.new(webinar: @webinar, status: "starting")
    assert_not dup.valid?, "un 2e Recording actif doit être invalide"
    assert dup.errors[:base].any? { |m| m =~ /enregistrement.*actif/i },
           "message lisible attendu ; vu : #{dup.errors[:base].inspect}"
  end

  test "only_one_active_recording_per_webinar: index unique partiel DB (course concurrente)" do
    # Course simulée : deux appels create! atomiques, la validation ne
    # protège pas (SELECT/INSERT non atomique entre threads). L'index
    # unique partiel côté SQLite doit rejeter le 2e (RecordNotUnique).
    Recording.create!(webinar: @webinar, status: "starting")
    dup = Recording.new(webinar: @webinar, status: "starting")
    assert_raises(ActiveRecord::RecordNotUnique) do
      dup.save!(validate: false)
    end
  end

  test "only_one_active_recording_per_webinar: un actif + un done sur le même webinaire → OK" do
    done   = Recording.create!(webinar: @webinar, status: "done",
                                path: "#{@webinar.slug}/x.mp4",
                                ended_at: 1.hour.ago, started_at: 2.hours.ago)
    active = Recording.create!(webinar: @webinar, status: "starting")
    assert done.persisted?
    assert active.persisted?
  end

  test "only_one_active_recording_per_webinar: relaxe possible après une transition done" do
    # Cycle nominal : starting → recording → done → nouvelle starting.
    r1 = Recording.create!(webinar: @webinar, status: "starting", egress_id: "EG_1")
    r1.update!(status: "done", path: "#{@webinar.slug}/a.mp4", ended_at: Time.current)
    r2 = Recording.create!(webinar: @webinar, status: "starting")
    assert r2.persisted?, "un nouveau Recording doit pouvoir démarrer après done"
  end

  test "only_one_active_recording_per_webinar: la validation ignore l'enregistrement en cours de mise à jour" do
    # Sinon on ne pourrait pas transitionner starting→recording (l'update
    # ferait échouer la validation « il existe déjà un actif = moi »).
    r = Recording.create!(webinar: @webinar, status: "starting")
    r.status = "recording"
    r.egress_id = "EG_x"
    assert r.valid?, "la validation doit s'auto-exclure : #{r.errors.full_messages.inspect}"
  end

  # ---- absolute_path : défense traversal ----

  test "absolute_path returns nil when path is blank" do
    r = Recording.new(webinar: @webinar, path: nil)
    assert_nil r.absolute_path
  end

  test "absolute_path resolves under recordings_root/<slug>/" do
    file_path = "#{@webinar.slug}/rec.mp4"
    FileUtils.mkdir_p(File.join(@root, @webinar.slug))
    File.write(File.join(@root, file_path), "fake mp4")

    r = Recording.new(webinar: @webinar, status: "done", path: file_path)
    resolved = r.absolute_path
    assert_not_nil resolved
    assert resolved.to_s.start_with?("#{Pathname.new(@root).cleanpath}/#{@webinar.slug}/")
    assert File.file?(resolved)
  end

  test "absolute_path rejects traversal via ../" do
    r = Recording.new(webinar: @webinar, status: "done",
                      path: "#{@webinar.slug}/../../etc/passwd")
    assert_nil r.absolute_path, "traversal must be blocked"
  end

  test "absolute_path rejects path missing slug prefix" do
    r = Recording.new(webinar: @webinar, status: "done",
                      path: "other-slug/rec.mp4")
    assert_nil r.absolute_path
  end

  test "absolute_path rejects absolute path (drops slug prefix)" do
    r = Recording.new(webinar: @webinar, status: "done",
                      path: "/etc/passwd")
    assert_nil r.absolute_path
  end

  # ---- Montage par personne : accès disque extraits de la vue ----

  test "kind participant est accepté et scoped par Recording.participants" do
    p = Recording.create!(webinar: @webinar, kind: "participant",
                          participant_identity: "speaker-1", path: nil)
    assert_equal "participant", p.kind
    assert_includes Recording.participants.to_a, p
  end

  # ---- Sous-arbre `participants/<slug>/` ------------

  test "participants_root pointe sous recordings_root/_participants (slug-reserved subdir)" do
    assert_equal Pathname.new(@root).join("_participants"), Recording.participants_root.cleanpath
  end

  test "absolute_path participant resolves under recordings_root/_participants/<slug>/" do
    rel = "_participants/#{@webinar.slug}/mux-speaker-7.mp4"
    FileUtils.mkdir_p(File.dirname(File.join(@root, rel)))
    File.write(File.join(@root, rel), "fake mp4")

    p = Recording.new(webinar: @webinar, kind: "participant", status: "done",
                      participant_identity: "speaker-7", path: rel)
    resolved = p.absolute_path
    assert_not_nil resolved, "participant valide doit résoudre"
    assert resolved.to_s.start_with?("#{Pathname.new(@root).cleanpath}/_participants/#{@webinar.slug}/")
    assert File.file?(resolved)
  end

  test "absolute_path participant refuse un path sans préfixe participants/<slug>/" do
    # Un participant qui pointerait sur l'ancienne arborescence <slug>/ est refusé.
    p = Recording.new(webinar: @webinar, kind: "participant", status: "done",
                      participant_identity: "speaker-7",
                      path: "#{@webinar.slug}/mux-speaker-7.mp4")
    assert_nil p.absolute_path, "sans participants/<slug>/ → nil"
  end

  test "absolute_path participant refuse un traversal sous participants/<slug>/" do
    p = Recording.new(webinar: @webinar, kind: "participant", status: "done",
                      participant_identity: "speaker-7",
                      path: "_participants/#{@webinar.slug}/../../etc/passwd")
    assert_nil p.absolute_path, "traversal sous participants doit être bloqué"
  end

  test "absolute_path participant refuse un slug différent" do
    p = Recording.new(webinar: @webinar, kind: "participant", status: "done",
                      participant_identity: "speaker-7",
                      path: "_participants/autre-slug/mux-speaker-7.mp4")
    assert_nil p.absolute_path
  end

  test "absolute_path composite refuse un path sous participants/" do
    # Préfixes mutuellement exclusifs : un composite ne peut pas être
    # résolu depuis l'arborescence participants/ (ni l'inverse).
    r = Recording.new(webinar: @webinar, kind: "composite", status: "done",
                      path: "_participants/#{@webinar.slug}/mux-x.mp4")
    assert_nil r.absolute_path, "composite doit rester sous <slug>/"
  end

  test "downloadable? false si not done, true si done + fichier présent" do
    file_path = "#{@webinar.slug}/mux.mp4"
    FileUtils.mkdir_p(File.join(@root, @webinar.slug))
    File.write(File.join(@root, file_path), "data")

    rec_recording = Recording.new(webinar: @webinar, status: "recording", path: file_path)
    assert_not rec_recording.downloadable?, "actif n'est pas téléchargeable"

    rec_done = Recording.new(webinar: @webinar, status: "done", path: file_path)
    assert rec_done.downloadable?

    rec_nofile = Recording.new(webinar: @webinar, status: "done",
                               path: "#{@webinar.slug}/ghost.mp4")
    assert_not rec_nofile.downloadable?, "done sans fichier n'est pas téléchargeable"
  end

  test "size_on_disk retourne la taille ou nil (jamais lève)" do
    file_path = "#{@webinar.slug}/mux.mp4"
    FileUtils.mkdir_p(File.join(@root, @webinar.slug))
    File.write(File.join(@root, file_path), "abcdef")

    rec = Recording.new(webinar: @webinar, status: "done", path: file_path)
    assert_equal 6, rec.size_on_disk

    rec_blank = Recording.new(webinar: @webinar, status: "done", path: nil)
    assert_nil rec_blank.size_on_disk

    rec_missing = Recording.new(webinar: @webinar, status: "done",
                                path: "#{@webinar.slug}/ghost.mp4")
    assert_nil rec_missing.size_on_disk
  end

  test "extension dérive du path (.mp4 / .m4a / vide)" do
    assert_equal ".mp4", Recording.new(webinar: @webinar, path: "x/y.mp4").extension
    assert_equal ".m4a", Recording.new(webinar: @webinar, path: "x/y.m4a").extension
    assert_equal "",     Recording.new(webinar: @webinar, path: nil).extension
  end
end
