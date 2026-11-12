module Api
  # Préférences de périphériques du participant courant
  # (contrat DevicePreference).
  #
  # Lecture : livrée avec le token (POST /api/token, `devicePreferences`).
  # Pas de GET ici : il porterait le jeton intervenant dans l'URL, donc
  # dans les journaux du proxy.
  #
  # Écriture : PATCH JSON, partielle (seules les clés envoyées changent :
  # une page ouverte plus tôt n'écrase pas un choix fait entre-temps). Le
  # propriétaire est le participant que résout RoomParticipant (session
  # animateur, sinon jeton intervenant), jamais un identifiant fourni par
  # le client : chacun n'écrit que SES préférences.
  # Spectateur (sans mémoire serveur) ou participant inconnu → 403.
  # CSRF actif (X-CSRF-Token) et JSON exigé, comme /api/token.
  class DevicePreferencesController < ApplicationController
    include RoomParticipant
    include JsonOnly

    # Entrée : { slug, speaker_token | null, device_preferences: <contrat, partiel> }.
    # Sortie 200 : les préférences enregistrées, complètes, même contrat.
    def update
      @webinar = Webinar.find_by(slug: params[:slug].to_s)
      return head :not_found if @webinar.nil?

      owner = resolve_role(webinar: @webinar, speaker_token: params[:speaker_token])&.record
      return head :forbidden unless DevicePreference.ownable?(owner)

      payload = preferences_params
      saved = DevicePreference.transaction do
        # Deux onglets qui écrivent ensemble : la ligne unique est retrouvée,
        # pas créée deux fois (index unique, pas de 500). Refus = rien d'écrit.
        preference = DevicePreference.create_or_find_by!(owner: owner).merge_payload(payload)
        preference.save ? preference : raise(ActiveRecord::Rollback)
      end
      return render json: { error: "invalid_device_preferences" }, status: :unprocessable_entity unless saved

      render json: saved.to_payload
    end

    private

    # `expect` : une structure inattendue (chaîne, liste…) donne 400, jamais 500.
    def preferences_params
      params.expect(device_preferences: [
        :audioEnabled, :videoEnabled, { audioinput: [ :deviceId, :label ], videoinput: [ :deviceId, :label ] }
      ]).to_h
    end
  end
end
