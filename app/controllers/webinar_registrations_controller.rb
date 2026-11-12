require "csv"

class WebinarRegistrationsController < ApplicationController
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!
  before_action :set_webinar

  CSV_HEADERS = %w[name email confirmed_at paid_confirmed_at created_at room_joined_at].freeze
  UTF8_BOM    = "﻿"

  def index
    @registrations   = @webinar.registrations.order(created_at: :desc)
    @confirmed_count = @registrations.confirmed.count

    respond_to do |format|
      format.html
      format.csv { send_data csv_payload, type: "text/csv; charset=utf-8", disposition: "attachment", filename: "#{@webinar.slug}-inscrits.csv" }
    end
  end

  # Bloc « Inscrits » de la régie : chaque inscrit et sa présence dans la
  # salle (RoomAttendance), relu toutes les 5 s comme /regie/status.
  def attendance
    response.headers["Cache-Control"] = "no-store"
    render json: RoomAttendance.new(@webinar).call
  end

  private

  # La liste des inscrits porte des PII (nom,
  # email, paiement). On la restreint aux animateurs du projet et au
  # propriétaire (`where_managed_by`) — un co-animateur invité reçoit
  # 404 sur cette route (« PAS d'accès à la liste des
  # inscrits »).
  def set_webinar
    @webinar = Webinar.where_managed_by(current_user)
                      .find_by!(slug: params[:webinar_id])
  end

  def csv_payload
    body = CSV.generate(force_quotes: true) do |csv|
      csv << CSV_HEADERS
      @registrations.each do |r|
        csv << [
          csv_text(r.name),
          csv_text(r.email),
          r.confirmed_at&.iso8601,
          r.paid_confirmed_at&.iso8601,
          r.created_at.iso8601,
          r.room_joined_at&.iso8601
        ]
      end
    end
    UTF8_BOM + body
  end

  # Spreadsheet programs interpret formula prefixes even in quoted CSV cells.
  # Keep textual values literal without changing stored registration data.
  def csv_text(value)
    value.match?(/\A(?:[\t\r\n]|[[:space:]]*[=+@\-＝＋－＠])/) ? "'#{value}" : value
  end
end
