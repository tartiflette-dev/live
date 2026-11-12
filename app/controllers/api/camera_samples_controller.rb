module Api
  # Mesures de l'émetteur caméra (contrat CameraSample), postées toutes les
  # 10 s par le navigateur de qui publie (rooms/camera_health.jsx).
  #
  # Entrée : { slug, speaker_token | null, sample: { publication_sid, event,
  # top_width, top_height, frames_per_second, quality_limitation_reason,
  # encoder_implementation, capture_width, capture_height, paused_layers,
  # layers: [{ rid, active, width, height, fps, reason }] } }.
  # Sortie : 204 ; 403 hors direct ou participant qui ne publie pas ; 413
  # corps au-delà de MAX_BODY_BYTES ; 429 mesure trop rapprochée
  # (CameraSample::MIN_INTERVAL) ; 400 structure inattendue ; 422 mesure hors
  # bornes.
  #
  # Écriture bornée : seulement pendant le direct, seulement par qui a le
  # droit de publier (PublishPermission : animation de droit, intervenant
  # ou co-animateur avec accord, spectateur à qui la parole est donnée),
  # identité résolue par RoomParticipant, jamais fournie par le client.
  # CSRF actif et JSON exigé, comme /api/token.
  class CameraSamplesController < ApplicationController
    include RoomParticipant
    include JsonOnly

    # Une mesure réelle pèse moins de 1 Ko (quatre couches au plus).
    MAX_BODY_BYTES = 8.kilobytes

    # Avant tout autre filtre, pour qu'un corps trop gros reçoive 413 et non
    # l'erreur d'analyse que lèverait la langue (ApplicationController lit
    # `params`). La borne protège l'écriture, pas l'analyse : Rails a déjà lu
    # le corps (journal des paramètres) avant la chaîne des filtres.
    prepend_before_action :refuse_large_body

    def create
      @webinar = Webinar.find_by(slug: params[:slug].to_s)
      return head :not_found if @webinar.nil?

      identity = publishing_identity
      return head :forbidden if identity.nil? || !@webinar.live?
      return head :too_many_requests if CameraSample.too_soon?(@webinar, identity)

      sample = @webinar.camera_samples.new(sample_params.merge(participant_identity: identity))
      return head :unprocessable_entity unless sample.save

      head :no_content
    end

    private

    def refuse_large_body
      size = request.content_length || request.raw_post.bytesize
      head :content_too_large if size > MAX_BODY_BYTES
    end

    # Identité LiveKit du participant reconnu, s'il a le droit de publier.
    def publishing_identity
      record = resolve_role(webinar: @webinar, speaker_token: params[:speaker_token])&.record
      return unless record && PublishPermission.new(@webinar).token_grant(record)[:can_publish]

      PublishPermission.identity_for(record)
    end

    # `expect` : une structure inattendue donne 400, jamais 500.
    def sample_params
      params.expect(sample: [
        :publication_sid, :event, :top_width, :top_height, :frames_per_second, :quality_limitation_reason,
        :encoder_implementation, :capture_width, :capture_height, :paused_layers,
        { layers: [ CameraSample::LAYER_KEYS.map(&:to_sym) ] }
      ]).to_h
    end
  end
end
