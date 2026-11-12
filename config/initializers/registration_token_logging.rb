# Rails filters query parameters, but not bearer tokens carried in path segments.
# Masque partagé avec le journal des rapports CSP : TokenPathMask.
module RegistrationTokenLogging
  def filtered_path
    TokenPathMask.mask(super)
  end
end

ActionDispatch::Request.prepend(RegistrationTokenLogging)
