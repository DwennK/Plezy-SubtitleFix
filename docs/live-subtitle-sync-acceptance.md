# Plezy + LiveSync — acceptation actuelle

**Objectif complet non atteint.** Aucun critère n'est réduit au périmètre des
probes qui passent. Cette synthèse suit les 14 sections de la demande initiale.
Les limites ne sont pas des validations. Les preuves historiques gardent leur SHA.

## Code et artefacts de référence

- Upstream intégré : `7883cf8c88d31e9b81e574c6949031a1c46de0b4`.
- Code courant construit/testé : `0d2482fb6dcc00b5411e20ec382b88b2466de70f` (Release).
- Promotion : `6ea456cd4a0486a05defec7d4c876fc1a26ae633`, code identique ; seuls des documents de preuve supplémentaires diffèrent.
- Base d’intégration upstream validée : `10ace9fc6d93c59a2f577e1d2a2d9e7245087f52`.
- [Chaîne complète, PR #1, promotion et no-op](livesync-evidence/upstream-10ace9fc-full-workflow.json).
- [Archives Release brouillon courantes vérifiées](livesync-evidence/draft-test-artifacts-0d2482fb.json), pour `0d2482fb`, cache v2 inclus.
- [Archives historiques de la base upstream](livesync-evidence/draft-test-artifacts-10ace9fc.json).
- [Manifestes et outils](live-subtitle-sync-versions.json).

## Matrice

| Demande | État démontré | Travail ou preuve encore nécessaire |
|---|---|---|
| 1. Dernier upstream et versions | Intégration complète, cinq workflows réussis sur le même SHA ; locks et natifs épinglés | Répéter la vérification upstream avant la livraison finale et tester le code finalement livré |
| 2. Synchronisation locale anglais/SRT, Windows x64 et Mac arm64 | Code local, plateformes ciblées, transport des sidecars et extraction complète du SRT Plex ; acquisitions dans des probes, le contrôleur Windows et le candidat Mac `4da5ba32` | Mentalist dans le lecteur utilisateur ; parcours serveur/UI complets et limites des architectures optionnelles |
| 3. Faisabilité native et petite surface d'intégration | PCM actif horodaté, worker, SRT complet, rendu réversible et builds documentés sur les deux plateformes | Revalider l'ensemble sur les derniers correctifs combinés, sans attribuer d'anciens résultats au nouveau code |
| 4. Capture et horloges | Ring borné, mono 16 kHz, générations et contrats de pause/seek/vitesse ; capture dans mpv | Comparaison de lecture audible et charge réelle ; parcours applicatifs d'échec/passthrough complets |
| 5. Whisper, identification et alignement | Versions/modèles figés, matching conservateur et ancres ; segmentation ASR bornée corrigée | Précision des repères, corpus indépendant et absence de dégradation encore non établis |
| 6. Suivi léger et stabilité | VAD heuristique, cadence adaptative et confirmations indépendantes implémentés | Calibrage musique/parole/confiance ; stabilité et coût sur des épisodes réels |
| 7. Dérive et scènes différentes | Segments/domaines, fits affines et navigation connue/inconnue présents ; des essais de dérive échouent encore | Détection automatique des gaps, scènes supprimées, cues aux frontières, dérive réelle et retour arrière après apprentissage complet |
| 8. Corrections et UX | Composition manuel/automatique/audio et arrêt vérifiés dans les contrôleurs Windows et candidat Mac `4da5ba32` ; états et contrôles intégrés | UX native courante sur Mac, Mentalist audible/visible ; rendu des frontières appris automatiquement |
| 9. Cache, modèles, confidentialité | Cache borné/atomique avec identité forte, vérification SHA du modèle, suppression et tests d'annulation ; aucun transcript/PCM privé conservé par défaut | Validation native des paramètres et de la persistance entre processus ; revue des derniers chemins d'erreur |
| 10. Performances et backends | Comparaisons CPU et explorations Metal historiques ; fallback CPU contrôlé | Budgets CPU/GPU/mémoire/latence/frames/audio respectés sur machines de référence ; évaluation Vulkan Windows et stratégie finale |
| 11. Tests et preuves | CI upstream complète et nombreux tests natifs/domaines ; acquisition, intro-90, seeks, délais et cache passent sur calibration Windows | Tous les scénarios de la demande, précision médiane/percentiles sur validation indépendante, faux sauts et absence de dégradation |
| 12. Git, distribution et suivi quotidien | Branches séparées, miroir main, workflow quotidien exercé, conflits conservés, PR/promotions/no-op et release brouillon | Installation, lancement/désinstallation, coexistence et choix de signature/notarisation vérifiés sur les plateformes livrées |
| 13. Exécution jusqu'au bout | Plan, implémentation, preuves et poursuite des échecs conservés | Continuer les étapes E–J qui restent incomplètes ; un build n'est pas le produit final |
| 14. Fin et compte rendu | Aucun état « terminé » annoncé | Prouver chaque critère précédent sur l'état finalement livré avant clôture |

## Correctifs et portée des preuves

- **Présentation d'un gap déjà confirmé**, `c205484a` : [13 états Windows,
  cinq captures inspectées et contrôleur](livesync-evidence/scene-c205484a-windows.json).
  Cela ne détecte pas automatiquement un ajout/suppression de scène.
- **Capture pendant le chargement complet du SRT**, `41dba5c5` : 146 tests
  locaux et analyse passent ; [run Windows `35101753081` réussi](livesync-evidence/startup-41dba5c5-windows.json)
  avec source retardée de 15 s, PCM effectivement accumulé avant le texte,
  acquisition en 23,373 s et erreur de calibration 182,7 ms. Le coût d'extraction
  Plex lui-même demeure.
- **Candidat combiné**, `114301c0` : 153 tests locaux et analyse passent ;
  run `35103325258` échoue après un seek pendant l'initialisation, sans analyse.
  Le correctif `a5838cbe` acquiert ensuite le décalage et passe les contrôles de
  seek, délai manuel/audio, cache et arrêt dans le run Windows `35104648989`.
  [Comparaison native et build Mac](livesync-evidence/startup-seek-a5838cbe-comparison.json).
  L'acquisition de calibration prend **52,022 s**, au-delà du budget initial de
  **45 s** ; l'intro-90 prend 125,266 s. Les quatre workflows du candidat
  passent ; la PR interne nº 2 est intégrée dans `893b247f`.
- **Revalidation des gaps en cache**, `ccde2f31` : trois régressions reproduites,
  puis sept nouveaux cas et les contrôles existants passent ; analyse locale et
  CI Dart `35106046085` réussissent. Cette branche séparée n'est pas dans le
  build `a5838cbe` et n'ajoute pas la détection automatique des gaps.
  La suite `be6f431d` versionne également le cache en v2 ; 160 tests locaux,
  analyse et CI Dart `35108485431` passent. Le candidat `f04d8e29` ajoute un essai
  natif de cache volontairement erroné : 162 tests locaux passent ainsi que les
  quatre workflows. Windows `35109362139` confirme chargement, masquage puis
  récupération réelle et correction du cache ; macOS `35109400288` passe ses
  14 contrats natifs. Acquisition 20,946 s / 122,224 s, erreurs de calibration
  198,7 / 227,6 ms. [Preuve et limites](livesync-evidence/cache-recovery-f04d8e29-windows.json).
  PR nº 3 intégrée dans `7a68ca09` ; cela ne valide pas Mentalist.
- **Mesure de l'acquisition**, `902d7701` : le probe conserve maintenant les
  instants des demandes/résultats, le coût natif et le coût du matching, sans
  dialogue ni PCM. [Run Windows `35108145786` réussi](livesync-evidence/acquisition-trace-902d7701-windows.json) :
  acquisition 37,647 s avec deux inférences de 6,32 et 6,71 s ; matching de
  37 et 57 ms. L'ancien échec à 52,022 s demeure, sans trace permettant de le
  décomposer. Ce nouvel essai ne prouve pas une accélération.
- **Validation Release**, `7267abfc` : même scénario, modèle et seuils ; mode de
  compilation et archives identifiés séparément. [Run Windows `35110773889` réussi](livesync-evidence/release-7267abfc-windows.json) :
  acquisition 26,826 s / 121,450 s ; erreur face au SRT 214 / 239,6 ms.
  Capture prête à 2,284 s sur la calibration, inférences 3,72 et 4,21 s,
  matching 3 et 2 ms. Comparaison de runners distincts, sans preuve causale
  d’accélération ni validation générale des budgets. Ce source ne contient
  pas le cache v2 ni la protection ultérieure après soumission native.

## Point utilisateur prioritaire

Le transport Plex du SRT de Mentalist a historiquement pris 80,404 s. Une autre
analyse PCM a proposé +3,749 s, sans référence annotée ni validation visible et
audible dans le lecteur. **Ni cette estimation ni les acquisitions Sintel ne
prouvent que l'épisode utilisateur est correctement synchronisé.** Les nouveaux
correctifs n'ont pas été installés sur son Mac durant ces vérifications.

## Candidat Release combiné

`0d2482fb` regroupe le code maintenu du cache v2, une protection contre les
accusés de soumission arrivant après un seek, et les builds Release Windows/Mac.
La protection a passé 162 tests locaux et l’analyse sur le code cache combiné ;
la course elle-même n’a pas été reproduite dans un probe natif. Le bundle Mac
ordinaire est archivé avant qu’XCTest active la testabilité de son hôte Release.
La CI Dart, la CI générale et le [build Mac Release avec 14 contrats](livesync-evidence/release-0d2482fb-macos.json)
passent. Le contrôleur Windows Release passe également : 35,037 / 125,158 s,
erreurs face au SRT 231,6 / 245 ms, récupération du mauvais cache et contrôles
usuels réussis. [Preuve combinée](livesync-evidence/release-0d2482fb-comparison.json).
La PR nº 4 est intégrée dans `6ea456cd`, code identique au candidat testé.

## Scènes ajoutées/supprimées : référence native en échec

La [PR nº 5](https://github.com/DwennK/Plezy-SubtitleFix/pull/5) conserve trois
fixtures réelles à coupures connues et leurs premières inférences au SHA
`f3621f5c`. Le SRT complet reste identique ; le moteur ne reçoit pas l’oracle.
Les trois cas apprennent deux régions mais aucun gap. Après ajout de 30 s,
la récupération prend 29,634 s et le p95 de suivi vaut 30,210 s. Après suppression
de 13 s : 11,575 s et p95 12,780 s. Le cas coupant une cue échoue également.
Ces premiers essais utilisent l’ancienne bibliothèque locale c734. Une deuxième
série au SHA `6ff7ae18`, après reconstruction locale du natif épinglé courant,
confirme les trois échecs : aucun gap, p95 de 30,205 / 12,795 / 30,210 s.
La capture PCM et le resampler passent leurs contrats natifs ; cela ne valide
ni le bundle CI exact, ni l’UI, ni l’audio audible. La PR nº 5 est intégrée dans
`440ba749` : [preuves et limites](livesync-evidence/scene-edit-fixtures.md).
Détection des coupures et rendu des cues traversantes restent requis.

La [PR nº 6](https://github.com/DwennK/Plezy-SubtitleFix/pull/6), encore séparée,
retire une extrapolation lorsque deux répliques indépendantes contredisent
l’ancien mapping sans permettre un nouveau fit. Elle ne détecte aucun gap et
ne constitue pas une correction complète des scènes différentes. Le build
brouillon `0d2482fb` ne contient pas ce candidat.

## Candidat : première chaîne complète dans le contrôleur Mac

Le [run Mac Release `35149938639`](https://github.com/DwennK/Plezy-SubtitleFix/actions/runs/35149938639)
passe au source `4da5ba32a6da94a572f882d1d252934dabdfc5ee`, dont le code produit
est celui de `e85fd4bd` (PR nº 6 encore séparée). Les 14 contrats natifs et le
contrôleur réel avec PCM/Whisper passent : acquisition de calibration en 24,533 s,
intro-90 en 118,245 s, erreurs face au SRT de 219 et 226 ms. Mauvais cache,
seeks, délais manuel/audio, persistance et arrêt sont vérifiés.
[Rapports complets](livesync-evidence/macos-controller-4da5ba32.json).

Ce résultat provient d'un point d'entrée de test dans l'application Flutter
native, avec sortie audio nulle, sans inspection visuelle. Il ne prouve pas
Mentalist, la lecture audible, la précision indépendante ou les scènes complètes.
Le run Mac précédent `35148927428` échoue sur une course d'activation dans un
contrat ; la correction du test est en validation séparée dans la PR nº 7.
Le run Windows `35148901282` échoue par arrêt du renderer avant son premier état ;
la PR nº 8 ajoute son diagnostic et conserve le contrôle de synchronisation
indépendant. Aucun de ces candidats n'est présenté comme un nouveau build validé
sur les deux plateformes ; les archives brouillon `0d2482fb` restent distinctes.


## Contrôle utilisateur et derniers candidats — 16 septembre, 21:50 UTC

Le bundle maintenu `0d2482fb` est installé dans `/Applications/PlezyLiveSync.app`.
Son inventaire correspond à l’archive vérifiée ; Plezy officiel est intact.
L’accueil, la lecture vidéo de Mentalist S2 E16 et le SRT anglais sélectionné
ont été inspectés par Computer Use. **LiveSync refuse cependant l’activation** :
« Unsupported — Select an accessible SRT subtitle track. »
[Installation et constat UI](livesync-evidence/macos-install-0d2482fb.json).
Une extraction séparée par le chargeur de production réussit en 48,983 s,
57 067 octets en RAM ; aucune donnée audio ni dialogue n’est enregistrée.
Le branchement Plex est installé avant `PlayerNative.open`, puis effacé par cet
open. Le correctif est isolé dans `codex/livesync-source-lifecycle` ; la preuve
native du recalage utilisateur reste à obtenir.

Les candidats de contrôleur distincts passent désormais :
[Mac `18c16d19`](livesync-evidence/macos-controller-18c16d19.json),
24,023 s / 117,127 s avec intro-90, et
[Windows `b31d9b2e`](livesync-evidence/windows-controller-b31d9b2e.json),
21,682 s / 125,371 s. Erreurs face au SRT de calibration : respectivement
199,7 / 223,6 ms et 189,3 / 227,7 ms. Mac passe ses 14 contrats natifs.
Le crash Windows précédent ne se reproduit pas ; sa cause reste inconnue.
Ces résultats n’établissent ni la précision indépendante ni les budgets de
performance (les inférences Windows observées dépassent 3 s), et ne résolvent
pas le refus Plex dans l’application installée.
