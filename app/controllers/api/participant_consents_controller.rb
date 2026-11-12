module Api
  # Accord à l'image du participant courant (contrat ParticipantConsent) :
  # donné dans la salle avant la première
  # activation de la caméra ou du micro, retiré par « Retirer mon accord ».
  #
  # Le porteur est le participant que résout RoomParticipant (session d'un
  # co-animateur invité, jeton intervenant, sinon cookie d'inscription
  # confirmée), jamais un identifiant fourni par le client : chacun ne donne
  # ou ne retire que SON accord. Animateur de droit (pas de fenêtre) ou
  # participant inconnu → 403. Spectateur : il donne son accord seulement
  # quand il a la parole (main accordée) ; il peut toujours le retirer.
  #
  # L'accord ouvre la publication dans la salle (PublishPermission, sous le
  # verrou de HandRaiseControl, qui relit parole et accord juste avant
  # l'appel LiveKit) : le jeton de qui n'a pas d'accord ne publie pas. Le
  # retrait la referme (ConsentWithdrawal).
  # CSRF actif (X-CSRF-Token, refus en JSON 422) et JSON exigé, comme /api/token.
  class ParticipantConsentsController < ApplicationController
    include RoomParticipant
    include JsonOnly
    include JsonCsrfRefusal

    before_action :set_holder

    # Entrée : { slug, speaker_token | null, recording, excerpts, adult }, cases
    # en booléens JSON (une chaîne ne vaut pas une case cochée).
    # 201 : { given: true, labels } ; 422 si la case (a) ou (c) manque ;
    # 502 si la salle n'a pas ouvert la publication (accord gardé : un nouvel
    # envoi la redemande).
    def create
      return head :forbidden unless PublishPermission.new(@webinar).floor?(@holder)
      return render json: { error: "consent_incomplete" }, status: :unprocessable_entity unless checked?(:recording) && checked?(:adult)

      ParticipantConsent.grant!(@holder, webinar: @webinar, recording: true, excerpts: checked?(:excerpts), adult: true)
      HandRaiseControl.new(@webinar).open_publication(@holder)
      render json: ParticipantConsent.payload_for(@webinar, @holder), status: :created
    rescue RoomServiceClient::Error => error
      Rails.logger.warn("[participant_consents] publication non ouverte webinar=#{@webinar.id} err=#{error.class}")
      render json: { error: "permission_update_failed" }, status: :bad_gateway
    end

    # Entrée : { slug, speaker_token | null }. 200 : { given: false, labels }.
    def destroy
      ConsentWithdrawal.new(@webinar, @holder).call
      render json: ParticipantConsent.payload_for(@webinar, @holder)
    end

    private

    def set_holder
      @webinar = Webinar.find_by(slug: params[:slug].to_s)
      return head :not_found if @webinar.nil?

      @holder = resolve_role(webinar: @webinar, speaker_token: params[:speaker_token])&.record
      head :forbidden unless PublishPermission.consent_required?(@webinar, @holder)
    end

    def checked?(key)
      params[key] == true
    end
  end
end
