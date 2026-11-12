# frozen_string_literal: true

# Remise en file de la synchro CRM (docs/registrations-api.md §Reprise).
#   bin/rails crm:requeue
# À lancer une fois la cause d'une panne corrigée (CRM redéployé, jeton
# réparé) : remet à zéro l'attente de TOUT ce qui reste à pousser (compteurs
# de tentatives compris) puis enqueue immédiatement les jobs. Sans effet si
# CRM_SYNC_ENABLED != 1. N'affiche que des compteurs.
namespace :crm do
  desc "Remet en file tout ce qui reste à pousser vers le CRM (sans attendre l'espacement)"
  task requeue: :environment do
    unless ENV["CRM_SYNC_ENABLED"] == "1"
      puts "crm:requeue — CRM_SYNC_ENABLED != 1 : rien n'est enqueué."
      next
    end

    backlog = Crm::Backlog.new
    backlog.reset_schedule
    count = backlog.items.size
    CrmResyncJob.perform_now(force: true)
    puts "crm:requeue — #{count} élément(s) remis en file."
  end
end

# Effacement explicite (docs/registrations-api.md §Effacement) — à lancer
# quand une demande d'effacement est traitée, APRÈS avoir effacé la fiche
# dans le CRM. Forme nominale, adresse sur l'entrée standard :
#   printf '%s' 'adresse@exemple.fr' | bin/rails crm:erase
# `EMAIL=adresse bin/rails crm:erase` reste accepté mais déconseillé :
# l'adresse reste dans l'historique du shell et la liste des processus.
# Enregistre l'effacement (empreinte, date), efface les données live de cet
# email, puis vérifie en lecture seule (lookup) qu'aucune fiche CRM ne
# subsiste. N'affiche que des compteurs et le résultat de la vérification.
namespace :crm do
  desc "Efface une personne de live (adresse sur stdin : printf '%s' 'adresse' | bin/rails crm:erase), après le CRM"
  task erase: :environment do
    if ENV["EMAIL"].present?
      warn "crm:erase — EMAIL= est déconseillé (historique shell, ps) : préfère printf '%s' 'adresse' | bin/rails crm:erase"
    end
    email = CrmErasure.normalize(ENV["EMAIL"].presence || $stdin.gets)
    abort "crm:erase — adresse email manquante ou invalide." unless email.match?(URI::MailTo::EMAIL_REGEXP)

    counts = CrmErasure.erase!(email)
    puts "crm:erase — effacement enregistré ; " + counts.map { |kind, n| "#{kind}=#{n}" }.join(" ")
    puts "Rappel : vérifie que la fiche est effacée dans le CRM."
    puts Crm::ErasureCheck.call(email)
  end
end
