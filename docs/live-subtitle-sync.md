# Plezy + LiveSync — plan et décisions

## Contrat de livraison

Synchronisation locale, pendant la lecture, de l'audio anglais avec le texte
original de SRT accessibles intégralement. Cibles obligatoires : Windows x64 et
macOS Apple Silicon. Aucun microphone, mixage système, service de transcription,
second flux réseau du média ou analyse préalable intégrale. Sources inchangées.
Le fork et ses artefacts de test peuvent être poussés ; les releases restent en
brouillon. Aucun changement ni PR au dépôt officiel.

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
- Le client public libmpv expose un renderer vidéo et des callbacks de flux
  d'entrée ; l'existence d'un callback PCM de sortie reste à vérifier dans la
  révision effective. Étudier un filtre de prélèvement isolé si nécessaire.

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

Plan enregistré avant implémentation. Phase A en cours. Aucun fonctionnement
LiveSync livré ou validé à ce stade. Voir le journal de validation et le manifeste.
