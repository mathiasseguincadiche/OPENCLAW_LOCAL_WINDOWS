# Télémétrie locale

## Objectif

La télémétrie de `OPENCLAW_LOCAL_WINDOWS` sert à observer le comportement réel de la plateforme sans transformer les prompts, réponses ou documents privés en données de monitoring.

Architecture V2 n'utilise aucun modèle LLM cloud ; la télémétrie d'inférence reste donc attachée aux backends locaux.

## Flotte suivie

```text
qwen-max          -> qwen3.5:9b-q4_K_M
gemma-deep        -> gemma4:12b-it-q4_K_M
devstral-devops   -> hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M
```

`devstral-devops` est l'alias de compatibilité du spécialiste Ministral 3 14B Reasoning.

Le challenger local `granite-devops -> granite4.2:8b-q4_K_M` possède ses propres preuves de benchmark et ne doit pas être agrégé comme modèle routé.

Toute métrique portant sur une flotte retirée reste historique. Elle ne doit pas être agrégée comme si elle mesurait Architecture V2.

## Données autorisées pour les nouvelles écritures

Selon disponibilité réelle du runtime :

- timestamp ;
- projet et phase ;
- agent ;
- alias et runtime modèle ;
- backend/provider local ;
- contexte demandé ;
- durée murale ;
- TTFT ;
- tokens d'entrée/sortie ;
- tokens/s ;
- VRAM/RAM observées ;
- durée de chargement ;
- tool calls ;
- retries ;
- transitions locales de profondeur ;
- statut PASS/FAIL ;
- utilisation d'un outil Web et provenance de la preuve lorsque la politique le prévoit, sans contenu privé.

Une donnée non disponible reste `null`/absente. Elle n'est jamais estimée puis présentée comme observée.

## Compatibilité des anciennes preuves V0.2

Les anciens journaux peuvent contenir les champs historiques suivants :

```text
cloud_escalation
cloud_cost_eur
route_kind = cloud_escalation
```

Architecture V2 les traite comme **lecture seule**. `read_telemetry()` et `summarize_telemetry()` peuvent encore les relire afin de préserver l'audit d'anciennes preuves, mais `append_telemetry()`, la capture automatique et `scripts/34_record_telemetry.py` refusent toute nouvelle écriture de ces champs ou de cette route.

Les résumés historiques utilisent des noms explicitement préfixés `legacy_`. Une ancienne ligne de télémétrie ne peut jamais réactiver une route LLM cloud, modifier le routage courant ni satisfaire un gate Architecture V2.

## Données interdites

La télémétrie ne doit pas stocker :

- prompts complets ;
- réponses complètes ;
- documents utilisateur ;
- secrets ;
- clés API ;
- tokens Gateway ;
- contenu du canal thinking ;
- fichiers privés du projet.

Le volume de thinking peut être compté lorsqu'il est exposé, mais son contenu brut n'est pas conservé.

## Contextes

Deux contrats doivent rester distinguables dans les preuves :

```text
8192  -> benchmark nominal / HARD-40M
16384 -> orchestration full-agent OpenClaw nominale
```

Les cas 16K du HARD-40M restent des cas de stress du benchmark, alors que le 16K OpenClaw est la fenêtre nominale d'orchestration. Les métriques doivent indiquer le protocole afin de ne jamais mélanger les deux usages.

Aucune série 32K ne peut être assimilée au nominal sans qualification dédiée.

## Migration et fingerprints

Après changement de modèle, digest, quantification, backend, pilote ou runtime, les séries doivent rester distinguables. Une ancienne performance ne peut pas être réattribuée au nouveau fingerprint.

## Stockage

Les preuves/télémétries opérationnelles restent locales, sous la racine gérée et hors Git selon les politiques du projet.

L'objectif est de pouvoir relier une mesure à :

```text
commit
+ agent
+ alias
+ runtime_id
+ digest/quantification si disponible
+ backend
+ pilote
+ contexte
+ protocole/scénario
```

## Utilisation pour la qualification

Les données de télémétrie peuvent soutenir la décision V1 uniquement lorsqu'elles correspondent à la flotte, au commit et au matériel réellement qualifiés. Elles complètent les preuves HARD-40M, E2E, backend, multimodalité, challenger, Golden Projects et projet représentatif ; elles ne les remplacent pas.

La CI ne fabrique jamais de mesure B580. Une valeur matérielle absente reste absente jusqu'au run réel sur la workstation.
