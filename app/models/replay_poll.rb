# Sondage du direct tel que le lecteur de replay le montre : en surcouche
# de la vidéo (jamais incrusté), de son instant d'ouverture à son instant
# de fermeture, en secondes de la vidéo de référence (même horloge que les
# sous-titres : horodatage − début du composite).
#
# Un sondage resté ouvert peu de temps reste à l'écran au moins
# MIN_WINDOW_SECONDS, le temps de lire la question. Un sondage jamais lancé,
# ou lancé après la fin de la vidéo, n'y paraît pas.
#
# Ce que voit le spectateur du replay (`attributes_for`) : la question, sa
# réponse (du direct ou du replay) et, une fois qu'il a répondu, le résultat
# direct + replay réunis avec la part de chacun. Les réponses courtes ne
# sont jamais montrées aux autres spectateurs (textes que personne n'a
# relus) : le résultat s'y limite au nombre de réponses.
class ReplayPoll
  MIN_WINDOW_SECONDS = 60

  attr_reader :poll, :start_second, :end_second

  # @return [Array<ReplayPoll>] dans l'ordre de la vidéo
  def self.for(replay)
    duration = replay.duration
    replay.webinar.polls.where.not(opened_at: nil).order(:opened_at, :id).filter_map do |poll|
      start = replay.video_second(poll.opened_at)
      next if start > duration

      start = start.clamp(0.0, duration)
      finish = poll.closed_at ? replay.video_second(poll.closed_at) : duration
      new(poll, start, [ finish, start + MIN_WINDOW_SECONDS ].max.clamp(start, duration))
    end
  end

  def initialize(poll, start_second, end_second)
    @poll = poll
    @start_second = start_second
    @end_second = end_second
  end

  # @param viewer [User, Registration]
  def attributes_for(viewer)
    mine = own_response(viewer)
    {
      id: poll.id, kind: poll.kind, multiple: poll.multiple, label: poll.label, options: poll.options,
      start: start_second.round(1), end: end_second.round(1),
      my_response: mine && { value: mine.value, origin: mine.origin },
      results: mine && results
    }
  end

  private

  def own_response(viewer)
    identities = PollResponse.live_identities(viewer) + [ PollResponse.replay_identity(viewer) ]
    poll.responses.where(respondent_identity: identities).order(Arel.sql("origin = 'live' DESC")).first
  end

  def results
    by_origin = poll.responses.group(:origin).count
    shares = { live: by_origin.fetch("live", 0), replay: by_origin.fetch("replay", 0) }
    return shares.merge(respondents: shares.values.sum) if poll.short_text?

    poll.results(poll.responses).merge(shares)
  end
end
