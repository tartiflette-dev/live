class PacksController < ApplicationController
  # Packs : formules payantes modélisées (le paiement n'est pas encaissé).
  #
  # CRUD animateur MINIMAL : index / new / create. Pas de show, pas de
  # edit, pas de destroy (YAGNI).
  # Isolation par host_sub, comme WebinarsController.
  before_action :authenticate_animateur!
  # 404 (défense énumération, comme authorize_project_host!) pour un compte
  # connecté sans droit sur les packs (User#can_manage_packs?).
  before_action -> { head :not_found unless current_user.can_manage_packs? }

  def self.animateur_browser_policy_options
    {}
  end
  include AnimateurBrowserPolicy

  def index
    @packs = Pack.hosted_by(current_user.oidc_sub).order(created_at: :desc).includes(:webinars)
  end

  def new
    @pack = Pack.new
  end

  def create
    @pack = Pack.new(pack_params)
    # host_sub = identité Pocket ID — jamais un input formulaire (défense
    # cohérente avec WebinarsController#create).
    @pack.host_sub = current_user.oidc_sub

    if @pack.save
      redirect_to packs_path, notice: "Pack créé."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def pack_params
    params.require(:pack).permit(:name, :price_cents)
  end
end
