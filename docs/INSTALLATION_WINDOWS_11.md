# Installation Windows 11

## Préconditions

- Windows 11 Pro x64 ;
- PowerShell 7+ ;
- WinGet ;
- Git ;
- connexion Internet pour le bootstrap, les mises à jour, le téléchargement initial des modèles et les outils Web explicitement utilisés ;
- pilote Intel Arc à jour avant la qualification matérielle.

Python, Node.js, OpenClaw, Ollama et llama.cpp sont contrôlés par les locks versionnés du dépôt.

Architecture V2 est **LLM local-only** et utilise **Vulkan comme unique accélération GPU LLM sur la B580**. Les outils Web peuvent fournir des sources publiques, mais le raisonnement reste exécuté localement.

## Emplacement géré

Si `OPENCLAW_LOCAL_ROOT` n'est pas défini, `E:\AI\OpenClawLocal` est utilisé lorsque `E:` existe, sinon `%LOCALAPPDATA%\OpenClawLocal`.

La racine des modèles Ollama est :

```text
<OPENCLAW_LOCAL_ROOT>\models\ollama
```

Les scripts configurent `OLLAMA_MODELS` vers cette racine.

## Flotte opérationnelle Architecture V2

```text
qwen3.5:9b-q4_K_M
gemma4:12b-it-q4_K_M
hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M
```

Alias logiques :

```text
qwen-max        -> qwen3.5:9b-q4_K_M
gemma-deep      -> gemma4:12b-it-q4_K_M
devstral-devops -> hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M
```

Le HARD-40M utilise **8192 tokens** comme contexte nominal, avec six cas de stress à 16384. Le full-agent OpenClaw utilise séparément **16384 tokens** comme fenêtre nominale d'orchestration. Aucune promotion automatique à 32768 n'est autorisée.

## Challenger local séparé

```text
granite-devops -> granite4.2:8b-q4_K_M
```

Granite 4.2 8B est un challenger de **modèle** pour le spécialiste DevOps. Il n'est ni routé, ni fallback, ni compté parmi les trois modèles opérationnels, et il ne modifie pas la décision Vulkan.

Il n'est pas téléchargé par le parcours normal. Si la comparaison de modèle est nécessaire :

```powershell
ollama pull granite4.2:8b-q4_K_M
```

## Nouvelle installation

Depuis PowerShell 7 :

```powershell
git clone https://github.com/mathiasseguincadiche/OPENCLAW_LOCAL_WINDOWS.git
cd OPENCLAW_LOCAL_WINDOWS

.\menu.ps1 -Action install-full -DryRun
.\menu.ps1 -Action install-full
```

Le parcours complet :

1. installe/vérifie les runtimes verrouillés ;
2. crée le Python géré ;
3. configure la racine locale et `OLLAMA_MODELS` ;
4. démarre/vérifie Ollama sur loopback ;
5. télécharge exactement les trois modèles routés ;
6. génère la configuration OpenClaw local-only sur `ollama-vulkan` ;
7. déploie les huit workspaces agents ;
8. vérifie le Gateway et le parcours local.

Aucun échec local ne déclenche une bascule vers un modèle LLM en ligne.

## Migration d'une installation existante

```powershell
git checkout main
git pull

.\menu.ps1 -Action configure-local
.\scripts\windows\03_pull_models.ps1
.\menu.ps1 -Action audit
.\menu.ps1 -Action verify
```

Les anciens modèles présents sur disque peuvent rester temporairement pour diagnostic ou historique, mais ils ne sont plus supportés, routés ni considérés comme fallback.

## Installation des modèles routés uniquement

Dry-run :

```powershell
.\scripts\windows\03_pull_models.ps1 -DryRun
```

Réel :

```powershell
.\scripts\windows\03_pull_models.ps1
```

Le script lit `config/v1/model_catalog.yaml` et télécharge uniquement les entrées requises de `models:`. Les entrées `benchmark_challengers:` sont volontairement exclues.

## Vérification locale nominale

```powershell
.\menu.ps1 -Action audit
.\menu.ps1 -Action verify
```

Le smoke minimal appelle Ollama sur loopback, utilise le Python géré pour les contrôles d'identité et affiche les métriques `/api/ps` lorsqu'elles sont disponibles. Il ne vaut pas qualification matérielle.

## OpenClaw nominal

```powershell
.\menu.ps1 -Action configure-openclaw -DryRun
.\menu.ps1 -Action configure-openclaw
.\menu.ps1 -Action deploy-agents
.\menu.ps1 -Action e2e
```

Le profil nominal/rollback est `ollama-vulkan`.

## Runtime llama.cpp/Vulkan géré

Dry-run :

```powershell
.\menu.ps1 -Action intel-vulkan-setup -DryRun
```

Installation/démarrage et vérification :

```powershell
.\menu.ps1 -Action intel-vulkan-setup
.\menu.ps1 -Action intel-vulkan-verify
```

Le runtime géré :

- utilise la release llama.cpp verrouillée ;
- vérifie son archive par SHA-256 ;
- détecte la B580 via Vulkan ;
- écoute uniquement sur `127.0.0.1:8081/v1` ;
- utilise `models-max=1`, `parallel=1`, `gpu_layers=auto`, `fit=on` ;
- reste offline ;
- réutilise les blobs GGUF locaux exposés par Ollama ;
- gère Gemma 4 et Ministral 3 Reasoning pour le profil hybride.

## Profil B580 hybride Vulkan

```powershell
.\menu.ps1 -Action configure-openclaw -Backend b580-hybrid -DryRun
.\menu.ps1 -Action configure-openclaw -Backend b580-hybrid
.\menu.ps1 -Action e2e -Backend b580-hybrid
```

Répartition :

```text
qwen-max        -> Ollama/Vulkan
gemma-deep      -> llama.cpp/Vulkan
devstral-devops -> llama.cpp/Vulkan
image/PDF       -> Ollama/Vulkan
```

Ce profil est une voie d'exploitation à valider sur la workstation réelle. Il ne remet pas Vulkan en compétition avec une autre API GPU.

Rollback :

```powershell
.\menu.ps1 -Action configure-openclaw -Backend ollama-vulkan
.\menu.ps1 -Action intel-vulkan-stop
```

## Qualification des trois modèles routés

```powershell
.\menu.ps1 -Action e2e
.\menu.ps1 -Action qualification -DryRun
.\menu.ps1 -Action qualification
```

Les trois modèles sont obligatoires. Le HARD-40M conserve 30 cas, dont 24 à 8K et 6 à 16K, avec les seuils existants. Aucun PASS n'est inféré de la seule installation des modèles.

## Comparaison Ministral / Granite

Après installation explicite de Granite :

```powershell
.\scripts\windows\23_compare_model_challenger.ps1 -DryRun
.\scripts\windows\23_compare_model_challenger.ps1
```

Cette comparaison produit une preuve de sélection de **modèle** mais ne change jamais automatiquement la flotte et ne peut pas contourner un échec HARD-40M.

## Golden Projects

```powershell
.\menu.ps1 -Action golden -DryRun
.\menu.ps1 -Action golden
```

## Désinstallation / nettoyage

Avant de supprimer des modèles ou runtimes :

1. vérifier les trois modèles routés ;
2. vérifier `audit`/`verify` ;
3. conserver les preuves historiques utiles ;
4. ne pas supprimer `proofs/`, les états de qualification ou les projets utilisateur ;
5. arrêter le runtime llama.cpp/Vulkan géré avant suppression de son répertoire ;
6. ne supprimer Granite qu'après conservation de sa preuve comparative si elle a été utilisée pour une décision.

## Qualification B580

La CI prouve les contrats logiciels ; elle ne prouve ni la résidence VRAM, ni le débit, ni la stabilité matérielle de la flotte. Ces affirmations restent interdites tant qu'un run réel sur l'Intel Arc B580 n'a pas produit ses preuves avec le commit, les digests/quantifications, le runtime Vulkan, le pilote et les contextes correspondants.
