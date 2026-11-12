# Salle LiveKit SIMULÉE pour les tests système (la CI n'a pas de LiveKit,
# livekit.invalid) : la diffusion serveur (RoomServiceClient#send_data) est
# captée par un enregistreur, puis REMISE à la Room LiveKit de la page comme
# le ferait livekit-server — événement `dataReceived` sans participant
# émetteur. Le code de production n'expose rien pour le test. Partagé par la
# discussion (room_chat_test), la file Q&R (qa_room_test), la modération
# depuis la régie (regie_moderation_test), qui y place des présents,
# l'accord à l'image (participant_consent_test) et la prise de parole des
# participants (lien_participants_test).
module LivekitPacketDelivery
  # Ce que livekit-server ferait des paquets du serveur. `create_room` en
  # échec : l'enregistrement auto-démarré à l'ouverture de la scène échoue
  # tout de suite, sans attendre un egress injoignable.
  class RoomRecorder
    attr_accessor :offline

    def initialize
      @packets = []
      @participants = []
      @muted = []
      @removed = []
      @permissions = []
      @lock = Mutex.new
    end

    def create_room(**) = raise(RoomServiceClient::RemoteError, "livekit hors ligne (test)")

    def send_data(room:, data:, kind:, destination_identities: [])
      raise RoomServiceClient::RemoteError, "livekit hors ligne (test)" if offline

      @lock.synchronize { @packets << data }
      {}
    end

    def packets
      @lock.synchronize { @packets.dup }
    end

    # Lectures de la régie (RoomSnapshot) : salle ouverte, vide par défaut.
    def room_metadata(room:) = ""

    # Présents, sous la forme que rend RoomServiceClient#list_participants.
    # Copie profonde : le serveur Capybara (autre thread) lit et modifie la
    # salle simulée, le test n'en garde que ce qu'il observe.
    def participants=(list)
      @lock.synchronize { @participants = JSON.parse(JSON.generate(list), symbolize_names: true) }
    end

    def list_participants(room:)
      @lock.synchronize { JSON.parse(JSON.generate(@participants), symbolize_names: true) }
    end

    # Modération (ParticipantModeration) : la piste coupée le reste, la
    # personne retirée quitte la salle, comme le ferait livekit-server.
    def mute_track(room:, identity:, track_sid:)
      @lock.synchronize do
        @muted << [ identity, track_sid ]
        participant = @participants.find { |entry| entry[:identity] == identity }
        Array(participant&.fetch(:tracks, nil)).each { |track| track[:muted] = true if track[:sid] == track_sid }
      end
      {}
    end

    def remove_participant(room:, identity:)
      @lock.synchronize do
        @removed << identity
        @participants.reject! { |entry| entry[:identity] == identity }
      end
      {}
    end

    # Droit de publier accordé ou retiré (prise de parole, retrait de
    # l'accord à l'image) : la permission du présent suit, comme le ferait
    # livekit-server.
    def update_participant(room:, identity:, can_publish:, sources: [])
      @lock.synchronize do
        @permissions << [ identity, can_publish ]
        participant = @participants.find { |entry| entry[:identity] == identity }
        participant[:permission] = { can_publish: can_publish } if participant
      end
      {}
    end

    def muted = @lock.synchronize { @muted.dup }
    def permissions = @lock.synchronize { @permissions.dup }
    def removed = @lock.synchronize { @removed.dup }
  end

  # Remet un paquet à la Room de la page (contexte React au-dessus de la
  # salle). `identity` simule un paquet émis par un PARTICIPANT.
  DELIVER_JS = <<~JS.freeze
    const [data, identity] = arguments;
    const anchor = document.querySelector('[data-testid="stage"], .lk-viewer');
    const fiberKey = anchor && Object.keys(anchor).find((k) => k.startsWith('__reactFiber$'));
    let room = null;
    for (let fiber = fiberKey && anchor[fiberKey]; fiber && !room; fiber = fiber.return) {
      const value = fiber.memoizedProps && fiber.memoizedProps.value;
      if (value && value.remoteParticipants instanceof Map && value.localParticipant) room = value;
    }
    if (!room) return false;
    room.emit('dataReceived', new TextEncoder().encode(data), identity ? { identity } : undefined);
    return true;
  JS

  # Remet `data` (chaîne JSON) à la Room de la page ouverte.
  def deliver_packet(data, identity = nil)
    evaluate_script("(function() { #{DELIVER_JS} })(#{data.to_json}, #{identity.to_json})")
  end
end
