# Fiche d'une personne sur tous les cafés (PersonActivity) : inscriptions,
# visionnages des replays, questions, réponses aux sondages, recherches, et
# lien vers sa fiche dans le CRM quand elle existe. `:id` = clé
# PersonActivity.key_for ; inconnue → 404.
module Animation
  class PeopleController < BaseController
    def show
      @person = PersonActivity.find(params[:id])
      raise ActiveRecord::RecordNotFound unless @person
    end
  end
end
