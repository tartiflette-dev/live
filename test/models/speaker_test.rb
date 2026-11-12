require "test_helper"

class SpeakerTest < ActiveSupport::TestCase
  # Rattachement prouvé par la personne (lien participants).
  test "rattacher l'adresse déclarée : une fois, à l'inscription de cette adresse" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    registration = webinar.registrations.create!(name: "Inès", email: "ines@example.test")
    speaker = webinar.speakers.create!(name: "Inès", declared_email: " Ines@Example.TEST ")

    assert_equal "ines@example.test", speaker.declared_email
    assert_predicate speaker.link_token, :present?
    assert_equal speaker, Speaker.find_by_link_token(speaker.link_token)

    assert_equal :linked, speaker.link_to_declared_registration!
    assert_equal [ registration, nil ], [ speaker.reload.registration, speaker.link_token ]
    assert_not speaker.link_to_declared_registration!, "usage unique"
    assert_nil Speaker.find_by_link_token(nil)
  end

  # La preuve de la boîte de l'intervenant ne promeut
  # jamais l'identité provisoire ouverte sous son adresse.
  test "adresse ouverte en identité provisoire : pierre tombale sans retrait, inscription neuve non confirmée, rattachée" do
    webinar = Webinar.create!(title: "Café", starts_at: Time.current, host_sub: "h", visibility: "published", state: "live", started_at: Time.current)
    provisional = webinar.registrations.create!(name: "Intrus", email: "o@example.test", instant_access_at: Time.current)
    speaker = webinar.speakers.create!(name: "Olga", declared_email: "o@example.test")

    assert_equal :created, speaker.link_to_declared_registration!

    provisional.reload
    assert provisional.retired?
    assert_nil provisional.room_removed_at, "pierre tombale sans retrait"
    assert provisional.room_access?, "elle reste au navigateur qui l'a ouverte"
    fresh = speaker.reload.registration
    assert_not_equal provisional, fresh
    assert_equal [ "o@example.test", "Olga", "participant", false ], [ fresh.email, fresh.name, fresh.participation, fresh.confirmed? ]
    assert_not fresh.provisional?
  end

  test "adresse dont l'inscription est déjà une pierre tombale : inscription neuve, rattachée" do
    webinar = Webinar.create!(title: "Café", starts_at: Time.current, host_sub: "h", visibility: "published", state: "live", started_at: Time.current)
    tombstone = webinar.registrations.create!(name: "Intrus", email: "o@example.test", instant_access_at: Time.current)
    tombstone.remove_from_room!
    speaker = webinar.speakers.create!(name: "Olga", declared_email: "o@example.test")

    assert_equal :created, speaker.link_to_declared_registration!
    assert_equal "o@example.test", speaker.reload.registration.email
    assert_nil speaker.registration.room_removed_at
  end

  test "le lien de rattachement expire au bout de 14 jours" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    webinar.registrations.create!(name: "Inès", email: "ines@example.test")
    speaker = webinar.speakers.create!(name: "Inès", declared_email: "ines@example.test")

    travel 14.days + 1.minute do
      assert speaker.link_expired?
      assert_not speaker.link_to_declared_registration!
    end
    assert_nil speaker.reload.registration
  end

  test "pas de rattachement d'un intervenant retiré, ni vers une inscription effacée" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    registration = webinar.registrations.create!(name: "Inès", email: "ines@example.test")
    removed = webinar.speakers.create!(name: "Inès", declared_email: "ines@example.test")
    removed.remove_from_room!
    orphan = webinar.speakers.create!(name: "Inès", declared_email: "ines@example.test")

    assert_not removed.link_to_declared_registration!
    registration.destroy!
    assert_not orphan.link_to_declared_registration!
    assert_nil orphan.reload.registration
  end

  test "un intervenant rattaché d'emblée, ou ajouté par l'animation, n'a pas de lien de rattachement" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    registration = webinar.registrations.create!(name: "Inès", email: "ines@example.test")

    assert_nil webinar.speakers.create!(name: "Inès", registration: registration).link_token
    assert_nil webinar.speakers.create!(name: "Ajouté par l'animation").link_token
  end

  setup do
    @webinar = Webinar.create!(title: "Speakers", starts_at: 1.day.from_now, host_sub: "host")
  end

  test "speaker_schema_and_token generates unique opaque invitations" do
    first = @webinar.speakers.create!(name: " Basile ")
    second = @webinar.speakers.create!(name: "Marc")
    assert_equal "Basile", first.name
    assert_match(/\A[A-Za-z0-9_-]{32}\z/, first.token)
    assert_not_equal first.token, second.token
    assert_equal @webinar, first.webinar
    assert_equal 2, Speaker.active.count
    assert_not_includes first.inspect, first.token
    duplicate = @webinar.speakers.build(name: "Other", token: first.token)
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:token, :taken)
  end

  # Retirer ≠ révoquer : seul le retrait depuis la régie pose
  # `room_removed_at` ; il révoque aussi le lien, une seule fois.
  test "remove_from_room! retire et révoque, une seule fois ; revoke! ne retire pas" do
    removed = @webinar.speakers.create!(name: "Intrus")
    revoked = @webinar.speakers.create!(name: "Basile")

    removed.remove_from_room!
    removed_at = removed.room_removed_at
    travel(1.hour) { removed.remove_from_room! }
    revoked.revoke!

    assert_equal removed_at, removed.reload.room_removed_at
    assert_equal removed_at, removed.revoked_at
    assert_nil revoked.reload.room_removed_at
    assert_equal [ removed ], @webinar.speakers.removed_from_room.to_a
    assert_empty Speaker.active
  end

  test "le nom tient sur une ligne : caractères de contrôle remplacés par un espace" do
    speaker = @webinar.speakers.create!(name: "a | Extraits autorisés |\n| b\t\u0000c")

    assert_equal "a | Extraits autorisés | | b c", speaker.name
  end

  test "name must be nonblank and bounded" do
    [ nil, "   ", "x" * 121 ].each do |name|
      assert_not @webinar.speakers.build(name: name).valid?
    end
  end

  test "find_for_speaker_resout_un_speaker_nominatif_et_rejette_le_legacy" do
    # Seul le Speaker nominatif actif
    # résout ; l'ancien signed_id legacy (purpose:speaker) ne résout plus.
    speaker = @webinar.speakers.create!(name: "Basile")
    assert_equal [ @webinar, speaker ], Webinar.find_for_speaker(slug: @webinar.slug, token: speaker.token)
    legacy_token = @webinar.signed_id(purpose: :speaker)
    assert_nil Webinar.find_for_speaker(slug: @webinar.slug, token: legacy_token)
  end

  test "revocation invalidates only the named link and is idempotent" do
    revoked = @webinar.speakers.create!(name: "Basile")
    active = @webinar.speakers.create!(name: "Marc")
    revoked.revoke!
    original_time = revoked.revoked_at
    travel 1.hour do
      revoked.revoke!
    end
    assert_equal original_time, revoked.reload.revoked_at
    assert_not_includes Speaker.active, revoked
    assert_nil Webinar.find_for_speaker(slug: @webinar.slug, token: revoked.token)
    assert_equal [ @webinar, active ], Webinar.find_for_speaker(slug: @webinar.slug, token: active.token)
    # Un ancien signed_id legacy ne résout plus.
    legacy_token = @webinar.signed_id(purpose: :speaker)
    assert_nil Webinar.find_for_speaker(slug: @webinar.slug, token: legacy_token)
  end

  test "foreign room and malformed token never resolve as truthy pairs" do
    speaker = @webinar.speakers.create!(name: "Basile")
    other = Webinar.create!(title: "Other", starts_at: 1.day.from_now, host_sub: "host")
    assert_nil Webinar.find_for_speaker(slug: other.slug, token: speaker.token)
    [ nil, "", "invalid", [ speaker.token ], { token: speaker.token } ].each do |token|
      assert_nil Webinar.find_for_speaker(slug: @webinar.slug, token: token)
    end
  end
  # ---- rattachement à l'inscription (lien participants privé) ----

  test "un intervenant se rattache à une inscription de SON webinaire, ou à aucune" do
    registration = @webinar.registrations.create!(name: "Mathilde", email: "mathilde@example.test")
    speaker = @webinar.speakers.create!(name: "Mathilde", registration: registration)

    assert_equal registration, speaker.registration
    assert_equal [ speaker ], registration.speakers.to_a
    assert @webinar.speakers.create!(name: "Sans mail").valid?, "un intervenant sans inscription reste valide"

    other = Webinar.create!(title: "Autre", starts_at: 1.day.from_now, host_sub: "host")
    foreign = other.registrations.create!(name: "Ailleurs", email: "ailleurs@example.test")
    stray = @webinar.speakers.build(name: "Ailleurs", registration: foreign)
    assert_not stray.valid?
    assert stray.errors.of_kind?(:registration, :invalid)
  end

  test "entré par le lien participants privé : adresse déclarée ou inscription rattachée" do
    registration = @webinar.registrations.create!(name: "Manon", email: "manon@example.test")

    assert @webinar.speakers.create!(name: "Inès", declared_email: "ines@example.test").entered_by_share_link?
    assert @webinar.speakers.create!(name: "Manon", registration: registration).entered_by_share_link?
    assert_not @webinar.speakers.create!(name: "Paul", email: "paul@example.test").entered_by_share_link?,
      "ajouté par l'animation (adresse des fichiers du direct)"
  end

  test "une inscription effacée (purge, crm:erase) détache l'intervenant sans le supprimer" do
    registration = @webinar.registrations.create!(name: "Mathilde", email: "mathilde@example.test")
    speaker = @webinar.speakers.create!(name: "Mathilde", registration: registration)

    Registration.where(id: registration.id).delete_all

    assert_nil speaker.reload.registration_id
    assert_equal "Mathilde", speaker.name
  end

  test "replace! révoque et recrée la personne, nouvelle identité, sans les périphériques" do
    registration = @webinar.registrations.create!(name: "Inès", email: "ines@example.test")
    speaker = @webinar.speakers.create!(
      name: "Inès", email: "pub@example.test", declared_email: "ines@example.test"
    )
    speaker.update!(registration: registration)
    speaker.create_device_preference!(audio_enabled: true)
    old_token = speaker.token
    carried_link = speaker.link_token

    successor = speaker.replace!

    speaker.reload
    assert speaker.revoked_at
    assert_nil speaker.room_removed_at
    assert_nil speaker.link_token
    assert_nil speaker.registration_id
    assert_equal successor, speaker.replaced_by
    assert_in_delta speaker.created_at, successor.link_issued_at, 1.second
    assert_equal [ "Inès", "pub@example.test", "ines@example.test", registration ],
                 [ successor.name, successor.email, successor.declared_email, successor.registration ]
    assert_not_equal speaker.id, successor.id
    assert_not_equal old_token, successor.token
    assert_equal carried_link, successor.link_token
    assert_equal successor, Speaker.find_by_link_token(carried_link)
    assert speaker.device_preference
    assert_nil successor.device_preference
    assert_nil successor.room_removed_at
    assert_nil Webinar.find_for_speaker(slug: @webinar.slug, token: old_token)
    assert_equal [ @webinar, successor ], Webinar.find_for_speaker(slug: @webinar.slug, token: successor.token)
    assert_not TrackRecordingSession.authorized?(@webinar, "speaker-#{speaker.id}")
    assert TrackRecordingSession.authorized?(@webinar, "speaker-#{successor.id}")
    assert_equal [ successor ], @webinar.speakers.reachable_by_email.to_a
    assert_nil speaker.replace!, "déjà révoqué : pas un troisième intervenant"
    assert_equal 2, @webinar.speakers.count
  end

  test "replace! est atomique : un successeur invalide laisse l'ancien lien intact" do
    speaker = @webinar.speakers.create!(name: "Inès", declared_email: "ines@example.test")
    speaker.update_columns(email: "pas-une-adresse")
    speaker.reload

    assert_no_difference -> { Speaker.count } do
      assert_raises(ActiveRecord::RecordInvalid) { speaker.replace! }
    end
    speaker.reload
    assert_nil speaker.revoked_at
    assert_predicate speaker.link_token, :present?
    assert_equal [ @webinar, speaker ], Webinar.find_for_speaker(slug: @webinar.slug, token: speaker.token)
  end

  test "replace! garde l'échéance du lien de rattachement, même déjà dépassée" do
    speaker = @webinar.speakers.create!(name: "Inès", declared_email: "ines@example.test")
    token = speaker.link_token

    successor = travel 13.days do
      fresh = speaker.replace!
      assert_not fresh.link_expired?
      assert_equal token, fresh.link_token
      fresh
    end
    travel 15.days + 1.minute do
      assert successor.reload.link_expired?
      assert_not successor.link_to_declared_registration!
    end

    expired = @webinar.speakers.create!(name: "Olga", declared_email: "olga@example.test")
    expired_token = expired.link_token
    travel 14.days + 1.minute do
      successor = expired.replace!
      assert successor.created_at > expired.created_at
      assert successor.link_expired?
      assert_equal expired_token, successor.link_token
      assert_not successor.link_to_declared_registration!
      assert_equal 1, @webinar.speakers.where(link_token: expired_token).count
    end
  end

  test "retirer l'ancienne identité ne retire pas l'inscription reprise par le successeur" do
    registration = @webinar.registrations.create!(name: "Inès", email: "ines@example.test")
    speaker = @webinar.speakers.create!(name: "Inès", declared_email: "ines@example.test", email: "pub@example.test")
    speaker.update!(registration: registration)
    successor = speaker.replace!
    client = Object.new
    client.define_singleton_method(:remove_participant) { |**| nil }

    ParticipantModeration.new(@webinar, "speaker-#{speaker.id}", client: client).remove

    assert speaker.reload.room_removed_at
    assert_nil registration.reload.room_removed_at
    assert_equal registration, successor.reload.registration
    assert_equal [ @webinar, successor ], Webinar.find_for_speaker(slug: @webinar.slug, token: successor.token)
  end

  # Alerte de la page du webinaire : qui la publication ne préviendra pas.
  test "unreachable_by_email : intervenants actifs sans adresse, ni révoqués ni joignables" do
    webinar = Webinar.create!(title: "Café", starts_at: 1.day.from_now, host_sub: "h")
    silent = webinar.speakers.create!(name: "thomas")
    webinar.speakers.create!(name: "laurent", email: "laurent@example.test")
    webinar.speakers.create!(name: "ancien", revoked_at: Time.current)
    blank = webinar.speakers.create!(name: "Nicolas", email: "  ")

    assert_equal [ silent, blank ].sort_by(&:id), webinar.speakers.unreachable_by_email.order(:id).to_a
    assert_equal webinar.speakers.active.count,
                 webinar.speakers.unreachable_by_email.count + webinar.speakers.reachable_by_email.count
  end
end
