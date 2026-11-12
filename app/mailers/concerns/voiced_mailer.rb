# Tonalité d'un mail (Voice) : le gabarit `<action>.<format>+<tonalité>.erb`
# s'il existe (variante ActionView), sinon le gabarit par défaut ; l'objet
# vient de `voices.<tonalité>.<mailer>.<action>.subject`.
module VoicedMailer
  extend ActiveSupport::Concern

  private

  def speak_as(voice)
    @voice = voice
    lookup_context.variants = [ voice.to_sym ] unless voice == Voice::DEFAULT
  end

  def voiced_subject(**values)
    Voice.t("#{mailer_name}.#{action_name}.subject", voice: @voice, **values)
  end
end
