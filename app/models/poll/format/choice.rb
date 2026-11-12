# Choix parmi 2 à 6 libellés ; `multiple` autorise plusieurs choix.
# Réponse = tableau trié d'indices d'options ([2], ou [0, 3] en multiple).
class Poll::Format::Choice < Poll::Format::Base
  COUNT = (2..6)

  def multiple_allowed? = true

  def answer_labels = options

  def normalize_options(raw)
    raw.is_a?(Array) ? raw.map { |option| option.to_s.strip }.reject(&:empty?) : raw
  end

  def validate_options(errors)
    valid = options.is_a?(Array) && COUNT.cover?(options.size) &&
      options.all? { |option| option.length <= Poll::OPTION_LIMIT } && options.uniq.size == options.size
    errors.add(:options, "doivent compter de 2 à 6 choix distincts, de #{Poll::OPTION_LIMIT} caractères au plus") unless valid
  end

  def normalize_value(raw)
    Array(raw).filter_map { |index| Poll::Format.strict_integer(index) }.uniq.sort
  end

  def valid_value?(value)
    value.is_a?(Array) && value.any? && (poll.multiple? || value.size == 1) &&
      value.all? { |index| index.between?(0, options.size - 1) }
  end

  # Une personne compte pour chaque option cochée (json_each).
  def tally(responses)
    counts = responses.from("poll_responses, json_each(poll_responses.value) AS picked").group("picked.value").count
    { counts: options.each_index.map { |index| counts.fetch(index, 0) } }
  end

  def respondents(rows)
    options.each_index.map { |index| rows.select { |_, value| value.include?(index) }.map(&:first) }
  end
end
