# EgressActivationJob — retient, pour une piste, l'instant où son egress a
# écrit le premier échantillon (webhook `egress_updated`, statut ACTIVE).
#
# Pourquoi : l'egress de piste (LiveKit egress, sans transcodage) rebase le
# fichier à 0 sur ce premier échantillon. L'audio Opus démarre au premier
# paquet ; la vidéo attend la première image clé (SPS/PPS + IDR), et son
# fichier commence de 0,09 à 1,64 s après celui du micro selon la personne et
# la session (mesuré sur deux directs). Recaler caméra et micro sur l'heure de la
# DEMANDE (`started_at`) avançait donc la vidéo de ce délai : 0,65 s pour
# l'hôte au Café #8, 1,55 s au Café #7.
#
# L'egress passe ACTIVE quand son pipeline GStreamer atteint PLAYING
# (egress v1.9, `updateStartTime`) ; `EgressInfo.updated_at` est posé à cet
# instant dans le processus egress (protocole LiveKit, `UpdateStatus`),
# indépendamment du délai de livraison du webhook. D'après le journal egress
# des Cafés #7 et #8, PLAYING suit l'abonnement de 50 ms pour un micro, et
# pour une caméra survient à l'arrivée de la première image clé : c'est
# l'instant qui suit le début réel du fichier, à l'écart résiduel près
# (ParticipantMux::VIDEO_ACTIVATION_LAG).
#
# Pas `file_results[].started_at` (aussi dans egress_ended) : c'est l'arrivée
# du premier paquet RTP, avant l'image clé ; il ramènerait le défaut.
class EgressActivationJob < ApplicationJob
  queue_as :default

  ACTIVE = "EGRESS_ACTIVE"

  def perform(info)
    return unless info.is_a?(Hash) && info["status"] == ACTIVE && info["egress_id"].present?

    activated_at = Integer(info["updated_at"].to_s, exception: false)
    return unless activated_at&.positive?

    webinar = Webinar.find_by(room_name: info["room_name"])
    recording = webinar && Recording.for_egress_info(webinar, info)
    recording&.note_media_start(Time.at(0, activated_at, :nanosecond))
  end
end
