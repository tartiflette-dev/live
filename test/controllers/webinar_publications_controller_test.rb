# frozen_string_literal: true

require "test_helper"

# Publication Nextcloud depuis la page du webinaire : bouton de lancement
# ou de relance, état du dernier dépôt, vidéos en relecture et « Valider
# et partager ». Owner / project_host seulement.
class WebinarPublicationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include OidcSignIn
  include EpisodePublicationHelpers

  setup do
    @owner = User.create!(email: "owner@example.test", oidc_sub: "publication-owner")
    @guest = User.create!(email: "jean@partenaire.test", oidc_sub: "publication-guest",
                          email_verified: true, email_verified_for: "jean@partenaire.test")
    @webinar = Webinar.create!(title: "Café IA #7", slug: "cafe-ia-7", kind: "cafe_ia", visibility: "published",
                               starts_at: 1.hour.ago, host_sub: @owner.oidc_sub, state: "ended",
                               started_at: 2.hours.ago, ended_at: 30.minutes.ago)
    @webinar.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
  end

  test "le propriétaire lance la publication : job enfilé, publication en attente" do
    sign_in_as(@owner)

    with_nextcloud(FakeNextcloud.new) do
      assert_enqueued_with(job: PublishEpisodeJob, args: [ @webinar.id ]) { post webinar_publication_path(@webinar) }
    end
    assert_redirected_to webinar_path(@webinar)
    assert_equal "Publication dans Nextcloud lancée.", flash[:notice]
    assert @webinar.reload.episode_publication.queued?
  end

  test "un dépôt déjà en cours n'est pas relancé" do
    sign_in_as(@owner)
    @webinar.create_episode_publication!(status: "publishing", started_at: 1.minute.ago)

    with_nextcloud(FakeNextcloud.new) do
      assert_no_enqueued_jobs(only: PublishEpisodeJob) { post webinar_publication_path(@webinar) }
    end
    assert_equal "Publication déjà en cours.", flash[:notice]
  end

  test "refus lisibles : direct non terminé, série non configurée" do
    sign_in_as(@owner)

    assert_no_enqueued_jobs(only: PublishEpisodeJob) { post webinar_publication_path(@webinar) }
    assert_equal "Publication Nextcloud non configurée pour cette série.", flash[:alert]

    @webinar.update!(state: "live", ended_at: nil)
    with_nextcloud(FakeNextcloud.new) do
      assert_no_enqueued_jobs(only: PublishEpisodeJob) { post webinar_publication_path(@webinar) }
    end
    assert_equal "Le direct n'est pas terminé : rien à publier.", flash[:alert]
  end

  test "un co-animateur invité ou un anonyme ne publient pas" do
    post webinar_publication_path(@webinar)
    assert_redirected_to sign_in_path

    sign_in_as(@guest)
    with_nextcloud(FakeNextcloud.new) do
      assert_no_enqueued_jobs(only: PublishEpisodeJob) { post webinar_publication_path(@webinar) }
    end
    assert_response :not_found
  end

  test "page du webinaire : état publié, lien du dossier, prévenus, bouton de relance" do
    sign_in_as(@owner)
    @webinar.create_episode_publication!(status: "published", folder: "Cafe-IA/2030-01-17-cafe-ia-007",
                                         folder_url: "https://cloud.test/f/4242", started_at: 5.minutes.ago,
                                         published_at: 4.minutes.ago, files: [ { "name" => "README.md", "size" => 1, "zone" => "shared" } ],
                                         notified_emails: [ "basile@example.test" ])

    with_nextcloud(FakeNextcloud.new) { get webinar_path(@webinar) }

    assert_select "[data-role='publication'] [data-role='publication-state']", text: /Publiée.*1 fichier partagé dans/m
    assert_select "[data-role='publication-review']", count: 0
    assert_select "[data-role='publication-folder'][href='https://cloud.test/f/4242']", text: "Cafe-IA/2030-01-17-cafe-ia-007"
    assert_select "[data-role='publication-notified']", text: "Mail envoyé à : basile@example.test."
    assert_select "form[action='#{webinar_publication_path(@webinar)}'] [data-role='publication-launch']", count: 1
  end

  test "page du webinaire : vidéos en relecture, lien du dossier de relecture, bouton « Valider et partager » avec les vidéos montrées" do
    sign_in_as(@owner)
    publish_with_review

    with_nextcloud(FakeNextcloud.new) { get webinar_path(@webinar) }

    assert_select "[data-role='publication-state']", text: /1 fichier partagé dans/
    assert_select "[data-role='publication-review-folder'][href='https://cloud.test/f/7777']", text: "Relecture/Cafe-IA/2030-01-17-cafe-ia-007"
    assert_select "[data-role='publication-review-file']", 2
    assert_select "[data-role='publication-approved-file']", text: /pistes\/marc-son-ecran-3\.ogg — validée par owner@example\.test/
    assert_select "[data-role='publication-withdrawn']", text: /jamais partagées : pistes\/marc-partage-ecran-0\.mp4\./
    assert_select "form[action='#{webinar_publication_path(@webinar)}']:has([data-role='publication-approve'])" do
      assert_select "input[name='_method'][value='patch']"
      assert_select "input[name='names[]']", 2
      assert_select "input[name='names[]'][value='video-complete-1.mp4']"
    end
  end

  test "Valider et partager : valide les vidéos montrées encore en relecture, qui les valide, puis relance le dépôt" do
    sign_in_as(@owner)
    publish_with_review

    with_nextcloud(FakeNextcloud.new) do
      assert_enqueued_with(job: PublishEpisodeJob, args: [ @webinar.id ]) do
        patch webinar_publication_path(@webinar), params: { names: [ "video-complete-1.mp4", "README.md" ] }
      end
    end

    assert_redirected_to webinar_path(@webinar)
    assert_equal "1 vidéo validée : déplacement vers le dossier partagé lancé.", flash[:notice]
    publication = @webinar.reload.episode_publication
    assert publication.queued?
    assert_equal [ [ "video-complete-1.mp4", "owner@example.test" ], [ "pistes/marc-son-ecran-3.ogg", "owner@example.test" ] ],
                 publication.files_in("approved").map { |file| file.values_at("name", "approved_by") }
    assert_equal [ "pistes/marc-partage-ecran-2.mp4" ], publication.files_in("review").pluck("name")
  end

  test "Valider et partager : rien à valider, dépôt en cours, direct repris, co-animateur" do
    sign_in_as(@owner)
    publish_with_review

    with_nextcloud(FakeNextcloud.new) do
      assert_no_enqueued_jobs(only: PublishEpisodeJob) { patch webinar_publication_path(@webinar), params: { names: [ "README.md" ] } }
      assert_equal "Aucune vidéo en relecture à valider.", flash[:alert]
      assert_no_enqueued_jobs(only: PublishEpisodeJob) { patch webinar_publication_path(@webinar), params: { names: { "x" => "y" } } }
      assert_equal "Aucune vidéo en relecture à valider.", flash[:alert]

      @webinar.episode_publication.update!(status: "publishing", started_at: 1.minute.ago)
      patch webinar_publication_path(@webinar), params: { names: [ "video-complete-1.mp4" ] }
      assert_equal "Publication déjà en cours.", flash[:notice]

      @webinar.episode_publication.update!(status: "published")
      @webinar.update!(state: "live", ended_at: nil)
      patch webinar_publication_path(@webinar), params: { names: [ "video-complete-1.mp4" ] }
      assert_equal "Le direct n'est pas terminé : rien à publier.", flash[:alert]

      sign_in_as(@guest)
      patch webinar_publication_path(@webinar), params: { names: [ "video-complete-1.mp4" ] }
      assert_response :not_found
    end
    assert_equal [ "pistes/marc-son-ecran-3.ogg" ], @webinar.reload.episode_publication.files_in("approved").pluck("name"),
                 "rien de plus n'a été validé"
  end

  test "page du webinaire : ce qui retient le dépôt automatique est dit" do
    sign_in_as(@owner)
    @webinar.recordings.create!(kind: "track", status: "done", participant_identity: "speaker-1", track_source: "camera",
                                started_at: 90.minutes.ago, ended_at: 32.minutes.ago)

    with_nextcloud(FakeNextcloud.new) { get webinar_path(@webinar) }
    assert_select "[data-role='publication-state']", text: /En attente des assemblages \(1 personne\)/

    @webinar.update!(visibility: "draft")
    with_nextcloud(FakeNextcloud.new) { get webinar_path(@webinar) }
    assert_select "[data-role='publication-state']", text: /Brouillon : pas de dépôt automatique/
    assert_select "[data-role='publication-launch']", count: 1
  end

  test "page du webinaire : non configurée, aucun bouton ; invisible pour un co-animateur" do
    sign_in_as(@owner)
    get webinar_path(@webinar)
    assert_select "[data-role='publication-state']", text: /Non configurée/
    assert_select "[data-role='publication-launch']", count: 0

    sign_in_as(@guest)
    get webinar_path(@webinar)
    assert_response :success
    assert_select "[data-role='publication']", count: 0
  end

  private

  def publish_with_review
    @webinar.create_episode_publication!(
      status: "published", folder: "Cafe-IA/2030-01-17-cafe-ia-007", folder_url: "https://cloud.test/f/4242",
      review_folder: "Relecture/Cafe-IA/2030-01-17-cafe-ia-007", review_folder_url: "https://cloud.test/f/7777",
      started_at: 5.minutes.ago, published_at: 4.minutes.ago,
      files: [ { "name" => "README.md", "size" => 1, "zone" => "shared" },
               { "name" => "video-complete-1.mp4", "size" => 2, "zone" => "review" },
               { "name" => "pistes/marc-partage-ecran-2.mp4", "size" => 3, "zone" => "review" },
               { "name" => "pistes/marc-son-ecran-3.ogg", "size" => 4, "zone" => "approved", "approved_by" => "owner@example.test" },
               { "name" => "pistes/marc-partage-ecran-0.mp4", "size" => 5, "zone" => "withdrawn" } ]
    )
  end
end
