# Libellé du bouton d'accord RÉELLEMENT affiché, figé à l'accord :
# une page /confirmer parle dans la tonalité de son
# émission (Voice), la preuve CRM cite ce que la personne a vu. Additive :
# lignes antérieures nulles = libellé par défaut, seul affiché jusque-là.
class AddMarketingConsentLabel < ActiveRecord::Migration[8.1]
  def change
    add_column :registrations, :marketing_consent_label, :string
    add_column :registration_requests, :marketing_consent_label, :string
  end
end
