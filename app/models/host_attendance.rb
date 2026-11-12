# Présence d'un animateur à un webinaire (docs/host-presence.md). Une ligne
# par animateur × webinaire : le propriétaire (`webinar_host_id` nul) et
# chaque co-animateur (WebinarHost).
#
# Une réponse vaut pour la date à laquelle elle a été donnée
# (`answered_for_starts_at`) : un webinaire déplacé repasse « à confirmer »
# sans rien effacer, et le co-animateur est redemandé pour la nouvelle date
# (`requested_for_starts_at`, `reminded_for_starts_at`). Le propriétaire est
# présumé présent pour chaque date, sauf « non » de sa part pour cette date :
# il n'est jamais demandé ni relancé. Le jeton, opaque, porte les deux liens
# du mail (/presence?t=) et ne donne aucun autre droit.
class HostAttendance < ApplicationRecord
  self.filter_attributes += [ :token ]

  ANSWERS = %w[present absent].freeze
  TOKEN_BYTES = 24
  # Relance des non-répondants : à partir de J-3 (jour calendaire, Paris),
  # jamais le jour même de la demande (jour calendaire, Paris : deux tournées
  # quotidiennes ne se comparent pas à la seconde).
  REMINDER_DAYS_BEFORE = 3

  # Écritures conditionnelles : la date du webinaire est LUE EN BASE dans le
  # même UPDATE, sans dépendre d'une valeur Ruby peut-être périmée, et copiée
  # telle quelle (même précision partout).
  WEBINAR_STARTS_AT_SQL = "(SELECT webinars.starts_at FROM webinars WHERE webinars.id = host_attendances.webinar_id)"
  CLAIMS = {
    # Pas déjà répondu, pas déjà demandé / relancé pour cette date.
    request: {
      pending: "answered_for_starts_at IS NOT #{WEBINAR_STARTS_AT_SQL} AND requested_for_starts_at IS NOT #{WEBINAR_STARTS_AT_SQL}",
      claimed: "requested_for_starts_at = #{WEBINAR_STARTS_AT_SQL}, requested_at = :now, updated_at = :now"
    }.freeze,
    reminder: {
      pending: "answered_for_starts_at IS NOT #{WEBINAR_STARTS_AT_SQL} AND reminded_for_starts_at IS NOT #{WEBINAR_STARTS_AT_SQL}",
      claimed: "reminded_for_starts_at = #{WEBINAR_STARTS_AT_SQL}, updated_at = :now"
    }.freeze,
    # Réponse différente de celle déjà enregistrée pour cette date.
    answer: {
      pending: "answer IS NOT :value OR answered_for_starts_at IS NOT #{WEBINAR_STARTS_AT_SQL}",
      claimed: "answer = :value, answered_at = :now, answered_for_starts_at = #{WEBINAR_STARTS_AT_SQL}, updated_at = :now"
    }.freeze,
    # Présomption du propriétaire : seulement sans réponse pour cette date ;
    # `answered_at` reste nul (rien n'a été répondu).
    presumption: {
      pending: "answered_for_starts_at IS NOT #{WEBINAR_STARTS_AT_SQL}",
      claimed: "answer = :value, answered_at = NULL, answered_for_starts_at = #{WEBINAR_STARTS_AT_SQL}, updated_at = :now"
    }.freeze
  }.freeze
  private_constant :WEBINAR_STARTS_AT_SQL, :CLAIMS

  belongs_to :webinar
  belongs_to :webinar_host, optional: true

  before_validation :assign_token, on: :create

  validates :token, presence: true, uniqueness: true
  validates :answer, inclusion: { in: ANSWERS }, allow_nil: true

  # Ligne de l'animateur, créée au besoin. Les index uniques (propriétaire,
  # co-animateur) font de deux créations concurrentes une seule ligne.
  def self.for!(webinar, webinar_host = nil)
    webinar.host_attendances.create_or_find_by!(webinar_host: webinar_host)
  end

  # Même forme que HostInvitation.find_by_token : l'index unique compare, le
  # secure_compare revérifie l'égalité exacte côté Ruby.
  # @return [HostAttendance, nil]
  def self.find_by_token(token)
    return nil unless token.is_a?(String) && token.present?

    candidate = find_by(token: token)
    candidate if candidate && ActiveSupport::SecurityUtils.secure_compare(candidate.token, token)
  end

  # Relance J-3 des co-animateurs : demande partie pour la date actuelle un
  # jour calendaire précédent (Paris), toujours sans réponse pour cette date.
  # @return [Integer] relances envoyées
  def self.remind_due(now = Time.current)
    today = now.in_time_zone.beginning_of_day
    last_day = (today + REMINDER_DAYS_BEFORE.days).end_of_day
    joins(:webinar).merge(Webinar.published.upcoming(now).where(starts_at: ..last_day))
      .where.not(webinar_host_id: nil)
      .where("host_attendances.requested_for_starts_at = webinars.starts_at")
      .where(requested_at: ...today)
      .includes(:webinar, :webinar_host).to_a
      .count { |attendance| attendance.remind!(now: now) }
  end

  def owner?
    webinar_host_id.nil?
  end

  def email
    owner? ? webinar.owner_email : webinar_host.email
  end

  # Réponse pour la date ACTUELLE du webinaire. Sans réponse pour cette date :
  # « present » pour le propriétaire (présomption), nil pour un co-animateur.
  # Comparaison à la seconde : la précision stockée ne doit pas faire d'une
  # même date deux dates.
  def current_answer
    return answer if answered_for_starts_at && answered_for_starts_at.to_i == webinar.starts_at.to_i

    "present" if owner?
  end

  def attending?
    current_answer == "present"
  end

  # Enregistre la présomption du propriétaire pour la date actuelle, sans
  # écraser une réponse qu'il aurait donnée pour cette date.
  def presume_present!(now: Time.current)
    write_if(CLAIMS[:presumption], now, value: "present") if owner?
  end

  # Un « non » nouveau d'un co-animateur pour cette date prévient le
  # propriétaire, et lui seul décide (déplacer, dépublier) : rien ne change
  # côté public. La nouveauté se décide sur la ligne en base : deux « non »
  # simultanés ne font qu'un avis. Le propriétaire qui se déclare absent
  # n'est pas prévenu de sa propre réponse.
  # @return [Boolean] true si la réponse a changé pour cette date
  def answer!(value, now: Time.current)
    raise ArgumentError, "réponse inconnue : #{value.inspect}" unless ANSWERS.include?(value)

    changed = write_if(CLAIMS[:answer], now, value: value)
    reload
    HostAttendanceMailer.absence_notice(self).deliver_later if changed && value == "absent" && !owner?
    changed
  end

  # Demande de présence à un co-animateur pour la date actuelle : une fois
  # par date, et pas s'il a déjà répondu pour cette date.
  # @return [Boolean] true si la demande part
  def request!(now: Time.current)
    claimed = !owner? && write_if(CLAIMS[:request], now)
    HostAttendanceMailer.presence_request(self).deliver_later if claimed
    claimed
  end

  # @return [Boolean] true si la relance part
  def remind!(now: Time.current)
    claimed = !owner? && write_if(CLAIMS[:reminder], now)
    HostAttendanceMailer.presence_reminder(self).deliver_later if claimed
    claimed
  end

  private

  # UPDATE conditionnel unique : deux tournées concurrentes, un rejeu ou un
  # double clic n'écrivent (et n'envoient) qu'une fois.
  def write_if(sql, now, **binds)
    pending = binds.empty? ? sql.fetch(:pending) : [ sql.fetch(:pending), binds ]
    self.class.where(id: id).where(pending)
      .update_all([ sql.fetch(:claimed), binds.merge(now: now) ]) == 1
  end

  def assign_token
    self.token ||= SecureRandom.urlsafe_base64(TOKEN_BYTES)
  end
end
