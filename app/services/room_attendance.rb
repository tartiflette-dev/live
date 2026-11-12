# Inscrits d'un webinaire et leur présence dans la salle du direct, pour la
# régie : « la liste des inscrits et s'ils sont présents ou non ».
#
# Une inscription est vue dans la salle sous deux identités LiveKit
# (Api::TokensController#identity_for) :
#   • `viewer-<Registration.id>`  — spectateur inscrit ;
#   • `speaker-<Speaker.id>`      — intervenant rattaché à son inscription
#                                   (Speaker#registration, lien privé).
# L'animation (`host-<sub>`) n'est pas une inscription.
#
# Présence d'un inscrit :
#   • "present" — dans la salle maintenant (RoomSnapshot, lecture LiveKit) ;
#   • "left"    — déjà venu dans la salle, plus là maintenant (`room_joined_at`) ;
#   • "absent"  — jamais vu dans la salle.
# Salle illisible (LiveKit injoignable) : personne n'est dit présent, la
# régie l'annonce ; « venu » reste lu en base.
#
# `room_joined_at` = première fois que l'inscrit a été vu dans la salle de
# CE webinaire, direct lancé ou non (la salle s'ouvre avant le direct :
# accueil, répétition). D'où « venu dans la salle », jamais « au direct ».
# Il est posé par le webhook
# `participant_joined` (`note_arrival`) et, en filet, quand la lecture de la
# salle voit un inscrit que le webhook n'a pas relevé (webhook perdu, inscrit
# arrivé avant le déploiement de la colonne), et quand le journal du serveur
# LiveKit est rejoué (PresenceLogImport : cafés tenus avant la colonne).
# Écriture idempotente : une valeur vide est remplie, une valeur plus récente
# remplacée par une arrivée plus ancienne, et seulement s'il y a lieu
# (SQLite : pas de verrou d'écriture pris à chaque relecture de la régie).
# Le détail des arrivées et départs est au journal de présence
# (PresenceEvent, page « Présence »).
#
# Les inscriptions effacées (pierre tombale RGPD, `retired?`) ne sont pas
# listées : elles ne désignent plus personne.
class RoomAttendance
  VIEWER = /\Aviewer-([1-9]\d*)\z/
  SPEAKER = /\Aspeaker-([1-9]\d*)\z/
  # Présents d'abord, puis venus, puis absents ; par nom dans chaque groupe.
  STATUS_ORDER = { "present" => 0, "left" => 1, "absent" => 2 }.freeze
  # Colonnes lues à chaque relecture : ni jeton ni secret d'identité.
  LISTED_COLUMNS = %i[id name email participation confirmed_at instant_access_at room_removed_at room_joined_at].freeze
  private_constant :STATUS_ORDER, :LISTED_COLUMNS

  def initialize(webinar, snapshot: nil)
    @webinar = webinar
    @snapshot = snapshot
  end

  # Webhook `participant_joined`, identité déjà jugée autorisée.
  def self.note_arrival(webinar, identity, at: Time.current)
    ids = new(webinar).registration_ids_for([ identity ])
    mark_joined(webinar, ids, at)
  end

  # Garde la PREMIÈRE arrivée : une arrivée plus ancienne, rejouée depuis le
  # journal LiveKit (PresenceLogImport), remplace une plus récente.
  def self.mark_joined(webinar, registration_ids, at)
    return if registration_ids.empty?

    scope = webinar.registrations.where(id: registration_ids)
    scope.where(room_joined_at: nil).or(scope.where.not(room_joined_at: ..at)).update_all(room_joined_at: at)
  end

  # @return [Hash] { room:, registered:, present:, came:, registrations: [...] }
  def call
    snapshot = @snapshot || RoomSnapshot.new(@webinar).call
    readable = snapshot[:room] != "unavailable"
    in_room = (readable ? registration_ids_for(Array(snapshot[:participants]).map { |person| person[:identity] }) : []).to_set
    registrations = listed_registrations.to_a
    note_unrecorded_arrivals(registrations, in_room)

    entries = registrations.map { |registration| entry(registration, in_room.include?(registration.id)) }
                           .sort_by { |item| [ STATUS_ORDER.fetch(item[:status]), sort_key(item[:name]) ] }
    {
      room: snapshot[:room],
      registered: entries.size,
      present: entries.count { |item| item[:status] == "present" },
      came: entries.count { |item| item[:status] != "absent" },
      registrations: entries
    }
  end

  # Identités LiveKit → ids d'inscription de CE webinaire. Un intervenant sans
  # inscription rattachée, ou d'un autre webinaire, ne désigne aucun inscrit.
  def registration_ids_for(identities)
    viewer_ids = identities.filter_map { |identity| identity.to_s[VIEWER, 1]&.to_i }
    speaker_ids = identities.filter_map { |identity| identity.to_s[SPEAKER, 1]&.to_i }
    # Intervenant révoqué : la garde webhook l'expulse, il ne compte pas.
    from_speakers = speaker_ids.empty? ? [] : @webinar.speakers.active.where(id: speaker_ids).where.not(registration_id: nil).pluck(:registration_id)
    candidates = (viewer_ids + from_speakers).uniq
    return [] if candidates.empty?

    @webinar.registrations.where(id: candidates).pluck(:id)
  end

  private

  def listed_registrations
    @webinar.registrations.where(retired_email_digest: nil).select(*LISTED_COLUMNS)
  end

  def note_unrecorded_arrivals(registrations, in_room)
    now = Time.current
    unrecorded = registrations.select { |registration| in_room.include?(registration.id) && registration.room_joined_at.nil? }
    return if unrecorded.empty?

    self.class.mark_joined(@webinar, unrecorded.map(&:id), now)
    unrecorded.each { |registration| registration.room_joined_at = now }
  end

  # « Élodie » parmi les E, pas après « Zoé ».
  def sort_key(name)
    I18n.transliterate(name.to_s).downcase
  end

  def entry(registration, in_room)
    {
      id: registration.id,
      name: registration.name,
      email: registration.email,
      participation: registration.participation,
      confirmed: registration.confirmed? || registration.instant_access?,
      removed: registration.room_removed_at.present?,
      status: status_of(registration, in_room),
      joined_at: registration.room_joined_at&.iso8601
    }
  end

  def status_of(registration, in_room)
    return "present" if in_room
    return "left" if registration.room_joined_at

    "absent"
  end
end
