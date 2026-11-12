# Auto-start du recording quand l'animateur rejoint la salle.
# Un seul Recording composite ACTIF par
# webinaire est désormais un INVARIANT DB : la garde applicative
# (RecordingsController#create + RecordingSession.ensure_active) est
# doublée d'un index unique partiel côté SQLite pour éliminer la race
# « deux onglets / reload concurrent → deux Recording starting » que la
# garde métier seule laisse passer (contrôle → INSERT non atomique).
#
# SCOPE au kind='composite' : le composite = le direct enregistré (1 par
# webinaire). Les tracks (kind='track') représentent des egress par
# participant/source et coexistent — l'index ne les contraint
# pas.
#
# SQLite (≥ 3.8) supporte les index partiels avec WHERE (cf.
# https://www.sqlite.org/partialindex.html). Rails traduit `where:` en
# clause CREATE UNIQUE INDEX ... WHERE ....
#
# NETTOYAGE PRÉ-INDEX : la sonde prod n'a montré AUCUN
# doublon (1 seul Recording actif — un reliquat non réconcilié). Mais on
# ne peut pas GARANTIR l'absence de
# doublons sur toutes les DB futures (data prehistoric, bug applicatif,
# base recréée). On sécurise donc la migration : avant add_index, on
# ferme (status=failed, message tracé) tous les Recordings actifs
# EXCÉDENTAIRES (on garde le plus récent par webinaire).
#
# NB — l'ordonnancement temporel garantit que `add_kind_to_recordings`
# (20260921161000) a déjà tourné : la colonne `kind` existe. Une base qui
# n'a pas encore appliqué les track migrations les roule AVANT celle-ci,
# dans l'ordre timestamp.
class AddActiveRecordingUniqueIndexToRecordings < ActiveRecord::Migration[8.0]
  def up
    close_duplicate_active_composites!
    add_index :recordings,
              :webinar_id,
              unique: true,
              where: "kind = 'composite' AND status IN ('starting', 'recording', 'stopping')",
              name: "index_recordings_on_active_composite_webinar_id"
  end

  def down
    remove_index :recordings, name: "index_recordings_on_active_composite_webinar_id"
  end

  private

  # Ferme les Recordings actifs composites EXCÉDENTAIRES par webinaire :
  # on garde le plus récent (max updated_at, id DESC), les autres sont
  # marqués failed avec un message traçable. No-op si aucun doublon.
  def close_duplicate_active_composites!
    rows = select_all(<<~SQL).to_a
      SELECT webinar_id, COUNT(*) AS c
        FROM recordings
       WHERE kind = 'composite'
         AND status IN ('starting', 'recording', 'stopping')
       GROUP BY webinar_id
      HAVING COUNT(*) > 1
    SQL

    rows.each do |row|
      wid = row["webinar_id"]
      execute(<<~SQL)
        UPDATE recordings
           SET status = 'failed',
               error_message = COALESCE(error_message, 'doublon actif nettoyé par migration 20260924143739'),
               ended_at = COALESCE(ended_at, CURRENT_TIMESTAMP)
         WHERE kind = 'composite'
           AND status IN ('starting', 'recording', 'stopping')
           AND webinar_id = #{wid.to_i}
           AND id NOT IN (
             SELECT id FROM recordings
              WHERE kind = 'composite'
                AND status IN ('starting', 'recording', 'stopping')
                AND webinar_id = #{wid.to_i}
              ORDER BY updated_at DESC, id DESC
              LIMIT 1
           )
      SQL
    end
  end
end
