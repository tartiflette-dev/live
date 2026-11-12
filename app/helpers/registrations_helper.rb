module RegistrationsHelper
  def registration_privacy_url
    value = ENV["REGISTRATION_PRIVACY_URL"].presence
    uri = URI.parse(value) if value
    value if uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil?
  rescue URI::InvalidURIError
    nil
  end
end
