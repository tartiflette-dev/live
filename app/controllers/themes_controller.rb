# Bascule clair/sombre — implémentation fournie par le thème
# (lib/theme.rb : ThemesConcern de la gem pour undust, Theme::Pack::ModeSwitch
# sinon) : cookie `theme` permanent, puis retour à la page courante. L'app n'a
# pas de colonne users.theme : le cookie est le seul store.
class ThemesController < ApplicationController
  include Theme.current.mode_switch
end
