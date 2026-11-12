# frozen_string_literal: true

# Rattrapage du mail d'équipe (docs/registrations-api.md §Inscriptions transmises à l'équipe et à la communauté)
# pour les demandes confirmées dont le message n'a jamais été transmis :
#   bin/rails registrations:notify_team_backlog            # simulation
#   CONFIRM=1 bin/rails registrations:notify_team_backlog  # envoi
# Idempotente : une demande transmise (`team_notified_at`) ne repart jamais.
# N'affiche que des identifiants, des dates et des compteurs.
namespace :registrations do
  desc "Envoie aux co-organisateurs les messages d'inscription jamais transmis (simulation sans CONFIRM=1)"
  task notify_team_backlog: :environment do
    pending = RegistrationRequest.team_notification_pending.order(:created_at, :id)
    recipient_line = CoOrganizerMailer.recipient ? "destinataire configuré" : "CO_ORGANIZERS_NOTIFY_TO absente"

    unless ENV["CONFIRM"] == "1"
      puts "registrations:notify_team_backlog — simulation (#{recipient_line}) : #{pending.size} message(s) à transmettre."
      pending.each { |registration_request| puts "  ##{registration_request.id} reçue le #{registration_request.created_at.iso8601}" }
      puts "Relancer avec CONFIRM=1 pour envoyer."
      next
    end

    abort "registrations:notify_team_backlog — CO_ORGANIZERS_NOTIFY_TO absente : rien n'est envoyé." unless CoOrganizerMailer.recipient

    sent = pending.count(&:notify_team!)
    puts "registrations:notify_team_backlog — #{sent} message(s) transmis."
  end
end
