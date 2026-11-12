require "net/smtp"

# Rappel de la veille (J-1) : la veille d'un webinaire, chaque inscription
# confirmée reçoit le lien pour rejoindre le direct (docs/registration-reminders.md).
#
# Politique d'envoi, à l'heure de Paris (Time.zone de l'app) :
#   • dû de SEND_HOURS.first h à SEND_HOURS.last h 59 la VEILLE (jour
#     calendaire précédent), jamais la nuit ; RegistrationReminderJob passe
#     toutes les heures de cette plage (config/recurring.yml). Une
#     confirmation arrivée dans la journée de la veille est servie au tour
#     suivant ; arrivée après la plage, ou le jour même : pas de rappel (la
#     page de confirmation donne déjà le lien du direct) ;
#   • webinaire publié, pas encore lancé (`state: draft`) ; dépublié = annulé.
#
# Exactement une fois par inscription ET par date de début : l'état vit dans
# `registrations.reminder_sent_at` (json), donc une ligne effacée par
# `crm:erase` ne laisse rien à envoyer. Clés :
#   "j1_starts_at"    début du webinaire visé (UTC ISO 8601) : le verrou ;
#   "j1_attempted_at" prise du verrou, avant tout appel SMTP ;
#   "j1"              remise acceptée par le serveur SMTP (le « sent_at ») ;
#   "j1_error"        classe de la dernière erreur d'envoi ;
#   "j1_attempts"     tentatives pour la date "j1_attempts_for" (posées au verrou) ;
#   "j1_abandoned_at" abandon définitif après MAX_ATTEMPTS refus temporaires.
# Le verrou est un UPDATE conditionnel unique qui revérifie l'éligibilité
# (confirmée, webinaire publié, non lancé, même date) : deux exécutions
# concurrentes, un redémarrage ou un rejeu n'envoient qu'une fois. Un
# webinaire déplacé à une autre date ré-ouvre un rappel pour la nouvelle.
#
# SQLite et SMTP ne partagent pas de transaction : après un échec, le verrou
# n'est rendu (nouvel essai au tour suivant) que si le serveur n'a
# certainement PAS accepté le message (RETRYABLE_ERRORS), et au plus
# MAX_ATTEMPTS fois par date. Toute autre issue (coupure en cours d'envoi,
# délai de réponse, refus définitif 5xx, arrêt du processus) garde le
# verrou : un rappel peut manquer, il ne part jamais plus de MAX_ATTEMPTS fois.
class RegistrationReminder
  SEND_HOURS = 9..20
  # Refus ou impossibilité AVANT acceptation du message : connexion,
  # authentification (avant MAIL FROM), refus temporaire 4xx (y compris en
  # fin de DATA, qui signifie « non accepté »).
  RETRYABLE_ERRORS = [
    Net::SMTPServerBusy, Net::SMTPAuthenticationError, Net::OpenTimeout,
    Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError
  ].freeze
  # Plafond des tentatives par date. Un 4xx peut arriver au QUIT, APRÈS un
  # DATA accepté (Net::SMTP#start le lève depuis son ensure) : indiscernable
  # d'un refus, il ne doit pas renvoyer le message à chaque passage.
  MAX_ATTEMPTS = 2

  def self.enabled?
    ENV["REMINDERS_ENABLED"] == "1"
  end

  # Inscriptions à servir à `now` ; le verrou de `deliver` reste l'arbitre.
  # `now` est ramené à l'heure de Paris : l'heure d'envoi et « le lendemain »
  # s'y lisent, quel que soit le fuseau de l'appelant.
  def self.due(now = Time.current)
    paris_now = now.in_time_zone
    return Registration.none unless SEND_HOURS.cover?(paris_now.hour)

    Registration.confirmed.joins(:webinar).includes(:webinar)
      .merge(Webinar.published.where(state: "draft", starts_at: paris_now.tomorrow.all_day))
  end

  # Tournée : `{ due:, outcomes: { sent: n, … } }` (issues de #deliver).
  def self.deliver_due(now = Time.current)
    registrations = due(now).to_a
    { due: registrations.size, outcomes: registrations.map { |registration| new(registration).deliver(now) }.tally }
  end

  def initialize(registration)
    @registration = registration
    @webinar = registration.webinar
    @starts_key = @webinar.starts_at.utc.iso8601
  end

  # :sent | :skipped (déjà traité pour cette date, ou plus éligible) |
  # :smtp_retry (verrou rendu) | :abandoned (plafond atteint) |
  # :failed (rendu impossible, ou issue SMTP incertaine : verrou gardé)
  def deliver(now = Time.current)
    return :skipped if @registration.reminder_sent_at["j1_starts_at"] == @starts_key

    message = render
    return :failed unless message
    return :skipped unless claim(now)

    send_claimed(message)
  end

  private

  # Rendu complet AVANT le verrou : une vue cassée ne verrouille rien et
  # n'interrompt pas la tournée (nouvel essai au tour suivant).
  def render
    RegistrationMailer.reminder(@registration).tap(&:message)
  rescue StandardError => error
    report(error, :failed)
    nil
  end

  def send_claimed(message)
    message.deliver_now
    own_row.update_all([ "reminder_sent_at = json_set(reminder_sent_at, '$.j1', ?)", Time.current.utc.iso8601 ])
    :sent
  rescue *RETRYABLE_ERRORS => error
    return report(error, :smtp_retry) if release(error)

    own_row.update_all([
      "reminder_sent_at = json_set(reminder_sent_at, '$.j1_error', ?, '$.j1_abandoned_at', ?)",
      error.class.name, Time.current.utc.iso8601
    ])
    report(error, :abandoned)
  rescue StandardError => error
    own_row.update_all([ "reminder_sent_at = json_set(reminder_sent_at, '$.j1_error', ?)", error.class.name ])
    report(error, :failed)
  end

  def claim(now)
    still_due = Webinar.published.where(id: @webinar.id, state: "draft", starts_at: @webinar.starts_at)
    Registration.confirmed.where(id: @registration.id, webinar_id: still_due.select(:id))
      .where("json_extract(reminder_sent_at, '$.j1_starts_at') IS NOT ?", @starts_key)
      .update_all([
        "reminder_sent_at = json_set(json_remove(reminder_sent_at, '$.j1', '$.j1_error', '$.j1_abandoned_at'), " \
        "'$.j1_starts_at', ?, '$.j1_attempted_at', ?, '$.j1_attempts_for', ?, '$.j1_attempts', " \
        "CASE WHEN json_extract(reminder_sent_at, '$.j1_attempts_for') IS ? " \
        "THEN coalesce(json_extract(reminder_sent_at, '$.j1_attempts'), 0) + 1 ELSE 1 END)",
        @starts_key, now.utc.iso8601, @starts_key, @starts_key
      ]) == 1
  end

  # Rend le verrou (nouvel essai au passage suivant) tant que le plafond
  # n'est pas atteint ; `false` = plafond atteint, verrou gardé.
  def release(error)
    own_row.where("json_extract(reminder_sent_at, '$.j1_attempts') < ?", MAX_ATTEMPTS).update_all([
      "reminder_sent_at = json_set(json_remove(reminder_sent_at, '$.j1_starts_at', '$.j1_attempted_at'), '$.j1_error', ?)",
      error.class.name
    ]) == 1
  end

  def own_row
    Registration.where(id: @registration.id)
  end

  # Sans donnée personnelle : identifiants seulement (AppErrorSubscriber).
  def report(error, outcome)
    Rails.error.report(error, handled: true, context: {
      registration_id: @registration.id, webinar_id: @webinar.id, reminder_outcome: outcome
    })
    outcome
  end
end
