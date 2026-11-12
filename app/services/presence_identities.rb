# Qui est derrière une identité LiveKit d'un webinaire, pour le journal de
# présence (PresenceTimeline, PresenceLogImport) :
#   • `viewer-<Registration.id>` — l'inscrit ;
#   • `speaker-<Speaker.id>`     — l'intervenant, et son inscription s'il y
#                                  est rattaché (lien privé) : la même
#                                  personne que son `viewer-<id>` ;
#   • `host-<oidc_sub>`          — l'animation.
#
# À la différence de RoomAttendance (salle en cours), un intervenant révoqué
# depuis reste reconnu : le journal raconte ce qui s'est passé. Une
# inscription effacée (pierre tombale RGPD) ou un intervenant purgé ne
# désignent plus personne : la présence reste comptée, sans nom.
class PresenceIdentities
  # `key` regroupe les identités d'une même personne ; `registration` est
  # l'inscription qu'elle porte, s'il y en a une.
  Person = Struct.new(:key, :name, :role, :registration, keyword_init: true) do
    def anonymous?
      name.nil?
    end
  end

  ROLES = { "host" => :animation, "speaker" => :intervenant, "viewer" => :inscrit }.freeze

  def initialize(webinar, identities)
    @webinar = webinar
    ids = identities.compact.uniq.group_by { |identity| identity.split("-", 2).first }
    @registrations = webinar.registrations.where(retired_email_digest: nil).where(id: numeric(ids["viewer"])).index_by(&:id)
    @speakers = webinar.speakers.where(id: numeric(ids["speaker"])).index_by(&:id)
    linked = @speakers.values.filter_map(&:registration_id) - @registrations.keys
    @registrations.merge!(webinar.registrations.where(retired_email_digest: nil).where(id: linked).index_by(&:id))
    @users = User.where(oidc_sub: Array(ids["host"]).map { |identity| identity.delete_prefix("host-") }).index_by(&:oidc_sub)
  end

  # @return [Person]
  def person_for(identity)
    prefix, value = identity.split("-", 2)
    case prefix
    when "viewer" then registration_person(@registrations[value.to_i], identity, :inscrit)
    when "speaker" then speaker_person(@speakers[value.to_i], identity)
    else Person.new(key: identity, name: @users[value]&.chat_alias, role: :animation)
    end
  end

  private

  def numeric(identities)
    Array(identities).map { |identity| identity.split("-", 2).last.to_i }
  end

  def speaker_person(speaker, identity)
    registration = @registrations[speaker&.registration_id]
    return registration_person(registration, identity, :intervenant) if registration

    Person.new(key: identity, name: speaker&.name, role: :intervenant)
  end

  def registration_person(registration, identity, role)
    return Person.new(key: identity, name: nil, role: role) if registration.nil?

    Person.new(key: "registration-#{registration.id}", name: registration.name, role: role, registration: registration)
  end
end
