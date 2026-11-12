class TranscriptSegment < ApplicationRecord
  # Segment de transcript multi-locuteur produit par
  # transcriber/ (LiveKit Agent + Whisper) et archivé pendant le
  # direct. Un segment = résultat STT FINAL d'une tranche de parole d'une
  # piste micro distante (silero VAD détermine la frontière de phrase,
  # StreamAdapter encapsule le STT non-streaming openai).
  #
  # Idempotence : (webinar_id, segment_id) unique — défense contre un
  # double envoi accidentel ou un rejeu futur. L'agent ne retente PAS un
  # POST échoué (un segment manqué vaut mieux qu'un direct qui boucle).

  belongs_to :webinar

  validates :participant_identity, presence: true, length: { maximum: 128 }
  validates :speaker_name, length: { maximum: 128 }, allow_nil: true
  validates :text, presence: true
  validates :started_at, presence: true
  validates :ended_at, presence: true
  validates :segment_id, presence: true, length: { maximum: 128 },
                         uniqueness: { scope: :webinar_id }

  scope :chronological, -> { order(started_at: :asc, created_at: :asc) }

  # Rendu plat `[HH:MM:SS] Nom : texte`, un segment par ligne.
  # Fuseau = Europe/Paris (config/application.rb) — la webinaire se vit
  # côté animateur à l'heure locale ; l'archive sert à relire la session,
  # pas à aligner des télémesures.
  def self.formatted_text(scope = chronological)
    scope.pluck(:started_at, :speaker_name, :participant_identity, :text).map do |started_at, name, identity, text|
      displayed = (name.presence || identity.presence || "Participant")
      "[#{started_at.in_time_zone(Time.zone).strftime("%H:%M:%S")}] #{displayed} : #{text}"
    end.join("\n") + "\n"
  end
end
