# Marque d'envoi d'une annonce de WebinarChangeNotice à une inscription :
# posée AVANT la mise en file du mail, unique par annonce (révision) et
# destinataire. `kind` : rescheduled | cancelled.
class WebinarChangeDelivery < ApplicationRecord
  belongs_to :webinar_change_notice, inverse_of: :deliveries
  belongs_to :registration
end
