# Liens de la page animateur d'un webinaire (constat en direct : un
# partage d'écran a montré les jetons des liens intervenants).
#
# Un lien secret (invitation partagée, lien personnel d'intervenant) ne
# s'affiche que masqué ; son URL complète vit seulement dans l'attribut
# `data-copy-link` du bouton « Copier le lien » (app/javascript/copy_link.js),
# jamais dans un title, une valeur de champ ni un texte visible.
module WebinarLinksHelper
  TOKEN_MASK = "••••••••".freeze

  # Forme lisible d'un lien dont le paramètre `t` est le secret :
  # `live.example.org/w/cafe-ia-7/join?t=••••••••`.
  def masked_token_link(url)
    uri = URI.parse(url)
    port = ":#{uri.port}" unless uri.port == uri.default_port
    "#{uri.host}#{port}#{uri.path}?t=#{TOKEN_MASK}"
  end

  # `status_id` désigne la zone `copy_link_status` qui annonce le résultat.
  # `primary` : bouton principal de la page (avant le direct, le lien public).
  def copy_link_button(url, status_id:, role:, label: "Copier le lien", primary: false)
    tag.button label, type: "button", class: primary ? "btn" : "btn btn--secondary",
                      aria: { controls: status_id }, data: { copy_link: url, role: role }
  end

  def copy_link_status(id)
    tag.span id: id, role: "status", aria: { live: "polite" }
  end

  # Échéance des liens participants (partagé et personnels), page animateur.
  # Pendant le direct, pas de date : la reprendre rouvre les jetons.
  def links_expiry_notice(webinar, now: Time.current)
    grace = Webinar.link_access_grace_label
    if webinar.live?
      "Valables pendant le direct, puis encore #{grace} après la fin."
    elsif (deadline = webinar.link_access_deadline)
      stamp = l(deadline, format: :jour_heure)
      if webinar.ended?
        webinar.link_access_open?(now) ? "Expirent le #{stamp}." : "Expirés le #{stamp}."
      else
        verb = webinar.link_access_open?(now) ? "expirent" : "ont expiré"
        "Sans direct lancé, #{verb} le #{stamp}. Un direct les garde, puis encore #{grace} après sa fin."
      end
    end
  end

  HOST_INVITATION_STATUS_LABELS = {
    revoked: "révoqué", exhausted: "épuisé", expired: "expiré", ended: "inutilisable : direct terminé"
  }.freeze

  # Libellé d'un lien animateur qui ne sert plus (HostInvitation#status).
  def host_invitation_status_label(status)
    HOST_INVITATION_STATUS_LABELS.fetch(status)
  end
end
