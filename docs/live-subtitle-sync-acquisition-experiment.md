# Acquisition avant application d'une dérive — expérience non livrée

Branche `codex/livesync-onset-evidence`, source native testée `dcfe7e34`.
Les options restent désactivées dans le contrôleur applicatif. Cette expérience
ne constitue pas une correction installée de Mentalist ni une validation globale.

## Motif et rejeu préalable

Le calcul actuel peut appliquer une constante après deux cues rapprochées, puis
attendre six cues sur une minute avant de suivre leur dérive. Sur les deux essais
précédents, le décalage reste alors erroné pendant l'acquisition de la pente.

Un rejeu des vraies classes Dart, à partir des arrivées et positions enregistrées,
reproduit exactement toutes les corrections des deux lectures `bbcee30d` (écart
maximal **zéro**). Les seuls changements explorés sont les critères de pente
(trois cues, quinze secondes dans les deux timelines, paires distantes de huit
secondes) et l'attente de trois cues espacées avant la première correction.
Rapport : `livesync-evidence/early-acquisition-exact-replay.json`.

Cette attente donne une acquisition simulée vers 33,5–33,6 s. Après acquisition,
p95 simulé 587 ms / 725 ms ; en conservant aussi les positions auparavant corrigées
mais désormais inconnues, p95 1,118 s / 1,209 s. Les positions avant la toute
première acquisition des anciens rapports n'existent pas : ce rejeu ne prouve
pas la précision depuis l'activation. Il ne reproduit pas non plus le changement
de cadence des inférences. Il ne suffit donc pas à retenir la politique.

## Implémentation expérimentale

- `--experimental-early-acquisition true` active le candidat dans le probe seul.
- La première correction exige trois cues distinctes et quinze secondes dans
  les deux timelines. La pente garde la régression médiane et ses résidus/inliers.
- Au moins deux lots d'observations doivent apporter de nouvelles cues valides.
  Revoir ou affiner la même cue ne lui attribue pas un nouveau lot ; une preuve
  invalide ne peut pas compter comme son observation antérieure.
- La provenance temporaire est bornée à 256 cues et effacée aux ruptures.
- Le cache, les réglages de l'app et les seuils de production restent inchangés.
- **149 tests** passent et l'analyse Flutter complète est sans diagnostic.

Les seuils sont des hypothèses de développement, pas des probabilités calibrées.
L'incertitude d'une extrapolation après seulement trois cues, les faux changements
de pente et les autres éditions restent à éprouver indépendamment.

## Mesure native

Le probe conserve désormais chaque position échantillonnée depuis l'activation,
y compris celles sans correction. Il expose séparément le temps d'acquisition,
le nombre de positions inconnues, puis l'erreur après la première correction
réellement appliquée (les pertes de mapping ultérieures restent dans cette erreur).
La limite d'acquisition est explicitement **45 secondes**, le p95 **750 ms**.
L'erreur médiane visée **250 ms** reste une exigence distincte non validée par
le simple champ `passed` du probe, qui couvre acquisition/p95/pente.

### Premières lectures réelles à `dcfe7e34`

| Cas de développement | Première correction / pente | P95 après acquisition | Médiane | Positions initiales inconnues |
| --- | --- | --- | --- | --- |
| Ralenti 25/23,976 | 33,604 s | 573 ms | 339 ms | 33 sur 146 échantillons |
| Accéléré 23,976/25 | 34,489 s | 732 ms | 720 ms | 34 sur 134 échantillons |

Les deux lectures respectent acquisition ≤45 s et p95 <750 ms. **Aucune ne valide
la médiane <250 ms**. Les rapports `early-acquisition-{slower,faster}-dcfe7e34.json`
conservent les mesures depuis l'activation et portent `overallPrecisionValidated:
false`. Aucun préfixe ni rejet natif dans ces deux essais ; six et sept analyses.

Le cas ralenti récupère aussi la cue acoustique à 35,011 s. Le cas accéléré ne la
récupère pas, mais attend suffisamment de dialogue avant de choisir sa première
correction. La cadence change réellement les fenêtres par rapport au rejeu ; les
mesures ci-dessus proviennent de nouvelles lectures, pas de celui-ci.

La référence reste la transformation des bornes d'énoncés LibriSpeech, avec leurs
silences de début ; ce ne sont pas des annotations précises de la parole. Aucun
offset de référence n'a été modifié pour réduire l'erreur. La marge de 18 ms sur
le p95 accéléré est trop faible pour conclure à une précision généralisable.

### Cas déjà aligné

Nouvelle lecture de 144 secondes : acquisition **33,693 s**, p95 **661 ms**,
médiane **656 ms**, huit analyses dont trois préfixes valides et aucun rejet
natif. Toutes les régions conservent une pente de **1**, donc aucune dérive
n'est inventée. Cependant, une correction +0,646 à +0,661 s est appliquée à
la référence déjà alignée. **L'absence de dégradation n'est pas démontrée.**
Rapport `early-acquisition-aligned-dcfe7e34.json`, également marqué
`overallPrecisionValidated: false`.

Décision à ce stade : conserver les deux options désactivées dans l'app. Les
lectures valident une amélioration du délai d'estimation de la dérive sur ce
chapitre de développement, mais pas la précision médiane, la non-dégradation,
le corpus indépendant ni le comportement réel sur Mentalist. Un essai négatif
natif sur Sintel 650–888 s est lancé avec le même SHA ; son résultat n'est pas
encore attribué à cette étape.

### Essai négatif et nouvelle région

Le probe `dcfe7e34` sur Sintel 650–888 s termine après **238,054 s**, sans aucune
correction. Six analyses complètes, cinq sorties rejetées (`invalidOutput`) :
aucun faux verrouillage sur ce passage déjà utilisé dans le développement.
Rapport `early-acquisition-negative-dcfe7e34.json`. Des tests Dart ont tourné
pendant une partie de la lecture ; ce n'est pas une mesure de performance.

`8699a49e` corrige ensuite un défaut de l'option expérimentale : une région
anciennement apprise autorisait une nouvelle région inconnue à contourner le
seuil d'acquisition. Le contrôle porte maintenant sur le domaine des ancres,
aussi après restauration d'un cache. La régression échoue avant et passe après ;
**150 tests LiveSync** passent et l'analyse Flutter est sans diagnostic. Les
lectures précédentes ne sont pas réattribuées à ce nouveau SHA.

### Premier corpus de film indépendant

Les sources et la partition 0–180 s d'Elephants Dream sont figées dans
`test/fixtures/livesync/elephants-dream-validation.json` avant la première
inférence, au commit `bb66513c`. Les seuils restent ceux de `8699a49e` ; les
partitions 180–360 s et 360–540 s sont réservées et non analysées.

Le fichier média choisi est celui auquel la piste TimedText est attachée :
[Commons, fichier original](https://commons.wikimedia.org/wiki/File:Elephants_Dream.ogv)
et [sous-titres anglais à la révision 1204466026](https://commons.wikimedia.org/w/index.php?title=TimedText:Elephants_Dream.ogv.en.srt&oldid=1204466026).
Le SHA-1 publié du média et les SHA-256 des deux sources sont vérifiés. Les
licences et attributions sont conservées séparément (média CC BY-SA 2.5,
texte Commons CC BY-SA 4.0). Le générateur extrait seulement les 180 secondes
prévues en PCM mono 16 kHz et copie les octets SRT sans correction de timing.
Ce SRT reste une référence d'affichage publiée, pas une annotation acoustique
mot à mot. Aucun décalage attendu n'est ajusté à partir des inférences.

#### Résultat indépendant : échec d’acquisition

Le premier essai natif `bb66513c` termine après **179,016 s sans correction**.
Neuf analyses complètes, aucun rejet natif, 174 positions toutes inconnues.
Une seule cue fournit des ancres : −1,935 s puis +0,161 s lors d’une autre
fenêtre. Cette variation de 2,096 s interdit de considérer la seule similarité
textuelle comme une preuve de précision. Le champ historique `acquisitionMs`
du probe est ici le temps écoulé, pas une acquisition réelle. Les erreurs nulles
avant verrouillage ne valident rien sur ce fichier déjà aligné.

Rapport : `elephants-dream-initial-bb66513c.json`. **Aucune précision ni
non-dégradation validée.** La partition 0–180 s est désormais consommée ; toute
modification et réévaluation qui s’y appuie relève du développement. Les deux
partitions réservées restent non analysées. Les limites de matching/timing
restent à diagnostiquer avant de généraliser les améliorations LibriSpeech.

### Diagnostic du même extrait après consommation

`7dcc840d`, modèle **base.en non quantifié**, options expérimentales actives :
179,002 s, neuf analyses, aucun recalage. Le remplacement du modèle quantifié
ne résout pas cet échec. Il produit une première ancre −1,943 s et une ancre
distante −0,137 s, insuffisantes pour confirmer le domaine.

`980cbf24` ajoute uniquement des diagnostics numériques des tokens. Une lecture
de 59 s avec q5 montre un premier point DTW à 16,183 s pour la cue 18,130 s,
puis le mot suivant à 18,403 s. Une autre fenêtre place le début à 18,299 s.
Ces points d’alignement ne sont pas des durées acoustiques de mots ; la confiance
textuelle ne garantit pas leur précision. Aucune transcription n’est conservée.

`0c9df1d1` corrige les verdicts du probe : médiane <250 ms désormais requise
en plus du p95 ; acquisition absente explicitement `none`, et budget de latence
aussi appliqué aux contrôles positifs constants. Quatre tests de ces verdicts
passent. Les résultats historiques restent conservés avec leurs limites.

`1a02e229` corrige le rejet systématique des fenêtres de plus de huit segments.
Le moteur énumère tous les groupes contigus d’au plus trois segments, élimine
ceux qui ne peuvent satisfaire les conditions nécessaires du matcher, puis
conserve un plafond de **21 recherches**. Si plus de 21 groupes sont viables,
il reste sans résultat ; il ne tronque pas les concurrents. Seuils de similarité,
ambiguïté, précision et estimation inchangés. Régression rouge avant correction,
**156 tests** après, analyse Flutter sans diagnostic. Le nouvel essai natif
utilise les options expérimentales **désactivées**, comme l’app actuelle.

#### Politique applicative actuelle sur le passage consommé

`1a02e229`, q5, options expérimentales désactivées : première correction en
**33,671 s**, médiane **19 ms**, p95 **94 ms**, offset final +0,019 s sur 179 s.
Le nouveau verdict complet passe. L’acquisition utilise deux cues distinctes
aux offsets +0,169 s et +0,019 s ; le point initial erroné −1,939 s est affiné
avant application. Le premier événement est un rejet natif ; voir rapport brut.

Ce résultat n’isole pas l’effet du nouveau budget de groupes : les fenêtres
qui acquièrent ont au plus huit segments, et la politique d’acquisition a aussi
changé depuis le premier essai. Il montre surtout que l’attente expérimentale
de trois cues sur quinze secondes peut empêcher l’acquisition sur ce film.
Les seuils expérimentaux restent donc désactivés. La prochaine évaluation
porte sur la partition réservée 180–360 s, figée avant toute inférence avec
les réglages applicatifs et un offset attendu de −180 s (SRT inchangé).

#### Partition réservée 180–360 s : acquisition réussie, médiane en échec

Premier essai `8f99fc0a` : acquisition **21,604 s**, médiane et p95 **341 ms**,
offset final **−179,659 s** face au −180 s attendu. Trois cues distinctes
fournissent −179,659 / −179,759 / −179,623 s. Le délai d’acquisition et le p95
respectent les budgets ; **la médiane <250 ms échoue**. Le verdict du probe est
bien négatif. Rapport `elephants-dream-reserved-8f99fc0a.json`. La référence
reste le SRT publié, dont les débuts ne sont pas des annotations acoustiques
mot à mot. Aucun offset attendu ni seuil n’est ajusté à partir du résultat.

La partition 180–360 s est maintenant consommée. **360–540 s reste non analysée**.
Le correctif borné de matching est porté sans options expérimentales au commit
de production `5bddabd0` : 137 tests LiveSync et analyse complète passent.
Il ne constitue pas une résolution vérifiée de Mentalist, de la dérive ou des
exigences de précision générales. La validation complète du candidat upstream
est relancée par le run parent `35097858231` sur cette base maintenue.

### Régression native de la correction portée en production

Le probe lancé depuis la branche maintenue exacte `5bddabd0` termine le passage
Sintel négatif 650–888 s en **238,094 s sans correction** : huit analyses
complètes, quatre rejets. Aucun faux verrouillage observé sur ce passage de
développement déjà consommé. Rapport `production-bounded-groups-negative-5bddabd0.json`.
Cette vérification n’établit ni la précision générale ni une validation UI.

La chaîne upstream complète `35097858231` prépare `10ace9fc` à partir de
`5bddabd0` et de l’upstream `7883cf8c`, vérifié de nouveau ce jour par fetch.
Dart `35097914160` réussit ; natif Windows `35097915052` et macOS `35097912981`
restent en cours. Aucun run relancé pendant son exécution. Les branches maintenue
et candidate restent figées pendant cette validation. Le build Mac historique
`fe4fc52c` est téléchargé localement et sa signature strict/deep vérifiée, mais
il ne contient pas la correction `5bddabd0`, n’est pas lancé ni installé.
