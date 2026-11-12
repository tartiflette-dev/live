# frozen_string_literal: true

# Fiche d'une personne pour l'animation du projet (Animation::PeopleController) :
# tout ce qu'elle a fait sur live, à travers les
# cafés. Une personne = une adresse : toutes ses inscriptions (casse ignorée)
# et le compte de même adresse s'il existe.
#
# Agrège ses inscriptions (café, confirmée, venue dans la salle), ses
# visionnages de replay par café (ReplayStats.row_for sur l'union de ses
# séances, par inscription ou par compte), ses questions du direct (messages
# @animateur ou retenus dans la file Q&R), ses réponses aux sondages et ses
# recherches dans les replays. Lecture seule ; la fiche CRM est un simple
# lien, aucune écriture CRM.
class PersonActivity
  Question = Data.define(:webinar, :body, :at)
  Answer = Data.define(:webinar, :poll, :value, :at)

  # Clé d'URL d'une personne, par son inscription ou son compte : jamais son
  # adresse.
  def self.key_for(record)
    "#{record.is_a?(User) ? "u" : "r"}#{record.id}"
  end

  # @param key [String] « r<inscription> » ou « u<compte> » (key_for)
  # @return [PersonActivity, nil]
  def self.find(key)
    kind, id = key.to_s.match(/\A([ru])(\d+)\z/)&.captures
    record = case kind
    when "r" then Registration.find_by(id: id)
    when "u" then User.find_by(id: id)
    end
    new(record.email) if record
  end

  attr_reader :email

  def initialize(email)
    @email = email.to_s.strip.downcase
  end

  def registrations
    @registrations ||= Registration.where("LOWER(email) = ?", email).includes(:webinar)
                                   .sort_by { |registration| -registration.webinar.starts_at.to_i }
  end

  def user
    return @user if defined?(@user)

    @user = User.find_by("LOWER(email) = ?", email)
  end

  def name
    registrations.first&.name || user&.chat_alias
  end

  # Identifiant de sa fiche CRM, porté par l'inscription la plus récente
  # qui l'a.
  def crm_contact_id
    registrations.filter_map(&:crm_contact_id).first
  end

  # Visionnages par replay, le plus récent d'abord.
  # @return [Array<Array(Replay, ReplayStats::Row)>]
  def viewings
    views = ReplayView.where(registration_id: registrations.map(&:id))
    views = views.or(ReplayView.where(user_id: user.id)) if user
    views.includes(replay: %i[webinar recording]).group_by(&:replay)
         .map { |replay, list| [ replay, ReplayStats.row_for(replay, user || registrations.first, list) ] }
         .sort_by { |_, row| -row.last_seen_at.to_f }
  end

  # Questions posées pendant les directs : mentions @animateur et messages
  # retenus dans la file Q&R. Un message effacé (crm:erase) n'y revient pas.
  # @return [Array<Question>]
  def questions
    messages = Message.where(author_identity: identities).where.not(body: CrmErasure::ERASED_BODY)
    messages.where(kind: "question").or(messages.where(id: QaItemMessage.select(:message_id)))
            .includes(:webinar).order(created_at: :desc)
            .map { |message| Question.new(webinar: message.webinar, body: message.body, at: message.created_at) }
  end

  # Réponses aux sondages des directs.
  # @return [Array<Answer>]
  def answers
    PollResponse.where(registration_id: registrations.map(&:id)).includes(poll: :webinar).order(created_at: :desc)
                .map { |response| Answer.new(webinar: response.poll.webinar, poll: response.poll, value: response.value, at: response.created_at) }
  end

  def searches
    scope = ReplaySearch.where(registration_id: registrations.map(&:id))
    scope = scope.or(ReplaySearch.where(user_id: user.id)) if user
    scope.order(created_at: :desc)
  end

  private

  def identities
    registrations.map { |registration| "viewer-#{registration.id}" }
  end
end
