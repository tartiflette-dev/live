class ApplicationController < ActionController::Base
  # `allow_browser versions: :modern` n'est PAS posé ici (défaut Rails 8) :
  # il rendrait 406 aux navigateurs < Chrome 120 / Safari 17.2 / Firefox 121
  # sur les pages PUBLIQUES (/w/:slug, /w/:slug/join) ET sur POST /api/token
  # que ces pages appellent — un spectateur d'entreprise au navigateur figé
  # serait exclu du webinaire sans recours. Le garde-fou est posé dans les
  # controllers ANIMATEUR seulement (Webinars CRUD/stage, Recordings,
  # Sessions), cf. `AnimateurBrowserPolicy`. Le client LiveKit v2 impose
  # de lui-même un plancher WebRTC bien plus bas que :modern.

  # Helpers d'authentification animateur. Les controllers
  # spectateur (NG-2 spec) N'appellent PAS `authenticate_animateur!`.
  include Authenticatable

  # Langue : rotation fr → en → fr (partial shared/locale_rotate),
  # persistée en cookie ; `html[lang]` posé par les layouts.
  around_action :switch_locale

  private

  def switch_locale(&action)
    locale = pick_locale
    if params[:locale].present? && locale.to_s == params[:locale].to_s
      cookies[:locale] = { value: locale, expires: 1.year.from_now, same_site: :lax, path: "/" }
    end
    I18n.with_locale(locale, &action)
  end

  def pick_locale
    available = I18n.available_locales.map(&:to_s)
    wanted = [ params[:locale], cookies[:locale] ].filter_map { |v| v.to_s.presence }
    (wanted.find { |v| available.include?(v) } || I18n.default_locale).to_sym
  end
end
