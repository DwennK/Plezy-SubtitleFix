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
