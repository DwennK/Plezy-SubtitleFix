# Expérience : débuts de voix comme preuve complémentaire

Branche `codex/livesync-onset-evidence`, issue de `4edf46d4`. Expérience en cours,
non intégrée à la branche maintenue et non livrée comme correction de Mentalist.

## Problème observé

Une réplique peut être identifiée grâce à ses mots voisins, mais son premier mot
est parfois substitué par Whisper ou situé dans une fin de segment rejetée.
L'alignement actuel refuse alors son début. Dans les essais LibriSpeech, les
repères restants arrivent trop tard pour corriger la dérive pendant l'acquisition.

Élargir une fenêtre isolée à quinze secondes ne récupère pas le début manquant
dans les deux modèles testés. Un abaissement global des seuils de régression
n'a pas non plus satisfait les essais de développement. Ces pistes ne sont pas
retenues comme corrections validées.

## Hypothèse à vérifier

Un début d'activité acoustique pourrait corroborer un horodatage de réplique
lorsque suffisamment de mots voisins identifient déjà le passage sans ambiguïté.
Le VAD seul ne doit jamais produire une ancre, un décalage ou une zone absente.
La musique, les bruits, les débuts tronqués et les pauses internes doivent être
traités comme des cas négatifs, pas comme des preuves de parole.

## Étape implémentée

- Analyse du PCM exact envoyé à l'inférence, avant effacement du buffer temporaire.
- Repères numériques : début et fin d'activité, silence observé avant le début,
  durée d'activité effective sans compter le prolongement de 200 ms du détecteur.
- Fenêtre bornée à 240 000 échantillons ; aucun PCM retenu dans ces objets.
- Conservation de toute la fenêtre de quinze secondes pour cette analyse ; le
  détecteur de cadence conserve son historique habituel de douze secondes.
- Transport des repères avec le résultat de leur propre inférence et invalidation
  lors d'un changement de génération, de continuité ou de fermeture.
- Le contexte exclut les intervalles acoustiques qui chevauchent la nouvelle fenêtre.
- Le probe exporte uniquement les repères numériques, l'instant de réception et
  les coordonnées des ancres pour éviter les hypothèses de latence des anciens rejeux.

Aucun repère acoustique ne participe encore au calcul des ancres ou des mappings.
Les seuils de correspondance, de régression et de cadence sont inchangés.

## Conditions avant intégration

1. Vérifier le transport sur PCM natif réel et ses ruptures de continuité.
2. Définir et tester la règle combinant preuve textuelle, timestamps et acoustique ;
   un mot manquant, un bruit ou un repère VAD ne doit pas être une confirmation seul.
3. Rejeter les débuts sans silence antérieur observé, les candidats multiples et
   les timings hors domaine. Ne pas reconstruire une phrase à travers un trou audio.
4. Exercer la règle sur les deux dérives, le cas déjà aligné, les faux passages,
   la musique et un corpus distinct des extraits de développement.
5. Mesurer le suivi depuis la première correction réellement appliquée, avec
   les périodes incertaines incluses ; ne pas déplacer le début de mesure pour passer.
6. Vérifier coût, cycle de vie, builds et comportement réel dans Plezy avant promotion.

Les premiers tests de transport passent : 138 tests LiveSync, dont silence connu,
début tronqué, vitesse, fenêtre longue, PCM corrompu et contexte inter-fenêtres.
Ils ne valident ni la qualité du VAD ni la synchronisation.

L'analyse Flutter complète passe sans diagnostic. Un essai natif de 46 secondes
sur la dérive accélérée transporte des repères cohérents avec les fenêtres
capturées, y compris le début à 32,235 s situé dans une fin ASR partiellement
rejetée (0,780 s de calme observé, 0,500 s d'activité effective). Quatre analyses,
un préfixe valide, aucun rejet natif. Le suivi temporel reste en échec (p95
2,223 s) car ces repères ne sont pas encore utilisés pour apprendre un mapping.
Ce résultat prouve le transport des métadonnées, pas leur aptitude à recaler le SRT.

## Règle expérimentale explicite — `bbcee30d`

Le probe accepte désormais `--experimental-acoustic-beginnings true` ; la valeur
par défaut reste `false`, notamment dans le contrôleur applicatif. Le rapport
inscrit cette option pour éviter de confondre les deux comportements.

La récupération se limite à **un mot substitué**, avec un emplacement ASR encore
horodaté. Elle demande la dernière parole exacte de la cue précédente, exactement
un mot entre cette parole et cinq mots exacts consécutifs de la nouvelle cue,
des temps valides et ordonnés, puis un seul début acoustique à moins de 250 ms
du mot substitué. Ce début doit suivre la cue précédente, précéder le deuxième
mot, montrer au moins 400 ms de calme observé et 300 ms d'activité effective,
et rester dans la fenêtre capturée. L'ancre emploie le début acoustique avec une
incertitude heuristique de 500 ms. Les seuils restent à calibrer indépendamment.

Un mot absent, une insertion, un mot droit peu fiable, un début tronqué, un bruit
bref, plusieurs départs proches ou un calme non observé entraînent un rejet.
Même les départs faibles comptent dans le test d'ambiguïté. Cette règle ne joint
pas les textes rejetés d'un préfixe ASR et ne récupère pas une cue dont le début
se trouve dans une autre fenêtre. Elle ne modifie ni la cadence ni la régression.

**142 tests LiveSync passent**, analyse Flutter complète sans diagnostic. Les
cas acoustiques de ces nouveaux tests sont synthétiques : ils vérifient les
conditions logiques, pas la discrimination voix/musique ni la précision réelle.

### Lecture native ralentie — résultat insuffisant

Le probe natif de 150 secondes à `bbcee30d`, option activée et modèle q5, récupère
la cue 4 à **35,011 s** dans la fenêtre 32,991–44,991 s, incertitude 500 ms. Il
acquiert la première correction à 9,577 s puis la pente à **69,752 s**. Six
analyses complètes, aucun préfixe ni rejet natif. L'erreur p95 est **1,528 s**,
maximum **1,780 s**, erreur finale **432 ms** : **échec**, limite inchangée 750 ms.

La cue récupérée rend six ancres disponibles plus tôt. Le précédent essai ralenti
atteignait la pente à 93,845 s et p95 2,526 s, mais les phases des fenêtres diffèrent
entre les lectures : ce n'est pas une comparaison contrôlée ni une mesure de gain
généralisable. Le rapport `onset-rule-slower-bbcee30d.json` conserve les fenêtres,
les instants de réception, les repères et les erreurs. Les seuils de régression
sont restés inchangés ; aucune application utilisateur n'est mise à jour.

### Lecture native accélérée — absence de gain démontré

L'essai de 137 secondes à `bbcee30d` ne récupère aucune nouvelle ancre acoustique.
Première correction **21,651 s**, pente **94,017 s**, p95 **3,441 s**, maximum
**3,660 s**, erreur finale **720 ms** : **échec**. Huit analyses complètes, un
préfixe valide et aucun rejet natif. La cue 4 reste coupée entre les fenêtres ;
la règle ne peut pas inventer le premier mot ou reprendre un texte rejeté.
Rapport `onset-rule-faster-bbcee30d.json`.

**Décision : ne pas promouvoir cette expérience.** La récupération bornée a un
effet mesurable sur les ancres du cas ralenti, mais aucune des deux lectures ne
respecte la précision visée. Elle ne résout ni la perte de débuts aux frontières
ASR ni le retard de l'estimation initiale. Les essais négatifs natifs, la musique,
le corpus indépendant et le contrôleur applicatif restent à vérifier avant toute
intégration éventuelle. Les 142 tests ne remplacent pas ces preuves manquantes.
