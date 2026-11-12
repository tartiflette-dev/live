# Qui peut envoyer quoi, et maintenant, depuis l'écran d'envoi d'un webinaire
# (docs/announcements.md, audit sécurité de l'envoi groupé). Communication
# sortante vers des tiers : les cibles sont fermées par défaut et bornées.
#
#   • Listes (`marketing_list`, `notify_next`) : animateurs du PROJET seulement
#     (`User#project_host?` : groupe Pocket ID frais, liste ENV à email vérifié,
#     admin) — jamais le seul propriétaire d'un café. Au plus un envoi aux
#     listes par LIST_COOLDOWN glissantes, et aucun tant qu'un autre envoi aux
#     listes est en cours.
#   • Inscrits du webinaire (`webinar_registrants`) : propriétaire et
#     animateurs du projet, sans fenêtre ; co-animateur invité le JOUR du café
#     seulement (Paris, de 0:00 à la fin prévue + GUEST_WINDOW_AFTER_END), au
#     plus GUEST_DAILY_LIMIT envois par jour.
#
# `audiences` décide de ce que l'écran propose (le reste répond 404) ;
# `refusal` des quotas, relu au moment de l'envoi sous le verrou d'écriture
# (Announcement#dispatch!).
class AnnouncementPermission
  LIST_AUDIENCES = %w[marketing_list notify_next].freeze
  LIST_COOLDOWN = 24.hours
  GUEST_DAILY_LIMIT = 3
  GUEST_WINDOW_AFTER_END = 2.hours

  def initialize(webinar, user, now: Time.current)
    @webinar = webinar
    @user = user
    @now = now
  end

  def role
    @role ||= @webinar.role_for(@user)
  end

  def guest?
    role == :guest_host
  end

  def audiences
    Announcement::AUDIENCES.select { |audience| audience_open?(audience) }
  end

  # Raison d'un refus de quota pour un nouvel envoi à cette cible, ou nil.
  def refusal(audience)
    if LIST_AUDIENCES.include?(audience)
      list_refusal(except: nil)
    elsif guest? && guest_sent_today >= GUEST_DAILY_LIMIT
      "Tu as déjà fait #{GUEST_DAILY_LIMIT} envois aujourd'hui : c'est le maximum pour un co-animateur."
    end
  end

  # Reprise d'un envoi : jamais deux envois aux listes en cours à la fois.
  def resume_refusal(announcement)
    list_refusal(except: announcement, cooldown: false) if LIST_AUDIENCES.include?(announcement.audience)
  end

  private

  def audience_open?(audience)
    return @user&.project_host? if LIST_AUDIENCES.include?(audience)

    %i[owner project_host].include?(role) || (guest? && webinar_day?)
  end

  def webinar_day?
    (@webinar.starts_at.in_time_zone.beginning_of_day..(@webinar.planned_ends_at + GUEST_WINDOW_AFTER_END)).cover?(@now)
  end

  def guest_sent_today
    Announcement.where(author_sub: @user.oidc_sub, author_role: "guest_host", created_at: @now.in_time_zone.all_day).count
  end

  def list_refusal(except:, cooldown: true)
    lists = Announcement.where(audience: LIST_AUDIENCES).where.not(id: except&.id)
    last = lists.where(created_at: (@now - LIST_COOLDOWN)..).maximum(:created_at) if cooldown
    if last
      "Un envoi à une liste est déjà parti le #{I18n.l(last, format: :short)} : un seul par 24 h, " \
        "prochain possible à partir du #{I18n.l(last + LIST_COOLDOWN, format: :short)}."
    elsif lists.joins(:deliveries).merge(AnnouncementDelivery.in_flight(@now)).exists?
      "Un autre envoi à une liste est encore en cours : attends qu'il soit terminé."
    end
  end
end
