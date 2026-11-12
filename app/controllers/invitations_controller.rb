class InvitationsController < ApplicationController
  include CurrentRegistration
  include RegistrationsHelper

  # Lien participants PRIVÉ — point d'entrée PUBLIC, successeur du lien
  # d'invitation intervenant partagé). Un jeton opaque par webinaire (vit sur
  # Webinar#share_token). L'ouvrant saisit son nom, son adresse email
  # (obligatoire : sans elle, aucun contact au CRM) et choisit
  # (InvitationEntry) :
  #   - participant → un Speaker nominatif (identité LiveKit `speaker-<id>`,
  #     DONC enregistré ET transcrit), rattaché à son inscription seulement si
  #     la boîte mail est prouvée (InvitationEntry) → redirect vers son lien
  #     personnel `/w/:slug/join?t=…`, qui publie sans attente ;
  #   - spectateur → l'inscription seule, salle ouverte tout de suite pendant
  #     le direct, sinon par le mail de confirmation.
  #
  # ANONYME par contrat (aucun `authenticate_animateur!`).
  # CSRF actif (Rails omakase + layout `application` qui pose le meta-tag).

  # Rate limit par IP sur la création : plafond ample pour l'usage réel
  # (plusieurs intervenants d'un même tiers-lieu derrière un NAT),
  # bloquant à l'usage automatisé (10/min = 1 toutes les 6 s moyenne).
  # Store = fichier mutualisé Puma (même mécanisme que RegistrationsController).
  rate_limit to: 10, within: 1.minute, only: :create,
    by: -> { "invitation:#{Digest::SHA256.hexdigest(ClientNetwork.key(request.remote_ip))}" },
    store: RegistrationRateLimitStore.new,
    with: -> { render plain: "Trop de demandes. Réessayez dans une minute.", status: :too_many_requests }

  # GET /i?t=<share_token> — formulaire (nom, email, choix) OU redirect direct
  # vers le lien personnel si le cookie existe déjà. Navigateur retiré de ce
  # webinaire depuis la régie (RoomRemoval) → 403 : il n'obtient pas un nouvel
  # intervenant. Plafond d'intervenants atteint : le choix spectateur reste
  # offert, la création d'un intervenant le revérifie (503). Ce GET ne pose
  # aucun cookie.
  def show
    @webinar = Webinar.find_by_active_share_token(params[:t])
    return head :not_found if @webinar.nil?
    return render :ended, status: :gone, layout: "application" unless @webinar.link_access_open?
    return render_room_removed if room_removed?(@webinar)

    if (speaker = reuse_existing_speaker(@webinar))
      return redirect_to join_webinar_path(slug: @webinar.slug, t: speaker.token)
    end

    @entry = InvitationEntry.new(webinar: @webinar)
    render_form
  end

  # POST /i?t=<share_token> — entrée (InvitationEntry), cookie d'identité
  # (persistant, RoomRemoval#identity_cookie), redirect.
  # Garanties :
  #   - jeton inconnu/désactivé/régénéré   → 404 (jamais 500)
  #   - grâce des liens passée              → 410 Gone + message
  #   - politique de confidentialité absente → 503 (même règle que le
  #     formulaire d'inscription public : on recueille une adresse)
  #   - plafond d'intervenants atteint      → 503 + message
  #   - navigateur retiré (RoomRemoval), ou
  #     adresse retirée de la salle         → 403 + message, rien de créé
  #   - spectateur, navigateur déjà inscrit
  #     à ce webinaire sous une autre adresse → 409, son inscription gardée
  #   - rate limit par IP (filtre controller)
  #   - jamais le rôle host (Speaker ⇒ identité speaker-<id>)
  #   - jamais le jeton dans les logs (filter_parameters + /\At\z/ ;
  #     jeton en QUERY, pas en SEGMENT de chemin — cf. config/routes.rb)
  #   - plafond ATOMIQUE : comptage et création sous `webinar.with_lock`
  #     (InvitationEntry#save), évite la course « deux requêtes passent le
  #     count=49, deux Speakers créés ».
  def create
    @webinar = Webinar.find_by_active_share_token(params[:t])
    return head :not_found if @webinar.nil?

    @voice = @webinar.voice
    return render :ended, status: :gone, layout: "application" unless @webinar.link_access_open?
    return head :service_unavailable unless registration_privacy_url
    return render_room_removed if room_removed?(@webinar)

    if (speaker = reuse_existing_speaker(@webinar))
      return redirect_to join_webinar_path(slug: @webinar.slug, t: speaker.token), status: :see_other
    end

    @entry = InvitationEntry.new(webinar: @webinar, browser_registration: registration_in_browser(@webinar.registrations), **entry_params)
    case @entry.save
    when :speaker
      remember_room_speaker(@webinar, @entry.speaker)
      redirect_to join_webinar_path(slug: @webinar.slug, t: @entry.speaker.token), status: :see_other
    when :admitted
      return render "registrations/already_registered", status: :conflict, layout: "application" unless remember_registration(@entry.registration)

      redirect_to public_webinar_path(@webinar.slug), status: :see_other
    when :pending
      render "registrations/pending", layout: "application"
    when :removed
      render_room_removed
    when :full
      render :full, status: :service_unavailable, layout: "application"
    when :invalid
      render_form(status: :unprocessable_entity)
    end
  end

  private

  def entry_params
    params.expect(invitation: [ :name, :email, :participation ]).to_h.symbolize_keys
  end

  def render_form(status: :ok)
    @voice = @webinar.voice
    render :show, status: status, layout: "application"
  end

  # Cookie d'intervenant (RoomRemoval) → Speaker ACTIF du webinaire courant :
  # rouvrir le lien partagé du même navigateur saute le formulaire. Révoqué
  # par le propriétaire ou inconnu de ce webinaire : on retombe sur le
  # formulaire (le navigateur retiré depuis la régie a déjà été écarté).
  def reuse_existing_speaker(webinar)
    speaker_id = room_speaker_id(webinar)
    return nil if speaker_id.blank?

    webinar.speakers.active.find_by(id: speaker_id)
  end
end
