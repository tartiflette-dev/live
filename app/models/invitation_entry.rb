# Une entrée par le lien participants privé `/i?t=` (successeur du lien
# d'invitation intervenant partagé) : nom, adresse email
# OBLIGATOIRE et choix spectateur / participant.
#
# - participant : un intervenant (Speaker) qui entre sur scène tout de suite,
#   comme avant, et publie dès son accord à l'image (PublishPermission), et
#   l'inscription de son adresse (créée ou retrouvée). Le Speaker
#   n'est RATTACHÉ à cette inscription que si la boîte mail est PROUVÉE :
#     • tout de suite, si l'inscription est CONFIRMÉE et que le navigateur
#       porte son cookie (id et secret) : le lien de son mail a été cliqué,
#       et une identité provisoire n'est jamais confirmée depuis un autre
#       navigateur que le sien (Registration#hand_over!) ;
#     • sinon, adresse neuve comprise, l'adresse reste DÉCLARÉE sur
#       l'intervenant (`declared_email`) et la personne reçoit un mail qui
#       nomme l'intervention (RegistrationMailer#speaker_link) ; le
#       rattachement attend le POST de son bouton. Confirmer son inscription
#       ne rattache RIEN : une victime dont un tiers a saisi l'adresse neuve
#       confirmerait sinon une fiche qui porte ses interventions.
#   Sans quoi n'importe qui saisirait l'adresse d'autrui pour lui faire
#   attribuer ses interventions, ou la faire retirer avec lui ;
# - spectateur : l'inscription seule. Créée pendant le direct (ou le quart
#   d'heure qui le précède), elle ouvre la salle tout de suite sur cet
#   appareil ; sinon, le lien du mail de confirmation y mène.
#
# Une inscription non confirmée reçoit le mail de confirmation : l'entrée au
# CRM attend ce clic (double opt-in, Registration#confirm!).
#
# Invariants, repris du formulaire public et du lien partagé :
# - une inscription retrouvée n'est jamais modifiée (nom, choix) et ne donne
#   jamais la salle à qui saisit son adresse ; aucune inscription n'est
#   rattachée à un intervenant sans preuve de la boîte ;
# - une personne retirée de la salle par l'animation (`room_removed_at`)
#   reste dehors, quel que soit le lien ;
# - plafond d'intervenants ATOMIQUE : comptage et création sous le verrou de
#   la ligne du webinaire.
class InvitationEntry
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :name, :string
  attribute :email, :string
  attribute :participation, :string, default: "participant"

  validates :name, presence: true, length: { maximum: 120 }
  validates :email, presence: true, length: { maximum: 254 }, format: { with: URI::MailTo::EMAIL_REGEXP }
  # Domaine réservé aux pierres tombales (Registration::RESERVED_EMAIL).
  validate { errors.add(:email, :invalid) if Registration.reserved_email?(email) }
  validates :participation, inclusion: { in: Registration.participations.keys }

  # registration : l'inscription de l'adresse saisie (créée ou retrouvée),
  # JAMAIS une preuve d'identité ; le rattachement prouvé se lit sur
  # `speaker.registration`.
  attr_reader :registration, :speaker

  # @param browser_registration [Registration, nil] inscription que porte le
  #   cookie du navigateur, secret vérifié (RoomRemoval#registration_in_browser) :
  #   preuve de la boîte quand elle est confirmée (`mailbox_proven_by_browser?`).
  def initialize(webinar:, browser_registration: nil, **attributes)
    @webinar = webinar
    @browser_registration = browser_registration
    super(attributes)
  end

  def name=(value)
    super(value.to_s.strip.presence)
  end

  def email=(value)
    super(value.to_s.strip.downcase.presence)
  end

  # @return [Symbol] :speaker (intervenant créé), :admitted (spectateur, salle
  #   ouverte sur cet appareil), :pending (spectateur, salle ouverte par le
  #   mail), ou, sans rien créer : :removed, :full, :invalid.
  def save
    return :invalid unless valid?

    outcome = @webinar.with_lock { participation == "participant" ? enter_as_speaker : enter_as_spectator }
    return outcome unless %i[speaker admitted pending].include?(outcome)

    @confirmation_reservation&.deliver
    PendingRegistrationMail.speaker_link(speaker, registration) if speaker&.link_token
    outcome
  end

  private

  def enter_as_speaker
    return :full if @webinar.speaker_capacity_reached?

    resolve_registration
    return :removed if registration.room_removed_at

    @speaker =
      if mailbox_proven_by_browser?
        @webinar.speakers.create!(name: name, registration: registration)
      else
        @webinar.speakers.create!(name: name, declared_email: email)
      end
    reserve_confirmation(instant_access_wanted: false)
    :speaker
  end

  def mailbox_proven_by_browser?
    registration == @browser_registration && registration.confirmed?
  end

  def enter_as_spectator
    created = resolve_registration
    return :removed if registration.room_removed_at

    # Pas de mail possible (budget `:security` de RecipientMailThrottle
    # épuisé) = pas d'accès immédiat : ce mail prévient la boîte de l'entrée
    # sous son adresse.
    reservation = reserve_confirmation(instant_access_wanted: created && @webinar.instant_access_open?)
    created && reservation.instant_access && registration.grant_instant_access! ? :admitted : :pending
  end

  # Réserve le mail de confirmation (la réservation consomme la limite par
  # destinataire ; `first` : l'inscription vient d'être créée). Enqueué par
  # `save`, après l'effet qui en dépend.
  def reserve_confirmation(instant_access_wanted:)
    @confirmation_reservation = PendingRegistrationMail.reserve_confirmation(
      registration, instant_access_wanted: instant_access_wanted, first: @registration_created
    )
  end

  # @return [Boolean] l'inscription vient d'être créée
  def resolve_registration
    @registration, @registration_created = Registration.find_or_create_for(@webinar, email: email, name: name, participation: participation)
    @registration_created
  end
end
