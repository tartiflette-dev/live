# Pack de thème : le contrat

Un pack est un dossier `themes/<nom>/`, choisi par `BRAND_THEME=<nom>` au build et au démarrage.
Le nom suit `[a-z0-9][a-z0-9_-]*`. Un pack est du code de confiance : son `logo.svg` est injecté tel
quel dans les pages, et son CSS s'applique partout.

| Fichier | Obligatoire | Rôle |
|---|---|---|
| `theme.yml` | oui | Identité (clés ci-dessous) |
| `tokens.css` | non | Valeurs des custom properties. Sans ce fichier : jetons neutres de l'app |
| `chrome.css` | non | Retouches du chrome, chargées après le chrome par défaut |
| `assets/logo.svg` | non | Logo en ligne, décoratif. Sans ce fichier : logo neutre |
| `assets/favicon.svg` | non | Favicon. Sans ce fichier ni clé `favicon` : favicon neutre |
| `assets/*` | non | Tout autre fichier servi, par exemple `assets/fonts/` |

Seul `assets/` est servi au navigateur. Le reste du dossier (README, `theme.yml`, captures) ne quitte
pas le dépôt.

## `theme.yml`

```yaml
product_name: "Exemple Live"     # obligatoire
theme_color: "#101418"           # obligatoire, <meta name="theme-color">
default_mode: "dark"             # light (défaut) ou dark, mode sans cookie
favicon: "favicon.svg"           # chemin dans assets/
credit:                          # obligatoire, mention de bas de page
  label: "Propulsé par Exemple"  # obligatoire
  url: "https://exemple.example" # obligatoire
links:                           # liens affichés à côté du crédit
  site: "https://exemple.example"
```

Les URL de `credit` et de `links` doivent être en `http(s)` : toute autre valeur est refusée au
démarrage. Le nom de l'organisation qui opère l'instance n'appartient pas au pack : chaque instance
le pose par `BRAND_ORGANIZATION`. `config/brand.yml` puis les variables `BRAND_<CHEMIN>` (`BRAND_HOST`, `BRAND_CREDIT_URL`…)
priment sur ces valeurs. `BRAND_CREDIT_SHOWN=false` retire le crédit et ses liens du bas des pages
(chrome par défaut, connexion, salle) : la mention n'est pas une condition de la licence.

## `tokens.css` et `chrome.css`

`tokens.css` doit définir toutes les propriétés listées dans [le contrat de
propriétés](theme-contract.md), en mode clair (`:root`) et, s'il le souhaite, en mode sombre
(`[data-theme="dark"]`).

Les deux feuilles ne sont pas servies telles quelles : `theme:sync` les fait inliner par Tailwind
dans `tailwind.css`. Leurs `url()` s'écrivent donc comme vues depuis `assets/`
(`url("fonts/ma-police.woff2")`) : Propshaft les y résout. Un `url()` qui désigne un fichier absent de
`assets/` fait échouer les tests.

## Vérifier un pack

```sh
npm ci && BRAND_THEME=<nom> BUNDLE_GEMFILE=Gemfile bin/rails javascript:build
BRAND_THEME=<nom> BUNDLE_GEMFILE=Gemfile bin/rails tailwindcss:build
BRAND_THEME=<nom> BUNDLE_GEMFILE=Gemfile bin/rails test test/lib/theme_test.rb test/lib/theme_contract_test.rb test/integration/theme_smoke_test.rb
```
