# Géométrie des graphiques SVG de la page « Présence », rendus côté serveur
# (aucune bibliothèque de graphique dans l'app) : la courbe du nombre de
# présents et la chronologie par personne, sur la même échelle de temps.
# Coordonnées en unités du viewBox ; la vue n'a plus qu'à les poser.
class PresenceChart
  WIDTH = 720
  LEFT = 36
  RIGHT = 12
  CURVE_HEIGHT = 180
  CURVE_TOP = 10
  AXIS_HEIGHT = 24
  ROW_HEIGHT = 22
  BAR_HEIGHT = 12
  TICK_STEPS = [ 1, 2, 5, 10, 15, 20, 30, 60, 120, 240 ].map(&:minutes).freeze
  MAX_TICKS = 8

  attr_reader :from, :to, :max

  def initialize(timeline)
    @curve = timeline.curve
    @from, @to = timeline.window
    @to = @from + 1.minute if @to <= @from
    @max = [ timeline.peak&.last.to_i, 1 ].max
  end

  def plot_width
    WIDTH - LEFT - RIGHT
  end

  def curve_bottom
    CURVE_TOP + CURVE_HEIGHT
  end

  def curve_view_height
    curve_bottom + AXIS_HEIGHT
  end

  # Hors de la fenêtre (PresenceTimeline#window_of) : collé au bord.
  def x(time)
    (LEFT + (time.clamp(@from, @to) - @from) / (@to - @from) * plot_width).round(1)
  end

  def y(count)
    (curve_bottom - count.to_f / @max * CURVE_HEIGHT).round(1)
  end

  # Courbe en marches : le nombre de présents ne change qu'aux arrivées et
  # aux départs.
  # Commence au nombre de présents à l'ouverture de la fenêtre.
  def curve_path
    before, within = @curve.partition { |at, _| at <= @from }
    steps = [ "M#{x(@from)} #{y(before.last&.last.to_i)}" ]
    within.take_while { |at, _| at <= @to }.each do |at, count|
      steps << "H#{x(at)}" << "V#{y(count)}"
    end
    steps << "H#{x(@to)}"
    steps.join(" ")
  end

  # @return [Array<Array(Float, Time)>] graduations de l'axe du temps
  def time_ticks
    step = TICK_STEPS.find { |candidate| (@to - @from) / candidate <= MAX_TICKS } || TICK_STEPS.last
    first = Time.zone.at((@from.to_f / step).ceil * step)
    (0..).lazy.map { |index| first + index * step }.take_while { |tick| tick <= @to }.map { |tick| [ x(tick), tick ] }.to_a
  end

  # @return [Array<Array(Float, Integer)>] graduations du nombre de présents
  def count_ticks
    step = (@max / 5.0).ceil
    (0..@max).step(step).map { |count| [ y(count), count ] }
  end

  def rows_view_height(rows)
    rows * ROW_HEIGHT + AXIS_HEIGHT
  end

  def row_y(index)
    index * ROW_HEIGHT + (ROW_HEIGHT - BAR_HEIGHT) / 2.0
  end

  # @return [Array<Array(Float, Float)>] [x, largeur] de chaque présence
  def bars(attendee)
    attendee.intervals.select { |from, to| to > @from && from < @to }
            .map { |from, to| [ x(from), [ x(to) - x(from), 1.5 ].max.round(1) ] }
  end

  # @return [Array<Array(Float, String)>] [x, sorte] de chaque tentative visible
  def marks(attendee)
    attendee.attempts.select { |event| event.occurred_at.between?(@from, @to) }.map { |event| [ x(event.occurred_at), event.kind ] }
  end
end
