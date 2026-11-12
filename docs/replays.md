# Replays

Le replay complet d'un direct terminé, réservé aux personnes identifiées.

## Qui voit quoi (ReplayAccess)

| Personne | Accès |
| --- | --- |
| Compte connecté (Pocket ID), quel qu'il soit | tous les replays **publiés** |
| Animation du webinaire (propriétaire, co-animateur, animateur du projet) | son replay, publié ou non |
| Inscription confirmée, ouverte par son lien personnel | le replay de **son** café, publié |
| Personne d'autre | page de connexion (replay publié) ou 404 |

- Lien personnel d'un inscrit : `/w/<slug>/replay?t=<jeton d'inscription>`. Le GET
  affiche un bouton, sans effet ; le POST du bouton pose un cookie chiffré propre au
  webinaire (id + secret d'identité) puis renvoie sur `/w/<slug>/replay`, sans jeton.
  Une inscription retirée de la salle par l'animation, effacée ou remplacée par une
  pierre tombale n'ouvre plus rien.
- Ce lien part dans le pied des envois groupés aux inscrits dès que le replay est
  publié (à la place du lien d'accès à la salle).
- Page d'un inscrit sans compte : invitation à créer un compte
  (`LIVE_SPECTATOR_SIGNUP_URL`, lien d'un jeton d'inscription Pocket ID, accepté
  seulement s'il pointe vers l'émetteur OIDC) et bouton de connexion.
  Secret de la configuration de déploiement (par exemple `env.secret` de Kamal).
  Pocket ID borne un jeton à 31 jours et 100 inscriptions : à son expiration (ou une
  fois épuisé), le bouton mène à une erreur Pocket ID. Le renouveler = créer un nouveau jeton lié au groupe
  `live-spectateurs`, reposer le secret, redéployer.

## Rôle spectateur

Un compte Pocket ID n'a de droit d'animation que par le groupe nommé par
`LIVE_ANIMATEURS_GROUP` (sans défaut), la propriété d'un webinaire ou une invitation de
co-animateur (`User#animateur?`). Tout autre compte est spectateur : 404 sur toute la
zone animateur (`Authenticatable#authenticate_animateur!`), arrivée sur `/replays`
après connexion. Un compte sans aucun groupe est spectateur. Le groupe
`live-spectateurs` ne sert qu'à Pocket ID : il autorise la connexion au client OIDC
de live et se rattache au jeton d'inscription. L'application ne le lit pas.

## Publication

`/webinars/<slug>/replay` (propriétaire et animateurs du projet) : publier une fois
le direct terminé, retirer. La vidéo de référence est la vue d'ensemble (composite)
terminée la plus longue ; son horloge cale les sous-titres WebVTT (transcription) et
borne les positions des battements.

## Vidéo

- Servie par `ReplayMediaController` avec le contrôle d'accès de la page, jamais
  publique. Derrière Thruster (`X-Sendfile-Type: X-Sendfile`), l'application répond
  par l'en-tête `X-Sendfile` et Thruster sert le fichier et ses plages (Range) : aucun
  fil Puma n'est occupé pendant la lecture. Sans Thruster, `Rack::Files` sert les
  plages.
- Copie de diffusion : un fichier `.mp4` déposé sous `RECORDINGS_ROOT/_replays/<slug>/`,
  puis `Replay#update!(derived_path: "_replays/<slug>/<fichier>.mp4")`. Présent sur disque,
  il remplace le composite à la lecture ; absent, le composite est servi. Son temps 0 est le
  `started_at` de la vidéo de référence (l'horloge des sous-titres et des battements).

## Montage piloté par la parole

Bouton « Monter le replay » (page Replay, animation) ou `bin/rails "replays:montage[<slug>]"` :
le replay est créé non publié s'il n'existe pas, et l'application dépose une demande de rendu.
**L'application ne rend pas la vidéo, et le moteur de rendu est externe, non distribué avec
l'application** : un programme externe, lancé hors direct sur l'hôte des enregistrements, lit
la demande et dépose la vidéo montée (contrat dans « Rendus hors de l'application » ci-dessous). Une fois rendu, le
montage devient la copie de diffusion (ReplayMontageSweepJob, toutes les 10 min). Sans moteur, la
demande reste en file, le composite reste servi, et la page Replay signale la demande en retard.

- **Qui est à l'image** (MontagePlan) : la personne qui a un segment de transcription à cet
  instant, pas celle qui fait du bruit (un clavier ne produit pas de segment). Deux voix à la
  fois : la plus récente. Silence : l'image reste sur la dernière personne qui a parlé. Les autres
  sont en vignettes sur le côté, dans l'ordre d'arrivée.
- **Écran partagé** : l'écran en grand, la personne qui parle en première vignette.
- **Mise en avant de l'animation** pendant le direct : elle l'emporte sur la parole (journal
  SpotlightChange, écrit par RoomSpotlight à chaque changement).
- **Sans piste séparée** (pas d'accord à l'image, caméra coupée), et avant toute parole : la vue
  d'ensemble du direct pour ces plans.
- **Lissage** : segment de moins de 1 s ignoré, segments d'une même personne à moins de 1,5 s
  fusionnés, aucun plan de moins de 2,5 s ; bruit Whisper écarté (« Merci d'avoir regardé »,
  « Sous-titrage… », hésitations seules : `transcriber/transcript_noise.json`).
- **Rendu** (ce que fait le moteur de l'instance d'origine, la demande ne l'impose pas) : 1280x720,
  25 i/s, H.264 CRF 23, faststart ; son du composite (toutes les voix, telles qu'entendues en
  direct), calé par corrélation avec les micros séparés (`probes`) ; la page Replay dit si le
  calage est mesuré ou estimé, et alerte quand une demande n'est toujours pas rendue après
  `ReplayMontage::OVERDUE_AFTER` (30 h).
- **Extrait de contrôle** : `bin/rails "replays:montage_extrait[<slug>,<début>,<fin>]"` écrit
  sur la sortie standard le document de rendu d'un extrait : même format qu'une demande, sans
  `request_id`, `digest` ni `requested_at`, et `output` vaut
  `_replays/<slug>/extrait-<id du composite>-<début>-<fin>.mp4`. Il n'entre pas dans la file :
  à faire rendre à la main par le moteur externe.

## Rendus hors de l'application (contrat par fichiers)

Deux traitements vidéo lourds ne tournent pas dans l'application (mémoire du conteneur, fils
Puma, disque) : le montage du replay et les versions légères de la publication Nextcloud.
L'application en porte le côté application — les demandes, leur suivi, l'adoption du
résultat — mais **le moteur de rendu est externe, non distribué avec l'application**. Une
instance qui veut ces fonctions branche le sien, qui doit
respecter le contrat ci-dessous. Sans moteur : les demandes restent en file, le replay sert le
composite, la publication dépose les originaux (après `LightVersion::WAIT`, 6 h).

Règles communes :

- Tous les chemins sont relatifs à `RECORDINGS_ROOT`, répertoire partagé entre l'application et
  le moteur. Chaque fichier est écrit par remplacement atomique (fichier temporaire puis
  renommage) : un lecteur ne voit jamais un fichier à moitié écrit.
- Le moteur ne modifie jamais les enregistrements bruts. Il publie sa sortie vidéo d'abord, une
  fois vérifiée, puis son marqueur `<sortie>.json` : un marqueur `done` désigne toujours une vidéo
  complète.
- Le moteur ne devrait pas travailler pendant un direct (le serveur sert alors la salle) ; c'est
  à lui de le vérifier, l'application ne le bloque pas.

### Montage du replay (ReplayMontage)

- **Demande**, écrite par l'application : `_montages/demandes/<replay id>.json`, un objet JSON.
  - `version` (1), `webinar` (slug), `replay_id`, `request_id` (UUID de la demande), `digest`
    (SHA-256 du document), `requested_at` (ISO 8601, UTC) ;
  - `output` : vidéo à produire, `_replays/<slug>/montage-<id du composite>.mp4` ;
  - `duration` : durée de la vidéo montée, en secondes ;
  - `composite` : `{path, end}`, le fichier de la vue d'ensemble et l'instant où il finit ;
  - `sources` : `[{key, path, offset}]`, les pistes vidéo séparées (caméras, écrans) ;
  - `probes` : `[{path, offset, from, to}]`, des fenêtres où une personne parle dans son micro
    séparé, pour caler le son du composite par corrélation ;
  - `shots` : `[{from, to, layout, main, thumbnails}]`, les plans. `layout` vaut `composite`
    (vue d'ensemble seule), `speaker` (caméra `main` en grand) ou `screen` (écran `main` en
    grand) ; `main` et `thumbnails` sont des `key` de `sources` (plan `composite` : `main`
    vaut `null` et `thumbnails` `[]`) ;
  - `notes` : textes libres (pistes au calage approximatif).

  Les temps sont en secondes de la vidéo montée, dont le 0 est le `started_at` de la vidéo de
  référence (l'horloge des sous-titres et des statistiques) ; `offset` est l'instant où commence
  le fichier d'une piste. Une demande au même `digest` déjà en file (et pas en échec) n'est pas
  réécrite.
- **Sortie**, écrite par le moteur : la vidéo MP4 à `output`, puis le marqueur `<output>.json` :
  - réussite : `{"status": "done", "request_id": …, "digest": …, "output_size": <octets de la
    vidéo>}`, et en option `audio.method` (`mesuré`, `médiane` ou `estimé`), affiché sur la page
    Replay ;
  - échec : `{"status": "failed", "request_id": …, "reason": "<texte>"}`, affiché sur la page
    Replay ; l'échec attend une nouvelle demande.

  Un marqueur ne vaut que si son `request_id` est celui de la demande en file.
- **Adoption**, par l'application : ReplayMontageSweepJob (toutes les 10 min) prend un marqueur
  `done` dont la vidéo a bien la taille `output_size`, pose `Replay#derived_path` et retire la
  demande. Une demande dont le replay n'existe plus est retirée. Une demande toujours en file
  après `ReplayMontage::OVERDUE_AFTER` (30 h) est signalée en retard sur la page Replay.

### Versions légères (LightVersion)

Activées par `PUBLICATION_LIGHT_VERSIONS=1` ; sans elles, la publication dépose les originaux.

- **Demande**, écrite par l'application : `_leger/demandes/<recording id>.json` :
  `{recording_id, source, output, crf, max_height, source_size, requested_at}`. `source` est
  l'original, `source_size` sa taille en octets ; `output` vaut `_leger/<chemin de l'original>`,
  ou `_replays/<slug>/<fichier>` pour le composite (sa version légère est aussi la copie de
  diffusion du replay). `crf` : 26 pour le composite, 23 sinon ; `max_height` : 1080. Seuls le
  composite, les assemblages par personne et les caméras en `.mp4` sont demandés (pas les écrans
  partagés).
- **Sortie**, écrite par le moteur : la vidéo réencodée à `output`, puis le marqueur
  `<output>.json` :
  - réussite : `{"status": "done", "source_size": …, "output_size": <octets de la vidéo>}` ;
  - renoncement : `{"status": "original", "source_size": …, "reason": "<texte>", "cause":
    "gain_insuffisant" | "erreur"}` — l'application dépose alors l'original.

  Un marqueur ne vaut que si son `source_size` est la taille actuelle de l'original : un
  assemblage refait périme la demande et le marqueur, et l'application redemande.

### Publications en échec (PublicationFailureMarker)

Pour une supervision externe, facultative : à chaque échec d'une publication Nextcloud,
l'application écrit `_publication/echecs/<publication id>.json` (`publication_id`, `webinar_id`,
`webinar`, `page`, `reason`, `digest` de la raison, `failed_at`) et le retire quand un dépôt
aboutit. Le marqueur ne porte jamais le nom du fichier en cause. L'application ne le lit jamais.

## Statistiques de visionnage

- Battements du lecteur (`app/javascript/replay_player.js`) : toutes les 15 s pendant
  la lecture, à la pause, avant un saut, à la fin et à la fermeture de la page, le
  passage lu `[from, to]` en secondes de la vidéo.
- Une séance (`ReplayView`) par onglet et par personne (inscription ou compte). Le
  serveur ne crédite pas un passage plus long que le temps écoulé (×2 + 3 s).
- Débit borné : 20 battements par minute et par personne, un battement à moins de 2 s
  du précédent est ignoré, 50 séances par personne, replay et jour, 200 passages
  distincts par séance.
- Tableau animateur (par replay) : personnes, vues (séances avec lecture), temps regardé, part de la
  vidéo vue, passages vus, dernier visionnage. Les séances partent avec l'inscription
  (effacement, rétention 12 mois) ou le compte, et au plus avec le replay (purge des
  enregistrements à 3 ans, copie de diffusion comprise).
- Fiche d'une personne sur tous les cafés (`/animation/personnes/<clé>`, animateurs du projet) :
  ses visionnages par replay (séances par inscription et par compte de même adresse réunies),
  ses inscriptions, ses questions du direct, ses réponses aux sondages, ses recherches, et le
  lien vers sa fiche dans le CRM (`CRM_BASE_URL/contacts/<id>`, lecture seule). La
  clé est `r<inscription>` ou `u<compte>`, jamais l'adresse. Le nom d'une personne dans le
  tableau d'un replay y mène.

## Sondages dans le replay

- Un sondage lancé pendant le direct reparaît en surcouche du lecteur (jamais incrusté
  dans la vidéo) de son instant d'ouverture à son instant de fermeture, en secondes de
  la vidéo de référence (même horloge que les sous-titres), une minute au moins. Sur
  écran large, la carte se pose sur le coin de la vidéo ; au téléphone, sous la vidéo.
  Un sondage dont la personne s'est saisie (choix, texte, réponse) reste affiché hors de
  son créneau jusqu'à ce qu'elle le masque ou qu'un autre sondage arrive. En plein écran
  natif, la carte n'est pas visible.
- Une réponse par personne et par sondage : l'inscription garde son identité du direct
  (`viewer-<id>`), un compte répond comme `account-<id>`. Qui a déjà répondu au
  direct voit sa réponse et le résultat, sans pouvoir répondre de nouveau.
- Chaque réponse garde son origine (`poll_responses.origin` : `live` ou `replay`). La
  salle et la régie ne comptent que le direct ; le spectateur du replay, une fois sa
  réponse donnée, voit direct + replay réunis avec la part de chacun (les réponses
  courtes : leur nombre seulement) ; la page Replay de l'animation montre les deux
  séparément.
- Écrire exige un replay publié. Débit : 10 réponses par minute et par personne.

## Questions hors direct

- Depuis le lecteur, une question part vers les animateurs, ancrée à l'instant où la
  personne a commencé à l'écrire. Elle rejoint la file Q&R du café (source `replay`,
  instant de la vidéo, auteur inscription ou compte), sans reformulation ni
  rapprochement par le modèle de langage.
- Animation : la file du café (régie) la montre avec son instant ; `/questions` liste
  toutes les questions des cafés que l'on anime, direct et replay, filtrables par café
  et par origine, avec un lien vers l'instant du replay (`/w/<slug>/replay?instant=<s>`).
  Le lien « Questions » du chrome animateur compte les questions du replay encore à
  traiter.
- Débit : 5 questions en 10 minutes et 20 par jour, par personne. Une question part
  avec l'inscription (effacement, rétention de 12 mois après le café) ou le compte.

## Chapitres

- Proposés par le LLM local de l'application (`QA_LLM_*`, par exemple glm-4-9b) à partir de la
  transcription (`ChapterProposal`, `ChapterProposalJob`) : titre court, instant de début et
  thèmes de chaque chapitre. La transcription est lue par passages de 8 minutes au plus ; les
  personnes y sont des repères (P1, P2…), jamais des noms. Mesuré sur un direct réel :
  10 passages, 85 à 155 s, 8 chapitres.
- Déclenchés 10 minutes après la fin du direct et à la publication du replay ; jamais pendant
  un direct (le GPU est celui de la transcription : le travail est remis à 20 minutes). Rien
  n'est redemandé si la transcription n'a pas changé.
- **Proposés, ils ne sont pas montrés aux spectateurs.** L'animation (propriétaire, animateurs
  du projet) les relit dans `/webinars/<slug>/chapters` : corriger un instant, un titre, des
  thèmes, en ajouter, en retirer, puis « Valider : montrer aux spectateurs ». Un jeu validé
  n'est jamais remplacé par le LLM ; « Redemander une proposition » n'est offert qu'avant
  validation.
- LLM coupé ou injoignable : aucun chapitre, rien d'autre ne change ; l'écran le dit et
  l'animation peut les saisir à la main.
- Cafés passés : `bin/rails replays:chapitres` (tous les cafés qui ont transcription et vidéo),
  `bin/rails "replays:chapitres[<slug>]"`, `bin/rails "replays:chapitres[<slug>,refaire]"`.
- Lecteur : liste cliquable sous la vidéo et repères sur une barre (`replay_navigation.js`), le
  chapitre en cours signalé ; `/w/<slug>/replay?instant=<secondes>` ouvre la vidéo à cet
  instant. Les instants sont des heures réelles recalées sur la vidéo du replay
  (`Replay#offset_of`).
- `/replays` montre les thèmes de chaque café (chapitres validés) ; un thème lance la
  recherche.

## Recherche

- `/replays?q=…` cherche dans la transcription, les titres des chapitres validés et leurs thèmes
  de tous les replays que la personne peut regarder (compte : tous les publiés ; inscrit : ceux
  de ses cafés). Résultat : par café, des extraits surlignés, chacun un lien vers le lecteur à
  l'instant exact.
- SQLite FTS5 (`replay_search_entries`, compilé dans la gem sqlite3 de l'image) : accents et
  casse ignorés, tous les mots exigés, préfixe
  pour les mots de 3 lettres et plus. Aucune syntaxe FTS5 ne passe (chaque mot est cité). Un
  `LIKE` aurait ignoré les accents seulement en ASCII (« securite » ne trouve pas
  « sécurité ») et parcouru toute la transcription à chaque requête.
- L'index (`ReplaySearchIndex`) est reconstruit par café après chaque proposition de chapitres,
  chaque relecture, et par `bin/rails replays:chapitres`. Un segment arrivé après la
  publication (rattrapage) n'est trouvé qu'au passage suivant.
- Débit : 30 recherches par minute et par personne.
- Vue animateur `/animation/themes` : thèmes de tous les cafés (chapitres validés et proposés,
  marqués), les cafés qui en ont parlé avec un lien à l'instant ; « les cafés où on a parlé
  de… » cherche aussi dans la transcription de tous les replays, publiés ou non. Ces
  recherches ne vont pas au journal.

## Journal des recherches

- Chaque recherche sur `/replays`, même sans résultat, est enregistrée (`replay_searches`) :
  requête, requête normalisée, nombre de passages trouvés, auteur (compte ou inscription).
- `/animation/recherches` (animateurs du projet) : requêtes sans résultat (la demande qu'aucun
  café ne couvre), les plus fréquentes, les dernières avec leur auteur, sur 30 jours, 90 jours
  ou 12 mois.
- Conservation : 12 mois après la recherche (`RetentionPurgeJob`) ; avant, elles partent avec
  l'inscription (effacement `crm:erase`, rétention) ou le compte. Politique v2.6.
