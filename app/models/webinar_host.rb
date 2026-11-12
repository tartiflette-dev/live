class WebinarHost < ApplicationRecord
  # Co-animateur INVITÉ.
  #
  # Table d'appartenance email ↔ webinaire. Le rapprochement avec un `User`
  # se fait côté lecture : à chaque callback OIDC, l'email normalisé
  # (downcase) sert à comparer dans `Webinar#role_for` (contrat : lien par
  # email, JAMAIS par oidc_sub — invité désigné par email, par un animateur
  # du projet ou le propriétaire). Si l'invité ne s'est jamais connecté,
  # l'enregistrement existe sans `User` correspondant — c'est voulu.
  #
  # Durcissement sécurité (broken-authentication) :
  # `claimed_sub` colle l'invitation au `sub` OIDC à la PREMIÈRE
  # résolution :guest_host réussie (voir Webinar#guest_role_for). Un sub
  # différent présentant le même email ne peut PAS reprendre l'invitation.
  # Nul = jamais revendiquée (encore ouverte à qui que ce soit, à
  # condition d'un email vérifié).
  belongs_to :webinar
  # Présence de ce co-animateur (Webinar::HostPresence) : retirer le
  # co-animateur efface sa réponse et invalide les liens de son mail.
  has_one :host_attendance, dependent: :destroy

  before_validation :normalize_email
  # Nouveau co-animateur, quelle que soit la voie (email, reprise, lien
  # animateur) : sa présence lui est demandée si le webinaire est publié.
  after_create_commit -> { HostAttendanceRequestJob.perform_later(webinar) }

  validates :email,
            presence: true,
            format: { with: URI::MailTo::EMAIL_REGEXP },
            uniqueness: { scope: :webinar_id, case_sensitive: false }
  validates :invited_by_sub, presence: true

  private

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end
end
