# frozen_string_literal: true

Rails.application.config.x.room_service_client_factory = -> { RoomServiceClient.new }
