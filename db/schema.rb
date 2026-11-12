# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_11_230000) do
  create_table "announcement_deliveries", force: :cascade do |t|
    t.integer "announcement_id", null: false
    t.string "recipient_digest", null: false
    t.string "holder_type", null: false
    t.bigint "holder_id", null: false
    t.datetime "enqueued_at"
    t.datetime "scheduled_at"
    t.datetime "sending_at"
    t.datetime "delivered_at"
    t.datetime "skipped_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["announcement_id", "recipient_digest"], name: "index_announcement_deliveries_on_recipient", unique: true
  end

  create_table "announcements", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "audience", null: false
    t.string "subject", null: false
    t.text "body", null: false
    t.string "author_sub", null: false
    t.string "author_email", null: false
    t.string "author_role", null: false
    t.integer "recipients_count", default: 0, null: false
    t.string "dispatch_token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dispatch_token"], name: "index_announcements_on_dispatch_token", unique: true
    t.index ["webinar_id"], name: "index_announcements_on_webinar_id"
  end

  create_table "calendar_subscriptions", force: :cascade do |t|
    t.string "email", null: false
    t.string "token", null: false
    t.datetime "revoked_at"
    t.datetime "last_fetched_at"
    t.integer "fetch_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_calendar_subscriptions_on_email", unique: true
    t.index ["token"], name: "index_calendar_subscriptions_on_token", unique: true
  end

  create_table "camera_samples", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "participant_identity", null: false
    t.string "publication_sid"
    t.string "event", default: "sample", null: false
    t.integer "top_width"
    t.integer "top_height"
    t.float "frames_per_second"
    t.string "quality_limitation_reason"
    t.string "encoder_implementation"
    t.integer "capture_width"
    t.integer "capture_height"
    t.integer "paused_layers", default: 0, null: false
    t.json "layers", default: [], null: false
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_camera_samples_on_created_at"
    t.index ["webinar_id", "participant_identity", "created_at"], name: "index_camera_samples_on_webinar_identity_time"
  end

  create_table "chapter_sets", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "llm_outcome", limit: 40
    t.string "llm_model", limit: 120
    t.datetime "generated_at"
    t.string "transcript_digest", limit: 80
    t.datetime "validated_at"
    t.integer "validated_by_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["validated_by_id"], name: "index_chapter_sets_on_validated_by_id"
    t.index ["webinar_id"], name: "index_chapter_sets_on_webinar_id", unique: true
  end

  create_table "chapters", force: :cascade do |t|
    t.integer "chapter_set_id", null: false
    t.datetime "starts_at", null: false
    t.string "title", limit: 120, null: false
    t.json "themes", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chapter_set_id", "starts_at"], name: "index_chapters_on_chapter_set_id_and_starts_at"
  end

  create_table "crm_disappearances", force: :cascade do |t|
    t.string "contact_id", null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.index ["contact_id"], name: "index_crm_disappearances_on_contact_id", unique: true
  end

  create_table "crm_erasures", force: :cascade do |t|
    t.string "email_digest", null: false
    t.datetime "erased_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_digest"], name: "index_crm_erasures_on_email_digest", unique: true
  end

  create_table "device_preferences", force: :cascade do |t|
    t.string "owner_type", null: false
    t.integer "owner_id", null: false
    t.string "audio_input_device_id"
    t.string "audio_input_label"
    t.string "video_input_device_id"
    t.string "video_input_label"
    t.boolean "audio_enabled"
    t.boolean "video_enabled"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id"], name: "index_device_preferences_on_owner", unique: true
  end

  create_table "episode_publications", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "status", null: false
    t.string "folder"
    t.string "folder_url"
    t.string "review_folder"
    t.string "review_folder_url"
    t.json "files", default: [], null: false
    t.json "notified_emails", default: [], null: false
    t.string "error_message"
    t.integer "attempts", default: 0, null: false
    t.datetime "queued_at"
    t.datetime "started_at"
    t.datetime "published_at"
    t.datetime "notified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.json "deposited_versions", default: {}, null: false
    t.index ["webinar_id"], name: "index_episode_publications_on_webinar_id", unique: true
  end

  create_table "hand_raises", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "granted_at"
    t.string "last_error"
    t.datetime "raised_at", null: false
    t.integer "registration_id", null: false
    t.datetime "revoked_at"
    t.string "state", default: "waiting", null: false
    t.datetime "updated_at", null: false
    t.integer "webinar_id", null: false
    t.index ["registration_id"], name: "index_hand_raises_on_registration_id"
    t.index ["registration_id"], name: "one_active_hand_per_registration", unique: true, where: "revoked_at IS NULL"
    t.index ["webinar_id"], name: "index_hand_raises_on_webinar_id"
  end

  create_table "host_attendances", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.integer "webinar_host_id"
    t.string "token", null: false
    t.string "answer"
    t.datetime "answered_at"
    t.datetime "answered_for_starts_at"
    t.datetime "requested_at"
    t.datetime "requested_for_starts_at"
    t.datetime "reminded_for_starts_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token"], name: "index_host_attendances_on_token", unique: true
    t.index ["webinar_host_id"], name: "index_host_attendances_on_webinar_host_id", unique: true
    t.index ["webinar_id"], name: "index_host_attendances_on_owner", unique: true, where: "webinar_host_id IS NULL"
    t.index ["webinar_id"], name: "index_host_attendances_on_webinar_id"
  end

  create_table "host_invitations", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "token", null: false
    t.integer "max_uses", default: 3, null: false
    t.integer "uses_count", default: 0, null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.string "created_by_sub", null: false
    t.string "signup_url", limit: 2048
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token"], name: "index_host_invitations_on_token", unique: true
    t.index ["webinar_id"], name: "index_host_invitations_on_webinar_id"
    t.check_constraint "max_uses >= 1 AND uses_count >= 0 AND uses_count <= max_uses", name: "host_invitations_uses_within_limit"
  end

  create_table "messages", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "author_identity", limit: 128, null: false
    t.string "name", limit: 120, null: false
    t.text "body", null: false
    t.string "kind", default: "chat", null: false
    t.datetime "answered_at"
    t.datetime "pinned_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["webinar_id", "updated_at", "id"], name: "index_messages_on_webinar_id_and_updated_at_and_id"
  end

  create_table "packs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "host_sub", null: false
    t.string "name", null: false
    t.integer "price_cents", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["host_sub"], name: "index_packs_on_host_sub"
  end

  create_table "participant_consents", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "holder_type", null: false
    t.integer "holder_id", null: false
    t.string "participant_identity", limit: 128, null: false
    t.boolean "recording_accepted", null: false
    t.boolean "excerpts_accepted", null: false
    t.boolean "adult_declared", null: false
    t.string "policy_version", null: false
    t.string "recording_label", null: false
    t.string "excerpts_label", null: false
    t.string "adult_label", null: false
    t.datetime "consented_at", null: false
    t.datetime "withdrawn_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["holder_type", "holder_id"], name: "index_participant_consents_on_holder_type_and_holder_id"
    t.index ["webinar_id", "holder_type", "holder_id"], name: "one_current_participant_consent_per_holder", unique: true, where: "withdrawn_at IS NULL"
    t.index ["webinar_id", "participant_identity"], name: "index_participant_consents_on_webinar_and_identity"
    t.index ["webinar_id"], name: "index_participant_consents_on_webinar_id"
  end

  create_table "poll_responses", force: :cascade do |t|
    t.integer "poll_id", null: false
    t.string "respondent_identity", null: false
    t.integer "registration_id"
    t.string "name", null: false
    t.json "value", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "origin", default: "live", null: false
    t.integer "user_id"
    t.index ["poll_id", "respondent_identity"], name: "index_poll_responses_on_poll_id_and_respondent_identity", unique: true
    t.index ["registration_id"], name: "index_poll_responses_on_registration_id"
    t.index ["user_id"], name: "index_poll_responses_on_user_id"
    t.check_constraint "origin = 'live' OR ((registration_id IS NULL) <> (user_id IS NULL))", name: "poll_responses_replay_one_viewer"
    t.check_constraint "origin IN ('live', 'replay')", name: "poll_responses_origin"
  end

  create_table "polls", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.integer "position", null: false
    t.string "kind", null: false
    t.boolean "multiple", default: false, null: false
    t.string "label", null: false
    t.json "options"
    t.integer "planned_minute"
    t.text "note"
    t.datetime "opened_at"
    t.datetime "closed_at"
    t.datetime "results_shown_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["webinar_id", "position"], name: "index_polls_on_webinar_id_and_position"
    t.index ["webinar_id"], name: "index_polls_one_open_per_webinar", unique: true, where: "opened_at IS NOT NULL AND closed_at IS NULL"
  end

  create_table "presence_events", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "kind", null: false
    t.string "identity"
    t.datetime "occurred_at", null: false
    t.string "source", null: false
    t.string "livekit_event_id"
    t.datetime "created_at", null: false
    t.index ["livekit_event_id"], name: "index_presence_events_on_livekit_event_id", unique: true, where: "livekit_event_id IS NOT NULL"
    t.index ["webinar_id", "identity", "kind", "occurred_at"], name: "index_presence_events_on_attempts"
    t.index ["webinar_id", "occurred_at"], name: "index_presence_events_on_webinar_id_and_occurred_at"
  end

  create_table "qa_item_messages", force: :cascade do |t|
    t.integer "qa_item_id", null: false
    t.integer "message_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_qa_item_messages_on_message_id", unique: true
    t.index ["qa_item_id"], name: "index_qa_item_messages_on_qa_item_id"
  end

  create_table "qa_items", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "label", limit: 500, null: false
    t.string "status", default: "open", null: false
    t.string "source", null: false
    t.string "llm_model", limit: 120
    t.integer "label_message_id"
    t.datetime "answered_at"
    t.datetime "displayed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.float "video_position"
    t.integer "registration_id"
    t.integer "user_id"
    t.index ["registration_id"], name: "index_qa_items_on_registration_id"
    t.index ["source", "status"], name: "index_qa_items_on_source_and_status"
    t.index ["user_id"], name: "index_qa_items_on_user_id"
    t.index ["webinar_id", "status"], name: "index_qa_items_on_webinar_id_and_status"
    t.index ["webinar_id"], name: "index_qa_items_one_displayed_per_webinar", unique: true, where: "displayed_at IS NOT NULL"
    t.check_constraint "source <> 'replay' OR (video_position IS NOT NULL AND (registration_id IS NULL) <> (user_id IS NULL))", name: "qa_items_replay_author"
    t.check_constraint "source = 'replay' OR (registration_id IS NULL AND user_id IS NULL)", name: "qa_items_live_without_replay_author"
  end

  create_table "recordings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "egress_id"
    t.datetime "ended_at"
    t.string "error_message"
    t.string "kind", default: "composite", null: false
    t.string "participant_identity"
    t.string "path"
    t.datetime "started_at"
    t.string "status", default: "starting", null: false
    t.string "track_source"
    t.datetime "updated_at", null: false
    t.integer "webinar_id", null: false
    t.string "track_sid"
    t.string "output_prefix"
    t.datetime "completion_received_at"
    t.json "source_track_ids"
    t.datetime "media_started_at"
    t.index ["egress_id"], name: "index_recordings_on_egress_id", unique: true
    t.index ["webinar_id", "participant_identity", "source_track_ids"], name: "index_recordings_on_participant_sources", unique: true, where: "kind = 'participant'"
    t.index ["webinar_id", "status"], name: "index_recordings_on_webinar_id_and_status"
    t.index ["webinar_id", "track_sid"], name: "index_recordings_on_active_track_claim", unique: true, where: "track_sid IS NOT NULL AND status IN ('starting', 'recording', 'stopping')"
    t.index ["webinar_id", "track_sid"], name: "index_recordings_on_webinar_id_and_track_sid"
    t.index ["webinar_id"], name: "index_recordings_on_active_composite_webinar_id", unique: true, where: "kind = 'composite' AND status IN ('starting', 'recording', 'stopping')"
    t.index ["webinar_id"], name: "index_recordings_on_webinar_id"
  end

  create_table "registration_reminder_runs", force: :cascade do |t|
    t.datetime "ran_at", null: false
    t.integer "due", default: 0, null: false
    t.integer "sent", default: 0, null: false
    t.integer "skipped", default: 0, null: false
    t.integer "smtp_retry", default: 0, null: false
    t.integer "abandoned", default: 0, null: false
    t.integer "failed", default: 0, null: false
    t.index ["ran_at"], name: "index_registration_reminder_runs_on_ran_at"
  end

  create_table "registration_requests", force: :cascade do |t|
    t.string "name", null: false
    t.string "email", limit: 254, null: false
    t.string "token", null: false
    t.string "source"
    t.string "profile"
    t.text "message"
    t.boolean "notify_next", default: false, null: false
    t.datetime "confirmed_at"
    t.datetime "pushed_to_crm_at"
    t.string "crm_contact_id"
    t.integer "crm_sync_attempts", default: 0, null: false
    t.integer "crm_last_error_code"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "crm_last_attempt_at"
    t.datetime "crm_next_attempt_at"
    t.datetime "crm_contact_gone_at"
    t.boolean "marketing_box_checked", default: false, null: false
    t.boolean "marketing_consent", default: false, null: false
    t.datetime "marketing_consent_at"
    t.string "marketing_consent_policy_version"
    t.string "marketing_withdrawal_token"
    t.datetime "marketing_consent_withdrawn_at"
    t.datetime "crm_marketing_consent_pushed_at"
    t.datetime "crm_withdrawal_pushed_at"
    t.string "marketing_consent_label"
    t.datetime "team_notified_at"
    t.datetime "whatsapp_relayed_at"
    t.datetime "community_announced_at"
    t.datetime "community_announcement_withheld_at"
    t.datetime "notify_next_stopped_at"
    t.index ["marketing_withdrawal_token"], name: "index_registration_requests_on_marketing_withdrawal_token", unique: true
    t.index ["token"], name: "index_registration_requests_on_token", unique: true
  end

  create_table "registrations", force: :cascade do |t|
    t.datetime "confirmed_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", null: false
    t.datetime "paid_confirmed_at"
    t.json "reminder_sent_at", default: {}, null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.integer "webinar_id", null: false
    t.boolean "marketing_consent", default: false, null: false
    t.datetime "marketing_consent_at"
    t.datetime "pushed_to_crm_at"
    t.integer "crm_sync_attempts", default: 0, null: false
    t.string "crm_contact_id"
    t.integer "crm_last_error_code"
    t.string "marketing_consent_token"
    t.datetime "marketing_consent_token_expires_at"
    t.string "marketing_withdrawal_token"
    t.datetime "marketing_consent_withdrawn_at"
    t.datetime "crm_withdrawal_pushed_at"
    t.integer "registration_request_id"
    t.datetime "crm_marketing_consent_pushed_at"
    t.datetime "crm_enrolled_at"
    t.datetime "crm_last_attempt_at"
    t.datetime "crm_next_attempt_at"
    t.integer "crm_withdrawal_attempts", default: 0, null: false
    t.datetime "crm_withdrawal_last_attempt_at"
    t.datetime "crm_withdrawal_next_attempt_at"
    t.integer "crm_withdrawal_last_error_code"
    t.datetime "crm_backfilled_at"
    t.datetime "crm_sync_contact_gone_at"
    t.string "marketing_consent_source"
    t.string "marketing_consent_path"
    t.string "marketing_consent_policy_version"
    t.integer "marketing_consent_request_id"
    t.string "marketing_consent_label"
    t.datetime "room_removed_at"
    t.string "participation", default: "spectator", null: false
    t.datetime "instant_access_at"
    t.string "identity_secret"
    t.string "retired_email_digest"
    t.datetime "participation_chosen_at"
    t.datetime "room_joined_at"
    t.index ["marketing_consent_token"], name: "index_registrations_on_marketing_consent_token", unique: true, where: "marketing_consent_token IS NOT NULL"
    t.index ["marketing_withdrawal_token"], name: "index_registrations_on_marketing_withdrawal_token", unique: true, where: "marketing_withdrawal_token IS NOT NULL"
    t.index ["registration_request_id"], name: "index_registrations_on_registration_request_id"
    t.index ["retired_email_digest"], name: "index_registrations_on_retired_email_digest", where: "retired_email_digest IS NOT NULL"
    t.index ["token"], name: "index_registrations_on_token", unique: true
    t.index ["webinar_id", "email"], name: "index_registrations_on_webinar_id_and_email", unique: true
    t.index ["webinar_id"], name: "index_registrations_on_webinar_id"
  end

  create_table "replay_searches", force: :cascade do |t|
    t.string "query", limit: 100, null: false
    t.string "normalized_query", limit: 100, null: false
    t.integer "results_count", null: false
    t.integer "registration_id"
    t.integer "user_id"
    t.datetime "created_at", null: false
    t.index ["created_at"], name: "index_replay_searches_on_created_at"
    t.index ["normalized_query"], name: "index_replay_searches_on_normalized_query"
    t.index ["registration_id"], name: "index_replay_searches_on_registration_id"
    t.index ["user_id"], name: "index_replay_searches_on_user_id"
    t.check_constraint "(registration_id IS NULL) <> (user_id IS NULL)", name: "replay_searches_one_author"
  end

  create_table "replay_views", force: :cascade do |t|
    t.integer "replay_id", null: false
    t.integer "registration_id"
    t.integer "user_id"
    t.string "session_key", null: false
    t.datetime "started_at", null: false
    t.datetime "last_seen_at", null: false
    t.float "last_position", default: 0.0, null: false
    t.boolean "playing", default: false, null: false
    t.float "watched_seconds", default: 0.0, null: false
    t.json "intervals", default: [], null: false
    t.integer "beats_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["registration_id"], name: "index_replay_views_on_registration_id"
    t.index ["replay_id", "session_key"], name: "index_replay_views_on_replay_id_and_session_key", unique: true
    t.index ["user_id"], name: "index_replay_views_on_user_id"
    t.check_constraint "(registration_id IS NULL) <> (user_id IS NULL)", name: "replay_views_one_viewer"
  end

  create_table "replays", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.integer "recording_id", null: false
    t.string "derived_path"
    t.datetime "published_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["recording_id"], name: "index_replays_on_recording_id"
    t.index ["webinar_id"], name: "index_replays_on_webinar_id", unique: true
  end

  create_table "speakers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "revoked_at"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.integer "webinar_id", null: false
    t.string "email", limit: 254
    t.datetime "room_removed_at"
    t.integer "registration_id"
    t.string "declared_email", limit: 254
    t.string "link_token"
    t.integer "replaced_by_id"
    t.datetime "link_issued_at"
    t.index ["link_token"], name: "index_speakers_on_link_token", unique: true, where: "link_token IS NOT NULL"
    t.index ["registration_id"], name: "index_speakers_on_registration_id"
    t.index ["replaced_by_id"], name: "index_speakers_on_replaced_by_id"
    t.index ["token"], name: "index_speakers_on_token", unique: true
    t.index ["webinar_id"], name: "index_speakers_on_webinar_id"
  end

  create_table "spotlight_changes", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "identity", limit: 256
    t.datetime "changed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["webinar_id", "changed_at"], name: "index_spotlight_changes_on_webinar_id_and_changed_at"
  end

  create_table "transcript_segments", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "participant_identity", limit: 128, null: false
    t.string "speaker_name", limit: 128
    t.text "text", null: false
    t.datetime "started_at", null: false
    t.datetime "ended_at", null: false
    t.string "segment_id", limit: 128, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["webinar_id", "segment_id"], name: "index_transcript_segments_on_webinar_id_and_segment_id", unique: true
    t.index ["webinar_id", "started_at"], name: "index_transcript_segments_on_webinar_id_and_started_at"
    t.index ["webinar_id"], name: "index_transcript_segments_on_webinar_id"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "oidc_sub", null: false
    t.datetime "updated_at", null: false
    t.json "oidc_groups", default: [], null: false
    t.boolean "email_verified", default: false, null: false
    t.datetime "oidc_groups_fetched_at"
    t.string "email_verified_for"
    t.index "LOWER(email)", name: "index_users_on_lower_email", unique: true
    t.index ["oidc_sub"], name: "index_users_on_oidc_sub", unique: true
  end

  create_table "webinar_change_deliveries", force: :cascade do |t|
    t.integer "webinar_change_notice_id", null: false
    t.integer "registration_id", null: false
    t.integer "revision", null: false
    t.string "kind", null: false
    t.datetime "created_at", null: false
    t.index ["registration_id"], name: "index_webinar_change_deliveries_on_registration_id"
    t.index ["webinar_change_notice_id", "revision", "registration_id"], name: "index_webinar_change_deliveries_once", unique: true
  end

  create_table "webinar_change_notices", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.datetime "starts_at", null: false
    t.boolean "published", null: false
    t.integer "revision", default: 0, null: false
    t.datetime "changed_at", null: false
    t.datetime "notified_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["webinar_id"], name: "index_webinar_change_notices_on_webinar_id", unique: true
  end

  create_table "webinar_hosts", force: :cascade do |t|
    t.integer "webinar_id", null: false
    t.string "email", null: false
    t.string "invited_by_sub", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "claimed_sub"
    t.index "webinar_id, LOWER(email)", name: "index_webinar_hosts_on_webinar_id_and_lower_email", unique: true
    t.index ["claimed_sub"], name: "index_webinar_hosts_on_claimed_sub"
    t.index ["webinar_id"], name: "index_webinar_hosts_on_webinar_id"
  end

  create_table "webinars", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "ended_at"
    t.string "host_sub", null: false
    t.string "kind", default: "cafe_ia", null: false
    t.json "layout"
    t.integer "pack_id"
    t.integer "price_cents", default: 0, null: false
    t.string "room_name", null: false
    t.string "slug", null: false
    t.datetime "started_at"
    t.datetime "starts_at", null: false
    t.string "state", default: "draft", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.string "visibility", default: "draft", null: false
    t.string "share_token"
    t.datetime "room_empty_since"
    t.string "qa_llm_outcome", limit: 20
    t.datetime "qa_llm_at"
    t.integer "qa_llm_duration_ms"
    t.string "topic"
    t.text "topic_summary"
    t.json "announced_speakers", default: [], null: false
    t.string "lead_host_name"
    t.datetime "transcriber_absent_since"
    t.datetime "transcription_interrupted_at"
    t.index ["host_sub"], name: "index_webinars_on_host_sub"
    t.index ["room_name"], name: "index_webinars_on_room_name", unique: true
    t.index ["share_token"], name: "index_webinars_on_share_token", unique: true, where: "share_token IS NOT NULL"
    t.index ["slug"], name: "index_webinars_on_slug", unique: true
  end

  add_foreign_key "announcement_deliveries", "announcements"
  add_foreign_key "announcements", "webinars"
  add_foreign_key "camera_samples", "webinars"
  add_foreign_key "chapter_sets", "users", column: "validated_by_id", on_delete: :nullify
  add_foreign_key "chapter_sets", "webinars"
  add_foreign_key "chapters", "chapter_sets", on_delete: :cascade
  add_foreign_key "episode_publications", "webinars"
  add_foreign_key "hand_raises", "registrations"
  add_foreign_key "hand_raises", "webinars"
  add_foreign_key "host_attendances", "webinar_hosts", on_delete: :cascade
  add_foreign_key "host_attendances", "webinars", on_delete: :cascade
  add_foreign_key "host_invitations", "webinars"
  add_foreign_key "messages", "webinars"
  add_foreign_key "participant_consents", "webinars"
  add_foreign_key "poll_responses", "polls"
  add_foreign_key "poll_responses", "registrations"
  add_foreign_key "poll_responses", "users", on_delete: :cascade
  add_foreign_key "polls", "webinars"
  add_foreign_key "presence_events", "webinars", on_delete: :cascade
  add_foreign_key "qa_item_messages", "messages"
  add_foreign_key "qa_item_messages", "qa_items"
  add_foreign_key "qa_items", "messages", column: "label_message_id"
  add_foreign_key "qa_items", "registrations", on_delete: :cascade
  add_foreign_key "qa_items", "users", on_delete: :cascade
  add_foreign_key "qa_items", "webinars"
  add_foreign_key "recordings", "webinars"
  add_foreign_key "registrations", "registration_requests"
  add_foreign_key "registrations", "webinars"
  add_foreign_key "replay_searches", "registrations", on_delete: :cascade
  add_foreign_key "replay_searches", "users", on_delete: :cascade
  add_foreign_key "replay_views", "registrations", on_delete: :cascade
  add_foreign_key "replay_views", "replays", on_delete: :cascade
  add_foreign_key "replay_views", "users", on_delete: :cascade
  add_foreign_key "replays", "recordings", on_delete: :cascade
  add_foreign_key "replays", "webinars"
  add_foreign_key "speakers", "registrations", on_delete: :nullify
  add_foreign_key "speakers", "speakers", column: "replaced_by_id", on_delete: :nullify
  add_foreign_key "speakers", "webinars"
  add_foreign_key "spotlight_changes", "webinars"
  add_foreign_key "transcript_segments", "webinars"
  add_foreign_key "webinar_change_deliveries", "registrations", on_delete: :cascade
  add_foreign_key "webinar_change_deliveries", "webinar_change_notices", on_delete: :cascade
  add_foreign_key "webinar_change_notices", "webinars", on_delete: :cascade
  add_foreign_key "webinar_hosts", "webinars"

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
  create_virtual_table "replay_search_entries", "fts5", ["body", "webinar_id UNINDEXED", "kind UNINDEXED", "at UNINDEXED", "tokenize='unicode61 remove_diacritics 2'"]
end
