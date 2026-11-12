# Échelle { min (0 ou 1), max (2 à 10), min_label, max_label }.
# Réponse = un entier entre min et max.
class Poll::Format::Scale < Poll::Format::Base
  MIN = (0..1)
  MAX = (2..10)
  VALUE_SQL = Arel.sql("CAST(json_extract(value, '$') AS INTEGER)")

  def normalize_options(raw)
    return raw unless raw.is_a?(Hash)

    scale = raw.stringify_keys
    {
      "min" => Integer(scale["min"], exception: false),
      "max" => Integer(scale["max"], exception: false),
      "min_label" => scale["min_label"].to_s.strip.presence,
      "max_label" => scale["max_label"].to_s.strip.presence
    }
  end

  def validate_options(errors)
    valid = options.is_a?(Hash) && MIN.cover?(options["min"]) && MAX.cover?(options["max"]) &&
      [ options["min_label"], options["max_label"] ].all? { |label| label.nil? || label.length <= Poll::OPTION_LIMIT }
    errors.add(:options, "d'échelle : minimum 0 ou 1, maximum de 2 à 10") unless valid
  end

  def normalize_value(raw)
    Poll::Format.strict_integer(raw)
  end

  def valid_value?(value)
    values.include?(value)
  end

  def tally(responses)
    counts = responses.group(VALUE_SQL).count
    { counts: values.map { |value| counts.fetch(value, 0) }, average: responses.average(VALUE_SQL)&.to_f&.round(1) }
  end

  def answer_labels
    values.map(&:to_s)
  end

  def respondents(rows)
    values.map { |scale| rows.select { |_, value| value == scale }.map(&:first) }
  end

  private

  def values
    (options.fetch("min")..options.fetch("max")).to_a
  end
end
