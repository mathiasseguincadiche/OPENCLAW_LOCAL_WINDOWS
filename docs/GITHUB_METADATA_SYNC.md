# Synchronisation des métadonnées GitHub

Architecture V2 est **LLM local-only**. La description et les topics publics du dépôt doivent refléter ce contrat et ne doivent plus annoncer d'escalade LLM cloud ni `openrouter`.

## Cible

Description :

> Plateforme IA multi-agents local-only côté LLM pour Windows 11 : OpenClaw + Ollama, routage local hybride et qualification Intel Arc B580.

Topics :

```text
openclaw
ollama
local-ai
local-llm
multi-agent
windows-11
intel-arc
powershell
python
devops
llm
```

## Synchronisation

Le helper `scripts/windows/25_sync_github_metadata.ps1` utilise GitHub CLI avec la session du propriétaire du dépôt. Il est volontairement en lecture seule sans `-Apply`.

Prévisualisation :

```powershell
.\scripts\windows\25_sync_github_metadata.ps1
```

Application :

```powershell
.\scripts\windows\25_sync_github_metadata.ps1 -Apply
```

Prérequis :

```powershell
gh auth login
gh auth status
```

Le script met à jour la description et remplace la liste des topics par la cible versionnée, puis relit GitHub et échoue si la vérification post-écriture ne correspond pas exactement à la cible.

Ce helper existe parce que l'automatisation de code du dépôt n'a pas vocation à conserver un jeton d'administration GitHub dans CI. L'opération reste donc explicite, effectuée avec la session GitHub du propriétaire, et traçable par l'issue administrative dédiée.
