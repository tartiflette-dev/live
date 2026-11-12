# Toutes les questions, tous cafés confondus — le fonds des questions du
# direct (file Q&R extraite de la discussion) et de celles posées depuis le
# replay (QaItem, source replay), réserve de sujets de contenu :
#
#   GET /questions[?cafe=<slug>][&origine=direct|replay]
#
# Animation seulement, chacun sur les webinaires qu'il anime (même scope
# `where_animated_by` que la file Q&R de la régie, qui nomme déjà les
# auteurs) ; un spectateur reçoit 404. Lecture seule : les questions se
# traitent dans la file du café (régie). Les plus récentes d'abord, au plus
# LIMIT.
class QuestionsController < ApplicationController
  include AnimateurBrowserPolicy

  LIMIT = 300
  ORIGINS = %w[direct replay].freeze

  before_action :authenticate_animateur!

  def index
    webinars = Webinar.where_animated_by(current_user)
    items = QaItem.where(webinar_id: webinars.select(:id))
    @cafes = webinars.where(id: items.select(:webinar_id)).order(starts_at: :desc)
    @cafe = @cafes.find_by(slug: params[:cafe]) if params[:cafe].present?
    @origin = params[:origine].presence_in(ORIGINS)

    # Café inconnu ou animé par un autre : aucune question (webinar_id IS NULL).
    items = items.where(webinar: @cafe) if params[:cafe].present?
    items = case @origin
    when "replay" then items.where(source: "replay")
    when "direct" then items.from_live
    else items
    end
    @items = items.includes({ webinar: { replay: :recording } }, :registration, :user, :messages).order(created_at: :desc, id: :desc).limit(LIMIT)
  end
end
