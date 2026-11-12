require "test_helper"

class RecipientMailThrottleTest < ActiveSupport::TestCase
  ADDRESS = "victime@example.test".freeze
  PAUSE = RecipientMailThrottle::INTERVAL + 1.minute

  setup { @throttle = RecipientMailThrottle.default }

  # ---- Intervalle, plafond de flux ------------------------------------------

  test "un mail par flux et par adresse toutes les 10 minutes" do
    assert @throttle.claim(ADDRESS, "confirmation:1")
    assert_not @throttle.claim(ADDRESS, "confirmation:1")
    travel(RecipientMailThrottle::INTERVAL - 1.second) { assert_not @throttle.claim(ADDRESS, "confirmation:1") }
    travel(RecipientMailThrottle::INTERVAL + 1.second) { assert @throttle.claim(ADDRESS, "confirmation:1") }
  end

  test "l'adresse est comparée sans casse ni espaces" do
    assert @throttle.claim("Victime@Example.test", "confirmation:1")
    assert_not @throttle.claim("  victime@example.test ", "confirmation:1")
  end

  test "un autre flux ou une autre adresse ne sont pas limités par celui-ci" do
    assert @throttle.claim(ADDRESS, "confirmation:1")
    assert @throttle.claim(ADDRESS, "confirmation:2")
    assert @throttle.claim("autre@example.test", "confirmation:1")
  end

  test "plafond quotidien par flux, puis reprise après 24 h" do
    RecipientMailThrottle::SCOPE_CAP.times do |index|
      travel(index * PAUSE) { assert @throttle.claim(ADDRESS, "confirmation:1"), "mail #{index + 1} autorisé" }
    end
    travel RecipientMailThrottle::SCOPE_CAP * PAUSE do
      assert_not @throttle.claim(ADDRESS, "confirmation:1"), "le plafond du flux est atteint"
      assert @throttle.claim("autre@example.test", "confirmation:1"), "une autre adresse n'est pas touchée"
    end
    travel(RecipientMailThrottle::DAY + 1.minute) { assert @throttle.claim(ADDRESS, "confirmation:1") }
  end

  test "un mail couvrant plusieurs flux est refusé dès qu'un flux est limité, et n'enregistre alors rien" do
    assert @throttle.claim(ADDRESS, "confirmation:1")
    assert_not @throttle.claim(ADDRESS, "confirmation:2", "confirmation:1")
    assert @throttle.claim(ADDRESS, "confirmation:2"), "le flux 2 n'a pas été consommé par le refus"
  end

  # ---- Total par adresse (budget :unproven) ---------------------------------

  # Répartir sur plusieurs flux ne dépasse pas la borne.
  test "répartir les renvois sur plusieurs flux ne dépasse pas le total de l'adresse" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      assert @throttle.claim(ADDRESS, "confirmation:#{index}"), "flux #{index} autorisé"
    end
    assert_not @throttle.claim(ADDRESS, "confirmation:neuf"), "le total de l'adresse est atteint, quel que soit le flux"
    assert @throttle.claim("autre@example.test", "confirmation:neuf"), "une autre adresse n'est pas touchée"
    travel(RecipientMailThrottle::DAY + 1.minute) { assert @throttle.claim(ADDRESS, "confirmation:neuf") }
  end

  test "un mail couvrant plusieurs flux ne compte que pour un dans le total" do
    (RecipientMailThrottle::DAILY_TOTAL_CAP - 1).times { |index| assert @throttle.claim(ADDRESS, "autre:#{index}") }
    assert @throttle.claim(ADDRESS, "confirmation:1", "confirmation:2", "confirmation:3"), "trois flux, un seul mail : le dernier du total"
    assert_not @throttle.claim(ADDRESS, "autre:neuf")
  end

  # ---- Première confirmation d'une inscription neuve ------------------------

  test "la première confirmation d'une inscription neuve ne compte pas dans le total et n'en dépend pas" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| @throttle.claim(ADDRESS, "renvoi:#{index}") }
    assert_not @throttle.claim(ADDRESS, "renvoi:neuf"), "le total est atteint"

    assert @throttle.claim(ADDRESS, "confirmation:nouvelle", first_of: [ "webinar:1" ]), "première confirmation : hors total"
    assert_not @throttle.claim(ADDRESS, "confirmation:nouvelle", first_of: [ "webinar:1" ]), "mais soumise à la limite de son flux"
    assert_not @throttle.claim(ADDRESS, "confirmation:nouvelle"), "et le renvoi qui suit, lui, compte dans le total"
  end

  test "les premières confirmations ne consomment pas le total des renvois" do
    5.times { |index| assert @throttle.claim(ADDRESS, "confirmation:#{index}", first_of: [ "webinar:#{index}" ]) }
    RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| assert @throttle.claim(ADDRESS, "renvoi:#{index}"), "renvoi #{index + 1}" }
  end

  # ---- Boîte canonique et exemption une fois par (boîte × webinaire) ---------
  # Boîtes gmail fictives : Gmail refuse le « _ » dans un nom d'utilisateur,
  # aucune de ces adresses ne peut exister.

  test "boîte canonique : minuscules, +tag retiré partout, points retirés pour gmail, googlemail ramené à gmail" do
    canonical = RecipientMailThrottle.method(:canonical_mailbox)
    assert_equal "victime@example.test", canonical.call(" Victime+promo@Example.test ")
    assert_equal "v.i.c@example.test", canonical.call("v.i.c+x@example.test"), "les points comptent hors gmail"
    assert_equal "fictif_v@gmail.com", canonical.call("F.i.c.t.i.f_v+z@GoogleMail.com")
    assert_equal "fictif_v@gmail.com", canonical.call("fictif_v@gmail.com")
    assert_equal "+tag@example.test", canonical.call("+tag@example.test"), "un local réduit à un tag reste tel quel"
    assert_equal "sans-arobase", canonical.call("sans-arobase")
  end

  test "les variantes d'une même boîte partagent le total et les flux, pas l'adresse stockée" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| assert @throttle.claim("victime+#{index}@example.test", "renvoi:#{index}") }
    assert_not @throttle.claim("victime@example.test", "renvoi:neuf")
    assert_not @throttle.claim("VICTIME+autre@Example.test", "renvoi:neuf")
  end

  # Arbitrage final : clé d'exemption = adresse SAISIE × webinaire ; une adresse
  # avec +tag n'est jamais exemptée.
  test "préemption : une variante +tag saisie avant la victime ne grille pas son exemption" do
    assert @throttle.claim("victime+x@example.test", "confirmation:1", first_of: [ "webinar:7" ])
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      @throttle.claim("victime+#{index}@example.test", "renvoi:#{index}", first_of: [ "webinar:7" ])
    end
    assert_not @throttle.claim("victime@example.test", "renvoi:neuf"), "le total :unproven de la boîte est plein"

    assert @throttle.claim("victime@example.test", "confirmation:victime", first_of: [ "webinar:7" ]), "la vraie première confirmation part, hors total"
  end

  test "une adresse avec +tag n'est jamais exemptée : elle compte dans le total :unproven" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      assert @throttle.claim("victime+#{index}@example.test", "confirmation:v#{index}", first_of: [ "webinar:7" ])
    end
    assert_not @throttle.claim("victime+neuf@example.test", "confirmation:vneuf", first_of: [ "webinar:7" ]), "total atteint : aucune exemption pour une adresse à +tag"
  end

  test "la victime avec un +tag légitime reçoit son mail tant que :unproven n'est pas plein" do
    (RecipientMailThrottle::DAILY_TOTAL_CAP - 1).times { |index| assert @throttle.claim("victime+#{index}@example.test", "renvoi:#{index}") }
    assert @throttle.claim("victime+perso@example.test", "confirmation:perso", first_of: [ "webinar:7" ])
    assert_not @throttle.claim("victime+autre@example.test", "confirmation:autre", first_of: [ "webinar:7" ])
  end

  test "l'exemption ne vaut qu'une fois par adresse saisie et webinaire" do
    assert @throttle.claim("victime@example.test", "confirmation:1", first_of: [ "webinar:7" ])
    RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| @throttle.claim("victime@example.test", "renvoi:#{index}") }
    assert_not @throttle.claim("victime@example.test", "confirmation:2", first_of: [ "webinar:7" ]), "même adresse, même webinaire : plus exemptée, total plein"
    assert @throttle.claim("victime@example.test", "confirmation:3", first_of: [ "webinar:8" ]), "un autre webinaire : exemptée"
  end

  # Seul le marqueur compte ici : au moment du test, les renvois d'avant ont
  # expiré, le total est rempli à neuf. Avec un TTL de 365 jours, le marqueur
  # survivrait, l'adresse ne serait plus exemptée et le claim serait refusé.
  test "le marqueur d'exemption expire avec la fenêtre du throttle, pas après" do
    assert @throttle.claim("victime@example.test", "confirmation:1", first_of: [ "webinar:7" ])
    travel(RecipientMailThrottle::DAY + 1.minute) do
      RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| assert @throttle.claim("victime@example.test", "renvoi:#{index}") }
      assert @throttle.claim("victime@example.test", "confirmation:2", first_of: [ "webinar:7" ]), "marqueur expiré : de nouveau exemptée malgré le total plein"
    end
  end

  # La clé du marqueur est l'adresse SAISIE : écrit sous la boîte canonique,
  # la forme `…@gmail.com` serait vue comme déjà exemptée.
  test "adresse non taguée dont la forme saisie diffère de la canonique : le marqueur suit la forme saisie" do
    assert_equal "jeanfictif_d@gmail.com", RecipientMailThrottle.canonical_mailbox("Jean.Fictif_D@googlemail.com")
    assert @throttle.claim("Jean.Fictif_D@googlemail.com", "confirmation:1", first_of: [ "webinar:7" ])
    RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| @throttle.claim("jean.fictif_d@gmail.com", "renvoi:#{index}") }

    assert @throttle.claim("jean.fictif_d@gmail.com", "confirmation:2", first_of: [ "webinar:7" ]), "autre forme saisie, même boîte canonique : sa propre exemption"
    assert_not @throttle.claim("JEAN.FICTIF_D@googlemail.com", "confirmation:3", first_of: [ "webinar:7" ]), "même forme saisie (casse près) : déjà exemptée"
  end

  test "résidu connu : chaque forme à points d'une adresse gmail a sa propre exemption" do
    assert @throttle.claim("fictif_v@gmail.com", "confirmation:1", first_of: [ "webinar:7" ])
    RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| @throttle.claim("fictif_v@gmail.com", "renvoi:#{index}") }
    assert @throttle.claim("f.ictif_v@gmail.com", "confirmation:2", first_of: [ "webinar:7" ])
    assert @throttle.claim("fi.ctif_v@gmail.com", "confirmation:3", first_of: [ "webinar:7" ])
  end

  test "un refus est journalisé avec une empreinte de la boîte canonique, jamais l'adresse" do
    @throttle.claim("Victime+x@example.test", "confirmation:1")
    io = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    @throttle.claim("victime@example.test", "confirmation:1")
    Rails.logger = previous

    digest = RecipientMailThrottle.log_digest("victime@example.test")
    assert_not_equal Digest::SHA256.hexdigest("victime@example.test")[0, RecipientMailThrottle::LOG_DIGEST_LENGTH], digest, "pas le SHA256 nu, retrouvable par dictionnaire"
    assert_equal OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key("mail-throttle-log"), "victime@example.test")[0, RecipientMailThrottle::LOG_DIGEST_LENGTH], digest
    assert_includes io.string, "[mail-throttle] refused budget=unproven scopes=confirmation:1 reason=interval mailbox=#{digest}"
    assert_no_match(/victime/, io.string.sub("mailbox=#{digest}", ""))
  end

  # ---- Budget :security (accès immédiat) ------------------------------------

  # (b) : des confirmations épuisées n'empêchent pas le mail de sécurité.
  test "épuiser les confirmations ordinaires n'empêche pas le mail de sécurité d'un autre flux" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| @throttle.claim(ADDRESS, "confirmation:#{index}") }
    assert_not @throttle.claim(ADDRESS, "confirmation:neuf")

    assert @throttle.claim(ADDRESS, "confirmation:neuf", budget: :security)
  end

  test "le budget de sécurité n'a pas de total par adresse : un flux par inscription, chacun son tour" do
    (RecipientMailThrottle::DAILY_TOTAL_CAP + 5).times do |index|
      assert @throttle.claim(ADDRESS, "confirmation:#{index}", budget: :security), "accès immédiat #{index + 1}"
    end
  end

  # (d) : un budget de sécurité épuisé refuse le claim, donc l'accès.
  test "le budget de sécurité d'un flux est plafonné à SCOPE_CAP par jour" do
    RecipientMailThrottle::SCOPE_CAP.times do |index|
      travel(index * PAUSE) { assert @throttle.claim(ADDRESS, "confirmation:1", budget: :security) }
    end
    travel RecipientMailThrottle::SCOPE_CAP * PAUSE do
      assert_not @throttle.claim(ADDRESS, "confirmation:1", budget: :security)
      assert @throttle.claim(ADDRESS, "confirmation:2", budget: :security), "un autre flux n'est pas touché"
    end
  end

  # (c) : l'accès immédiat respecte l'intervalle.
  test "un mail de sécurité est refusé si le flux a servi depuis moins de 10 minutes, et inversement" do
    assert @throttle.claim(ADDRESS, "confirmation:1")
    assert_not @throttle.claim(ADDRESS, "confirmation:1", budget: :security), "le flux ordinaire a servi à l'instant"
    travel(RecipientMailThrottle::INTERVAL + 1.second) { assert @throttle.claim(ADDRESS, "confirmation:1", budget: :security) }

    assert @throttle.claim(ADDRESS, "confirmation:2", budget: :security)
    assert_not @throttle.claim(ADDRESS, "confirmation:2"), "l'accès immédiat a inscrit son envoi dans le flux ordinaire"
    travel(RecipientMailThrottle::INTERVAL + 1.second) { assert @throttle.claim(ADDRESS, "confirmation:2") }
  end

  test "l'envoi de sécurité n'entre pas dans le total des mails ordinaires" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| assert @throttle.claim(ADDRESS, "confirmation:#{index}", budget: :security) }
    RecipientMailThrottle::DAILY_TOTAL_CAP.times do |index|
      travel(PAUSE) { assert @throttle.claim(ADDRESS, "renvoi:#{index}"), "renvoi #{index + 1}" }
    end
  end

  # ---- Budget :proof (lien intervenant) -------------------------------------

  # (b) : le lien intervenant n'est pas empêché par des confirmations épuisées.
  test "épuiser les confirmations n'empêche pas le mail de preuve du lien intervenant" do
    RecipientMailThrottle::DAILY_TOTAL_CAP.times { |index| @throttle.claim(ADDRESS, "confirmation:#{index}") }
    assert_not @throttle.claim(ADDRESS, "confirmation:neuf")

    assert @throttle.claim(ADDRESS, "speaker-link:1", budget: :proof)
  end

  # Deux liens intervenant légitimes peuvent se suivre.
  test "le mail de preuve n'a pas d'intervalle : deux liens légitimes en moins de 10 minutes" do
    assert @throttle.claim(ADDRESS, "speaker-link:1", budget: :proof)
    travel(2.minutes) { assert @throttle.claim(ADDRESS, "speaker-link:1", budget: :proof) }
  end

  test "le mail de preuve est borné par son plafond de flux, sans total par adresse" do
    RecipientMailThrottle::SCOPE_CAP.times { assert @throttle.claim(ADDRESS, "speaker-link:1", budget: :proof) }
    assert_not @throttle.claim(ADDRESS, "speaker-link:1", budget: :proof), "6 par jour et par flux"
    (RecipientMailThrottle::DAILY_TOTAL_CAP + 5).times do |index|
      assert @throttle.claim(ADDRESS, "speaker-link:#{index + 2}", budget: :proof)
    end
  end

  # ---- Divers ---------------------------------------------------------------

  test "adresse vide ou sans flux : refusé" do
    assert_not @throttle.claim("", "confirmation:1")
    assert_not @throttle.claim(nil, "confirmation:1")
    assert_not @throttle.claim(ADDRESS)
  end

  test "budget inconnu : erreur, jamais d'envoi par défaut" do
    assert_raises(KeyError) { @throttle.claim(ADDRESS, "confirmation:1", budget: :libre) }
  end

  test "deux demandes simultanées pour la même adresse : une seule passe" do
    results = 8.times.map { Thread.new { @throttle.claim("course@example.test", "confirmation:1") } }.map(&:value)
    assert_equal 1, results.count(true)
  end

  test "aucune adresse en clair sur le disque" do
    @throttle.claim("secrete-adresse@example.test", "confirmation:1")
    root = RegistrationRateLimitStore.storage_root.join("recipient_mail_throttle")
    contents = Dir.glob(root.join("**", "*")).select { |file| File.file?(file) }.map { |file| File.binread(file) }.join
    assert_no_match(/secrete-adresse/, contents)
  end
end
