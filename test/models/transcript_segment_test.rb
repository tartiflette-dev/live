# frozen_string_literal: true

require "test_helper"

# Segment de transcript archive. L'idempotence par (webinar_id,
# segment_id) est l'invariant central — l'agent transcriber retente les
# POST échoués, deux lignes ne doivent jamais exister pour un même id.
class TranscriptSegmentTest < ActiveSupport::TestCase
  setup do
    @webinar = Webinar.create!(title: "Café IA", starts_at: 1.hour.from_now, host_sub: "sub-marc")
  end

  test "crée un segment valide" do
    segment = @webinar.transcript_segments.create!(
      participant_identity: "speaker-42",
      speaker_name: "Pauline",
      text: "Bonjour tout le monde.",
      started_at: Time.current - 10.seconds,
      ended_at: Time.current,
      segment_id: SecureRandom.uuid,
    )
    assert segment.persisted?
  end

  test "segment_id unique par webinar — doublon rejeté (validation modèle)" do
    sid = SecureRandom.uuid
    @webinar.transcript_segments.create!(
      participant_identity: "speaker-1", text: "A",
      started_at: Time.current, ended_at: Time.current, segment_id: sid,
    )
    doublon = @webinar.transcript_segments.build(
      participant_identity: "speaker-1", text: "B",
      started_at: Time.current, ended_at: Time.current, segment_id: sid,
    )
    assert_not doublon.save
    assert doublon.errors[:segment_id].any?
  end

  test "contrainte unique au niveau DB — bypass de validation ignoré" do
    sid = SecureRandom.uuid
    now = Time.current
    @webinar.transcript_segments.create!(
      participant_identity: "speaker-1", text: "A",
      started_at: now, ended_at: now, segment_id: sid,
    )
    assert_raises(ActiveRecord::RecordNotUnique) do
      TranscriptSegment.insert_all!([ {
        webinar_id: @webinar.id, participant_identity: "speaker-1", text: "B",
        started_at: now, ended_at: now, segment_id: sid,
        created_at: now, updated_at: now
      } ])
    end
  end

  test "le même segment_id sur deux webinaires différents est accepté" do
    sid = SecureRandom.uuid
    other = Webinar.create!(title: "Autre", starts_at: 1.hour.from_now, host_sub: "sub-x")
    @webinar.transcript_segments.create!(participant_identity: "a", text: "x",
      started_at: Time.current, ended_at: Time.current, segment_id: sid)
    assert_nothing_raised do
      other.transcript_segments.create!(participant_identity: "b", text: "y",
        started_at: Time.current, ended_at: Time.current, segment_id: sid)
    end
  end

  test "formatted_text rend `[HH:MM:SS] Nom : texte`, chronologique, fuseau Paris" do
    base = Time.zone.local(2026, 10, 7, 9, 0, 10)
    @webinar.transcript_segments.create!(participant_identity: "speaker-1",
      speaker_name: "Pauline", text: "Deuxième phrase.", segment_id: "b",
      started_at: base + 5.seconds, ended_at: base + 8.seconds)
    @webinar.transcript_segments.create!(participant_identity: "host-x",
      speaker_name: "Marc", text: "Première phrase.", segment_id: "a",
      started_at: base, ended_at: base + 2.seconds)
    out = TranscriptSegment.formatted_text(@webinar.transcript_segments.chronological)
    assert_equal "[09:00:10] Marc : Première phrase.\n[09:00:15] Pauline : Deuxième phrase.\n", out
  end

  test "formatted_text retombe sur l'identité quand le nom est absent" do
    @webinar.transcript_segments.create!(participant_identity: "speaker-42",
      text: "Ok.", segment_id: "s", started_at: Time.zone.local(2026, 10, 7, 9, 0, 0),
      ended_at: Time.zone.local(2026, 10, 7, 9, 0, 1))
    assert_match(/speaker-42 : Ok\./, TranscriptSegment.formatted_text)
  end
end
