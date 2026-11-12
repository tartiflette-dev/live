# GET /agenda/<jeton>.ics[?kind=cafe_ia] — flux d'agenda PERSONNEL, réservé
# aux personnes dont une inscription est confirmée (CalendarSubscription,
# lien envoyé par CalendarSubscriptionMailer). Même sérialisation que
# l'ancien flux public /agenda.ics (WebinarCalendar#feed, octets figés par
# AgendaFeedGoldenTest) : tous les webinaires publiés, passés compris ; un
# webinaire dépublié en sort au rafraîchissement suivant.
#
# Jeton inconnu ou révoqué : 404, sans dire lequel. Ni session ni cookie
# (aucun Set-Cookie, toujours en français) ; `Cache-Control: private` : un
# cache partagé ne garde pas une réponse adressée par un jeton. Pas de CORS :
# ce flux n'est lu que par l'agenda de la personne. Chaque lecture compte
# (`fetch_count`, `last_fetched_at`) : la mesure des abonnés actifs ne dépend
# pas des journaux.
class CalendarFeedsController < ApplicationController
  include AgendaKindFilter

  skip_around_action :switch_locale
  around_action :in_french

  def show
    subscription = CalendarSubscription.find_active_by_token(params[:token])
    return head :not_found unless subscription
    return render(plain: invalid_kind_message, status: :bad_request, content_type: "text/plain") if kind_invalid?

    subscription.record_fetch!
    # Ordre total (id départage) : un flux inchangé garde les mêmes octets.
    webinars = of_requested_kind(Webinar.published.includes(:pack).order(starts_at: :asc, id: :asc))
    expires_in 0, must_revalidate: true
    send_data helpers.webinar_calendar.feed(webinars, kind: requested_kind),
              type: WebinarCalendar::CONTENT_TYPE, disposition: "inline", filename: "agenda-#{Brand.organization.parameterize}-live.ics"
  end

  private

  def in_french(&action)
    I18n.with_locale(:fr, &action)
  end
end
