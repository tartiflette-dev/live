# Géométrie de l'en-tête du panneau latéral (side_panel.jsx), partagée par
# la scène (stage_layout_test) et la discussion (room_chat_test, pastille
# de non-lus réelle). Cas observé : « Masquer » posé
# sur l'onglet « Transcription » ; le même
# chevauchement revenait dès que la pastille de non-lus élargissait
# « Discussion ».
module SidePanelGeometry
  HEADER_JS = <<~JS.freeze
    (() => {
      const box = (el) => { const r = el.getBoundingClientRect();
        return { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }; };
      const panel = document.querySelector("[data-testid='side-panel']");
      const toggle = document.querySelector("[data-testid='side-panel-toggle']");
      const t = toggle.getBoundingClientRect();
      const hit = document.elementFromPoint(t.left + t.width / 2, t.top + t.height / 2);
      // Libellé = nœuds texte directs de l'onglet (la pastille, en exposant,
      // dépasse exprès de l'onglet : scrollWidth la compterait).
      const label = (tab) => {
        const nodes = Array.from(tab.childNodes).filter((n) => n.nodeType === Node.TEXT_NODE && n.textContent.trim());
        const range = document.createRange();
        range.setStartBefore(nodes[0]);
        range.setEndAfter(nodes[nodes.length - 1]);
        const r = range.getBoundingClientRect(), t = tab.getBoundingClientRect();
        return { text: nodes.map((n) => n.textContent).join('').trim(), clipped: r.left < t.left - 1 || r.right > t.right + 1,
                 text_box: { left: r.left, top: r.top, right: r.right, bottom: r.bottom } };
      };
      return { panel: box(panel), toggle: box(toggle),
               tabs: Array.from(panel.querySelectorAll('.lk-side-panel__tab')).map((tab) => {
                 const l = label(tab);
                 return { label: l.text, clipped: l.clipped, text_box: l.text_box, ...box(tab) };
               }),
               badges: Array.from(panel.querySelectorAll('.lk-side-panel__tab .lk-side-panel__badge')).map((b) => ({
                 text: b.textContent, ...box(b) })),
               clickable: !!hit && (hit === toggle || toggle.contains(hit)) };
    })()
  JS

  # Onglets, pastilles et bouton de repli : disjoints deux à deux, aucune
  # pastille sur un libellé d'onglet, tout dans le panneau, aucun onglet
  # rogné ; au centre du bouton, c'est lui que le navigateur touche.
  def assert_side_panel_header_clear(width)
    m = evaluate_script(HEADER_JS)
    panel, toggle = m["panel"], m["toggle"]
    assert m["clickable"], "bouton de repli du panneau recouvert à #{width} px"
    assert toggle["left"] >= panel["left"] && toggle["right"] <= panel["right"], "bouton de repli hors du panneau à #{width} px"
    m["tabs"].each do |tab|
      refute tab["clipped"], "onglet « #{tab['label']} » rogné à #{width} px"
      assert_operator tab["right"], :<=, panel["right"], "onglet « #{tab['label']} » hors du panneau à #{width} px"
      assert_boxes_disjoint tab, toggle, "« Masquer » sur l'onglet « #{tab['label']} » à #{width} px"
    end
    m["badges"].each do |badge|
      assert badge["left"] >= panel["left"] && badge["right"] <= panel["right"] && badge["top"] >= panel["top"],
        "pastille « #{badge['text']} » hors du panneau à #{width} px (#{badge.inspect})"
      assert_boxes_disjoint badge, toggle, "pastille « #{badge['text']} » sur le bouton de repli à #{width} px"
      m["tabs"].each do |tab|
        assert_boxes_disjoint badge, tab["text_box"], "pastille « #{badge['text']} » sur le libellé « #{tab['label']} » à #{width} px"
      end
    end
  end

  private

  def assert_boxes_disjoint(a, b, message)
    disjoint = a["right"] <= b["left"] || b["right"] <= a["left"] || a["bottom"] <= b["top"] || b["bottom"] <= a["top"]
    assert disjoint, "#{message} : #{a.inspect} / #{b.inspect}"
  end
end
