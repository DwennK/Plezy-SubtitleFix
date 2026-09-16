# Plezy + LiveSync — plan et décisions

## Contrat de livraison

Synchronisation locale, pendant la lecture, de l'audio anglais avec le texte
original de SRT accessibles intégralement. Cibles obligatoires : Windows x64 et
macOS Apple Silicon. Aucun microphone, mixage système, service de transcription,
second flux réseau du média ou analyse préalable intégrale. Sources inchangées.
Le fork et ses artefacts de test peuvent être poussés ; les releases restent en
brouillon. Aucun changement ni PR au dépôt officiel.

## État de la chaîne intégrée — 16 septembre 2026

Le contrôle « Live subtitle sync » est branché dans les menus de sous-titres
et de réglages vidéo sur les plateformes ciblées. Il charge le SRT externe
anglais sélectionné avec les en-têtes du média, ou le SRT intégré sélectionné
sur Plex en lecture directe après vérification des décisions de copie. Il vérifie/télécharge
base.en sur Windows (~148 Mo), le modèle quantifié sur Mac (~60 Mo), puis prélève
le PCM du lecteur. Plusieurs ancres concordantes établissent le décalage initial.
Le suivi par zones est maintenant raccordé : il conserve les domaines observés
et peut estimer une pente après six ancres espacées sur au moins une minute.
Les prédictions restent séparées et bornées à 120 s. Leur précision réelle et le
rendu des frontières restent à valider. La lecture continue pendant l'analyse.
Le délai manuel est additionné séparément ; désactiver retire seulement la
contribution automatique. Les seeks, changements de vitesse et discontinuités
PCM invalident l'analyse et les prédictions, en conservant les régions connues ;
un changement de piste relance une session demandée. Le délai audio manuel est
composé dans la timeline audio ; sa vérification dans le banc natif est en cours.

La première preuve native macOS sur audio réel de calibration a appliqué
−100,16 s pour −100 s attendues, en 47,49 s, puis vérifié le délai manuel et
l'arrêt du prélèvement. C'est une preuve intermédiaire sur un extrait,
avec sortie audio nulle. Le premier test multicanal a révélé des ancres
imprécises. L'alignement DTW suivant donne −100,23 s en 33,62 s dans le banc
natif sans UI. Sur le cas utilisateur, le transport complet du SRT intégré
et le rapprochement depuis le véritable PCM 5.1 fonctionnent dans des probes
sans UI. La correction estimée (+3,75 s) reste à confirmer visuellement et
à l'écoute dans le lecteur applicatif. Le premier chargement du SRT a demandé
80 s avec l'adaptateur final, puis l'acquisition native 46 s sur un autre essai.
Ces temps dépassent le budget utilisateur ; ce n'est pas une livraison finale.
Le Mac verrouillé empêche actuellement la suite des contrôles d'interface.

Le contrôleur Windows acquiert le cas de calibration en 24,261 s avec base.en
(erreur 199 ms) et préserve le délai manuel après arrêt. Le probe natif Mac avec
timeline acquiert aussi le générique de 90 s (erreur 212 ms, délai total 135,856 s).
Ces résultats ne prouvent ni la dérive réelle ni une précision statistique :
l'extrait court de validation échoue encore, et un autre acquiert en 195,723 s.

Le suivi léger d'activité vocale est branché, avec un retour périodique à ASR
pour la parole manquée et sans accorder de confiance sur ce seul indice. Il
réagit à la reprise d'activité et aux désaccords avec les durées des cues ; il
ne sait pas séparer fiablement musique et voix. Les premiers essais natifs Mac
passent, sa validation applicative Windows reste en cours.

Les gaps confirmés et leur rendu, le cache de mappings et la suppression
du modèle dans les paramètres ne sont pas livrés. La dérive avec vraie parole,
les performances, la validation native de Mentalist et les autres critères de
livraison restent ouverts. Aucun build final annoncé. Voir les preuves exactes
et leur provenance dans `live-subtitle-sync-validation.md`.

## Plan d'exécution et portes de validation

| Phase | Livrable | Preuve nécessaire avant la suite |
|---|---|---|
| A | Upstream exact, manifeste, environnement et contrôles de référence | Versions issues des locks/workflows ; état Git propre |
| B | Prélèvement PCM natif, SRT et renderer | PCM horodaté réel Windows/macOS, délai réversible, whisper compilé |
| C | Chaîne PCM → whisper.cpp → SRT → correction | Inférence réelle sur extrait redistribuable |
| D | Matching conservateur, générations, réglage manuel | Ambiguïtés, seeks, piste changée, résultats obsolètes |
| E | Timeline segmentée `media = a * subtitle + b` | Dérive 23.976/25, scènes ajoutées/supprimées, retour arrière |
| F | VAD, cadence adaptative | Silence/musique, absence de transcription continue |
| G | UI, modèle, cache | Activation/désactivation natives, téléchargement vérifié, cache partiel |
| H | Optimisation | Comparaison désactivé/activé sur machines identifiées |
| I | Artefacts et suivi upstream | CI Windows/macOS et intégration automatique exercées |
| J | Refetch et livraison | SHA réellement testé et écarts à l'heure du contrôle |

Les phases B et C sont des validations intermédiaires, pas la livraison. Aucun
test injecté ne remplace une preuve de capture ou d'inférence native. En cas de
prérequis externe manquant, poursuivre les travaux indépendants et documenter
l'accès précis requis. Ne pas annoncer le projet terminé avec des cases ouvertes.

## Architecture à vérifier

- Plezy utilise `lib/mpv/player/` et des bridges Swift/C++ vers libmpv.
- macOS : `macos/Runner/MpvPlayer/` et `shared/apple/MpvPlayer/` ; dépendance
  Swift Package `edde746/mpv-build`, verrouillée par `Package.resolved`.
- Windows : `windows/runner/mpv/` ; binaires et checksums dans
  `mpv-build.lock.json`, moteur Flutter patché sélectionné par upstream.
- SRT : `PlaybackSubtitleResolver`, sidecars et `external-filename` de mpv.
- Réglages : `sub-delay` et `audio-delay` dans `SyncOffsetControl`.
- Le client public libmpv ne fournit pas le prélèvement PCM requis. Le patch
  isolé ajoute une lecture destructive bornée de PCM horodaté dans le pipeline
  existant, avant le filtre de vitesse. Les probes PCM/SRT sont acquis sur macOS
  et Windows ; le délai est visible et réversible sur les deux plateformes.

Séparer capture, inférence, index SRT, rapprochement, alignement, confiance,
timeline et adaptation player. UI indépendante de whisper. Une seule inférence,
identifiant de génération de lecture, ring de 30 s maximum, mono float32 16 kHz.
Le thread audio ne bloque jamais pour l'analyse ; abandonner en surcharge.

## Conventions temporelles et confidentialité

Toutes les coordonnées sont des secondes dans la timeline média/SRT. Un offset
positif `b` affiche le texte plus tard. Le délai manuel s'ajoute à la contribution
automatique. Les segments ont des domaines validés explicites ; les zones inconnues
et sans correspondance ne sont pas de simples offsets globaux. Les timestamps
viennent du PCM et des tokens, jamais de la fin de calcul. Changement majeur :
plusieurs passages indépendants, pas deux fenêtres de la même réplique.

Aucun PCM/transcript conservé par défaut ou envoyé en télémétrie. Les clés de cache
utilisent identités stables/version du média, piste audio, hash SRT, versions du
schéma/algorithme, sans URL avec jeton. Modèle téléchargé à la première activation,
taille affichée, révision et SHA-256 vérifiés, écriture atomique et suppression UI.
Passthrough incompatible : raison explicite, aucune désactivation silencieuse.

## Git et distribution

`main` reste un miroir de l'officiel ; `feature/live-subtitle-sync` porte le patch.
La synchronisation doit créer une branche d'intégration et une PR interne, éviter
concurrence/doublons et échouer avec la liste des conflits. La promotion doit
préserver l'historique du patch sans le rejouer deux fois. Avant installation :
identité et stockage distincts, auto-update officiel désactivé, aucune écriture
dans les données de l'application Plezy existante. Signature/notarisation ne sont
pas implicites dans un build de test.

## État

Plan enregistré avant implémentation. Phase A revalidée sur `9babe681`, phase B
acquise sur fixtures natives : inférence CPU Windows/macOS, prélèvement PCM macOS avec PTS,
renderer macOS et lecture complète bornée des SRT démontrés séparément.
Le consommateur PCM 16 kHz borné passe sur Windows/macOS. La chaîne lecture
active → consommateur → worker Whisper CPU passe sur le Mac avec les deux modèles.
Le worker et son interface C passent en CI sur Windows/macOS. Le build Windows
du mpv patché et les probes PCM/SRT passent dans `35031113958`. Le build applicatif Windows passe ;
six états du renderer Windows sont vérifiés visuellement (`35035639850`). Aucun fonctionnement
LiveSync de bout en bout livré. Voir le journal de validation et le manifeste.


## Accès au SRT retenu

`SubtitleSourceLoader` reçoit la `SubtitleTrack` déjà résolue par Plezy et le
client HTTP existant (avec les en-têtes de la session), sans reconstruire les
URLs ni démarrer un flux média. Plex fournit des sidecars `/library/streams/…`
avec son jeton ; Jellyfin/Emby fournissent une URL de sous-titre avec leur
paramètre d'authentification ; les téléchargements hors ligne fournissent un
chemin ou une URI `file:`. Ces détails restent dans les clients actuels.

Le loader accepte uniquement les sidecars SRT/SubRip dont le fichier complet
est accessible, borne la lecture à 4 MiB et 20 secondes, et permet d'annuler
l'opération. Il conserve les octets originaux et calcule leur SHA-256 hors du
thread principal quand l'isolate est disponible. Il ne ferme pas le client
HTTP partagé. Les erreurs et la représentation textuelle des résultats
n'incluent ni URL, ni jeton, ni dialogue.
Le parseur complet conserve texte, styles, positions et ordre des cues ; il
accepte UTF-8, UTF-16 et un fallback Windows-1252 explicite, rejette les cues
endommagés et borne tailles/comptages. Indexation et branchement au contrôleur
restent à implémenter. Les huit tests couvrent aussi un vrai serveur HTTP local, le corps
réseau bloqué puis annulé, la limite de taille et la préservation du fichier.
Cette preuve de transport n'est pas une validation d'un serveur Plex/Jellyfin
réel avec son catalogue.

## Gestion locale du modèle

`LiveSyncModelManager` expose les deux modèles épinglés au manifeste. Il reçoit
un répertoire dédié dans l'Application Support du fork et un client HTTP sans
en-têtes média. L'UI recevra la phase et les octets téléchargés, avec la taille
totale exacte disponible avant activation.

Une acquisition vérifie aussi un fichier déjà en cache. Le téléchargement écrit
par blocs avec contre-pression disque, vérifie taille et SHA-256 dans un isolate,
puis renomme le fichier validé sur le même système de fichiers. Les préparations
concurrentes du même modèle partagent une seule opération. Annulation, inactivité
et délai total interrompent le transport et nettoient les fichiers temporaires.
Une lease protège le modèle chargé jusqu'à sa libération par le worker natif ;
la suppression depuis les paramètres devra d'abord arrêter ce worker.

À la première acquisition, les temporaires identifiés par un marqueur propre au
gestionnaire et vieux de plus de 24 heures sont récupérés après un éventuel crash.
Les dossiers récents, non identifiés ou contenant d'autres fichiers sont préservés.
L'intégration au contrôleur, à l'UI et au répertoire de production reste à faire.
Le probe réseau explicite `flutter test --no-pub tool/livesync_model_probe_test.dart`
vérifie un vrai téléchargement du modèle quantifié, sa réutilisation et sa suppression.
Il utilise un répertoire temporaire et ne laisse pas de modèle utilisateur installé.

## Budgets fixés avant la validation de bout en bout

Référence macOS : Apple M4, 16 Gio, macOS 26.6.2. La machine Windows physique
et son GPU restent à identifier ; le runner CI sert aux contrats et à la
faisabilité, pas à certifier les performances de toutes les machines clientes.
Les mêmes cibles seront appliquées à la référence Windows annoncée avant ses
mesures. Un dépassement impose une correction ou une limite documentée ; ces
valeurs sont des critères, pas des résultats acquis.

| Mesure | Cible de validation |
|---|---|
| Capture | Ring ≤30 s, snapshot ≤15 s ; une inférence active ; aucun backlog |
| Inférence sur fenêtre de 12 s | p95 ≤3 s, modèle déjà chargé |
| Mémoire supplémentaire | pic ≤512 Mio au-dessus de la lecture seule |
| CPU en suivi stabilisé | moyenne sur 5 min ≤30 % d'un cœur supplémentaire |
| UI pendant l'inférence | p95 réponse à une interaction ≤100 ms |
| Vidéo | hausse des frames perdues ≤0,1 point de pourcentage sur 10 min |
| Audio | aucune interruption supplémentaire sur le scénario de 10 min |
| Acquisition initiale | ≤45 s avec dialogues exploitables, hors téléchargement |
| Reprise après seek inconnu | ≤30 s avec dialogues exploitables |
| Erreur d'alignement sur validation séparée | médiane ≤250 ms ; p95 ≤750 ms |
| Mauvais verrouillages/grands sauts | zéro observé dans le corpus négatif, effectif publié |

Mesurer séparément pause, absence de dialogue et contenu sans correspondance :
ces périodes ne doivent pas être forcées à converger pour tenir un délai.
Relever CPU/GPU, thermique, mémoire, latences et défauts audio/vidéo avec fonction
désactivée puis activée. Publier les distributions, pas seulement les moyennes.

Premier choix à évaluer dans le player : `base.en-q5_1` avec Metal sur Apple
Silicon, CPU disponible comme repli. Cinq lancements isolés par combinaison sur
le M4 donnent environ 0,30 s médiane Metal contre 0,42 s CPU sur la fixture JFK,
avec moins de temps CPU cumulé. Ce petit extrait connu ne valide aucun des
budgets de lecture ou d'alignement ci-dessus. Le worker de production préparé
reste CPU à ce stade ; Metal, Vulkan et le repli réel restent à intégrer/tester.
