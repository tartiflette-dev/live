# Présence des animateurs (Webinar::HostPresence, docs/host-presence.md).
#
# `presence_request` / `presence_reminder` : à UN animateur, deux liens
# /presence?t=…&reponse=oui|non vers une page sans effet ; la réponse n'est
# prise qu'au POST de son bouton (scanners de liens). `absence_notice` : au
# propriétaire, quand un co-animateur répond « non ».
#
# Sans adresse (propriétaire introuvable), aucun mail : `mail` n'est pas
# appelé, rien ne part.
class HostAttendanceMailer < ApplicationMailer
  def presence_request(attendance)
    prepare_presence(attendance)
    return if @attendance.email.blank?

    mail(to: @attendance.email, reply_to: @webinar.owner_email,
         subject: "#{@webinar.title} — seras-tu là le #{@starts_at} ?")
  end

  def presence_reminder(attendance)
    prepare_presence(attendance)
    return if @attendance.email.blank?

    mail(to: @attendance.email, reply_to: @webinar.owner_email,
         subject: "Rappel — #{@webinar.title} : seras-tu là le #{@starts_at} ?")
  end

  def absence_notice(attendance)
    @attendance = attendance
    @webinar    = attendance.webinar
    @starts_at  = I18n.l(@webinar.starts_at, format: :long)
    @webinar_url = webinar_url(@webinar)
    owner_email = @webinar.owner_email
    return if owner_email.blank?

    mail(to: owner_email, reply_to: @attendance.email,
         subject: "#{@webinar.title} — #{@attendance.email} ne sera pas là le #{@starts_at}")
  end

  private

  def prepare_presence(attendance)
    @attendance  = attendance
    @webinar     = attendance.webinar
    @starts_at   = I18n.l(@webinar.starts_at, format: :long)
    @present_url = host_attendance_url(t: attendance.token, reponse: "oui")
    @absent_url  = host_attendance_url(t: attendance.token, reponse: "non")
    @webinar_url = webinar_url(@webinar)
  end
end
