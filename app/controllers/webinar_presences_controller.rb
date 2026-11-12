# Réponse de présence depuis la page du webinaire, sans passer par le mail :
# le propriétaire et chaque co-animateur connecté répondent pour eux-mêmes
# (Webinar#host_attendance_for). Un animateur du projet qui n'est ni l'un ni
# l'autre n'a pas de présence à donner : 404, comme un compte sans rôle.
class WebinarPresencesController < ApplicationController
  include AnimateurBrowserPolicy
  before_action :authenticate_animateur!

  ANSWERS = { "present" => "Noté : tu seras là.", "absent" => "Noté : tu ne seras pas là." }.freeze

  def create
    webinar = Webinar.where_animated_by(current_user).find_by!(slug: params[:webinar_id])
    attendance = webinar.host_attendance_for(current_user) or raise ActiveRecord::RecordNotFound
    answer = params[:answer].to_s
    return head :unprocessable_entity unless ANSWERS.key?(answer)
    unless webinar.host_attendance_open?
      return redirect_to webinar_path(webinar), alert: "Le café n'est pas publié ou a commencé : plus de présence à donner.",
                                                status: :see_other
    end

    attendance = HostAttendance.for!(webinar, attendance.webinar_host) if attendance.new_record?
    attendance.answer!(answer)
    redirect_to webinar_path(webinar), notice: ANSWERS.fetch(answer), status: :see_other
  end
end
