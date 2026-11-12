class MarketingWithdrawalsController < ApplicationController
  # Retrait du consentement marketing — jeton distinct, persistant, émis
  # au moment du consentement effectif. Permet la promesse « retrait à
  # tout moment » de /confidentialite SANS passer par un email contact.
  #
  # Mêmes contraintes sécurité que MarketingConsentsController : GET
  # sans effet, POST protégé CSRF via button_to, jeton en query string,
  # pas de PII à l'écran, Referrer-Policy strict-origin (TokenLinkPage).
  include TokenLinkPage

  NOTIFY_NEXT_TITLE = "« préviens-moi du prochain Café IA »".freeze
  WITHDRAWN_WEBINAR_TITLE = "un café qui n'est plus au programme".freeze

  def show
    holder = consent_holder
    return render :invalid, status: :not_found unless holder

    @voice = voice_of(holder)
    return render :already_withdrawn unless holder.marketing_consent?

    @webinar_title = title_of(holder)
  end

  def create
    holder = consent_holder
    return render :invalid, status: :not_found unless holder

    @voice = voice_of(holder)

    # Sérialisation garantie 2 : verrou atomique sur la
    # ligne. Un consentement concurrent arrivé avant ce verrou aura
    # posé `marketing_consent=true` → le retrait l'écrase. Un consentement
    # concurrent arrivé APRÈS ce verrou verra `marketing_consent_withdrawn_at`
    # posé et refusera (via `grant_marketing_consent!`). État final =
    # retiré, quelle que soit la fenêtre d'arrivée.
    withdrawn = withdraw(holder)
    return render :already_withdrawn if withdrawn.empty?

    # Propagation : on enqueue TOUJOURS
    # dès que la synchro CRM est active, SANS filtrer sur `crm_pushed?`.
    # Raison : si `CrmSyncJob` a créé le contact côté CRM mais a
    # abandonné avant la pose de `pushed_to_crm_at` (retrait concurrent),
    # `crm_contact_id` est renseigné mais `crm_pushed?` false — le
    # contact serait orphelin consentant côté CRM sans aucune
    # propagation. Le job de retrait sait retrouver le contact par email
    # au besoin ; il est idempotent (`crm_withdrawal_pushed_at`) et
    # no-op si aucun contact n'existe côté CRM. Une demande « préviens-moi »
    # propage le sien par CrmNotifyNextJob, qui porte toute sa synchro.
    enqueue_crm_withdrawals(withdrawn) if ENV["CRM_SYNC_ENABLED"] == "1"

    @webinar_title = title_of(holder)
    render :created
  end

  private

  # Le jeton désigne une inscription (case /mc ou café d'une demande) ou
  # une demande « préviens-moi » sans café (politique v1.6). Le droit
  # d'opposition ne dépend pas du café : une inscription à un café dépublié
  # (annulé) se retire comme les autres, sous un titre neutre.
  def consent_holder
    registration = Registration.find_by_marketing_withdrawal_token(params[:t])
    return registration if registration

    request = RegistrationRequest.find_by_marketing_withdrawal_token(params[:t])
    request if request&.confirmed?
  end

  # Tonalité (Voice) : celle du café, ou de la demande « préviens-moi ».
  def voice_of(holder)
    holder.is_a?(Registration) ? holder.webinar.voice : holder.voice
  end

  def title_of(holder)
    return NOTIFY_NEXT_TITLE unless holder.is_a?(Registration)

    holder.webinar.visibility_published? ? holder.webinar.title : WITHDRAWN_WEBINAR_TITLE
  end

  # Le retrait vaut pour la personne — à
  # condition que CE jeton porte encore un consentement, sans quoi un lien
  # déjà utilisé retirerait autre chose que ce qu'il désigne.
  def withdraw(holder)
    return [] unless holder.with_lock { holder.withdraw_marketing_consent! }

    [ holder, *Registration.withdraw_marketing_consent_of(holder.email),
      *RegistrationRequest.withdraw_marketing_consent_of(holder.email) ]
  end

  def enqueue_crm_withdrawals(withdrawn)
    withdrawn.each do |item|
      if item.is_a?(Registration)
        CrmMarketingWithdrawalJob.perform_later(item.id)
      else
        CrmNotifyNextJob.perform_later(item.id)
      end
    end
  end
end
