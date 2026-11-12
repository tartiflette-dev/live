# Montage du replay piloté par la parole (ReplayMontage), à la demande.
#
#   bin/rails "replays:montage[cafe-ia-9]"
#
# Dépose la demande de montage du replay du webinaire (le replay est créé,
# non publié, s'il n'existe pas encore) ; un moteur de rendu externe, non
# distribué avec l'application, la rend hors direct (docs/replays.md,
# « Rendus hors de l'application ») et ReplayMontageSweepJob l'adopte comme
# copie de diffusion. Même geste que le bouton « Monter le replay » de la
# page Replay.
#
#   bin/rails "replays:montage_extrait[cafe-ia-9,900,1080]" > extrait.json
#
# Écrit sur la sortie standard le document de rendu d'un extrait (bornes en
# secondes de la vidéo), pour un rendu de contrôle ponctuel, hors file, à
# confier au moteur de rendu externe (même format qu'une demande).
namespace :replays do
  montage_for = lambda do |slug|
    webinar = Webinar.find_by!(slug: slug)
    replay = webinar.ended? && Replay.prepare!(webinar)
    abort "#{slug} : pas de direct terminé avec sa vue d'ensemble lisible" unless replay

    ReplayMontage.new(replay)
  end

  desc "Demande le montage piloté par la parole du replay d'un webinaire (slug)"
  task :montage, %i[slug] => :environment do |_task, args|
    montage = montage_for.call(args.fetch(:slug))
    puts montage.request! ? "demande déposée, rendu la nuit prochaine hors direct" : "demande identique déjà en file, ou montage déjà fait"
  end

  desc "Document de rendu d'un extrait du montage (slug, début et fin en secondes), sur la sortie standard"
  task :montage_extrait, %i[slug from to] => :environment do |_task, args|
    montage = montage_for.call(args.fetch(:slug))
    puts JSON.pretty_generate(montage.document(window: Float(args.fetch(:from))..Float(args.fetch(:to))))
  end
end

# Chapitres et index de recherche des replays, à la demande (cafés passés).
#
#   bin/rails replays:chapitres                      # tous les cafés qui ont transcription + vidéo
#   bin/rails "replays:chapitres[cafe-ia-9]"         # un café
#   bin/rails "replays:chapitres[cafe-ia-9,refaire]" # nouvelle proposition, même si la transcription n'a pas changé
#
# Même travail que la fin du direct et la publication (ChapterProposalJob),
# lancé ici sur place, café après café (~1 à 3 min par café avec le LLM de
# l'app). Un café sans vidéo de référence (Replay.reference_recording_for) ou
# sans transcription est sauté. Des chapitres VALIDÉS ne sont jamais
# remplacés ; l'index de recherche est remis à jour dans tous les cas. Les
# propositions attendent la relecture de l'animation (écran Chapitres du
# replay). Refuse de tourner pendant un direct (GPU partagé avec la
# transcription).
namespace :replays do
  desc "Propose les chapitres des cafés passés (slug facultatif, « refaire ») et met à jour l'index de recherche"
  task :chapitres, %i[slug mode] => :environment do |_task, args|
    mode = args[:mode].presence
    abort "mode inconnu : #{mode} (seul « refaire » est reconnu)" unless mode.nil? || mode == "refaire"
    abort "un direct est en cours : relancer après sa fin" if Webinar.live.exists?

    webinars = args[:slug].present? ? Webinar.where(slug: args[:slug]) : Webinar.ended.order(:starts_at)
    abort "café inconnu : #{args[:slug]}" if webinars.empty?

    webinars.each do |webinar|
      unless webinar.transcript_segments.exists? && Replay.reference_recording_for(webinar)
        puts "#{webinar.slug} : sauté (sans transcription ou sans vidéo)"
        next
      end

      ChapterProposalJob.perform_now(webinar.id, force: mode == "refaire")
      set = webinar.reload.chapter_set
      state = set.validated? ? "validés" : "proposés"
      puts "#{webinar.slug} : #{set.chapters.count} chapitres #{state} · LLM #{set.llm_outcome || "—"}"
    end
  end
end
