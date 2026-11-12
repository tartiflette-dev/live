# Tonalités des émissions

L'application a une tonalité **par défaut** (vouvoiement, sobre) et chaque émission peut avoir **la sienne**, appliquée à tout ce que voit un participant de cette émission. Code : `Voice` (`app/models/voice.rb`), `VoiceHelper#voice_t`.

| Émission (`Webinar.kind`) | Tonalité | Référence |
|---|---|---|
| `cafe_ia` | tutoiement, phrases courtes, chaleureux, concret | le site [tartiflette.dev](https://tartiflette.dev) : en cas d'écart, il fait foi |
| `bootcamp` | défaut | aucune référence donnée pour l'instant |
| hors émission (lien invalide, accueil, agenda, politique de confidentialité, interface animateur) | défaut | — |

## Comment c'est résolu

Le nom d'une tonalité est le `kind` de l'émission (`Webinar#voice`). Une émission qui n'a rien écrit pour elle retombe sur le défaut.

- **Pages et libellés** : clés `voices.<tonalité>.<clé>` dans `config/locales/voices.fr.yml`, avec repli **clé par clé** sur `voices.default.<clé>`. Le contrôleur pose `@voice` (`webinar.voice`, `registration_request.voice`) ; la vue appelle `voice_t("…")`. Hors vue (sujets de mails, message d'erreur du formulaire) : `Voice.t("…", voice:)`.
- **Corps des mails** : variante de gabarit `app/views/registration_mailer/<mail>.<html|text>+<tonalité>.erb`. Sans variante, le gabarit par défaut. Le mailer appelle `speak_as(voice)`.
- **Demande groupée** (API tartiflette.dev, `/confirmer`) : la tonalité commune à tous ses webinaires ; « préviens-moi du prochain » compte comme un Café IA ; une demande qui mêle des émissions prend le défaut.
- La copie est en français : les clés se lisent en `fr` même quand le chrome est en anglais.

Les libellés des cases de consentement (« J'accepte… ») sont à la première personne et restent identiques dans toutes les tonalités : le mail de confirmation et la page `/mc` les citent mot pour mot. Le bouton d'accord de `/mc` (« Oui, j'accepte d'être recontacté·e », clé `marketing_consents.show.accept`) suit la même règle que ceux de `/confirmer` : son libellé, affiché dans la tonalité de l'émission, est figé dans la preuve à l'accord (`marketing_consent_label`) et cité par la note CRM — une tonalité qui réécrit la clé ne change que les accords futurs.

Consentement de la demande groupée : dans **chaque** tonalité, l'annonce dit que la case « a été cochée lors de cette demande » (jamais « vous avez / tu as coché » : un tiers a pu la cocher), et chacun des deux boutons dit ce qu'il accorde. Café IA : « Je confirme, et Acme peut me recontacter » (`marketing=1`) / « Je confirme, sans être recontacté·e » (`marketing=0`). Défaut : « Confirmer et accepter d'être recontacté·e » / « Confirmer sans être recontacté·e ». Le mail cite les libellés de la page de sa tonalité ; un test le vérifie. La preuve de l'accord fige le libellé réellement affiché (`marketing_consent_label`), que la note CRM relit : jamais recalculé à l'envoi.

## Donner sa tonalité à une émission

1. Écrire sous `voices.<kind>` les seules clés qui changent (le reste suit le défaut).
2. Pour réécrire un mail entier : ajouter `<mail>.html+<kind>.erb` **et** `<mail>.text+<kind>.erb`, en gardant tous les liens et mentions obligatoires du gabarit par défaut (lien de confirmation ou d'accès, avertissement « ne clique pas » du bloc marketing, effacement sous 30 jours, lien de retrait, contact@example.org).
3. Tests : `test/integration/voice_pages_test.rb` (pages), `test/mailers/registration_mailer_test.rb` (les invariants tournent sur chaque tonalité), un aperçu `*_<kind>` dans `test/mailers/previews/registration_mailer_preview.rb` (le test des aperçus exige un aperçu par mail et par tonalité).
