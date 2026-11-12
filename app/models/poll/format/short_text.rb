# Réponse libre de Poll::TEXT_LIMIT caractères, sans options.
class Poll::Format::ShortText < Poll::Format::Base
  # Réponses montrées à la salle : anonymes, les plus récentes, dans un
  # budget d'octets JSON qui garde le paquet LiveKit sous 16 KiB (libellé
  # et enveloppe compris, caractères échappés compris).
  PUBLIC_ANSWERS_BYTES = 8 * 1024

  # Montrer en direct des textes libres que personne n'a relus : non. Le
  # résultat se montre une fois le sondage fermé.
  def results_showable_while_open? = false

  def normalize_options(_raw) = nil

  def validate_options(_errors); end

  def normalize_value(raw)
    raw.strip if raw.is_a?(String)
  end

  def valid_value?(value)
    value.present? && value.length <= Poll::TEXT_LIMIT
  end

  def tally(responses)
    { answers: responses.order(:updated_at, :id).pluck(:value) }
  end

  def respondents(rows)
    rows.map { |name, value| { name: name, text: value } }
  end

  def public_results(results)
    budget = PUBLIC_ANSWERS_BYTES
    recent = results[:answers].reverse.take_while { |answer| (budget -= answer.to_json.bytesize + 1) >= 0 }
    results.merge(answers: recent.reverse)
  end
end
