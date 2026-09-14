[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$AllowRuntimeDrift,
    [switch]$SkipGatewayService,
    [ValidateRange(5, 300)][int]$GatewayReadyTimeoutSeconds = 90,
    [ValidateRange(1, 10000)][int]$GatewayPollIntervalMilliseconds = 2000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$env:OPENCLAW_LOCAL_REPO_ROOT = $RepoRoot
$Bootstrap = Join-Path $PSScriptRoot '00_bootstrap.ps1'
$ConfigureOllama = Join-Path $PSScriptRoot '02_configure_local.ps1'
$PullModels = Join-Path $PSScriptRoot '03_pull_models.ps1'
$ConfigureOpenClaw = Join-Path $PSScriptRoot '08_configure_openclaw.ps1'
$VerifyLocal = Join-Path $PSScriptRoot '04_verify_local.ps1'
$GatewayHealth = Join-Path $PSScriptRoot 'lib\gateway_health.ps1'
$PlatformBackup = Join-Path $PSScriptRoot 'lib\platform_backup.ps1'
$ReadOnlyGuard = Join-Path $PSScriptRoot 'lib\openclaw_readonly.ps1'

foreach ($Library in @($GatewayHealth, $PlatformBackup, $ReadOnlyGuard)) {
    if (-not (Test-Path -LiteralPath $Library)) {
        throw "Bibliothèque d'installation introuvable: $Library"
    }
    . $Library
}

function Get-PlatformRoot {
    if ($env:OPENCLAW_LOCAL_ROOT) { return $env:OPENCLAW_LOCAL_ROOT }
    if (Test-Path -LiteralPath 'E:\') { return 'E:\AI\OpenClawLocal' }
    return (Join-Path $env:LOCALAPPDATA 'OpenClawLocal')
}

function Invoke-ScriptChecked {
    param(
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Parameters = @{},
        [Parameter(Mandatory)][string]$Description
    )
    & $Path @Parameters
    if ($LASTEXITCODE -ne 0) { throw "$Description (code $LASTEXITCODE)." }
}

function Get-OpenClawCommand([string]$PlatformRoot) {
    $Found = Get-Command openclaw -ErrorAction SilentlyContinue
    if ($Found) { return $Found.Source }
    $Managed = Join-Path $PlatformRoot 'runtime\npm-global\openclaw.cmd'
    if (Test-Path -LiteralPath $Managed) { return $Managed }
    throw 'OpenClaw est introuvable après bootstrap.'
}

$PlatformRoot = Get-PlatformRoot

if ($DryRun) {
    Write-Host '[DRY-RUN] Si projects/state/proofs existent, créer et vérifier un backup SHA256 avant toute mutation.'
    Write-Host "[DRY-RUN] Racine backup: $(Join-Path $PlatformRoot 'backup\pre-upgrade-<UTC>')"
    Invoke-ScriptChecked -Path $Bootstrap -Parameters @{ DryRun = $true; AllowRuntimeDrift = $AllowRuntimeDrift } -Description 'Dry-run bootstrap'
    Invoke-ScriptChecked -Path $ConfigureOllama -Parameters @{ DryRun = $true } -Description 'Dry-run Ollama'
    Invoke-ScriptChecked -Path $PullModels -Parameters @{ DryRun = $true } -Description 'Dry-run modèles'
    Write-Host '[DRY-RUN] Dans la fenêtre d écriture, exécuter openclaw doctor --fix --non-interactive avant configure-openclaw afin de migrer les états legacy supportés.'
    Invoke-ScriptChecked -Path $ConfigureOpenClaw -Parameters @{ DryRun = $true } -Description 'Dry-run OpenClaw'
    Write-Host '[DRY-RUN] Fenêtre contrôlée: process READONLY=0 uniquement pendant doctor/configure-openclaw; User reste READONLY=1.'
    Write-Host '[DRY-RUN] Après configuration, process + User doivent être READONLY=1 avant Gateway install/start.'
    Write-Host "[DRY-RUN] Readiness RPC bornée: timeout=${GatewayReadyTimeoutSeconds}s, intervalle=${GatewayPollIntervalMilliseconds}ms."
    Write-Host '[DRY-RUN] Aucune mutation réalisée.'
    exit 0
}

$BackupResult = New-OpenClawPreUpgradeBackup -PlatformRoot $PlatformRoot
if ($null -ne $BackupResult -and -not [bool]$BackupResult.verified) {
    throw 'Installation refusée: le backup pré-upgrade existe mais n est pas vérifié.'
}

Invoke-ScriptChecked -Path $Bootstrap -Parameters @{ AllowRuntimeDrift = $AllowRuntimeDrift } -Description 'Bootstrap runtime'
Invoke-ScriptChecked -Path $ConfigureOllama -Description 'Configuration Ollama'
Invoke-ScriptChecked -Path $PullModels -Description 'Téléchargement des modèles'

$OpenClaw = Get-OpenClawCommand $PlatformRoot
$env:OPENCLAW_STATE_DIR = Join-Path $PlatformRoot 'state'
$env:OLLAMA_API_KEY = 'ollama-local'
$env:OPENCLAW_LOCAL_CLOUD_ENABLED = 'false'

Invoke-OpenClawConfigWriteWindow -Operation {
    & $OpenClaw doctor --fix --non-interactive
    if ($LASTEXITCODE -ne 0) {
        throw 'Migration OpenClaw doctor --fix --non-interactive en échec.'
    }
    Write-Host 'OK  Migrations OpenClaw supportées convergées via doctor --fix --non-interactive.'

    Invoke-ScriptChecked -Path $ConfigureOpenClaw -Description 'Configuration OpenClaw'
}
Assert-OpenClawReadOnlySteadyState

if (-not $SkipGatewayService) {
    Assert-OpenClawReadOnlySteadyState
    & $OpenClaw gateway install --runtime node --force --json
    if ($LASTEXITCODE -ne 0) { throw 'Installation du service Gateway OpenClaw en échec.' }

    Assert-OpenClawReadOnlySteadyState
    & $OpenClaw gateway start --json
    if ($LASTEXITCODE -ne 0) { throw 'Démarrage du service Gateway OpenClaw en échec.' }

    $Readiness = Wait-OpenClawGatewayReady -OpenClaw $OpenClaw -TimeoutSeconds $GatewayReadyTimeoutSeconds -PollIntervalMilliseconds $GatewayPollIntervalMilliseconds
    if (-not $Readiness.ready) {
        $DiagnosticPath = Write-OpenClawGatewayDiagnostic -OpenClaw $OpenClaw -PlatformRoot $PlatformRoot -Readiness $Readiness
        Write-Host "GATEWAY_FAILURE_CLASS=$($Readiness.failure_class)"
        Write-Host "GATEWAY_DIAGNOSTIC=$DiagnosticPath"
        throw "Gateway OpenClaw non prêt après $($Readiness.elapsed_seconds) s. Classification=$($Readiness.failure_class). Diagnostic=$DiagnosticPath"
    }
}

Invoke-ScriptChecked -Path $VerifyLocal -Description 'Vérification Ollama'
Assert-OpenClawReadOnlySteadyState
Write-Host 'OK  Installation complète OPENCLAW_LOCAL terminée.'
Write-Host "Repo: $RepoRoot"
if ($null -ne $BackupResult) { Write-Host "Backup vérifié: $($BackupResult.path)" }
Write-Host 'Config runtime: OPENCLAW_CONFIG_READONLY=1 (Process + User)'
Write-Host 'Étape suivante: .\menu.ps1 -Action e2e puis .\menu.ps1 -Action qualification.'
exit 0
