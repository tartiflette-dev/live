# Format d'une question de sondage — un objet par type,
# choisi UNE fois par `Poll#format`. Ajouter un type
# (long_text, ranking…) = une classe de plus ici, rien
# d'autre dans Poll ni PollResponse.
#
# Contrat de chaque format (POROs, construits sur le sondage) :
#   normalize_options(raw)      options nettoyées (nil si le type n'en a pas)
#   validate_options(errors)    erreurs sur `options`
#   multiple_allowed?           `multiple` a-t-il un sens
#   normalize_value(raw)        valeur de réponse normalisée (nil si illisible)
#   valid_value?(value)         la valeur répond-elle à la question
#   tally(responses)            agrégat SQL sans nom, hors `respondents`
#   respondents(rows)           noms par réponse, rows = [[name, value], …]
#   answer_labels               libellés alignés sur `tally[:counts]` (nil sans comptes)
#   public_results(results)     ce que la salle voit quand le résultat est montré
#   results_showable_while_open?  le résultat peut-il être montré en cours de sondage
module Poll::Format
  FORMATS = {
    "choice" => "Poll::Format::Choice",
    "scale" => "Poll::Format::Scale",
    "short_text" => "Poll::Format::ShortText"
  }.freeze

  def self.for(poll)
    FORMATS[poll.kind]&.constantize&.new(poll)
  end

  # Entier JSON ou chaîne de chiffres ; jamais un flottant tronqué.
  def self.strict_integer(raw)
    return raw if raw.is_a?(Integer)

    raw.to_i if raw.is_a?(String) && raw.match?(/\A\d{1,3}\z/)
  end

  class Base
    def initialize(poll)
      @poll = poll
    end

    def multiple_allowed? = false

    def results_showable_while_open? = true

    def answer_labels = nil

    def public_results(results) = results

    private

    attr_reader :poll

    def options = poll.options
  end
end
