require "test_helper"

# Reconduction des co-animateurs : suggestion
# pré-cochée sur la page du webinaire, reprise au seul clic d'un
# gestionnaire (propriétaire ou animateur du projet).
class WebinarHostsCarryOverTest < ActionDispatch::IntegrationTest
  include OidcSignIn

  setup do
    @owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    @guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean")
    @previous = Webinar.create!(title: "Café IA 7", starts_at: 7.days.ago, host_sub: @owner.oidc_sub)
    @current = Webinar.create!(title: "Café IA 8", starts_at: 1.day.from_now, host_sub: @owner.oidc_sub)
    @previous.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub, claimed_sub: @guest.oidc_sub)
    @previous.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
  end

  test "la page propose les co-animateurs du café précédent, cochés, sans rien créer" do
    sign_in_as(@owner)

    get webinar_path(@current)

    assert_select "form[data-role='co-animateurs-carryover'][action=?]", carry_over_webinar_hosts_path(@current) do
      assert_select "legend", text: /Café IA 7/
      assert_select "input[type='checkbox'][name='emails[]'][checked]", count: 2
      assert_select "input[type='submit'][value='Reprendre les co-animateurs du café précédent']"
    end
    assert_empty @current.webinar_hosts
  end

  test "un co-animateur entré après la fin du café précédent n'est pas proposé" do
    ended_at = 6.days.ago
    @previous.update!(state: "ended", ended_at: ended_at)
    late = @previous.webinar_hosts.create!(email: "tardif@partenaire.example.org", invited_by_sub: @owner.oidc_sub,
                                           created_at: ended_at + 1.hour)
    @previous.webinar_hosts.find_by!(email: @guest.email).update_columns(created_at: ended_at - 1.hour)
    @previous.webinar_hosts.find_by!(email: "paul@partenaire.example.org").update_columns(created_at: ended_at - 1.hour)
    sign_in_as(@owner)

    get webinar_path(@current)

    assert_select "form[data-role='co-animateurs-carryover']" do
      assert_select "input[type='checkbox'][name='emails[]'][checked]", count: 2
      assert_select "input[value=?]", late.email, count: 0
    end
  end

  test "pas de suggestion quand le café précédent n'a personne de plus" do
    @current.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    @current.webinar_hosts.create!(email: "paul@partenaire.example.org", invited_by_sub: @owner.oidc_sub)
    sign_in_as(@owner)

    get webinar_path(@current)

    assert_select "[data-role='co-animateurs-carryover']", count: 0
  end

  test "le clic reprend les cases cochées seulement" do
    sign_in_as(@owner)

    post carry_over_webinar_hosts_path(@current), params: { emails: [ @guest.email ] }

    assert_redirected_to webinar_path(@current)
    assert_match(/jean@partenaire\.example\.org/, flash[:notice])
    host = @current.webinar_hosts.sole
    assert_equal [ "jean@partenaire.example.org", "sub-owner", "sub-jean" ], [ host.email, host.invited_by_sub, host.claimed_sub ]
  end

  test "aucune case cochée, ou un email hors de la liste : rien n'est créé" do
    sign_in_as(@owner)

    post carry_over_webinar_hosts_path(@current)
    assert_equal "Aucun co-animateur sélectionné.", flash[:alert]

    post carry_over_webinar_hosts_path(@current), params: { emails: [ "intrus@ailleurs.example.net" ], extra: { emails: "x" } }
    assert_equal "Aucun co-animateur sélectionné.", flash[:alert]
    assert_empty @current.webinar_hosts
  end

  test "un co-animateur invité ne voit ni n'utilise la reprise" do
    @current.webinar_hosts.create!(email: @guest.email, invited_by_sub: @owner.oidc_sub)
    sign_in_as(@guest)

    get webinar_path(@current)
    assert_response :success
    assert_select "[data-role='co-animateurs-carryover']", count: 0

    post carry_over_webinar_hosts_path(@current), params: { emails: [ "paul@partenaire.example.org" ] }
    assert_response :not_found
    assert_equal [ @guest.email ], @current.webinar_hosts.pluck(:email)
  end
end
