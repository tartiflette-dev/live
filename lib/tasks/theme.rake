namespace :theme do
  desc "Écrit app/assets/tailwind/theme.css pour le thème choisi (BRAND_THEME) et synchronise ses sources"
  task sync: :environment do
    Theme.current.sync_assets!
    Rails.root.join("app/assets/tailwind/theme.css").write(Theme.current.stylesheet)
  end
end

task "tailwindcss:build" => "theme:sync"
task "tailwindcss:watch" => "theme:sync"
