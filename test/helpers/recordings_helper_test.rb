require "test_helper"

class RecordingsHelperTest < ActionView::TestCase
  def rec(seconds, ended: true)
    start = Time.zone.parse("2026-10-06T19:00:00")
    Recording.new(started_at: start, ended_at: (start + seconds if ended))
  end

  test "durée lisible en français" do
    assert_equal "38 s", duree_enregistrement(rec(38))
    assert_equal "12 min 05 s", duree_enregistrement(rec(725))
    assert_equal "1 h 03 min", duree_enregistrement(rec(3790))
    assert_equal "—", duree_enregistrement(rec(10, ended: false))
  end
end
