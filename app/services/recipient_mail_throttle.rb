# Limite par DESTINATAIRE des mails envoyés à une adresse que personne n'a
# prouvée : le formulaire et l'API sont
# anonymes, quiconque peut y saisir l'adresse d'un tiers. La limite par IP
# seule laisse un attaquant arroser une boîte depuis plusieurs IP, et
# retourner à l'envoi tout mail déjà envoyé.
#
# MODÈLE : on n'empêche JAMAIS un mail qui
# prouve la boîte ; on accepte une inondation résiduelle BORNÉE par le nombre
# de webinaires ouverts à l'inscription, qui est petit. Chaque mail relève d'un
# budget, tous comptés par adresse et par « flux » (`scope` : UNE inscription,
# les liens intervenant d'UN webinaire) :
#
#   • `:unproven` — confirmations ordinaires à une adresse non prouvée
#     (renvoi, resoumission, demande de l'API sans inscription neuve) : par
#     flux, 1 mail toutes les `INTERVAL` et au plus `SCOPE_CAP` par 24 h ; ET
#     au total, tous flux confondus, au plus `DAILY_TOTAL_CAP` par 24 h (sans ce
#     total, répartir les soumissions sur N flux multiplierait le plafond par N).
#     Exception `first_of:` : la PREMIÈRE confirmation d'une inscription
#     NOUVELLEMENT créée est exemptée du total (ni vérifiée, ni comptée) mais
#     reste soumise à la limite de son flux ; les renvois ne le sont pas.
#     CLÉ D'EXEMPTION = adresse SAISIE (minuscules) × webinaire, et non la
#     boîte canonique : une variante saisie par un tiers (`victime+x@…`) ne
#     peut pas « griller » l'exemption de la vraie personne (préemption). Une
#     adresse avec `+tag` n'est JAMAIS exemptée : elle compte dans
#     `:unproven`, donc les variantes `+N` ne peuvent pas inonder (au plus le
#     total). RÉSIDU CONNU, accepté : chaque forme à points d'une adresse gmail
#     (`v.ictime@`, `vi.ctime@`…) a sa propre exemption ; il est borné par la
#     limite IP (10 / min par IPv4 ou par /64) et par le nombre de formes.
#     Le marqueur d'exemption expire avec la fenêtre (`DAY`).
#     DÉROGATIONS ASSUMÉES, écrites telles quelles :
#       - une adresse `+tag` LÉGITIME peut être préemptée : un tiers qui remplit
#         le total `:unproven` de la boîte avec d'autres `+N` la prive de mail
#         de confirmation pendant AU PLUS 24 h (le total expire avec la
#         fenêtre) ;
#       - gmail : N formes à points d'une même adresse donnent N mails exemptés
#         (une exemption par forme saisie), bornés par la limite IP, 10 / min
#         par IPv4 ou par /64 ; un /48 contient 65 536 /64, donc un attaquant
#         qui contrôle un /48 n'est pas borné par cette limite.
#   • `:security` — le mail de confirmation qui accompagne un accès immédiat
#     (il prévient la boîte qu'on est entré avec son adresse) : par flux
#     seulement, `SCOPE_CAP` par 24 h, JAMAIS de total par adresse, donc non
#     consommable par les mails ordinaires ni par ceux d'autres flux. Il respecte
#     malgré tout l'intervalle : son envoi est inscrit dans l'historique du flux
#     `:unproven` (horodatage seul, hors total), et il est refusé si ce flux a
#     servi depuis `INTERVAL`. L'appelant conditionne l'accès immédiat à la
#     réussite de ce claim : refusé, pas d'accès, jamais d'accès sans mail
#     (PendingRegistrationMail.reserve_confirmation).
#   • `:proof` — mails de preuve demandés pour sa propre boîte (lien
#     intervenant) : budget propre par flux, hors du total partagé, SANS
#     intervalle (deux liens légitimes peuvent se suivre) : seul le plafond
#     de flux borne, d'où le 6 N ci-dessous.
#
# BOÎTE CANONIQUE : minuscules, suffixe `+tag` retiré pour tous les domaines,
# points retirés pour gmail.com et googlemail.com (googlemail ramené à
# gmail). Elle est la clé du total `:unproven` et des plafonds de flux (pas de
# l'exemption, voir plus haut) : l'adresse stockée et celle de l'envoi restent
# celles saisies.
#
# REFUS : chaque refus est journalisé (`[mail-throttle] refused`) avec le
# budget, le flux, la raison et une empreinte SHA256 tronquée de la boîte
# canonique (empreinte HMAC-SHA256 tronquée, clé dérivée de `secret_key_base`,
# donc non retrouvable par dictionnaire), jamais l'adresse. La ligne
# `[mail-throttle] refused` est prête pour une alerte de supervision (suivi).
#
# BORNE de l'inondation résiduelle, par adresse et par jour, pour N webinaires
# ouverts à l'inscription (une ligne d'inscription active par webinaire et par
# adresse ; en recréer une exige un retrait par l'animation) :
#   DAILY_TOTAL_CAP renvois  +  N premières confirmations (:unproven, first)
#   +  N accès immédiats (:security)  +  N × SCOPE_CAP liens intervenant (:proof).
#
# `claim` vérifie ET enregistre dans la même section critique
# (RegistrationRateLimitStore#synchronize, verrou de fichier partagé par
# les workers Puma) : deux requêtes simultanées ne passent pas toutes les
# deux. Aucune adresse n'est stockée en clair : les clés sont des empreintes.
# Hors de cette limite, par construction : les mails adressés à une boîte
# PROUVÉE (accès, rappel, consentement, retrait de consentement).
class RecipientMailThrottle
  INTERVAL = 10.minutes
  DAY = 24.hours
  SCOPE_CAP = 6
  DAILY_TOTAL_CAP = 10
  GMAIL_DOMAINS = %w[gmail.com googlemail.com].freeze
  LOG_DIGEST_LENGTH = 12

  # `total_cap` nil : pas de total par adresse pour ce budget ; `interval` :
  # un mail par flux toutes les INTERVAL.
  BUDGETS = {
    unproven: { scope_cap: SCOPE_CAP, total_cap: DAILY_TOTAL_CAP, interval: true },
    security: { scope_cap: SCOPE_CAP, total_cap: nil, interval: true },
    proof: { scope_cap: SCOPE_CAP, total_cap: nil, interval: false }
  }.freeze

  # Un seul mécanisme de stockage partagé par tout le processus.
  def self.default
    @default ||= new
  end

  # Vide les compteurs (tests).
  def self.reset!
    default.reset!
  end

  # Boîte canonique d'une adresse, pour les clés de limite seulement.
  # @return [String]
  def self.canonical_mailbox(email)
    local, _, domain = email.to_s.strip.downcase.rpartition("@")
    return email.to_s.strip.downcase if local.empty? || domain.empty?

    domain = "gmail.com" if GMAIL_DOMAINS.include?(domain)
    stripped = local.split("+").first.to_s
    local = stripped unless stripped.empty?
    local = local.delete(".") if domain == "gmail.com"
    "#{local}@#{domain}"
  end

  def initialize(store: RegistrationRateLimitStore.new(name: "recipient_mail_throttle"))
    @store = store
  end

  # Autorise ET enregistre un envoi à `email` pour tous les flux `scopes`,
  # sur le budget `budget`. Refusé dès qu'un flux a servi depuis `INTERVAL`
  # (budgets à intervalle) ou atteint son plafond du jour, ou que le total du
  # budget `:unproven` est atteint ; rien n'est alors enregistré. Un mail
  # couvrant plusieurs flux compte pour UN dans le total.
  # @param scopes [Array<String>] flux couverts par ce mail
  # @param budget [Symbol] `:unproven`, `:security` ou `:proof`
  # @param first_of [Array<String>] webinaires dont ce mail est la première
  #   confirmation d'une inscription neuve ; exempté du total si l'adresse
  #   saisie n'a pas de `+tag` et qu'aucun n'a déjà été exempté pour cette
  #   adresse saisie (budget `:unproven` seulement)
  # @return [Boolean] true = le mail peut partir
  def claim(email, *scopes, budget: :unproven, first_of: [], now: Time.current)
    rules = BUDGETS.fetch(budget)
    mailbox = self.class.canonical_mailbox(email)
    typed = email.to_s.strip.downcase
    return refuse(budget, scopes, mailbox, :invalid) if mailbox.empty? || scopes.empty?

    instant = now.to_f
    @store.synchronize do |cache|
      history = scopes.to_h { |scope| [ scope, recent_sends(cache.read(key(budget, mailbox, scope)), instant) ] }
      # Le flux `:unproven` porte aussi l'horodatage des accès immédiats : un
      # mail de sécurité respecte l'intervalle, jamais l'inverse du plafond.
      spaced = budget == :security ? unproven_history(cache, mailbox, scopes, instant) : history
      exempt = first_of.any? && !tagged?(typed) && first_of.none? { |webinar| cache.exist?(first_key(typed, webinar)) }
      counted = rules[:total_cap] && !exempt
      total = recent_sends(cache.read(key(budget, mailbox)), instant)

      reason = refusal_reason(rules, history, spaced, total, counted, instant)
      next refuse(budget, scopes, mailbox, reason) if reason

      history.each { |scope, sends| cache.write(key(budget, mailbox, scope), sends + [ instant ], expires_in: DAY) }
      record_in_unproven_history(cache, mailbox, scopes, instant) if budget == :security
      cache.write(key(budget, mailbox), total + [ instant ], expires_in: DAY) if counted
      first_of.each { |webinar| cache.write(first_key(typed, webinar), true, expires_in: DAY) } if exempt && budget == :unproven
      true
    end
  end

  # Empreinte HMAC-SHA256 tronquée d'une boîte canonique, pour le journal des
  # refus : jamais l'adresse, et non retrouvable par dictionnaire (clé dérivée
  # de `secret_key_base`). Publique : les tests la recalculent.
  def self.log_digest(mailbox)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key("mail-throttle-log"), mailbox)[0, LOG_DIGEST_LENGTH]
  end

  def reset!
    @store.synchronize { |cache| cache.clear }
  end

  private

  # Adresse saisie portant un `+tag` dans sa partie locale.
  def tagged?(typed)
    typed.rpartition("@").first.include?("+")
  end

  def refusal_reason(rules, history, spaced, total, counted, instant)
    return :total_cap if counted && total.size >= rules[:total_cap]
    return :scope_cap if history.values.any? { |sends| sends.size >= rules[:scope_cap] }
    :interval if rules[:interval] && spaced.values.any? { |sends| sends.last && sends.last > instant - INTERVAL }
  end

  def refuse(budget, scopes, mailbox, reason)
    digest = self.class.log_digest(mailbox)
    Rails.logger.info("[mail-throttle] refused budget=#{budget} scopes=#{scopes.join(',')} reason=#{reason} mailbox=#{digest}")
    false
  end

  def unproven_history(cache, mailbox, scopes, instant)
    scopes.to_h { |scope| [ scope, recent_sends(cache.read(key(:unproven, mailbox, scope)), instant) ] }
  end

  # Horodatage seul : hors du total `:unproven` (qui ne bouge pas).
  def record_in_unproven_history(cache, mailbox, scopes, instant)
    unproven_history(cache, mailbox, scopes, instant).each do |scope, sends|
      cache.write(key(:unproven, mailbox, scope), sends + [ instant ], expires_in: DAY)
    end
  end

  def recent_sends(sends, instant)
    Array(sends).select { |at| at > instant - DAY }
  end

  # Empreinte de (budget, boîte[, flux]) : la clé ne porte jamais l'adresse.
  def key(budget, mailbox, scope = nil)
    "sends-#{Digest::SHA256.hexdigest([ budget, mailbox, scope ].join("\n"))}"
  end

  # Marqueur « déjà exempté » de (adresse saisie × webinaire).
  def first_key(typed, webinar)
    "first-#{Digest::SHA256.hexdigest([ typed, webinar ].join("\n"))}"
  end
end
