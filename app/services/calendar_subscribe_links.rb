# Portes d'entrée d'un flux d'agenda vers les calendriers : `webcal://`
# l'ouvre dans l'agenda du système (Apple, Outlook bureau, Thunderbird), les
# liens web l'ajoutent par abonnement chez Google et Microsoft, le lien
# https le télécharge une fois (sans mise à jour). Aucune requête sortante :
# ce ne sont que des liens.
class CalendarSubscribeLinks
  # @param feed_url [String] URL https absolue du flux
  # @param name [String] nom proposé par Outlook pour le calendrier
  def initialize(feed_url, name: WebinarCalendar::NAME)
    @feed_url = feed_url
    @name = name
  end

  def download_url
    @feed_url
  end

  def webcal_url
    @feed_url.sub(%r{\Ahttps?://}, "webcal://")
  end

  def google_url
    "https://calendar.google.com/calendar/r?#{{ cid: webcal_url }.to_query}"
  end

  # Outlook n'a pas d'adresse commune aux comptes pro et perso.
  def outlook_365_url
    outlook_url("outlook.office.com")
  end

  def outlook_com_url
    outlook_url("outlook.live.com")
  end

  private

  def outlook_url(host)
    "https://#{host}/calendar/0/addfromweb?#{{ url: @feed_url, name: @name }.to_query}"
  end
end
