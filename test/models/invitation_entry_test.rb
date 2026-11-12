require "test_helper"

# Entrée par le lien participants privé : mail obligatoire,
# choix, intervenant rattaché à l'inscription de son adresse seulement si la
# boîte mail est PROUVÉE.
class InvitationEntryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.day.from_now, host_sub: "host", visibility: "published")
  end

  test "nom, mail valide et choix connu sont obligatoires ; le mail est normalisé" do
    assert_not entry(email: nil).valid?
    assert_not entry(email: "pas-un-mail").valid?
    assert_not entry(name: "  ").valid?
    assert_not entry(participation: "host").valid?
    assert_equal "mathilde@example.test", entry(email: "  Mathilde@Example.TEST ").email
    assert_equal "participant", InvitationEntry.new(webinar: @webinar).participation, "le lien privé sert d'abord aux participants"
  end

  # Créer l'inscription ne prouve rien : un tiers peut saisir l'adresse neuve
  # d'une autre personne.
  test "adresse neuve : inscription créée avec son choix, intervenant NON rattaché, confirmation et demande de rattachement" do
    assert_equal :speaker, (participant = entry).save

    speaker = participant.speaker
    assert participant.registration.participant?
    assert_equal [ "Mathilde", nil, "mathilde@example.test" ], [ speaker.name, speaker.registration, speaker.declared_email ]
    assert_predicate speaker.link_token, :present?
    assert_enqueued_email_with RegistrationMailer, :confirmation, args: [ participant.registration ]
    assert_enqueued_email_with RegistrationMailer, :speaker_link, args: [ speaker, participant.registration ]
  end

  # Le scénario d'attaque de la revue : l'adresse d'une inscrite, saisie par
  # un tiers. Il publie quand même, mais rien n'est rattaché à sa fiche ; elle
  # reçoit le mail qui lui demande si c'est elle, et rien d'autre.
  test "adresse déjà inscrite, sans preuve : intervenant non rattaché, adresse déclarée, mail à sa propriétaire" do
    victim = @webinar.registrations.create!(name: "Victime", email: "victime@example.test", confirmed_at: Time.current)

    attacker = entry(name: "Intrus", email: "victime@example.test")
    assert_no_difference "Registration.count" do
      assert_equal :speaker, attacker.save
    end

    speaker = attacker.speaker
    assert_nil speaker.registration
    assert_equal [ "victime@example.test", true ], [ speaker.declared_email, speaker.link_token.present? ]
    assert_enqueued_email_with RegistrationMailer, :speaker_link, args: [ speaker, victim ]
    assert_enqueued_emails 1
    assert_equal "Victime", victim.reload.name
    assert_empty victim.speakers
  end

  test "inscription confirmée et son cookie dans le navigateur : rattaché tout de suite, aucun mail" do
    mine = @webinar.registrations.create!(name: "Mathilde", email: "mathilde@example.test", confirmed_at: Time.current)

    participant = InvitationEntry.new(webinar: @webinar, browser_registration: mine, name: "Mathilde C.", email: "mathilde@example.test")
    assert_equal :speaker, participant.save

    assert_equal mine, participant.speaker.registration
    assert_nil participant.speaker.link_token
    assert_no_enqueued_emails
  end

  test "inscription NON confirmée et son cookie (accès immédiat) : pas de rattachement" do
    pending = @webinar.registrations.create!(name: "Inès", email: "ines@example.test", instant_access_at: Time.current)

    participant = InvitationEntry.new(webinar: @webinar, browser_registration: pending, name: "Inès", email: "ines@example.test")
    participant.save

    assert_nil participant.speaker.registration
    assert_enqueued_email_with RegistrationMailer, :confirmation, args: [ pending ]
    assert_enqueued_email_with RegistrationMailer, :speaker_link, args: [ participant.speaker, pending ]
  end

  test "le cookie d'une AUTRE inscription ne prouve rien" do
    @webinar.registrations.create!(name: "Victime", email: "victime@example.test", confirmed_at: Time.current)
    other = @webinar.registrations.create!(name: "Intrus", email: "intrus@example.test", confirmed_at: Time.current)

    attacker = InvitationEntry.new(webinar: @webinar, browser_registration: other, name: "Intrus", email: "victime@example.test")
    attacker.save

    assert_nil attacker.speaker.registration
  end

  test "rien n'est créé pour une entrée invalide, refusée ou au plafond" do
    @webinar.registrations.create!(name: "Retirée", email: "retiree@example.test", confirmed_at: Time.current).remove_from_room!

    Webinar::SPEAKER_LIMIT.times { |i| @webinar.speakers.create!(name: "N#{i}") }

    assert_no_difference [ "Speaker.count", "Registration.count" ] do
      assert_no_enqueued_jobs do
        assert_equal :invalid, entry(email: "").save
        assert_equal :removed, entry(email: "retiree@example.test", participation: "spectator").save
        assert_equal :full, entry(email: "nouvelle@example.test").save
      end
    end
    Speaker.where(webinar: @webinar).delete_all
    assert_no_difference [ "Speaker.count", "Registration.count" ] do
      assert_equal :removed, entry(email: "retiree@example.test").save
    end
  end

  private

  def entry(name: "Mathilde", email: "mathilde@example.test", participation: "participant")
    InvitationEntry.new(webinar: @webinar, name: name, email: email, participation: participation)
  end
end
