# V7 Full Parity / Superset Gate

`OPENCLAW_LOCAL_WINDOWS` est le successeur local-first puis **local-only côté LLM** de `openclaw_openrouter`. La règle de cette passe est plus stricte que la simple reprise des grandes fonctions : **toute capacité V7 encore pertinente doit être `PRESERVED`, `IMPROVED` ou explicitement `REPLACED`**.

La baseline de comparaison est le commit V7 `b2d5ae5c9df4dc06fe2f2c3fbae5653b37b67f1b` de `mathiasseguincadiche/openclaw_openrouter`. Le registre machine-readable est `config/v1/v7_superset_matrix.yaml`.

## Manifeste projet strict

Les nouveaux projets utilisent `project.json` schema `2.0.0`. Les champs inconnus sont refusés. Le manifeste porte désormais `owner`, `classification`, `criticality`, critères d'acceptation et frontières d'approbation humaine.

Classifications : `public`, `internal`, `confidential`, `restricted`. Criticités : `low`, `standard`, `high`, `critical`.

La classification et la criticité ne sont plus décoratives. Le **LLM cloud est interdit globalement** par Architecture V2, quelle que soit la classification. La politique de classification gouverne désormais les **services externes non-LLM** : `restricted` les interdit ; `confidential` exige redaction et approbation humaine. Les projets `high` et `critical` renforcent les gates ; `critical` exige notamment une seconde revue indépendante et une approbation explicite avant service externe lorsque ce service est demandé.

## Gates de criticité exécutables

Les gates sont persistées dans `context/governance/criticality_gates.json` et vérifiées par l'orchestrateur avant les transitions sensibles. Elles ne sont donc plus de simples métadonnées.

- `standard` : preuve de travail puis audit indépendant avant `REVIEW` ;
- `high` : audit indépendant + revue sécurité par `ingenieur-securite` + preuve de rollback avant `PACKAGING`, puis approbation humaine finale ;
- `critical` : tous les gates `high` + seconde revue indépendante réalisée par un reviewer différent ;
- `external_service_requires_human_approval` reste conditionnel : il ne bloque pas un projet qui n'utilise aucun service externe, mais impose une approbation humaine avant l'usage concerné d'un projet `critical`.

Le shim historique `cloud_policy_for_project()` reste fail-closed et retourne systématiquement `llm_cloud_not_supported`. Il ne constitue pas une voie d'autorisation.

La CLI `scripts/41_project_gates.py` permet d'afficher les gates manquants et d'enregistrer leurs preuves. L'orchestrateur enregistre automatiquement les preuves qu'il peut établir sans ambiguïté : tâches toutes `PASS`, audit de validation et approbation finale.

## Task Contract enrichi

Chaque tâche peut porter : scope in/out, faits, hypothèses, inconnues, critères d'acceptation, preuves requises, producteur, reviewer et décisions humaines. Le plan est normalisé avant d'être accepté par l'orchestrateur. Lorsqu'un reviewer est déclaré, il doit être distinct du producteur.

## Intake et sources

L'Intake conserve ses protections immuables, SHA-256, MIME, rapport et ACL Windows. En plus, les `sources/` sont désormais scannées pour secrets avant copie. Le scan des fichiers textuels est streamé et ne saute plus silencieusement un fichier seulement parce qu'il dépasse une limite de taille.

Les sources gardent leur propre inventaire de hashes/MIME/symlinks dans `evidence/sources/`.

## Intégrité multi-phase

`project_integrity.py` crée des snapshots SHA-256 et un digest agrégé. L'orchestrateur enregistre des snapshots aux jalons structurants (`PLANNED`, `VALIDATING`, `REVIEW`, `PACKAGING`, `COMPLETE`) ainsi qu'avant/après packaging.

Cela distingue l'intégrité de l'Intake, des sources, du travail, des livrables et du package final.

## Pédagogie complète

`LEARNING_CONTRACT.json` sépare désormais le verdict pédagogique du verdict technique. Verdicts : `ACQUIS`, `ACQUIS_AVEC_RESERVES`, `A_RENFORCER`, `NON_EVALUE`.

L'échelle d'aide V7 est restaurée : question courte → indice → correction ciblée → solution complète justifiée, avec possibilité de sauter des niveaux lorsque la situation ou la demande l'exige.

Une compétence ne doit pas être considérée acquise par simple exposition : il faut des preuves permettant d'expliquer, exécuter ou relire, interpréter, identifier un risque, diagnostiquer et reproduire avec moins d'aide.

## Accessibilité documentaire

Les quatre profondeurs restent `Comprendre → Utiliser → Approfondir → Diagnostiquer`. La politique machine-readable contient maintenant les responsabilités documentaires des huit agents, une checklist d'audit en dix points et une règle de proportionnalité fondée sur risque, complexité, réversibilité, public et fréquence.

## Publication : deux barrières indépendantes

La machine d'états de publication reste active, mais V7 Full Parity rétablit aussi les gates par **action** : création de dépôt distant, changement de visibilité, publication publique, merge PR/MR, release, branch protection, force-push/réécriture d'historique et suppression distante/tag.

Un état valide ne donne donc jamais implicitement l'autorisation d'exécuter une action sensible.

## Migration non destructive et transactionnelle

Les projets schema `1.1.0` sont migrables vers `2.0.0` avec backup préalable sous `.migrations/`, validation post-migration et ledger JSONL. La migration est idempotente : un projet déjà courant ne produit aucune étape.

Si une étape échoue après avoir commencé à modifier le projet, le moteur restaure `project.json` ainsi que les contextes Learning/Governance sauvegardés, inscrit `ROLLED_BACK` dans le ledger et propage l'échec. Une migration ne peut donc plus laisser silencieusement un projet à moitié converti.

## Pilotage

Chaque projet possède `context/governance/DECISIONS.md` et `RISKS.md`. L'analyse initiale alimente ces journaux sans remplacer les artefacts structurés de l'orchestrateur.

## Télémétrie automatique

Les appels LLM du Project Orchestrator sont automatiquement chronométrés et enregistrés dans le ledger local. Les métriques présentes dans la sortie OpenClaw sont extraites uniquement lorsqu'elles sont réellement observées : TTFT, tokens, TPS, VRAM/RAM, tool calls et retries.

Aucun prompt, réponse, secret ou document privé n'entre dans la télémétrie. Les éventuels champs historiques liés au cloud restent uniquement des compatibilités de schéma et ne réactivent aucune route LLM cloud.

## Sécurité transverse

La redaction couvre logs, diagnostics, exceptions et support bundle. Un support bundle exclut Intake/sources par défaut, redige les contenus textuels sélectionnés et applique une seconde passe de détection avant création de l'archive.

Le contrat supply-chain exige versions bornées, lockfile avant release lorsque l'écosystème le permet, images officielles préférées, SBOM, secret scan et analyse de vulnérabilités/dependency review.

## Gate anti-régression

`scripts/39_validate_v7_superset.py` vérifie la matrice de parité, les contrats critiques, l'interdiction LLM cloud, la gouvernance des services externes, les gates `high/critical`, la séparation producteur/reviewer, le rollback des migrations et le branchement effectif des CLI. Ce gate est exécuté en CI et dans le workflow Release afin qu'une évolution future ne puisse pas supprimer silencieusement une qualité héritée de V7.

Cette parité est **fonctionnelle et contractuelle**. Elle ne remplace toujours pas la qualification réelle de la workstation, des modèles locaux, de l'Intel Arc B580, des ACL Windows sur la machine finale ou d'une publication GitHub/GitLab E2E.
