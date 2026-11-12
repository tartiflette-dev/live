# Recette des tests salle sans serveur LiveKit (la CI vise livekit.invalid :
# la connexion échoue, la salle est rendue quand même). La Room LiveKit de
# la page est retrouvée par le contexte React — valeur du RoomContext
# au-dessus de la scène ou de la vue spectateur — puis manipulée avec les
# vraies classes de livekit-client. Le code de production n'expose rien
# pour le test.
module LivekitRoomRecipe
  # Pose `room` (null si la vue salle n'est pas encore montée).
  FIND_ROOM_JS = <<~JS.freeze
    const anchor = document.querySelector('[data-testid="stage"], .lk-viewer');
    const fiberKey = anchor && Object.keys(anchor).find((k) => k.startsWith('__reactFiber$'));
    let room = null;
    for (let fiber = fiberKey && anchor[fiberKey]; fiber && !room; fiber = fiber.return) {
      const value = fiber.memoizedProps && fiber.memoizedProps.value;
      if (value && value.remoteParticipants instanceof Map && value.localParticipant) room = value;
    }
  JS

  # Publication accordée au participant local, une fois la connexion (vers
  # livekit.invalid) échouée : comme le ferait livekit-server. Rend 'ok', ou
  # null tant que la salle n'est pas montée ou que la connexion est en cours.
  GRANT_LOCAL_PUBLISH_JS = <<~JS.freeze
    (() => {
      #{FIND_ROOM_JS}
      if (!room || room.state !== 'disconnected') return null;
      room.localParticipant.permissions = { canPublish: true, canSubscribe: true, canPublishData: true,
                                            canPublishSources: [], hidden: false, agent: false };
      room.localParticipant.emit('participantPermissionsChanged', undefined);
      return 'ok';
    })()
  JS
end
