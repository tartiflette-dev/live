require "test_helper"

# Présence des animateurs (docs/host-presence.md) : une réponse par animateur
# et par date, propriétaire présumé présent, demandes et relances aux seuls
# co-animateurs une fois par date, « non » signalé au propriétaire.
class HostAttendanceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  # Heure fixe, Paris : les relances se comptent en jours calendaires.
  NOW = Time.zone.local(2026, 11, 10, 10, 0, 5)

  setup do
    travel_to NOW
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @webinar = Webinar.create!(title: "Café IA 12", starts_at: Time.zone.local(2026, 11, 20, 19, 0),
                               host_sub: @owner.oidc_sub, visibility: "published")
    @host = @webinar.webinar_hosts.create!(email: "jean@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    clear_enqueued_jobs
  end

  test "une ligne par animateur : propriétaire et co-animateur, jamais en double" do
    owner_row = HostAttendance.for!(@webinar)
    host_row = HostAttendance.for!(@webinar, @host)

    assert_equal owner_row, HostAttendance.for!(@webinar)
    assert_equal host_row, HostAttendance.for!(@webinar, @host)
    assert owner_row.owner?
    assert_not host_row.owner?
    assert_equal [ "owner@example.net", "jean@partenaire.example.org" ], [ owner_row.email, host_row.email ]
    assert_not_equal owner_row.token, host_row.token
  end

  test "propriétaire présumé présent : la date est confirmée quand les co-animateurs ont dit oui" do
    assert_equal "present", HostAttendance.for!(@webinar).current_answer
    assert_equal "to_confirm", @webinar.date_status, "le co-animateur n'a pas répondu"

    HostAttendance.for!(@webinar, @host).answer!("present")
    assert_equal "confirmed", @webinar.reload.date_status
  end

  test "café sans co-animateur : date confirmée d'office ; « non » du propriétaire : à confirmer" do
    @host.destroy!
    assert_equal "confirmed", @webinar.reload.date_status

    HostAttendance.for!(@webinar).answer!("absent")
    assert_equal "to_confirm", @webinar.reload.date_status
  end

  test "date déplacée : les oui des co-animateurs ne valent plus, la présomption du propriétaire se renouvelle" do
    owner_row = HostAttendance.for!(@webinar)
    owner_row.answer!("absent")
    HostAttendance.for!(@webinar, @host).answer!("present")

    @webinar.update!(starts_at: @webinar.starts_at + 1.day)

    assert_not @webinar.reload.date_confirmed?
    assert_nil HostAttendance.for!(@webinar, @host).current_answer
    assert_equal "present", owner_row.reload.current_answer
  end

  test "présomption enregistrée sans écraser un « non » du propriétaire pour la même date" do
    owner_row = HostAttendance.for!(@webinar)

    assert owner_row.presume_present!
    assert_equal [ "present", nil ], owner_row.reload.slice(:answer, :answered_at).values
    owner_row.answer!("absent")
    assert_not owner_row.presume_present!
    assert_equal "absent", owner_row.reload.current_answer
    assert_not HostAttendance.for!(@webinar, @host).presume_present!, "pas de présomption pour un co-animateur"
  end

  test "un co-animateur retiré ne compte plus, et sa ligne disparaît avec lui" do
    row = HostAttendance.for!(@webinar, @host)

    @host.destroy!

    assert_nil HostAttendance.find_by_token(row.token)
    assert @webinar.reload.date_confirmed?
  end

  test "un « non » de co-animateur prévient le propriétaire une fois par date ; le sien ne prévient personne" do
    row = HostAttendance.for!(@webinar, @host)

    assert_enqueued_emails 1 do
      assert row.answer!("absent")
    end
    assert_enqueued_email_with HostAttendanceMailer, :absence_notice, args: [ row ]

    assert_no_enqueued_emails do
      assert_not row.answer!("absent"), "même réponse, même date : rien de neuf"
      HostAttendance.for!(@webinar).answer!("absent")
    end
    assert_no_enqueued_emails { row.answer!("present") }
  end

  test "deux « non » simultanés (objets en mémoire périmés) : un seul avis" do
    first = HostAttendance.for!(@webinar, @host)
    second = HostAttendance.find(first.id)

    assert_enqueued_emails 1 do
      assert first.answer!("absent")
      assert_not second.answer!("absent"), "la ligne en base porte déjà ce « non »"
    end
  end

  test "réponse inconnue refusée" do
    assert_raises(ArgumentError) { HostAttendance.for!(@webinar).answer!("peut-être") }
  end

  test "demande : jamais au propriétaire ; au co-animateur une fois par date, de nouveau après un changement de date" do
    owner_row = HostAttendance.for!(@webinar)
    host_row = HostAttendance.for!(@webinar, @host)

    assert_enqueued_emails 1 do
      assert_not owner_row.request!, "le propriétaire n'est jamais demandé"
      assert host_row.request!
      assert_not host_row.request!, "déjà demandé pour cette date"
    end

    @webinar.update_columns(starts_at: @webinar.starts_at + 2.hours)
    assert_enqueued_emails 1 do
      assert_not owner_row.request!
      assert host_row.request!
    end
  end

  test "pas de demande à un co-animateur qui a déjà répondu pour cette date" do
    host_row = HostAttendance.for!(@webinar, @host)
    host_row.answer!("present")

    assert_no_enqueued_emails { assert_not host_row.request! }
  end

  test "relance J-3 : co-animateur sans réponse, une seule fois ; jamais le propriétaire" do
    owner_row = HostAttendance.for!(@webinar)
    host_row = HostAttendance.for!(@webinar, @host)
    host_row.request!
    owner_row.update_columns(requested_at: NOW, requested_for_starts_at: @webinar.starts_at)
    clear_enqueued_jobs

    assert_equal 0, HostAttendance.remind_due(Time.zone.local(2026, 11, 16, 10, 0)), "J-4 : trop tôt"

    j3 = Time.zone.local(2026, 11, 17, 10, 0)
    assert_enqueued_emails 1 do
      assert_equal 1, HostAttendance.remind_due(j3)
    end
    assert_enqueued_email_with HostAttendanceMailer, :presence_reminder, args: [ host_row ]
    assert_equal 0, HostAttendance.remind_due(j3 + 1.day), "relance déjà faite pour cette date"
  end

  test "relance : demande partie à 10:00:05, tournée du lendemain à 10:00:02 → relancée (jour calendaire, pas 24 h)" do
    @webinar.update_columns(starts_at: Time.zone.local(2026, 11, 12, 9, 30))
    row = HostAttendance.for!(@webinar, @host)
    row.request!(now: NOW)

    assert_equal 0, HostAttendance.remind_due(NOW + 2.hours), "jamais le jour même de la demande"
    assert_equal 1, HostAttendance.remind_due(Time.zone.local(2026, 11, 11, 10, 0, 2))
  end

  test "pas de relance pour un café dépublié" do
    @webinar.update_columns(starts_at: Time.zone.local(2026, 11, 12, 19, 0))
    HostAttendance.for!(@webinar, @host).request!
    @webinar.update_columns(visibility: "draft")

    assert_equal 0, HostAttendance.remind_due(Time.zone.local(2026, 11, 11, 10, 0))
  end

  test "jeton : retrouvé exactement, rien pour un jeton vide ou inconnu" do
    row = HostAttendance.for!(@webinar, @host)

    assert_equal row, HostAttendance.find_by_token(row.token)
    assert_nil HostAttendance.find_by_token("")
    assert_nil HostAttendance.find_by_token(nil)
    assert_nil HostAttendance.find_by_token("inconnu")
  end
end
