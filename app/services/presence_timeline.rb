# Page « Présence » d'un webinaire : qui s'est connecté quand, la courbe du
# nombre de présents, et qui a essayé sans entrer — lu dans le journal de
# présence (PresenceEvent), jamais dans la salle elle-même.
#
# Lecture du journal, par identité LiveKit :
#   • `joined` ouvre une présence, `left` la ferme ; `room_finished` ferme
#     toutes celles qui sont ouvertes ;
#   • `aborted` (connexion interrompue), `refused` (garde du webhook),
#     `page_opened`, `token_issued` sont des tentatives : elles ne font
#     entrer personne ;
#   • une présence encore ouverte court jusqu'à maintenant si la salle peut
#     l'être (direct pas terminé), sinon jusqu'au dernier fait connu ou à la
#     fin du direct ;
#   • arrivées et départs se comptent par identité (une reconnexion LiveKit
#     peut dater de la même seconde le départ et la nouvelle arrivée, dans un
#     ordre ou dans l'autre) ;
#     revers : un départ perdu suivi d'un retour prolonge la présence
#     jusqu'à la fermeture de la salle (ou la fin du récit) ;
#   • un départ sans arrivée relevée (webhook perdu, journal LiveKit tronqué)
#     prouve une présence dont l'arrivée est inconnue — sauf s'il suit de
#     près un refus de la garde (`REFUSAL_GRACE`, dans un ordre ou dans
#     l'autre) : c'est le départ de l'expulsé, qui n'est jamais entré ;
#   • un inscrit noté venu (`room_joined_at`) dont le journal ne montre aucune
#     présence est venu, arrivée seule connue.
#     Ces présences partielles ne comptent pas dans la courbe.
# Les identités d'une même personne (spectatrice, puis intervenante par son
# lien privé) ne font qu'une ligne et ne comptent qu'une fois dans la courbe
# (PresenceIdentities). L'animation compte parmi les présents.
class PresenceTimeline
  # `partial` : présences dont une extrémité n'est pas relevée,
  # [nil, départ] ou [arrivée, nil].
  Attendee = Struct.new(:person, :intervals, :partial, :attempts, :ongoing, keyword_init: true) do
    def came?
      intervals.any? || partial.any?
    end

    def duration
      intervals.sum { |from, to| to - from }
    end

    def first_seen
      (intervals.flatten + partial.flatten.compact + attempts.map(&:occurred_at)).min
    end
  end

  # `window` : fenêtre des graphiques ; `full_window` : tout le récit.
  Result = Struct.new(:attendees, :tried, :never_came, :expected_count, :unconfirmed_count, :curve, :window, :full_window,
                      :peak, :sources, :attempts_captured, keyword_init: true) do
    def empty?
      sources.empty?
    end

    # Le journal a-t-il relevé quelque chose (au-delà des arrivées notées sur
    # les inscriptions) ?
    def logged?
      (sources - [ "registration" ]).any?
    end

    def all_came?
      expected_count.positive? && never_came.empty?
    end

    def registrations_came_count
      attendees.count { |attendee| attendee.person.registration }
    end
  end

  FOCUS_MARGIN = 1.hour
  REFUSAL_GRACE = 10.seconds

  def initialize(webinar, now: Time.current)
    @webinar = webinar
    @now = now
  end

  # @return [Result]
  def call
    events = @webinar.presence_events.chronological.to_a
    identities = PresenceIdentities.new(@webinar, events.map(&:identity))
    registrations = @webinar.registrations.where(retired_email_digest: nil).to_a
    attendees = with_noted_arrivals(group(events, identities), registrations)
    came, tried = attendees.partition(&:came?)
    tried = tried.select { |attendee| attendee.attempts.any? }
    came_ids = came.filter_map { |attendee| attendee.person.registration&.id }.to_set
    # Attendus : inscriptions confirmées ou en accès immédiat, retirées de la
    # salle comprises (elles ont pu venir avant).
    expected, unconfirmed = registrations.partition { |registration| registration.confirmed? || registration.instant_access? }
    curve = curve_of(came)

    Result.new(
      attendees: came.sort_by { |attendee| [ attendee.first_seen, attendee.person.key ] },
      tried: tried.sort_by { |attendee| [ attendee.first_seen, attendee.person.key ] },
      never_came: expected.reject { |registration| came_ids.include?(registration.id) }
                          .sort_by { |registration| I18n.transliterate(registration.name).downcase },
      expected_count: expected.size,
      unconfirmed_count: unconfirmed.size,
      curve: curve,
      window: window_of(curve, events),
      full_window: curve.empty? ? nil : [ [ curve.first.first, @webinar.starts_at ].min, horizon(events) ],
      peak: curve.max_by(&:last),
      sources: events.map(&:source).uniq + (came.any? { |attendee| attendee.partial.any?(&:first) } ? [ "registration" ] : []),
      attempts_captured: events.any? { |event| event.kind.in?(PresenceEvent::ATTEMPT_KINDS) }
    )
  end

  private

  def group(events, identities)
    end_of_record = horizon(events)
    by_person = Hash.new { |hash, key| hash[key] = { person: nil, intervals: [], partial: [], attempts: [], ongoing: false } }
    # Par identité : [connexions ouvertes, depuis quand].
    open = Hash.new { |hash, identity| hash[identity] = [ 0, nil ] }
    refusals = events.select { |event| event.kind == "refused" }.group_by(&:identity)

    events.each do |event|
      if event.kind == "room_finished"
        open.each { |identity, (count, from)| by_person[identities.person_for(identity).key][:intervals] << [ from, event.occurred_at ] if count.positive? }
        open.clear
        next
      end

      person = identities.person_for(event.identity)
      entry = by_person[person.key]
      entry[:person] = person
      state = open[event.identity]
      case event.kind
      when "joined"
        state[1] = event.occurred_at if state[0].zero?
        state[0] += 1
      when "left"
        if state[0].zero?
          entry[:partial] << [ nil, event.occurred_at ] unless expelled?(event, refusals)
        else
          state[0] -= 1
          entry[:intervals] << [ state[1], event.occurred_at ] if state[0].zero?
        end
      else entry[:attempts] << event
      end
    end

    open.each do |identity, (count, from)|
      next unless count.positive?

      entry = by_person[identities.person_for(identity).key]
      entry[:intervals] << [ from, end_of_record ]
      entry[:ongoing] = !@webinar.ended?
    end

    by_person.values.map do |entry|
      Attendee.new(person: entry[:person], intervals: merge(entry[:intervals]), partial: entry[:partial],
                   attempts: entry[:attempts], ongoing: entry[:ongoing])
    end
  end

  def expelled?(departure, refusals)
    Array(refusals[departure.identity]).any? { |refusal| (refusal.occurred_at - departure.occurred_at).abs <= REFUSAL_GRACE }
  end

  # Inscrits notés venus (`room_joined_at` : webhook d'avant le journal,
  # lecture de la salle par la régie) que le journal ne montre pas entrer.
  def with_noted_arrivals(attendees, registrations)
    by_registration = attendees.select { |attendee| attendee.person.registration }.index_by { |attendee| attendee.person.registration.id }
    noted = registrations.select { |registration| registration.room_joined_at && !by_registration[registration.id]&.came? }
    noted.each do |registration|
      attendee = by_registration[registration.id] || Attendee.new(
        person: PresenceIdentities::Person.new(key: "registration-#{registration.id}", name: registration.name, role: :inscrit,
                                               registration: registration),
        intervals: [], partial: [], attempts: [], ongoing: false
      ).tap { |created| attendees << created }
      attendee.partial << [ registration.room_joined_at, nil ]
    end
    attendees
  end

  # Présences qui se touchent ou se chevauchent (reconnexion, deux identités
  # de la même personne) : une seule.
  def merge(intervals)
    intervals.sort.each_with_object([]) do |(from, to), merged|
      if merged.any? && from <= merged.last.last
        merged.last[1] = [ merged.last.last, to ].max
      else
        merged << [ from, to ]
      end
    end
  end

  # Marches de la courbe : [heure, présents à partir de cette heure].
  def curve_of(attendees)
    deltas = Hash.new(0)
    attendees.each do |attendee|
      attendee.intervals.each do |from, to|
        deltas[from] += 1
        deltas[to] -= 1
      end
    end
    return [] if deltas.empty?

    count = 0
    deltas.sort.map { |at, delta| [ at, count += delta ] }
  end

  # Fenêtre des graphiques (nil sans aucune présence datée) : du premier présent (ou de l'heure annoncée) à la
  # fin du récit, resserrée autour du direct — une heure avant l'heure
  # annoncée ou le lancement, une heure après la fin. Une salle rouverte
  # l'après-midi n'écrase pas le café ; le tableau garde tout.
  def window_of(curve, events)
    return if curve.empty?

    from = [ curve.first.first, @webinar.starts_at ].min
    to = horizon(events)
    focus_from = [ @webinar.starts_at, @webinar.started_at ].compact.min - FOCUS_MARGIN
    focus_to = (@webinar.ended_at || @now) + FOCUS_MARGIN
    clipped = [ [ from, focus_from ].max, [ to, focus_to ].min ]
    clipped.first < clipped.last ? clipped : [ from, to ]
  end

  # Fin du récit : maintenant tant que le direct n'est pas terminé ; sinon le
  # dernier fait de salle (une page rouverte le lendemain n'allonge rien) ou
  # la fin du direct.
  def horizon(events)
    return @now unless @webinar.ended?

    last_room_fact = events.reverse.find { |event| event.kind.in?(PresenceEvent::ROOM_KINDS) }
    [ last_room_fact&.occurred_at, @webinar.ended_at ].compact.max
  end
end
