# Chapitres d'un café, un jeu par webinaire : PROPOSÉS par le LLM local
# (ChapterProposalJob) ou saisis par l'animation, montrés aux spectateurs du
# replay seulement une fois VALIDÉS par un animateur (WebinarChaptersController).
#
# `llm_outcome` = issue du dernier passage du LLM (ok, partial, invalid,
# unreachable, llm_disabled, llm_unconfigured, no_transcript) ;
# `transcript_digest` = empreinte de la transcription qu'il a lue : une
# transcription qui a changé depuis (reprise du direct, rattrapage) relance une
# proposition tant qu'elle n'est pas validée. Un jeu validé n'est plus jamais
# remplacé par le LLM, seulement par l'animation.
class ChapterSet < ApplicationRecord
  # Chapitre avant enregistrement : proposé par le LLM ou saisi.
  Draft = Data.define(:starts_at, :title, :themes)

  belongs_to :webinar, inverse_of: :chapter_set
  belongs_to :validated_by, class_name: "User", optional: true
  has_many :chapters, -> { order(:starts_at, :id) }, dependent: :delete_all, inverse_of: :chapter_set

  validates :webinar_id, uniqueness: true

  scope :validated, -> { where.not(validated_at: nil) }

  # Empreinte de la transcription d'un webinaire : nombre de segments et
  # dernière écriture.
  def self.transcript_digest(webinar)
    count, last_write = webinar.transcript_segments.pick(Arel.sql("COUNT(*)"), Arel.sql("MAX(updated_at)"))
    "#{count}:#{last_write}"
  end

  def validated?
    validated_at.present?
  end

  # Le LLM a-t-il une transcription plus récente à lire ? Jamais pour un jeu
  # validé.
  def stale?(digest)
    !validated? && transcript_digest != digest
  end

  # Remplace les chapitres par une proposition du LLM (vide s'il a échoué).
  # Le LLM lit plusieurs minutes : l'écriture se fait sous verrou, sur l'état
  # relu en base, et n'a pas lieu si le jeu est validé ou si l'animation y a
  # touché depuis `read_at` (son `updated_at` lu au départ du job) — son
  # travail n'est jamais écrasé, et des titres non relus ne deviennent jamais
  # visibles.
  # @return [Boolean] false si rien n'a été écrit
  def propose!(drafts, outcome:, model:, digest:, read_at: nil, now: Time.current)
    with_lock do
      next false if validated? || (read_at && updated_at != read_at)

      replace_chapters(drafts)
      update!(llm_outcome: outcome, llm_model: model, generated_at: now, transcript_digest: digest)
      true
    end
  end

  # Chapitres relus par l'animation ; `validate` les montre aux spectateurs,
  # sinon le jeu garde son état (un jeu validé reste visible). Le travail de
  # l'animation porte sur la transcription du moment : le LLM ne le remplace
  # pas tant qu'elle ne change pas. `updated_at` est toujours avancé, même sans
  # autre changement : c'est lui qu'une proposition en cours relit.
  def revise!(drafts, by:, validate:, now: Time.current)
    transaction do
      replace_chapters(drafts)
      attributes = { transcript_digest: self.class.transcript_digest(webinar), updated_at: now }
      attributes.merge!(validated_at: now, validated_by: by) if validate
      update!(attributes)
    end
  end

  def unvalidate!
    update!(validated_at: nil, validated_by: nil)
  end

  # Thèmes du café : ceux des chapitres, dans l'ordre d'apparition, sans
  # doublon (Chapter.theme_key).
  # @return [Array<String>]
  def themes
    chapters.flat_map(&:themes).uniq { |theme| Chapter.theme_key(theme) }
  end

  # Heure réelle du début de la vidéo sur laquelle les chapitres se calent :
  # celle du replay, sinon celle qu'il aurait (Replay.reference_recording_for),
  # sinon le premier segment de transcription.
  # @return [ActiveSupport::TimeWithZone, nil]
  def origin
    recording = webinar.replay&.recording || Replay.reference_recording_for(webinar)
    recording&.started_at || webinar.transcript_segments.minimum(:started_at)
  end

  private

  # Un jeu encore jamais enregistré (écran ouvert sans proposition) l'est ici.
  def replace_chapters(drafts)
    save! if new_record?
    chapters.delete_all
    drafts.each { |draft| chapters.create!(starts_at: draft.starts_at, title: draft.title, themes: draft.themes) }
    chapters.reset
  end
end
