# Site public de la série que l'instance anime (Brand.series), dans les mails
# de sa tonalité (gabarits `+cafe_ia`) : là où envoyer quelqu'un, et ce que
# signe le mail. Sans site de série configuré, l'agenda public de l'instance.
module SeriesHelper
  def series_url
    Brand.series.url.presence || agenda_url
  end

  # « exemple.org » : texte du lien et signature.
  def series_host
    URI.parse(series_url).host
  end
end
