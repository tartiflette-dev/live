class HandRaisesController < ApplicationController
  include CurrentRegistration

  before_action :authenticate_animateur!, only: [ :index, :grant, :revoke ]
  before_action :set_webinar
  before_action :require_registration!, only: [ :status, :create, :destroy ]

  rescue_from HandRaiseControl::Conflict do
    render json: { error: "hand_raise_conflict" }, status: :conflict
  end

  rescue_from RoomServiceClient::Error do
    render json: { error: "permission_update_failed" }, status: :bad_gateway
  end

  rescue_from HandRaiseControl::PaymentRequired do
    render json: { error: "payment_required" }, status: :forbidden
  end

  def index
    render json: @webinar.hand_raises.active.includes(:registration).order(:raised_at).map { |hand| serialize(hand) }
  end

  def create
    render json: serialize(control.raise_hand(current_registration)), status: :created
  end

  def status
    hand = @webinar.hand_raises.active.find_by(registration: current_registration)
    render json: { hand_raise: hand ? serialize(hand) : nil }
  end

  def destroy
    control.lower_hand(current_registration)
    head :no_content
  end

  def grant
    render json: serialize(control.grant(params[:id]))
  end

  def revoke
    render json: serialize(control.revoke(params[:id]))
  end

  private

  def set_webinar
    @webinar = if %w[status create destroy].include?(action_name)
      Webinar.published.find_by!(slug: params[:slug])
    else
      # Donner/retirer la parole = animation :
      # autorisé pour tout animateur (owner, project_host, guest_host).
      Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
    end
  end

  def require_registration!
    render json: { error: "registration_required" }, status: :forbidden unless current_registration
  end

  def control
    HandRaiseControl.new(@webinar)
  end

  # `wants_video` : inscrit « participant », signalé dans la
  # régie comme voulant intervenir en vidéo.
  def serialize(hand)
    hand.slice(:id, :registration_id, :state, :raised_at, :granted_at, :revoked_at).merge(
      name: hand.registration.name, wants_video: hand.registration.participant?,
      error: hand.last_error.present? ? "permission_update_failed" : nil
    )
  end
end
