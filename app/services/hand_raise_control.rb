# Permission changes and webinar end serialize across local
# workers. No SQLite transaction is held while LiveKit responds.
#
# Accord à l'image : donner la parole n'ouvre la
# publication LiveKit qu'au spectateur qui a un accord en cours
# (PublishPermission). Sans accord, sa main passe « accordée » et la salle
# lui montre la fenêtre de consentement ; son accord ouvre la publication.
# Ouvrir, fermer ou remettre d'accord la publication d'après l'accord passe
# aussi par ce verrou (`*_publication*`) : parole et accord y sont relus juste
# avant l'appel LiveKit, qu'une parole retirée en même temps ne peut devancer.
class HandRaiseControl
  class Conflict < StandardError; end
  class PaymentRequired < StandardError; end

  def initialize(webinar, client: nil)
    @webinar = webinar
    @client = client
  end

  def raise_hand(registration)
    synchronize { open_hand(registration) }
  end

  # Main pré-déclarée (lien public, choix « participant ») :
  # levée d'office à la PREMIÈRE entrée dans la salle, pour que l'animation
  # l'admette (`grant`). Jamais relevée ensuite : une main baissée, refusée
  # ou rendue le reste. Sans effet pour un spectateur, hors direct, sans
  # accès à la salle ou sans paiement : l'entrée ne dépend pas de la main.
  # @return [HandRaise, nil]
  def raise_declared_hand(registration)
    return unless registration.participant?

    synchronize do
      open_hand(registration) unless @webinar.hand_raises.exists?(registration: registration)
    end
  rescue Conflict, PaymentRequired
    nil
  end

  # Choix fait à l'entrée de la salle (ParticipationsController), geste de
  # la personne : « Je participe » lève la main, même si une main plus
  # ancienne a été baissée ou refusée (c'est un nouveau choix) ; « J'observe »
  # baisse la main encore en attente. Une parole accordée ou en cours
  # d'attribution reste : l'animation la retire. Sans effet hors direct,
  # sans accès à la salle ou sans paiement, comme `raise_declared_hand`.
  # Le choix est relu sous le verrou : de deux choix envoyés ensemble, la main
  # suit celui que la base a gardé.
  # @return [HandRaise, nil] « Je participe » : la main active (levée ou déjà
  #   là) ; « J'observe » : la main baissée ; nil sinon (pas de main en
  #   attente, hors direct, sans accès, sans paiement)
  def follow_participation(registration)
    synchronize do
      next open_hand(registration) if registration.reload.participant?

      hand = @webinar.hand_raises.waiting.find_by(registration: registration)
      revoke_hand(hand) if hand
    end
  rescue Conflict, PaymentRequired
    nil
  end

  def lower_hand(registration)
    synchronize do
      hand = @webinar.hand_raises.active.find_by(registration: registration)
      revoke_hand(hand) if hand
    end
  end

  # Avec un accord à l'image, une main déjà accordée est ré-accordée :
  # LiveKit reçoit de nouveau la permission (participant revenu avec un jeton
  # émis avant l'accord, ou permission perdue côté salle). Sans accord, la
  # main passe accordée et la salle montre la fenêtre de consentement, dont
  # le POST ouvre la publication.
  def grant(hand_id)
    synchronize do
      ensure_live!
      hand = @webinar.hand_raises.active.find(hand_id)
      raise Conflict, "registration lost its room access" unless hand.registration.room_access?
      ensure_payment!(hand.registration)
      next change_permission(hand, publish: true) if permission.consented?(hand.registration)
      next hand if hand.state == "granted"

      hand.update!(state: "granted", granted_at: Time.current, last_error: nil)
      hand
    end
  end

  def revoke(hand_id)
    synchronize do
      hand = @webinar.hand_raises.find(hand_id)
      hand.revoked_at ? hand : revoke_hand(hand)
    end
  end

  # Personne retirée de la salle (ParticipantModeration) : sa main se
  # referme sans appel à LiveKit, qui l'expulse de toute façon. Sous le même
  # verrou qu'un `grant` concurrent, qui ne la rouvrira plus (room_access?).
  def drop_hand(registration)
    synchronize do
      @webinar.hand_raises.active.where(registration: registration).find_each do |hand|
        hand.update!(state: "revoked", revoked_at: Time.current, last_error: nil)
      end
    end
  end

  # @return [Boolean] publication ouverte (PublishPermission#open!)
  def open_publication(record)
    synchronize { permission.open!(record) }
  end

  # Retrait du droit de publier (ConsentWithdrawal, PublishingRevocationJob) :
  # la règle est relue SOUS ce verrou, juste avant l'appel
  # LiveKit ; qui peut publier maintenant (accord et parole) le garde. Sinon
  # une main en cours (accordée, en vol, incertaine) se referme, ce qui
  # retire la permission ; à défaut la publication est fermée. Une main
  # seulement en attente reste levée, et la publication est fermée quand
  # même : refermer cette main n'appellerait pas LiveKit, alors qu'un ancien
  # jeton peut publier.
  # @return [Boolean] droit retiré ; false s'il est gardé, ou si la personne
  #   n'est pas dans la salle
  # @raise [RoomServiceClient::Error] salle injoignable
  def close_publication_unless_allowed(record)
    synchronize do
      next false if permission.allowed?(record)

      hand = @webinar.hand_raises.active.where.not(state: "waiting").find_by(registration: record) if record.is_a?(Registration)
      next permission.close!(record) unless hand

      revoke_hand(hand)
      true
    end
  end

  def reconcile_publication(identity, publishing:)
    synchronize { permission.reconcile_on_join(identity, publishing: publishing) }
  end

  def end_webinar
    synchronize do
      raise Webinar::TransitionError, "webinaire pas en live (état: #{@webinar.state}) — end refusé" unless @webinar.live?

      @webinar.update!(state: "ended", ended_at: Time.current, room_empty_since: nil)
      @webinar.hand_raises.active.find_each do |hand|
        begin
          revoke_hand(hand)
        rescue RoomServiceClient::Error => error
          Rails.logger.error("hand_raise end revocation failed webinar=#{@webinar.id} hand=#{hand.id} error=#{error.class}")
        end
      end
    end
  end

  private

  def open_hand(registration)
    ensure_live!
    registration.reload
    raise Conflict, "registration with room access required" unless registration.room_access? && registration.webinar_id == @webinar.id
    ensure_payment!(registration)

    @webinar.hand_raises.active.find_or_create_by!(registration: registration) do |hand|
      hand.raised_at = Time.current
    end
  end

  def synchronize
    directory = Rails.root.join("storage", "hand_raise_locks")
    FileUtils.mkdir_p(directory)
    File.open(directory.join("#{@webinar.id}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      @webinar.reload
      yield
    end
  end

  def ensure_live!
    raise Conflict, "webinar must be live and published" unless @webinar.live? && @webinar.visibility_published?
  end

  def ensure_payment!(registration)
    raise PaymentRequired, "payment confirmation required" unless @webinar.free? || registration.paid_confirmed?
  end

  def revoke_hand(hand)
    if hand.state == "waiting"
      hand.update!(state: "revoked", revoked_at: Time.current, last_error: nil)
      hand
    else
      change_permission(hand, publish: false)
    end
  end

  def permission
    @permission ||= PublishPermission.new(@webinar, client: @client)
  end

  def change_permission(hand, publish:)
    hand.update!(state: publish ? "granting" : "revoking", last_error: nil)
    begin
      permission.update!(hand.registration, publish: publish)
    rescue RoomServiceClient::Error => error
      hand.update!(state: "uncertain", last_error: error.class.name)
      raise
    end
    if publish
      hand.update!(state: "granted", granted_at: Time.current)
    else
      hand.update!(state: "revoked", revoked_at: Time.current)
    end
    hand
  end
end
