# Envoi des mails adressés à une adresse que personne n'a encore prouvée
# (confirmation d'inscription, demande de l'API, lien intervenant) : chacun
# passe par RecipientMailThrottle, quel que soit le chemin qui le demande
# (formulaire, API, lien participants privé, rattachement d'intervenant).
#
# Un mail refusé par la limite n'est PAS une erreur pour l'appelant : la
# réponse faite à la personne reste identique, qu'un mail parte ou non (pas
# d'oracle sur l'existence d'une inscription, ni sur la limite). L'inscription
# en attente et son lien restent valables ; seul l'accès immédiat, qui exige
# son mail, est refusé quand le budget `:security` l'est (reserve_confirmation).
#
# Les mails adressés à une boîte PROUVÉE (accès, rappel, consentement,
# retrait) ne passent PAS ici : la limite ne consomme jamais leur budget et ne
# peut jamais les faire taire.
module PendingRegistrationMail
  module_function

  # Le mail de confirmation réservé, et si l'accès immédiat a été autorisé
  # avec lui. `deliver` enqueue le mail (sans effet si la limite l'a refusé).
  Reservation = Data.define(:sender, :instant_access) do
    def deliver
      sender&.call
      sender.present?
    end
  end

  # @param first [Boolean] première confirmation d'une inscription NEUVE
  #   (hors total par adresse, une fois par boîte canonique et webinaire,
  #   RecipientMailThrottle) ; un renvoi : false
  # @return [Boolean] le mail est parti en file
  def confirmation(registration, first: false, throttle: RecipientMailThrottle.default)
    reserve_confirmation(registration, instant_access_wanted: false, first: first, throttle: throttle).deliver
  end

  # Réserve le mail de confirmation SANS l'enqueuer, pour un appelant dont un
  # effet dépend du mail : l'accès immédiat (le mail prévient la boîte qu'on
  # est entré avec son adresse). Avec `instant_access_wanted`, la réservation
  # tente d'abord le budget `:security` (par flux, sans total par adresse :
  # ni les mails ordinaires ni ceux d'autres flux ne peuvent le vider) :
  # réussie, `instant_access` vaut true. Refusée, pas d'accès immédiat : le
  # mail ordinaire est tenté sur le budget `:unproven`,
  # l'inscription reste en attente. Jamais d'accès sans mail.
  # L'appelant enqueue (`deliver`) APRÈS l'effet, car le gabarit relit l'état
  # de l'inscription. (Un lambda plutôt qu'un `MessageDelivery` : tout appel de
  # méthode sur celui-ci, même `present?`, construit le message et interdit
  # ensuite `deliver_later`.)
  # @return [Reservation]
  def reserve_confirmation(registration, instant_access_wanted:, first: false, throttle: RecipientMailThrottle.default)
    return Reservation.new(sender: nil, instant_access: false) if registration.confirmed?

    scope = confirmation_scope(registration)
    if instant_access_wanted && throttle.claim(registration.email, scope, budget: :security)
      return Reservation.new(sender: confirmation_sender(registration), instant_access: true)
    end

    first_of = first ? [ webinar_key(registration) ] : []
    sender = confirmation_sender(registration) if throttle.claim(registration.email, scope, first_of: first_of)
    Reservation.new(sender: sender, instant_access: false)
  end

  # Un seul mail couvre les inscriptions créées par la demande et le
  # « préviens-moi ». Avec des inscriptions NEUVES, c'est leur première
  # confirmation : le claim porte le flux de chacune, hors total par adresse ;
  # le « préviens-moi » qui l'accompagne n'ajoute pas son propre flux (celui
  # d'un tiers ne doit pas bloquer cette première confirmation). Sans
  # inscription neuve, le « préviens-moi » seul est un renvoi : son flux et le
  # total le bornent.
  def request_confirmation(registration_request, throttle: RecipientMailThrottle.default)
    registrations = registration_request.published_registrations.to_a
    scopes = registrations.map { |registration| confirmation_scope(registration) }
    scopes << "request-notify" if scopes.empty? && registration_request.notify_next?
    first_of = registrations.map { |registration| webinar_key(registration) }
    return false unless throttle.claim(registration_request.email, *scopes, first_of: first_of)

    RegistrationMailer.request_confirmation(registration_request).deliver_later
    true
  end

  # Mail de preuve demandé pour la propre boîte de la personne : budget
  # `:proof` propre, hors du total des confirmations.
  def speaker_link(speaker, registration, throttle: RecipientMailThrottle.default)
    return false unless throttle.claim(registration.email, "speaker-link:#{speaker.webinar_id}", budget: :proof)

    RegistrationMailer.speaker_link(speaker, registration).deliver_later
    true
  end

  def webinar_key(registration)
    "webinar:#{registration.webinar_id}"
  end

  def confirmation_sender(registration)
    -> { RegistrationMailer.confirmation(registration).deliver_later }
  end

  # Flux = la LIGNE d'inscription, pas le webinaire : la pierre tombale d'un
  # intrus retiré libère l'adresse, et la vraie personne qui s'y inscrit juste
  # après a une ligne neuve, donc son propre mail (et son accès immédiat). Les
  # renvois répétés vers une même ligne restent limités ; en créer une autre
  # exige un retrait par l'animation.
  def confirmation_scope(registration)
    "confirmation:#{registration.id}"
  end
end
