require "test_helper"

# Plan de montage du replay piloté par la parole : horaires en entrée, plans
# en sortie, sans base ni vidéo. Café de 10 min à partir de T0, trois
# personnes caméra allumée tout du long : Anne (hôte), Inès, Marc.
class MontagePlanTest < ActiveSupport::TestCase
  T0 = Time.zone.parse("2026-11-10 08:30:00")
  DURATION = 600

  setup do
    @segments = []
    @sources = [ camera("cam-anne", "host-anne"), camera("cam-ines", "speaker-1"), camera("cam-marc", "speaker-2") ]
    @spotlights = []
  end

  test "la personne qui parle est en grand, les autres en vignettes, dans l'ordre d'arrivée" do
    says("host-anne", 0, 40)
    says("speaker-1", 40, 90)

    assert_equal [ [ 0, 40, :speaker, "cam-anne", %w[cam-ines cam-marc] ],
                   [ 40, DURATION, :speaker, "cam-ines", %w[cam-anne cam-marc] ] ], summary
  end

  test "silence : l'image reste sur la dernière personne qui a parlé" do
    says("host-anne", 0, 30)
    says("speaker-1", 200, 230)

    assert_equal [ [ 0, 200, "cam-anne" ], [ 200, DURATION, "cam-ines" ] ], mains
  end

  test "bruit de clavier, interjection et bruit Whisper ne prennent jamais l'image" do
    says("host-anne", 0, 60)
    # Marc tape au clavier : aucun segment. Inès dit « oui » (0,6 s), puis
    # Whisper invente deux phrases sur le bruit de Marc.
    says("speaker-1", 20, 20.6, "Oui.")
    says("speaker-2", 30, 33, "Merci d'avoir regardé cette vidéo !")
    says("speaker-2", 40, 44, "Sous-titrage Société Radio-Canada")
    says("speaker-2", 50, 52, "Euh… hum.")

    assert_equal [ [ 0, DURATION, "cam-anne" ] ], mains
    assert_equal [ "host-anne" ], plan.speech.keys
  end

  test "deux voix à la fois : la plus récente prend l'image ; une courte interruption est absorbée" do
    says("host-anne", 0, 100)
    says("speaker-1", 30, 31.8, "Ah oui, tout à fait")
    says("speaker-1", 60, 90, "Je voulais ajouter quelque chose sur ce point")

    assert_equal [ [ 0, 60, "cam-anne" ], [ 60, 90, "cam-ines" ], [ 90, DURATION, "cam-anne" ] ], mains
  end

  test "segments rapprochés d'une même personne : un seul plan, sans bascule dans les pauses" do
    says("host-anne", 0, 10)
    [ 10, 13, 16 ].each { |start| says("speaker-1", start, start + 2) }
    says("host-anne", 12.5, 13.5, "Oui oui")

    assert_equal [ [ 0, 10, "cam-anne" ], [ 10, DURATION, "cam-ines" ] ], mains
  end

  test "aucun plan de moins de MIN_SHOT, plans contigus de 0 à la fin" do
    0.step(590, 3.1).each_with_index do |start, index|
      says(%w[host-anne speaker-1 speaker-2][index % 3], start, start + 1.4 + (index % 4))
    end

    shots = plan.shots
    assert_in_delta 0, shots.first.from
    assert_in_delta DURATION, shots.last.to
    shots.each_cons(2) { |shot, following| assert_in_delta shot.to, following.from }
    assert shots.all? { |shot| shot.duration >= MontagePlan::MIN_SHOT }, shots.map(&:duration).min.to_s
  end

  test "écran partagé : l'écran en grand, la personne qui parle en première vignette" do
    @sources << source("ecran-marc", "speaker-2", :screen, 100, 200)
    says("speaker-1", 0, 300)

    assert_equal [ [ 0, 100, :speaker, "cam-ines", %w[cam-anne cam-marc] ],
                   [ 100, 200, :screen, "ecran-marc", %w[cam-ines cam-anne cam-marc] ],
                   [ 200, DURATION, :speaker, "cam-ines", %w[cam-anne cam-marc] ] ], summary
  end

  test "personne sans piste caméra séparée : la vue d'ensemble pour ses plans" do
    says("host-anne", 0, 50)
    says("speaker-9", 50, 120)
    says("speaker-1", 120, 160)

    assert_equal [ [ 0, 50, :speaker ], [ 50, 120, :composite ], [ 120, DURATION, :speaker ] ],
                 summary.map { |row| row.first(3) }
  end

  test "caméra coupée en cours de route : la vue d'ensemble prend le relais, puis la caméra revient" do
    @sources = [ camera("cam-anne", "host-anne"), source("cam-ines-1", "speaker-1", :camera, 0, 100),
                 source("cam-ines-2", "speaker-1", :camera, 150, DURATION) ]
    says("speaker-1", 0, 300)

    assert_equal [ [ 0, 100, :speaker, "cam-ines-1" ], [ 100, 150, :composite, nil ], [ 150, DURATION, :speaker, "cam-ines-2" ] ],
                 summary.map { |row| row.first(4) }
  end

  test "caméra qui arrive ou part pendant un plan : les vignettes suivent, le grand cadre ne bouge pas" do
    @sources = [ camera("cam-anne", "host-anne"), source("cam-marc", "speaker-2", :camera, 0, 500),
                 source("cam-ines", "speaker-1", :camera, 100, DURATION) ]
    says("host-anne", 0, DURATION)

    assert_equal [ [ 0, 100, :speaker, "cam-anne", %w[cam-marc] ],
                   [ 100, 500, :speaker, "cam-anne", %w[cam-marc cam-ines] ],
                   [ 500, DURATION, :speaker, "cam-anne", %w[cam-ines] ] ], summary
  end

  test "écran partagé long : les vignettes suivent aussi les arrivées" do
    @sources = [ camera("cam-anne", "host-anne"), source("ecran", "host-anne", :screen, 0, DURATION),
                 source("cam-ines", "speaker-1", :camera, 300, DURATION) ]
    says("host-anne", 0, DURATION)

    assert_equal [ [ 0, 300, :screen, "ecran", %w[cam-anne] ], [ 300, DURATION, :screen, "ecran", %w[cam-anne cam-ines] ] ], summary
  end

  test "avant toute parole : la vue d'ensemble" do
    says("speaker-1", 45, 80)

    assert_equal [ [ 0, 45, :composite ], [ 45, DURATION, :speaker ] ], summary.map { |row| row.first(3) }
  end

  test "mise en avant explicite : elle l'emporte sur la parole jusqu'à son retrait" do
    says("host-anne", 0, 300)
    spotlight("speaker-2", 100)
    spotlight(nil, 200)

    assert_equal [ [ 0, 100, "cam-anne" ], [ 100, 200, "cam-marc" ], [ 200, DURATION, "cam-anne" ] ], mains
  end

  test "piste hors de la vidéo ignorée, horaires bornés à la vidéo" do
    @sources << source("cam-avant", "speaker-3", :camera, -400, -100)
    says("host-anne", -20, 30)

    assert_equal [ [ 0, DURATION, :speaker, "cam-anne", %w[cam-ines cam-marc] ] ], summary
  end

  test "au plus MAX_THUMBNAILS vignettes" do
    6.times { |index| @sources << camera("cam-#{index}", "speaker-#{index + 10}") }
    says("host-anne", 0, 60)

    assert_equal MontagePlan::MAX_THUMBNAILS, plan.shots.first.thumbnails.size
  end

  private

  def plan
    MontagePlan.new(origin: T0, finish: T0 + DURATION, segments: @segments, sources: @sources, spotlights: @spotlights)
  end

  def summary
    plan.shots.map { |shot| [ shot.from.round(2), shot.to.round(2), shot.layout, shot.main, shot.thumbnails ] }
  end

  def mains
    plan.shots.map { |shot| [ shot.from.round(2), shot.to.round(2), shot.main ] }
  end

  def says(identity, from, to, text = "Une phrase assez longue pour compter.")
    @segments << MontagePlan::Segment.new(identity: identity, started_at: T0 + from, ended_at: T0 + to, text: text)
  end

  def camera(key, identity)
    source(key, identity, :camera, 0, DURATION)
  end

  def source(key, identity, kind, from, to)
    MontagePlan::Source.new(key: key, identity: identity, kind: kind, started_at: T0 + from, ended_at: T0 + to)
  end

  def spotlight(identity, at)
    @spotlights << MontagePlan::Spotlight.new(at: T0 + at, identity: identity)
  end
end
