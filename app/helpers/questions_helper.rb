module QuestionsHelper
  ORIGIN_LABELS = { "direct" => "Direct", "replay" => "Replay" }.freeze
  STATUS_LABELS = { "open" => "À traiter", "answered" => "Répondue", "dismissed" => "Écartée" }.freeze

  # Questions posées depuis le replay, encore à traiter, sur les webinaires
  # qu'anime le compte connecté : le compteur du lien « Questions ».
  def open_replay_questions_count
    @open_replay_questions_count ||=
      QaItem.open.where(source: "replay", webinar_id: Webinar.where_animated_by(current_user).select(:id)).count
  end

  def question_origin(item)
    item.source_replay? ? "replay" : "direct"
  end

  # Instant du replay où la question se situe : celui de la vidéo pour une
  # question du replay, le moment où elle a été posée pour une question du
  # direct ; nil sans replay ou hors de la vidéo.
  def question_replay_second(item)
    return item.video_position if item.source_replay?

    replay = item.webinar.replay
    second = replay&.video_second(item.created_at)
    second if second&.between?(0, replay.duration)
  end
end
