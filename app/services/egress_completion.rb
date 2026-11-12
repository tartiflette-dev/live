# Only a terminal server result confirms completion and its filename.
class EgressCompletion
  def self.apply(recording, result)
    recording.with_lock do
      return if recording.done? && recording.completion_received_at
      # Garde symétrique côté
      # :failed. Un recording déjà clos en échec (completion_received_at
      # posé par un webhook antérieur) ne doit pas être rejoué — sinon
      # un second webhook sur le même egress écraserait `error_message`
      # et pourrait transitionner l'état d'un fantôme déjà réconcilié.
      return if recording.failed? && recording.completion_received_at.present?
      return if recording.egress_id.present? && recording.egress_id != result[:egress_id]

      recording.egress_id = result[:egress_id]
      state = result[:status].to_s.sub(/\AEGRESS_/, "").downcase
      filename = Array(result[:files]).first
      path = verified_path(recording, filename)
      recording.path = path if path
      case state
      when "complete"
        recording.status = path ? :done : :failed
        recording.error_message = path ? nil : "Egress terminé sans fichier vérifiable."
        recording.ended_at ||= Time.current
        recording.completion_received_at ||= Time.current
      when "failed", "aborted", "limit_reached"
        recording.status = :failed
        recording.error_message = "Egress terminé en échec (#{state})."
        recording.ended_at ||= Time.current
        recording.completion_received_at ||= Time.current
      when "active", "starting"
        recording.status = :recording if recording.starting?
      when "ending"
        recording.status = :stopping
      end
      recording.save!
    end
  end

  def self.verified_path(recording, filename)
    return unless filename.is_a?(String)
    relative = filename.delete_prefix("/data/")
    if recording.track?
      prefix = recording.output_prefix
      relative if prefix.present? && relative.match?(/\A#{Regexp.escape(prefix)}\.(mp4|webm|ogg)\z/)
    elsif recording.path.present? && relative == recording.path
      relative
    end
  end
end
