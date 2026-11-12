require "test_helper"

# Bruit Whisper côté Rails : mêmes listes que le transcripteur et le
# panneau du direct (transcriber/transcript_noise.json).
class TranscriptNoiseTest < ActiveSupport::TestCase
  test "phrases fantômes et hésitations seules : du bruit, quelle que soit la graphie" do
    [ "Merci d'avoir regardé cette vidéo !", "Sous-titrage Société Radio-Canada", "SOUS-TITRES RÉALISÉS PAR la communauté",
      "Euh… hum.", "Euhhh", "Euh, sous-titrage ST' 501", "", "  ", nil ].each do |text|
      assert TranscriptNoise.noise?(text), text.inspect
    end
  end

  test "une vraie phrase n'en est pas, même commencée par une hésitation ou citant une formule" do
    [ "Euh, donc on parlait des agents.", "Ben oui", "Je vous dis merci d'avoir regardé le replay hier",
      "Les sous-titres sont activables" ].each do |text|
      assert_not TranscriptNoise.noise?(text), text
    end
  end
end
