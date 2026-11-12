# Les webinaires vus par les agendas des visiteurs : calendrier iCalendar
# (RFC 5545) — flux d'abonnement personnel (/agenda/<jeton>.ics) et fichier d'un seul
# événement (/w/:slug.ics) — et modèle d'événement Google Agenda, qui
# partagent une même description. Enveloppe UNIQUE de la gem `icalendar` :
# le pliage à 75 octets, l'échappement TEXT et les
# fins de ligne CRLF sont les siens. Le choix des webinaires servis (publiés
# seulement) appartient à l'appelant.
#
# Choix de sérialisation :
#   • instants en UTC (suffixe Z) plutôt qu'un VTIMEZONE : Rails convertit
#     l'heure de Paris au bon décalage été/hiver, chaque client la restitue
#     dans le fuseau de l'abonné, et aucune définition de fuseau n'est à tenir ;
#   • DTSTAMP = LAST-MODIFIED = updated_at, pas l'heure de la requête : sans
#     METHOD, DTSTAMP est la dernière révision de l'événement (RFC 5545
#     §3.8.7.2), et un flux inchangé reste identique octet pour octet
#     (ETag stable, 304) ;
#   • SEQUENCE = secondes écoulées entre created_at et updated_at : 0 à la
#     création, croissante à chaque modification, sans colonne dédiée ;
#   • UID = slug (unique, immuable) @ domaine de l'app : le même événement
#     garde le même UID dans le flux et dans le fichier unitaire.
class WebinarCalendar
  # Charset explicite : `send_data` le retire sinon, et certains clients
  # lisent encore un text/* sans charset en Latin-1.
  CONTENT_TYPE = "text/calendar; charset=utf-8".freeze
  NAME = "Webinaires #{Brand.organization}".freeze
  # Rafraîchissement suggéré aux abonnés (RFC 7986, et son équivalent Outlook).
  REFRESH_INTERVAL = "PT1H".freeze
  PRODID = "-//#{Brand.organization}//#{Brand.host}//FR".freeze
  UID_DOMAIN = (ENV["APP_HOST"].presence || Brand.host).freeze
  # Le lien Google porte tout dans son URL : texte libre tronqué.
  GOOGLE_TEXT_LIMIT = 500

  # Nom du calendrier d'un flux restreint à `kind` (ou complet).
  def self.feed_name(kind = nil)
    kind ? "#{I18n.t("catalogue.kinds.#{kind}", locale: :fr)} — #{NAME}" : NAME
  end

  # @param page_url [#call] webinaire → URL absolue de sa page publique
  def initialize(page_url:)
    @page_url = page_url
  end

  # Flux d'abonnement : nom de calendrier et intervalle de rafraîchissement.
  # `kind` = format auquel l'appelant a restreint `webinars` : il nomme le
  # calendrier (« Café IA — Webinaires <organisation> »), sans toucher aux UID.
  def feed(webinars, kind: nil)
    calendar = new_calendar
    calendar.x_wr_calname = self.class.feed_name(kind)
    calendar.refresh_interval = REFRESH_INTERVAL
    calendar.x_published_ttl = REFRESH_INTERVAL
    webinars.each { |webinar| calendar.add_event(event_for(webinar)) }
    calendar.to_ical
  end

  # Fichier d'un seul événement, importé une fois dans l'agenda de la personne.
  def event(webinar)
    calendar = new_calendar
    calendar.add_event(event_for(webinar))
    calendar.to_ical
  end

  # Événement prérempli dans Google Agenda (fin = durée prévue du format).
  def google_event_url(webinar)
    url = @page_url.call(webinar)
    query = {
      action: "TEMPLATE",
      text: webinar.title,
      dates: [ webinar.starts_at, webinar.planned_ends_at ].map { |time| time.utc.strftime("%Y%m%dT%H%M%SZ") }.join("/"),
      details: description(webinar.description_text.truncate(GOOGLE_TEXT_LIMIT), webinar, url),
      location: url,
      ctz: Time.zone.tzinfo.name
    }
    "https://calendar.google.com/calendar/render?#{query.to_query}"
  end

  private

  # Sans METHOD : ni le flux ni le fichier ne sont des messages iTIP
  # (RFC 5546). Un METHOD:PUBLISH exigerait le paramètre `method` du
  # Content-Type (RFC 5545 §3.7.2) et un ORGANIZER par événement.
  def new_calendar
    Icalendar::Calendar.new.tap { |calendar| calendar.prodid = PRODID }
  end

  def event_for(webinar)
    url = @page_url.call(webinar)
    Icalendar::Event.new.tap do |event|
      event.uid           = "#{webinar.slug}@#{UID_DOMAIN}"
      event.dtstamp       = utc(webinar.updated_at)
      event.last_modified = utc(webinar.updated_at)
      event.created       = utc(webinar.created_at)
      event.sequence      = (webinar.updated_at - webinar.created_at).to_i
      event.dtstart       = utc(webinar.starts_at)
      event.dtend         = utc(webinar.planned_ends_at)
      event.summary       = webinar.title
      event.description   = description(webinar.description_text, webinar, url)
      event.url           = url
      event.location      = url
      event.status        = "CONFIRMED"
    end
  end

  def description(free_text, webinar, url)
    [
      free_text,
      "#{webinar.kind_label} · #{webinar.price_label}",
      "Page du webinaire : #{url}"
    ].compact_blank.join("\n\n")
  end

  def utc(time)
    Icalendar::Values::DateTime.new(time.utc, "tzid" => "UTC")
  end
end
