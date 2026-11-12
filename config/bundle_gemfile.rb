# Gemfile.distribution, quand il existe, remplace Gemfile : une distribution y
# ajoute ses gems (eval_gemfile "Gemfile", puis les siennes) sans toucher au
# Gemfile de l'amont. Un BUNDLE_GEMFILE déjà posé l'emporte. Lu par
# config/boot.rb et bin/setup, avant Bundler.
distribution_gemfile = File.expand_path("../Gemfile.distribution", __dir__)
ENV["BUNDLE_GEMFILE"] ||= File.exist?(distribution_gemfile) ? distribution_gemfile : File.expand_path("../Gemfile", __dir__)
