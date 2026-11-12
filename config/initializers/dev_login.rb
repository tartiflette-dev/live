# Refus de démarrer une instance qui ouvrirait la connexion sans fournisseur
# (lib/dev_login.rb) : drapeau posé en production, ou réseaux admis hors des
# plages privées.
DevLogin.assert_not_in_production!
DevLogin.assert_safe_networks!
