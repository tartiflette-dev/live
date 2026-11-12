require "test_helper"

# Géométrie des graphiques de la page « Présence » : même échelle de temps
# pour la courbe et la chronologie, graduations en heures de Paris.
class PresenceChartTest < ActiveSupport::TestCase
  Timeline = Struct.new(:curve, :window, :peak, keyword_init: true)

  def at(clock)
    Time.zone.parse("2026-11-10 #{clock}")
  end

  setup do
    curve = [ [ at("9:30"), 1 ], [ at("9:45"), 4 ], [ at("10:30"), 0 ] ]
    @chart = PresenceChart.new(Timeline.new(curve: curve, window: [ at("9:30"), at("10:30") ], peak: [ at("9:45"), 4 ]))
  end

  test "le temps va de la marge gauche à la marge droite, le nombre de bas en haut" do
    assert_equal PresenceChart::LEFT, @chart.x(at("9:30"))
    assert_equal PresenceChart::WIDTH - PresenceChart::RIGHT, @chart.x(at("10:30"))
    assert_equal @chart.curve_bottom, @chart.y(0)
    assert_equal PresenceChart::CURVE_TOP, @chart.y(4)
  end

  test "courbe en marches" do
    x = ->(clock) { @chart.x(at(clock)) }
    y = ->(count) { @chart.y(count) }
    assert_equal "M#{x['9:30']} #{y[1]} H#{x['9:45']} V#{y[4]} H#{x['10:30']} V#{y[0]} H#{x['10:30']}",
                 @chart.curve_path
  end

  test "fenêtre resserrée : la courbe part du nombre déjà présent, rien n'est tracé au-delà" do
    curve = [ [ at("9:00"), 2 ], [ at("9:45"), 4 ], [ at("16:00"), 1 ], [ at("16:10"), 0 ] ]
    chart = PresenceChart.new(Timeline.new(curve: curve, window: [ at("9:30"), at("10:30") ], peak: [ at("9:45"), 4 ]))

    assert_equal "M#{chart.x(at('9:30'))} #{chart.y(2)} H#{chart.x(at('9:45'))} V#{chart.y(4)} H#{chart.x(at('10:30'))}", chart.curve_path
    assert_equal PresenceChart::WIDTH - PresenceChart::RIGHT, chart.x(at("16:00")), "hors fenêtre : collé au bord"
    afternoon = PresenceTimeline::Attendee.new(intervals: [ [ at("16:00"), at("16:10") ] ], attempts: [])
    assert_empty chart.bars(afternoon)
  end

  test "graduations : toutes les dix minutes sur une heure, nombres entiers" do
    assert_equal %w[9:30 9:40 9:50 10:00 10:10 10:20 10:30], @chart.time_ticks.map { |_, time| time.strftime("%-H:%M") }
    assert_equal [ 0, 1, 2, 3, 4 ], @chart.count_ticks.map(&:last)
  end

  test "barres et marques d'une personne" do
    attempt = PresenceEvent.new(kind: "aborted", occurred_at: at("9:40"))
    early = PresenceEvent.new(kind: "page_opened", occurred_at: at("8:00"))
    attendee = PresenceTimeline::Attendee.new(intervals: [ [ at("9:30"), at("10:00") ] ], attempts: [ attempt, early ])

    assert_equal [ [ PresenceChart::LEFT, (@chart.plot_width / 2.0).round(1) ] ], @chart.bars(attendee)
    assert_equal [ [ @chart.x(at("9:40")), "aborted" ] ], @chart.marks(attendee), "hors de la fenêtre : pas de marque"
  end
end
