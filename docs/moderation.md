# Modération du direct : couper le micro, retirer

Régie du direct (`/webinars/:slug/regie`, bloc « Participants »), pour toute l'animation du webinaire : propriétaire, animateur du projet, co-animateur invité. Cibles : intervenants (`speaker-<id>`) et spectateurs (`viewer-<id>`) de ce webinaire, jamais une identité d'animation (`host-*`).

Le co-animateur invité ne gère ni les intervenants ni les inscrits : il modère seulement **pendant le direct** (sinon 403 `not_live`) une personne **présente dans la salle** LiveKit au moment de la commande (sinon 422 `not_in_room`) ; LiveKit injoignable → 502. Refusé, il n'écrit rien. Le propriétaire et l'animateur du projet retirent à tout moment, présente ou non.

| Commande | Route | Effet |
|---|---|---|
| Couper le micro | `POST /webinars/:id/participants/:identity/mute` | Coupe côté serveur les pistes audio publiées (micro, son d'un partage d'écran). La personne peut le rallumer. |
| Retirer | `POST /webinars/:id/participants/:identity/remove` | Pose `room_removed_at` (et révoque le lien d'un intervenant), puis expulse de la salle LiveKit. |

## Retirer ≠ révoquer

- **Révoquer** (propriétaire, page du webinaire, `speakers#revoke`) : le lien personnel meurt (`speakers.revoked_at`), rien de plus. Le navigateur de l'intervenant revoit le formulaire du lien partagé et peut recevoir un nouveau lien.
- **Retirer** (régie seulement) : `room_removed_at` sur l'intervenant (lien révoqué avec) ou sur l'inscription. Le navigateur de la personne est retiré du webinaire, quel que soit le rôle qu'il demande (`RoomRemoval`). Un intervenant entré par le lien participants privé et rattaché à son inscription (`Speaker#registration`) est retiré avec elle ; ce rattachement n'existe que s'il est **prouvé** (docs/public-registration.md) : une adresse saisie par un tiers ne fait jamais retirer son propriétaire.

## Régénérer le lien partagé

Une personne retirée peut revenir en caméra par le lien partagé d'intervenant (lien participants privé, `/i?t=`), sous une nouvelle identité, depuis un autre navigateur. La régie permet à toute l'animation de fermer cette porte pendant le direct, même à un co-animateur invité seul en régie. Hors direct, le co-animateur invité reçoit 403 `not_live` et rien ne change (régénérer avant l'événement couperait les intervenants invités qui n'ont pas encore cliqué) ; le propriétaire et l'animateur du projet régénèrent à tout moment.

| Commande | Route | Effet |
|---|---|---|
| Régénérer le lien intervenants | `POST /webinars/:id/share_link/regeneration` (JSON) | `Webinar#regenerate_share_token!` : nouveau jeton, l'ancien lien meurt. Les intervenants déjà entrés gardent leur lien personnel. Sans lien actif : 409, rien n'est créé. |

- **Qui** : toute l'animation (`where_animated_by`). Sans session animateur (anonyme, intervenant, spectateur) : 403 ; connecté sans rôle sur ce webinaire : 404. Créer le lien et le désactiver restent sur la page du webinaire, au propriétaire et à l'animateur du projet (`WebinarShareLinksController`).
- **Qui reçoit le nouveau lien** : le propriétaire et l'animateur du projet (`can_manage_speakers?`). Un co-animateur invité ferme la porte sans recevoir le lien (réponse `{ fingerprint }` seule) : ce lien fait entrer des intervenants, et inviter reste au propriétaire. La régie lui dit que le propriétaire le transmettra.
- **Confirmation en deux temps**, comme « Retirer ». Le bouton n'apparaît que si un lien est actif.
- **Après un « Retirer »** d'un intervenant entré par ce lien encore actif (`Speaker#entered_by_share_link?` : adresse déclarée ou inscription rattachée), la réponse porte `share_link_reentry: true` et la confirmation du retrait propose de régénérer. Jamais d'office : ce serait couper les intervenants légitimes qui n'ont pas encore cliqué.
- **Le jeton** ne voyage que dans la réponse au POST (CSRF actif, `Cache-Control: no-store`) : la régie affiche le nouveau lien masqué (`masked_token_link`), l'URL complète ne vit que dans le bouton « Copier le lien ». Il n'apparaît dans aucun GET : `/regie/status` ne donne que son empreinte (`share_link_fingerprint`, 16 caractères hexadécimaux de son SHA-256, `null` sans lien), qui sert à retirer de l'affichage un lien remplacé depuis par un autre animateur ou désactivé. Après un rechargement, la régie ne le montre plus.

## Modèle de menace

**Ce que « Retirer » garantit** : la personne ne revient pas
- depuis le **même navigateur, avec les mêmes cookies**, ni comme intervenant (lien partagé, lien personnel), ni comme spectateur (jeton, discussion, main levée, sondages), même après avoir fermé le navigateur. Cela vaut pour l'identité que le navigateur porte en cookie : un spectateur (cookie d'inscription) ou un intervenant entré par le lien partagé (cookie d'intervenant) ;
- avec la **même adresse** d'inscription, même depuis un autre navigateur, si cette inscription était **confirmée** : l'inscription retirée ne donne plus accès, et une nouvelle inscription avec cette adresse retombe sur elle. Une inscription **non confirmée** (identité provisoire de l'accès immédiat) retirée passe en pierre tombale et **libère** son adresse : rien ne prouvait qu'elle fût celle de la personne retirée, et un intrus ne doit pas pouvoir faire bannir l'adresse de sa victime (docs/public-registration.md, « Provisional identity »). Exception : retirée avec un intervenant dont la boîte de cette adresse est prouvée (`/rattacher`), elle garde son adresse, retirée. Le retrait est posé avant la pierre tombale, dans sa propre transaction : un échec de celle-ci ne le défait jamais ;
- avec son **lien personnel** d'intervenant, révoqué.

**Ce qu'il ne garantit pas** : revenir
- depuis un **autre navigateur ou en navigation privée** (sans les cookies) ;
- depuis un navigateur qui a fait « Ce n'est pas moi » **avant** d'être retiré (un autre onglet resté en salle, un clic pendant la confirmation de « Retirer ») : son cookie d'inscription est déjà oublié, rien ne le désigne plus. C'est l'équivalent d'une navigation privée ;
- avec une **autre adresse** (nouvelle inscription, à confirmer par mail) ;
- par le **lien partagé d'intervenant** tant qu'il n'est pas régénéré. Toute l'animation peut le régénérer depuis la régie, co-animateur invité compris (voir « Régénérer le lien partagé » ci-dessous) ; le créer et le désactiver restent à la page du webinaire (propriétaire et animateur du projet).

**Limite à connaître** : un intervenant entré par son **lien personnel** ne laisse aucun cookie dans son navigateur (aucune entrée GET n'en pose, voir plus bas). S'il a aussi sa propre inscription confirmée dans ce navigateur, il peut revenir comme spectateur, sans publier. Il réapparaît alors dans la liste de la régie, d'où on le retire à ce titre.

## Mécanisme

Une seule règle, `app/controllers/concerns/room_removal.rb` : un navigateur qui porte, pour ce webinaire, une identité retirée (`room_removed_at`) est retiré. Les identités lues dans le navigateur :

- le cookie d'intervenant `share_speaker_<webinar_id>` ;
- le cookie d'inscription `registration_id`, qui porte l'id de l'inscription **et** son secret d'identité : sans le bon secret, il ne désigne personne. Le format d'avant (id seul) est encore lu pour détecter un retrait, jamais pour donner accès ;
- la trace `room_removed_<webinar_id>`, posée dès qu'une identité retirée est vue dans ces cookies, ou quand le cookie d'inscription (unique pour tous les webinaires) en remplace un qui désignait une inscription retirée.

Un jeton d'intervenant retiré présenté ferme la requête, sans repli spectateur, mais ne laisse aucune trace : un jeton se transmet par simple lien.

**Persistance** : les cookies d'identité vivent jusqu'au lendemain de la fin prévue du webinaire, au plus 30 jours. La trace vit 30 jours. Fermer le navigateur ne les efface pas.

**Aucune entrée GET ne pose de cookie d'identité** (verrouillage forcé par CSRF de connexion) : sans cette règle, un participant retiré pourrait envoyer à sa victime un lien qui pose son identité retirée et la bannir du webinaire. Les cookies qui servent d'ancre ne naissent que d'un POST protégé CSRF :

| Cookie | Posé par | Méthode |
|---|---|---|
| `registration_id` | confirmation d'inscription ou accès d'une inscription confirmée (`POST /r/:token`) | POST, CSRF |
| `share_speaker_<id>` | formulaire du lien partagé (`POST /i`) | POST, CSRF |
| `room_removed_<id>` | la règle, à la lecture de l'un des deux précédents | dérivé |

`GET /r/:token` affiche toujours une page à bouton (confirmer, ou ouvrir la page d'une inscription déjà confirmée) ; une inscription retirée y voit « Accès retiré », sans cookie. `GET /w/:slug/join?t=` ne pose plus de cookie : le jeton de l'URL suffit pour entrer.

Hors participants, pour mémoire : la session animateur (`session[:user_id]`) naît du retour OIDC (GET protégé par le paramètre `state`) et le cookie `host_invitation` du POST `/auth/pocket_id`. Un animateur n'est jamais retiré par cette voie.

**Bouton d'accès d'un tiers (POST)** : un navigateur qui porte déjà une inscription **valide** à ce webinaire la garde ; le bouton du lien d'un tiers (confirmation ou accès) ne la remplace pas et affiche « Ce navigateur est déjà inscrit » (409), sans rien dire de l'inscription du lien ouvert ; seule l'inscription gardée y est nommée. Une victime inscrite ne peut donc pas être amenée à prendre l'identité d'un tiers retiré ensuite sans un geste explicite de sa part : « Ce n'est pas moi » sous **son propre nom** (ci-dessous), puis le bouton du lien du tiers. La même règle (`CurrentRegistration#remember_registration`) vaut pour l'accès immédiat d'une nouvelle inscription, publique ou par le lien participants privé : elle ne remplace pas l'inscription valide que porte déjà le navigateur.

**« Ce n'est pas moi »** (`POST /w/:slug/not_me`, CSRF, `NotMeController`) : le cookie d'inscription étant persistant et gardé (409 ci-dessus), la personne suivante sur un ordinateur partagé entrait sous le nom de la précédente, et une deuxième adresse dans le même navigateur recevait 409. Un bouton « Ce n'est pas moi » sur la page 409, dans la salle spectateur et sur la page du webinaire d'un inscrit fait oublier à ce navigateur son inscription à ce webinaire ; il peut ensuite s'inscrire, ou ouvrir le lien de sa propre inscription (deuxième adresse). Chacune de ces pages **nomme l'inscription gardée**, celle que le bouton oublie, et jamais celle du lien ouvert : sur la page 409, atteinte par le lien d'un tiers, la victime voit son propre nom et ne peut pas croire qu'elle oublie l'inscription du lien. Bornes :

- seul le cookie `registration_id` est effacé, et seulement s'il désigne une inscription de **ce** webinaire (il est unique pour tous les webinaires) ; l'inscription en base, le cookie d'intervenant et les autres webinaires ne bougent pas ;
- il ne lève **jamais** un retrait : un navigateur retiré de ce webinaire reçoit « Accès retiré » (403) et rien n'est effacé ; la trace `room_removed_<id>` n'est jamais supprimée, et le retrait que désignerait le cookie effacé reste tracé (`keep_room_removal_trace`, cas d'un animateur connecté, que la règle laisse passer). Un navigateur **déjà** retiré reste donc retiré (le cas d'un oubli fait avant le retrait est dans « Ce qu'il ne garantit pas ») ;
- POST seulement, protégé CSRF : un site tiers ne peut pas faire oublier son inscription à un navigateur.

**Oracle d'appartenance pendant le direct** : l'inscription publique répond différemment selon l'adresse, inhérent à l'accès immédiat. Adresse déjà inscrite à ce webinaire : page « Vérifiez votre boîte mail » (200), sans accès ; adresse neuve : redirection vers la salle (302). Un tiers peut donc savoir, pendant le direct ou le quart d'heure qui le précède, si une adresse est inscrite à ce webinaire. Hors de cette fenêtre, les deux cas répondent la même page. Borné par la limite de 10 inscriptions par minute et par IP.

**Résidu** : un navigateur **sans** inscription valide à ce webinaire qui clique sur le bouton du lien d'un tiers prend son identité ; si ce tiers est retiré ensuite, ce navigateur l'est avec lui. Cela demande un geste explicite sur une page qui ne montre aucune identité, et ne touche que quelqu'un qui n'était pas encore inscrit à ce webinaire depuis ce navigateur. Depuis « Ce n'est pas moi », une victime inscrite peut aussi s'y exposer, au prix de deux gestes explicites : faire oublier l'inscription que la page 409 affiche **sous son propre nom**, puis cliquer le bouton du lien du tiers. Après l'oubli, l'application ne renvoie pas vers ce lien (retour à la page du webinaire) et son message invite à ouvrir le lien de **sa propre** inscription.
