# OPENCLAW_LOCAL_WINDOWS

[![CI](https://github.com/mathiasseguincadiche/OPENCLAW_LOCAL/actions/workflows/ci.yml/badge.svg)](https://github.com/mathiasseguincadiche/OPENCLAW_LOCAL/actions/workflows/ci.yml)
[![CodeQL](https://github.com/mathiasseguincadiche/OPENCLAW_LOCAL/actions/workflows/codeql.yml/badge.svg)](https://github.com/mathiasseguincadiche/OPENCLAW_LOCAL/actions/workflows/codeql.yml)
[![Version](https://img.shields.io/badge/version-0.3.0-blue.svg)](VERSION)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell 7](https://img.shields.io/badge/PowerShell-7%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![Python 3.12-3.13](https://img.shields.io/badge/Python-3.12%20%7C%203.13-blue.svg)](pyproject.toml)

Plateforme IA **100 % locale côté LLM, multi-agents et multi-modèles** pour Windows 11 Pro x64, conçue pour la workstation cible **AMD Ryzen 7 7700 + Intel Arc B580 12 Go**.

`OPENCLAW_LOCAL` combine OpenClaw, huit rôles spécialisés, Project Intake, orchestration fail-closed, Artifact Exchange, preuves, télémétrie locale et publication gouvernée. **Architecture V2 ne supporte aucun modèle LLM cloud et aucun fournisseur d'inférence LLM en ligne.** Une demande de routage cloud échoue explicitement. Les outils Web restent autorisés comme sources d'information ; le raisonnement LLM reste local.

## Architecture V2 — flotte locale B580

La flotte opérationnelle contient exactement trois modèles routés Q4_K_M :

| Alias logique | Runtime local | Taille registre indicative | Usage nominal |
|---|---|---:|---|
| `qwen-max` | `qwen3.5:9b-q4_K_M` | ~6,6 Go | orchestration, recherche, sécurité, release, multimodal |
| `gemma-deep` | `gemma4:12b-it-q4_K_M` | ~7,6 Go | architecture, rédaction, audit, multimodal |
| `devstral-devops` | `hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M` | ~8,24 Go | DevOps, code, dépôts, tool-calling, raisonnement |

`devstral-devops` reste un alias logique de compatibilité. En V2, il pointe vers **Ministral 3 14B Reasoning Q4_K_M**, exécuté localement depuis le GGUF officiel Mistral AI. Le spécialiste est text-only dans le contrat ; les besoins image/PDF sont pris en charge par Qwen 3.5 ou Gemma 4 puis transmis par un handoff traçable.

Un quatrième modèle est déclaré séparément pour la comparaison locale de sélection du spécialiste :

```text
granite-devops -> granite4.2:8b-q4_K_M
```

Granite 4.2 8B est **challenger de modèle uniquement** : il n'est pas routé, ne compte pas dans les trois modèles opérationnels et ne peut pas être promu automatiquement.

## Accélération GPU B580 : Vulkan uniquement

Le choix du backend GPU est arrêté. Le projet actif ne maintient qu'une voie d'accélération LLM : **Vulkan**.

- `ollama-vulkan` — profil OpenClaw nominal et rollback ;
- `llama-cpp-vulkan` — runtime géré interne pour Gemma 4 et Ministral dans le profil hybride ;
- `b580-hybrid` — profil OpenClaw explicite, toujours 100 % Vulkan : Qwen sur Ollama/Vulkan, Gemma + Ministral sur llama.cpp/Vulkan.

Il n'existe plus de campagne de sélection entre API GPU dans le projet actif. La qualification matérielle vérifie que la voie Vulkan choisie fonctionne correctement sur la B580 réelle ; elle ne cherche pas à choisir un autre backend.

## Contextes : qualification et orchestration séparées

```text
8192  -> contexte nominal du HARD-40M
16384 -> contexte nominal d'orchestration OpenClaw pour les agents
>16K  -> aucune promotion nominale sans qualification dédiée
```

Le contexte OpenClaw à 16384 **n'est pas une promotion du benchmark**. Aucune montée automatique à 32K n'est autorisée.

## Huit rôles

```text
chef-operations             -> Qwen 3.5 9B
expert-recherche            -> Qwen 3.5 9B + outils Web
architecte-solutions        -> Gemma 4 12B
ingenieur-devops            -> Ministral 3 14B Reasoning
ingenieur-securite          -> Qwen 3.5 9B
ingenieur-release-forges    -> Qwen 3.5 9B
redacteur-technique         -> Gemma 4 12B
auditeur-qualite            -> Gemma 4 12B
                               -> Qwen 3.5 9B si séparation de famille requise
```

Les rôles restent distincts et soumis à leurs scopes d'outils. Le Workspace Guard, la séparation producteur/auditeur et les gates V1 restent fail-closed.

## Architecture générale

```text
Consignes / PDF / images / Office / code / ZIP
                     |
                     v
          Project Intake durci
  SHA-256 / MIME / liens / secrets / ACL
                     |
                     v
         Document Ingestion locale
                     |
                     v
          Project Orchestrator
 ANALYZE -> CLARIFY -> PLAN -> ASSIGN
 -> EXECUTE -> VALIDATE -> REVIEW -> PACKAGE
                     |
                     v
        Artifact Exchange versionné
                     |
                     v
          OpenClaw / Gateway local
                     |
             8 agents spécialisés
                     |
      +--------------+-------------------+
      |              |                   |
   Qwen 3.5       Gemma 4       Ministral 3 Reasoning
      |              |                   |
      +--------------+-------------------+
                     |
             Vulkan / Intel Arc B580
                     |
               preuves locales
```

## Prérequis

- Windows 11 Pro x64 ;
- PowerShell 7+ ;
- WinGet ;
- Git ;
- connexion Internet uniquement pour le bootstrap, les mises à jour, le téléchargement initial des modèles et les outils Web explicitement utilisés ;
- espace disque suffisant pour les modèles, runtimes et preuves.

Python, Node.js, OpenClaw et Ollama sont contrôlés par le runtime lock du dépôt.

## Installation

```powershell
git clone https://github.com/mathiasseguincadiche/OPENCLAW_LOCAL.git
cd OPENCLAW_LOCAL

.\menu.ps1 -Action install-full -DryRun
.\menu.ps1 -Action install-full
```

Par défaut, la plateforme gérée est placée sous `E:\AI\OpenClawLocal` si `E:` existe, sinon sous `%LOCALAPPDATA%\OpenClawLocal`. `OPENCLAW_LOCAL_ROOT` peut surcharger cet emplacement.

Sur une installation existante après changement de flotte :

```powershell
git pull
.\menu.ps1 -Action configure-local
.\scripts\windows\03_pull_models.ps1
```

Les anciens modèles éventuellement présents dans le cache Ollama ne sont plus routés par le catalogue actif. Leur présence dans le cache ne constitue pas un fallback supporté.

## Vérification opérateur

```powershell
.\menu.ps1 -Action audit
.\menu.ps1 -Action verify
.\menu.ps1 -Action e2e
```

Ces commandes doivent notamment vérifier : runtime verrouillé, Ollama sur loopback, trois modèles requis, huit agents OpenClaw, inférence locale, tool-calling, voie GPU Vulkan et absence de route LLM cloud.

Pour le profil B580 hybride Vulkan :

```powershell
.\menu.ps1 -Action intel-vulkan-setup -DryRun
.\menu.ps1 -Action intel-vulkan-setup
.\menu.ps1 -Action intel-vulkan-verify
.\menu.ps1 -Action configure-openclaw -Backend b580-hybrid -DryRun
.\menu.ps1 -Action configure-openclaw -Backend b580-hybrid
.\menu.ps1 -Action e2e -Backend b580-hybrid
```

Le rollback reste :

```powershell
.\menu.ps1 -Action configure-openclaw -Backend ollama-vulkan
.\menu.ps1 -Action intel-vulkan-stop
```

Voir [Backends](docs/RUNTIME_BACKENDS.md).

## Qualification matérielle

```powershell
.\menu.ps1 -Action qualification -DryRun
.\menu.ps1 -Action qualification
```

Le **HARD-40M reste inchangé** : 30 cas, dont 24 à 8K et 6 à 16K, avec les seuils existants. Aucun seuil n'est abaissé par Architecture V2.

Le mode diagnostic reste :

```powershell
.\menu.ps1 -Action qualification -Quick
```

Les trois modèles routés sont obligatoires. Un échec de l'un d'eux fait échouer la flotte. Granite possède une comparaison de modèle séparée et ne peut pas servir de contournement.

La qualification ne remet pas le choix Vulkan en compétition : elle valide le fonctionnement, la stabilité et les limites du chemin retenu sur la workstation réelle.

Voir [Qualification](docs/QUALIFICATION.md) et [Benchmark](docs/BENCHMARK.md).

## Golden Projects pré-V1

```powershell
.\menu.ps1 -Action golden -DryRun
.\menu.ps1 -Action golden
```

Les scénarios couvrent notamment documents techniques, exigences contradictoires, pipeline cassé, remédiation et prompt injection. Ils ne remplacent pas le projet représentatif final ni la revue humaine.

## Principes de sécurité et de qualité

- **LLM local-only** ;
- **Vulkan seul pour l'accélération GPU LLM B580** ;
- **fail-closed** ;
- **aucun fournisseur LLM cloud** ;
- **aucun fallback LLM en ligne** ;
- **Intake immuable** ;
- **ZIP/Office bornés et sûrs** ;
- **Workspace Guard** appliqué par le code ;
- **REQ -> tâche -> sortie -> preuve -> verdict** ;
- **séparation producteur/auditeur** ;
- **télémétrie locale privacy-safe** ;
- **publication gouvernée** ;
- **approbation humaine finale** ;
- **aucune performance matérielle inventée par CI**.

## Machine d'états projet

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

La transition finale exige une approbation humaine.

## Documentation

- [État du projet](STATUS.md)
- [Modèles locaux](docs/MODELES_LOCAUX.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Installation Windows 11](docs/INSTALLATION_WINDOWS_11.md)
- [Intégration OpenClaw](docs/OPENCLAW_INTEGRATION.md)
- [Routage local](docs/ROUTAGE_HYBRIDE.md)
- [Backends](docs/RUNTIME_BACKENDS.md)
- [Qualification](docs/QUALIFICATION.md)
- [Benchmark](docs/BENCHMARK.md)
- [Opérations](docs/OPERATIONS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)

## V1.0.0

La version `1.0.0` reste bloquée tant que la workstation réelle n'a pas fourni toutes les preuves requises : HARD-40M, OpenClaw E2E, voie Vulkan gérée, Golden Projects, multimodalité, télémétrie, projet représentatif, limites documentées et approbation humaine UTC.

Le manifeste `config/v1/release_readiness.yaml` reste fail-closed. Aucun changement de flotte ou de runtime ne contourne cette exigence.
