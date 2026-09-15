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

## Matrice de preuves

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
