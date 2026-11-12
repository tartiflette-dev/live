# transcriber — worker LiveKit Agents (Whisper + archive signée)

Code = ce dossier, construit en image par `transcriber/Dockerfile`.

## Exécution

L'agent est lancé par `cli.run_app` (livekit-agents) :

```
python agent.py start
```

Variables d'environnement : voir le docstring de `agent.py` (en-tête).
En service, l'image est construite et lancée par les scripts de déploiement
de l'instance, jamais à la main.

### Entrée dans la salle : dispatch par l'app

Le worker est NOMMÉ (`AGENT_NAME`) : LiveKit ne l'envoie dans une salle que
si l'app l'y dispatche (`TranscriberPresence`, Rails), sous le même nom
(`TRANSCRIBER_AGENT_NAME`, à poser dans la configuration de déploiement de
l'app). L'app le dispatche à
l'ouverture et à la reprise du direct, à l'arrivée d'une personne autorisée,
et vérifie chaque minute qu'il est là tant que la captation est ouverte. À la
fin du direct, elle supprime le dispatch (LiveKit termine le job) et retire
l'agent.

Ordre de déploiement : l'app d'abord, puis l'image du transcripteur. Un agent
nommé face à une app qui ne dispatche pas encore ne rejoint aucune salle ;
l'app nouvelle face à l'ancien agent (auto-dispatché) le trouve dans la salle,
et ses dispatches nommés restent sans preneur, sans effet.

## Tests

Les tests Python couvrent la logique sans tomber dans LiveKit RTC (pas de
room réelle) : fakes légers d'`ArchiveClient`, de `rtc.Track`, de participant
et de pipeline STT. Pytest est **absent** de l'image (seul `requirements.txt`
y est installé).

```
cd transcriber/
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
```

### Arrêt propre

À la fermeture de salle, `shutdown_session` annule les pistes, ferme
l'archive et laisse l'entrypoint revenir — sinon livekit-agents 0.12
tue le process au bout de 60 s (`process is unresponsive`).

### Image traçable

L'image est étiquetée `org.opencontainers.image.revision` (SHA git,
`--build-arg GIT_REVISION=…`) par les scripts de déploiement, qui refusent
de construire sans SHA ; un `docker build` sans argument pose `unknown`. Lecture : `docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' <conteneur>`.

### Résilience

`supervise_track` enveloppe `transcribe_track` d'une reprise bornée par piste :

- **N tentatives** (`RETRY_MAX_ATTEMPTS` = 5), **backoff exponentiel plafonné**
  (`RETRY_BASE_DELAY = 1 s`, `RETRY_MAX_DELAY = 30 s`) ;
- **arrêt** dès que la room est déconnectée, le participant parti, ou la piste
  dépubliée (`_track_alive`) ;
- **pas de boucle serrée** : `asyncio.sleep` entre deux essais, injecté dans
  les tests pour vérifier qu'aucun retry ne part pendant que la piste est
  morte ;
- **abandon journalisé** après la dernière tentative (ERROR, cause + type).

Les tests pytest couvrent : succès au 1er essai, échec puis succès, abandon
après N tentatives, arrêt si piste dépubliée pendant le backoff, exception
d'envoi archive aussi retentée (pas que l'erreur STT).

### Cycle de vie, latence, mémoire

Une salle de test a vu le transcripteur retarder des segments de
plusieurs minutes, republier les mêmes phrases jusqu'à 5 fois, grossir à
2,2 Go et rester actif après « Terminer le direct ». Causes et correctifs :

| Cause | Correctif |
|---|---|
| Un pipeline par piste, jamais retiré : 11 démarrés, 10 vivants pour 2 participants | `lifecycle.PipelineRegistry` : UN pipeline par identité, remplacé à la reconnexion, arrêté à `track_unsubscribed`, `track_unpublished` et `participant_disconnected` (par sid de piste / de session, pour ne pas couper le pipeline neuf) |
| Whisper appelé SANS `priority` : la requête attendait derrière les traitements longs du serveur | `whisper_client.WhisperClient` : `priority=realtime` (backend rapide), `source` (`WHISPER_SOURCE`, défaut `live`) |
| `StreamAdapter` attend Whisper dans la boucle des événements VAD : file de segments non bornée | file bornée par pipeline (`SEGMENT_QUEUE_MAX`), le plus ancien est abandonné |
| Horodatages d'archive = heure de publication (le retard était invisible) | `started_at` / `ended_at` = instants de la PAROLE ; un segment de plus de `LIVE_MAX_AGE_SECONDS` n'est plus diffusé mais reste archivé |
| Audio 48 kHz converti en Python | flux demandé en 16 kHz mono dès la source |
| Le panneau ne voyait que l'heure d'envoi | attributs `lk.segment_start_ms` / `lk.segment_end_ms` (epoch ms, heure murale de la parole) sur le flux texte live |
| Phrases fantômes de Whisper | `noise.py` + `transcript_noise.json`, liste partagée avec le panneau (`transcript_filter.js`) |
| L'agent reste dans la salle après la fin du direct | la fin du direct (`LiveEnding`) supprime le dispatch et retire les participants `AGENT` ; l'agent voit la salle se déconnecter et libère tout. L'archive refuse toute parole commencée après la fin |

Mesures de référence (silero 0.7.5, une trame de 10 ms) : le VAD coûte 7 à
12 ms de CPU par seconde d'audio et par flux, soit moins de 1,5 % d'un
cœur : il n'est PAS le goulot. Le « inference is slower than realtime »
observé venait de la boucle d'événements saturée par les pipelines fantômes.

Le journal `stats` (toutes les `STATS_INTERVAL_SECONDS`) donne pipelines
actifs, mémoire résidente et compteurs (`published`, `archived_only_stale`,
`filtered_noise`, `dropped_overflow`, `whisper_errors`, `whisper_ms_max`,
`lag_s_max`). `JOB_MEMORY_WARN_MB` / `JOB_MEMORY_LIMIT_MB` règlent
l'alerte et le garde-fou de livekit-agents (le process du job est tué au-delà
de la limite ; la vérification minute par minute de l'app le redispatche).

Contexte de build : la liste des fichiers est dans le `COPY` du Dockerfile ;
un module ajouté à ce dossier doit y figurer, sinon l'image démarre sans lui.
