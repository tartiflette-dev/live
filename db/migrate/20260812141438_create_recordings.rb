class CreateRecordings < ActiveRecord::Migration[8.1]
  # Recording.
  #
  # Un Recording = une session d'egress room-composite pour un webinaire.
  #
  # Colonnes :
  # `webinar_id`    : FK — un recording appartient à UN webinaire (isolation
  #                   par host_sub côté controller).
  # `egress_id`     : identifiant Twirp renvoyé par livekit-server au start.
  #                   Nullable : si start échoue AVANT retour egress, on
  #                   persiste quand même (status=failed) — invariant
  #                   fail-loud (jamais silencieux). Unique quand présent.
  # `status`        : machine `starting` → `recording` → `stopping` → `done`
  #                   OU `failed` (chemin d'échec). String pour lisibilité
  #                   BDD (SQLite) + validation enum côté modèle.
  # `started_at`,
  # `ended_at`      : horodatage transitions. `started_at` = pose au start
  #                   (source de vérité côté app, pas celui de l'egress qui
  #                   arrive par webhook, non implémenté v1).
  # `path`          : chemin RELATIF au `recordings_root` (jamais absolu :
  #                   défense traversal côté téléchargement). Toujours
  #                   préfixé `<webinar.slug>/…` (validé côté controller).
  # `error_message` : erreur remontée si status=failed (surface UI, log).
  def change
    create_table :recordings do |t|
      t.references :webinar,       null: false, foreign_key: true
      t.string     :egress_id
      t.string     :status,        null: false, default: "starting"
      t.datetime   :started_at
      t.datetime   :ended_at
      t.string     :path
      t.string     :error_message

      t.timestamps
    end

    # Recherche « recording actif » par webinar (index composite).
    add_index :recordings, [ :webinar_id, :status ]
    # egress_id vient de livekit-server → unique quand présent, mais peut
    # être nil (chemin failed pre-retour). Index unique partiel non
    # portable SQLite ; on garde unique simple qui accepte plusieurs NULL
    # sous SQLite (spec sqlite_stat1) — cohérent avec l'invariant fail-loud.
    add_index :recordings, :egress_id, unique: true
  end
end
