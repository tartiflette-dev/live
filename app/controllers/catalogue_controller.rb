class CatalogueController < ApplicationController
  # Catalogue public des webinaires (face publique).
  #
  # Racine PUBLIQUE : liste les webinaires `visibility: published` en
  # direct, en retard puis à venir (groupes disjoints définis sur Webinar,
  # cf. LATE_START_WINDOW). Aucune session requise. Controller DÉDIÉ —
  # WebinarsController reste animateur (`authenticate_animateur!`,
  # `AnimateurBrowserPolicy`, scope host_sub) et n'est PAS branché en mode
  # public (deux acteurs différents = deux controllers).
  #
  # Pas d'`authenticate_animateur!` et pas d'`AnimateurBrowserPolicy` ici :
  # un visiteur au navigateur figé (poste d'entreprise) DOIT pouvoir
  # consulter le catalogue — même raisonnement que pour /w/:slug (cf.
  # ApplicationController).
  def index
    now = Time.current
    published = Webinar.published.includes(:pack, :host_attendances, :webinar_hosts)
    @live_webinars          = published.live.order(starts_at: :asc).to_a
    @starting_late_webinars = published.starting_late(now).to_a
    @upcoming_webinars      = published.upcoming(now).to_a
  end
end
