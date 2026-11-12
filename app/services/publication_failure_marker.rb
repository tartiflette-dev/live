# frozen_string_literal: true

# PublicationFailureMarker — marqueur d'une publication Nextcloud en échec,
# destiné à une supervision externe de l'hôte (facultative, non distribuée
# avec l'application : docs/replays.md, « Publications en échec »), qui peut
# en tirer une alerte ; l'application ne le lit jamais. Même contrat par
# fichiers que les versions légères (LightVersion), relatif à
# RECORDINGS_ROOT :
#   _publication/echecs/<publication id>.json
# écrit à chaque passage en échec (`EpisodePublication#fail!`), retiré quand
# un dépôt aboutit (`complete!`). Sans lui, une publication en échec (mot de
# passe révoqué, partage retiré, Nextcloud en panne) ne se voyait que sur la
# page du webinaire.
#
# La sonde n'alerte qu'une fois par publication et par raison (`digest`,
# calculé sur la raison affichée, pas sur le message de la page) : les
# relances qui échouent pareil (retry_on), même sur un autre fichier, ne font
# pas de rafale. Le marqueur ne porte pas le nom du fichier en cause (il
# porte celui d'un participant) : seulement la raison, le webinaire et le
# lien de sa page.
#
# Écrire le marqueur ne doit jamais masquer l'échec qu'il signale : une
# erreur d'écriture est journalisée, pas relancée.
class PublicationFailureMarker
  DIR = "_publication/echecs"
  REASON_LIMIT = 300

  def initialize(publication)
    @publication = publication
  end

  def write!(reason)
    path = self.path
    FileUtils.mkdir_p(path.dirname)
    tmp = path.dirname.join(".#{path.basename}.#{SecureRandom.hex(4)}.tmp")
    tmp.write("#{JSON.generate(content(reason))}\n")
    File.rename(tmp, path)
  rescue StandardError => error
    Rails.logger.warn("[publication] marqueur d'échec non écrit (publication #{@publication.id}) : #{error.class}")
    FileUtils.rm_f(tmp) if tmp
  end

  def clear!
    File.delete(path)
  rescue Errno::ENOENT
    nil
  rescue StandardError => error
    Rails.logger.warn("[publication] marqueur d'échec non retiré (publication #{@publication.id}) : #{error.class}")
  end

  def path
    Recording.recordings_root.cleanpath.join(DIR, "#{@publication.id}.json")
  end

  private

  def content(reason)
    webinar = @publication.webinar
    reason = reason.to_s.truncate(REASON_LIMIT)
    { publication_id: @publication.id, webinar_id: webinar.id, webinar: webinar.title, page: page_url(webinar),
      reason: reason, digest: Digest::SHA256.hexdigest(reason)[0, 16], failed_at: Time.current.utc.iso8601 }
  end

  def page_url(webinar)
    host = Rails.application.config.action_mailer.default_url_options&.dig(:host)
    path = Rails.application.routes.url_helpers.webinar_path(webinar)
    host.present? ? "https://#{host}#{path}" : path
  end
end
