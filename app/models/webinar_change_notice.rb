# Ce que les inscrits confirmés d'un webinaire savent de sa date : le dernier
# état annoncé (`starts_at`, `published`), une ligne par webinaire, née au
# premier changement d'un webinaire publié. La première publication d'un
# brouillon n'en crée pas : rien n'avait été annoncé, même à des inscrits
# confirmés par le lien participants privé, qui n'a pas de garde de visibilité.
#
# Webinar appelle `track` après chaque commit qui touche `starts_at` ou
# `visibility`, quel que soit le chemin (écran d'édition, console). Chaque
# changement relance un délai d'apaisement (QUIET_PERIOD) et seul le dernier
# job, celui dont la `revision` est encore la courante, compare l'état du
# webinaire au dernier annoncé. Une date corrigée puis remise, une
# dépublication annulée dans le délai : rien ne part.
#
# Sauf urgence : si le café concerné commence dans moins de URGENT_WINDOW
# (date annoncée pour une annulation ; la plus proche de l'annoncée et de la
# nouvelle pour un changement), le job part sans attendre. Et « à venir »
# se juge au moment du changement (`changed_at`), pas quand le job tourne :
# un café de 18:00 annulé à 17:55 est annoncé même si le job passe à 18:01.
#
# Deux `update!` dans une même transaction (console) :
# `*_before_last_save` ne voit que le second, et l'état noté « avant » à la
# naissance de la ligne est alors la valeur intermédiaire (l'« annulé » la
# citerait). Faire un changement par commande.
#
# Deux annonces, aux inscriptions confirmées, jamais retirées de la salle
# (Webinar#registrations_to_notify, le nombre qu'annonce l'écran d'édition) :
#   • « nouvelle date » (WebinarChangeMailer#rescheduled, .ics joint, même UID
#     et SEQUENCE croissante) : webinaire publié dont la date diffère de la
#     dernière annoncée, ou republié après une annulation annoncée ;
#   • « annulé » (WebinarChangeMailer#cancelled) : webinaire dépublié.
# Seulement pour un webinaire À VENIR au moment du changement (pas lancé ;
# date annoncée future pour une annulation, nouvelle date future pour un
# changement) ; dans les autres cas, l'état courant devient l'annoncé sans mail.
#
# Une fois par destinataire et par annonce : chaque envoi est d'abord marqué
# (WebinarChangeDelivery, index unique), puis le mail part après la
# transaction. Un job rejoué ou repris après une coupure n'envoie qu'à ceux
# qui n'ont rien reçu ; un mail peut manquer (coupure entre la marque et la
# mise en file), il ne double jamais.
class WebinarChangeNotice < ApplicationRecord
  QUIET_PERIOD = 10.minutes
  URGENT_WINDOW = 30.minutes

  belongs_to :webinar
  has_many :deliveries, class_name: "WebinarChangeDelivery", inverse_of: :webinar_change_notice

  # @param webinar [Webinar] juste enregistré, ses `*_before_last_save` lisibles
  def self.track(webinar)
    published_before = webinar.visibility_before_last_save == "published"
    return unless published_before || exists?(webinar_id: webinar.id)

    now = Time.current
    notice = create_or_find_by!(webinar_id: webinar.id) do |row|
      row.starts_at = webinar.starts_at_before_last_save
      row.published = published_before
      row.changed_at = now
    end
    wait = notice.urgent?(now) ? 0 : QUIET_PERIOD
    WebinarChangeNoticeJob.set(wait: wait).perform_later(notice, notice.record_change!(now))
  end

  # @return [Integer] la révision qui porte ce changement
  def record_change!(now = Time.current)
    with_lock do
      update!(revision: revision + 1, changed_at: now)
      revision
    end
  end

  # Le café concerné commence-t-il trop tôt pour attendre l'apaisement ?
  def urgent?(now = Time.current)
    concerned = webinar.visibility_published? ? [ starts_at, webinar.starts_at ].min : starts_at
    concerned < now + URGENT_WINDOW
  end

  # Annonce l'écart entre l'état du webinaire et le dernier annoncé, si
  # `revision` est toujours la dernière (sinon un job plus récent s'en charge).
  # @return [Integer] mails mis en file
  def announce!(revision, now: Time.current)
    announced_starts_at = nil
    change, recipients = with_lock do
      next [ nil, [] ] unless revision == self.revision

      announced_starts_at = starts_at
      change = pending_change(changed_at)
      recipients = change ? mark_recipients(change, now) : []
      update!(starts_at: webinar.starts_at, published: webinar.visibility_published?, notified_at: now)
      [ change, recipients ]
    end
    recipients.each { |registration| mail_for(change, registration, announced_starts_at).deliver_later }
    recipients.size
  end

  private

  # @param changed_at [Time] moment du dernier changement : « à venir » s'y juge
  def pending_change(changed_at)
    return unless webinar.draft?

    if published? && !webinar.visibility_published?
      "cancelled" if starts_at > changed_at
    elsif webinar.visibility_published? && (!published? || starts_at.to_i != webinar.starts_at.to_i)
      "rescheduled" if webinar.starts_at > changed_at
    end
  end

  def mark_recipients(change, now)
    ids = webinar.registrations_to_notify.ids
    return [] if ids.empty?

    rows = ids.map do |registration_id|
      { webinar_change_notice_id: id, registration_id: registration_id, revision: revision, kind: change, created_at: now }
    end
    marked = WebinarChangeDelivery.insert_all(rows, unique_by: :index_webinar_change_deliveries_once,
                                                    returning: [ :registration_id ])
    Registration.where(id: marked.rows.flatten).includes(:webinar).order(:id).to_a
  end

  def mail_for(change, registration, announced_starts_at)
    case change
    when "rescheduled" then WebinarChangeMailer.rescheduled(registration)
    when "cancelled" then WebinarChangeMailer.cancelled(registration, starts_at: announced_starts_at)
    end
  end
end
