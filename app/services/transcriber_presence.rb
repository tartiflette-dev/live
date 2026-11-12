# frozen_string_literal: true

# Le transcripteur dans la salle d'un direct : « tout ce qui arrive doit être
# transcrit en direct » (cas réel : direct terminé puis repris
# dans une salle restée ouverte, vingt minutes sans transcripteur).
#
# L'agent (transcriber/agent.py) est un worker NOMMÉ : LiveKit ne l'envoie
# dans une salle que sur dispatch explicite. L'auto-dispatch d'avant ne jouait
# qu'à la création de la salle, et rien ne le rappelait après une fin.
#
# #ensure_present : tant que la fenêtre de captation est ouverte (direct en
# cours, ou composite actif avant le go_live : ce qui est enregistré est
# transcrit) et qu'une personne est dans la salle, un transcripteur y est, ou y
# vient. Appelé (TranscriberPresenceJob) à l'ouverture et à la reprise du
# direct, à chaque arrivée autorisée et chaque minute (TranscriberSweepJob) :
# un agent tombé en plein direct revient sans geste.
#
# #dismiss : fin du direct (LiveEnding). Les dispatches sont supprimés (LiveKit
# termine leurs jobs) et tout agent encore présent est retiré : rien n'est
# transcrit ni archivé après la fin.
class TranscriberPresence
  AGENT_KIND = "AGENT"
  HUMAN_KINDS = [ "", "STANDARD" ].freeze
  IN_FLIGHT_STATUSES = %w[JS_PENDING JS_RUNNING].freeze
  # Dispatch accepté dont l'agent n'est pas (encore) dans la salle : en route
  # pendant ce délai depuis son dernier signe de vie, perdu au-delà, remplacé.
  JOIN_GRACE = 2.minutes

  def self.agent_name
    ENV.fetch("TRANSCRIBER_AGENT_NAME", "transcriber")
  end

  def initialize(webinar, room_client: Rails.configuration.x.room_service_client_factory.call,
                 agent_name: self.class.agent_name)
    @webinar = webinar
    @room_client = room_client
    @agent_name = agent_name
  end

  # @return [Symbol] :closed, :empty_room, :present, :pending ou :dispatched
  # @raise [RoomServiceClient::Error] LiveKit injoignable : le prochain appel retente
  def ensure_present
    return :closed unless capture_open?

    participants = @room_client.list_participants(room: room)
    return :present if participants.any? { |participant| agent?(participant) }
    return :empty_room unless participants.any? { |participant| human?(participant) }

    dispatches = own_dispatches
    return :pending if dispatches.any? { |dispatch| in_flight?(dispatch) }

    dispatches.each { |dispatch| delete(dispatch) }
    @room_client.create_agent_dispatch(room: room, agent_name: @agent_name)
    # Fin du direct pendant ce dispatch : LiveEnding a pu passer avant lui.
    dismiss unless capture_open?(@webinar.reload)
    :dispatched
  end

  # Meilleur effort, chaque étape tentée : le direct est déjà terminé côté app.
  def dismiss
    dispatches = best_effort(:dispatches) { own_dispatches } || []
    dispatches.each { |dispatch| best_effort(:dispatches) { delete(dispatch) } }
    best_effort(:participants) do
      @room_client.list_participants(room: room).each do |participant|
        @room_client.remove_participant(room: room, identity: participant[:identity]) if agent?(participant)
      end
    end
  end

  private

  def room
    @webinar.room_name
  end

  def capture_open?(webinar = @webinar)
    Webhooks::TranscriptsController.enabled? && !webinar.ended? &&
      TrackRecordingSession.recording_window_open?(webinar)
  end

  def agent?(participant)
    participant[:kind].to_s == AGENT_KIND
  end

  def human?(participant)
    HUMAN_KINDS.include?(participant[:kind].to_s)
  end

  def own_dispatches
    @room_client.list_agent_dispatches(room: room).select { |dispatch| dispatch[:agent_name] == @agent_name }
  end

  def in_flight?(dispatch)
    state = dispatch[:state] || {}
    jobs = state[:jobs] || []
    live_jobs = jobs.select { |job| IN_FLIGHT_STATUSES.include?(job.dig(:state, :status).to_s) }
    return false if jobs.any? && live_jobs.empty?

    Time.current - last_sign_of_life(state[:created_at], live_jobs) < JOIN_GRACE
  end

  # Horodatages LiveKit en nanosecondes (chaînes dans le JSON protobuf).
  def last_sign_of_life(created_at, jobs)
    nanos = jobs.flat_map { |job| job[:state].values_at(:started_at, :updated_at) } << created_at
    Time.at(0, nanos.map(&:to_i).max, :nanosecond)
  end

  def delete(dispatch)
    @room_client.delete_agent_dispatch(room: room, dispatch_id: dispatch[:id])
  rescue RoomServiceClient::RemoteError => e
    raise unless e.code == "not_found"
  end

  def best_effort(step)
    yield
  rescue RoomServiceClient::Error => e
    Rails.logger.warn("[transcriber_presence] dismiss #{step} room=#{room} err=#{e.message}")
    nil
  end
end
