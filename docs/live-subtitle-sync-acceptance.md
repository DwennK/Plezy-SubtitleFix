# Plezy + LiveSync — acceptation actuelle

**Objectif complet non atteint.** Aucun critère n'est réduit au périmètre des
probes qui passent. Cette synthèse suit les 14 sections de la demande initiale.
Les limites ne sont pas des validations. Les preuves historiques gardent leur SHA.

## Code et artefacts de référence

- Upstream intégré : `7883cf8c88d31e9b81e574c6949031a1c46de0b4`.
- Code construit/testé : `10ace9fc6d93c59a2f577e1d2a2d9e7245087f52`.
- Promotion : `4d06568f8d633c606d498804ccd0bbeab9fa99bc`, arbre identique.
- [Chaîne complète, PR #1, promotion et no-op](livesync-evidence/upstream-10ace9fc-full-workflow.json).
- [Archives brouillon vérifiées](livesync-evidence/draft-test-artifacts-10ace9fc.json).
- [Manifestes et outils](live-subtitle-sync-versions.json).

## Matrice

| Demande | État démontré | Travail ou preuve encore nécessaire |
|---|---|---|
| 1. Dernier upstream et versions | Intégration complète, cinq workflows réussis sur le même SHA ; locks et natifs épinglés | Répéter la vérification upstream avant la livraison finale et tester le code finalement livré |
| 2. Synchronisation locale anglais/SRT, Windows x64 et Mac arm64 | Code local, plateformes ciblées, transport des sidecars et extraction complète du SRT Plex ; acquisitions dans des probes et le contrôleur Windows | Mentalist dans le lecteur utilisateur ; parcours serveur/UI complets et limites des architectures optionnelles |
| 3. Faisabilité native et petite surface d'intégration | PCM actif horodaté, worker, SRT complet, rendu réversible et builds documentés sur les deux plateformes | Revalider l'ensemble sur les derniers correctifs combinés, sans attribuer d'anciens résultats au nouveau code |
| 4. Capture et horloges | Ring borné, mono 16 kHz, générations et contrats de pause/seek/vitesse ; capture dans mpv | Comparaison de lecture audible et charge réelle ; parcours applicatifs d'échec/passthrough complets |
| 5. Whisper, identification et alignement | Versions/modèles figés, matching conservateur et ancres ; segmentation ASR bornée corrigée | Précision des repères, corpus indépendant et absence de dégradation encore non établis |
| 6. Suivi léger et stabilité | VAD heuristique, cadence adaptative et confirmations indépendantes implémentés | Calibrage musique/parole/confiance ; stabilité et coût sur des épisodes réels |
| 7. Dérive et scènes différentes | Segments/domaines, fits affines et navigation connue/inconnue présents ; des essais de dérive échouent encore | Détection automatique des gaps, scènes supprimées, cues aux frontières, dérive réelle et retour arrière après apprentissage complet |
| 8. Corrections et UX | Composition manuel/automatique/audio et arrêt vérifiés dans le contrôleur Windows ; états et contrôles intégrés | UX native courante sur Mac, Mentalist audible/visible ; rendu des frontières appris automatiquement |
| 9. Cache, modèles, confidentialité | Cache borné/atomique avec identité forte, vérification SHA du modèle, suppression et tests d'annulation ; aucun transcript/PCM privé conservé par défaut | Validation native des paramètres et de la persistance entre processus ; revue des derniers chemins d'erreur |
| 10. Performances et backends | Comparaisons CPU et explorations Metal historiques ; fallback CPU contrôlé | Budgets CPU/GPU/mémoire/latence/frames/audio respectés sur machines de référence ; évaluation Vulkan Windows et stratégie finale |
| 11. Tests et preuves | CI upstream complète et nombreux tests natifs/domaines ; acquisition, intro-90, seeks, délais et cache passent sur calibration Windows | Tous les scénarios de la demande, précision médiane/percentiles sur validation indépendante, faux sauts et absence de dégradation |
| 12. Git, distribution et suivi quotidien | Branches séparées, miroir main, workflow quotidien exercé, conflits conservés, PR/promotions/no-op et release brouillon | Installation, lancement/désinstallation, coexistence et choix de signature/notarisation vérifiés sur les plateformes livrées |
| 13. Exécution jusqu'au bout | Plan, implémentation, preuves et poursuite des échecs conservés | Continuer les étapes E–J qui restent incomplètes ; un build n'est pas le produit final |
| 14. Fin et compte rendu | Aucun état « terminé » annoncé | Prouver chaque critère précédent sur l'état finalement livré avant clôture |

## Correctifs isolés en validation

- **Présentation d'un gap déjà confirmé**, `c205484a` : [13 états Windows,
  cinq captures inspectées et contrôleur](livesync-evidence/scene-c205484a-windows.json).
  Cela ne détecte pas automatiquement un ajout/suppression de scène.
- **Capture pendant le chargement complet du SRT**, `41dba5c5` : 146 tests
  locaux et analyse passent ; [run Windows `35101753081` réussi](livesync-evidence/startup-41dba5c5-windows.json)
  avec source retardée de 15 s, PCM effectivement accumulé avant le texte,
  acquisition en 23,373 s et erreur de calibration 182,7 ms. Le coût d'extraction
  Plex lui-même demeure.
- **Candidat combiné**, `114301c0` : 153 tests locaux et analyse passent ;
  run `35103325258` vérifie un seek réel au milieu de l'initialisation. Il s'agit
  d'une investigation de concurrence, pas d'un correctif déjà prouvé.

## Point utilisateur prioritaire

Le transport Plex du SRT de Mentalist a historiquement pris 80,404 s. Une autre
analyse PCM a proposé +3,749 s, sans référence annotée ni validation visible et
audible dans le lecteur. **Ni cette estimation ni les acquisitions Sintel ne
prouvent que l'épisode utilisateur est correctement synchronisé.** Les nouveaux
correctifs n'ont pas été installés sur son Mac durant ces vérifications.
