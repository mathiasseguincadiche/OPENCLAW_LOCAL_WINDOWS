# Changelog

Toutes les modifications notables sont documentées ici. Le format s'inspire de
Keep a Changelog et le versionnage suit SemVer.

## [Unreleased]

### Fixed

- supprime le fournisseur LLM cloud résiduel des contrats actifs Architecture V2 et rend l'escalade LLM cloud explicitement fail-closed ;
- distingue l'escalade de sources Web distantes du raisonnement LLM, qui reste local ;
- marque le contrat FinOps OpenRouter V0.2 comme compatibilité historique, sans route d'exécution LLM en V2 ;
- remplace la preuve V1 obsolète de comparaison de backends par une preuve de stabilité du runtime Vulkan retenu ;
- corrige les badges, URLs de clonage et références de gouvernance vers `OPENCLAW_LOCAL_WINDOWS`.

## [0.3.0] - 2026-09-14

### Added

- chaîne de publication documentaire premium bornée Markdown/HTML/DOCX/PDF via Quarto/Pandoc/Typst, avec diagrammes Mermaid/Graphviz versionnés ;
- outillage métier spécialisé et traçable par agent, sans élargissement des privilèges génériques, avec gate CI dédié ;
- préparation de release gouvernée permettant une demande explicite du propriétaire avant création du tag et publication.
- Project Orchestrator fail-closed avec machine d'états explicite ;
- analyse structurée, clarifications humaines, plan et assignation de tâches ;
- exécution locale des tâches OpenClaw avec dépendances et tentatives bornées ;
- collecte namespacée des sorties par tâche/agent/tentative ;
- validation et review indépendantes avec retour en correction ;
- boucle de remediation exécutable avec réouverture ciblée des tâches et dépendants transitifs ;
- historique `remediation_history.json` sans remise à zéro des tentatives ;
- arrêt fail-closed lorsque la limite de tentatives impose une intervention humaine ;
- packaging final ZIP avec SHA-256 et approbation humaine obligatoire ;
- Intake renforcé avec archive canonique hors projet, SHA-256, MIME, rapport d'ingestion et lecture seule/ACL Windows ;
- politique pédagogique `efficient` / `balanced` / `intensive` et modes guided/assisted/autonomous/evaluation ;
- artefacts `SKILLS_MATRIX.csv`, `LEARNING_JOURNAL.md`, `TEACH_BACK.md` et `RETENTION_PLAN.yaml` ;
- documentation progressive Comprendre / Utiliser / Approfondir / Diagnostiquer ;
- machine d'états de publication des projets GitHub/GitLab avec preuves locales/distantes et gates humains ;
- télémétrie opérationnelle locale append-only sans prompts, réponses, secrets ni documents privés ;
- writer d'architecture borné à `context/architecture/` et `diagrams/` ;
- validateur `35_validate_v7_parity.py` et documentation de filiation V7 ;
- manifeste projet strict, criticité/classification actives, Task Contract enrichi et migrations transactionnelles ;
- validateur canonique `39_validate_v7_superset.py` et matrice V7 `PRESERVED/IMPROVED/REPLACED` ;
- **Document Ingestion local-first** : index SHA-256/MIME, extraction déterministe texte/DOCX/PPTX/XLSX, PDF via l'outil OpenClaw `pdf` et images via `view_image` ;
- `source_coverage[]` obligatoire pour démontrer la lecture de chaque document déclaré, avec statuts `READ`, `PARTIAL` ou `UNREADABLE` ;
- **Artifact Exchange** versionné entre tâches : self-history par tentative, propagation des sorties `PASS` aux dépendants directs/transitifs, provenance et SHA-256 ;
- resynchronisation ciblée des workspaces agents après chaque tentative afin que les consommateurs voient automatiquement les sorties amont ;
- CLI `42_project_ingest.py` et `43_project_exchange.py` pour reconstruire/valider l'ingestion et auditer les échanges ;
- validateur anti-régression `44_validate_document_flow.py`, exécuté par CI et Release ;
- flotte opérationnelle Architecture V2 contenant exactement `qwen3.5:9b-q4_K_M`, `gemma4:12b-it-q4_K_M` et `hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M`, avec Granite 4.2 8B challenger de benchmark non routé ;
- indépendance renforcée de l'Auditeur par séparation de famille Gemma/Qwen lorsqu'elle est praticable ;
- validateur anti-régression `45_validate_model_fleet.py`, exécuté par CI et Release ;
- helper `safe_fs` pour appliquer un confinement fail-closed commun aux entrées, snapshots, sorties, échanges et packaging ;
- limites de sécurité des archives Office : taille compressée/décompressée, nombre et taille des membres, ratio de compression et refus des membres chiffrés ;
- réservations FinOps append-only et atomiques sous verrou de processus avant chaque exécution cloud réelle ;
- tests hostiles de symlink/junction/reparse point sur Linux et Windows ;
- pinning des GitHub Actions critiques par SHA de commit immuable.

### Changed

- `project_policy.yaml` couvre désormais tout le cycle jusqu'à `COMPLETE` et référence Intake/Pédagogie/Accessibilité/Publication/Télémétrie ;
- les snapshots de revue peuvent inclure les sorties centrales ;
- le portail projet documente le parcours flou -> livrable -> publication contrôlée ;
- un `FAIL` de validation/review remet réellement les tâches concernées en état exécutable ;
- l'Ingénieur sécurité reste explicitement read-only pour les modifications de sources ;
- l'Architecte produit ADR et schémas via un writer spécialisé plutôt que via des droits génériques ;
- la CI et le workflow Release exécutent les validateurs de parité V7 ;
- les huit agents disposent des outils locaux `pdf` et `view_image` tout en conservant leurs restrictions d'écriture ;
- le patch OpenClaw configure explicitement `imageModel`, `pdfModel`, `pdfMaxBytesMb` et `pdfMaxPages` sur les modèles locaux ;
- l'analyse projet vérifie l'index d'ingestion et refuse une couverture documentaire incomplète ;
- les phases de validation, revue, packaging et completion refusent de progresser lorsque l'Artifact Exchange attendu est absent ou altéré ;
- les prompts contractuels des huit rôles distinguent originaux, représentations dérivées et artefacts échangés en lecture seule ;
- `qwen-max` pointe vers Qwen 3.5 9B, `gemma-deep` vers Gemma 4 12B et l'alias de compatibilité `devstral-devops` vers Ministral 3 14B Reasoning ;
- Architecture V2 est local-only côté LLM : aucun catalogue, routage ou fallback LLM cloud n'est supporté ; les outils Web restent des sources d'information distinctes ;
- les trois modèles supportés sont tous `required: true` et participent tous au gate global de qualification ;
- les anciens switches `IncludeDeep`, `IncludeSpecialist` et `IncludeMax` ont été supprimés du parcours nominal : aucune classe locale supportée n'est optionnelle ;
- le benchmark nominal sélectionne directement `qualification_policy.automated_gates.required_models` ;
- le README dispose d'un parcours de démarrage en cinq étapes avec résultats attendus ;
- le ledger FinOps prend les réservations actives en compte avant d'autoriser une nouvelle dépense ;
- le bootstrap Windows rafraîchit le PATH après installation Ollama et revalide immédiatement la version verrouillée avant de poursuivre.

### Security

- les documents entrants sont explicitement non fiables et ne peuvent pas redéfinir la politique des agents ;
- les symlinks, junctions et autres reparse points sont refusés sur les frontières filesystem gérées et ne sont jamais déréférencés pour copier un fichier extérieur au projet ;
- les secrets potentiels bloquent l'ingestion avant matérialisation du projet ;
- l'Intake et son archive canonique deviennent immuables après création ;
- les représentations documentaires locales ne remplacent jamais les originaux comme source de vérité ;
- les archives Office malformées, path-traversal, chiffrées ou présentant des caractéristiques de décompression dangereuses sont refusées avant lecture XML ;
- les PDF dépassant la limite locale déclarée sont refusés avant d'être marqués `READY_TOOL` ;
- les bundles d'échange sont hashés, versionnés et refusent les fichiers liés/reparse ;
- les snapshots d'intégrité et bundles de support réutilisent les garde-fous `safe_fs`, y compris contre les junctions/reparse points Windows ;
- les backups, ledgers et rollbacks de migration sont confinés au projet et refusent les liens/reparse points ;
- la primitive de packaging de base refuse elle-même les liens/reparse points et sécurise ses cibles de sortie, indépendamment du wrapper superset ;
- le packaging refuse les liens/reparse points dans les artefacts gérés ;
- l'ingestion documentaire n'active aucun service cloud ;
- les réservations FinOps empêchent deux agents concurrents de consommer simultanément le même budget disponible ;
- la télémétrie refuse les contenus privés et les métriques négatives/fabriquées ;
- les publications distantes restent soumises à approbation humaine et preuves observées ;
- aucune promotion automatique de modèle/backend n'est autorisée ;
- l'activation des tiers performance ne réactive jamais le cloud et ne contourne pas les gates FinOps/humains.

## [0.2.0] - 2026-08-27

### Added

- Project Intake avec manifeste, arborescence gérée et snapshots par agent ;
- garde-fou contre les secrets évidents dans l'intake ;
- recherche Web local-first avec raisonnement local ;
- politique d'escalade cloud à préconditions exécutables ;
- budget FinOps quotidien, mensuel et par projet ;
- Qwen 3.5 27B comme candidat LOCAL_DEEP ;
- matrice de backends Ollama/Vulkan, llama.cpp/SYCL et llama.cpp/Vulkan ;
- support de qualification multimodale text/image ;
- diagram-as-code local D2, PlantUML et Graphviz ;
- suite de qualification `devops-v2` ;
- documentation Project Intake, Web, runtime backends, FinOps et diagrammes.

### Changed

- Gemma est désormais épinglé explicitement sur `gemma4:12b` ;
- la fraîcheur Web seule ne déclenche plus Perplexity/Sonar ;
- les modèles téléchargés et smoke-testés sont lus depuis `model_catalog.yaml` ;
- le runner charge la suite déclarée dans `qualification_policy.yaml` ;
- les validateurs couvrent les nouveaux contrats V0.2 ;
- la version plateforme/package passe à `0.2.0`.

### Security

- aucun fallback cloud silencieux ;
- dépassement de budget refusé par défaut ;
- approbation humaine appliquée aux motifs qui l'exigent ;
- snapshots de projet non gérés protégés contre l'écrasement.

## [0.1.0] - 2026-08-25

### Added

- socle `OPENCLAW_LOCAL` local-first sous Windows 11 ;
- huit rôles multi-agents ;
- catalogue Qwen/Gemma et candidat SERA ;
- routage local avec escalade cloud explicite ;
- profil matériel Intel Arc B580 12 Go ;
- scripts d'audit, configuration, vérification et benchmark ;
- validateurs Python et tests unitaires.
