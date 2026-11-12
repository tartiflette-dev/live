# frozen_string_literal: true

# Factory `EgressClient` injectable — /.
#
# Le controller `RecordingsController` appelle
# `Rails.configuration.x.egress_client_factory.call` pour obtenir un client.
# Par défaut = nouvelle instance qui lit ENV (LIVEKIT_HOST/KEY/SECRET).
#
# Les tests remplacent le factory pour injecter un client stubbé (voir
# `test/controllers/recordings_controller_test.rb`), en évitant tout
# monkey-patch de la classe et sans mock global fragile.
Rails.application.config.x.egress_client_factory = -> { EgressClient.new }
