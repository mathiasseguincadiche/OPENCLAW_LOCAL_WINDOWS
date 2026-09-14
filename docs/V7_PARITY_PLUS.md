# Filiation V7 — `openclaw_openrouter` vers `OPENCLAW_LOCAL_WINDOWS`

`OPENCLAW_LOCAL_WINDOWS` est la réécriture **local-first puis local-only côté LLM** de l'idée portée historiquement par `openclaw_openrouter` : OpenClaw reste le runtime agentique, huit rôles spécialisés conservent leurs responsabilités, et la couche de contrôle versionnée conserve projets, preuves, sécurité, budget historique, validation et gouvernance.

La différence structurante est le chemin IA actuel :

```text
baseline historique openclaw_openrouter
OpenClaw → OpenRouter → modèles cloud → contrats/projets/preuves

OPENCLAW_LOCAL_WINDOWS — Architecture V2
OpenClaw → modèles locaux → outils Web distants si nécessaires
          │                 │
          └── raisonnement LLM local uniquement
              + contrats/projets/preuves/orchestration
```

Architecture V2 ne cherche pas à rendre l'ancien chemin OpenRouter optionnel : elle le **remplace**. Aucun fournisseur d'inférence LLM cloud, aucun fallback LLM en ligne et aucune escalade LLM cloud ne sont supportés. Les outils Web peuvent rester distants comme sources d'information ; leurs résultats sont analysés localement.

L'objectif n'est pas de prétendre qu'un petit modèle local est individuellement supérieur à tous les modèles frontier. La plateforme cherche à obtenir un meilleur **rapport autonomie / coût / confidentialité / vérifiabilité** grâce à l'orchestration, la spécialisation, la recherche Web, les corrections, l'audit et des frontières d'exécution explicites.

## Capacités V7 conservées, renforcées ou remplacées

| ADN V7 | OPENCLAW_LOCAL_WINDOWS Architecture V2 |
| --- | --- |
| 8 rôles spécialisés | conservés, avec Project Orchestrator |
| producteur ≠ auditeur | conservé et validé par politiques |
| projets + contrats | Project Intake + machine d'états complète |
| preuves | evidence/, runs namespacés, remediation history |
| budget cloud historique | remplacé comme route active ; ledger V0.2 conservé seulement pour compatibilité/audit |
| sécurité Intake | archive canonique, secrets, symlinks, SHA-256, MIME, ACL |
| pédagogie | efficient / balanced / intensive + artefacts d'apprentissage |
| accessibilité | Comprendre / Utiliser / Approfondir / Diagnostiquer |
| publication | machine d'états GitHub/GitLab avec gates humains |
| télémétrie | métriques locales sans prompts ni contenus privés ; champs cloud historiques tolérés pour compatibilité |
| architecture | writer borné pour ADR/schémas, pas de droit générique |
| sécurité | agent sécurité read-only sur les sources |
| gouvernance réseau | services externes non-LLM gouvernés par classification/criticité |

## Principe de supériorité

Une amélioration n'est acceptée que si elle ne détruit pas un garde-fou utile de V7. Les validateurs `21_validate_repository.py`, `22_validate_configs.py`, `35_validate_v7_parity.py` et `39_validate_v7_superset.py` empêchent les régressions structurantes.

La règle V2 est plus stricte que « le local doit fonctionner sans OpenRouter » : **OpenRouter et tout autre fournisseur LLM cloud sont hors du runtime supporté**. Une demande LLM cloud doit échouer explicitement.

## Ce qui reste à prouver sur la workstation

La parité fonctionnelle du code ne qualifie pas automatiquement les modèles locaux ni l'Intel Arc B580. Les performances, le contexte utile, la stabilité Vulkan, le tool calling, la multimodalité et la qualité sémantique sur de vrais projets restent des preuves matérielles à mesurer.
