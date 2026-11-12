# Lien entre une question de la file Q&R et un message du chat qui la pose.
# Un message ne nourrit qu'une question : l'unicité
# (index + validation) rend QaExtractionJob rejouable sans doublon.
class QaItemMessage < ApplicationRecord
  belongs_to :qa_item, inverse_of: :qa_item_messages
  belongs_to :message

  validates :message_id, uniqueness: true
end
