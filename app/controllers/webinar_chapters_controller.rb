# Chapitres du replay d'un webinaire, côté animation :
#
#   GET   /webinars/:webinar_id/chapters             → la proposition du LLM
#                                                      (ou les chapitres validés)
#                                                      à relire, corriger, valider ;
#   PATCH /webinars/:webinar_id/chapters             → enregistrer ; `validate`
#                                                      les montre aux spectateurs ;
#                                                      un jeu déjà validé reste
#                                                      visible (l'écran le dit) ;
#   POST  /webinars/:webinar_id/chapters/propose     → redemander une proposition
#                                                      au LLM (jeu non validé) ;
#   POST  /webinars/:webinar_id/chapters/unvalidate  → les retirer aux spectateurs.
#
# Propriétaire et animateurs du projet (`where_managed_by`), comme la
# publication du replay ; tout autre compte reçoit 404. Chaque enregistrement
# remet l'index de recherche des replays à jour (ReplaySearchIndex).
class WebinarChaptersController < ApplicationController
  include AnimateurBrowserPolicy

  before_action :authenticate_animateur!
  before_action :set_webinar
  before_action :set_chapter_set

  def show
    @revision = ChapterRevision.for(@chapter_set) if @chapter_set.origin
  end

  def update
    return redirect_to(webinar_chapters_path(@webinar), status: :see_other) unless @chapter_set.origin

    @revision = ChapterRevision.from_params(@chapter_set, params[:chapters])
    drafts = @revision.drafts
    return render(:show, status: :unprocessable_entity) if drafts.nil?

    validate = params[:validate].present?
    @chapter_set.revise!(drafts, by: current_user, validate: validate)
    ReplaySearchIndex.refresh(@webinar)
    notice = if validate then "Chapitres validés : les spectateurs du replay les voient."
    elsif @chapter_set.validated? then "Chapitres enregistrés : toujours visibles des spectateurs."
    else "Chapitres enregistrés, pas encore montrés aux spectateurs."
    end
    redirect_to webinar_chapters_path(@webinar), notice: notice, status: :see_other
  end

  def propose
    if @chapter_set.validated?
      redirect_to webinar_chapters_path(@webinar), status: :see_other,
                  alert: "Chapitres validés : retire-les aux spectateurs avant d'en redemander."
    else
      ChapterProposalJob.perform_later(@webinar.id, force: true)
      redirect_to webinar_chapters_path(@webinar), status: :see_other,
                  notice: "Proposition demandée : elle remplacera ces chapitres d'ici quelques minutes."
    end
  end

  def unvalidate
    @chapter_set.unvalidate!
    ReplaySearchIndex.refresh(@webinar)
    redirect_to webinar_chapters_path(@webinar), notice: "Chapitres retirés aux spectateurs.", status: :see_other
  end

  private

  def set_webinar
    @webinar = Webinar.where_managed_by(current_user).find_by!(slug: params[:webinar_id])
  end

  # Le jeu n'est créé qu'au premier enregistrement (ChapterSet#revise!) ou
  # par la proposition du LLM : un GET n'écrit rien.
  def set_chapter_set
    @chapter_set = @webinar.chapter_set || @webinar.build_chapter_set
  end
end
