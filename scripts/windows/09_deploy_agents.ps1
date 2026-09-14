[CmdletBinding()]
param([switch]$DryRun)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$AgentsRoot = Join-Path $RepoRoot 'agents'
$SharedRoot = Join-Path $AgentsRoot '_shared'
$ContractPath = Join-Path $SharedRoot 'CONTRACT.md'
$PedagogyPath = Join-Path $SharedRoot 'PEDAGOGY.md'
$RuntimeContractPath = Join-Path $SharedRoot 'RUNTIME_CONTRACT.md'
$BootstrapFileBudgetChars = 6500
$BootstrapBudgetChars = 8000
$BootstrapTotalBudgetChars = $BootstrapBudgetChars
$AgentIds = @(
    'chef-operations',
    'expert-recherche',
    'architecte-solutions',
    'ingenieur-devops',
    'ingenieur-securite',
    'ingenieur-release-forges',
    'redacteur-technique',
    'auditeur-qualite'
)

function Get-PlatformRoot {
    if ($env:OPENCLAW_LOCAL_ROOT) {
        return $env:OPENCLAW_LOCAL_ROOT
    }
    if (Test-Path -LiteralPath 'E:\') {
        return 'E:\AI\OpenClawLocal'
    }
    return (Join-Path $env:LOCALAPPDATA 'OpenClawLocal')
}

foreach ($RequiredShared in @($ContractPath, $PedagogyPath, $RuntimeContractPath)) {
    if (-not (Test-Path -LiteralPath $RequiredShared)) {
        throw "Contrat partagé introuvable: $RequiredShared"
    }
}

$PlatformRoot = Get-PlatformRoot
$WorkspacesRoot = Join-Path $PlatformRoot 'workspaces'
$RuntimeContract = Get-Content -Raw -LiteralPath $RuntimeContractPath
$Tools = Get-Content -Raw -LiteralPath (Join-Path $SharedRoot 'TOOLS.md')
$Heartbeat = Get-Content -Raw -LiteralPath (Join-Path $SharedRoot 'HEARTBEAT.md')
$UserTemplate = @'
# Utilisateur

Ce workspace est public et reproductible. Aucune donnée personnelle, secret, préférence privée ou mémoire utilisateur ne doit être ajoutée ici automatiquement.

Les informations propres à l'opérateur restent dans l'état runtime local non versionné.
'@

foreach ($AgentId in $AgentIds) {
    $Source = Join-Path $AgentsRoot $AgentId
    $Workspace = Join-Path $WorkspacesRoot $AgentId
    $Marker = Join-Path $Workspace '.openclaw-local-managed'

    foreach ($Required in @('AGENTS.md', 'SOUL.md', 'IDENTITY.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Source $Required))) {
            throw "Source agent incomplète: $AgentId/$Required"
        }
    }

    if ((Test-Path -LiteralPath $Workspace) -and -not (Test-Path -LiteralPath $Marker)) {
        throw "Workspace non géré déjà présent: $Workspace. Refus d'écrasement."
    }

    $RoleAgents = Get-Content -Raw -LiteralPath (Join-Path $Source 'AGENTS.md')
    $Soul = Get-Content -Raw -LiteralPath (Join-Path $Source 'SOUL.md')
    $Identity = Get-Content -Raw -LiteralPath (Join-Path $Source 'IDENTITY.md')
    $MergedAgents = @"
# Contrat runtime OPENCLAW_LOCAL

$RuntimeContract

---

# Contrat spécifique du rôle

$RoleAgents
"@

    # OpenClaw 2026.9.4 injecte encore AGENTS.md et TOOLS.md. SOUL/USER/
    # HEARTBEAT/IDENTITY restent matérialisés dans le workspace, mais le patch
    # géré les exclut explicitement de l'injection automatique pour économiser
    # le budget prompt. Les skill cards nominales sont également désactivées
    # explicitement par le renderer final.
    $InjectedBootstrapChars = $MergedAgents.Length + $Tools.Length
    if ($MergedAgents.Length -gt $BootstrapFileBudgetChars) {
        throw (
            "Budget fichier bootstrap OpenClaw dépassé pour ${AgentId}: " +
            "$($MergedAgents.Length) > $BootstrapFileBudgetChars caractères dans AGENTS.md."
        )
    }
    if ($InjectedBootstrapChars -gt $BootstrapTotalBudgetChars) {
        throw (
            "Budget bootstrap OpenClaw dépassé pour ${AgentId}: " +
            "$InjectedBootstrapChars > $BootstrapTotalBudgetChars caractères injectés."
        )
    }

    if ($DryRun) {
        Write-Host (
            "[DRY-RUN] Déployer $AgentId -> $Workspace avec pédagogie transversale compacte " +
            "(${InjectedBootstrapChars}/${BootstrapTotalBudgetChars} caractères runtime injectés; " +
            'SOUL/USER/HEARTBEAT/IDENTITY conservés mais non auto-injectés)'
        )
        continue
    }

    New-Item -ItemType Directory -Path $Workspace -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Workspace 'AGENTS.md') -Value $MergedAgents -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Workspace 'SOUL.md') -Value $Soul -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Workspace 'IDENTITY.md') -Value $Identity -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Workspace 'TOOLS.md') -Value $Tools -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Workspace 'HEARTBEAT.md') -Value $Heartbeat -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Workspace 'USER.md') -Value $UserTemplate -Encoding utf8

    # Références complètes disponibles à la demande mais non auto-injectées par OpenClaw.
    Copy-Item -LiteralPath $ContractPath -Destination (Join-Path $Workspace 'CONTRACT.md') -Force
    Copy-Item -LiteralPath $PedagogyPath -Destination (Join-Path $Workspace 'PEDAGOGY.md') -Force

    Set-Content -LiteralPath $Marker -Value "managed_by=OPENCLAW_LOCAL`nagent=$AgentId" -Encoding utf8
    Write-Host (
        "OK  $AgentId déployé: pédagogie transversale compacte + références complètes " +
        "(${InjectedBootstrapChars}/${BootstrapTotalBudgetChars} caractères runtime injectés; " +
        'fichiers facultatifs conservés hors injection automatique).'
    )
}

exit 0
