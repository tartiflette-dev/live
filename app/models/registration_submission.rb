# Une soumission de l'API cross-origin `POST /api/registrations`
# (docs/registrations-api.md) : validation stricte de
# l'entrée, puis création de la demande et des inscriptions NOUVELLES.
#
# Sécurité (invariants repris de RegistrationsController#create) :
# - une soumission anonyme ne modifie JAMAIS une inscription existante :
#   ni son nom, ni sa demande de rattachement, ni son consentement
#   marketing (la case ne vaut que pour les inscriptions NOUVELLES de la
#   demande, au clic de confirmation) ;
# - mêmes effets visibles qu'il y ait déjà inscription ou non (pas
#   d'oracle d'existence d'un email) : l'inscription en attente reçoit à
#   nouveau son propre lien (reprise après perte du mail), une inscription
#   confirmée ne reçoit rien ; tout mail à une adresse non prouvée passe
#   par la limite par destinataire (PendingRegistrationMail) ;
# - champ piège `website` : rempli = robot, réponse identique, aucun effet.
class RegistrationSubmission
  include ActiveModel::Model
  include ActiveModel::Attributes

  MAX_WEBINARS = 3

  attribute :name, :string
  attribute :email, :string
  attribute :slugs
  attribute :notify_next, :boolean, default: false
  attribute :profile, :string
  attribute :message, :string
  # Case « Ok pour que l'organisation me recontacte » (politique v1.6), facultative.
  # Sans cast : seul un booléen JSON est accepté (ActiveModel castait
  # "no", "oui", 1… en true), et seul `true` vaut accord.
  attribute :marketing_consent
  attribute :source, :string
  attribute :website, :string
  # Choix spectateur / participant, facultatif et additif :
  # absent ou `null` = spectateur (défaut de Registration). Sans cast, comme
  # `marketing_consent` : seule une des deux chaînes est acceptée.
  attribute :participation

  validate :marketing_consent_shape
  validates :participation, inclusion: { in: Registration.participations.keys }, allow_nil: true
  validate :slugs_shape
  validate :request_attributes
  validate :something_to_register

  # Webinaires retenus : publiés, ni terminés ni présumés annulés
  # (`Webinar#past?`, même règle que le catalogue), dans l'ordre soumis.
  # Un slug inconnu, en brouillon ou passé est ignoré.
  def webinars
    @webinars ||= begin
      found = Webinar.published.where(slug: slug_list).index_by(&:slug)
      slug_list.filter_map { |slug| found[slug] }.reject(&:past?)
    end
  end

  def save
    return false unless valid?
    return true if website.present?

    request, pending_existing = persist
    PendingRegistrationMail.request_confirmation(request) if request
    pending_existing.each { |registration| PendingRegistrationMail.confirmation(registration) }
    true
  end

  private

  def registration_request
    @registration_request ||= RegistrationRequest.new(
      name: name.to_s.strip, email: email, source: source.presence, profile: profile.presence,
      message: message.to_s.strip.presence, notify_next: notify_next,
      marketing_box_checked: marketing_consent == true
    )
  end

  def slug_list
    slugs.is_a?(Array) ? slugs.map(&:to_s).uniq : []
  end

  # La demande n'est enregistrée que si elle porte quelque chose : une
  # inscription NOUVELLE (belongs_to l'enregistre avec elle) ou le
  # « préviens-moi ». Les inscriptions retrouvées n'y sont jamais
  # rattachées.
  def persist
    pending_existing = []
    ActiveRecord::Base.transaction do
      webinars.each do |webinar|
        registration, created = Registration.find_or_create_for(
          webinar, email: registration_request.email, name: registration_request.name,
          registration_request: registration_request, participation: participation
        )
        pending_existing << registration unless created || registration.confirmed?
      end
      registration_request.save! if registration_request.new_record? && notify_next
    end
    [ (registration_request if registration_request.persisted?), pending_existing ]
  end

  def marketing_consent_shape
    errors.add(:marketing_consent, :invalid) unless [ nil, true, false ].include?(marketing_consent)
  end

  def slugs_shape
    return if slugs.nil?
    return errors.add(:slugs, :invalid) unless slugs.is_a?(Array) && slugs.all?(String)

    errors.add(:slugs, :too_many) if slug_list.size > MAX_WEBINARS
  end

  def request_attributes
    registration_request.validate
    registration_request.errors.each do |error|
      errors.add(error.attribute, error.type) unless error.attribute == :token
    end
  end

  def something_to_register
    return if errors.any? || notify_next || webinars.any?

    errors.add(:slugs, :no_open_webinar)
  end
end
