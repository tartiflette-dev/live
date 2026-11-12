# Une instance de production démarre avec ses propres réglages ou pas du tout
# (lib/instance_settings.rb). La compilation des assets (SECRET_KEY_BASE_DUMMY)
# n'a pas d'environnement de déploiement : elle n'est pas concernée.
if Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank?
  Rails.application.config.after_initialize { InstanceSettings.assert_complete! }
end
