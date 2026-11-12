class AgendaController < ApplicationController
  # Agenda PUBLIC (« un calendrier où les gens peuvent
  # connaître toutes les dates des webinaires et les inclure dans leurs
  # calendriers quotidiens »). Aucune session, aucune garde navigateur,
  # comme le catalogue : un poste d'entreprise figé doit pouvoir le lire.
  #
  # Seuls les webinaires `published` existent ici. L'abonnement à toutes les
  # dates est PERSONNEL : le lien
  # /agenda/<jeton>.ics part par mail à la confirmation d'une inscription
  # (CalendarSubscription, CalendarFeedsController). L'ancien flux public
  # /agenda.ics répond 410 avec le mode d'emploi ; le fichier d'un seul
  # événement (/w/:slug.ics) reste public, comme la page qu'il reprend.
  #
  # /w/:slug.ics et /agenda/next.json sont lisibles depuis tout site
  # (tartiflette.dev) : données publiques, sans session
  # ni cookie, donc `*` sans Access-Control-Allow-Credentials. Ce ne sont
  # que des GET simples, sans pré-vol : l'en-tête suffit (pas de rack-cors).
  # La page HTML /agenda n'est pas ouverte.
  #
  # Ces réponses ouvertes sont toujours en français : elles ignorent
  # `?locale=` et le cookie de langue, et n'écrivent donc jamais ce cookie
  # (une réponse `Cache-Control: public` ne porte pas de Set-Cookie, et
  # son contenu ne dépend d'aucun cookie). La page HTML garde la rotation
  # de langue de l'application.
  include AgendaKindFilter

  NEXT_DEFAULT_LIMIT = 3
  NEXT_LIMITS = 1..10
  # Le site appelant revient souvent ; une minute de retard sur un passage
  # en direct reste acceptable.
  NEXT_MAX_AGE = 60.seconds
  # Section de la page /agenda qui explique le flux personnel.
  REGISTER_ANCHOR = "inscription"

  skip_around_action :switch_locale
  around_action :localize
  before_action :open_to_any_origin, if: :open_response?

  # GET /agenda (page) ; /agenda.ics, flux public fermé : 410 et le chemin
  # vers le flux personnel. Un agenda abonné cesse d'interroger une adresse
  # disparue (Gone), là où un 404 passerait pour une panne passagère.
  def index
    respond_to do |format|
      format.html do
        # Ordre total : deux webinaires à la même heure gardent leur ordre.
        webinars = Webinar.published.includes(:pack, :host_attendances, :webinar_hosts).order(starts_at: :asc, id: :asc)
        now = Time.current
        past, upcoming = webinars.partition { |webinar| webinar.past?(now) }
        @upcoming_by_month = upcoming.group_by { |webinar| webinar.starts_at.beginning_of_month }
        @past = past.reverse
      end
      format.ics do
        render plain: t("agenda.public_feed_gone", url: agenda_url), status: :gone, content_type: "text/plain"
      end
    end
  end

  # GET /w/:slug.ics — un seul événement, à importer.
  def show
    webinar = Webinar.published.find_by!(slug: params[:slug])
    send_data helpers.webinar_calendar.event(webinar),
              type: WebinarCalendar::CONTENT_TYPE, disposition: "attachment", filename: "#{webinar.slug}.ics"
  end

  # GET /agenda/next.json[?kind=cafe_ia&limit=3] — les prochaines dates
  # (Webinar.next_dates) et où s'inscrire pour recevoir le flux personnel.
  # Frontière lue par tartiflette.dev : contrat live.agenda.next.v2, détail
  # dans docs/agenda.md.
  def next_dates
    if kind_invalid?
      return render json: { error: "invalid_kind", message: invalid_kind_message, allowed_kinds: Webinar::KINDS },
                    status: :bad_request
    end

    dates = of_requested_kind(Webinar.published.includes(:pack, :host_attendances, :webinar_hosts)).next_dates(next_limit)
    calendar = helpers.webinar_calendar
    expires_in NEXT_MAX_AGE, public: true
    render json: {
      calendar: calendar_links,
      webinars: dates.map { |status, webinar| next_date(status, webinar, calendar) }
    }
  end

  private

  # .ics (fichier unitaire, ancien flux fermé) et JSON : tout sauf la page.
  def open_response?
    action_name != "index" || request.format.ics?
  end

  def localize(&action)
    open_response? ? I18n.with_locale(:fr, &action) : switch_locale(&action)
  end

  # Ni ces actions ni `localize` ne touchent session ou cookies : aucune
  # réponse ouverte ne porte de Set-Cookie (gardé par les tests).
  def open_to_any_origin
    response.headers["Access-Control-Allow-Origin"] = "*"
  end

  # Absent ou illisible → défaut ; hors bornes → ramené dans les bornes.
  def next_limit
    limit = Integer(params[:limit].to_s, 10, exception: false) || NEXT_DEFAULT_LIMIT
    limit.clamp(NEXT_LIMITS)
  end

  # v2 : plus de flux public. `register_url` mène à l'explication de la page
  # /agenda : s'inscrire à un webinaire donne le lien personnel.
  def calendar_links
    { page_url: agenda_url, register_url: agenda_url(anchor: REGISTER_ANCHOR) }
  end

  def next_date(status, webinar, calendar)
    {
      slug: webinar.slug,
      title: webinar.title,
      kind: webinar.kind,
      status: status,
      date_status: webinar.date_status,
      starts_at: webinar.starts_at.utc.iso8601,
      ends_at: webinar.planned_ends_at.utc.iso8601,
      url: public_webinar_url(slug: webinar.slug),
      ics_url: webinar_calendar_url(slug: webinar.slug, format: :ics),
      google_calendar_url: calendar.google_event_url(webinar),
      free: webinar.free?,
      price_label: webinar.price_label,
      topic: (webinar.topic && { title: webinar.topic, summary: webinar.topic_summary }),
      speakers: webinar.announced_speakers,
      lead_host: webinar.lead_host_name
    }
  end
end
