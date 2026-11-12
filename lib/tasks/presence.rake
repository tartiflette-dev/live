# frozen_string_literal: true

# Présence des cafés tenus avant le journal de présence (PresenceLogImport) :
# rejoue les webhooks que le serveur LiveKit a envoyés, lus dans son journal
# sur l'entrée standard. N'affiche que des compteurs. Rejouable sans doublon.
#   docker logs livekit 2>&1 | grep '"sent webhook"' | bin/rails presence:import_livekit_log
#   SLUGS=cafe-ia-7,cafe-ia-8,cafe-ia-9 … pour se limiter à quelques cafés.
namespace :presence do
  desc "Rejoue au journal de présence les webhooks lus dans le journal du serveur LiveKit (entrée standard)"
  task import_livekit_log: :environment do
    slugs = ENV["SLUGS"].to_s.split(",").map(&:strip).reject(&:empty?).presence
    added = PresenceLogImport.call($stdin.each_line, slugs: slugs)
    if added.empty?
      puts "presence:import_livekit_log — aucun fait nouveau."
    else
      added.sort.each { |slug, count| puts "presence:import_livekit_log — #{slug} : #{count} fait(s) ajouté(s)." }
    end
  end
end
