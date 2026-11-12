# frozen_string_literal: true

# Bruit Whisper reconnu côté Rails : phrases « fantômes » apprises sur des
# génériques de sous-titrage (« Merci d'avoir regardé », « Sous-titrage
# Société Radio-Canada »), émises sur du silence ou du bruit de clavier, et
# segments faits uniquement d'hésitations (« Euh… »).
#
# Même règle et MÊMES listes que le filtre à la source (transcriber/noise.py)
# et le filtre d'affichage du direct (app/javascript/rooms/transcript_filter.js) :
# un seul fichier, `transcriber/transcript_noise.json`. Sert aux segments
# archivés avant le filtre à la source, que le montage du replay ne doit pas
# prendre pour de la parole (MontagePlan).
module TranscriptNoise
  NOISE = JSON.parse(Rails.root.join("transcriber/transcript_noise.json").read).freeze
  PHANTOM_PREFIXES = NOISE.fetch("phantom_prefixes").freeze
  HESITATION_WORDS = NOISE.fetch("hesitation_words").to_set.freeze
  LEADING_FILLER = Regexp.new(NOISE.fetch("leading_filler_pattern"), Regexp::IGNORECASE)

  module_function

  def noise?(text)
    normalized = normalize(text.to_s.sub(LEADING_FILLER, ""))
    normalized.empty? || phantom?(normalized) || hesitation_only?(normalized)
  end

  # Minuscules, accents retirés, tout ce qui n'est ni lettre ni chiffre
  # ramené à une espace.
  def normalize(text)
    text.unicode_normalize(:nfd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, " ").strip
  end

  def phantom?(normalized)
    PHANTOM_PREFIXES.any? { |prefix| normalized == prefix || normalized.start_with?("#{prefix} ") }
  end

  def hesitation_only?(normalized)
    normalized.split(" ").all? { |word| HESITATION_WORDS.include?(word.squeeze) }
  end
end
