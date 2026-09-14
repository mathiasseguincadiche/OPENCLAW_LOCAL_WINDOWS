# Intégration OpenClaw

## Objectif

`OPENCLAW_LOCAL` matérialise huit rôles versionnés dans OpenClaw, avec workspaces séparés, outils bornés, projets synchronisés et routage **LLM strictement local**. Architecture V2 ne configure aucun fournisseur LLM cloud et toute demande de routage cloud échoue fail-closed.

Les outils Web restent autorisés comme sources d'information. Ils ne changent pas le backend de raisonnement : les agents continuent d'utiliser la flotte locale.

Sur l'Intel Arc B580, **Vulkan est l'unique accélération GPU LLM supportée**.

## Sources de vérité

- `config/v1/runtime_versions.json` : versions des runtimes locaux ;
- `config/v1/model_catalog.yaml` : exactement trois modèles locaux routés + challenger local séparé ;
- `config/v1/model_routing.yaml` : routes nominales et fallbacks dans la flotte fermée ;
- `config/v1/runtime_backends.yaml` : profils Vulkan actifs ;
- `config/v1/tool_policy.yaml` : permissions par rôle ;
- `config/v1/web_policy.yaml` : outils Web local-first ;
- `config/v1/document_ingestion_policy.yaml` : PDF/images/Office/texte ;
- `agents/*` : identité et contrat des huit rôles ;
- `src/clawlocal/openclaw_config.py` : génération du patch OpenClaw.

## Runtime OpenClaw verrouillé

Le lock V2 actuel fixe **OpenClaw 2026.9.4** avec le plugin Parallel officiel aligné sur **2026.9.4**. Le projet n'installe ni `main` ni une version flottante.

```text
OpenClaw      : 2026.9.4
release SHA   : 3a9d69db306cd7f081e06254cb89c4bcc14a7107
npm SRI       : sha512-lTQpEEe1Xm3u2PCHaPEr+vP8paGk1vLdHuzdItsNToaLI6hAqRVvgJYg+GxukJhETJp4tPy/S1Gftl4KuB8n7A==
Parallel      : @openclaw/parallel-plugin@2026.9.4
Parallel SRI  : sha512-/6XIzmiF1iJtXzKYZxO+v92xTzOvTnSQJh89tTQfpZkyk5SxsaQtBAeBwFT7sv3blGIYhGEVhs3+hf4rKVIqtA==
```

Après une modification du lock runtime :

```powershell
.\menu.ps1 -Action install-core
openclaw --version
```

`configure-openclaw` vérifie la version verrouillée avant toute mutation.

## Compatibilité spécifique OpenClaw 2026.9.4

Le projet exploite les comportements 2026.9.4 de façon conservatrice :

- **Node.js 26.1.0 est le runtime préféré** du lock local : `openclaw@2026.9.4` exige `>=26.1.0` sur la branche Node 26 ; le ZIP Windows x64 est verrouillé par SHA-256 ;
- l'état OpenClaw de la plateforme reste volontairement relocalisé sous `<OPENCLAW_LOCAL_ROOT>\state` au lieu du répertoire canonique sous le home du compte Windows ;
- OpenClaw 2026.9.4 refuse volontairement `gateway install/start` pour un état/config non canonique. `OPENCLAW_LOCAL` n'essaie donc plus de détourner le service natif : `scripts/windows/26_gateway_external_supervisor.ps1` installe un **superviseur externe Windows Task Scheduler** qui exécute le runtime géré avec `openclaw gateway run` ;
- le processus supervisé reçoit explicitement `OPENCLAW_SUPERVISOR_MODE=external`, `OPENCLAW_SERVICE_REPAIR_POLICY=external`, `OPENCLAW_STATE_DIR=<root>\state` et `OPENCLAW_CONFIG_PATH=<root>\state\openclaw.json` ;
- le wrapper externe reste propriétaire du cycle de vie : il relance `gateway run` après une sortie avec backoff, tandis qu'une mise à niveau arrête d'abord l'instance existante avant de remplacer le script et la définition de tâche ;
- `install-full` conserve ensuite la readiness RPC bornée et échoue avec diagnostic si le Gateway n'est pas réellement prêt ;
- `openclaw@2026.9.4` et `@openclaw/parallel-plugin@2026.9.4` ont chacun un SRI SHA-512 exact dans le runtime lock ;
- `scripts/50_verify_npm_integrities.py` refuse le core ou le plugin si `runtime lock`, `npm dist.integrity` et le SHA-512 recalculé du tarball ne sont pas strictement identiques ;
- ce même contrôle est exécuté par la CI et par le job de validation du workflow de release avant construction/publication ;
- le bootstrap continue de calculer localement le SHA-512 du tarball OpenClaw et refuse l'installation si le SRI ne correspond pas au lock ;
- une montée de version sur un état existant doit être précédée d'une **sauvegarde vérifiée** : le rollback applicatif OpenClaw ne remplace pas la restauration des données lorsqu'une migration de données a eu lieu.

### Fenêtre d'écriture `OPENCLAW_CONFIG_READONLY`

`OPENCLAW_CONFIG_READONLY=1` est désormais l'état d'exploitation stable géré par le projet. La bibliothèque `scripts/windows/lib/openclaw_readonly.ps1` impose le contrat fail-closed suivant :

1. avant configuration, les niveaux **Process** et **User** sont forcés puis vérifiés à `1` ;
2. seule la variable du **Process courant** passe temporairement à `0` ; la valeur User persistante doit rester à `1` ;
3. baseline, convergence des plugins et patch OpenClaw s'exécutent dans cette fenêtre ;
4. un bloc `finally` remet Process et User à `1` puis vérifie cet état ;
5. toute impossibilité de restaurer/vérifier `1` provoque un échec ;
6. `install-full` réexige l'état stable avant l'installation du superviseur externe, avant son démarrage et en fin d'installation ; le Gateway supervisé lui-même reçoit `OPENCLAW_CONFIG_READONLY=1`.

L'action opérateur `menu.ps1 -Action configure-openclaw` passe par `08_configure_openclaw_guarded.ps1`. `08_configure_openclaw.ps1` est le moteur interne de mutation et n'est pas l'entrée opérateur à appeler directement.

### Admission full-agent sans faux positif de fallback

Le gate nominal des trois familles est fail-closed sur le modèle réellement gagnant. Pour chaque agent de contrôle, le script lit `meta.agentMeta.provider/model`, exige qu'il corresponde exactement au primaire configuré et refuse toute trace de fallback (`executionTrace.fallbackUsed` ou `agentMeta.fallbackAttempts`). Une réponse réussie d'un modèle local de secours ne peut donc pas être comptabilisée comme réussite du primaire demandé.

Le gate continue en parallèle d'exiger `systemPromptReport.skills.promptChars=0` et la réponse déterministe attendue.

## Flotte locale active V2

```text
qwen-max          -> ollama/qwen3.5:9b-q4_K_M
gemma-deep        -> ollama/gemma4:12b-it-q4_K_M
devstral-devops   -> ollama/hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M
```

`devstral-devops` est un alias de compatibilité : son runtime V2 est Ministral 3 14B Reasoning Q4_K_M. La flotte routée reste exactement à trois modèles.

Challenger de modèle séparé :

```text
granite-devops -> granite4.2:8b-q4_K_M
```

Il n'est pas injecté dans le routage OpenClaw nominal et ne peut pas être auto-promu.

## Profils runtime OpenClaw

Les profils sélectionnables sont seulement :

```text
ollama-vulkan
b580-hybrid
```

Le runtime interne `llama-cpp-vulkan` est utilisé par `b580-hybrid` pour Gemma et Ministral, mais n'est pas exposé comme profil OpenClaw autonome.

Répartition hybride :

```text
qwen-max        -> Ollama/Vulkan
gemma-deep      -> llama.cpp/Vulkan
devstral-devops -> llama.cpp/Vulkan
image/PDF       -> Ollama/Vulkan
```

Aucun profil ne permet de sélectionner une autre API GPU.

## Contrat de contexte : qualification 8K, agent OpenClaw 16K

- **8192 tokens** : contexte nominal du HARD-40M ;
- **16384 tokens** : fenêtre d'exécution nominale du full-agent OpenClaw sur Ollama afin d'absorber prompt système, contrat du rôle, réserve et surface d'outils autorisée.

Cette fenêtre OpenClaw 16K **n'est pas une promotion du benchmark** et ne constitue aucune preuve de performance ou de full-offload sur la B580. Les seuils HARD-40M restent inchangés.

Le provider Ollama amont peut accepter une capacité supérieure, mais `OPENCLAW_LOCAL` conserve 16K comme valeur nominale gérée tant que la B580 n'a pas fourni de preuve justifiant une extension.

Le runtime llama.cpp/Vulkan géré conserve son propre contexte 8192 selon le contrat actuel du profil hybride.

## Budget du prompt runtime

La surface runtime reste bornée :

- le contrat compact `RUNTIME_CONTRACT.md` + le rôle sont injectés via `AGENTS.md` ;
- `CONTRACT.md` et `PEDAGOGY.md` complets restent disponibles à la demande ;
- `SOUL.md`, `USER.md`, `HEARTBEAT.md` et `IDENTITY.md` restent matérialisés mais exclus de l'injection automatique ;
- `AGENTS.md` reste plafonné à 6500 caractères et le bootstrap runtime géré à 8000 caractères ;
- chaque agent géré reçoit explicitement `skills: []` ;
- `skills.limits.maxSkillsPromptChars=0` constitue le hard-stop nominal de rendu des skills ;
- les profils d'outils partent de `minimal` et réautorisent uniquement les capacités nécessaires ;
- `tools.toolSearch` en mode structuré `tools` diffère les schémas non essentiels ;
- `experimental.localModelLean=true` reste activé pour les agents locaux.

La politique de sécurité reste : workspace-only, `exec` soumis au contrat d'approbation, elevated désactivé et rôles de revue non mutateurs.

## Contrat multimodal

- `qwen-max` et `gemma-deep` acceptent texte + image dans le parcours Ollama ;
- `devstral-devops` / Ministral Reasoning est **text-only** dans le contrat nominal ;
- `imageModel` et `pdfModel` utilisent `qwen-max`, avec `gemma-deep` en fallback local ;
- lorsqu'une tâche DevOps provient d'un PDF ou d'une image, l'ingestion multimodale est effectuée localement avant le handoff textuel vers le spécialiste.

Aucun document n'est transmis à un modèle LLM en ligne par la plateforme V2.

## Contrat de schéma OpenClaw

Le générateur produit le roster sous la surface d'entrée compatible :

```text
agents.list[]
```

OpenClaw 2026.9.x peut persister ce roster sous :

```text
agents.entries.<agent-id>
```

Le roster est explicitement déclaré `agents.ownership=explicit`. `chef-operations` est déclaré comme propriétaire ambiant et de session via `agents.defaults.systemAgent.agentId` et `agents.defaults.sessionStore.agentId`.

Le E2E accepte `agents.entries` et la surface de compatibilité `agents.list` pour lire l'état.

## Générer et appliquer la configuration

Nominal :

```powershell
.\menu.ps1 -Action configure-openclaw -DryRun
.\menu.ps1 -Action configure-openclaw
```

Hybride Vulkan :

```powershell
.\menu.ps1 -Action intel-vulkan-setup
.\menu.ps1 -Action intel-vulkan-verify
.\menu.ps1 -Action configure-openclaw -Backend b580-hybrid -DryRun
.\menu.ps1 -Action configure-openclaw -Backend b580-hybrid
```

Le parcours :

1. vérifie le profil local sélectionné ;
2. exige la version OpenClaw verrouillée ;
3. converge le plugin Web requis ;
4. crée la baseline OpenClaw si nécessaire ;
5. capture le schéma vivant ;
6. déploie les huit workspaces gérés ;
7. génère le patch depuis les contrats ;
8. exécute le dry-run du patch ;
9. applique le patch uniquement si la validation réussit ;
10. exécute `openclaw config validate --json` ;
11. vérifie `openclaw agents list --json` ;
12. sur `ollama-vulkan`, exécute un vrai prompt full-agent sur Qwen 3.5, Gemma 4 et Ministral 3 Reasoning avant PASS, sans accepter qu'un fallback local masque l'échec du primaire.

Les listes gérées sont remplacées intentionnellement via :

```text
--replace-path models.providers
--replace-path agents.list
```

Le patch nominal configure notamment Gateway loopback, Ollama local, exactement trois modèles routés, huit agents, outils bornés et **aucun provider LLM cloud**.

## Workspaces et projets

```text
<OPENCLAW_LOCAL_ROOT>\models\ollama
<OPENCLAW_LOCAL_ROOT>\workspaces\<agent-id>
<OPENCLAW_LOCAL_ROOT>\projects\<project-id>
```

Les workspaces sont des snapshots jetables et ne remplacent jamais le projet central.

## Document Ingestion et Artifact Exchange

L'ingestion construit des représentations locales traçables sans modifier les originaux. Les sorties des tâches sont versionnées sous `context/exchange/`. Une sortie `PASS` peut être propagée ; une sortie `FAIL` reste historique.

## Routage nominal

```text
Chef opérations       -> qwen-max
Expert recherche      -> qwen-max + outils Web
Architecte solutions  -> gemma-deep
Ingénieur DevOps      -> devstral-devops
Ingénieur sécurité    -> qwen-max
Release/Forges        -> qwen-max
Rédacteur technique   -> gemma-deep
Auditeur qualité      -> gemma-deep
                         -> qwen-max si producteur Gemma
```

Tous les fallbacks restent dans la flotte locale fermée.

## Gate E2E

Nominal :

```powershell
.\menu.ps1 -Action e2e -DryRun
.\menu.ps1 -Action e2e
```

Hybride :

```powershell
.\menu.ps1 -Action e2e -Backend b580-hybrid -DryRun
.\menu.ps1 -Action e2e -Backend b580-hybrid
```

Le test doit prouver les huit agents, le provider local attendu, le modèle primaire conforme, le vrai tool-calling, la réparation après erreur d'outil, la stabilité et l'absence de dépendance LLM cloud.

## Promotion

Un succès d'admission, E2E ou challenger ne promeut automatiquement ni modèle, ni contexte 32K, ni profil hybride, ni V1. Le choix GPU Vulkan est déjà verrouillé ; les preuves servent à valider son exploitation réelle, pas à rouvrir une compétition de backends.
