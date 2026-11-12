require "test_helper"

class MessageTest < ActiveSupport::TestCase
  setup do
    User.create!(email: "marc@example.test", oidc_sub: "host-message-test")
    @webinar = Webinar.create!(title: "Discussion", host_sub: "host-message-test", starts_at: 1.day.from_now)
  end

  test "une question est reconnue côté serveur à la mention en tête, mot complet" do
    [ "@animateur comment ?", " @ANIMATEUR, pourquoi ?", "@Marc?", "@animatrice" ].each do |body|
      assert_predicate post_message(body, kind: :chat), :question?, body
    end
    [ "Bonjour @marc", "@lucie bonjour", "@animateurs ?", "@regie ?", "Bonjour" ].each do |body|
      assert_predicate post_message(body, kind: :question), :chat?, body
    end
  end

  test "CHAT_QUESTION_MENTIONS ajoute des mentions propres à l'instance, sans retirer les autres" do
    with_question_mentions(" regie , Equipe,") do
      [ "@regie une question", "@EQUIPE ?", "@animateur ?" ].each do |body|
        assert_predicate post_message(body, kind: :chat), :question?, body
      end
      [ "@regies ?", "Bonjour @equipe" ].each do |body|
        assert_predicate post_message(body, kind: :question), :chat?, body
      end
    end
  end

  test "le texte est rogné ; vide ou au-delà de 1 000 caractères, refusé" do
    assert_equal "Bonjour", post_message("  Bonjour \n").body
    assert_not build_message(" " * 5).valid?
    assert_not build_message("x" * 1001).valid?
    assert build_message("é" * 1000).valid?
  end

  test "l'identité d'auteur suit le format LiveKit ; le rôle affiché en dérive" do
    assert_not build_message("Bonjour", author_identity: "admin-1").valid?
    assert_not build_message("Bonjour", author_identity: "viewer-").valid?
    assert_equal "speaker", build_message("Bonjour", author_identity: "speaker-4").author_role
    assert_equal "host", build_message("Bonjour", author_identity: "host-sub-marc").author_role
  end

  test "la forme publique n'expose jamais l'identité technique et date à la microseconde" do
    message = post_message("Bonjour", author_identity: "host-sub-secret")
    attributes = message.public_attributes

    assert_equal %i[id kind author_role name body created_at updated_at answered_at pinned_at], attributes.keys
    assert_not_includes attributes.to_json, "sub-secret"
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/, attributes[:updated_at])
  end

  test "le curseur (updated_at, id) remonte un ancien message modifié et départage les égalités par id" do
    first, second, third = 3.times.map { |i| post_message("Message #{i}") }
    instant = 1.minute.ago.utc.change(usec: 123_456)
    Message.where(id: [ first.id, second.id, third.id ]).update_all(updated_at: instant)

    assert_equal [ second.id, third.id ], Message.updated_after(instant, first.id).in_cursor_order.pluck(:id)
    first.update!(pinned_at: Time.current)
    assert_equal [ first.id ], Message.updated_after(instant, third.id).in_cursor_order.pluck(:id)
  end

  private

  def build_message(body, author_identity: "viewer-1")
    @webinar.messages.new(author_identity: author_identity, name: "Alice", body: body)
  end

  def post_message(body, author_identity: "viewer-1", kind: nil)
    @webinar.messages.create!(author_identity: author_identity, name: "Alice", body: body, kind: kind)
  end

  def with_question_mentions(value)
    previous = ENV["CHAT_QUESTION_MENTIONS"]
    ENV["CHAT_QUESTION_MENTIONS"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("CHAT_QUESTION_MENTIONS") : ENV["CHAT_QUESTION_MENTIONS"] = previous
  end
end
