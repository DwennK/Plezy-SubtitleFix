# Plezy + LiveSync — preuves et validation

## Statut

Travail en cours, pas de livraison répondant à tous les critères. Des acquisitions
automatiques passent dans le contrôleur Windows et dans les probes natifs Mac.
La validation visible et audible de Mentalist, la dérive dans le lecteur réel, les gaps, le
cache, les performances et la distribution restent incomplets. Les sections
datées ci-dessous distinguent les résultats historiques des avancées suivantes.

## Référence initiale (2026-09-15)

- Dossier initial vide, aucun travail local à préserver.
- Fork créé : https://github.com/DwennK/Plezy-SubtitleFix
- Officiel : https://github.com/edde746/plezy ; branche par défaut `main`.
- SHA initial : `4992d1bd8b76830a9539f03d650e1db4e85c8dc7`.
- Date du commit : `2026-09-15T15:58:46+02:00`.
- Version : `2.20.0+150` ; release stable `2.20.0` publiée à `2026-09-15T08:12:19Z`.
- Hôte : macOS arm64, Xcode 27.0 (27A266a). Flutter absent au départ.
- Flutter requis : 3.47.1, commit `6655482ec06e547f90abf8ae7590466f4415978d`,
  engine `5d531788691ec3404cac0cee66ead4007b177363`.
- whisper.cpp candidat : v1.9.4 ; révision/checksum à figer après examen.

## Matrice de preuves initiale (historique ; avancées détaillées ci-dessous)

| Niveau | État | Limite |
|---|---|---|
| Contrôles upstream de référence | Analyse OK, suite 7 245 succès / 1 échec | Échec passe isolément, détails ci-dessous |
| PCM natif macOS avec PTS | Prouvé sur WAV réel, sortie nulle | Audio audible et app à vérifier |
| PCM natif Windows avec PTS | À réaliser | CI et matériel interactif à identifier |
| Lecture et correction visible réversible | À réaliser | App de test isolée nécessaire |
| Inférence réelle base.en / quantifiée | CPU Windows/macOS, Metal local OK | Un seul extrait, pas de calibration temporelle |
| Domaine et transcripts injectés | À réaliser | Ne prouvent pas la capture native |
| Précision et faux verrouillages | À réaliser | Corpus de validation distinct de calibration |
| Performances et budgets | À définir avant validation finale | Référence Windows non identifiée |
| Packaging/installation/désinstallation | À réaliser | Signature/notarisation non promises |
| Suivi upstream quotidien exercé | À réaliser | Aucun workflow propre installé |

## Critères à mesurer

Erreur médiane/p95/p99, acquisition initiale et après seek, faux verrouillages et
grands sauts incorrects ; CPU/GPU/RSS, inférences par minute et latence, frames
perdues et interruptions audio. Comparer désactivé/activé avec le même média et
les mêmes réglages. Identifier chaque machine et backend. Les seuils de confiance
sont heuristiques tant que la calibration ne démontre pas autre chose.

Corpus : SRT correct, offsets ±, générique 90 s, dérive 23.976/25, scènes ±,
frontières et gaps, seeks avant/arrière, pause/buffering/vitesse, changements
média/audio/SRT, délai manuel avant/pendant/après, résultats périmés, répliques
répétées, silence/musique/bruit, mauvaise édition, cache partiel/corrompu, modèle
interrompu, GPU défaillant et passthrough. Provenance redistribuable obligatoire.

## Commandes attendues

`flutter pub get --enforce-lockfile --no-example`, `flutter analyze`,
`scripts/run_tests.sh`, `scripts/codegen.sh --check`,
`scripts/ci_checks.sh`, `git diff --check`, builds natifs selon workflows upstream.
Conserver les résultats réels, les échecs de référence et les limites séparément.

## Journal — premiers résultats réels

### Environnement et contrôles upstream

Flutter 3.47.1 / Dart 3.13.1 installé dans le cache dédié. `flutter pub get
--enforce-lockfile --no-example` réussi. Le workflow upstream impose aussi cette
commande dans `packages/wakelock_plus` : après cette préparation, `flutter analyze
--no-pub` passe sans diagnostic. Les 49 diagnostics du premier essai étaient dus
à cette préparation incomplète, et ne sont pas des régressions LiveSync.

Suite complète : 7 245 réussites, 6 skips, 1 échec (`playback_open_failure_test`,
aucun `loadfile` observé dans le délai d'attente). Le même test relancé seul passe.
Cela ne permet pas de déclarer la suite entièrement verte ; sa sensibilité à la
charge reste à examiner. Aucun fichier Dart de l'application n'avait été modifié.

### Inférence réelle

whisper.cpp v1.9.4 compilé avec Metal sur Apple M4 / 16 Gio. Modèles vérifiés contre
les SHA-256 LFS de la révision Hugging Face figée. Un seul extrait JFK de 11 s :

| Modèle/backend local | Temps total CLI, chargement inclus |
|---|---:|
| base.en / Metal | 2 088 ms |
| base.en-q5_1 / Metal | 2 422 ms |
| base.en / CPU | 2 701 ms |

Mesures exploratoires, un essai par configuration, avec d'autres builds/tests en
cours. Ni benchmark stable, ni mesure d'impact sur la lecture, ni erreur temporelle
SRT. La quantification n'est pas sélectionnée comme meilleure sur cette base.

CI réelle Windows x64 et macOS arm64 : les deux modèles passent en CPU.
[Run 35015023385](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35015023385),
SHA `b68ec07e89a5e04b2f0163fa61edf5d59d07fa0b`. Les artefacts contiennent sorties
JSON, logs, versions et SHA. Vérification locale des quatre sorties téléchargées :
erreur de mots nulle sur cet extrait familier ; aucune précision temporelle déduite.

### Capture native macOS

mpv 0.41.0 + série Apple Plezy figée + patch LiveSync compilé pour arm64 et x86_64.
Le moteur Flutter reste inchangé. Le driver réutilise les install trees officiels
de FFmpeg et autres dépendances ; il a effectivement sélectionné Meson 1.12.0 via
son PATH interne, malgré le venv 1.4.2 préparé. Le manifeste distingue ces outils.

Sur arm64, `probe_pcm.py` charge les mêmes objets compilés dans un dylib de test.
Il décode réellement un WAV stéréo 48 kHz généré (317/691 Hz), avec la sortie audio
nulle cadencée de mpv. Les échantillons et PTS correspondent à la formule connue à
une unité d'amplitude 16 bits près. 43 blocs vérifiés : lecture, seek vers 7 s,
retour vers 2 s, vitesse 1.5. Les epochs progressent 0 → 1 → 2. Pause et retrait
du prélèvement passent. Les PTS sont vérifiés sur la grille 1/48 000 s.

Cette preuve ne valide pas l'audio audible, le rendu natif Plezy, le passthrough,
les flux réseau, les changements de pistes ni le fonctionnement Windows.
Les blocs peuvent précéder le point cible d'un seek exact ou anticiper la position
affichée : le consommateur devra sélectionner uniquement la fenêtre effectivement
entendue et rejeter les générations obsolètes.

### Travaux encore ouverts

Construction Windows du mpv patché en cours via le driver upstream et sa chaîne
LLVM/MinGW figée ; son bootstrap à froid peut durer plusieurs heures.
[Run 35015208320](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35015208320).
Pas encore de preuve PCM Windows, de fonction dans l'UI, de matching SRT, de cache,
de modèle géré par l'UI ni d'automatisation quotidienne d'intégration upstream.

La branche par défaut du fork est `feature/live-subtitle-sync`, pour héberger les
workflows propres au fork ; `main` reste le miroir officiel inchangé. Aucune
release publique, aucun changement dans l'application Plezy installée.

### Coexistence et application macOS de référence

Build debug macOS réussi : `build/macos/Build/Products/Debug/PlezyLiveSync.app`.
Bundle `com.dwennk.plezy.livesync`, fenêtre « Plezy + LiveSync ». Lancement natif
via Computer Use vérifié : écran de connexion vide, aucun compte importé.
Fenêtre agrandie à 1224 × 768 sur l'écran disponible, puis application refermée.
Capture conservée dans `docs/livesync-evidence/2026-09-15-macos-onboarding.png`.
Ce build d'application utilise encore le mpv officiel : le test du prélèvement
patché reste un test natif séparé. Aucune synchronisation n'est annoncée dans l'UI.

Windows : exécutable, métadonnées produit et mutex séparés préparés ; app Windows
pas encore construite/ouverte. Installer et signature restent à adapter/valider.

Protection des données : l'ancien import automatique depuis
`Documents/plezy_downloads.db` est désactivé dans le fork Windows/macOS, car il
déplace la base source. Le test passe sans même consulter Documents. 70 tests
de base de données passent, ainsi que les 7 tests updater et le test d'interdiction
de mise à jour officielle exécuté avec `ENABLE_UPDATE_CHECK=true`.
Le feed Sparkle officiel est retiré du plist. Analyse Dart sans diagnostic après
ces changements ; contrôles de pins et sécurité des workflows réussis.

Le build a approché la limite d'espace disque. Seuls les répertoires de staging
des téléchargements natifs de cette tâche et quatre produits Sentry non utilisés
dans son cache `build/macos/SourcePackages` ont été supprimés. Les versions
effectivement liées, les install trees, l'app construite et les preuves restent
présents. Environ 2,9 Gio libres après nettoyage ; une nouvelle résolution SwiftPM
peut retélécharger les variantes non utilisées.

### Point de reprise — 2026-09-15, environ 20:06 UTC

- Dernier refetch : `7e4c8feb0c7bd3b8aade2d240bc13abb05e1e2a8`, daté
  `2026-09-15T21:58:00+02:00`. Un commit Android uniquement au-delà du SHA initial.
  **Il n'est pas intégré aux binaires testés.** À intégrer/revalider avant livraison.
- La deuxième CI d'inférence avec vérification explicite du texte est verte :
  [35016502461](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35016502461).
- Le build natif Apple de la CI `35015208320` est vert ; le job Windows poursuit
  son cross-build. La vérification Windows séparée accepte cet ID et attend la fin
  du build avant de télécharger/exécuter sa DLL. Elle est déclenchable sans rebâtir
  LLVM. Les nouveaux runs du workflow de build incluent aussi le probe en dépendance.
- Le guard upstream refuse `workflow_run` : ce déclencheur a été retiré. Le helper
  emploie un dispatch explicite et une attente read-only. Les guards de sécurité
  et de pins passent avec ce fonctionnement.
- `scripts/codegen.sh --check` est terminé sans modification générée ; analyse et
  tests ciblés coexistence/updater restent verts. La suite complète de référence
  garde son unique échec sous charge, réussi ensuite isolément.
- Prochaine porte : preuve PCM Windows, ajout du rééchantillonnage hors thread UI,
  intégration du mpv patché dans Plezy, accès SRT et correction visible réversible.
  Ne pas confondre le build macOS de référence avec une app LiveSync fonctionnelle.
- L'accès à une machine Windows interactive pour les mesures finales a été demandé
  dans la conversation et n'est pas encore renseigné. Aucun secret serveur requis
  n'a été inventé ni repris de l'application Plezy existante.


## 2026-09-15 — mpv patché lié dans l'application macOS

- Le projet macOS utilise un package Swift local généré depuis le commit natif
  épinglé ; seul son binaire Libmpv est remplacé par l'archive patchée vérifiée.
  Les packages distants et lockfiles iOS/tvOS ne sont pas modifiés.
- `flutter build macos --debug --no-pub` : réussi avec ce package.
- `xcodebuild test ... -only-testing:RunnerTests` : **13 tests réussis**.
  Le nouveau test ouvre une WAV sinusoïdale créée localement, constate la capture
  désactivée, l'active, lit du PCM avec timestamps et la désactive dans la
  bibliothèque effectivement liée à `PlezyLiveSync.app`. Sortie audio nulle.
- Premier essai du nouveau test corrigé : lire la propriété avant toute piste
  audio renvoie « indisponible », conformément au patch. Le test vérifie désormais
  une vraie chaîne audio. Les douze contrats natifs upstream restent verts.
- L'import XCTest et les références du scheme ont été adaptés au nom du fork.
- Workflow dédié de construction macOS/test natif ajouté ; son exécution CI est
  distincte de la validation locale ci-dessus et reste à constater.
- Pas encore de contrôle LiveSync ni de synchronisation automatique dans l'UI.
  Ce résultat remplace seulement la référence précédente à une app liée au mpv
  officiel. Le workflow original de release et la mise à jour des pins natifs
  devront être adaptés avant distribution ; le workflow dédié produit des tests.


## 2026-09-15 — bornes PCM et timing SRT natif

- Probe PCM enrichi : vérification du changement d'époque après seeks avant et
  arrière ; taille de chaque transfert ≤ 256 KiB et ≤ 64 blocs ; arrêt volontaire
  du consommateur pendant une lecture accélérée. Le débordement augmente le
  compteur de pertes et invalide l'époque. Les échantillons gardent leur PTS exact.
  Exécution macOS arm64 réussie sur le mpv patché réel.
- Nouveau probe SRT : fichier local intégral et serveur HTTP local avec en-tête
  Authorization factice. Même texte chargé par le client et par libmpv ; URI de
  piste préservée. Délai positif : disparition du cue ; délai négatif : cue suivant ;
  retour au délai manuel 0,125 s : cue initial restauré. Fichier source inchangé.
- Cette preuve observe `sub-text` du décodeur réel avec sorties nulles. Elle ne
  prouve ni les pixels du renderer, ni l'intégration des clients Plex/Jellyfin,
  ni le contrôleur automatique. Ces validations restent ouvertes.
- Les workflows natifs Windows/macOS intègrent maintenant ces probes. Les runs
  démarrés avant ce commit continuent d'utiliser leur ancienne définition.


## 2026-09-15 — vérification visuelle du renderer macOS

Banc dédié `tool/livesync_player_probe.dart`, construit avec le projet macOS du
fork, son mpv patché, et les classes réelles `Player` / `Video` de Plezy. Média
local synthétique FFV1/PCM, SRT synthétique ; aucun compte ni média personnel.
Ce banc reste séparé du point d'entrée produit et ne contient pas d'alignement
Whisper ni de contrôleur de synchronisation automatique.

Contrôle via Computer Use dans une fenêtre native de 1224 × 768 :

- À 1,5 s, le renderer affiche FIRST PROBE CUE, délai manuel +0,125 s.
- Après +2 s supplémentaires, le cue disparaît visiblement.
- Avec délai −3 s, SECOND PROBE CUE apparaît à la même position média.
- Restaurer +0,125 s ramène FIRST PROBE CUE sans changer de piste (`sid=1`).
- Activer puis désactiver la capture affiche respectivement `yes` puis `no` ;
  la piste, son texte et le délai manuel sont conservés.

Captures : `docs/livesync-evidence/2026-09-15-renderer-macos/`. Pour éviter que
les contrôles du banc couvrent les sous-titres, leur position est fixée à 70 %
dans ce banc uniquement. Un premier essai a également confirmé qu'une piste
URI doit être résolue en identifiant natif avant `selectSubtitleTrack`, comme
le fait déjà l'application. Le banc a été corrigé en attendant la liste native.
L'entrée normale `lib/main.dart` a ensuite été reconstruite avec succès.

Le run CI macOS 35018938322 a compilé l'application, puis a échoué à compiler
le nouveau test : sa version de Swift exige des conversions C-string explicites
que le compilateur local acceptait implicitement. Correction `8c3a24b6` : les 13 tests natifs repassent localement ; nouveau run
CI lancé. Cela n'est pas encore un succès des tests CI.


## 2026-09-15 — dépendance de chargement Windows

Le mpv Windows upstream importe dynamiquement `vulkan-1.dll`. Le probe installe
maintenant à côté de libmpv le chargeur x64 déjà épinglé par
`windows/CMakeLists.txt` (1.4.357.0), avec sa licence. Téléchargement et hash de
l'archive vérifiés localement ; aucun backend ni pin modifié. Cela évite de
faire dépendre le chargement de la DLL de la présence d'un pilote système.
La preuve d'exécution du PCM sous Windows reste attendue du build en cours.


## Point de contrôle — 2026-09-15T20:59:00.555371+00:00

- Upstream intégré : `7e4c8feb0c7bd3b8aade2d240bc13abb05e1e2a8`, via merge `b1057814`.
  Dernier refetch : `7e4c8feb0c7bd3b8aade2d240bc13abb05e1e2a8` ; 0 commit non intégré.
  La branche `main` locale reste le miroir officiel, sans patch LiveSync.
- `scripts/run_tests.sh --no-pub` : **7 248 réussis, 6 ignorés, 0 échec**
  en environ 15 minutes. Le test de playback qui avait échoué au contrôle initial
  passe dans cette suite entière. Les huit nouveaux tests du loader SRT, ajoutés
  après l'énumération de cette suite, passent séparément.
- Analyse Dart globale et analyse ciblée du loader/tests : réussies.
  `scripts/codegen.sh --check`, gardes workflow/SwiftPM et `git diff --check` : réussis.
- CI macOS **35020270952 réussie**, commit `8c3a24b6`, avec 13 tests natifs.
  Artefact de test : `livesync-macos-app-8c3a24b62e42ce563e95e535fefe3068485ca42e`
  (123 408 463 octets). Ce build précède le merge Android-only ci-dessus ; il
  n'est pas présenté comme contenant ce commit upstream plus récent.
- Le probe natif utilise maintenant les métadonnées de linkage de la bibliothèque,
  sans supposer que le build upstream crée un exécutable CLI. Validation PCM arm64
  répétée avec succès. Probes PCM et SRT x86_64 réussis sous Rosetta sur le M4 ;
  pas de validation sur Intel physique, ni d'application Intel complète.
- Windows natif : run **35015208320** encore en cours au dernier contrôle.
  L'ancien attenteur **35017599687** a été annulé, remplacé par **35020598056**
  qui inclut le runtime Windows épinglé et les nouveaux probes PCM/SRT.

**Le produit n'est pas livré.** La capture native macOS, l'inférence de référence,
le transport SRT et le renderer ont des preuves séparées. Il reste notamment
la preuve Windows, le consommateur PCM 16 kHz borné, le moteur de matching,
la timeline segmentée, le contrôleur/UX, le modèle/cache utilisateur, les mesures
end-to-end et le workflow quotidien upstream. L'application normale a été
reconstruite après le banc de rendu, sans laisser son point d'entrée de test.

## Préparation de l'application Windows — 2026-09-15

- Ajout du raccordement CMake au paquet mpv patché x64, avec contrôle de révision,
  hash du patch et hash de la DLL. Le paquet doit provenir d'un build natif réussi
  du fork dont le lock et le patch sont identiques aux fichiers courants.
- Six tests Python/CMake passent : préparation, provenance, conservation d'un
  paquet antérieur en cas d'échec, refus d'archives dangereuses, de mauvaise
  architecture et de paquet absent, corrompu ou périmé. Les octets PE de ces
  tests sont synthétiques ; aucune preuve d'exécution Windows n'en est déduite.
- Workflow Windows dédié préparé : SDK Flutter exact, installateur DComp upstream
  inchangé, build de l'application, contrats natifs upstream et probes PCM/SRT
  sur sa DLL effectivement empaquetée. Sorties limitées aux artefacts de test.
- Gardes de sécurité/actions et architecture du workflow : réussies localement.
  Le build natif Windows `35015208320` et la relance macOS `35023134941` restent
  en cours à ce point de contrôle. L'étape Windows n'est donc pas validée.

## Consommateur PCM et nouveau résultat macOS — 2026-09-15

- CI macOS `35023134941` **réussie** au commit `a1604b6d`, avec l'upstream
  `7e4c8feb` intégré : application construite et **13 tests natifs réussis**.
  Les identités et hashes de l'artefact sont inscrits au manifeste.
- Workflow application Windows `35024252271` lancé sur `6053295b` ; il attend
  encore le build natif `35015208320`. Aucun succès Windows PCM/app n'est annoncé.
- Nouveau consommateur C++ : mono float32 16 kHz, filtre anti-repliement,
  ring borné à 30 secondes et snapshots limités à 15 secondes. Le temps de chaque
  sample provient du centre du filtre dans la timeline PCM d'origine.
- Tests natifs locaux réussis en Release et sous AddressSanitizer/UBSan :
  fréquences 8–192 kHz, packed/planar, représentations entières/flottantes,
  invariance aux frontières de paquets, rejet 12 kHz lors de la conversion
  48→16 kHz, timestamps, ring saturé, seeks/epochs, générations et données invalides.
- Probe **réel libmpv → consommateur natif** réussi sur M4 : lecture et seeks
  avant/arrière, erreur maximale des amplitudes normalisées inférieure à 0,00003
  par rapport aux deux sinusoïdes connues et à leurs timestamps. Mesure conservée
  dans `docs/livesync-evidence/2026-09-15-pcm-consumer-macos.json`.
- Les quelques millisecondes de conversion mesurées sur ce probe court ne sont
  **pas** un benchmark de lecture de l'application. Le composant n'est pas encore
  raccordé au worker de production, à Whisper ou au contrôleur. Le multicanal
  reste refusé tant que le tap n'expose pas les positions des haut-parleurs.
- Le workflow Windows en attente `35024252271` a été remplacé par
  `35025240430`, au commit `9c5b2b3e`, pour inclure aussi le probe du nouveau
  consommateur. La CI `35025239090` construit et teste ce composant sur macOS
  et Windows, puis refait les inférences CPU de référence. Résultats en attente.

## Chaîne de transcription depuis la lecture active — 2026-09-15

- CI `35025239090` **réussie sur Windows x64 et macOS arm64** : compilation et
  tests du consommateur natif, puis inférences CPU de référence avec les deux
  modèles. Cette CI utilise des PCM synthétiques pour le consommateur ; elle ne
  prouve toujours pas la capture du player Windows.
- Sur M4, `probe_inference_pipeline.py` fait lire l'extrait JFK vérifié par mpv,
  récupère son PCM actif, le convertit via le consommateur C++, puis envoie la
  fenêtre à Whisper CPU par stdin. **175 968 samples**, début média **0,001 s**,
  erreur textuelle **0 sur cet extrait connu**, pour `base.en` et `base.en-q5_1`.
  Aucun PCM capturé ni transcript n'est conservé ; seuls les résumés sont commis.
- Les horodatages Whisper de ce smoke test ne constituent pas des ancres de
  précision validée. Aucun rapprochement SRT ou mapping automatique n'est testé.
  Les temps d'inférence de cet essai court ne constituent pas des budgets finaux.
- Le workflow application Windows définit maintenant cette même chaîne complète
  pour les deux modèles. Run courant **35025719202**, commit `750e9ad2`, en
  attente du build natif `35015208320`. Les deux attenteurs d'application
  précédents ont été annulés après remplacement ; le build natif initial continue.

## Gestion du modèle — 2026-09-15

- Gestionnaire Dart ajouté : modèles épinglés, téléchargement unique par hash,
  progression, contrôle de taille et SHA-256 en isolate, cache vérifié à chaque
  acquisition et remplacement par rename après validation. Le flux disque utilise
  des écritures attendues, sans charger le modèle entier dans l'isolate UI.
- **10 tests réussis** : catalogue conforme au manifeste, téléchargements
  concurrents, cache, corruption, taille incorrecte, interruption, suppression
  pendant téléchargement, délais d'inactivité/global et chemins invalides.
  Les leases empêchent de supprimer un modèle encore détenu par un worker.
- Le téléchargement réel de `base.en-q5_1` a été effectué par ce gestionnaire :
  **59 721 011 octets**, SHA-256 conforme, réutilisation locale sans nouvel appel
  de téléchargement et suppression vérifiées. Résumé dans
  `docs/livesync-evidence/2026-09-15-model-download-macos.json` ; les éventuelles
  redirections HTTP ne sont pas comptées comme de nouveaux appels du manager.
- Analyse et formatage des fichiers concernés réussis. Les 8 tests du loader SRT
  restent réussis. Le nouveau workflow `livesync-dart.yml` vérifie les composants
  sur Windows/macOS sans attendre la compilation de mpv.
- Le modèle n'est pas encore exposé dans l'UI de production. La récupération
  des temporaires après crash reste à raccorder au cycle de vie de l'application.

### Reprise après crash et première CI des composants

- Ajout de la récupération des temporaires à la première acquisition : seuls
  les dossiers portant le marqueur du gestionnaire, âgés de plus de 24 heures
  et ne contenant que ses fichiers attendus sont supprimés. Ce délai dépasse
  largement les 15 minutes maximales d'une préparation active. Fichiers étrangers,
  liens symboliques et temporaires récents sont préservés.
- **11 tests du gestionnaire et analyse ciblée réussis** après cette extension.
- CI `35027104786` : macOS réussi ; Windows a échoué avant les tests parce que
  le premier lancement Flutter ajoutait sa sortie de bootstrap au JSON de version.
  Le workflow initialise désormais l'outil avant la lecture JSON stricte ; les
  contrôles des révisions SDK/engine restent inchangés. Nouvelle CI à exécuter.
- Relance `35027503606` : macOS réussi ; Windows passe l'analyse mais le test de
  transfert lent expire avant sa première donnée. La vérification de présence et
  taille se fait désormais par I/O asynchrone avant de créer l'isolate de hash,
  évitant ce coût pour un cache absent. Le scénario de délai global utilise une
  fenêtre de deux secondes pour laisser le transfert démarrer sur le runner ;
  il exige toujours plusieurs chunks avant l'expiration. Les 11 tests locaux passent.

## Composants Dart et worker natif — 2026-09-16

- CI `35028609282` **réussie sur Windows et macOS**, commit `f9afd243` : analyse,
  11 tests de gestion du modèle et 8 tests de transport SRT. L'échec de préparation
  Flutter et l'hypothèse trop courte du scénario réseau précédent sont corrigés.
- Worker C++ CPU ajouté : thread dédié, contexte modèle réutilisé, au maximum
  quatre threads de calcul, une seule inférence autorisée par processus et aucun
  empilement de fenêtres. Résultats bornés et suppression des générations périmées.
- Tests locaux avec les **deux vrais modèles** : reconnaissance de l'extrait
  connu sous le seuil de 25 % d'erreur textuelle du smoke test, conversion exacte
  origine/vitesse, refus d'une deuxième analyse, annulation pendant `whisper_full`,
  reprise du même contexte, arrêt idempotent et erreur de modèle typée.
- Le test du worker quantifié passe également sous **ThreadSanitizer**, sans
  signalement sur ce scénario. Le build CPU désactive `GGML_NATIVE` et les
  extensions x86 optionnelles ; il ne suppose pas les instructions du M4/runner.
- Les timings de tokens restent expérimentaux. Ce test de worker utilise une
  fixture exportée, tandis que le probe PCM → CLI précédent utilise la lecture
  active. Le worker n'est pas encore relié au player natif ou à l'UI ; son backend
  GPU et le matching SRT restent à implémenter. La CI native inclut désormais ce
  test de worker pour Windows/macOS ; résultat de cette nouvelle exécution à venir.

### Reprise du build natif Windows

- Le run `35015208320` a échoué à 22:01 UTC le 15 septembre dans le générateur
  de shaders de libplacebo : `ModuleNotFoundError: No module named 'jinja2'`.
  Le compilateur LLVM/MinGW et les dépendances déjà construites ont été mis en
  cache avec succès. Les probes et le build applicatif dépendants n'ont pas démarré.
- Le venv Meson reçoit désormais Jinja2, Mako et jsonschema, avec contrôle de
  leurs imports avant le build. Les paquets Python installés par apt étaient
  invisibles dans ce venv isolé. Aucune révision native ni patch Flutter ne change.
  Le prochain run reprend le cache ; la preuve Windows reste à obtenir.

### Interface C et inférence pendant la lecture active

- Ajout d'une interface C versionnée du worker, avec vérification de taille ABI
  et résultat de capacité fixe détenu par l'appelant. Les textes et tokens restent
  en mémoire ; la destruction attend la fin du worker sur le thread propriétaire.
- Les deux modèles passent localement le probe ABI et le probe de lecture active
  sur Apple M4. Ce dernier prélève environ neuf secondes du vrai PCM mpv, soumet
  au worker asynchrone, puis vérifie que le lecteur avance avant réception.
  Résumés : `docs/livesync-evidence/2026-09-16-worker-active-{base,q5}-macos.json`.
- Le WER sur le meilleur préfixe de référence est nul dans ces deux essais connus.
  Les durées sont des essais ponctuels CPU, hors chargement du modèle ; elles ne
  constituent pas un benchmark ni une mesure de précision temporelle.
- CI worker `35029878710` : macOS réussi ; Windows bloqué par C4244 traité comme
  erreur dans `std::fill` (zéro entier vers float). Correction explicite `0.0f`
  dans `990f061d`, sans réduire le niveau de diagnostics ; relance en cours.
- Le worker et son ABI restent séparés de l'UI de production. Le probe utilise
  une sortie audio nulle et ne valide pas la préservation de la sortie audible.

### Banc de rendu Windows automatisé (préparé)

- Le point d'entrée de test peut désormais attendre une capture native pour six
  états : délai initial, positif, négatif, restauration, capture PCM activée puis
  désactivée. Il vérifie le texte attendu, la piste et le délai manuel avant chaque
  capture. Ce mode exige deux `dart-define` et ne touche pas l'entrée de production.
- Le workflow conserve d'abord l'application normale, puis construit ce banc.
  Le pilote PowerShell capture uniquement sa fenêtre au premier plan, à 1440×900
  si le bureau du runner le permet, et enregistre les dimensions réelles.
  Une inspection visuelle des PNG reste obligatoire ; préparer ce test ne prouve
  pas encore le rendu Windows. Analyse Dart et contrôles YAML locaux réussis.
- Ce mode automatisé utilise explicitement `ao=null`, les runners pouvant ne pas
  avoir de périphérique audio physique. Chaque état le consigne ; il ne doit pas
  être présenté comme preuve de préservation de l'audio audible.

### Compatibilité curl/libssh et provenance transitive

- Le run natif `35029877791` a restauré son cache et dépassé libplacebo, puis a
  échoué dans curl : `ssh_scp` absent de `libssh.h` avec la libssh 0.12 récupérée.
  Les déclarations se trouvent désormais dans `libssh/scp.h`.
- Un patch séparé du driver Windows ajoute un include conditionnel de ce header
  aux flags de curl. Aucune version de composant, protocole ni patch Flutter n'est
  remplacé. Préparation idempotente, 20 tests du script upstream et six tests du
  staging Windows réussis localement ; le build cross natif doit encore confirmer.
- L'inspection révèle que certaines recettes transitives du winbuild sélectionné
  suivent une branche sans SHA, malgré le commit figé du méta-build. Les SHAs
  effectivement récupérés et les hashes des diffs sont désormais archivés, même
  après échec. Le gel complet de ces références reste requis avant livraison ;
  le manifeste principal ne suffit pas à prouver leur reproductibilité.
- CI `35030407327` réussie : worker C++ **et interface C réelle** avec les deux
  modèles sur Windows x64 et macOS arm64. Cela ne prouve pas le rendu Windows.

### Comparaison locale CPU/Metal — Apple M4

`compare_macos_backends.py` lance cinq essais par modèle/backend, quatre threads
CPU, un nouveau processus/contexte à chaque fois, caches OS potentiellement chauds.
Il vérifie le backend réellement utilisé et la reconnaissance, puis supprime la
transcription temporaire. Les 20 essais passent le seuil textuel de faisabilité.

| Modèle | Backend | Durée médiane du processus | CPU cumulé médian | RSS maximal |
|---|---|---:|---:|---:|
| base.en-q5_1 | CPU | 0,423 s | 1,20 s | 262,6 Mio |
| base.en-q5_1 | Metal | 0,303 s | 0,16 s | 243,5 Mio |
| base.en | CPU | 0,415 s | 1,12 s | 345,7 Mio |
| base.en | Metal | 0,308 s | 0,17 s | 360,7 Mio |

Rapport complet et hashes : `docs/livesync-evidence/2026-09-16-macos-backend-comparison.json`.
Ces durées incluent le démarrage/chargement et diffèrent de celles du worker
réutilisant son contexte. Elles favorisent l'évaluation de Metal dans le player,
sans prouver son impact vidéo, son utilisation GPU, ses performances soutenues
ou la précision des timestamps. Les budgets de validation finale sont fixés
dans le plan, avec la machine Windows physique encore à identifier.

### Latence CPU portable Windows : échec du budget

- Les rapports ABI de `35030407327` montrent **19,03 s pour base.en** et
  **17,41 s pour q5_1**, hors chargement du modèle, sur l'extrait de 11 secondes.
  Reconnaissance correcte (WER nul), mais le budget de latence est dépassé.
  Ces mesures isolées du runner ne constituent pas une validation matérielle finale.
- Rapports conservés sous `docs/livesync-evidence/2026-09-16-worker-portable-*-windows.json`.
  La CI compare désormais un profil AVX2 explicite après vérification CPU/OS
  d'AVX2, SSE4.2, BMI2, FMA et F16C. Les résultats de cette comparaison restent
  à obtenir ; aucune sélection automatique ou distribution AVX2 n'est encore faite.
- Le CPU portable demeure le défaut. Une sélection sûre avant chargement de la
  bibliothèque optimisée sera requise pour les machines plus anciennes.

### Préparation d'un corpus distinct du smoke test

- Master audio stéréo de **Sintel**, 888 s à 48 kHz, et SRT anglais original
  récupérés depuis Xiph ; taille et SHA-256 vérifiés, hash audio conforme au
  fichier de checksums publié. Les deux notices confirment CC BY 3.0 avec
  attribution à Blender Foundation ; elles sont également épinglées.
- Les sources restent hors Git. `prepare_corpus.py` vérifie les octets, préserve
  un fichier existant différent et conserve les notices. Téléchargement réel
  d'une notice, réutilisation et préservation d'un fichier étranger vérifiés.
- Séparation fixée avant calibration : 100–175 s pour calibrer, 200–650 s pour
  valider, 650–888 s sans cue SRT. Aucune inférence n'a encore été faite sur ces
  partitions. Les timings authored du SRT ne sont pas des ancres acoustiques
  indépendantes ; celles-ci et les variantes temporelles restent à préparer.

### Comparaison CPU Windows AVX2 réussie

Run `35031841845`, commit `42fda2e8`, runner Windows sur AMD EPYC 9V74 avec
**2 cœurs/4 processeurs logiques attribués**, environ 16 Gio. Le contrôle CPU/OS
préalable a confirmé toutes les instructions requises avant chargement de l'ABI.

| Modèle | CPU portable, même run | CPU AVX2 | WER |
|---|---:|---:|---:|
| base.en | 25,49 s | 1,69 s | 0 |
| base.en-q5_1 | 22,67 s | 2,15 s | 0 |

Durées d'inférence hors chargement, un essai par combinaison, fixture de 11 s.
Rapport : `docs/livesync-evidence/2026-09-16-windows-cpu-comparison.json`.
Le run portable précédent était plus rapide (17–19 s) : cette variation de CI
renforce le besoin de séries mesurées sur machine identifiée. Le gain justifie
une sélection CPU à l'exécution, mais celle-ci et son packaging restent à
implémenter. Aucun p95, impact sur la lecture ou résultat GPU Windows n'est validé.

## PCM et transport SRT Windows natifs démontrés — 2026-09-16

Le run **`35031113958` est réussi**, SHA fork `4ac6dd6d` : compilation du DLL
patché, puis probes exécutés sur Windows x64. Résumé et provenance complète :
`docs/livesync-evidence/2026-09-16-windows-native-probes.json`.

- 42 blocs PCM contrôlés sur lecture initiale, seeks avant/arrière et vitesse 1,5× :
  erreur maximale **0** sur les échantillons vérifiés aux PTS attendus.
- Pause/désactivation, overflow avec hausse d'epoch/dropped, et transfert limité
  à 256 Kio vérifiés. Sortie audio nulle : aucune validation audible implicite.
- SRT local et HTTP authentifié contrôlé : texte complet accessible, sélection
  native, délais positifs/négatifs et restauration du manuel à **0,125 s** réussis.
  Hash du SRT original conservé. Ni catalogue Plex/Jellyfin réel ni pixels validés.
- Artefact natif `10421094562`, archive intérieure SHA-256
  `a2aff7c906a4f8e9cc2981092984e648a1edef4c1a00d5c590671dc6a9357b33`,
  DLL `834c26a327cfd829eca194e4a109f862cf0ed79346cab6f206bac667dba8b873`.
- 87 révisions de sources observées sont archivées dans
  `2026-09-16-windows-native-sources.json`. Ce relevé n'est pas encore un gel
  exhaustif des téléchargements transitifs ni une preuve de rebuild identique.

Le premier staging applicatif (`35032033326`) a refusé les fichiers d'entrée
convertis en CRLF par Git Windows. `.gitattributes` force désormais LF uniquement
pour les entrées comparées octet par octet ; **7 tests de staging réussissent**,
dont un vrai checkout Git avec `core.autocrlf=true`. Le staging suivant a passé.
Le run applicatif actuel est `35032845964` (SHA `6afb5ee9`), incluant le banc de
rendu au nom d'exécutable réel `plezy_livesync.exe` ; résultat encore attendu.

### Upstream 9babe681 intégré — contrôles en cours

Le commit officiel `9babe6814a0f8bea13ee25904431d809af1e5d08` est intégré
par le merge `71cec7d8`. Sentry passe à 9.30.0 ; les pins Flutter, moteur custom,
mpv, FFmpeg et SentryCocoa restent inchangés. Résolution verrouillée réussie.
Les résultats et artefacts précédents restent attribués à leur SHA testé ;
la nouvelle analyse, suite complète et les builds natifs sont à revalider.
Le build Windows `35032845964`, déjà lancé, contient encore `7e4c8feb`.

### Revalidation 9babe681 et faisabilité Windows

- Suite Flutter locale complète au fork `b77dd811` : **7 267 réussis, 6 ignorés,
  aucun échec**. Analyse Dart complète et codegen réussis. Les huit tests du
  parseur SRT ajoutés ensuite passent séparément, y compris les 26 cues Sintel.
- macOS : build CI `35033587609` réussi à `b77dd811`, **13 contrats natifs**
  réussis. Artefact app `10422931951` et provenance exacte dans le manifeste.
- Windows : `35032845964` a construit l'app `6afb5ee9` (upstream `7e4c8feb`),
  passé ses trois contrats natifs, les probes PCM/SRT, le consommateur et les
  inférences sur PCM de lecture active. WER 0 sur le préfixe JFK ; base 18,26 s,
  q5 23,62 s hors chargement. Le profil portable dépasse le budget de latence ;
  ces valeurs isolées ne sont pas des p95 ni une validation de fluidité audible.
- Le renderer Windows expire initialement pendant l’attente de la piste ;
  les logs prouvent que `ao=null` déclenche la récupération audio upstream, qui arrête la lecture
  après cinq tentatives. Diagnostics/screenshot conservés dans `35034266231`.
  Le banc utilise désormais D3D11 WARP et PCM vers le périphérique `NUL` ;
  relance `35034940985` en attente. Pas de preuve de sortie audible ou de GPU.
- La CI upstream complète `35034268551` confirme le formatage natif, Linux
  (ASan/TSan), le serveur, le site et les dépendances. Ses jobs Apple/macOS et
  Windows x64 nécessitaient le staging patché, ajouté depuis ; le test tvOS
  sur les pins Apple est adapté et passe localement (6 tests, 123 assertions).
- Les contrôles de code/fichiers inutilisés refusent encore les composants
  LiveSync préparés mais non branchés. Ils restent actifs. Le contrôleur et
  l'intégration finale doivent supprimer ces échecs par une utilisation réelle.
- Identités d'installation Windows séparées (Inno/MSIX), exécutable harmonisé,
  16 tests du guard MSIX réussis. Métadonnées PowerShell à exercer en CI ;
  installation/désinstallation et signature restent non validées.

### Porte native acquise : rendu Windows lisible et réversible

`35035639850` réussit au fork `58c6ec0a`, incluant `9babe681`. Les six PNG
1024×720 sont inspectés dans `docs/livesync-evidence/2026-09-16-renderer-windows/` :
FIRST, absence de cue à +2,125 s, SECOND à −3 s, restauration FIRST avec délai
manuel +0,125 s, puis prélèvement activé/désactivé sans changer le rendu.
Le bureau CI est limité à 1024×720 ; rendu natif D3D11 WARP, audio PCM éliminé
dans `NUL`. Aucune validation audible ou de performance GPU n'en est déduite.

La correction du banc monte `Video` après l'initialisation native : autrement
le premier `setVideoRect` précède la création du HWND, accepte un no-op, et laisse
la surface à 100×100. Les anciennes captures ne sont pas utilisées comme preuve
d'un rendu de taille normale. Aucun changement du moteur Flutter custom.

`capture_bridge` ajoute maintenant un poller natif en arrière-plan, à priorité
réduite, avec client faible du lecteur. Sa table de fonctions vient du mpv déjà
chargé (le framework Apple est statique : aucune deuxième image mpv à charger).
Sur Mac, vraie capture, changements de génération, seeks avant/arrière, pause,
exclusion d'un second captureur et libération du client à l'arrêt du lecteur
passent. Le ring est vidé à l'arrêt. La purge double après seek a été supprimée :
l'epoch du tap effectue déjà cette purge. Le même probe passe sur Windows x64
dans `35036347229` au fork `8af77dc3` : erreur maximale des échantillons
2,93e-5, ring vidé à l'arrêt et libération du parent en 15 ms sur cette exécution.
Le rapport est conservé dans `2026-09-16-capture-owner-windows.json`.
L'intégration au player applicatif reste à faire ; ces probes ne prouvent pas
une sortie audible ni les performances de l'application finale.

La CI complète `35035257410` passe désormais les tests unitaires, Windows x64
et arm64, macOS, tvOS, Android et Linux ASan/TSan. Les deux échecs restants sont
le contrôle de code non utilisé et le test iOS
`testRealSetPropertyValidInvalidNonexistentAndPauseCache` (33,9 s). Ce dernier
n'est pas classé comme régression LiveSync ni comme fluctuation sans diagnostic.

### Identification textuelle initiale (tests injectés)

Normalisation Unicode séparée du texte original, index chronologique borné et
alignement approximatif sur plusieurs cues ajoutés. La recherche conserve les
concurrents et refuse les candidats saturés, les phrases courtes/génériques et
les répétitions adjacentes ou éloignées. La marge inclut les concurrents sous
le seuil d'acceptation. Les scores restent heuristiques, sans calibration réelle
ni déduction d'une ancre temporelle précise. Neuf nouveaux tests passent ; les
36 tests des composants LiveSync passent localement, analyse Dart sans remarque.

### Chaîne intégrée et premier test réel de correction

Les bindings FFI contrôlent l'ABI et les bornes, transfèrent le client faible
du mpv déjà chargé dans l'application et effectuent la capture, l'inférence,
la purge et les joins dans un isolate dédié. Le modèle reste protégé jusqu'à
la fin du teardown. Le runtime CPU épinglé est inclus dans l'app, avec empreintes
d'entrée/sortie et signature locale des dylibs Mac ; le packaging Windows
revérifie les fichiers à l'installation et force leur recopie.

Preuves locales nouvelles, sans sortie audible :

- `2026-09-16-dart-native-{base,q5}-macos.json` : vraie capture/inférence depuis
  Dart, annulation, exclusion d'un second propriétaire et heartbeat de l'isolate
  principal. Inférences individuelles de 0,356/0,373 s, pas une mesure p95.
- `2026-09-16-production-controller-stereo-macos.json` : vrai contrôleur et mpv
  applicatif, audio Sintel de la partition de calibration 100–175 s, SRT entier
  inchangé. Décalage −100,157656 s pour −100 s attendues, acquisition 47,494 s.
  Délai manuel avant/pendant/après vérifié, tap désactivé à l'arrêt. Une seule
  exécution avant les modifications multicanales suivantes ; aucune preuve
  Mentalist, de sortie audible ou de précision statistique. Budget 45 s dépassé.
- Conversion mono d'analyse par moyenne de tous les canaux (1–8), sans matrice
  de positions supposée. Tests PCM sur chaque canal, packed/planar, échantillons
  sources inchangés. Le dialogue réel placé artificiellement au centre d'une
  piste 5.1 passe dans le banc natif sans interface : −100,944 s en 45,604 s,
  rapport `2026-09-16-domain-alignment-six-channel-macos.json`. Des ancres
  individuelles errent de plusieurs secondes : ce test ne valide pas la
  précision ni une véritable bande-son surround. Les essais dans l'app 5.1
  n'ont pas confirmé l'acquisition ; le Mac s'est ensuite verrouillé.
- 108 tests Dart ciblés passent, dont composition des délais, concurrence,
  arrêt utilisateur pendant un changement de piste et annulation du worker.
  Contrôle d'analyse upstream, code/fichiers inutilisés, formatage Dart, tests
  PCM natifs, build Mac normal et `git diff --check` passent localement.
- Le nouveau contrat Swift du client faible passe après initialisation
  explicite de `pause=yes` ; le test ne suppose plus la valeur par défaut.
  L'ancien échec iOS du run `35035257410` passe à sa relance ciblée (tentative 2).

La partition de validation séparée 200–650 s n'a pas été utilisée pour ajuster
les seuils. Les horodatages SRT sont une référence éditoriale, pas une annotation
indépendante des débuts de parole. Les nouvelles bibliothèques et le contrôleur
Windows doivent encore passer leur CI ; le workflow ajoute cette preuve et
échoue si l'offset attendu n'est pas acquis. Le projet reste en cours.

### Affinement des horodatages par DTW

La calibration montre qu'une phrase parfaitement reconnue peut avoir une ancre
legacy à −104,08 s pour −100 s attendues. Le worker active maintenant les têtes
d'alignement `WHISPER_AHEADS_BASE_EN`, communes aux deux modèles épinglés, et
désactive explicitement flash attention : cette version de whisper.cpp désactive
sinon silencieusement DTW. Le budget d'espace de travail DTW est fixé à 128 Mio.
Les tokens exposent des intervalles de point d'alignement de 20 ms, et non une
durée de mot prétendument mesurée. L'incertitude de l'aligner reste distincte.

`2026-09-16-domain-alignment-six-channel-dtw-macos.json` : vraie capture active,
modèle quantifié, même partition de calibration, offset −100,229 s en 33,616 s.
Trois ancres dans deux fenêtres distinctes : −100,229 / −100,302 / −100,072 s.
Les contrats natifs avec les deux modèles passent (horloge, inférence unique,
annulation et reprise). Cette amélioration n'est pas une validation statistique,
une preuve Windows ou une preuve du contrôleur applicatif après modification.
Le build normal macOS est reconstruit ; vérification visuelle bloquée par le
verrouillage du Mac. Les performances mémoire/lecture et la validation séparée
restent nécessaires.

### Contrôles de l'intégration poussée

Au fork `fd658da8`, les composants Dart passent sur macOS et Windows dans
`35043203123`. L'inférence native et ses contrats passent sur les deux plateformes
dans `35043203122`. Le build et le contrôleur applicatif Windows sont encore
en cours dans `35043215939` : ces succès ne prouvent pas cet autre parcours.
Le contrôle local complet de génération de code passe également.

Une reconstruction incrémentale Mac a révélé un sceau de signature périmé pour
le runtime remplacé. Les fichiers embarqués sont désormais déclarés comme
sorties Xcode (`6e7c6fc3`) ; le bundle reconstruit passe `codesign --verify --deep
--strict`. La CI vérifie aussi ce sceau avant de créer son archive.

La suite complète locale a exposé une course dans le serveur HTTP du test de
délai total du modèle (écriture pendant un flush). Le test sérialise maintenant
les écritures et vérifie qu'un timeout d'inactivité prématuré ne satisfait pas
l'assertion ; ses 11 tests passent. Aucun changement au téléchargeur de production.


### SRT intégré Plex : défaut utilisateur reproduit et adaptateur branché

Le cas signalé emploie un SRT intégré, sans `Stream.key`, auparavant refusé
par le contrôleur. `/library/streams/{id}.srt` renvoie HTTP 501. L'extraction
Plex exige une décision préparée et une session dédiée ; une requête nue
peut échouer ou dépendre d'une ancienne session. Le serveur peut aussi choisir
de transcoder l'audio ou de convertir le SRT en ASS si les profils sont omis.

L'adaptateur vérifie la sélection avant/après, prépare un profil de copie,
refuse toute décision A/V autre que `copy`, exige le même SRT en copie et
ne récupère que le corps texte complet. Aucun endpoint de démarrage A/V
n'est demandé. Plex parcourt et remuxe néanmoins le conteneur côté serveur
pour en extraire la piste : son coût reste à mesurer. La session créée est
arrêtée en fin de requête ou annulation. La sélection et les fichiers sources
ne sont pas modifiés. Le document est conservé en mémoire pour la source
de lecture courante seulement ; changer de média le libère.

Une validation privée du **code de transport de production**, sur PMS
1.43.4.10903, récupère et parse 815 cues / 57 067 octets en 80,404 s. Les
identifiants du serveur, secrets et dialogues restent hors dépôt. Un probe
natif distinct, avec un unique flux de lecture H.264/EAC3 5.1, reconnaît les
dialogues et estime +3,749 s en 46,010 s, puis applique le délai mpv. L'arrêt
de sa session d'extraction renvoie HTTP 200. Ce n'est ni une mesure de
précision (décalage attendu non annoté), ni une preuve du contrôleur/UI Plezy
sur cet épisode. La lecture audible et le contrôle visuel restent ouverts.

L'UI affiche le chargement des sous-titres pendant l'extraction. 51 tests
Dart ciblés passent, dont huit cas de transport Plex (sélection, changement
pendant extraction, cache en mémoire, annulation, refus média/playlist et
refus de réencodage). Analyse du dépôt sans diagnostics et build macOS
normal avec signature stricte vérifiée.

Windows : `35043215939` échouait avant l'analyse, car le banc lançait
LiveSync avant la confirmation des pistes. Le banc attend désormais cet
événement. `35045347613` échoue plus tôt sur le délai du probe d'inférence
CPU quantifiée : aucun résultat applicatif Windows n'est déclaré acquis.
Les vérifications de traduction et le format du pont Windows ont été
corrigés dans `b07bfad3`; attente des pistes dans `a9fef9b9`.


### Sélection CPU Windows et actualisation upstream

Le nouvel upstream `e38759127a1fb26c4cd99172ba6609fd50e355d9` a été vérifié le
16 septembre à 02:09:21 UTC, puis intégré sans conflit dans `146a41a1`.
64 tests ciblés et l'analyse complète passent ; les builds conservés avant
cette intégration restent identifiés par leur ancien SHA.

Le runtime Windows empaquette maintenant deux DLL d'inférence : CPU portable
et AVX2. Le pont portable vérifie SSE4.2, AVX, AVX2, BMI2, FMA, F16C, XSAVE,
OSXSAVE et l'état XMM/YMM avant tout chargement accéléré. Une bibliothèque
absente ou incompatible revient au CPU portable. Les 55 tests Dart ciblés,
le test natif des capacités et une véritable inférence sur Mac passent.
Le choix réel et le secours Windows restent à vérifier dans la nouvelle CI.

Le délai du probe de compatibilité CPU portable Windows passe explicitement
à 90 s, car son précédent délai total de 35 s incluait neuf secondes de
capture et masquait le résultat lent. Cela ne change pas le budget de
performance de 3 s p95 et ne constitue pas une validation de ce budget.

### Vérifications du 16 septembre : upstream e3875912 et sources locales Windows

À `d99fad3b`, la suite complète locale termine en 10 min 59 s avec **7 311
succès et 6 tests ignorés**. Le build macOS de ce SHA et sa copie de revue
passent la vérification stricte de signature. Les contrôles CI natifs et Dart
`35047604719` / `35047604744` passent sur macOS et Windows. Les catalogues
non traduits nécessitaient les clés vides de repli LiveSync (`22121478`) ;
les icônes de bascule devaient utiliser les Symbols arrondis (`beb7416e`).
Génération, hygiène des traductions, icônes, analyse et détection du code et
des fichiers inutilisés passent localement après ces corrections.

Le run Windows `35047604169` prouve le choix automatique AVX2, le secours
portable lorsque la DLL accélérée manque, la capture et l'inférence natives,
ainsi que les six étapes de rendu du délai. Les captures baseline/positive/
restored montrent respectivement le cue, son absence après +2 s, puis son
retour avec le délai manuel restauré. Ce banc synthétique ne prouve pas le
recalage automatique d'un film. Sa capture de bureau est limitée à 1024×720.

Le contrôleur applicatif de ce run échoue sur `unsupported-englishTracks`.
L'attente de sélection ne suffit donc pas : mpv canonicalise les chemins
Windows des sidecars, tandis que le catalogue était indexé sur la chaîne
exacte. Les chemins mélangeant `\\` et `/` perdent leurs métadonnées. Le
correctif `7568fff0` canonicalise seulement les clés des chemins Windows,
conserve les URI des pistes et ne réécrit pas les URL signées. Ses 41 tests
ciblés passent. La confirmation dans l'application Windows reste en cours.

Sur ce même runner Windows Server 2025 / AMD EPYC 9V74, 2 cœurs / 4 threads,
le pont réel avec DTW et AVX2 traite la fenêtre JFK d'environ 8,51 s en
**2,665 s avec base.en**, contre **14,266 s avec Q5_1**. Le secours portable
Q5_1 prend **29,122 s** sur environ 8,57 s. Windows choisit désormais base.en
(148 Mo affichés), tandis que macOS conserve Q5_1 (60 Mo). Ces observations
uniques ne sont ni un p95, ni une preuve de fluidité audible ; le budget
sur des fenêtres de 12 s n'est pas encore établi.

### Première portion de validation indépendante : acquisition échouée

Le moteur figé avant l'essai (`5de134a9`, runtime natif de `bac639f9`) a lu
l'audio Sintel 200–275 s avec le SRT original complet. Aucun seuil n'a été
modifié pour ce résultat : offset attendu −200 s, limite d'erreur fixée à
750 ms, fenêtre d'acquisition maximale de 75 s.

Résultat : **aucun verrouillage en 75,049 s**, quatre analyses terminées,
un résultat sans candidat puis trois avec dialogue insuffisant. Il n'y a
aucune mesure de précision à calculer et aucun faux verrouillage observé
sur cet unique essai. Les dialogues courts et les fenêtres de capture sont
à étudier sur les fixtures de développement. Le rapport initial est conservé
dans `docs/livesync-evidence/heldout-200-275-initial.json` sans PCM ni dialogue.
Cette portion ne pourra plus servir de validation indépendante après un
ajustement motivé par cet échec. À ce stade, les portions 275–650 s et 650–888 s
étaient encore non évaluées ; leurs premiers résultats figurent plus bas.

Le modèle de timeline affine et ses 17 tests d'ancres injectées restent
isolés sur `codex/livesync-timeline` (`05a71c55`). Ils couvrent domaines bornés,
dérive et gaps explicites, mais ne sont pas raccordés au contrôleur de
production. La dérive et les scènes différentes ne sont donc pas livrées.

Reproduction de cette première portion (sources vérifiées par
`prepare_corpus.py`, runtime Mac construit par `build_analysis_runtime.py`) :

```sh
mkdir -p build/livesync/heldout-200-275
ffmpeg -v error -y -ss 200 -t 75 \
  -i build/livesync/corpus-source/sintel-master-st.flac -c:a pcm_s16le \
  build/livesync/heldout-200-275/fixture.wav
dart run tool/livesync_native_engine_probe.dart \
  --mpv build/livesync/libmpv-probe-metadata.dylib \
  --capture build/livesync/runtime/macos-arm64/liblivesync_capture_bridge.dylib \
  --inference build/livesync/runtime/macos-arm64/liblivesync_inference_bridge.dylib \
  --model /path/to/verified/ggml-base.en-q5_1.bin \
  --audio build/livesync/heldout-200-275/fixture.wav \
  --srt build/livesync/corpus-source/sintel_en.srt \
  --expected-offset -200 --maximum-error 0.75 \
  --output build/livesync/evidence/heldout-200-275-native.json
```

Ce WAV est une fixture redistribuable préparée explicitement pour le test ;
le prélèvement PCM effectué pendant sa lecture n'est pas conservé.

### Contrôleur Windows confirmé et nouveaux essais audio — 16 septembre

La CI upstream complète [35049528726](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35049528726)
passe à `a9d34645`. La canonicalisation des chemins est désormais confirmée
dans le contrôleur de production Windows, avec capture PCM et vraie inférence :

| Modèle | Acquisition | Erreur / SRT authored | Run applicatif |
|---|---:|---:|---|
| Q5_1 | 58,487 s | 125 ms | [35049057261](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35049057261) |
| base.en | 24,261 s | 199 ms | [35049530583](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35049530583) |

Les deux vérifient la somme avec le délai manuel et son maintien après arrêt,
ainsi que la désactivation du prélèvement. Les rapports publics sont
`windows-q5-controller-calibration.json` et `windows-base-controller-calibration.json`
sous `docs/livesync-evidence`. Les runs utilisent des VM différentes : ce n'est
pas une comparaison statistique contrôlée. Sortie PCM vers NUL et rendu logiciel,
donc aucune preuve d'audio audible ni de performance GPU physique.

Le matching de `4f492eb2` conserve au plus deux fenêtres adjacentes, sans déplacer
les timestamps des tokens. Il peut tester des groupes contigus de 1 à 3 segments
ASR parmi au plus huit segments. Les seuils textuels ne baissent pas et les
ancres contradictoires restent soumises au filtre temporel. Une tentative sans
ancre élargit la fenêtre suivante de 12 à 15 s. Les quatre nouveaux essais sur
200–275 s, dont un avec base.en, **échouent encore à acquérir en 75 s**. Il ne
faut pas présenter ce cas comme corrigé par l'ajout de contexte.

La fixture `intro-90` ajoute 90 s de silence à la portion de calibration
100–175 s et adapte les timestamps du SRT sans modifier son texte. Le probe
natif Mac acquiert **+89,828 s**, pour +90 attendu, en **105,532 s au total**
(erreur 172 ms). Les cinq premières analyses ne produisent aucune ancre. Ce
résultat précède le dernier garde-fou conservateur sur les tokens chevauchants ;
le chemin de correspondance complète utilisé n'a pas changé. Le rapport
`intro-90-macos-native.json` précise cette limite de provenance. Ce n'est pas
encore une validation du contrôleur ou du rendu natif du générique sur Mac.

Deux nouvelles évaluations indépendantes, sans retoucher les seuils après lecture :

| Portion Sintel | Résultat | Limite |
|---|---|---|
| 275–650 s, code `370d95d5` | −275,279 s acquis en 195,723 s ; erreur 279 ms | Le probe s'arrête au premier verrouillage, vers 470,7 s de la source. Le reste du clip n'est pas évalué. |
| 650–888 s, code `785dcef2` | Aucun verrouillage en 238,033 s | Sept analyses terminées, trois échecs natifs ; observations périodiques, pas couverture continue. |

Les rapports `heldout-275-650-initial.json` et `negative-650-888-initial.json`
contiennent uniquement métriques, temps et identifiants de cues, avec hashes
des fixtures. Le premier cas comporte huit analyses sans dialogue suffisant
avant acquisition. **Une acquisition indépendante ne valide ni la médiane de
250 ms, ni le p95 de 750 ms**, et son délai total ne respecte pas le budget
de 45 s. L'échec initial 200–275 s reste dans le bilan. Aucun résultat de cette
série ne constitue une annotation précise des attaques acoustiques.

### Raccordement de la timeline — `55da2726`

Le modèle auparavant isolé (`05a71c55`, repris par `1a5587af`) est raccordé au
contrôleur. Les régions observées restent disponibles après seek ; les
prédictions sont séparées, limitées à 120 s et révoquées à toute discontinuité.
La correction affine utilise l'horloge mpv et s'ajoute au délai manuel. Un saut
d'offset confirmé conserve les anciennes régions mais ne prétend pas connaître
la frontière de scène. Les intervalles intermédiaires restent inconnus.

**90 tests ciblés** passent localement et l'analyse ciblée ne signale aucun
diagnostic. Ils comprennent 17 tests du domaine et six du suivi incrémental.
Ce sont des preuves avec ancres injectées, pas une preuve acoustique de dérive.
Le nouveau banc Windows teste en plus un seek en zone inconnue puis un retour
dans une zone apprise avec contrôle du délai natif et de la contribution manuelle.
Run [35053063463](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35053063463)
déclenché, résultat en attente au moment de cette note. Les détails et limites
figurent dans `docs/live-subtitle-sync-timeline.md`. Les performances, le lissage,
le délai audio manuel, les gaps confirmés et leur rendu restent à traiter.

Le build macOS debug de `55da2726` compile et sa signature passe la vérification
stricte. Une copie identifiée et son manifeste sont conservés dans
`build/livesync/review-builds/55da2726/`. L'analyse complète du dépôt passe aussi.
L'application n'a pas été contrôlée visuellement : le bureau Mac reste verrouillé.

Le probe natif utilisant cette timeline et la vraie horloge mpv retrouve ensuite
le générique de 90 s : **+89,788 s, erreur 212 ms, acquisition totale 135,856 s**,
sept analyses terminées et aucune rejetée. La première fenêtre de dialogue ne
fournit qu'une ancre ; la suivante permet la confirmation. Ce délai plus long
que le premier essai reste dans le bilan. Le rapport
`timeline-intro-90-macos-native.json` identifie le tracker `55da2726` et le blob
du probe ajouté dans `b32c5be1`. Il ne prouve pas la dérive ni le rendu applicatif.

Le correctif suivant `1a0f82e5` compose le délai audio manuel dans la timeline
audio avant de reconvertir vers l'horloge vidéo. Sept tests du suivi passent,
y compris les deux signes et une pente différente de un ; l'analyse complète
reste verte. Le banc applicatif contrôle désormais aussi cette composition et
la conservation du délai audio après désactivation. Sa preuve native est en
attente. La CI upstream complète de `785dcef2`,
[35052223364](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35052223364),
est verte ; elle précède ces changements de timeline et de délai audio.

### Échec conservé : générique dans le contrôleur Windows

Le run [35052221863](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35052221863)
à `785dcef2` passe le cas simple en **24,819 s, erreur 167 ms**, avec le nouveau
seuil de 750 ms et les vérifications manuelles. Son cas **intro-90 échoue par
expiration du délai d'acquisition**. Cinq analyses silencieuses ne produisent
aucune ancre, une analyse native est rejetée, puis un rapprochement fournit
une seule ancre à +85,677 s. Elle ne suffit pas à confirmer un mapping et aucune
correction n'est appliquée. Les rapports complets des deux cas sont conservés
dans `docs/livesync-evidence/windows-{calibration,intro-90}-785dcef2.json`.

Cet échec expose aussi une attente inutile : après une erreur native ou un
dialogue retrouvé avec une seule ancre, l'acquisition restait au rythme de 30 s
hérité du silence. `3186f7a8` partage une politique de cadence entre contrôleur
et probe : passage reconnu sans mapping fiable → prochaine fenêtre de 15 s
après 12 s minimum ; deux erreurs natives consécutives bénéficient aussi de ce
retry, puis retour au rythme lent. Aucun seuil d'acceptation n'est abaissé et
la cause du rejet natif lui-même n'est pas présentée comme corrigée.

**93 tests ciblés passent** avec l'analyse complète sans diagnostic. Le nouvel
essai Windows est déclenché ; ce correctif de cadence ne transforme pas l'échec
précédent en succès. Le rendu natif et la précision de la dérive restent ouverts.

L'essai natif Mac du nouveau code `3186f7a8` retrouve **+89,775 s**, soit 225 ms
d'erreur, en **117,830 s au total**. Sept analyses terminées, aucune rejetée.
Le rapport `cadence-intro-90-macos-native.json` conserve ce résultat ponctuel ;
des contrôles/builds locaux tournaient en parallèle, donc aucune distribution
de latence ni comparaison contrôlée n'en est déduite. Le nouveau run applicatif
Windows est [35053833262](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35053833262).

Le contrôle du code inutilisé a repéré l'ancien `ConstantOffsetEstimator`,
remplacé par la timeline. `f80d7e65` le retire et migre les 16 tests d'alignement
et de contexte vers le fitter/tracker de production ; ils passent, ainsi que
l'analyse complète. Aucun garde upstream n'est désactivé.

Les contrôles finaux de code et de fichiers inutilisés passent. Le build macOS
debug `f80d7e65` et sa signature stricte passent ; sa copie de revue et le hash
du kernel Dart sont conservés dans `build/livesync/review-builds/f80d7e65/`.
Cela ne valide pas l'interface verrouillée ni le recalage audible de Mentalist.

### Contrôleur Windows : générique, navigation et délais confirmés

Le run [35053526846](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35053526846)
est entièrement vert à `3e4b4229` :

| Cas | Acquisition totale | Correction | Erreur / SRT |
|---|---:|---:|---:|
| Calibration | 38,672 s | −100,236 s | 236 ms |
| Intro de 90 s | 120,162 s | +89,799 s | 201 ms |

Dans chaque cas, le contrôleur réel vérifie le délai natif, un seek en zone
inconnue qui retire seulement sa correction, le retour dans une zone apprise,
les deux signes du délai audio manuel, le délai manuel des sous-titres et leur
conservation après désactivation. Les rapports `windows-*-3e4b4229.json`
conservent cette preuve. Sortie audio NUL et GPU logiciel : aucune validation
audible ou sur GPU physique. Ce succès suit l'échec conservé à `785dcef2` et ne
démontre pas une acquisition déterministe ni un p95. Il précède la nouvelle
cadence et le VAD. La CI upstream complète
[35054120815](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35054120815)
est également verte à `0d795195`.

### Suivi d'activité vocale — `dbe211a4`

Le VAD léger est branché au contrôleur et au probe natif, dans l'isolate existant.
Il examine les nouveaux échantillons de snapshots PCM de deux secondes et ne
renvoie que des agrégats temporels. La cadence réagit aux reprises d'activité et
compare les durées avec l'union des cues de dialogue. Un désaccord déclenche une
vérification ; il ne crée aucune confiance ni aucun décalage. Le bruit musical
continu ne peut pas imposer indéfiniment une cadence de 12 s. Détails et limites :
`docs/live-subtitle-sync-activity.md`.

Deux essais natifs Mac du code figé, avec les mêmes bibliothèques CPU :

| Cas | Résultat | Activité / analyses |
|---|---|---|
| Intro 90 s | +89,762 s, erreur 238 ms, acquisition 115,607 s | 226 lectures d'activité ; quatre ASR terminés, aucun rejet |
| Négatif 650–888 s | Aucun verrouillage en 238,062 s | 464 lectures d'activité ; six ASR terminés, cinq rejets |

La première ligne représente un essai de développement, la seconde une
régression d'une portion de validation déjà consommée. Le détecteur considère
455/464 observations du passage musical négatif comme actives : **il ne sépare
pas fiablement musique et parole**. Le rapprochement textuel/temporel empêche
néanmoins le verrouillage dans cet essai. Les rejets natifs restent visibles et
ne sont pas comptés comme analyses réussies.

Les appels d'activité prennent au total 170,634 ms / maximum 13,553 ms pour
l'intro et 324,011 ms / maximum 13,920 ms pour le négatif, dans l'isolate de test.
Ce sont des durées murales ponctuelles, pas des mesures CPU/UI ni un p95 de
transcription. Rapports : `activity-{intro-90,negative}-dbe211a4.json`.
La nouvelle CI applicative Windows
[35054766606](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35054766606)
a échoué sur la calibration : aucun verrouillage avant expiration. Trois puis
quatre cues reconnues comportent des horodatages contradictoires ; le moteur
refuse de les considérer comme un recalage fiable. L’intro et les contrôles
après acquisition ne sont pas atteints. Rapport conservé :
`windows-calibration-dbe211a4.json`. Les résultats Windows précédents ne
valident donc pas ce build VAD. La CI upstream complète `35055632459`, à
`2346f164`, passe ; elle ne remplace pas cette validation fonctionnelle.

### Absence de PCM et build de revue — `c679fc8a`

Après 30 secondes observées de lecture active sans aucun échantillon, la capture
s'arrête avec l'état d'indisponibilité. Pause, buffering et PCM silencieux ne
déclenchent pas ce délai. Le passthrough est vérifié pendant la lecture sans
être désactivé. Le changement de session attend la fin d'un worker en fermeture.
Trois tests de disponibilité et les régressions lifecycle/délai manuel passent ;
ce n'est pas encore une preuve native d'injection de panne.

**104 tests ciblés**, analyse complète et contrôles de code/fichiers inutilisés
passent. Le build macOS debug `c679fc8a` et sa signature stricte passent ; copie
et provenance dans `build/livesync/review-builds/c679fc8a/`. Les contrôles visuels
sur le Mac verrouillé, la dérive réelle, les gaps et les autres critères du Goal
restent ouverts. Aucun statut de livraison finale n'est attribué.


### Dérive avec parole réelle — `8f2f7ac2`

Le chapitre de développement LibriSpeech `1272/128104` contient 145,195 s de
parole et 15 transcriptions originales. La fixture ralentie conserve le texte
et applique la pente `25025/24000` à l'audio. Les cues suivent les limites des
fichiers source : ce ne sont pas des annotations de début des mots. Provenance,
licence, sommes de contrôle et reproduction dans
`live-subtitle-sync-speech-fixtures.md`.

| Essai natif Mac | Acquisition initiale | Pente acquise | Erreur p95 / maximum après acquisition |
|---|---:|---|---:|
| Sans dérive, `fe3b0b18` | 70,777 s | Constante conservée | 638 / 638 ms |
| Dérive initiale, `9fda2cf3` | 93,541 s | Non | 912 / 997 ms — échec |
| Conservation des repères, `9ad7ab86` | 93,631 s | Non ; analyse suivante rejetée | 1 946 / 2 030 ms — échec |
| Confirmation rapprochée, `8f2f7ac2` | 93,611 s | 1,042619 à 117,647 s | 637 / 683 ms — passe |

Le premier essai a révélé qu'un repère isolé initial était perdu après la
confirmation d'un groupe de décalages constants. Le tracker conserve désormais
ces observations dans son ensemble borné et les réévalue avec les confirmations
suivantes. Un test reprend les valeurs réellement observées ; les garde-fous
contre les contradictions, les longues zones non observées et la réutilisation
de répliques sont conservés.

Le deuxième essai a échoué après un rejet natif : le délai constant vieillissait
pendant une nouvelle attente de 30 s. La cadence permet maintenant cinq demandes
de confirmation rapprochées après le premier verrouillage et les deux reprises
natives bornées même lorsqu'un décalage est déjà actif. Les limites de matching
ne sont pas assouplies. **107 tests ciblés** passent.

Ces statistiques décrivent des positions de lecture corrélées après le premier
verrouillage, y compris les éventuelles zones inconnues à délai automatique nul.
Elles ne sont pas un p95 indépendant des débuts acoustiques des mots. L'absence
de dérive présente déjà un biais d'environ 638 ms face aux limites des fichiers.
Le probe vérifie le délai natif écrit et relu, mais pas le contrôleur Flutter,
l'interface, l'audio audible, la charge CPU stable ou les frames vidéo perdues.
L'acquisition initiale reste au-delà des 45 s demandées. Le ralentissement testé
ne suffit pas à valider les deux sens de dérive, les films ou Mentalist.
Les rapports `speech-*.json` conservent succès et échecs avec leurs SHA exacts.


Le sens inverse, `24000/25025`, à `8f2f7ac2`, acquiert la pente 0,958991
après 130,563 s. Il ne reste que 7 échantillons de suivi avant la fin du
probe de 138 s (minimum exigé : 10) : **le test échoue**. Les 633 ms p95 sur
ces quelques positions ne valident pas le suivi sur la durée. Le build macOS et
l'analyseur tournaient simultanément ; ce temps n'est pas un benchmark de
performance contrôlé. Rapport : `speech-drift-faster-8f2f7ac2.json`.

Le build macOS debug `8f2f7ac2` et sa signature stricte passent, avec **107 tests
ciblés** et l'analyse complète sans diagnostic. Copie et provenance dans
`build/livesync/review-builds/8f2f7ac2/`. Kernel Dart SHA-256 :
`fb63267c8de1fd4b64b123c308c99f8a5a18f82148df576952df5f2fea458981`.
La CI Windows `35056961286` et la CI upstream `35056963159` sont en cours.
Aucune conclusion de réussite n'est attribuée avant leur fin.


### Acquisition, horodatages partiels et outliers — `503d81b0`

Trois causes sont maintenant distinguées et corrigées :

1. **Horodatage natif invalide en fin de résultat.** Les diagnostics `2e550fd9`
   établissent que les rejets observés portent le statut 4 (temps de segment
   invalides), et non une erreur de décodage générique. Sur la fenêtre publique
   29,671–44,671 s, ce rejet supprimait trois segments corrects. `56f3e9ff`
   renvoie uniquement le préfixe précédant le premier segment invalide, avec
   statut 5 explicite. Dernier temps conservé : 44,551 s. Aucun timestamp n'est
   borné artificiellement ; un premier segment invalide reste rejeté. Le contexte
   ne raccorde pas une fenêtre suivante à la fin rejetée. Le layout ABI reste
   inchangé ; seuls les clients qui acceptent explicitement le statut 5 utilisent
   le texte partiel. Le test natif reproductible est
   `scripts/livesync/probe_valid_prefix.py`, sur le WAV de développement figé.
2. **Repère intérieur déjà réfuté.** La CI Windows `35056961286`, à `8f2f7ac2`,
   acquiert la calibration puis échoue à `manual-during`. Un outlier conservé
   dans la zone déjà validée s'associe à un second mauvais temps, et le tracker
   retire sa prédiction. Le test ajouté reproduit ce retrait avant correction.
   `ede025cf` écarte les repères rejetés à l'intérieur du domaine confirmé, tout
   en conservant les observations extérieures utiles à une future pente.
3. **Une substitution lexicale au troisième mot.** Les diagnostics d'indices
   `eaa672b2` montrent, pour les cues 1 et 3, des mots exacts aux positions
   0, 1, 3 et 4. `503d81b0` accepte ce cas borné si les cinq temps sont valides,
   monotones et rapprochés, avec les quatre mots exacts aux mêmes positions.
   Un début absent, un déplacement, deux substitutions, une répétition du début
   ou des temps invalides restent rejetés. Le chemin des trois mots exacts et
   les seuils globaux du passage sont conservés. L'identité de déduplication
   vient des trois premiers mots du SRT, quel que soit le chemin utilisé.

Sur le chapitre aligné, le probe natif `503d81b0` acquiert en **21,607 s**, avec
un offset de +0,6745 s face aux limites de fichiers, contre environ 70 s dans les
essais précédents. Deux analyses sont terminées, dont un préfixe valide. Cette
observation satisfait le délai de 45 s sur cette fixture ; ce n'est pas une
statistique indépendante ni une preuve de précision acoustique. Le biais des
limites de fichiers subsiste. Le préfixe seul n'avait pas amélioré l'acquisition
(69,547 s, aucun résultat partiel rencontré dans cet essai).

**111 tests ciblés**, analyse complète, format natif et tests CPU natifs passent.
Build macOS debug `503d81b0` et signature stricte vérifiés ; copie et provenance :
`build/livesync/review-builds/503d81b0/`. Kernel Dart SHA-256 :
`204a32ab20ae0b67912b251d1615f47e7d3a04cbca6d7f181d9f09db60948a69`.

La CI générale `35056963159` (`8f2f7ac2`) passe après relance du seul job macOS,
initialement arrêté par un dépôt SPM Sentry absent du cache du runner. Ce succès
ne valide pas les derniers changements. Les nouvelles CI Windows `35058910946`
et générale `35058912671` concernent `503d81b0`. La CI Windows intermédiaire
`35058268463` concerne `30b73ce9`, avant le correctif d'outlier intérieur.

Les régressions longues de dérive et de musique sont lancées séparément, sur le
même hôte et en parallèle du build. Elles serviront à vérifier le comportement,
pas à mesurer une latence ou une charge CPU dans des conditions contrôlées.


Résultats longs à `503d81b0` : le négatif 650–888 s passe sans verrouillage en
238,067 s (cinq analyses terminées, six rejets). **La dérive régresse** : premier
verrouillage à 21,656 s, aucune pente apprise, p95 4,770 s et maximum 6,124 s
après expiration de la prédiction. Les cinq confirmations sont consommées avant
les cues nécessaires ; la cadence espacée manque ensuite ces débuts de réplique.
Ces deux rapports sont conservés. Le gain d'acquisition ne valide donc pas ce
build pour le suivi de dérive. `574ef060` conserve jusqu'à dix confirmations
rapides, toujours bornées et interrompues dès que la carte est établie ; son
nouvel essai natif retrouve une pente à 93,625 s, après acquisition initiale
à 21,506 s. Il échoue néanmoins : p95 2,490 s, maximum 2,743 s pendant la
phase où la correction reste constante. Rapport `speech-drift-slower-574ef060.json`. Le garde-fou des six ancres sur une minute et
les critères d'erreur ne sont pas réduits pour faire passer l'essai.


Le build macOS `574ef060` et sa signature stricte passent également, avec
111 tests ciblés et l'analyse complète sans diagnostic. Il est conservé dans
`build/livesync/review-builds/574ef060/` ; kernel Dart SHA-256
`f585fef25fa0603f640734bf3fdca43d2120efdbc1b8e4fa1e0a8d0dfbcd3e4c`. La précision durant l'apprentissage
de la dérive reste un échec explicite, et le lecteur Mentalist n'est pas validé.

Upstream refetché à `2026-09-16T05:29:56Z` : toujours
`e38759127a1fb26c4cd99172ba6609fd50e355d9`, aucun commit supplémentaire.
Cette actualité du code de base ne constitue pas une validation finale LiveSync.
