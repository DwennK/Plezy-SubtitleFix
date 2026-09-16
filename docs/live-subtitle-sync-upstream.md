# Maintenance upstream du fork

## Branche et déclenchement

L'action `LiveSync upstream integration` s'exécute chaque jour à **05:23 UTC**
sur la branche par défaut `feature/live-subtitle-sync`. Elle peut aussi être
lancée depuis Actions ou avec :

```sh
gh workflow run livesync-upstream.yml --repo DwennK/Plezy-SubtitleFix
```

Le mode manuel `validate_current=true` exerce volontairement l'ensemble des
builds et de la PR brouillon même si aucun commit upstream n'est nouveau.
Le mode quotidien n'utilise pas cette option : un upstream déjà contenu dans
la branche maintenue produit uniquement un rapport `unchanged`.

```sh
gh workflow run livesync-upstream.yml --repo DwennK/Plezy-SubtitleFix -f validate_current=true
```

## Intégration et preuve

1. Fetch du `main` officiel et lecture de la dernière release stable.
2. Comparaison de l'ascendance Git avec la branche maintenue.
3. Préparation de `codex/upstream-sync`, sans modifier `main` ou la branche maintenue.
4. Fusion à trois voies des nouveautés officielles et des correctifs maintenus.
   Cette stratégie conserve les commits du patch au lieu de les dupliquer par
   cherry-pick ; elle permet une promotion sans réécriture forcée d'historique.
5. Mise à jour de la provenance candidate : versions Plezy/Flutter, commit du SDK,
   moteur Windows, lock natif officiel et composants du mpv-build épinglé.
   Les modèles Whisper et patches LiveSync restent explicitement épinglés.
   Un nouveau format de pins ou dépôt natif exige une revue ; aucun ancien pin
   ne remplace silencieusement une nouvelle version upstream.
6. Exécution de la CI upstream et des tests LiveSync, build natif Windows,
   build Mac et contrats natifs, puis build et probes applicatifs Windows.
7. Conservation des applications, contrats et provenances dans les artefacts
   des runs enfants. Publication ou actualisation d'une unique PR **brouillon**
   après succès de tous les contrôles sur le même SHA immuable.

Les dispatchs portent `integration_id=<SHA>`. Un contrôle manuel partiel, par
exemple un renderer seul, ne peut donc pas être pris pour le build complet de
l'intégration. Un run encore actif est repris et attendu ; une expiration de
l'attente ne l'annule pas. Le rapport conserve son identifiant pour diagnostic.
Les succès réutilisés avec artefacts exigent des artefacts non expirés.

Le workflow parent sérialise ses exécutions. Les pushes sont ordinaires, sans
`--force` : une modification concurrente du remote les fait échouer. Un nouveau
candidat replace une PR existante en brouillon avec l'état « validation en
attente ». Les anciens succès ne sont pas attribués au nouveau SHA.

Les rapports du parent sont conservés 30 jours ; les applications et preuves
des workflows natifs le sont actuellement 14 jours. Ce sont des artefacts de test,
pas une release publique. La CI sans sortie audio matérielle ne valide pas
l'écoute réelle, Mentalist, la précision statistique ou tous les budgets.

## Conflit ou échec

Un conflit interrompt la préparation et produit la liste des fichiers concernés.
L'action annule uniquement sa fusion dans son clone jetable ; elle n'écrase
aucun travail utilisateur et ne résout aucun conflit automatiquement. Consulter
l'artefact `livesync-upstream-prepare-<run>` puis résoudre le conflit explicitement
dans la branche d'intégration. Refaire une validation complète du nouveau SHA.

Si un build échoue, aucune promotion ni release n'a lieu. La branche maintenue
et ses artefacts antérieurs restent accessibles. Les rapports référencent les
jobs enfants ; ne pas relancer un build encore actif parce que son observateur
a expiré. Un nouveau lancement réutilise les runs actifs identifiés.

Le token Actions doit pouvoir écrire les branches et créer/mettre à jour les PRs
du fork. Les jobs de compilation reçoivent seulement les permissions nécessaires
pour lire le code et déclencher leurs contrôles. Aucune approbation ou fusion de
PR n'est automatisée. Aucun token personnel n'est installé dans le workflow.
Les déclenchements explicites sont nécessaires car les événements ordinaires
créés par `GITHUB_TOKEN` ne démarrent pas tous les workflows :
[documentation GitHub](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow).

## Promotion après revue

Vérifier le SHA courant de la PR, tous les runs référencés, leur conclusion,
les versions natives, les artefacts et les validations matérielles encore requises.
Si la branche maintenue a avancé depuis `maintainedBaseSha`, refaire l'intégration
et ses contrôles avant promotion. Le manifeste candidat conserve les checks
historiques avec leurs SHA ; ils ne prouvent pas sa validation.

Promouvoir la PR avec un **merge commit**, sans squash ni rebase, pour conserver
l'ascendance upstream et celle du patch. Une promotion locale équivalente est
un fast-forward de la branche maintenue vers le candidat vérifié, après contrôle
d'un worktree propre. Ne jamais forcer le remplacement de la branche maintenue.

Mettre ensuite `main` à jour par fast-forward vers le SHA upstream **effectivement
intégré et testé**, sans y fusionner les commits LiveSync. La préparation d'une
release brouillon et sa publication publique restent des étapes distinctes.
