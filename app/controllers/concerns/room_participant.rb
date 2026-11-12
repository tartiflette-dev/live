# Qui est ce participant dans la salle du webinaire ? Décision SERVEUR
# seule, partagée par l'émission du token LiveKit (Api::TokensController)
# et les préférences de périphériques (Api::DevicePreferencesController) :
# les deux doivent reconnaître le MÊME participant, et aucun paramètre
# client (`role`, `host_sub`, `identity`…) ne peut le changer.
#
# Ordre strict :
#   1. animateur AUTHENTIFIÉ (session) + rôle sur le webinaire       → :host | :cohost
#   2. navigateur retiré de ce webinaire (RoomRemoval)               → nil
#   3. speaker_token valide (Speaker nominatif actif seulement)      → :speaker
#   4. inscription confirmée au webinaire publié                     → :viewer
#   5. sinon                                                         → nil
#
# `resolve_role` pose `@webinar` : CurrentRegistration lit l'inscription
# dans le périmètre de ce webinaire.
module RoomParticipant
  extend ActiveSupport::Concern
  include CurrentRegistration

  # `record` = l'enregistrement qui porte le participant : User (host,
  # cohost), Speaker (speaker) ou Registration (viewer).
  Resolution = Struct.new(:role, :subject, :name, :record, keyword_init: true)

  private

  # Anti-escalade de privilège :
  #   • owner / project_host → :host (roomAdmin, pilote la salle)
  #   • guest_host           → :cohost (publie SANS roomAdmin ; les
  #                            contrôles applicatifs vont par les
  #                            endpoints Rails qui vérifient `role_for`
  #                            à chaque appel)
  # Identité LiveKit `host-<son oidc_sub>` dans TOUS les cas — DISTINCTE
  # du propriétaire, pour que pistes et transcript soient attribués au
  # bon animateur (`TrackRecordingSession.authorized?` reste cohérent :
  # il accepte toute identité `host-<sub>` dont le user anime).
  def resolve_role(webinar:, speaker_token:)
    @webinar = webinar
    if current_user
      animator_role = webinar.role_for(current_user)
      livekit_role = case animator_role
      when :owner, :project_host then :host
      when :guest_host           then :cohost
      end
      if livekit_role
        # `name` part dans le jeton LiveKit : tous les abonnés de la salle le
        # voient dès l'arrivée. Jamais l'adresse complète de l'animateur
        # (RGPD) : la partie locale seulement, comme dans la discussion.
        return Resolution.new(role: livekit_role, subject: current_user.oidc_sub, name: current_user.chat_alias, record: current_user)
      end
    end

    return if room_removed?(webinar, speaker_token: speaker_token)

    verified = Webinar.find_for_speaker(slug: webinar.slug, token: speaker_token)
    if verified
      _matched_webinar, speaker = verified
      # `speaker` est désormais TOUJOURS présent (la résolution legacy
      # `speaker-legacy-*` a été supprimée, cf. Webinar.find_for_speaker).
      return Resolution.new(role: :speaker, subject: speaker.id, name: speaker.name, record: speaker)
    end

    registration = current_registration if webinar.visibility_published?
    return unless registration

    Resolution.new(role: :viewer, subject: registration.id, name: registration.name, record: registration)
  end
end
