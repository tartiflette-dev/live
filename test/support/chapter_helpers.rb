# frozen_string_literal: true

# Chapitres et transcription d'un café de test (ReplayHelpers : composite de
# 09:31:06 à 10:27:44 le 17/01/2030).
module ChapterHelpers
  CAFE_DAY = "2030-01-17"

  # Segment de transcription à l'heure « HH:MM:SS » du café.
  def segment(webinar, at, text, identity: "speaker-1", name: "Laurent")
    started = Time.zone.parse("#{CAFE_DAY} #{at}")
    webinar.transcript_segments.create!(participant_identity: identity, speaker_name: name, text: text,
                                        started_at: started, ended_at: started + 4.seconds,
                                        segment_id: SecureRandom.uuid)
  end

  # Jeu de chapitres ; `validated` : montré aux spectateurs.
  def chapters_for(webinar, list, validated: true)
    set = webinar.chapter_set || ChapterSet.create!(webinar: webinar)
    set.unvalidate! if set.validated?
    drafts = list.map do |at, title, themes|
      ChapterSet::Draft.new(starts_at: Time.zone.parse("#{CAFE_DAY} #{at}"), title: title, themes: themes || [])
    end
    set.propose!(drafts, outcome: "ok", model: "glm-4-9b", digest: ChapterSet.transcript_digest(webinar))
    set.update!(validated_at: Time.current) if validated
    set
  end

  # Faux client qui découpe : rend `chapters` (Array de Hash) pour chaque
  # passage, `continues` faux.
  def chapter_llm(chapters = [ { "line" => 1, "title" => "Accueil", "themes" => [ "accueil" ] } ], continues: false)
    FakeLlmClient.new({ "continues" => continues, "chapters" => chapters })
  end

  def with_chapter_llm(client)
    previous = Rails.configuration.x.chapter_llm_client_factory
    Rails.configuration.x.chapter_llm_client_factory = -> { client }
    yield
  ensure
    Rails.configuration.x.chapter_llm_client_factory = previous
  end
end
