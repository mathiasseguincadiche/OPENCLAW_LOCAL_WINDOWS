# État du projet

## Version courante

**0.3.0 — Architecture V2 local-only + Project Orchestrator + V7 Superset + Document Flow + flotte B580**

`OPENCLAW_LOCAL` est une plateforme multi-agent locale avec huit rôles spécialisés, projets, preuves, séparation producteur/auditeur, pédagogie, publication gouvernée et garde-fous fail-closed. **Aucun modèle LLM cloud n'est supporté en Architecture V2.** Les outils Web peuvent fournir des informations fraîches, mais l'analyse et le raisonnement restent exécutés par les modèles locaux.

La CI valide l'architecture logicielle et les contrats. Elle **ne qualifie pas** les performances ni la stabilité matérielle sur la workstation réelle.

## Flotte V2 candidate B580

La flotte opérationnelle candidate contient exactement trois modèles Q4_K_M :

| Alias routé | Runtime local | Usage cible |
|---|---|---|
| `qwen-max` | `qwen3.5:9b-q4_K_M` | orchestration, recherche, sécurité, release, raisonnement, multimodal |
| `gemma-deep` | `gemma4:12b-it-q4_K_M` | architecture, rédaction, audit, multimodal |
| `devstral-devops` | `hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M` | DevOps/software engineering agentique, outils, texte/code |

L'alias `devstral-devops` est conservé pour compatibilité des routes et états. Son runtime V2 est **Ministral 3 14B Reasoning Q4_K_M**.

**Invariant : exactement trois modèles sont routables par le contrat opérationnel.** Aucun petit modèle, runtime legacy ou modèle en ligne n'est un fallback supporté.

## Challenger local : Granite 4.2 8B

Le catalogue déclare séparément :

```text
granite-devops -> granite4.2:8b-q4_K_M
```

Granite est un challenger local du spécialiste DevOps :

- `routing_active: false` ;
- aucun des huit rôles ne l'utilise nominalement ;
- il ne compte pas dans les trois modèles opérationnels ;
- il n'est pas un fallback ;
- il ne remplace pas un échec d'un modèle actif ;
- `automatic_promotion: false` ;
- toute substitution exige une décision humaine explicite appuyée sur des preuves réelles.

## Routage nominal

```text
Chef opérations       -> Qwen 3.5 9B
Expert recherche      -> Qwen 3.5 9B + outils Web
Architecte solutions  -> Gemma 4 12B
Ingénieur DevOps      -> Ministral 3 14B Reasoning
Ingénieur sécurité    -> Qwen 3.5 9B
Release/Forges        -> Qwen 3.5 9B
Rédacteur technique   -> Gemma 4 12B
Auditeur qualité      -> Gemma 4 12B
                         -> Qwen 3.5 9B si séparation de famille requise
```

Granite n'apparaît pas dans ce routage tant qu'une décision humaine future n'a pas explicitement modifié le contrat.

## Politique de contexte

Architecture V2 sépare explicitement le benchmark de l'orchestration :

- **8192 tokens** : contexte nominal benchmark/HARD-40M ;
- **16384 tokens** : contexte nominal d'orchestration OpenClaw ;
- le 16384 OpenClaw n'est pas une promotion du benchmark ;
- **aucune promotion automatique à 32K** ;
- toute extension future exige une qualification dédiée.

## Project Orchestrator et Document Flow

Machine d'états principale :

```text
INTAKE_READY
  -> ANALYZED
  -> CLARIFICATION_REQUIRED si nécessaire
  -> PLANNED
  -> ASSIGNED
  -> IN_PROGRESS
  -> VALIDATING
  -> REVIEW
  -> PACKAGING
  -> COMPLETE
```

Le système conserve notamment : Intake immuable, scan de secrets, SHA-256/MIME, ingestion PDF/image/Office, `source_coverage[]`, Artifact Exchange versionné, remediation bornée, séparation producteur/auditeur, package final et approbation humaine.

## Permissions

- Chef/Recherche : orchestration/lecture ;
- Architecte : écriture bornée architecture/diagrammes ;
- DevOps : modification/exécution selon politique ;
- Sécurité : audit read-only ;
- Release/Forges : Git/PR/MR/release sous gates ;
- Rédacteur : documentation versionnée ;
- Auditeur : contrôle indépendant sans correction silencieuse.

## Accélération Intel Arc B580

Le choix d'architecture GPU LLM est **Vulkan uniquement**. Il n'est plus soumis à une compétition entre API.

Chemins actifs :

- `ollama-vulkan` — nominal et rollback ;
- `llama-cpp-vulkan` — runtime géré local ;
- `b580-hybrid` — Qwen sur Ollama/Vulkan et Gemma/Ministral sur llama.cpp/Vulkan.

La qualification matérielle restante vérifie que ces chemins Vulkan fonctionnent réellement et restent stables sur la B580. Elle ne sert pas à choisir une autre API GPU.

## Gates anti-régression

CI/Release couvrent notamment :

```text
21_validate_repository.py
22_validate_configs.py
35_validate_v7_parity.py
39_validate_v7_superset.py
44_validate_document_flow.py
45_validate_model_fleet.py
24_validate_release.py
Ruff
mypy
pytest + coverage >= 75 %
Python 3.12 / 3.13
PowerShell 7
PSScriptAnalyzer
Pester
CodeQL
Dependency Review
```

Le gate flotte V2 exige notamment :

- exactement trois modèles routés Q4_K_M ;
- Qwen 3.5 9B + Gemma 4 12B + Ministral 3 14B Reasoning ;
- aucun runtime legacy actif ;
- `local_only: true` ;
- `cloud_models_supported: false` ;
- toute demande cloud refusée ;
- Vulkan comme unique accélération GPU LLM active ;
- aucun retour du backend GPU retiré dans les surfaces actives ;
- Granite 4.2 séparé du routage ;
- promotion automatique interdite et décision humaine obligatoire.

## À exécuter sur matériel réel

GitHub Actions ne peut pas valider :

1. installation réelle Windows 11 + Intel Arc B580 ;
2. démarrage et vérification du runtime Vulkan géré ;
3. configuration OpenClaw nominale puis `b580-hybrid` ;
4. E2E OpenClaw avec les trois modèles routés ;
5. vraie multimodalité PDF/image ;
6. Golden Projects ;
7. projet représentatif multi-documents ;
8. stabilité du chemin Vulkan, chargement/déchargement et récupération après redémarrage ;
9. VRAM/RAM et comportement matériel observés ;
10. indépendance producteur/auditeur ;
11. télémétrie réelle ;
12. package final et revue humaine.

## Non prétendu

- aucun modèle n'est qualifié matériellement par la CI ;
- Granite n'est pas déclaré meilleur que Ministral sans décision humaine ;
- aucun débit B580 n'est garanti ;
- aucune résidence VRAM complète n'est supposée ;
- le choix Vulkan est un contrat d'architecture, pas une revendication de performance ;
- aucun LLM cloud n'est supporté ;
- aucun résultat matériel n'est inventé par la CI.

## Critère pour V1.0.0

La version `1.0.0` reste réservée à un parcours réellement validé sur Windows 11 + Intel Arc B580, avec E2E, stabilité Vulkan, preuves fonctionnelles requises par les contrats de release, Golden Projects, multimodalité réelle, télémétrie, projet représentatif, limites documentées et validation humaine explicite.
