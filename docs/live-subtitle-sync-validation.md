# Plezy + LiveSync — preuves et validation

## Statut

Travail en cours, aucune livraison fonctionnelle. Les validations manquantes
restent explicitement non réalisées, y compris sur Windows et dans l'UI native.

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
