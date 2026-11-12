# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = "1.0"

# Fichiers servis par le pack de thème (themes/<nom>/assets/ seulement : logo,
# favicon, polices) ; aucun pour le thème undust, servi par la gem.
Rails.application.config.assets.paths.concat(Theme.current.asset_paths)
