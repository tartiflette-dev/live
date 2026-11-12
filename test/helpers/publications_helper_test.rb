# frozen_string_literal: true

require "test_helper"

# Raison affichée quand le dépôt automatique attend : les durées suivent
# les constantes d'EpisodePublication.
class PublicationsHelperTest < ActionView::TestCase
  include EpisodePublicationHelpers

  test "délai de calme et fenêtre automatique lus dans les constantes" do
    assert_equal "Dépôt automatique 10 min après la fin du direct, le temps d'une éventuelle reprise.",
                 publication_hold_message(nil, :quiet)
    assert_match(/\ADirect terminé il y a plus de 24 h : /, publication_hold_message(nil, :too_old))
  end

  test "heures et durée d'une vidéo à valider, lues sur son enregistrement ; rien sans enregistrement de ce webinaire" do
    with_recordings_root do
      webinar = ended_cafe(slug: "cafe-ia-7")
      other = ended_cafe(slug: "cafe-ia-8")
      recording = add_recording(webinar, kind: "composite", file: "a.mp4")
      foreign = add_recording(other, kind: "composite", file: "b.mp4")
      open_ended = add_recording(webinar, kind: "composite", file: "c.mp4", status: "failed", ended: nil)

      assert_equal "9:31-10:27 · 57 min", publication_video_timing(webinar, "video-complete-fin-10h27-#{recording.id}.mp4")
      assert_nil publication_video_timing(webinar, "video-complete-fin-10h27-#{foreign.id}.mp4")
      assert_nil publication_video_timing(webinar, "video-complete-fin-10h27-#{open_ended.id}.mp4")
      assert_nil publication_video_timing(webinar, "README.md")
    end
  end

  test "versions légères en préparation : leur nombre et l'attente maximale, lue dans LightVersion::WAIT" do
    original = EpisodePublication.method(:waiting_light_versions)
    EpisodePublication.define_singleton_method(:waiting_light_versions) { |*| %i[composite assemblage] }

    assert_equal "Versions légères des vidéos en préparation (2 fichiers), au plus 6 h : sinon les originaux partent. " \
                 "Le bouton dépose tout de suite, en original ce qui n'est pas prêt.",
                 publication_hold_message(Webinar.new, :lightening)
  ensure
    EpisodePublication.define_singleton_method(:waiting_light_versions, original)
  end

  test "durées en heures et minutes" do
    assert_equal "1 h 30", send(:duration_words, 90.minutes)
    assert_equal "45 min", send(:duration_words, 45.minutes)
    assert_equal "3 h", send(:duration_words, 3.hours)
    assert_equal "1 h 05", send(:duration_words, 65.minutes)
  end
end
