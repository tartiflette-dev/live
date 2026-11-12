# frozen_string_literal: true

require "test_helper"

# EpisodePublicationMailer — contenu factuel : dossier, lien, durée, fichiers
# partagés ; des vidéos en relecture, une phrase sans nom ni lien.
class EpisodePublicationMailerTest < ActionMailer::TestCase
  include EpisodePublicationHelpers

  test "mail à un intervenant : dossier et lien, durée du direct, liste des fichiers, réponse à l'animateur" do
    webinar = ended_cafe
    speaker = webinar.speakers.create!(name: "Tristan Lemaire", email: "tristan@example.test")
    publication = webinar.create_episode_publication!(
      status: "published", folder: "Cafe-IA/2030-01-17-cafe-ia-007", folder_url: "https://cloud.test/f/4242",
      files: [ { "name" => "video-complete-fin-10h27-64.mp4", "size" => 1_291_968_609, "zone" => "shared" },
               { "name" => "pistes/tristan-lemaire-micro-fin-10h27-67.ogg", "size" => 21_458_690, "zone" => "shared" } ]
    )

    mail = EpisodePublicationMailer.published(publication, speaker)

    assert_equal [ "tristan@example.test" ], mail.to
    assert_equal [ "marc@example.test" ], mail.reply_to
    assert_equal "Café IA #7 — fichiers déposés dans Nextcloud", mail.subject
    text = mail.text_part.body.to_s
    assert_includes text, "Bonjour Tristan Lemaire,"
    assert_includes text, "sont déposés dans Nextcloud.\n\nDurée du direct : 47 min 43 s (de 09:40 à 10:28, heure de Paris)\nDossier"
    assert_includes text, "Dossier : Cafe-IA/2030-01-17-cafe-ia-007\nLien : https://cloud.test/f/4242\n"
    assert_includes text, "Fichiers (2) :\n- video-complete-fin-10h27-64.mp4 (1,2 Go)\n- pistes/tristan-lemaire-micro-fin-10h27-67.ogg (20,5 Mo)\n"
    assert_includes mail.html_part.body.to_s, %(<a href="https://cloud.test/f/4242">https://cloud.test/f/4242</a>)
    assert_not_includes text, EpisodePublication::IN_REVIEW_NOTICE
  end

  test "vidéos en relecture ou validées non déplacées : ni nommées ni liées, annoncées d'une phrase" do
    webinar = ended_cafe
    speaker = webinar.speakers.create!(name: "Basile Delmas", email: "basile@example.test")
    publication = webinar.create_episode_publication!(
      status: "published", folder: "Cafe-IA/2030-01-17-cafe-ia-007", folder_url: "https://cloud.test/f/4242",
      review_folder: "Relecture/Cafe-IA/2030-01-17-cafe-ia-007", review_folder_url: "https://cloud.test/f/7777",
      files: [ { "name" => "README.md", "size" => 900, "zone" => "shared" },
               { "name" => "video-complete-fin-10h27-64.mp4", "size" => 1_291_968_609, "zone" => "review" },
               { "name" => "pistes/marc-partage-ecran-fin-10h13-71.mp4", "size" => 9, "zone" => "approved" },
               { "name" => "pistes/marc-son-ecran-fin-10h13-72.ogg", "size" => 9, "zone" => "withdrawn" } ]
    )

    mail = EpisodePublicationMailer.published(publication, speaker)

    notice = EpisodePublication::IN_REVIEW_NOTICE
    { mail.text_part.body.to_s => notice, mail.html_part.body.to_s => ERB::Util.html_escape(notice) }.each do |body, shown|
      assert_includes body, "Fichiers (1) :"
      assert_includes body, shown
      assert_no_match(/video-complete|ecran|7777|Relecture/, body)
    end
  end
end
