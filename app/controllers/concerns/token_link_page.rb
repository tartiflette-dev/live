# Pages ouvertes par un lien porteur de jeton (`?t=` ou `/r/:token`) et
# dont l'effet passe par un bouton POST : /confirmer, /mc, /mc/withdraw,
# /r/:token. `no-store` : la page ne reste dans aucun cache.
#
# `Referrer-Policy: strict-origin`, PAS `no-referrer` : sous `no-referrer`
# le navigateur envoie `Origin: null` sur le POST du bouton et la
# protection CSRF de Rails (`forgery_protection_origin_check`) le rejette —
# régression E2E, aucune confirmation possible. `strict-origin`
# n'envoie que l'origine (jamais le chemin ni la query, donc jamais le
# jeton), y compris vers nos propres journaux, et rien du tout vers HTTP.
# `same-origin` aurait mis l'URL complète, jeton compris, dans le Referer
# du POST.
module TokenLinkPage
  extend ActiveSupport::Concern

  included do
    before_action :protect_token_link_page
  end

  private

  def protect_token_link_page
    response.headers["Referrer-Policy"] = "strict-origin"
    response.headers["Cache-Control"]   = "no-store"
  end
end
