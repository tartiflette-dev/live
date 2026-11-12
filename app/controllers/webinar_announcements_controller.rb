# Écran d'envoi groupé d'un webinaire (docs/announcements.md) :
#
#   GET  /webinars/:webinar_id/announcements/new      → composer (cible, objet, corps)
#   POST /webinars/:webinar_id/announcements/preview  → aperçu + NOMBRE de destinataires
#                                                        (`edit=1` : retour à la composition)
#   POST /webinars/:webinar_id/announcements          → envoi, sur confirmation explicite
#   GET  /webinars/:webinar_id/announcements          → journal des envois
#   POST /webinars/:webinar_id/announcements/:id/resume → reprise (jamais partis, sans nouvelles)
#
# Seule voie d'envoi (Announcement : envoi irréversible à des tiers) : un
# humain connecté, page
# après page. La confirmation exige la case cochée ET le nombre montré à
# l'aperçu : si la cible a changé entre-temps, l'aperçu revient avec le
# nouveau nombre. `dispatch_token`, tiré à l'aperçu, rend le POST idempotent
# (double clic, renvoi du formulaire, double clic simultané).
#
# Droits et quotas : AnnouncementPermission. Cible non ouverte à
# l'utilisateur, maintenant : 404 (défense énumération, comme le reste de
# l'app). Quota atteint : 429 avec la raison, rien ne part. Aucune adresse de
# destinataire n'est affichée.
class WebinarAnnouncementsController < ApplicationController
  include AnimateurBrowserPolicy

  before_action :authenticate_animateur!
  before_action :set_webinar
  before_action :set_permission
  before_action :require_open_audience, only: %i[new preview create]

  def index
    @announcements = Announcement.visible_to(@webinar, current_user).recent_first.to_a
    @progress = Announcement.progress_of(@announcements)
  end

  def new
    @announcement = build_announcement(audience: params[:audience].presence_in(@audiences) || @audiences.first)
    @counts = audience_counts
  end

  def preview
    @announcement = build_announcement(announcement_params)
    return head :not_found unless @audiences.include?(@announcement.audience)
    return render_form(status: :ok) if params[:edit].present?

    @announcement.dispatch_token = SecureRandom.urlsafe_base64(24)
    return render_form unless @announcement.valid?

    refusal = @permission.refusal(@announcement.audience)
    return render_refusal(refusal) if refusal

    @recipients_count = @announcement.recipients.size
  end

  def create
    @announcement = build_announcement(announcement_params.merge(dispatch_token: params[:dispatch_token]))
    return head :not_found unless @audiences.include?(@announcement.audience)
    return redirect_to_journal(notice: "Cet envoi est déjà parti.") if already_dispatched?
    return render_form unless @announcement.valid?

    recipients = @announcement.recipients
    return render_preview_again(recipients.size) unless confirmed_for?(recipients.size)

    send_announcement(recipients)
  end

  def resume
    announcement = Announcement.visible_to(@webinar, current_user).find(params[:id])
    return head :not_found unless @permission.audiences.include?(announcement.audience)

    refusal = @permission.resume_refusal(announcement)
    return redirect_to webinar_announcements_path(@webinar), alert: refusal if refusal

    count = announcement.enqueue_pending!
    redirect_to_journal(notice: "Reprise : #{count} mail#{'s' if count > 1} remis en route.")
  end

  private

  def set_webinar
    @webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
  end

  def set_permission
    @permission = AnnouncementPermission.new(@webinar, current_user)
    head :not_found unless @permission.role
  end

  def require_open_audience
    @audiences = @permission.audiences
    head :not_found if @audiences.empty?
  end

  def announcement_params
    params.expect(announcement: %i[audience subject body])
  end

  def build_announcement(attributes)
    Announcement.new(attributes.to_h.merge(webinar: @webinar, author_sub: current_user.oidc_sub,
                                           author_email: current_user.email, author_role: @permission.role.to_s))
  end

  def audience_counts
    @audiences.index_with { |audience| build_announcement(audience: audience).recipients.size }
  end

  def already_dispatched?
    @announcement.dispatch_token.present? && Announcement.exists?(dispatch_token: @announcement.dispatch_token)
  end

  def confirmed_for?(count)
    params[:confirmed] == "1" && params[:expected_count].to_s == count.to_s && count.positive?
  end

  # Quotas relus sous le verrou d'écriture de l'envoi : deux confirmations
  # simultanées ne passent pas toutes les deux.
  def send_announcement(recipients)
    @announcement.dispatch!(recipients) do
      refusal = @permission.refusal(@announcement.audience)
      raise Announcement::Refused, refusal if refusal
    end
    redirect_to_journal(notice: "Envoi lancé : #{recipients.size} mail#{'s' if recipients.size > 1} en route, " \
                                "un toutes les #{Announcement::SPACING.to_i} secondes.")
  rescue Announcement::Refused => refusal
    render_refusal(refusal.message)
  rescue ActiveRecord::RecordNotUnique
    redirect_to_journal(notice: "Cet envoi est déjà parti.")
  end

  def render_form(status: :unprocessable_entity)
    @counts = audience_counts
    render :new, status: status
  end

  def render_refusal(message)
    flash.now[:alert] = message
    render_form(status: :too_many_requests)
  end

  def render_preview_again(count)
    flash.now[:alert] =
      if count.zero? then "Aucun destinataire : rien n'est envoyé."
      elsif params[:expected_count].to_s != count.to_s then "Le nombre de destinataires a changé : vérifie et confirme à nouveau."
      else "Coche la case de confirmation pour envoyer."
      end
    @recipients_count = count
    render :preview, status: :unprocessable_entity
  end

  def redirect_to_journal(notice:)
    redirect_to webinar_announcements_path(@webinar), notice: notice
  end
end
