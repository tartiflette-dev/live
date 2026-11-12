# Rappel de la veille (J-1)

La veille d'un webinaire, chaque inscription confirmée reçoit un mail avec le lien pour rejoindre le direct. C'est la promesse du formulaire de tartiflette.dev (« on t'envoie le lien du café la veille »). Code : `RegistrationReminder` (`app/services/registration_reminder.rb`), `RegistrationReminderJob`, `RegistrationMailer#reminder`.

## Quand

- Le job passe **toutes les heures pleines de 09:00 à 20:00, heure de Paris** (`config/recurring.yml`, cron `0 9-20 * * * Europe/Paris`, fuseau écrit dans le cron = `RegistrationReminder::SEND_HOURS`, testé). Jamais la nuit.
- À chaque passage, il sert les inscriptions **confirmées** (double opt-in) aux webinaires **publiés**, **pas encore lancés** (`state: draft`), qui commencent **le lendemain** (jour calendaire de Paris), sans rappel déjà pris pour cette date.
- Exemple : Café IA #8, mercredi 4 novembre 2026 à 09:30 → premier passage le mardi 3 novembre à 09:00 (08:00 UTC).
- Confirmation arrivée pendant la journée de la veille → rappel au passage suivant (une heure au plus).
- Confirmation arrivée après 20:59 la veille, ou le jour même → **pas de rappel**. Choix assumé : la page de confirmation donne déjà le lien du direct, et le mail de demande (`/confirmer`) dit de le garder ; un mail de plus, quelques minutes après, n'apporterait rien.
- Webinaire dépublié (traité comme annulé, l'app n'a pas d'état « annulé »), lancé ou terminé → rien. Webinaire déplacé à une autre date après le rappel → un rappel pour la nouvelle date. Le déplacement et l'annulation ont leur propre mail, dix minutes après le changement ([agenda.md](agenda.md), « Change notices »).

## Contenu

Dans la tonalité de l'émission ([tonalites.md](tonalites.md)), sans marketing. Café IA : tutoiement de tartiflette.dev, sujet `C'est demain, 9 h 30 : <titre>`, « Prépare ton café » (gabarits `reminder.*+cafe_ia.erb`). Tonalité par défaut (bootcamp) : vouvoiement sobre, sujet `Rappel — <titre>, demain à 09h30`. Dans les deux :

- l'objet ;
- titre, date et heure de Paris ;
- le sujet annoncé du café s'il y en a un (`Webinar::Program`, gabarits `_program.*.erb`) : « Au programme : <sujet> », les intervenants annoncés, puis sa présentation ;
- le lien personnel `/r/:token` : c'est le lien de confirmation (formulaire) et celui que la page `/confirmer` donne pour chaque café (API tartiflette.dev). Pour une inscription confirmée, il pose le cookie d'accès et ouvre la page du webinaire, d'où l'on rejoint le direct ;
- l'événement en pièce jointe (`<slug>.ics`, `WebinarCalendar#event`, même UID que `/w/:slug.ics` : un agenda qui l'a déjà le met à jour). Il ne contient ni jeton ni adresse.

Pas de lien de retrait marketing : le mail de confirmation n'en porte pas, et ce rappel n'est pas de la prospection.

## Une seule fois

L'état vit dans `registrations.reminder_sent_at` (json). Une ligne effacée par `crm:erase` emporte son état et ne reçoit rien.

| Clé | Sens |
|---|---|
| `j1_starts_at` | début du webinaire visé (UTC, ISO 8601) : le verrou |
| `j1_attempted_at` | prise du verrou, avant tout appel SMTP |
| `j1` | remise acceptée par le serveur SMTP |
| `j1_error` | classe de la dernière erreur d'envoi |
| `j1_attempts`, `j1_attempts_for` | tentatives (prises de verrou) pour cette date de début |
| `j1_abandoned_at` | abandon définitif après 2 refus temporaires |

Le mail est rendu d'abord (une vue cassée ne verrouille rien), puis le verrou est pris par un `UPDATE` conditionnel unique qui revérifie tout : inscription confirmée, webinaire publié, pas lancé, même date de début, pas de verrou pour cette date. SQLite sérialise les écritures : deux exécutions concurrentes, un redémarrage ou un rejeu n'envoient qu'une fois.

SQLite et SMTP ne partagent pas de transaction. Après une erreur :

- **le serveur n'a certainement pas accepté le message** (connexion refusée ou impossible, délai d'ouverture, authentification refusée, refus temporaire 4xx) → le verrou est rendu, nouvel essai au passage suivant, **au plus 2 tentatives par date** (`RegistrationReminder::MAX_ATTEMPTS`). Au-delà : abandon définitif, `j1_abandoned_at` posé, erreur rapportée avec `abandoned: true`. Ce plafond couvre le seul cas ambigu de cette famille : un 4xx au `QUIT`, renvoyé par `Net::SMTP#start` depuis son `ensure` APRÈS un DATA accepté, qui renverrait sinon le message à chaque passage ;
- **sinon** (coupure en cours d'envoi, délai de réponse, refus définitif 5xx, erreur inconnue, processus arrêté entre le verrou et l'envoi) → le verrou reste, **jamais de second envoi automatique**. Un rappel peut manquer, il ne double jamais.

Chaque erreur est rapportée à `Rails.error` (ligne `msg=AppError` sans donnée personnelle, contexte `registration_id`, `webinar_id`, `retry_next_round`). Le job ne lève pas : Solid Queue ne le rejoue pas.

Inspection en production (lecture), dans `kamal app exec -i --reuse "bin/rails console"` :

```ruby
Registration.where("json_extract(reminder_sent_at, '$.j1_error') IS NOT NULL").pluck(:id, :reminder_sent_at)
```

Une ligne avec `j1_attempted_at` sans `j1` a une issue inconnue : vérifier dans les journaux du fournisseur SMTP avant tout renvoi manuel.

## Supervision

Chaque tournée (drapeau à 1) écrit :

- une ligne de journal, sans donnée personnelle : `registration_reminder due=3 sent=2 skipped=0 smtp_retry=1 abandoned=0 failed=0`. `due` = inscriptions concernées par la tournée (confirmées, webinaire du lendemain), `skipped` = déjà traitées pour cette date ou devenues inéligibles, `smtp_retry` = refus temporaire avec nouvel essai, `abandoned` = plafond de 2 tentatives atteint, `failed` = rendu impossible ou issue SMTP incertaine (verrou gardé) ;
- une ligne `registration_reminder_runs` (mêmes compteurs, `ran_at`), conservée 30 jours (purge à chaque tournée).

La sonde `GET /internal/crm_status` les expose dans un bloc `reminders`, **informatif** :

```json
"reminders": {"enabled": true,
  "last_run_at": "2026-11-03T10:00:00+01:00",
  "last_run": {"due": 3, "sent": 0, "skipped": 2, "smtp_retry": 1, "abandoned": 0, "failed": 0},
  "today": {"sent": 2, "skipped": 2, "smtp_retry": 1, "abandoned": 1, "failed": 0}}
```

Il n'entre **pas** dans `alert` : la règle d'alerte (et donc le code HTTP 200/503) reste celle de la synchro CRM, que la supervision HTTP suit déjà. Pourquoi ici malgré le nom : c'est la seule sonde authentifiée de l'app, déjà branchée, et ses réponses ne portent que des compteurs. Pour une alerte dédiée sans toucher à la règle CRM, une supervision HTTP qui lit le corps JSON (Gatus, par exemple) peut tester : condition `[BODY].reminders.today.abandoned == 0` et `[BODY].reminders.today.failed == 0`, plus, la veille d'un webinaire, `[BODY].reminders.last_run_at` récent (moins de 70 min entre 09:00 et 21:00). Ce branchement est un réglage de la supervision, hors de ce dépôt.

## Couper, rallumer

`REMINDERS_ENABLED` : `"1"` pour envoyer, posée par le déploiement de l'instance de production ; `"0"` sur une instance de pré-production (avec Kamal, la destination remplace la valeur de la base) ; absent = coupé (dev, test). Couper = repasser à `"0"` et redéployer. La tâche récurrente reste déclarée : sans le drapeau, elle ne fait rien.
