# Retrait de l'accord à l'image et dépublication

Procédure à annoncer dans la politique de confidentialité de l'instance (retrait de l'accord à l'image et dépublication). Délais retenus par l'instance d'origine, comptés depuis le retrait ou la demande : **7 jours** pour les extraits et shorts, **30 jours** pour le replay publié, **30 jours** pour supprimer les fichiers d'origine sur demande d'effacement. Responsable : l'éditeur du service, seul à publier replays et extraits ou à pouvoir le demander aux co-organisateurs de la série (tartiflette.dev).

## D'où vient un retrait

| Origine | Ce que fait live.example.org | Où le voir |
|---|---|---|
| Bouton « Retirer mon accord » dans la salle | Coupe caméra, micro et partage d'écran ; pose `participant_consents.withdrawn_at` ; arrête l'enregistrement de ses pistes séparées ; retire le droit de publier dans la salle (réessayé en tâche de fond si LiveKit ne répond pas, puis mail d'alerte) ; **envoie un mail à l'animateur propriétaire**, avec les deux échéances ; redépose le dossier d'épisode s'il est déjà publié | Le mail ; page Enregistrements du webinaire, section « Extraits et shorts » : **accord retiré** ; dossier d'épisode (Nextcloud) : `<épisode>-extraits.json` pour les outils, même tableau dans le README |
| Mail à contact@example.org (« Retrait de mon image ») | Rien d'automatique | La boîte contact@example.org |

Une personne marquée **extraits non autorisés** ou **aucun accord** n'a jamais autorisé les extraits : elle n'y figure pas, sans qu'aucune demande soit nécessaire. Un accord retiré puis redonné garde son historique (« retiré le…, redonné le… ») : un extrait tourné avant le retrait n'est pas couvert par le nouvel accord.

## Qui fait quoi

1. **Avant tout montage** (après chaque direct) : celui qui monte (l'éditeur, ou un co-organisateur de la série (tartiflette.dev) à partir du dossier Nextcloud partagé, qui s'engage à ne publier que les personnes aux extraits autorisés) lit le tableau « Extraits et shorts » (ou `<épisode>-extraits.json`, qui fait foi pour un outil : le README n'en est que la version lisible). Chaque personne y est désignée par son identité LiveKit (`speaker-<id>`, `viewer-<id>`, `host-<compte>`) ; le JSON liste en plus ses fichiers (pistes, assemblage) et l'historique de ses accords, ce qui lève toute homonymie. Il ne garde dans un extrait ou un short que des personnes aux **extraits autorisés**, et l'animation de droit.
2. **Retrait reçu** (mail d'alerte, statut « accord retiré » ou mail de la personne) : l'éditeur
   - sous 7 jours : retire les extraits et shorts publiés où la personne apparaît (sites, LinkedIn de l'organisation ; LinkedIn est opéré par Microsoft, aux États-Unis), demande par écrit aux co-organisateurs de la série (tartiflette.dev) d'en faire autant, et garde leur réponse ;
   - sous 30 jours : retire du replay publié les passages de la personne (coupés ou image masquée), ou retire le replay le temps de le refaire ;
   - si la demande ne porte que sur les extraits, le replay reste tel quel.
3. **Demande d'effacement** : sous 30 jours, l'éditeur supprime aussi les fichiers d'origine où la personne apparaît, dans live.example.org (page Enregistrements) et dans le dossier Nextcloud, versions comprises.
4. **Réponse** : quand la personne a écrit, l'éditeur lui confirme par mail ce qui a été retiré, et où.
5. **Trace** : une note dans le CRM (fiche de la personne, si elle en a une) ou dans le dossier de l'épisode : date de la demande, date du retrait, liens retirés.

## Ce que le code ne fait pas

- Aucun effacement automatique des fichiers déposés dans Nextcloud ni des publications sur les réseaux : la purge de live.example.org (3 ans, `RetentionPurgeJob`) ne touche que ses propres enregistrements ; Nextcloud et les publications se retirent sur demande, à la main.
- Un retrait par mail n'est pas reporté dans `participant_consents` : il vit dans la boîte contact@example.org et la trace de l'étape 5.
- L'animateur du webinaire et l'équipe de l'organisation n'ont pas de fenêtre de consentement ; un animateur qui refuse un extrait suit la même procédure, par mail. Les co-animateurs invités ont la fenêtre, comme les intervenants.
