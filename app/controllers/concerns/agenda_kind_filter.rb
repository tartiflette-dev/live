# Filtre `?kind=` des lectures de l'agenda (/agenda/next.json, flux
# personnel /agenda/<jeton>.ics) : un de Webinar::KINDS, vide = sans filtre.
# Une valeur inconnue est une erreur (400) plutôt qu'un agenda complet : un
# abonné ne verrait jamais l'avertissement d'un flux mal orthographié.
module AgendaKindFilter
  extend ActiveSupport::Concern

  private

  def requested_kind
    params[:kind].presence
  end

  def kind_invalid?
    requested_kind.present? && !Webinar::KINDS.include?(requested_kind)
  end

  def invalid_kind_message
    "kind must be one of: #{Webinar::KINDS.join(", ")}"
  end

  def of_requested_kind(webinars)
    requested_kind ? webinars.where(kind: requested_kind) : webinars
  end
end
