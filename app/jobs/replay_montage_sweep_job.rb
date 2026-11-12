# frozen_string_literal: true

# Adopte les montages de replay finis (ReplayMontage#adopt!) : le montage
# devient la copie de diffusion du replay et sa demande quitte la file. Les
# demandes en attente ou en échec restent (le moteur de rendu externe les rend,
# une nouvelle demande relance un échec). Une demande dont le replay n'existe
# plus est retirée. Cadence : config/recurring.yml ; ne lit que la file.
class ReplayMontageSweepJob < ApplicationJob
  queue_as :default

  def perform
    Recording.recordings_root.join(ReplayMontage::QUEUE_DIR).glob("*.json").each do |request|
      replay_id = Integer(request.basename(".json").to_s, 10, exception: false)
      next if replay_id.nil?

      replay = Replay.find_by(id: replay_id)
      replay ? ReplayMontage.new(replay).adopt! : request.delete
    end
  end
end
