# Nom de l'organisation qui opère l'instance (Brand.organization) dans les
# vues et les mails. L'apostrophe de l'élision appartient au texte, pas au
# nom : « qu'Acme » s'écrit tel quel, seul le nom est échappé — en HTML
# seulement : un gabarit texte (partie text/plain d'un mail) n'échappe rien.
module OrganizationHelper
  # « qu'Acme », « que Studio Exemple » (`word` = "que", "de").
  def organization_after(word)
    return Brand.elision(word) + Brand.organization if text_template?

    Brand.elision(word).html_safe + Brand.organization
  end

  # Variables %{organization}, %{que_organization}, %{de_organization} d'un
  # libellé. Clé `_html` : translate échappe les valeurs non sûres, d'où les
  # formes élidées déjà sûres.
  def organization_interpolations(key)
    return Brand.interpolations unless key.to_s.match?(/(?:_|\b)html\z/)

    Brand.interpolations.merge(que_organization: organization_after("que"), de_organization: organization_after("de"))
  end

  private

  def text_template?
    @current_template&.format == :text
  end
end
