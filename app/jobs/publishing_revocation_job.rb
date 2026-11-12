# Retrait du droit de publier d'une personne que PublishPermission ne laisse
# plus publier (sans accord à l'image en cours, ou spectateur sans la parole),
# quand la salle LiveKit n'a pas répondu : après un retrait d'accord
# (ConsentWithdrawal), ou à l'arrivée dans la salle avec un jeton qui publie
# (webhook participant_joined). Essais bornés ; au-delà,
# l'animateur propriétaire est alerté par mail, l'erreur est journalisée, et
# le job échoue (visible dans les jobs en échec de Solid Queue).
#
# Les pistes séparées sont déjà arrêtées et n'ont plus le droit de démarrer :
# ce job ne retire que la publication dans la salle, d'où le composite et la
# transcription tirent l'image et la voix. La règle entière (accord ET
# parole) est relue sous le verrou des mains levées juste avant de fermer :
# qui peut de nouveau publier entre-temps (nouvel accord,
# parole donnée) garde son droit ; un spectateur avec accord mais sans la
# parole, revenu avec un ancien jeton qui publie, est fermé.
class PublishingRevocationJob < ApplicationJob
  ATTEMPTS = 5

  queue_as :default

  retry_on RoomServiceClient::Error, wait: :polynomially_longer, attempts: ATTEMPTS do |job, error|
    webinar, holder = job.arguments
    Rails.logger.error(
      "[publishing_revocation] droit de publier toujours ouvert après #{ATTEMPTS} essais " \
      "webinar=#{webinar.id} holder=#{holder.class.name}-#{holder.id} err=#{error.class}"
    )
    ConsentMailer.revocation_failed(webinar, holder).deliver_later
    raise error
  end
  discard_on ActiveJob::DeserializationError

  def perform(webinar, holder)
    ConsentWithdrawal.new(webinar, holder).revoke_publishing!
  end
end
