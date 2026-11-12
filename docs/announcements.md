# Envois groupés : message aux inscrits, à la liste, aux « préviens-moi »

Un animateur connecté écrit un message (objet + texte brut) et l'envoie à une cible, depuis l'écran d'envoi d'un webinaire. Code : `Announcement`, `AnnouncementAudience`, `AnnouncementPermission`, `AnnouncementDelivery`, `AnnouncementMailer`, `AnnouncementNoticeMailer`, `WebinarAnnouncementsController`, `NotifyNextStopsController`.

## Où

- **Régie** (`/webinars/:slug/regie`) : bouton « Envoyer un message aux inscrits », pensé pour le téléphone pendant le direct (une colonne, cibles en cartes radio de la charte, contrat mobile testé de 320 à 412 px : `test/system/announcements_mobile_test.rb`).
- **Page du webinaire** (`/webinars/:slug`) : bouton « Envoyer un message ».
- Écran : `GET /webinars/:slug/announcements/new` → `POST …/preview` → `POST …/announcements` ; journal : `GET /webinars/:slug/announcements`.

## Cibles

| Cible | Qui reçoit | Pied ajouté au mail |
|---|---|---|
| Inscrits du webinaire (« sur place » = le webinaire du jour) | inscriptions **confirmées** de ce webinaire, sauf retirées de la salle et pierres tombales | rappel « inscrit·e à … » + lien d'accès personnel `/r/:token`, ou celui du replay une fois publié (`/w/:slug/replay?t=`, docs/replays.md) ; **aucun** lien de retrait (message de service) |
| La liste | consentement marketing **actif** : inscriptions (quel que soit le café) et demandes confirmées, **dédoublonnées par adresse** | lien de retrait `/mc/withdraw?t=…` **obligatoire**, aussi en en-tête `List-Unsubscribe` |
| « Préviens-moi » | demandes `notify_next` confirmées, dédoublonnées, jamais arrêtées ; sauf qui a retiré son accord au recontact (le retrait vaut pour la personne), à moins d'un accord redonné depuis | lien d'arrêt `/prochain/stop?t=…` **obligatoire**, aussi en en-tête `List-Unsubscribe` |

Chaque cible porte son comportement (destinataires, lien du pied, tonalité) dans sa classe (`AnnouncementAudience::*`) ; `AnnouncementAudience.for` est le seul aiguillage sur le type de cible.

Texte : celui de l'auteur, tel quel (texte brut, échappé dans la partie HTML), objet ramené à une ligne. Tonalité du pied : celle du webinaire de l'écran ; « préviens-moi » parle en Café IA ([tonalites.md](tonalites.md)).

## Droits, quotas, avis

`AnnouncementPermission` (fermé par défaut ; cible non ouverte : 404 ; quota atteint : 429 avec la raison, rien ne part) :

| Cible | Qui | Bornes | Avis |
|---|---|---|---|
| La liste, « préviens-moi » | **animateurs du projet** seulement (`User#project_host?` : groupe Pocket ID frais, liste ENV à adresse vérifiée, admin), jamais le seul propriétaire d'un café | au plus **un envoi aux listes par 24 h glissantes**, toutes listes confondues, et aucun nouvel envoi ni reprise tant qu'un autre envoi aux listes est en cours | mail aux animateurs du projet à chaque envoi (objet, auteur, nombre, lien vers le journal, texte) |
| Inscrits du webinaire | propriétaire et animateurs du projet, sans fenêtre ; **co-animateur invité le jour du café seulement** (Paris, de 0:00 à la fin prévue + 2 h) | co-animateur : **3 envois par jour** au plus | envoi d'un co-animateur : mail au propriétaire du webinaire |

Les quotas sont relus au moment de l'envoi, dans la transaction d'écriture qui l'enregistre (SQLite `IMMEDIATE` : deux confirmations simultanées se suivent). Réponses (`Reply-To`) : à l'auteur, ou **au propriétaire** du webinaire quand l'auteur est un co-animateur. Pas de nouvelle authentification pour l'instant.

Journal : un co-animateur et un propriétaire n'y voient que les envois aux inscrits ; un co-animateur y voit l'adresse de ses propres envois, et le rôle (propriétaire, animateur du projet, co-animateur) à la place de celle des autres auteurs. Aucune adresse de destinataire n'est affichée à personne.

### Arrêt du « préviens-moi »

`GET /prochain/stop?t=…` affiche une page sans effet (les scanners de liens suivent les GET) ; le `POST` de son bouton (CSRF) pose `registration_requests.notify_next_stopped_at` sur **toutes** les demandes confirmées de la personne (`RegistrationRequest.stop_notify_next_of`). `notify_next` garde ce qu'elle a demandé (historique, synchro CRM inchangée) ; ses inscriptions et son consentement marketing ne changent pas. Jeton signé sans colonne (`generates_token_for :notify_next_stop`), qui cesse de valoir une fois l'arrêt posé : lien re-cliqué, forgé ou demande non confirmée → page neutre, 404. Une nouvelle demande « préviens-moi » repart de zéro.

### Retrait du consentement

`/mc/withdraw` fonctionne quelle que soit la visibilité du café de l'inscription qui porte le jeton : un café dépublié (annulé) ne coupe pas le droit d'opposition ; la page cite alors « un café qui n'est plus au programme ».

## Confirmation

1. L'aperçu montre l'objet, le texte, le pied de la cible et le **nombre de destinataires**, recalculé à cet instant.
2. L'envoi exige la case « Je confirme l'envoi de ce message à N destinataires » et le même N : si la cible a changé depuis l'aperçu (nouvel inscrit, retrait), l'aperçu revient avec le nouveau nombre.
3. Un jeton tiré à l'aperçu (`dispatch_token`, index unique) rend la confirmation idempotente : un double clic, même simultané, ne crée pas un second envoi (« Cet envoi est déjà parti »).

**Seul un humain déclenche un envoi**, depuis cet écran (communication sortante, classe D) : aucune API, aucun job récurrent, aucun agent ne crée ni ne met en file un envoi.

## Remise étalée, sans doublon

- À la confirmation, une ligne `announcement_deliveries` par destinataire : empreinte HMAC de l'adresse (`CrmErasure.digest`, pas d'adresse en clair) + référence de la fiche (inscription ou demande). Index unique envoi × empreinte.
- Mise en file `deliver_later`, un mail toutes les `Announcement::SPACING` (3 s : 20 par minute, 300 destinataires en un quart d'heure), heure prévue dans `scheduled_at`. Le marqueur `enqueued_at` est pris **avant** la mise en file.
- **Une seule remise par marqueur** : le mailer prend la remise en base (`sending_at`, mise à jour conditionnelle) avant tout rendu. Un job rejoué (redémarrage pendant un envoi étalé, relance manuelle d'un job) ou concurrent ne renvoie rien.
- **Exclusion immédiate** : à la remise, le mailer relit la cible pour cette adresse. Retrait ou arrêt arrivé entre-temps, fiche devenue pierre tombale : rien ne part, `skipped_at`. Remise acceptée par le serveur SMTP : `delivered_at`.
- **Sans nouvelles** : un marqueur ni remis ni écarté 10 minutes après son heure prévue (`AnnouncementDelivery::SILENT_AFTER` : job en échec SMTP, processus tombé) est compté « sans nouvelles » au journal, en rouge, avec ceux jamais mis en file (envoi interrompu).
- **Reprise** : « Reprendre l'envoi » remet en file ces seuls marqueurs, l'étalement continuant après le dernier mail déjà programmé (une reprise pendant l'envoi ne double pas le débit). Résidu assumé : un mail accepté par le serveur SMTP juste avant la chute du processus, avant `delivered_at`, repartirait à une reprise.
- **Effacement** : `crm:erase` supprime les marqueurs de la personne (par empreinte) ; un mail encore en file ne part plus.

## Journal

Par webinaire : objet, date, auteur, cible, nombre de destinataires confirmé, mails remis, écartés, en cours, sans nouvelles, texte. Avancement calculé en une requête groupée.
