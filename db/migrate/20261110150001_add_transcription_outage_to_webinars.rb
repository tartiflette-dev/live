# Transcription absente pendant un direct (Webinar::TranscriptionOutage) :
# depuis quand le transcripteur manque à une salle occupée, et quand cette
# absence a franchi le seuil (bandeau de la régie, alerte à l'équipe). En
# base, pas dans un cache : l'état survit aux redémarrages des jobs, et
# l'alerte ne repart pas à chaque relance.
class AddTranscriptionOutageToWebinars < ActiveRecord::Migration[8.1]
  def change
    change_table :webinars, bulk: true do |t|
      t.datetime :transcriber_absent_since
      t.datetime :transcription_interrupted_at
    end
  end
end
