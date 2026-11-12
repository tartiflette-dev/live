# Signal d'erreurs applicatif commun : une ligne JSON
# `msg=AppError` sur stdout par erreur rapportée à Rails.error (requêtes, jobs,
# appels explicites), sans donnée personnelle. Cf. lib/app_error_subscriber.rb.
#
# after_initialize : la classe est autochargée depuis lib/ (config.autoload_lib),
# ce qui n'est pas permis pendant l'exécution des initializers.
#
# stdout synchrone : dans le conteneur stdout est un tube, tamponné par défaut ;
# chaque ligne doit partir en une seule écriture, au moment de l'erreur.
Rails.application.config.after_initialize do
  $stdout.sync = true
  Rails.error.subscribe(AppErrorSubscriber.new)
end
