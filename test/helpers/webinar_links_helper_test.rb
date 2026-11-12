require "test_helper"

class WebinarLinksHelperTest < ActionView::TestCase
  test "un lien secret s'affiche sans aucun caractère de son jeton" do
    assert_equal "live.example.test/w/cafe-ia-7/join?t=••••••••",
                 masked_token_link("https://live.example.test/w/cafe-ia-7/join?t=Zx9_-secret")
    assert_equal "live.example.test/i?t=••••••••", masked_token_link("https://live.example.test/i?t=Zx9_-secret")
  end

  test "le port non standard reste visible, le port par défaut disparaît" do
    assert_equal "127.0.0.1:3000/i?t=••••••••", masked_token_link("http://127.0.0.1:3000/i?t=abc")
    assert_equal "www.example.com/i?t=••••••••", masked_token_link("http://www.example.com/i?t=abc")
  end

  test "le bouton Copier porte l'URL dans data-copy-link et désigne sa zone d'annonce" do
    render html: copy_link_button("https://live.example.test/i?t=abc", status_id: "copie-invitation", role: "invitation-copy") +
                 copy_link_status("copie-invitation")

    assert_select "button[type='button'][data-copy-link=?][aria-controls='copie-invitation'][data-role='invitation-copy']",
                  "https://live.example.test/i?t=abc", text: "Copier le lien"
    assert_select "button[title]", count: 0
    assert_select "span#copie-invitation[role='status'][aria-live='polite']", text: ""
  end

  test "libellé d'un lien animateur après la fin du direct" do
    assert_equal "inutilisable : direct terminé", host_invitation_status_label(:ended)
  end
end
