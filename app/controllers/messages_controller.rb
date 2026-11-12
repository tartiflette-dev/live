# Discussion du direct, côté participants.
#
#   GET  /w/:slug/messages[?updated_since=&updated_since_id=]  → { messages: [...] }
#   POST /w/:slug/messages  { body }                           → message + broadcast
#
# HTTP authentifie, persiste, puis le serveur seul diffuse (MessageBroadcast).
# Aucun champ d'identité, de nom, de nature ni de drapeau n'est lu du client.
# Le texte des participants sort en JSON échappé (< > & en \uXXXX) :
# `escape: true` empêche le rendu JSON de Rails 8.1 de couper l'échappement
# (escape_json_responses = false), `escape_html_entities: true` le maintient
# quel que soit le réglage global. Défense en profondeur : le client
# affiche le texte en texte (React), jamais en HTML.
#
# Qui participe : RoomAuthor (animation, intervenant nominatif, inscription
# confirmée) ; la salle elle-même n'ouvre qu'au direct.
# Animateurs et intervenants écrivent dès les coulisses ; tout le monde lit
# après la fin, personne n'écrit plus (410).
class MessagesController < ApplicationController
  include RoomAuthor
  include JsonCsrfRefusal

  PAGE_SIZE = 50
  CURSOR_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/
  CURSOR_ID = /\A\d{1,18}\z/
  RATE_LIMIT_STORE = RegistrationRateLimitStore.new(name: "message_rate_limits")

  class InvalidCursor < StandardError; end

  rescue_from InvalidCursor do
    render json: { error: "invalid_cursor" }, status: :bad_request
  end

  before_action :set_webinar
  before_action :require_json!, only: :create
  before_action :set_author

  # Anti-spam par auteur : une rafale, puis un débit soutenu.
  rate_limit to: 5, within: 10.seconds, name: "burst", only: :create,
    by: :rate_limit_key, store: RATE_LIMIT_STORE, with: :render_rate_limited
  rate_limit to: 20, within: 1.minute, name: "minute", only: :create,
    by: :rate_limit_key, store: RATE_LIMIT_STORE, with: :render_rate_limited

  def index
    messages = @webinar.messages
    messages = messages.updated_after(*cursor) if cursor_requested?
    render json: { messages: messages.in_cursor_order.limit(PAGE_SIZE).map(&:public_attributes) },
      escape: true, escape_html_entities: true
  end

  def create
    return render_error(:gone, "webinar_ended") if @webinar.ended?

    body = params[:body]
    return render_error(:unprocessable_entity, "invalid_message") unless body.is_a?(String)

    message = @webinar.messages.new(author_identity: @author.identity, name: @author.name, body: body)
    return render_error(:unprocessable_entity, "invalid_message") unless message.save

    render json: message.public_attributes.merge(broadcast: MessageBroadcast.new.deliver(message)),
      status: :created, escape: true, escape_html_entities: true
  end

  private

  def set_webinar
    @webinar = Webinar.find_by!(slug: params[:slug])
  end

  def require_json!
    head :unsupported_media_type unless request.media_type == "application/json"
  end

  def render_rate_limited
    render_error(:too_many_requests, "rate_limited")
  end

  # Curseur serveur (updated_at à la microseconde, id) : les deux moitiés
  # ensemble ou aucune ; toute autre forme est refusée, jamais corrigée.
  def cursor_requested?
    params.key?(:updated_since) || params.key?(:updated_since_id)
  end

  def cursor
    timestamp = params[:updated_since].to_s
    id = params[:updated_since_id].to_s
    raise InvalidCursor unless timestamp.match?(CURSOR_TIME) && id.match?(CURSOR_ID)

    time = Time.iso8601(timestamp)
    # Une date impossible (31 février) est normalisée par Ruby : refusée.
    raise InvalidCursor unless time.utc.iso8601(6) == timestamp

    [ time, id.to_i ]
  rescue ArgumentError
    raise InvalidCursor
  end

  def render_error(status, code)
    render json: { error: code }, status: status
  end
end
