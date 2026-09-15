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
| Contrôles upstream de référence | En préparation | SDK à installer |
| PCM natif macOS avec PTS | À réaliser | API effective à établir |
| PCM natif Windows avec PTS | À réaliser | CI et matériel interactif à identifier |
| Lecture et correction visible réversible | À réaliser | App de test isolée nécessaire |
| Inférence réelle base.en / quantifiée | À réaliser | Modèles et backends à évaluer |
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
