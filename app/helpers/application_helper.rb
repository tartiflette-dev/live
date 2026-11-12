module ApplicationHelper
  # Texte masqué pour un lien qui ouvre un autre onglet. L'espace initial
  # sépare du mot précédent (« confidentialité (nouvel onglet) »).
  def new_tab_hint
    safe_join([ " ", tag.span("(nouvel onglet)", class: "visually-hidden") ])
  end

  # Rotation de langue : langue suivante dans I18n.available_locales.
  def locale_switch_path(locale)
    q = request.query_parameters.merge("locale" => locale.to_s)
    "#{request.path}?#{q.to_query}"
  end

  def next_locale(current: I18n.locale)
    order = I18n.available_locales.map(&:to_sym)
    return current if order.length <= 1

    idx = order.index(current.to_sym) || 0
    order[(idx + 1) % order.length]
  end

  def locale_label(locale)
    t("chrome.lang_#{locale}", default: locale.to_s.upcase)
  end

  # Rotation de langue au format du composant `undust/charte/langue` (chrome
  # v3 de la gem). Pas de `lang` sur le bouton : son libellé est la
  # langue courante, déjà portée par <html lang>.
  def chrome_langue
    libelle_suivant = t("chrome.language_next", lang: locale_label(next_locale))
    {
      href: locale_switch_path(next_locale),
      libelle: locale_label(I18n.locale),
      titre: libelle_suivant,
      data: { turbo: false }
    }
  end

  # Favicon d'environnement : l'hôte staging (StagingHost : APP_HOST
  # parmi STAGING_HOSTS) reçoit le cadre orange, le
  # développement le cadre status-critical, la prod le cadre thème (SVG auto).
  # Le bandeau, lui, reste prod.
  def favicon_href
    return "/icon-dev.svg" if Rails.env.development?
    return "/icon-stg.svg" if StagingHost.current?

    asset_path(Brand.favicon)
  end
end
