# Présence des animateurs d'un webinaire (docs/host-presence.md).
# Animateurs = le propriétaire (`host_sub`) et les co-animateurs actuels
# (WebinarHost) ; un animateur du projet n'en est pas un à ce seul titre.
#
# Statut public : « date confirmée » quand chacun est présent pour la date
# actuelle, « à confirmer » sinon. Le propriétaire est présumé présent (sauf
# « non » de sa part pour cette date) et n'est jamais demandé : un café sans
# co-animateur a sa date confirmée d'office. Les demandes aux co-animateurs
# partent à la publication, au changement de date (après
# RESCHEDULE_REQUEST_DELAY : plusieurs retouches font un seul mail) et à
# l'ajout d'un co-animateur (WebinarHost).
module Webinar::HostPresence
  extend ActiveSupport::Concern

  RESCHEDULE_REQUEST_DELAY = 10.minutes

  included do
    has_many :host_attendances, dependent: :destroy, inverse_of: :webinar

    after_commit :request_host_attendances_later, on: %i[create update], if: :host_attendances_to_request?
  end

  # Demandes, liens du mail et réponses : seulement pour un webinaire publié
  # qui n'a pas commencé. Dépublié = annulé, commencé = plus rien à confirmer.
  def host_attendance_open?(now = Time.current)
    visibility_published? && draft? && starts_at > now
  end

  # Direct en cours ou terminé : la date a tenu. Lit les associations
  # préchargées quand elles le sont (catalogue, agenda, next.json).
  def date_confirmed?
    return true if live? || ended?

    by_host = host_attendances.index_by(&:webinar_host_id)
    owner_present = by_host[nil].nil? || by_host[nil].attending?
    owner_present && webinar_hosts.all? { |host| by_host[host.id]&.attending? }
  end

  # Valeur du champ `date_status` de /agenda/next.json.
  def date_status
    date_confirmed? ? "confirmed" : "to_confirm"
  end

  def owner_email
    User.find_by(oidc_sub: host_sub)&.email
  end

  # Enregistre la présomption du propriétaire pour la date actuelle, crée les
  # lignes manquantes des co-animateurs et leur demande leur présence
  # (HostAttendance#request! : une fois par date).
  # @return [Integer] demandes envoyées
  def request_host_attendances!(now = Time.current)
    return 0 unless host_attendance_open?(now)

    HostAttendance.for!(self).presume_present!(now: now)
    webinar_hosts.count { |host| HostAttendance.for!(self, host).request!(now: now) }
  end

  # Ligne de présence de `user` s'il anime ce webinaire comme propriétaire ou
  # comme co-animateur désigné par son adresse vérifiée (mêmes conditions que
  # Webinar#role_for) ; nil sinon. Non enregistrée si elle n'existe pas encore,
  # et hors de l'association : enregistrer le webinaire ne la crée pas.
  def host_attendance_for(user)
    return if user.nil?
    return HostAttendance.find_or_initialize_by(webinar: self, webinar_host: nil) if user.oidc_sub == host_sub
    return unless user.email_verified_and_fresh?

    host = webinar_hosts.where("LOWER(email) = ?", user.normalized_email)
                        .where("claimed_sub IS NULL OR claimed_sub = ?", user.oidc_sub).first
    host && HostAttendance.find_or_initialize_by(webinar: self, webinar_host: host)
  end

  # Réponses pour la page du webinaire (gestionnaires) : [adresse, réponse
  # actuelle ou nil], propriétaire d'abord (présumé présent) puis co-animateurs.
  def host_presence_roster
    by_host = host_attendances.index_by(&:webinar_host_id)
    [ [ owner_email, by_host[nil]&.current_answer || "present" ] ] +
      webinar_hosts.order(:created_at, :id).map { |host| [ host.email, by_host[host.id]&.current_answer ] }
  end

  private

  def host_attendances_to_request?
    host_attendance_open? && (saved_change_to_visibility? || saved_change_to_starts_at?)
  end

  def request_host_attendances_later
    rescheduled = saved_change_to_starts_at? && !saved_change_to_visibility? && !previously_new_record?
    job = rescheduled ? HostAttendanceRequestJob.set(wait: RESCHEDULE_REQUEST_DELAY) : HostAttendanceRequestJob
    job.perform_later(self)
  end
end
