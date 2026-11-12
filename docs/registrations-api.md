# Inscriptions cross-origin et CRM

API d'inscription pour un site partenaire, et poussée des inscrits vers le
CRM de l'opérateur de l'instance. Code :
`Api::RegistrationsController`, `RegistrationSubmission`,
`RegistrationRequest`, `RegistrationRequestsController`, jobs `Crm*`.

## API — `POST /api/registrations`

Corps JSON (`Content-Type: application/json`, sinon 415) :

| Champ | Type | Règle |
|---|---|---|
| `name` | string | obligatoire, ≤ 120 (le prénom suffit) |
| `email` | string | obligatoire, format email, ≤ 254 |
| `slugs` | string[] | 0 à 3 slugs ; doublons fusionnés ; un slug inconnu, en brouillon, terminé ou présumé annulé (`Webinar#past?`) est ignoré |
| `notify_next` | bool | « Pas dispo, préviens-moi du suivant » |
| `profile` | string | facultatif : `conception`, `fabrication`, `design`, `dev`, `autre` |
| `message` | string | facultatif, ≤ 2000 |
| `participation` | string | facultatif, additif : `"spectator"` (défaut si absent ou `null` : regarder, discussion, main levée) ou `"participant"` (veut intervenir en caméra et micro : sa main se lève d'office à son entrée dans la salle, l'animation l'admet). Toute autre valeur → `inclusion`. Porté par chaque inscription **créée** par la soumission ; une inscription retrouvée garde son choix. Une version du site qui l'ignore n'y perd rien : sans lui, la salle demande le choix à l'entrée, une fois (`participation_chosen_at`, cf. [hand-raises.md](hand-raises.md)) |
| `marketing_consent` | bool | facultatif, défaut `false` : case « Ok pour qu'Acme me recontacte au sujet de ses activités. Je peux dire stop quand je veux. » (Acme : l'organisation de l'instance, `BRAND_ORGANIZATION`), décochée par défaut. Seuls les booléens JSON sont acceptés (`"true"`, `1`, `"no"` → `invalid`) ; `true` pose le consentement marketing au clic de confirmation (voir plus bas) |
| `consent` | — | retiré (politique v1.6, 31/10/2026) : envoyé par une version antérieure du site, il est ignoré, quelle que soit sa valeur |
| `source` | string | facultatif, liste blanche : `tartiflette.dev` |
| `website` | string | champ piège, à rendre caché et laisser vide |

Réponses :

- `202 {"status":"pending_confirmation","webinars":["<slugs retenus>"]}` — identique qu'une inscription existe déjà ou non (pas d'oracle), et si le champ piège est rempli (aucun effet).
- `422 {"status":"invalid","errors":{"<champ>":["<code>"]}}` — codes : `blank`, `invalid`, `too_long`, `inclusion`, `too_many` (> 3 slugs), `no_open_webinar` (aucun café retenu et pas de `notify_next`).
- `403` sans en-tête CORS : origine absente ou hors liste.
- `400 {"status":"invalid","errors":{"body":["malformed_json"]}}` : corps JSON illisible (en-têtes CORS présents).
- `429 {"status":"rate_limited"}` : 10 requêtes/minute/IP (préfixe /64 pour une IPv6), compteur COMMUN avec le formulaire HTML (`scope: :registrations`, `RegistrationRateLimitStore`). Indépendamment de l'IP, un mail à une adresse non prouvée est limité par destinataire : 1 par flux (inscription) toutes les 10 min, 6 par 24 h et par flux, 10 renvois par 24 h par adresse tous flux confondus ; la première confirmation d'une inscription neuve est hors de ce total (`RecipientMailThrottle`, modèle et borne dans son en-tête). La réponse `202` est identique, mail parti ou non.
- `503 {"status":"unavailable"}` : `REGISTRATION_PRIVACY_URL` non configurée (même règle que le formulaire HTML).

CORS : `OPTIONS /api/registrations` répond 204 avec `Access-Control-Allow-Origin: <origine>`, `Allow-Methods: POST`, `Allow-Headers: Content-Type`, `Max-Age: 600`, `Vary: Origin`. Jamais `Allow-Credentials`, jamais de cookie (ActionController::API). L'origine est contrôlée côté serveur : un formulaire posté depuis un autre site est refusé avant tout effet.

Exemple (serveur local) :

```
POST /api/registrations
Origin: https://site.example.org
Content-Type: application/json

{"name":"Camille","email":"camille@example.test","slugs":["cafe-ia-novembre","cafe-termine-ou-inconnu"],
 "notify_next":false,"profile":"dev","message":"Hâte d y être.","marketing_consent":false,"source":"tartiflette.dev","website":""}

HTTP/1.1 202 Accepted
access-control-allow-origin: https://site.example.org
vary: Origin
{"status":"pending_confirmation","webinars":["cafe-ia-novembre"]}
```

Côté site : `fetch("https://live.example.org/api/registrations", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) })`, sans `credentials`.

## Effets et confirmation

- Une `RegistrationRequest` porte la soumission (nom, email, source, profil, message, `notify_next`) et les inscriptions **nouvelles** (une par café). Une inscription existante n'est jamais modifiée ni rattachée ; si elle est en attente, elle reçoit à nouveau son propre lien `/r/:token`, comme avec le formulaire HTML.
- **Un seul mail** pour les inscriptions créées par la soumission, avec un seul lien `GET /confirmer?t=<token>` : page sans effet (scanners de liens), bouton → `POST /confirmer?t=` qui confirme la demande et toutes ses inscriptions. La page confirmée liste les cafés et leur lien personnel `/r/:token` (cookie, accès au direct) ; le lien du mail reste la page d'accès. Cas mixte : si la soumission retrouve aussi une inscription existante EN ATTENTE, celle-ci reçoit en plus son propre mail (son lien `/r/:token`), donc deux mails au total.
- **Expiration** : sans confirmation, la demande et ses inscriptions sont effacées 30 jours après (`RetentionPurgeJob`), et le lien répond 410 au même terme. Une demande confirmée garde son lien.
- **Pages à bouton** (`/confirmer`, `/r/:token`, `/mc`, `/mc/withdraw`) : `Referrer-Policy: strict-origin` (concern `TokenLinkPage`). Avec `no-referrer`, le navigateur envoie `Origin: null` sur le POST du bouton et la protection CSRF de Rails le refuse.
- **Case de recontact** (`marketing_consent: true`, politique v1.6) : retenue sur la demande (`registration_requests.marketing_box_checked` — cochée lors de la demande, par la personne ou par un tiers : l'API n'est pas authentifiée), sans aucun effet avant confirmation. Le mail de demande dit que la case « a été cochée lors de cette demande » et annonce le choix ; la page `/confirmer` offre alors DEUX boutons explicites, libellés dans la tonalité de la demande ([tonalites.md](tonalites.md)) : pour un Café IA (tout le parcours tartiflette.dev, « préviens-moi » compris) « Je confirme, et Acme peut me recontacter » (`POST /confirmer?t=…&marketing=1`) et « Je confirme, sans être recontacté·e » (`marketing=0`) ; pour une demande qui mêle d'autres émissions, « Confirmer et accepter d'être recontacté·e » / « Confirmer sans être recontacté·e ». Le libellé du bouton cliqué est figé dans la preuve (`marketing_consent_label`, politique v1.7) et cité dans la note CRM. Seul `marketing=1` accorde : un POST sans choix n'accorde rien (`RegistrationRequest#confirm!(marketing_consent: false)` par défaut).
  - Choix offert si la case est cochée ET que la page a de quoi le porter (`marketing_choice_offered?`) : des cafés affichés (`published_registrations`) ou, à défaut, le « préviens-moi ». Sinon, ni avis ni choix.
  - Accord posé, daté, sur les cafés affichés créés par la demande (`Registration#grant_marketing_consent!`) — jamais sur une inscription existante, jamais après un retrait ; sans café, sur la demande elle-même (`RegistrationRequest#grant_marketing_consent!`, colonnes `marketing_consent*`). Pas de second mail.
  - Preuve FIGÉE à l'accord : `registrations.marketing_consent_source` (`tartiflette.dev`, `api`, `live.example.org`), `marketing_consent_path` (`/confirmer`, `/mc`), `marketing_consent_policy_version`, `marketing_consent_request_id` (+ `marketing_consent_at`). La poussée CRM relit ces valeurs, sans les recalculer. Côté demande : `marketing_consent_at`, `marketing_consent_policy_version`, la provenance et la page étant celles, immuables, de la demande.
  - Le libellé du bouton d'accord est figé de même (`marketing_consent_label`, politique v1.7), sur /confirmer comme sur /mc (« Oui, j'accepte d'être recontacté·e », dans la tonalité de l'émission) : la note CRM le cite ; les accords /mc antérieurs au figement gardent NULL et la note cite alors la constante « lien dédié /mc (jeton à usage unique) ». Aucune reprise des consentements existants.
  - Retrait (`/mc/withdraw?t=`, lien sur la page confirmée) : vaut pour la PERSONNE — toutes les inscriptions et demandes consenties de cet email (le jeton prouve la possession de la boîte).
- `notify_next` sans café : la demande seule, confirmée de la même façon, poussée au CRM par `CrmNotifyNextJob`.
- **Lien d'agenda personnel** : la première confirmation d'une personne (demande ou inscription, « préviens-moi » seul compris) lui envoie, une seule fois, son lien `/agenda/<jeton>.ics` (`CalendarSubscription`, [agenda.md](agenda.md)).
- Conservation : demande confirmée purgée 12 mois après sa création, une fois ses inscriptions purgées ; non confirmée, 30 jours (`RetentionPurgeJob`).
- Formulaire HTML (`/w/:slug/registrations`) : le lien `/r/:token` du mail affiche une page à bouton SANS effet ; le POST confirme. Une inscription déjà confirmée garde le GET comme lien d'accès (cookie + redirection), sans effet CRM. C'est ce lien `/r/:token` que porte le rappel de la veille, pour les deux parcours ([registration-reminders.md](registration-reminders.md)).

## CRM

L'instance pousse ses inscrits vers un CRM de contacts que fournit son opérateur, par un adaptateur HTTP générique (`Crm::HttpContactsClient`). Le CRM implémente le contrat décrit plus bas (§Contrat HTTP du CRM) ; sans `CRM_SYNC_ENABLED=1`, rien n'est poussé.

- Tout inscrit **confirmé par un POST** sous la politique v1.1 (`registrations.crm_enrolled_at`) entre au CRM (base légale depuis la politique v1.6 : intérêt légitime, art. 6.1.f, droit d'opposition par contact@example.org puis `crm:erase`). Les inscrits confirmés sous la v1.0 n'y entrent pas après coup — sauf ceux qui ont validé le consentement `/mc` et ne l'ont pas retiré : la migration `20261031090100_enroll_legacy_marketing_consents` leur pose `crm_enrolled_at = marketing_consent_at` et `crm_backfilled_at` (marqueur de la reprise, défaite exactement par `down`) ; CrmResyncJob les pousse à l'activation. Un inscrit v1.0 qui valide `/mc` plus tard entre au CRM à ce moment. Conservation au CRM : sans date de fin, tant que la personne n'en demande pas la suppression (politique v1.2) ; un retrait du consentement garde la fiche. Fiche trouvée par email ou créée (`crm_contact_id` = identifiant unique de la personne), segment `participant` (realm `professional`, `POST /api/v1/contacts/:id/segments`), interaction « Inscription webinaire — titre » (source `live.example.org:<slug>`, notes : choix spectateur / participant, provenance, profil, message). Le choix va dans les notes, seul champ libre du contrat : segment et `source_path` restent figés. Une inscription à accès immédiat pendant le direct n'entre au CRM qu'à sa confirmation, comme les autres. Marqueur `pushed_to_crm_at`.
- Le consentement marketing (POST `/mc`, ou confirmation d'une demande à case cochée) est une poussée **distincte** : interaction « Consentement marketing » (source `live.example.org:marketing_consent:<slug>`, `source_path` `/mc` ou `/confirmer` selon la preuve), marqueur `crm_marketing_consent_pushed_at`. Seule autorisation de prospection. Le retrait reste propagé (`CrmMarketingWithdrawalJob`) ; la fiche du participant reste.
- `notify_next` : interaction « Veut être prévenu·e du prochain Café IA » (source `live.example.org:notify_next`) + segment. Si la demande porte l'accord de recontact (sans café), `CrmNotifyNextJob` pousse aussi « Consentement marketing » (source `live.example.org:marketing_consent:notify_next`, `/confirmer`, marqueur `crm_marketing_consent_pushed_at`) puis, après retrait, « Retrait du consentement marketing » (source `live.example.org:withdrawal:notify_next`, `/mc/withdraw`, marqueur `crm_withdrawal_pushed_at`) ; même file et même compteur que le « préviens-moi » (`RegistrationRequest.crm_pending`).
- Les jobs CRM d'une même personne sont sérialisés (`limits_concurrency`, clé = empreinte SHA-256 de l'email) : trois cafés confirmés d'un clic ne créent qu'une fiche.
- Ordre : fiche → segment → interaction. Un segment refusé abandonne avant l'interaction ; la reprise retrouve la fiche.
- **Reprise** : `CrmResyncJob` (récurrent, toutes les 30 min en production, sous `CRM_SYNC_ENABLED`) ré-enqueue ce qui est **dû** (`Crm::Backlog`) : inscriptions (participant ou consentement), « préviens-moi », retraits. Pas de plafond qui gèle : une ligne jamais tentée attend 15 min (le job lancé à la confirmation passe d'abord). Après un enqueue par la reprise ou un échec, elle attend **au moins 45 min** (un tour de reprise de 30 min + marge : le job peut encore être en file ou dans sa chaîne de retry ; le tour suivant ne le ré-enqueue donc pas), puis 15 min × 2^(n−1) après n échecs, plafonnée à **24 h** — une ligne en échec est retentée au moins une fois par jour, sans fin. Une `Crm::ContractError` (corps hors politique, détecté avant l'envoi) est un échec permanent compté, code 422. Le **retrait** a son propre compteur (`crm_withdrawal_attempts`, `crm_withdrawal_last_attempt_at`, `crm_withdrawal_last_error_code`) : une inscription en échec ne le retarde jamais. Journal : `[CrmResyncJob] crm_resync pending=… enqueued=… failing=… permanent_failures=…`, `warn` dès qu'une ligne échoue.
- **Quota du CRM (429)** : le CRM peut plafonner les requêtes du jeton (`429 {"error":"rate_limited"}` + `Retry-After` en secondes ou date HTTP). Un 429 lève `Crm::RateLimitedError` ; le job s'arrête **sans retry SolidQueue** (cinq retries brûleraient le quota en quelques minutes) et la ligne attend `*_next_attempt_at` = Retry-After — au moins **1 h** si la fenêtre dépasse la minute (quota long, journalier par exemple) —, code 429, **sans tentative comptée** ni échec permanent. En pratique, seul un quota long retarde au-delà de la garde de 45 min : un Retry-After de la fenêtre minute (≤ 60 s) est absorbé par elle. Journal : `[CrmSyncJob] rate_limited registration_id=… http_status=429 retry_in=…`.
- **Moins de lookups** : une fiche déjà connue localement pour le même email (`crm_contact_id` d'une autre inscription ou d'une demande, `Crm.known_contact_id`) est réutilisée sans lookup ; un id périmé est relocalisé par le 404 de preuve (nouveau lookup, un seul nouvel essai, jamais de création). Fiche partie côté CRM :
  - **Disparition déduite** (404 de preuve puis lookup vide) : n'autorise **jamais** une création — ce n'est qu'une déduction (effacement, mais aussi email changé côté CRM). Enregistrée par id CRM (`crm_disappearances`, sans donnée personnelle) ; la ligne passe dans l'**état terminal de sa file** (`registrations.crm_sync_contact_gone_at` pour inscription et consentement `/mc`, `registration_requests.crm_contact_gone_at` pour « préviens-moi ») : sortie de la reprise, comptée par la sonde (`contact_gone`, `disappeared_contacts`), **sans 503**. L'état terminal d'une file ne ferme pas les autres.
  - **Retrait** sur fiche introuvable : **jamais un succès**. Échec permanent `withdrawal_contact_not_found` (code 404, compteur du retrait) → sonde en **503** (`withdrawal_contact_not_found`), un humain vérifie la fiche dans le CRM (email changé ? fiche fusionnée ?) et propage le retrait. Retenté au plus une fois par jour.
  - **Effacement explicite** = seule source d'autorisation (`crm_erasures` : empreinte HMAC-SHA256 de l'email normalisé, clé dérivée dédiée `crm-erasure-email-digest`, jamais l'email en clair ; `erased_at` = date du DERNIER effacement, jamais en recul). Une ligne confirmée **strictement après** `erased_at` crée normalement ; une ligne confirmée avant n'écrit rien, ni sur sa fiche ni par relocalisation (`ContactGoneError(:erased)`, état terminal). Un id emprunté n'est enregistré sur la ligne qu'une fois l'écriture passée ; un job mort entre la création et l'écriture de l'id est rattrapé par le lookup de la reprise. Rotation de `secret_key_base` = empreintes existantes inopérantes, à reporter avant.

### Effacement d'une personne — procédure

Quand une demande d'effacement (contact@example.org) est traitée :
1. effacer la fiche dans le CRM ;
2. lancer `crm:erase` avec l'adresse **sur l'entrée standard** (forme nominale) : `printf '%s' 'adresse@exemple.fr' | bin/rails crm:erase` — en production : `printf '%s' 'adresse@exemple.fr' | kamal app exec --reuse -i "bin/rails crm:erase"`. `EMAIL=<adresse>` reste accepté mais déconseillé (l'adresse reste dans l'historique du shell et dans `ps`) ; la tâche le signale. Elle enregistre l'effacement (empreinte, date), **supprime** les inscriptions (et mains levées) et demandes de cet email, **neutralise** ses messages de discussion (texte remplacé par « [message retiré] », nom par « Participant·e (effacé·e) »), **supprime** son abonnement à l'agenda personnel, et n'affiche que des compteurs (`registrations=… registration_requests=… hand_raises=… messages=… calendar_subscriptions=…`) ;
3. lire la fin de la sortie : un rappel de vérifier le CRM, puis le résultat d'un **lookup en lecture seule** (une requête, aucune écriture) — « aucune fiche trouvée », « une fiche existe ENCORE (id …) » → l'effacer dans le CRM, ou « vérification impossible » (jeton absent, CRM en erreur) → vérifier à la main. La tâche n'écrit jamais dans le CRM.

Hors de la tâche : les passages enregistrés où la personne a pris la parole (enregistrements, transcriptions) se retirent à part, sur demande (politique, « Prise de parole »).
- **Remise en file** (après correction d'une panne : CRM redéployé, jeton réparé) : `bin/rails crm:requeue` — remet les compteurs et l'attente à zéro pour tout ce qui reste à pousser, puis enqueue immédiatement. N'affiche que des compteurs ; sans effet si `CRM_SYNC_ENABLED != 1`. En production : `kamal app exec --reuse "bin/rails crm:requeue"`.

### Sonde — `GET /internal/crm_status`

Pour la supervision. Fermée par défaut : sans `CRM_STATUS_TOKEN` (ou avec une valeur vide), 404 ; avec, exactement `Authorization: Bearer <CRM_STATUS_TOKEN>` (401 sinon, y compris pour le jeton nu). `Cache-Control: no-store`. Aucune donnée personnelle : compteurs et dates.

```json
{"crm_sync_enabled":true,
 "pending":{"registrations":0,"notify_next":0,"withdrawals":0,"total":0},
 "oldest_pending_at":null,"oldest_pending_age_seconds":null,
 "failing":0,"permanent_failures":0,"alert":false,"generated_at":"2026-10-31T09:00:00+01:00"}
```

- **Code HTTP = verdict** : `200` sain, `503` alerte. Un contrôle HTTP « code attendu 200 » suffit.
- Bloc `reminders` : état du rappel de la veille (dernier passage, cumuls du jour), **informatif**, hors `alert` — [registration-reminders.md](registration-reminders.md) §Supervision.
- À l'activation, les inscrits repris par la migration sont en attente depuis leur date de consentement : la sonde est en alerte (âge > 24 h) jusqu'au premier passage de CrmResyncJob (≤ 30 min). Lancer `bin/rails crm:requeue` juste après l'activation évite d'attendre.
- **Seuils d'alerte** (synchro active seulement) : `permanent_failures > 0` (un 4xx hors 429, `ContractError` comprise : contrat ou fiche, à traiter par un humain), ou `oldest_pending_age_seconds > 86400` (une attente de plus de 24 h : panne qui dure). `failing` (erreurs transitoires en cours) est informatif.
- **À brancher** dans la supervision : `https://live.example.org/internal/crm_status`, en-tête `Authorization: Bearer <CRM_STATUS_TOKEN>`, toutes les 15 min, alerte si le code n'est pas 200. Le jeton est un secret du déploiement de l'instance.

### Contrat HTTP du CRM

L'interface que le CRM de l'opérateur implémente. Base `CRM_BASE_URL`, en-têtes `Authorization: Bearer <CRM_API_TOKEN>`, `Accept: application/json` et, pour un POST, `Content-Type: application/json`. Corps À PLAT, exactement ces clés ; le CRM répond 422 à toute autre clé. `Crm::HttpContactsClient` refuse tout écart avant l'envoi (`Crm::ContractError`). Seul `id` des réponses (minimales) est lu. Codes attendus : 2xx succès ; 404 `{"error":"not_found"}` comme ci-dessous ; 429 + `Retry-After` pour un quota ; tout autre 4xx = permanent ; 5xx, délai dépassé (3 s à l'ouverture, 5 s à la lecture) ou corps JSON illisible = transitoire, retenté.

- `GET /api/v1/contacts/lookup?email=<adresse>` (seul paramètre ; email principal ou secondaire, casse ignorée) → 200 `{id, email, segments}` ; **404 `{"error":"not_found"}` seulement** = pas de fiche, on la crée ; tout autre 404 (route absente, page d'erreur) = erreur transitoire `unexpected_404`, **jamais** de création ; 422 = permanent. Le client n'utilise aucune autre lecture.
- `POST /api/v1/contacts` : `first_name` (obligatoire ; un nom d'un seul mot est un prénom), `last_name`, `email` — pas de `notes`, la provenance va dans l'interaction.
- `POST /api/v1/contacts/:id/segments` : `{"email": "<preuve>", "segment": {"realm":"professional","segment":"participant"}}`.
- `POST /api/v1/interactions` : `contact_id`, `email` (preuve), `kind` = `form`, `occurred_at`, `title`, `notes`, `source` = `live.example.org:<x>[:<y>]` (`:<slug>`, `:marketing_consent:<slug>`, `:withdrawal:<slug>`, `:notify_next`), `source_path` ∈ `/w/<slug>` (inscription), `/mc` (consentement), `/mc/withdraw` (retrait), `/confirmer` (« préviens-moi », consentement par confirmation de la demande). La provenance (`source` de la demande), le profil et le message vont dans `notes`.
- Le lien « fiche CRM » de l'animation pointe vers `CRM_BASE_URL/contacts/<id>` (page de la fiche dans l'interface du CRM, lecture seule).
- **Preuve par email** : segment et interaction portent l'email de la personne ; il doit être celui de la fiche visée, sinon le CRM répond 404 `{"error":"not_found"}`. Ce 404-là sur ces deux appels (fiche introuvable, ou `crm_contact_id` local périmé après une fusion côté CRM) → nouveau lookup par email, `crm_contact_id` mis à jour, UN nouvel essai (`Crm::ParticipantSync#on_contact`). Lookup vide ou second 404 → erreur permanente journalisée sans PII (`http_status=404`). Une fiche disparue n'est JAMAIS recréée par ce chemin : elle a pu être effacée à la demande de la personne.

### Corps émis, exactement (référence de dérive)

Ce que `Crm::HttpContactsClient` envoie, au mot près (figé par `test/services/crm/http_contacts_client_test.rb` et `test/services/crm/http_contacts_wire_contract_test.rb`, dont le faux CRM applique ce contrat). Un CRM qui l'implémente peut rejouer cette liste dans ses propres tests ; toute évolution du client la met à jour.

```
GET  /api/v1/contacts/lookup?email=camille%40example.test
POST /api/v1/contacts
     {"first_name":"Camille","last_name":null,"email":"camille@example.test"}
POST /api/v1/contacts/78/segments
     {"email":"camille@example.test","segment":{"realm":"professional","segment":"participant"}}
POST /api/v1/interactions   — inscription
     {"contact_id":78,"email":"camille@example.test","kind":"form","occurred_at":"<iso8601>",
      "title":"Inscription webinaire — <titre>","source":"live.example.org:<slug>","source_path":"/w/<slug>",
      "notes":"Inscription confirmée le <iso8601> (double opt-in).\nChoix : spectateur (regarder, discussion).\nProvenance : tartiflette.dev\nProfil : dev\nMessage : …"}
POST /api/v1/interactions   — consentement marketing
     {… "title":"Consentement marketing","source":"live.example.org:marketing_consent:<slug>","source_path":"/mc", "notes":"Consentement explicite …"}
POST /api/v1/interactions   — retrait
     {… "title":"Retrait du consentement marketing","source":"live.example.org:withdrawal:<slug>","source_path":"/mc/withdraw", "notes":"Retrait exprimé via lien dédié (jeton à usage unique)."}
POST /api/v1/interactions   — « préviens-moi »
     {… "title":"Veut être prévenu·e du prochain Café IA","source":"live.example.org:notify_next","source_path":"/confirmer", "notes":"Demande confirmée le <iso8601> (double opt-in).\n…"}
```

Ligne du choix, l'une ou l'autre : `Choix : spectateur (regarder, discussion).` / `Choix : participant (intervenir en caméra et micro).` (`CrmSyncJob::PARTICIPATION_NOTES`).

Les trois derniers ont les mêmes clés que l'inscription (`contact_id`, `email`, `kind`, `occurred_at`, `title`, `source`, `source_path`, `notes`). `source_path` est toujours envoyé.

## Inscriptions transmises à l'équipe et à la communauté (mail et WhatsApp)

Seule une demande `source = tartiflette.dev` **confirmée** part (double opt-in : c'est la garde anti-spam, rien ne part d'une demande non confirmée). Trois canaux indépendants, chacun avec sa colonne d'horodatage, sa file et son acquittement :

| Canal | Quoi | Sélection | Colonne |
|---|---|---|---|
| Mail aux co-organisateurs | demandes **avec message** | `team_messages` | `team_notified_at` |
| WhatsApp, groupe des co-organisateurs (« Contact ») | **toutes** les inscriptions confirmées, avec ou sans message | `team_signups` | `whatsapp_relayed_at` |
| WhatsApp, groupe de la communauté Tartiflette | prénom et cafés seulement, inscriptions à au moins un café publié ; jamais une inscription de test (`+cafe-test-`), un prénom retenu ou une demande soumise avant la politique v2.3 | `community_announceable` | `community_announced_at` (retenue : `community_announcement_withheld_at`) |

Ajouter un canal = une colonne, un scope de file, une méthode d'acquittement et un contrôleur interne (exemple : `Internal::CommunityAnnouncementsController`).

- **Mail** : à la première confirmation, `RegistrationRequest#notify_team!` envoie `CoOrganizerMailer.message_received` à `CO_ORGANIZERS_NOTIFY_TO` — message intégral, prénom, email, profil, cafés (titre et date), « préviens-moi », dates de la demande et de la confirmation ; Reply-To = la personne, pour lui répondre directement ; sujet fixe, sans texte saisi. Une fois par demande (`team_notified_at`) : une confirmation rejouée ne renvoie rien. Variable absente = aucun envoi, et la demande reste à transmettre.
- **Rattrapage du mail** (messages arrivés avant la mise en service, ou pendant que la variable manquait) : `bin/rails registrations:notify_team_backlog` liste les identifiants à transmettre (simulation, rien n'est envoyé) ; `CONFIRM=1 bin/rails registrations:notify_team_backlog` envoie. Idempotente (`team_notified_at`). En production : `kamal app exec --reuse "bin/rails registrations:notify_team_backlog"`, puis `kamal app exec --reuse "env CONFIRM=1 bin/rails registrations:notify_team_backlog"`. N'affiche que des identifiants, des dates et des compteurs.
- **WhatsApp** : l'app ne joint pas l'API Beeper ; un relais externe vient chercher les deux files WhatsApp (§ Relais WhatsApp), poste chaque entrée à son groupe, puis l'acquitte.
- **Confidentialité** : une politique d'instance qui annonce ces transmissions peut ne nommer que les canaux actifs dans l'environnement servi — le mail si `CO_ORGANIZERS_NOTIFY_TO` est posée (`CoOrganizerMailer.recipient`), les deux groupes WhatsApp si `REGISTRATION_RELAY_TOKEN` l'est.
- **Reprise de l'existant** :
  - migration `20261106210000` : messages confirmés avant le 06/11/2026 21:12 UTC, relayés à la main au groupe des co-organisateurs à cette heure-là, marqués relayés à cette date (sélection par date, sans identifiant), `team_notified_at` laissé nul (rattrapage mail) ; inscriptions de test de bout en bout (adresse en `+cafe-test-…`, message « Inscription de test de bout en bout ») marquées transmises sur les deux canaux d'alors ;
  - migration `20261108100000` (file des co-organisateurs ouverte à toutes les inscriptions, canal communauté) : coupure = l'instant où elle tourne. Les demandes déjà confirmées SANS message reçoivent `whatsapp_relayed_at` = la coupure. Toutes les demandes créées avant la coupure, **confirmées ou non**, reçoivent `community_announced_at` = la coupure : soumises sous la politique v2.2, qui n'annonçait pas ce canal, elles ne sont jamais annoncées, même confirmées plus tard. Aucune avalanche. Les messages encore dans la file des co-organisateurs n'y sont pas touchés. Une demande confirmée après la coupure, ou encore en attente, part normalement.

### Relais WhatsApp — `/internal/registration_messages`

Fermé par défaut : sans `REGISTRATION_RELAY_TOKEN` (ou avec une valeur vide), 404 ; avec, exactement `Authorization: Bearer <REGISTRATION_RELAY_TOKEN>` (401 sans corps sinon, y compris pour le jeton nu ou le jeton de la sonde CRM). `Cache-Control: no-store`. Un seul jeton pour les deux files (un seul relais). Il voit des données personnelles et écrit : il est distinct de `CRM_STATUS_TOKEN` (supervision, compteurs seulement). Prod seulement : l'edge a une valeur vide (404). Chaque file rend **20 entrées au plus** : le relais acquitte puis rappelle jusqu'à une liste vide, et n'acquitte qu'après un envoi réussi au groupe (un échec laisse l'entrée pour le passage suivant).

#### Groupe des co-organisateurs

`GET /internal/registration_messages/pending` → `200`, `team_signups` sans `whatsapp_relayed_at`, plus anciennes d'abord (`created_at`, puis `id`). Les chemins gardent leur nom historique (`registration_messages`) : le relais les appelle tels quels.

```json
{"registration_messages":[
  {"id":42,"name":"Camille","email":"camille@example.test","profile":"dev",
   "webinars":[{"slug":"cafe-ia-9","title":"Café IA #9","starts_at":"2026-11-20T18:30:00+01:00"}],
   "notify_next":true,"message":"Je propose une présentation…",
   "created_at":"2026-11-02T09:30:00+01:00","confirmed_at":"2026-11-02T09:45:00+01:00"}]}
```

`message` et `profile` peuvent être `null`, `webinars` vide (« préviens-moi » seul) ; `webinars` = cafés publiés de la demande, par date. Dates ISO 8601 au fuseau de l'app (Paris).

`POST /internal/registration_messages/:id/relayed` (sans corps) → `200 {"id":42,"whatsapp_relayed_at":"<iso8601>"}`. **Idempotent** : rejoué, même réponse, la première date reste. Demande inconnue ou hors de la file (non confirmée, autre source) → `404` sans corps.

#### Groupe de la communauté Tartiflette

Groupe ouvert à des membres externes : la file ne rend **que** le prénom et les cafés — ni email, ni nom complet, ni profil, ni message.

`GET /internal/registration_messages/announcements/pending` → `200`, `community_announceable` sans `community_announced_at`, dans l'ordre des confirmations (`confirmed_at`, puis `id`).

```json
{"announcements":[
  {"id":42,"first_name":"Pierre",
   "webinars":[{"slug":"cafe-ia-9","title":"Café IA #9","starts_at":"2026-11-10T09:30:00+01:00"}],
   "confirmed_at":"2026-11-08T09:45:00+01:00"}]}
```

`first_name` = le premier mot du nom saisi, normalisé NFKC (`RegistrationRequest#first_name`) : le champ porte le plus souvent un prénom seul, mais « Pierre Martin » donne « Pierre », jamais un nom de famille ; « Jean-Pierre » reste entier. **Prénom publiable seulement** (`RegistrationRequest::ANNOUNCEABLE_FIRST_NAME`, `/\A\p{Latin}(?:[\p{Latin}'’-]{0,28}\p{Latin})?\z/`, même règle que le relais) : lettres latines (accentuées comprises), apostrophe ou trait d'union entre deux lettres, 30 au plus. Un prénom non conforme (chiffre, `@`, lien, formatage WhatsApp, emoji, caractère de remplissage invisible, autre alphabet ou sosie) est **retenu à la confirmation** (`community_announcement_withheld_at`, `RegistrationRequest#confirm!`) : jamais dans cette file, ne bloque rien, et le groupe des co-organisateurs reçoit la fiche entière comme pour toute inscription. `webinars` n'est jamais vide (un « préviens-moi » seul n'est pas annoncé).

`POST /internal/registration_messages/announcements/:id/announced` (sans corps) → `200 {"id":42,"community_announced_at":"<iso8601>"}`. **Idempotent**. Hors de la file (inconnue, non confirmée, autre source, sans café publié, inscription de test, prénom retenu) → `404` sans corps.

## Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `REGISTRATION_API_ORIGINS` | absente ou vide = API fermée (403) | origines autorisées (liste séparée par des virgules) |
| `CO_ORGANIZERS_NOTIFY_TO` | absente = aucun envoi | adresse du mail des messages aux co-organisateurs |
| `CRM_SYNC_ENABLED` | absente = aucune synchro | drapeau maître CRM (`1` pour activer) |
| `CRM_BASE_URL` | — | URL du CRM ; absente = jobs abandonnés sans retry (log `reason=crm_unconfigured variable=CRM_BASE_URL`) |
| `CRM_API_TOKEN` | — | Bearer du CRM ; absent = jobs abandonnés sans retry (log `reason=crm_unconfigured variable=CRM_API_TOKEN`) |
| `REGISTRATION_PRIVACY_URL` | — | conditionne l'ouverture des inscriptions (503 sinon) |
| `CRM_STATUS_TOKEN` | absente ou vide = sonde fermée (404) | Bearer de la sonde `GET /internal/crm_status` |
| `REGISTRATION_RELAY_TOKEN` | absente ou vide = files fermées (404), WhatsApp non annoncé par /confidentialite | Bearer du relais WhatsApp (`/internal/registration_messages`, deux files) ; secret de l'instance, posé par sa configuration de déploiement |

Déploiement : `CRM_API_TOKEN`, `CRM_STATUS_TOKEN` et `REGISTRATION_RELAY_TOKEN` sont des secrets du déploiement (Kamal : `env.secret`). Avec Kamal, une destination qui déclare son propre `env.secret` remplace la liste de la base au lieu de la compléter, et **Kamal refuse de déployer tant qu'un secret déclaré n'a pas de valeur** ; une valeur vide démarre sainement (CRM coupé, sonde 404). Activer `CRM_SYNC_ENABLED` est un changement séparé.

Activer `CRM_SYNC_ENABLED` suppose : un CRM qui implémente le contrat ci-dessus, un jeton dédié à l'instance et limité à ces appels côté CRM, et la sonde `/internal/crm_status` branchée dans la supervision (`CRM_STATUS_TOKEN` provisionné).
