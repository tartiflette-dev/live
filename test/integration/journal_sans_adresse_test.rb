# frozen_string_literal: true

require "test_helper"

# Au niveau de journal de la production, aucune adresse dans les journaux, y compris
# dans le message d'un 404 (le SQL du périmètre y porte l'adresse de l'animateur).
class JournalSansAdresseTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  ADRESSE = "passant@example.test"

  test "un animateur sur le webinaire d'un autre : 404, sans son adresse au journal" do
    webinar = Webinar.create!(title: "Hors périmètre", starts_at: 1.day.from_now, host_sub: "sub-autre", visibility: "published")
    sign_in_as(User.create!(email: ADRESSE, oidc_sub: "sub-passant"))

    log = journal_au_niveau_info { get stage_webinar_path(slug: webinar.slug) }

    assert_response :not_found
    assert_no_match(/passant|example\.test/, log)
  end

  # Indépendant des loggers : ce message part au journal par plusieurs chemins (rescue_from
  # d'un contrôleur, middleware), tous au niveau info.
  test "le message d'un RecordNotFound sur le périmètre d'un animateur ne cite pas son adresse" do
    sign_in_as(User.create!(email: ADRESSE, oidc_sub: "sub-passant"))
    user = User.find_by!(oidc_sub: "sub-passant")
    assert user.email_verified_and_fresh?, "le chemin qui lit l'adresse exige un compte vérifié"

    error = assert_raises(ActiveRecord::RecordNotFound) { Webinar.where_animated_by(user).find_by!(slug: "absent") }

    assert_no_match(/passant|example\.test/, error.message)
  end

  test "un sub inconnu sur une adresse déjà prise : refus journalisé, sans l'adresse" do
    User.create!(email: ADRESSE, oidc_sub: "sub-existant")

    log = journal_au_niveau_info { sign_in_as(User.new(email: ADRESSE, oidc_sub: "sub-reemis")) }

    assert_includes log, "[OIDC] refus rapprochement par email (sub=sub-reemis)"
    assert_no_match(/passant|example\.test/, log)
  end

  test "un job n'écrit pas ses arguments au journal : un destinataire y passerait" do
    assert_not ActionMailer::MailDeliveryJob.log_arguments?
  end

  private

  # Rails.logger et le logger du middleware, pris à la construction de l'app.
  def journal_au_niveau_info
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log, level: :info)
    env = Rails.application.env_config
    previous = [ Rails.logger, env["action_dispatch.logger"] ]
    Rails.logger = logger
    env["action_dispatch.logger"] = logger
    yield
    log.string
  ensure
    Rails.logger = previous.first
    env["action_dispatch.logger"] = previous.last
  end
end
