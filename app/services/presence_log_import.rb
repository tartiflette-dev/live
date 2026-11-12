# Rejoue au journal de présence (PresenceEvent) les webhooks que le serveur
# LiveKit a envoyés, lus dans SON journal (`docker logs livekit`, une ligne
# JSON par entrée) : arrivées, départs, connexions interrompues, fermetures
# de salle des cafés tenus avant que l'app ne les retienne.
#
# Seules les lignes « sent webhook » comptent : ce sont exactement les faits
# que l'app reçoit, avec leur identifiant (EV_…) — un webhook déjà reçu, ou
# une ligne importée deux fois, ne compte qu'une fois (index unique). Les
# lignes ne portent ni nom ni adresse ; aucune autre ligne n'est lue.
#
# Limite assumée : la garde du webhook (droit retiré → expulsion) n'est pas
# rejouée ; le journal LiveKit ne dit pas qui l'app a refusé. Les
# tentatives vues par l'app (page ouverte, accès délivré) n'y sont pas.
#
# La première arrivée d'un inscrit (`room_joined_at`, RoomAttendance) suit :
# la régie et l'export des inscrits voient ensuite les venus de ces cafés.
class PresenceLogImport
  KINDS = {
    "participant_joined" => "joined",
    "participant_left" => "left",
    "participant_connection_aborted" => "aborted",
    "room_finished" => "room_finished"
  }.freeze

  # @param lines [Enumerable<String>]
  # @param slugs [Array<String>, nil] cafés à reprendre ; tous sinon
  # @return [Hash{String => Integer}] faits ajoutés, par slug
  def self.call(lines, slugs: nil)
    new(slugs).import(lines)
  end

  def initialize(slugs)
    scope = slugs ? Webinar.where(slug: slugs) : Webinar.all
    @webinars = scope.index_by(&:room_name)
  end

  def import(lines)
    added = Hash.new(0)
    lines.each do |line|
      fact = parse(line)
      next unless fact

      webinar, kind, identity, at, event_id = fact
      next unless PresenceEvent.record_room!(webinar, kind, identity, at: at, livekit_event_id: event_id, source: "livekit_log")

      added[webinar.slug] += 1
      note_first_arrival(webinar, identity, at) if kind == "joined"
    end
    added
  end

  private

  def parse(line)
    entry = JSON.parse(line)
    return unless entry.is_a?(Hash) && entry["msg"] == "sent webhook"

    kind = KINDS[entry["event"]]
    webinar = @webinars[entry["room"]]
    identity = entry["participant"]
    return unless kind && webinar && entry["id"].present?
    return unless kind == "room_finished" || PresenceEvent.human_identity?(identity)

    at = time_of(entry)
    [ webinar, kind, kind == "room_finished" ? nil : identity, at, entry["id"] ] if at
  rescue JSON::ParserError
    nil
  end

  # `webhookTime` = heure du fait (secondes) ; `ts` = heure d'envoi, à
  # défaut. Sans heure, la ligne n'est pas reprise.
  def time_of(entry)
    seconds = Float(entry["webhookTime"].presence || entry["ts"], exception: false)
    Time.zone.at(seconds.floor) if seconds&.positive?
  end

  def note_first_arrival(webinar, identity, at)
    registration = PresenceIdentities.new(webinar, [ identity ]).person_for(identity).registration
    RoomAttendance.mark_joined(webinar, [ registration.id ], at) if registration
  end
end
