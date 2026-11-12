# Question posée depuis le lecteur de replay (app/javascript/replay_questions.js),
# ancrée à l'instant de la vidéo :
#
#   POST /w/:slug/replay/questions  { label, at } → 201 { id, label, video_position } ;
#        422 libellé absent, vide, trop long ou autre chose que du texte,
#        instant illisible ; 404 sans accès
#        ou replay non publié ; 429 débit dépassé.
#
# Elle rejoint la file Q&R du webinaire (QaItem, source replay), traitée
# par l'animation dans la régie et listée dans la vue de toutes les
# questions (QuestionsController).
class ReplayQuestionsController < ApplicationController
  include ReplayInteraction

  before_action :require_json!
  before_action :set_replay_viewer
  before_action :require_published_replay!

  rate_limit to: 5, within: 10.minutes, name: "replay-questions-burst",
    by: :rate_limit_key, store: RATE_LIMIT_STORE, with: :render_rate_limited
  rate_limit to: 20, within: 1.day, name: "replay-questions-day",
    by: :rate_limit_key, store: RATE_LIMIT_STORE, with: :render_rate_limited

  rescue_from ActiveRecord::RecordInvalid do
    render json: { error: "invalid_question" }, status: :unprocessable_entity
  end

  def create
    at = Float(params[:at], exception: false)
    label = params[:label]
    return render(json: { error: "invalid_question" }, status: :unprocessable_entity) unless at&.finite? && label.is_a?(String)

    item = QaItem.ask_from_replay!(replay: @replay, viewer: @viewer, label: label, at: at)
    return head(:not_found) unless item

    render_escaped_json({ id: item.id, label: item.label, video_position: item.video_position }, status: :created)
  end
end
