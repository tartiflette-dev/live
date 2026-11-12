# Replay d'un webinaire, côté animation :
#
#   GET  /webinars/:webinar_id/replay            → état, vidéo de référence,
#                                                  statistiques de visionnage,
#                                                  réponses aux sondages du
#                                                  direct et du replay, séparées ;
#   POST /webinars/:webinar_id/replay/publish    → publier (direct terminé,
#                                                  composite lisible), puis
#                                                  chapitres proposés et index
#                                                  de recherche (ChapterProposalJob) ;
#   POST /webinars/:webinar_id/replay/unpublish  → retirer (les statistiques
#                                                  restent) ;
#   POST /webinars/:webinar_id/replay/montage    → demander le montage piloté
#                                                  par la parole (ReplayMontage,
#                                                  rendu de nuit hors direct).
#
# Propriétaire et animateurs du projet seulement (`where_managed_by`, comme
# les enregistrements et les inscrits) : les statistiques nomment les
# personnes. Tout autre compte reçoit 404.
class WebinarReplaysController < ApplicationController
  include AnimateurBrowserPolicy

  before_action :authenticate_animateur!
  before_action :set_webinar

  def show
    @replay = @webinar.replay
    @reference_recording = @replay&.recording || Replay.reference_recording_for(@webinar)
    @stats = ReplayStats.new(@replay) if @replay
    @montage = ReplayMontage.new(@replay) if @replay
    @polls = @webinar.polls.where.not(opened_at: nil).order(:opened_at, :id)
  end

  def publish
    replay = @webinar.ended? && Replay.publish!(@webinar)
    if replay
      ChapterProposalJob.perform_later(@webinar.id)
      redirect_to webinar_replay_path(@webinar), notice: "Replay publié.", status: :see_other
    else
      redirect_to webinar_replay_path(@webinar), status: :see_other,
                  alert: "Publication impossible : il faut un direct terminé et sa vue d'ensemble enregistrée."
    end
  end

  def unpublish
    @webinar.replay&.unpublish!
    redirect_to webinar_replay_path(@webinar), notice: "Replay retiré.", status: :see_other
  end

  # Le replay est créé (non publié) s'il n'existe pas : on peut regarder le
  # montage avant de publier.
  def montage
    replay = @webinar.ended? && Replay.prepare!(@webinar)
    unless replay
      return redirect_to webinar_replay_path(@webinar), status: :see_other,
                         alert: "Montage impossible : il faut un direct terminé et sa vue d'ensemble enregistrée."
    end

    notice = ReplayMontage.new(replay).request! ? "Montage demandé : il sera rendu cette nuit, hors direct." : "Rien de nouveau à monter."
    redirect_to webinar_replay_path(@webinar), notice: notice, status: :see_other
  end

  private

  def set_webinar
    @webinar = Webinar.where_managed_by(current_user).find_by!(slug: params[:webinar_id])
  end
end
