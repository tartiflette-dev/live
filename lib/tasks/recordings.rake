# Montages par personne d'un webinaire, à la demande.
#
#   bin/rails "recordings:montages[cafe-ia-7,speaker-9]"   # une personne
#   bin/rails "recordings:montages[cafe-ia-7]"             # toutes
#   bin/rails "recordings:montages[cafe-ia-8,speaker-13,refaire]"   # montages existants refaits
#
# En mode `refaire`, une identité laissée vide vise toutes les personnes.
#
# Produit les montages manquants (pistes terminées qu'aucun montage ne
# couvre encore) et relance ceux qui n'ont pas abouti, par le même job que
# la fin du direct (MuxParticipantJob), puis liste les montages de chaque
# personne. Un nouveau lot reçoit un nouveau fichier. Les montages réussis ne
# sont refaits qu'en mode `refaire` (nouveau calage) : chacun est réécrit sous
# son nom, l'ancien fichier restant en place tant que le nouveau n'est pas
# prêt. Sans effet sur une personne dont une piste capte encore.
#
# Instants de démarrage des pistes enregistrées avant le webhook
# egress_updated (media_started_at, sur lequel ParticipantMux recale) : repris
# du journal du conteneur egress, lu sur l'entrée standard.
#
#   docker logs <conteneur egress> 2>&1 | bin/rails recordings:activations
#
# Le conteneur egress lu est celui de l'environnement visé (production ou
# staging, chacun le sien). Seules les
# lignes `egress_active` comptent : leur heure suit `updated_at` d'environ
# 1 ms, par le même chemin pour la caméra et le micro. Une piste déjà calée
# plus tôt n'est pas modifiée. À lancer AVANT `montages[…,refaire]`.
namespace :recordings do
  desc "Produit les montages par personne manquants d'un webinaire (slug, identité facultative, « refaire »)"
  task :montages, %i[slug identity mode] => :environment do |_task, args|
    webinar = Webinar.find_by!(slug: args.fetch(:slug))
    mode = args[:mode].presence
    abort "mode inconnu : #{mode} (seul « refaire » est reconnu)" unless mode.nil? || mode == "refaire"

    tracks = webinar.recordings.tracks
    identities = args[:identity].presence ? [ args[:identity] ] : tracks.where(status: "done").distinct.pluck(:participant_identity).compact.sort

    identities.each do |identity|
      if tracks.where(participant_identity: identity, status: Recording::ACTIVE_STATUSES).exists?
        puts "#{identity} : une piste capte encore, montage remis à plus tard"
        next
      end

      MuxParticipantJob.perform_now(webinar.id, identity, rebuild: mode == "refaire")
      webinar.recordings.participants.where(participant_identity: identity).order(:id).each do |mux|
        puts [ identity, "montage ##{mux.id}", mux.status, mux.path || "sans fichier",
               "pistes #{mux.source_track_ids.to_a.join(',')}", mux.error_message ].compact.join(" · ")
      end
    end
    deposited_at = webinar.episode_publication&.started_at
    if deposited_at && webinar.recordings.participants.done.where(participant_identity: identities)
                              .where("ended_at > ?", deposited_at).exists?
      puts "Assemblages refaits depuis le dernier dépôt dans Nextcloud : relancer la publication " \
           "depuis la page du webinaire pour les y remplacer."
    end
  end

  desc "Reprend media_started_at des pistes depuis le journal egress LiveKit (entrée standard)"
  task activations: :environment do
    activation = /\A(?<at>\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z)\s.*\begress_active\b.*"egressID": "(?<egress_id>EG_[A-Za-z0-9]+)"/
    activations = {}
    $stdin.each_line do |line|
      match = activation.match(line)
      activations[match[:egress_id]] ||= Time.iso8601(match[:at]) if match
    end

    tracks = Recording.tracks.where(egress_id: activations.keys).index_by(&:egress_id)
    activations.each do |egress_id, at|
      track = tracks[egress_id]
      next unless track

      outcome = track.note_media_start(at).positive? ? "calée sur #{at.iso8601(3)}" : "déjà calée, inchangée"
      puts "#{egress_id} · piste ##{track.id} #{track.participant_identity} #{track.track_source} · #{outcome}"
    end
    puts "#{tracks.size} piste(s) reconnue(s) sur #{activations.size} activation(s) lue(s)"
  end
end
