# frozen_string_literal: true

# Un aperçu par tonalité (Voice) du mail du lien d'agenda personnel. Objet non
# enregistré : l'aperçu n'écrit rien en base.
class CalendarSubscriptionMailerPreview < ActionMailer::Preview
  TOKEN = "PREVIEWTOKEN0000000000000000abcd"

  def feed_link_cafe_ia
    CalendarSubscriptionMailer.feed_link(subscription, name: "Camille", voice: "cafe_ia")
  end

  def feed_link_par_defaut
    CalendarSubscriptionMailer.feed_link(subscription, name: "Camille", voice: Voice::DEFAULT)
  end

  private

  def subscription
    CalendarSubscription.new(email: "spectateur@example.test", token: TOKEN)
  end
end
