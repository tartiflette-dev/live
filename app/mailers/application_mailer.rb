class ApplicationMailer < ActionMailer::Base
  default from: -> { Brand.mailer_from }
  layout "mailer"
  helper OrganizationHelper, SeriesHelper
end
