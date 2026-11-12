# Reprise du direct : une piste encore publiée quand le
# direct est terminé puis repris doit être enregistrée de nouveau, dans un
# nouveau fichier. L'index unique (webinaire, track_sid) l'interdisait : la
# piste gardait son unique Recording, clos à la fin du direct.
#
# La revendication d'une piste reste exclusive tant qu'elle
# capte : au plus UN Recording actif par piste. Les Recordings clos d'une
# même piste coexistent, un par tentative. L'index non unique sert la
# recherche par piste (FinalizeEgressJob).
#
# Retour arrière : il échoue (contrainte) dès qu'une piste a été
# enregistrée de nouveau après une reprise du direct — ses Recordings
# successifs ne tiennent plus sous l'ancienne unicité, et la base ne doit
# pas en oublier un en silence.
class ScopeTrackClaimToActiveRecordings < ActiveRecord::Migration[8.1]
  def change
    remove_index :recordings, %i[webinar_id track_sid], unique: true, name: "index_recordings_on_webinar_id_and_track_sid"
    add_index :recordings, %i[webinar_id track_sid], name: "index_recordings_on_webinar_id_and_track_sid"
    add_index :recordings, %i[webinar_id track_sid],
              unique: true,
              where: "track_sid IS NOT NULL AND status IN ('starting', 'recording', 'stopping')",
              name: "index_recordings_on_active_track_claim"
  end
end
