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
