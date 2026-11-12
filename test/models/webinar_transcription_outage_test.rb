# frozen_string_literal: true

require "test_helper"

# Transcription interrompue pendant un direct (Webinar::TranscriptionOutage) :
# une salle occupée sans transcripteur au-delà de 3 min ouvre l'interruption
# (bandeau, journal warn, un mail à l'équipe) ; son retour ou la fin de la
# captation la clôt (journal warn, un mail). Jamais de rafale.
class WebinarTranscriptionOutageTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    # ActiveSupport::TestCase ne vide pas les livraisons entre deux tests : un
    # mail livré par un autre test du même processus (le rappel de la veille
    # de registration_reminder_test) resterait dans la liste lue plus bas.
    ActionMailer::Base.deliveries.clear
    @webinar = Webinar.create!(title: "Café IA #9", starts_at: 1.hour.ago, host_sub: "sub-marc",
                               state: "live", started_at: 1.hour.ago)
    @start = Time.zone.parse("2026-11-10 10:31")
  end

  test "absent moins de 3 min : absence datée, pas d'interruption ni d'alerte" do
    assert_no_enqueued_emails do
      @webinar.transcriber_observed!(:dispatched, at: @start)
      @webinar.transcriber_observed!(:pending, at: @start + 2.minutes + 59.seconds)
    end

    @webinar.reload
    assert_equal @start, @webinar.transcriber_absent_since
    assert_nil @webinar.transcription_interrupted_since
  end

  test "absent 3 min avec du monde : interrompue depuis le début de l'absence, une alerte et un warn, pas de rafale" do
    @webinar.transcriber_observed!(:dispatched, at: @start)

    logs = capture_warn_logs do
      assert_enqueued_email_with TranscriptionOutageMailer, :interrupted, args: [ @webinar, { absent_since: @start } ] do
        @webinar.transcriber_observed!(:pending, at: @start + 3.minutes)
      end
    end
    assert_no_enqueued_emails do
      @webinar.transcriber_observed!(:dispatched, at: @start + 4.minutes)
      @webinar.transcriber_observed!(:pending, at: @start + 5.minutes)
    end

    assert_equal @start, @webinar.reload.transcription_interrupted_since
    assert_match(/\[transcription_outage\] event=interrupted webinar=#{@webinar.slug} room=#{@webinar.room_name} absent_since=#{Regexp.escape(@start.iso8601)} agent_name=transcriber/, logs)
  end

  # L'interruption peut se clore avant l'envoi différé (jobs
  # retardés, redémarrage) ; le mail d'entrée part quand même, avec l'heure
  # du début de l'absence.
  test "interruption close avant l'envoi : les deux mails partent, l'entrée avec son heure" do
    interrupt!
    @webinar.transcriber_observed!(:present, at: @start + 4.minutes)

    perform_enqueued_jobs
    subjects = ActionMailer::Base.deliveries.map(&:subject)
    assert_equal [ "Café IA #9 — transcription en direct interrompue depuis environ 10:31",
                   "Café IA #9 — transcription en direct rétablie à 10:35" ], subjects
  end

  # Une absence datée puis plus observée (captation arrêtée
  # dans la minute, personne entre-temps) n'interrompt pas d'emblée la
  # captation suivante : elle est redatée.
  test "absence périmée : redatée, pas d'interruption immédiate" do
    @webinar.transcriber_observed!(:dispatched, at: @start)

    assert_no_enqueued_emails { @webinar.transcriber_observed!(:dispatched, at: @start + 2.hours) }
    assert_equal @start + 2.hours, @webinar.reload.transcriber_absent_since
    assert_nil @webinar.transcription_interrupted_since
  end

  test "retour du transcripteur : interruption effacée, une alerte de fin et un warn" do
    interrupt!

    logs = capture_warn_logs do
      assert_enqueued_email_with TranscriptionOutageMailer, :ended,
                                 args: [ @webinar, { absent_since: @start, ended_at: @start + 7.minutes, reason: "restored" } ] do
        @webinar.transcriber_observed!(:present, at: @start + 7.minutes)
      end
    end
    assert_no_enqueued_emails { @webinar.transcriber_observed!(:present, at: @start + 8.minutes) }

    @webinar.reload
    assert_nil @webinar.transcriber_absent_since
    assert_nil @webinar.transcription_interrupted_since
    assert_match(/event=ended reason=restored webinar=#{@webinar.slug}/, logs)
  end

  test "retour avant le seuil : absence effacée, aucune alerte" do
    @webinar.transcriber_observed!(:dispatched, at: @start)

    assert_no_enqueued_emails { @webinar.transcriber_observed!(:present, at: @start + 1.minute) }
    assert_nil @webinar.reload.transcriber_absent_since
  end

  test "salle vidée avant le seuil : l'absence est oubliée, le retour du public ne déclenche rien" do
    @webinar.transcriber_observed!(:dispatched, at: @start)
    @webinar.transcriber_observed!(:empty_room, at: @start + 1.minute)

    assert_no_enqueued_emails { @webinar.transcriber_observed!(:dispatched, at: @start + 20.minutes) }
    assert_equal @start + 20.minutes, @webinar.reload.transcriber_absent_since
  end

  test "salle vidée pendant une interruption : l'interruption reste ouverte" do
    interrupt!

    assert_no_enqueued_emails { @webinar.transcriber_observed!(:empty_room, at: @start + 5.minutes) }
    assert_equal @start, @webinar.reload.transcription_interrupted_since
  end

  test "captation close pendant une interruption : clôture et alerte de fin, motif capture_closed" do
    interrupt!

    assert_enqueued_email_with TranscriptionOutageMailer, :ended,
                               args: [ @webinar, { absent_since: @start, ended_at: @start + 9.minutes, reason: "capture_closed" } ] do
      @webinar.transcriber_observed!(:closed, at: @start + 9.minutes)
    end
    assert_nil @webinar.reload.transcription_interrupted_since
  end

  test "vérification arrivée après la fin du direct : rien n'est rouvert" do
    @webinar.update!(state: "ended", ended_at: @start)

    assert_no_enqueued_emails do
      @webinar.transcriber_observed!(:dispatched, at: @start)
      @webinar.transcriber_observed!(:pending, at: @start + 4.minutes)
    end
    assert_nil @webinar.reload.transcriber_absent_since
  end

  test "captation close sans interruption : rien à signaler" do
    @webinar.transcriber_observed!(:dispatched, at: @start)

    assert_no_enqueued_emails { @webinar.end_transcription_outage!(:capture_closed, at: @start + 1.minute) }
    assert_nil @webinar.reload.transcriber_absent_since
  end

  private

  def interrupt!
    @webinar.transcriber_observed!(:dispatched, at: @start)
    @webinar.transcriber_observed!(:pending, at: @start + 3.minutes)
    assert @webinar.reload.transcription_interrupted_since
  end

  def capture_warn_logs
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    logger.level = :warn
    previous = Rails.logger
    Rails.logger = logger
    yield
    io.string
  ensure
    Rails.logger = previous
  end
end
