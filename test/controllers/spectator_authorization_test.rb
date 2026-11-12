require "test_helper"

# Rôle spectateur : un compte Pocket ID sans groupe des animateurs, sans
# webinaire et sans invitation de co-animateur n'a AUCUN droit d'animation.
# Inventaire MÉCANIQUE : toute route de la zone animateur (/webinars…,
# /packs…, /questions, /animation…, la scène /w/:slug/stage) répond 404 au spectateur, sans rien
# écrire. Une route animateur ajoutée plus tard entre d'office dans ce test.
class SpectatorAuthorizationTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  ANIMATEUR_PATHS = %r{\A/(webinars|packs|questions|animation)(/|\(|\z)|\A/w/:slug/stage}

  setup do
    @owner = User.create!(email: "proprio@example.test", oidc_sub: "sub-proprio", admin: true)
    @webinar = Webinar.create!(title: "Café du proprio", starts_at: 1.hour.ago, host_sub: @owner.oidc_sub,
                               state: "live", started_at: 1.hour.ago, visibility: "published")
    @recording = @webinar.recordings.create!(kind: "composite", status: "recording", started_at: 10.minutes.ago)
    @poll = @webinar.polls.create!(position: 1, kind: "choice", label: "Question ?", options: %w[A B])
  end

  teardown do
    OmniAuth.config.mock_auth[:pocket_id] = nil
    OmniAuth.config.test_mode = false
  end

  def animateur_routes
    Rails.application.routes.routes.filter_map do |route|
      spec = route.path.spec.to_s.sub("(.:format)", "")
      next unless spec.match?(ANIMATEUR_PATHS)

      verb = route.verb.to_s[/GET|POST|PATCH|PUT|DELETE/] or next
      [ verb, fill(spec) ]
    end.uniq
  end

  def fill(spec)
    spec.gsub(":webinar_id", @webinar.slug).gsub(":slug", @webinar.slug).gsub(":identity", "viewer-1")
        .gsub(%r{/recordings/:id}, "/recordings/#{@recording.id}").gsub(%r{/polls/:id}, "/polls/#{@poll.id}")
        .gsub(%r{/webinars/:id}, "/webinars/#{@webinar.slug}").gsub(":id", "1")
  end

  def assert_every_animateur_route_answers_404
    routes = animateur_routes
    assert_operator routes.size, :>=, 60, "inventaire des routes animateur trop court : #{routes.size}"

    counts = -> { [ Webinar.count, Pack.count, Recording.count, Poll.count, Speaker.count, WebinarHost.count,
                    HostInvitation.count, Announcement.count, Replay.count, Message.count, ChapterSet.count, Chapter.count ] }
    before = counts.call
    routes.each do |verb, path|
      process verb.downcase.to_sym, path, as: (path.end_with?("status", "attendance") ? :json : nil)
      assert_response :not_found, "#{verb} #{path} doit répondre 404 au spectateur"
    end
    assert_equal before, counts.call, "le spectateur n'a rien écrit"
    assert @webinar.reload.live?, "le direct n'a pas été arrêté"
  end

  test "compte sans aucun groupe : 404 sur toutes les routes animateur" do
    sign_in_as(User.create!(email: "sans-groupe@example.test", oidc_sub: "sub-sans-groupe"), groups: [])
    assert_every_animateur_route_answers_404
  end

  test "compte du groupe des spectateurs : 404 sur toutes les routes animateur" do
    sign_in_as(User.create!(email: "spectatrice@example.test", oidc_sub: "sub-spectatrice"), groups: [ "live-spectateurs" ])
    assert_every_animateur_route_answers_404
  end

  test "compte sans claim de groupe ni vérification d'adresse : spectateur, 404" do
    sign_in_as(User.create!(email: "brut@example.test", oidc_sub: "sub-brut"), email_verified: nil)
    assert_every_animateur_route_answers_404
  end

  test "un spectateur ne crée pas de webinaire" do
    sign_in_as(User.create!(email: "intrus@example.test", oidc_sub: "sub-intrus"), groups: [ "live-spectateurs" ])

    assert_no_difference -> { Webinar.count } do
      post webinars_path, params: { webinar: { title: "Le mien", starts_at: 1.day.from_now } }
    end
    assert_response :not_found
  end

  test "dans la salle, un spectateur connecté n'a pas de jeton d'animateur" do
    sign_in_as(User.create!(email: "salle@example.test", oidc_sub: "sub-salle"), groups: [ "live-spectateurs" ])

    post api_token_path, params: { slug: @webinar.slug }, as: :json

    assert_not_equal "host", response.parsed_body["role"]
    assert_not_equal "cohost", response.parsed_body["role"]
  end

  test "témoin : l'animateur du projet passe le même inventaire sans 404 sur les pages de lecture" do
    sign_in_as(User.create!(email: "anim@example.test", oidc_sub: "sub-anim"), groups: [ "live-animateurs" ])

    [ webinars_path, webinar_path(@webinar), webinar_recordings_path(@webinar), webinar_replay_path(@webinar),
      packs_path ].each do |path|
      get path
      assert_response :success, path
    end
  end
end
