# Édition d'un webinaire par son propriétaire (WebinarEditionsController) :
# date, titre, description, et dépublication, qui vaut annulation ; et du
# programme par toute l'animation (WebinarProgramsController). Chaque
# geste est UNE écriture, sous le verrou de la ligne (un lancement du direct
# concurrent gagne), validée dans le contexte `:edition` : ces règles ne
# pèsent que sur ce geste, jamais sur les transitions du direct ni sur la
# console.
#
# Rien n'est envoyé ici : prévenir les inscrits d'une nouvelle date ou d'une
# annulation suit le commit, ailleurs (WebinarChangeNotice).
module Webinar::Edition
  extend ActiveSupport::Concern

  NOT_EDITABLE_MESSAGE = "Ce webinaire a commencé ou est passé : il ne se modifie plus.".freeze

  included do
    validate :still_editable,   on: :edition
    validate :starts_after_lead, on: :edition
  end

  # Modifiable tant que le direct n'a pas commencé : jamais lancé, début prévu
  # encore à venir — annuler à la dernière minute reste possible, c'est là que
  # prévenir compte le plus. Lu sur l'état EN BASE : une date saisie dans le
  # formulaire ne rouvre pas un webinaire passé.
  def editable?(now = Time.current)
    state_in_database == "draft" && starts_at_in_database.present? && starts_at_in_database > now
  end

  # @param attributes [Hash] titre, date, description ou programme déjà filtrés
  # @return [Boolean] false si refusé (erreurs sur le webinaire)
  def revise(attributes)
    with_lock do
      assign_attributes(attributes)
      save(context: :edition)
    end
  end

  # Retire le webinaire du catalogue, de l'agenda et des flux.
  # @return [Boolean] false si refusé (erreurs sur le webinaire)
  def unpublish
    with_lock do
      unless visibility_published?
        errors.add(:visibility, :not_published, message: "n'est pas « publié » : rien à annuler")
        next false
      end

      self.visibility = "draft"
      save(context: :edition)
    end
  end

  # Inscriptions qu'une nouvelle date ou une annulation préviendra
  # (confirmées, jamais retirées de la salle) : WebinarChangeNotice les prend
  # ici, l'écran d'édition les compte ici, le nombre annoncé est le nombre servi.
  def registrations_to_notify
    registrations.confirmed.where(room_removed_at: nil, retired_email_digest: nil)
  end

  private

  def still_editable
    return if editable?

    errors.add(:base, :started, message: NOT_EDITABLE_MESSAGE)
  end

  # Une nouvelle date laisse aux inscrits le temps d'être prévenus : au moins
  # l'avance de l'accès immédiat (INSTANT_ACCESS_LEAD). Une date inchangée à
  # la seconde près (le formulaire ne renvoie pas les microsecondes) n'est pas
  # une nouvelle date : corriger le titre d'un café imminent reste possible.
  def starts_after_lead
    return if starts_at.nil? || starts_at.to_i == starts_at_in_database&.to_i
    return if starts_at >= Time.current + Webinar::INSTANT_ACCESS_LEAD

    minutes = (Webinar::INSTANT_ACCESS_LEAD / 1.minute).to_i
    errors.add(:starts_at, :too_soon, message: "doit être au moins #{minutes} minutes après maintenant")
  end
end
