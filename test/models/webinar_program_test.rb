require "test_helper"

# Programme annoncé d'un café (Webinar::Program) : sujet, présentation,
# intervenants annoncés, animateur du jour. Tout est facultatif.
class WebinarProgramTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 11, 10, 10, 0)
    @webinar = Webinar.create!(title: "Café IA #10", starts_at: Time.zone.local(2026, 11, 12, 18, 0),
                               host_sub: "sub-owner", visibility: "published")
  end

  test "un café neuf n'annonce aucun programme" do
    assert_nil @webinar.topic
    assert_equal [], @webinar.announced_speakers
    assert_nil @webinar.lead_host_name
    assert_not @webinar.program_announced?
  end

  test "saisie nettoyée : espaces retirés, champs vides oubliés, ordre des intervenants gardé" do
    @webinar.update!(topic: "  Agents IA  ", topic_summary: " ", lead_host_name: " Anne ",
                     announced_speakers: [ " Karim ", "", "  ", "Anne" ])

    @webinar.reload
    assert_equal "Agents IA", @webinar.topic
    assert_nil @webinar.topic_summary
    assert_equal "Anne", @webinar.lead_host_name
    assert_equal [ "Karim", "Anne" ], @webinar.announced_speakers
  end

  test "chaque élément suffit à annoncer un programme" do
    [ { topic: "Agents IA" }, { announced_speakers: [ "Karim" ] }, { lead_host_name: "Anne" } ].each do |program|
      assert Webinar.new(program).program_announced?, program.inspect
    end
  end

  test "trois intervenants au plus" do
    assert @webinar.revise(announced_speakers: %w[Anne Karim Marc])

    assert_not @webinar.revise(announced_speakers: %w[Anne Karim Marc Zoé])
    assert @webinar.errors.of_kind?(:announced_speakers, :too_many)
    assert_includes @webinar.errors.full_messages, "Intervenants annoncés 3 au plus"
  end

  test "longueurs bornées : sujet, présentation, noms" do
    assert_not @webinar.revise(topic: "a" * 121)
    assert @webinar.errors.of_kind?(:topic, :too_long)

    assert_not @webinar.reload.revise(topic: "Agents IA", topic_summary: "a" * 401)
    assert @webinar.errors.of_kind?(:topic_summary, :too_long)

    assert_not @webinar.reload.revise(lead_host_name: "a" * 81)
    assert @webinar.errors.of_kind?(:lead_host_name, :too_long)

    assert_not @webinar.reload.revise(announced_speakers: [ "a" * 81 ])
    assert @webinar.errors.of_kind?(:announced_speakers, :name_too_long)
  end

  test "une présentation sans sujet est refusée" do
    assert_not @webinar.revise(topic_summary: "Deux retours de terrain.")
    assert_includes @webinar.errors.full_messages, "Sujet doit être renseigné pour accompagner sa présentation"
  end

  test "un programme hors bornes écrit hors saisie ne bloque pas le lancement du direct" do
    @webinar.update!(topic: "a" * 200, announced_speakers: %w[Anne Karim Marc Zoé])

    @webinar.go_live!

    assert @webinar.reload.live?
  end

  test "revise écrit le programme ; plus rien une fois le direct commencé" do
    assert @webinar.revise(topic: "Agents IA", announced_speakers: [ "Karim" ])
    assert_equal "Agents IA", @webinar.reload.topic

    @webinar.go_live!
    assert_not @webinar.revise(topic: "Autre sujet")
    assert_equal "Agents IA", @webinar.reload.topic
  end

  test "toute l'animation saisit le programme, personne d'autre" do
    owner = User.create!(email: "owner@example.net", oidc_sub: "sub-owner")
    guest = User.create!(email: "jean@partenaire.example.org", oidc_sub: "sub-jean", email_verified: true,
                         email_verified_for: "jean@partenaire.example.org")
    stranger = User.create!(email: "autre@example.net", oidc_sub: "sub-autre")
    @webinar.webinar_hosts.create!(email: guest.email, invited_by_sub: owner.oidc_sub)

    assert @webinar.can_edit_program?(owner)
    assert @webinar.can_edit_program?(guest)
    assert_not @webinar.can_edit_program?(stranger)
    assert_not @webinar.can_edit_program?(nil)
  end
end
