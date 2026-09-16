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
