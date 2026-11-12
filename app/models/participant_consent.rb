# Accord à l'image d'un participant qui n'anime pas de droit
# (contre) : intervenant
# (Speaker), co-animateur invité (User) ou spectateur à qui la parole est
# donnée (Registration) — qui le doit : PublishPermission.consent_required?.
# Recueilli dans la salle avant la première activation de la caméra ou du
# micro dans ce webinaire (app/javascript/rooms/participant_consent.jsx).
#
# Preuve FIGÉE, sur le modèle de `Registration#grant_marketing_consent!` :
# cases cochées, libellés tels que le serveur les a fait afficher (jamais
# un texte venu du client), version de la politique, identité LiveKit, date.
# La ligne ne change plus, sauf `withdrawn_at` ; un nouvel accord après un
# retrait est une nouvelle ligne : l'historique reste lisible.
#
# Ce que l'accord ouvre : la publication dans la salle (PublishPermission),
# l'enregistrement des pistes séparées de la personne
# (TrackRecordingSession.recordable?) et, s'il porte la case des extraits,
# sa présence dans les extraits et shorts (ExcerptConsents).
class ParticipantConsent < ApplicationRecord
  HOLDER_TYPES = %w[Speaker Registration User].freeze

  # Libellés affichés par la fenêtre de consentement, livrés avec le jeton
  # de la salle (Api::TokensController) et figés dans chaque preuve.
  # Changer un libellé = changer ce que les personnes acceptent : nouvelle
  # version de /confidentialite (PrivacyPolicy::VERSION). `organization` :
  # celle qui opère l'instance et publie les extraits ; `co_organizers` :
  # ceux de la série qui les publient aussi (Brand.series), s'il y en a.
  def self.labels_for(organization, co_organizers: nil)
    publishers =
      if co_organizers.present?
        "#{organization} et les co-organisateurs de la série (#{co_organizers}) sur leurs"
      else
        "#{organization} sur ses"
      end
    {
      recording: "Je suis filmé·e, enregistré·e et transcrit·e, et le replay du direct est rediffusé",
      excerpts: "J'accepte que des extraits soient publiés par #{publishers} sites et réseaux sociaux",
      adult: "J'ai 18 ans ou plus"
    }.freeze
  end

  LABELS = labels_for(Brand.organization, co_organizers: Brand.series.co_organizers)

  belongs_to :webinar, inverse_of: :participant_consents
  belongs_to :holder, polymorphic: true

  validates :holder_type, inclusion: { in: HOLDER_TYPES }
  validates :recording_accepted, :adult_declared, inclusion: { in: [ true ] }
  validates :excerpts_accepted, inclusion: { in: [ true, false ] }
  validates :policy_version, :recording_label, :excerpts_label, :adult_label, :participant_identity, :consented_at,
            presence: true
  validate :holder_concerned_by_webinar

  scope :current, -> { where(withdrawn_at: nil) }

  # `webinar` : obligatoire pour un co-animateur (User), qui peut animer
  # plusieurs webinaires ; sinon celui de l'intervenant ou de l'inscription.
  def self.current_for(holder, webinar: nil)
    current.find_by(webinar: webinar || holder.webinar, holder: holder)
  end

  # Ce que la salle sait de l'accord de `record` : `participantConsent` de
  # POST /api/token, réponse de /api/participant_consent. nil pour
  # l'animation de droit, qui n'a pas de fenêtre ; sinon { given, labels,
  # contact } (contact : l'adresse de retrait affichée par la fenêtre).
  def self.payload_for(webinar, record)
    return unless PublishPermission.consent_required?(webinar, record)

    { given: current_for(record, webinar: webinar).present?, labels: LABELS, contact: Brand.support_email }
  end

  # Accord en cours de `holder`, ou nouvel accord avec ses cases et la
  # preuve figée. Idempotent : deux onglets qui valident ensemble trouvent
  # le même accord (index unique partiel), jamais deux.
  #
  # @raise [ActiveRecord::RecordInvalid] case (a) ou (c) non cochée
  def self.grant!(holder, recording:, excerpts:, adult:, webinar: nil, now: Time.current)
    webinar ||= holder.webinar
    current_for(holder, webinar: webinar) || create!(
      webinar: webinar, holder: holder, participant_identity: PublishPermission.identity_for(holder),
      recording_accepted: recording, excerpts_accepted: excerpts, adult_declared: adult,
      policy_version: PrivacyPolicy::VERSION,
      recording_label: LABELS[:recording], excerpts_label: LABELS[:excerpts], adult_label: LABELS[:adult],
      consented_at: now
    )
  rescue ActiveRecord::RecordNotUnique
    current_for(holder, webinar: webinar)
  end

  # Une identité LiveKit de la salle de `webinar` est-elle couverte ?
  # L'animation de droit l'est par la politique ; toute autre identité, par
  # son accord en cours.
  def self.covers?(webinar, identity)
    PublishPermission.new(webinar).exempt_identity?(identity) ||
      current.exists?(webinar: webinar, participant_identity: identity.to_s)
  end

  # Retrait (RGPD art. 7.3), horodaté UNE fois : un second retrait ne
  # réécrit pas la date. @return [Boolean] cet appel a retiré l'accord
  def withdraw!(now: Time.current)
    with_lock do
      next false if withdrawn_at

      update!(withdrawn_at: now)
      true
    end
  end

  def withdrawn?
    withdrawn_at.present?
  end

  # Ce que cet accord permet pour les extraits et shorts.
  def excerpt_status
    return :withdrawn if withdrawn?

    excerpts_accepted ? :allowed : :refused
  end

  private

  def holder_concerned_by_webinar
    errors.add(:holder, :invalid) if holder && webinar && !PublishPermission.consent_required?(webinar, holder)
  end
end
