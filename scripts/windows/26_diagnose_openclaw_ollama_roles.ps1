[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$AgentId = 'ingenieur-devops',
    [ValidateRange(30, 300)][int]$TimeoutSeconds = 120,
    [ValidateRange(1025, 65535)][int]$ProxyPort = 11435
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ProxyScript = Join-Path $RepoRoot 'scripts\54_capture_ollama_request_roles.py'
$PythonRuntime = Join-Path $PSScriptRoot 'lib\python_runtime.ps1'

if (-not (Test-Path -LiteralPath $PythonRuntime)) {
    throw "Helper runtime Python géré introuvable: $PythonRuntime"
}
. $PythonRuntime

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
    throw 'OpenClaw absent. Exécutez install-core.'
}

function Get-AgentEntry {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Id
    )
    $Entries = $Config.agents.PSObject.Properties['entries']
    if ($Entries -and $Entries.Value) {
        $Entry = $Entries.Value.PSObject.Properties[$Id]
        if ($Entry -and $Entry.Value) {
            return $Entry.Value
        }
    }
    $List = $Config.agents.PSObject.Properties['list']
    if ($List -and $List.Value) {
        $Entry = @($List.Value | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
        if ($Entry) {
            return $Entry
        }
    }
    throw "Agent absent de la configuration OpenClaw: $Id"
}

function Set-ProcessEnvValue {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'None')]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$Value
    )

    if (-not $PSCmdlet.ShouldProcess("Process environment variable $Name", 'Set or clear')) {
        return
    }
    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -LiteralPath "Env:$Name" -Value $Value
    }
}

$PlatformRoot = Get-PlatformRoot
$StateDir = Join-Path $PlatformRoot 'state'
$ProofsRoot = Join-Path $PlatformRoot 'proofs'
$ConfigPath = Join-Path $StateDir 'openclaw.json'
$OpenClaw = Get-OpenClawCommand $PlatformRoot

if (-not (Test-Path -LiteralPath $ProxyScript)) {
    throw "Proxy de diagnostic introuvable: $ProxyScript"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration OpenClaw absente: $ConfigPath"
}

$Python = Get-ClawLocalManagedPython -PlatformRoot $PlatformRoot
$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$Agent = Get-AgentEntry -Config $Config -Id $AgentId
$ModelRef = [string]$Agent.model.primary
$OllamaProvider = $Config.models.providers.PSObject.Properties['ollama']
if (-not $OllamaProvider -or -not $OllamaProvider.Value) {
    throw 'Provider Ollama absent de la configuration OpenClaw.'
}
$OriginalBaseUrl = [string]$OllamaProvider.Value.baseUrl
if ($OriginalBaseUrl -notmatch '^http://127\.0\.0\.1:11434/?$') {
    throw "Base URL Ollama inattendue pour ce diagnostic: $OriginalBaseUrl"
}
$OllamaTagsUri = "$($OriginalBaseUrl.TrimEnd('/'))/api/tags"

$ProxyUrl = "http://127.0.0.1:$ProxyPort"
if ($DryRun) {
    Write-Host '[DRY-RUN] Diagnostic non destructif de la séquence de rôles OpenClaw -> Ollama.'
    Write-Host "[DRY-RUN] Agent=$AgentId modèle=$ModelRef timeout=${TimeoutSeconds}s."
    Write-Host "[DRY-RUN] Vérifier d'abord que le backend Ollama répond sur $OllamaTagsUri."
    Write-Host "[DRY-RUN] Créer une copie temporaire de $ConfigPath avec models.providers.ollama.baseUrl=$ProxyUrl."
    Write-Host '[DRY-RUN] Sélectionner cette copie via OPENCLAW_CONFIG_PATH; ne jamais réécrire openclaw.json.'
    Write-Host '[DRY-RUN] Le proxy journalise uniquement rôles, tailles, noms d outils et paramètres de forme; aucun texte de prompt.'
    Write-Host '[DRY-RUN] Exécuter le même openclaw agent --local que le gate d admission, avec une session fraîche.'
    exit 0
}

try {
    $null = Invoke-RestMethod -Method Get -Uri $OllamaTagsUri -TimeoutSec 3
    Write-Host "OK  Backend Ollama prêt pour le diagnostic: $OllamaTagsUri"
}
catch {
    throw (
        "Backend Ollama non prêt pour le diagnostic sur $OllamaTagsUri : {0}. " +
        "Exécutez .\menu.ps1 -Action configure-local puis relancez ce diagnostic."
    ) -f $_.Exception.Message
}

if (Get-NetTCPConnection -State Listen -LocalPort $ProxyPort -ErrorAction SilentlyContinue) {
    throw "Port de proxy déjà occupé: 127.0.0.1:$ProxyPort"
}

New-Item -ItemType Directory -Path $ProofsRoot -Force | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
$TempConfigPath = Join-Path $ProofsRoot ".openclaw_role_capture_${Stamp}.json"
$CapturePath = Join-Path $ProofsRoot "openclaw_ollama_role_capture_${Stamp}.jsonl"
$SummaryPath = Join-Path $ProofsRoot "openclaw_ollama_role_capture_${Stamp}.summary.json"
$ProxyStdoutPath = Join-Path $ProofsRoot ".openclaw_role_proxy_${Stamp}.stdout.tmp"
$ProxyStderrPath = Join-Path $ProofsRoot ".openclaw_role_proxy_${Stamp}.stderr.tmp"
$AgentStdoutPath = Join-Path $ProofsRoot ".openclaw_role_agent_${Stamp}.stdout.tmp"
$AgentStderrPath = Join-Path $ProofsRoot ".openclaw_role_agent_${Stamp}.stderr.tmp"
$SessionKey = "role-capture-$Stamp-$AgentId"
$Expected = "ROLE_CAPTURE_OK $AgentId"
$Prompt = "N'utilise aucun outil. Réponds immédiatement en une ligne avec exactement: $Expected"

$TempConfig = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$TempConfig.models.providers.ollama.baseUrl = $ProxyUrl
$TempConfig | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $TempConfigPath -Encoding utf8

$OriginalEnv = @{}
foreach ($Name in @('OPENCLAW_CONFIG_PATH', 'OPENCLAW_STATE_DIR', 'OLLAMA_API_KEY', 'OPENCLAW_LOCAL_CLOUD_ENABLED')) {
    $OriginalEnv[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
}

$ProxyProcess = $null
$ExitCode = $null
$AgentStdout = ''
$AgentStderr = ''
try {
    $ProxyArgs = @(
        $ProxyScript,
        '--listen-host', '127.0.0.1',
        '--listen-port', [string]$ProxyPort,
        '--upstream', 'http://127.0.0.1:11434',
        '--output', $CapturePath
    )
    $ProxyProcess = Start-Process -FilePath $Python -ArgumentList $ProxyArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $ProxyStdoutPath -RedirectStandardError $ProxyStderrPath

    $Ready = $false
    $ProxyOutput = ''
    $Deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $Deadline) {
        if ($ProxyProcess.HasExited) {
            break
        }
        if (Test-Path -LiteralPath $ProxyStdoutPath) {
            $ProxyOutput = Get-Content -Raw -LiteralPath $ProxyStdoutPath -ErrorAction SilentlyContinue
            if ($ProxyOutput -match 'ROLE_CAPTURE_READY=') {
                $Ready = $true
                break
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $Ready) {
        $ProxyError = if (Test-Path -LiteralPath $ProxyStderrPath) {
            Get-Content -Raw -LiteralPath $ProxyStderrPath
        } else { '' }
        throw "Proxy de diagnostic non prêt. stdout=$ProxyOutput stderr=$ProxyError"
    }

    Set-ProcessEnvValue -Name 'OPENCLAW_CONFIG_PATH' -Value $TempConfigPath
    Set-ProcessEnvValue -Name 'OPENCLAW_STATE_DIR' -Value $StateDir
    Set-ProcessEnvValue -Name 'OLLAMA_API_KEY' -Value 'ollama-local'
    Set-ProcessEnvValue -Name 'OPENCLAW_LOCAL_CLOUD_ENABLED' -Value 'false'

    Write-Host "ROLE_CAPTURE_AGENT=$AgentId"
    Write-Host "ROLE_CAPTURE_REQUESTED_MODEL=$ModelRef"
    Write-Host "ROLE_CAPTURE_PROXY=$ProxyUrl"
    Write-Host "ROLE_CAPTURE_SESSION=$SessionKey"

    & $OpenClaw 'agent' '--local' '--agent' $AgentId `
        '--session-key' $SessionKey '--message' $Prompt '--thinking' 'off' `
        '--timeout' ([string]$TimeoutSeconds) '--json' 1> $AgentStdoutPath 2> $AgentStderrPath
    $ExitCode = $LASTEXITCODE

    if (Test-Path -LiteralPath $AgentStdoutPath) {
        $AgentStdout = (Get-Content -Raw -LiteralPath $AgentStdoutPath).Trim()
    }
    if (Test-Path -LiteralPath $AgentStderrPath) {
        $AgentStderr = (Get-Content -Raw -LiteralPath $AgentStderrPath).Trim()
    }
}
finally {
    foreach ($Name in $OriginalEnv.Keys) {
        Set-ProcessEnvValue -Name $Name -Value $OriginalEnv[$Name]
    }
    if ($ProxyProcess -and -not $ProxyProcess.HasExited) {
        Stop-Process -Id $ProxyProcess.Id -Force -ErrorAction SilentlyContinue
        $ProxyProcess.WaitForExit(5000) | Out-Null
    }
    Remove-Item -LiteralPath $TempConfigPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AgentStdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $AgentStderrPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ProxyStdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ProxyStderrPath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $CapturePath)) {
    throw 'Aucune requête /api/chat capturée pendant le diagnostic.'
}

$Records = @(
    Get-Content -LiteralPath $CapturePath |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_ | ConvertFrom-Json }
)
if ($Records.Count -eq 0) {
    throw 'Capture Ollama vide.'
}

$PrimaryModel = if ($ModelRef.StartsWith('ollama/')) { $ModelRef.Substring(7) } else { $ModelRef }
$PrimaryRecords = @($Records | Where-Object { [string]$_.request.model -eq $PrimaryModel })
$Primary500 = @($PrimaryRecords | Where-Object { [int]$_.response_status -eq 500 }).Count -gt 0

foreach ($Record in $Records) {
    $Roles = @($Record.request.roles) -join ' -> '
    $Duplicates = @($Record.request.duplicate_non_tool_roles).Count
    Write-Host (
        'ROLE_CAPTURE_REQUEST model={0} http={1} roles=[{2}] duplicate_non_tool_roles={3} tools={4}' -f `
            [string]$Record.request.model,
            [string]$Record.response_status,
            $Roles,
            $Duplicates,
            [string]$Record.request.tool_count
    )
}

[ordered]@{
    schema_version = '1.0.0'
    timestamp_utc = [DateTime]::UtcNow.ToString('o')
    agent = $AgentId
    requested_model_ref = $ModelRef
    requested_model = $PrimaryModel
    session_key = $SessionKey
    openclaw_exit_code = $ExitCode
    primary_request_count = $PrimaryRecords.Count
    primary_http_500 = $Primary500
    capture_path = $CapturePath
    requests = $Records
    agent_stdout = $AgentStdout
    agent_stderr = $AgentStderr
} | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $SummaryPath -Encoding utf8

Write-Host "ROLE_CAPTURE_OPENCLAW_EXIT_CODE=$ExitCode"
Write-Host "ROLE_CAPTURE_PRIMARY_REQUESTS=$($PrimaryRecords.Count)"
Write-Host "ROLE_CAPTURE_PRIMARY_HTTP500=$Primary500"
Write-Host "ROLE_CAPTURE_EVIDENCE=$SummaryPath"
Write-Host "ROLE_CAPTURE_RAW=$CapturePath"

if ($PrimaryRecords.Count -eq 0) {
    throw "Aucune requête capturée pour le modèle primaire: $PrimaryModel"
}
