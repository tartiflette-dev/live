# Destinataires d'un envoi groupé (Announcement), par cible
# (docs/announcements.md). `AnnouncementAudience.for` est le SEUL aiguillage
# sur le type de cible : tout ce qui en dépend vit dans sa classe.
#   • `recipients`           — qui reçoit, UNE fois par adresse (dédoublonné),
#     triés par adresse ;
#   • `recipient_for(email)` — cette adresse en fait-elle ENCORE partie ?
#     Relu au moment de la remise de chaque mail : un retrait ou un arrêt
#     arrivé entre la confirmation et la remise exclut la personne sur-le-champ ;
#   • `footer_url(holder, routes)` — le lien personnel du pied : accès au
#     webinaire, retrait du consentement, ou arrêt du « préviens-moi » ;
#   • `stop_link?` — ce lien arrête-t-il les envois (en-tête List-Unsubscribe) ;
#   • `voice` — la tonalité du mail.
#
# Un destinataire porte la fiche qui fournit son adresse (`holder`) :
# inscription (Registration) ou demande (RegistrationRequest). C'est elle qui
# donne le lien du pied.
module AnnouncementAudience
  Recipient = Data.define(:email, :holder)

  def self.for(announcement)
    case announcement.audience
    when "webinar_registrants" then WebinarRegistrants.new(announcement.webinar)
    when "marketing_list"      then MarketingList.new(announcement.webinar)
    when "notify_next"         then NotifyNext.new(announcement.webinar)
    end
  end

  # Partie commune : dédoublonnage par adresse, la première fiche trouvée
  # porte la personne. Les sous-classes donnent `holders(narrowing)`, qui
  # applique `narrowing` à chacune de leurs requêtes : `EVERYONE` pour toute la
  # cible, `only(email)` pour une adresse.
  class Base
    EVERYONE = ->(scope) { scope }

    def initialize(webinar)
      @webinar = webinar
    end

    def recipients
      to_recipients(holders(EVERYONE)).sort_by(&:email)
    end

    def recipient_for(email)
      return nil if email.blank?

      to_recipients(holders(only(email))).first
    end

    def stop_link?
      true
    end

    def voice
      @webinar.voice
    end

    private

    def only(email)
      ->(scope) { scope.where(email: email) }
    end

    def to_recipients(holders)
      holders.uniq(&:email).map { |holder| Recipient.new(email: holder.email, holder: holder) }
    end
  end

  # (a) Inscrits confirmés d'UN webinaire — « sur place » quand c'est le
  # webinaire du jour. Message de service : ni consentement exigé, ni lien de
  # retrait ; le pied rappelle l'accès personnel : la salle, ou le replay une
  # fois publié (ReplayAccess). Jamais une inscription retirée de la salle par
  # l'animation, ni une pierre tombale.
  class WebinarRegistrants < Base
    def stop_link?
      false
    end

    def footer_url(holder, routes)
      return routes.public_webinar_replay_url(@webinar.slug, t: holder.token) if @webinar.replay&.published?

      routes.confirm_registration_url(holder.token)
    end

    private

    def holders(narrowing)
      scope = @webinar.registrations.confirmed.where(room_removed_at: nil, retired_email_digest: nil)
      narrowing.call(scope).order(:id).to_a
    end
  end

  # (b) La liste : consentement marketing ACTIF, sur une inscription (quel
  # que soit son café) ou sur une demande « préviens-moi » confirmée — les
  # fiches dont le lien de retrait fonctionne
  # (MarketingWithdrawalsController#consent_holder) : sans lien de retrait,
  # pas d'envoi.
  class MarketingList < Base
    def footer_url(holder, routes)
      routes.marketing_withdrawal_url(t: holder.marketing_withdrawal_token)
    end

    private

    def holders(narrowing)
      registrations = Registration.where(marketing_consent: true, retired_email_digest: nil)
                                  .where.not(marketing_withdrawal_token: nil)
      requests = RegistrationRequest.where.not(confirmed_at: nil).where(marketing_consent: true)
                                    .where.not(marketing_withdrawal_token: nil)
      [ registrations, requests ].flat_map { |scope| narrowing.call(scope).order(:id).to_a }
    end
  end

  # (c) Demandes « préviens-moi du prochain Café IA » confirmées, jamais
  # arrêtées par le lien de ces mails (`notify_next_stopped_at`). La personne
  # a demandé ce mail ; mais qui a dit stop au recontact (retrait, qui vaut
  # pour la personne entière) en est exclu, sauf accord redonné depuis.
  # Tonalité Café IA : la demande vise le prochain Café IA.
  class NotifyNext < Base
    def voice
      "cafe_ia"
    end

    def footer_url(holder, routes)
      routes.notify_next_stop_url(t: holder.generate_token_for(:notify_next_stop))
    end

    private

    def holders(narrowing)
      scope = RegistrationRequest.where.not(confirmed_at: nil).where(notify_next: true, notify_next_stopped_at: nil)
      requests = narrowing.call(scope).order(:id).to_a
      stopped = stopped_emails(requests.map(&:email).uniq)
      requests.reject { |request| stopped.include?(request.email) }
    end

    def stopped_emails(emails)
      withdrawn = [ Registration, RegistrationRequest ].flat_map do |model|
        model.where(email: emails).where.not(marketing_consent_withdrawn_at: nil).distinct.pluck(:email)
      end
      consenting = [ Registration, RegistrationRequest ].flat_map do |model|
        model.where(email: emails, marketing_consent: true).distinct.pluck(:email)
      end
      withdrawn.to_set - consenting
    end
  end
end
