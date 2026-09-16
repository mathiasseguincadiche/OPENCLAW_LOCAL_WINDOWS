[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet('ollama-vulkan', 'b580-hybrid')]
    [string]$Backend = 'ollama-vulkan'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$DeployScript = Join-Path $PSScriptRoot '09_deploy_agents.ps1'
$PromptAdmissionScript = Join-Path $PSScriptRoot '24_test_openclaw_prompt_admission.ps1'
$Renderer = Join-Path $RepoRoot 'scripts\26_render_openclaw_config.py'
$RuntimeLockPath = Join-Path $RepoRoot 'config\v1\runtime_versions.json'
$LegacyStateMigration = Join-Path $PSScriptRoot 'lib\openclaw_legacy_state.ps1'

function Get-PlatformRoot {
    if ($env:OPENCLAW_LOCAL_ROOT) {
        return $env:OPENCLAW_LOCAL_ROOT
    }
    if (Test-Path -LiteralPath 'E:\') {
        return 'E:\AI\OpenClawLocal'
    }
    return (Join-Path $env:LOCALAPPDATA 'OpenClawLocal')
}

function Get-OpenClawCommand([string]$PlatformRoot) {
    $Found = Get-Command openclaw -ErrorAction SilentlyContinue
    if ($Found) {
        return $Found.Source
    }
    $Managed = Join-Path $PlatformRoot 'runtime\npm-global\openclaw.cmd'
    if (Test-Path -LiteralPath $Managed) {
        return $Managed
    }
    throw 'OpenClaw est absent. Exécutez en premier .\menu.ps1 -Action install-core.'
}

function Get-PythonCommand([string]$PlatformRoot) {
    $Managed = Join-Path $PlatformRoot 'runtime\venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $Managed) {
        return $Managed
    }
    $Found = Get-Command python -ErrorAction SilentlyContinue
    if ($Found) {
        return $Found.Source
    }
    throw 'Python clawlocal est absent. Exécutez en premier install-core.'
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Description
    )
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description (code $LASTEXITCODE)."
    }
}

function Assert-OpenClawVersion {
    param(
        [Parameter(Mandatory)][string]$OpenClaw,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    $Actual = (& $OpenClaw '--version' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Impossible de lire la version OpenClaw: $Actual"
    }
    if ($Actual -notmatch [regex]::Escape($ExpectedVersion)) {
        throw (
            "Runtime OpenClaw inattendu. Attendu=$ExpectedVersion Reçu=$Actual. " +
            'Exécutez .\menu.ps1 -Action install-core avant configure-openclaw.'
        )
    }
    Write-Host "OK  OpenClaw verrouillé: $Actual"
}

function Invoke-OpenClawLegacyStateMigration {
    param([Parameter(Mandatory)][string]$ConfigPath)

    if (-not (Test-Path -LiteralPath $LegacyStateMigration)) {
        throw "Migration état OpenClaw introuvable: $LegacyStateMigration"
    }
    & $LegacyStateMigration -ConfigPath $ConfigPath
}

function Get-PluginInventory {
    param([Parameter(Mandatory)][string]$OpenClaw)

    $Output = & $OpenClaw 'plugins' 'list' '--json'
    if ($LASTEXITCODE -ne 0) {
        throw "Lecture de l'inventaire plugins OpenClaw en échec (code $LASTEXITCODE)."
    }
    $Text = ($Output | Out-String).Trim()
    try {
        return ($Text | ConvertFrom-Json)
    }
    catch {
        throw 'L''inventaire plugins OpenClaw n''est pas un JSON valide.'
    }
}

function Initialize-ParallelSearchPlugin {
    param(
        [Parameter(Mandatory)][string]$OpenClaw,
        [Parameter(Mandatory)][string]$LockPath
    )

    if (-not (Test-Path -LiteralPath $LockPath)) {
        throw "Contrat runtime introuvable: $LockPath"
    }
    $Lock = Get-Content -Raw -LiteralPath $LockPath | ConvertFrom-Json
    $Parallel = $Lock.openclaw.plugins.parallel
    $PluginId = 'parallel'
    $Package = [string]$Parallel.package
    $Version = [string]$Parallel.preferred
    $Provider = [string]$Parallel.provider
    if (-not $Package -or -not $Version -or $Provider -ne 'parallel-free') {
        throw 'Contrat Parallel invalide dans runtime_versions.json.'
    }

    $Inventory = Get-PluginInventory -OpenClaw $OpenClaw
    $Plugin = @($Inventory.plugins | Where-Object { [string]$_.id -eq $PluginId })
    $Spec = "$Package@$Version"
    if ($Plugin.Count -eq 0) {
        Write-Host "Installation du plugin Web requis : npm:$Spec"
        Invoke-Checked -Command $OpenClaw -Arguments @(
            'plugins', 'install', "npm:$Spec", '--pin'
        ) -Description 'Installation du plugin Parallel'
    }
    else {
        Write-Host "Convergence du plugin Web requis : $Spec"
        Invoke-Checked -Command $OpenClaw -Arguments @(
            'plugins', 'update', $Spec
        ) -Description 'Mise à niveau du plugin Parallel'
    }

    $Inventory = Get-PluginInventory -OpenClaw $OpenClaw
    $Plugin = @($Inventory.plugins | Where-Object { [string]$_.id -eq $PluginId })
    if ($Plugin.Count -eq 0) {
        throw 'Plugin Parallel absent après installation/mise à niveau.'
    }

    if (-not [bool]$Plugin[0].enabled) {
        Invoke-Checked -Command $OpenClaw -Arguments @(
            'plugins', 'enable', $PluginId
        ) -Description 'Activation du plugin Parallel'
        $Inventory = Get-PluginInventory -OpenClaw $OpenClaw
        $Plugin = @($Inventory.plugins | Where-Object { [string]$_.id -eq $PluginId })
    }
    if ($Plugin.Count -eq 0 -or -not [bool]$Plugin[0].enabled) {
        throw 'Plugin Parallel installé mais non activé.'
    }

    $RuntimeProbe = & $OpenClaw 'plugins' 'inspect' $PluginId '--runtime' '--json'
    if ($LASTEXITCODE -ne 0) {
        throw "Chargement runtime du plugin Parallel en échec (code $LASTEXITCODE)."
    }
    try {
        $null = (($RuntimeProbe | Out-String).Trim() | ConvertFrom-Json)
    }
    catch {
        throw 'Le diagnostic runtime du plugin Parallel n''est pas un JSON valide.'
    }
    Write-Host "OK  Plugin Parallel $Version actif pour le provider $Provider."
}

function Test-OllamaReady {
    try {
        $null = Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 5
    }
    catch {
        throw "Backend Ollama non prêt: $($_.Exception.Message)"
    }
}

function Test-OllamaCompatReady {
    $HealthUrl = 'http://127.0.0.1:11436/__openclaw_compat_health'
    try {
        $Health = Invoke-RestMethod -Method Get -Uri $HealthUrl -TimeoutSec 5
    }
    catch {
        throw (
            "Proxy Ollama compat non prêt sur $HealthUrl : $($_.Exception.Message). " +
            'Exécutez .\scripts\windows\28_ollama_compat_supervisor.ps1 -Action install puis -Action start.'
        )
    }

    $ExpectedModel = 'hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M'
    if (
        $Health.ok -ne $true -or
        [string]$Health.model -ne $ExpectedModel -or
        [string]$Health.upstream -ne 'http://127.0.0.1:11434'
    ) {
        throw "Proxy Ollama compat actif mais contrat inattendu: $($Health | ConvertTo-Json -Compress)"
    }
    Write-Host 'OK  Proxy Ollama compat prêt pour Ministral/OpenClaw sur 127.0.0.1:11436.'
}

function Test-LlamaCppInventory {
    param(
        [Parameter(Mandatory)][string]$Endpoint,
        [Parameter(Mandatory)][string[]]$Expected,
        [Parameter(Mandatory)][string]$Label
    )

    try {
        $Inventory = Invoke-RestMethod -Method Get -Uri "$Endpoint/models?reload=1" -TimeoutSec 10
    }
    catch {
        throw "$Label non prêt sur $Endpoint. Détail: $($_.Exception.Message)"
    }
    $Ids = @($Inventory.data | ForEach-Object { [string]$_.id })
    foreach ($Model in $Expected) {
        if (-not ($Ids | Where-Object { $_ -ieq $Model })) {
            throw "$Label actif mais modèle requis absent: $Model (disponibles=$($Ids -join ','))."
        }
    }
}

function Test-SelectedBackendReady {
    param(
        [Parameter(Mandatory)][string]$BackendId,
        [Parameter(Mandatory)][string]$LockPath
    )

    if ($BackendId -eq 'ollama-vulkan') {
        Test-OllamaReady
        Test-OllamaCompatReady
        Write-Host 'OK  Backend texte sélectionné: ollama-vulkan + compat Ministral local.'
        return
    }

    $Lock = Get-Content -Raw -LiteralPath $LockPath | ConvertFrom-Json
    if ($BackendId -eq 'b580-hybrid') {
        Test-OllamaReady
        $ExpectedRuntimeModels = @(
            $Lock.llama_cpp_vulkan.managed_runtime_models |
                ForEach-Object { [string]$_ }
        )
        if ($ExpectedRuntimeModels.Count -ne 2) {
            throw 'Contrat managed_runtime_models Intel Vulkan invalide.'
        }
        Test-LlamaCppInventory -Endpoint ([string]$Lock.llama_cpp_vulkan.endpoint) `
            -Expected $ExpectedRuntimeModels `
            -Label 'Backend Intel Vulkan géré'
        Write-Host 'OK  Profil B580 hybride prêt: Qwen 3.5->Ollama/Vulkan, Gemma 4/Ministral Reasoning->llama.cpp/Vulkan.'
        Write-Host 'INFO Image/PDF restent intégralement sur Ollama/Vulkan via Qwen 3.5/Gemma 4.'
        return
    }

    throw "Backend OpenClaw non géré par le configurateur: $BackendId"
}

$PlatformRoot = Get-PlatformRoot
$StateDir = Join-Path $PlatformRoot 'state'
$SystemWorkspace = Join-Path $PlatformRoot 'workspaces\system'
$GeneratedDir = Join-Path $PlatformRoot 'runtime\generated'
$PatchPath = Join-Path $GeneratedDir "openclaw.$Backend.patch.json"
$SchemaPath = Join-Path $GeneratedDir 'openclaw.schema.json'
$RuntimeLock = Get-Content -Raw -LiteralPath $RuntimeLockPath | ConvertFrom-Json
$ExpectedOpenClawVersion = [string]$RuntimeLock.openclaw.preferred

if ($DryRun) {
    Write-Host '[DRY-RUN] Configuration OpenClaw local-only / Vulkan'
    Write-Host "Backend    : $Backend"
    Write-Host "OpenClaw   : $ExpectedOpenClawVersion (version verrouillée)"
    Write-Host "State      : $StateDir"
    Write-Host "Workspaces : $(Join-Path $PlatformRoot 'workspaces')"
    Write-Host "Patch      : $PatchPath"
    Write-Host "Schema     : $SchemaPath"
    if ($Backend -eq 'ollama-vulkan') {
        Write-Host '[DRY-RUN] Contexte nominal B580=8192; orchestration OpenClaw=16384 pour absorber réserve, système et outils.'
        Write-Host '[DRY-RUN] Tool Search structuré + profils minimaux par rôle réduisent les schémas injectés.'
        Write-Host '[DRY-RUN] Exiger le proxy local 127.0.0.1:11436; seul Ministral y est routé pour fusion user+user validée sur B580.'
        Write-Host '[DRY-RUN] Après application, contrôler réellement l admission des trois familles de modèles avant PASS.'
    }
    elseif ($Backend -eq 'b580-hybrid') {
        Write-Host '[DRY-RUN] Exiger Ollama/Vulkan + routeur llama.cpp/Vulkan géré prêt.'
        Write-Host '[DRY-RUN] Routage texte: Qwen 3.5 -> Ollama/Vulkan; Gemma 4 + Ministral 3 Reasoning -> llama.cpp/Vulkan; image/PDF -> Ollama/Vulkan.'
        Write-Host '[DRY-RUN] Vulkan est le choix GPU LLM verrouillé; ce contrôle valide la readiness/E2E, pas un nouveau choix de backend.'
        Write-Host '[DRY-RUN] Rollback explicite: .\menu.ps1 -Action configure-openclaw -Backend ollama-vulkan'
    }
    Write-Host '[DRY-RUN] Exiger la version OpenClaw verrouillée avant toute mutation de configuration.'
    Write-Host '[DRY-RUN] Pré-migrer uniquement les clés d''état 2026.7.x retirées, avec sauvegarde, avant toute commande CLI qui parse openclaw.json.'
    Write-Host '[DRY-RUN] Converger Parallel sur la version verrouillée avant validation runtime.'
    Write-Host '[DRY-RUN] Migration gérée: models.providers et agents.list sont remplacés exactement via --replace-path afin de retirer les anciens providers et IDs.'
    Write-Host '[DRY-RUN] Déployer 8 agents, capturer le schéma vivant, valider le patch avec --replace-path puis l''appliquer.'
    exit 0
}

$env:OPENCLAW_LOCAL_ROOT = $PlatformRoot
$env:OPENCLAW_STATE_DIR = $StateDir
$env:OLLAMA_API_KEY = 'ollama-local'
$env:INTEL_VULKAN_API_KEY = 'intel-vulkan-local'
$env:OPENCLAW_LOCAL_CLOUD_ENABLED = 'false'

Test-SelectedBackendReady -BackendId $Backend -LockPath $RuntimeLockPath

$OpenClaw = Get-OpenClawCommand $PlatformRoot
Assert-OpenClawVersion -OpenClaw $OpenClaw -ExpectedVersion $ExpectedOpenClawVersion
$Python = Get-PythonCommand $PlatformRoot
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
New-Item -ItemType Directory -Path $SystemWorkspace -Force | Out-Null
New-Item -ItemType Directory -Path $GeneratedDir -Force | Out-Null

$ConfigPath = Join-Path $StateDir 'openclaw.json'
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Invoke-Checked -Command $OpenClaw -Arguments @(
        'setup', '--baseline', '--workspace', $SystemWorkspace
    ) -Description 'Initialisation baseline OpenClaw'
}

Invoke-OpenClawLegacyStateMigration -ConfigPath $ConfigPath
Initialize-ParallelSearchPlugin -OpenClaw $OpenClaw -LockPath $RuntimeLockPath

$SchemaOutput = & $OpenClaw 'config' 'schema'
if ($LASTEXITCODE -ne 0) {
    throw "Lecture du schéma OpenClaw en échec (code $LASTEXITCODE)."
}
$SchemaText = ($SchemaOutput | Out-String).Trim()
try {
    $null = $SchemaText | ConvertFrom-Json
}
catch {
    throw 'Le schéma OpenClaw retourné par la CLI n''est pas un JSON valide.'
}
Set-Content -LiteralPath $SchemaPath -Value $SchemaText -Encoding utf8
Write-Host "OPENCLAW_SCHEMA=$SchemaPath"

& $DeployScript
if ($LASTEXITCODE -ne 0) {
    throw 'Déploiement des workspaces agents en échec.'
}

Invoke-Checked -Command $Python -Arguments @(
    $Renderer, '--platform-root', $PlatformRoot, '--backend', $Backend, '--output', $PatchPath
) -Description 'Génération du patch OpenClaw'

Invoke-Checked -Command $OpenClaw -Arguments @(
    'config', 'patch', '--file', $PatchPath, '--dry-run',
    '--replace-path', 'models.providers',
    '--replace-path', 'agents.list'
) -Description 'Validation dry-run du patch OpenClaw avec remplacement des chemins gérés'

Invoke-Checked -Command $OpenClaw -Arguments @(
    'config', 'patch', '--file', $PatchPath,
    '--replace-path', 'models.providers',
    '--replace-path', 'agents.list'
) -Description 'Application du patch OpenClaw avec remplacement des chemins gérés'

Invoke-Checked -Command $OpenClaw -Arguments @(
    'config', 'validate', '--json'
) -Description 'Validation finale de la configuration OpenClaw'

Invoke-Checked -Command $OpenClaw -Arguments @(
    'agents', 'list', '--json'
) -Description 'Lecture de la flotte OpenClaw'

if ($Backend -eq 'ollama-vulkan') {
    if (-not (Test-Path -LiteralPath $PromptAdmissionScript)) {
        throw "Contrôle d admission OpenClaw introuvable: $PromptAdmissionScript"
    }
    foreach ($AdmissionAgent in @('chef-operations', 'architecte-solutions', 'ingenieur-devops')) {
        & $PromptAdmissionScript -AgentId $AdmissionAgent -TimeoutSeconds 180
        if ($LASTEXITCODE -ne 0) {
            throw "Admission prompt OpenClaw en échec pour $AdmissionAgent."
        }
    }
    Write-Host 'OK  Admission prompt validée sur Qwen 3.5, Gemma 4 et Ministral 3 Reasoning.'
}
else {
    Write-Host 'INFO Le profil B580 hybride reste soumis à son E2E Vulkan avant validation d usage.'
}

Write-Host "OK  Configuration OpenClaw appliquée: backend texte=$Backend, 8 agents."
if ($Backend -eq 'b580-hybrid') {
    Write-Host 'INFO Rollback: .\menu.ps1 -Action configure-openclaw -Backend ollama-vulkan'
}
exit 0
