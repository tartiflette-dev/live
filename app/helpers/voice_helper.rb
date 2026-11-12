# Libellés d'une page dans la tonalité de son émission (`Voice`). La
# tonalité vient de `@voice`, posée par le contrôleur ; absente = défaut.
# Passe par `translate` d'ActionView : une clé `_html` reste sûre (les
# valeurs interpolées sont échappées, sauf celles déjà html_safe). Le nom de
# l'organisation est toujours fourni (OrganizationHelper).
module VoiceHelper
  def voice_t(key, voice: @voice, **options)
    primary, *fallbacks = Voice.keys(key, voice)
    t(primary, default: fallbacks.map(&:to_sym), locale: Voice::LOCALE, **organization_interpolations(key), **options)
  end

  # Date d'un webinaire au format de la tonalité (`voices.*.date_format`,
  # nom d'un format `time.formats`) : celui des mails de l'émission.
  def voice_l(time, voice: @voice)
    l(time, format: voice_t("date_format", voice: voice).to_sym)
  end
end
