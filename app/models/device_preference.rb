# Préférences de périphériques d'un participant identifié :
# micro et caméra choisis, et si chacun
# était activé. Une ligne par propriétaire : l'animateur (User, valable
# d'un webinaire à l'autre) ou l'intervenant (Speaker, propre à son
# webinaire). Le spectateur n'en a pas : sa seule mémoire est son
# navigateur.
#
# Le périphérique est gardé par identifiant ET par libellé : l'identifiant
# est propre au navigateur et peut changer, le client retrouve alors le
# périphérique par son libellé (app/javascript/rooms/device_preferences.js).
#
# Contrat JSON = la forme du client, à l'identique dans les deux sens
# (`devicePreferences` de POST /api/token, corps — éventuellement
# partiel — de PATCH /api/device_preferences) :
#   { audioinput: { deviceId, label } | null, videoinput: { deviceId, label } | null,
#     audioEnabled: true | false | null, videoEnabled: true | false | null }
class DevicePreference < ApplicationRecord
  OWNER_TYPES = %w[User Speaker].freeze
  DEVICES = { "audioinput" => :audio_input, "videoinput" => :video_input }.freeze
  FLAGS   = { "audioEnabled" => :audio_enabled, "videoEnabled" => :video_enabled }.freeze
  MAX_LENGTH = 255

  belongs_to :owner, polymorphic: true

  # Une ligne par participant : l'index unique (owner_type, owner_id) en
  # est la seule garde. Une validation Ruby en plus ferait échouer
  # create_or_find_by! en RecordInvalid au lieu de retrouver la ligne.
  validates :owner_type, inclusion: { in: OWNER_TYPES }
  validates :audio_input_device_id, :audio_input_label, :video_input_device_id, :video_input_label,
            length: { maximum: MAX_LENGTH }

  # `record` (participant résolu par RoomParticipant) peut-il porter des
  # préférences ? Animateur et intervenant oui, spectateur non.
  def self.ownable?(record)
    OWNER_TYPES.include?(record.class.name)
  end

  # Préférences de `owner`, vides s'il n'a encore rien choisi.
  def self.payload_for(owner)
    (owner.device_preference || new).to_payload
  end

  def to_payload
    devices = DEVICES.to_h { |key, prefix| [ key, device_payload(prefix) ] }
    flags   = FLAGS.to_h { |key, column| [ key, self[column] ] }
    devices.merge(flags)
  end

  # Applique `payload` (forme du client, éventuellement partielle) : seules
  # les clés présentes changent ; une clé présente mais illisible efface.
  def merge_payload(payload)
    DEVICES.each do |key, prefix|
      next unless payload.key?(key)

      device = payload[key]
      device_id = device.is_a?(Hash) ? device["deviceId"].presence : nil
      self["#{prefix}_device_id"] = device_id
      self["#{prefix}_label"] = device_id && device["label"].to_s
    end
    FLAGS.each { |key, column| self[column] = boolean_or_nil(payload[key]) if payload.key?(key) }
    self
  end

  private

  def device_payload(prefix)
    device_id = self["#{prefix}_device_id"]
    device_id && { "deviceId" => device_id, "label" => self["#{prefix}_label"].to_s }
  end

  # Strict : seul un booléen JSON compte. Le cast ActiveRecord ferait d'une
  # chaîne quelconque un `true`.
  def boolean_or_nil(value)
    value if value == true || value == false
  end
end
