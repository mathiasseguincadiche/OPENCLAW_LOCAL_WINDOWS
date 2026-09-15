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

function Get-OpenClawCommand {
    param([Parameter(Mandatory)][string]$PlatformRoot)

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

function Invoke-ProcessEnvironmentValue {
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$Value
    )

    if ($null -eq $Value) {
        Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue
    }
    else {
        Set-Item -LiteralPath "Env:$Name" -Value $Value
    }
}

$PlatformRoot = Get-PlatformRoot
$CanonicalStateDir = Join-Path $PlatformRoot 'state'
$ProofsRoot = Join-Path $PlatformRoot 'proofs'
$ConfigPath = Join-Path $CanonicalStateDir 'openclaw.json'
$ProxyUrl = "http://127.0.0.1:$ProxyPort"

if ($DryRun) {
    Write-Host '[DRY-RUN] Diagnostic ciblé du transport full-agent OpenClaw -> proxy local -> provider Ollama sélectionné.'
    Write-Host "[DRY-RUN] Agent=$AgentId timeout=${TimeoutSeconds}s proxy=$ProxyUrl."
    Write-Host "[DRY-RUN] Config canonique attendue: $ConfigPath"
    Write-Host '[DRY-RUN] Résoudre le provider depuis le préfixe du modèle primaire (ollama ou ollama-ministral).'
    Write-Host '[DRY-RUN] Une copie temporaire de la config sera créée; state/openclaw.json ne sera pas modifié.'
    Write-Host '[DRY-RUN] OPENCLAW_STATE_DIR pointera vers un état temporaire isolé pour ne pas entrer en conflit avec un Gateway actif.'
    Write-Host '[DRY-RUN] Vérifier la config effectivement résolue et la baseUrl proxy avant l appel agent.'
    Write-Host '[DRY-RUN] Conserver stdout, stderr, capture proxy et résumé JSON même si aucune requête /api/chat n atteint le proxy.'
    exit 0
}

$OpenClaw = Get-OpenClawCommand -PlatformRoot $PlatformRoot
$Python = Get-ClawLocalManagedPython -PlatformRoot $PlatformRoot

if (-not (Test-Path -LiteralPath $ProxyScript)) {
    throw "Proxy de diagnostic introuvable: $ProxyScript"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration OpenClaw absente: $ConfigPath"
}

$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$Agent = Get-AgentEntry -Config $Config -Id $AgentId
$ModelRef = [string]$Agent.model.primary
$SeparatorIndex = $ModelRef.IndexOf('/')
if ($SeparatorIndex -le 0 -or $SeparatorIndex -ge ($ModelRef.Length - 1)) {
    throw "Référence modèle primaire invalide pour ${AgentId}: $ModelRef"
}
$ProviderId = $ModelRef.Substring(0, $SeparatorIndex)
$PrimaryModel = $ModelRef.Substring($SeparatorIndex + 1)
$ProviderProperty = $Config.models.providers.PSObject.Properties[$ProviderId]
if (-not $ProviderProperty -or -not $ProviderProperty.Value) {
    throw "Provider OpenClaw absent pour ${AgentId}: $ProviderId"
}
$OriginalBaseUrl = [string]$ProviderProperty.Value.baseUrl
if ($OriginalBaseUrl -notmatch '^http://127\.0\.0\.1:(11434|11436)/?$') {
    throw "Base URL Ollama locale inattendue pour ${ProviderId}: $OriginalBaseUrl"
}
$ProviderConfigPath = "models.providers.$ProviderId.baseUrl"

try {
    $null = Invoke-RestMethod -Method Get -Uri "$($OriginalBaseUrl.TrimEnd('/'))/api/tags" -TimeoutSec 3
}
catch {
    throw "Provider Ollama non prêt sur $OriginalBaseUrl : $($_.Exception.Message)"
}

if (Get-NetTCPConnection -State Listen -LocalPort $ProxyPort -ErrorAction SilentlyContinue) {
    throw "Port de proxy déjà occupé: 127.0.0.1:$ProxyPort"
}

New-Item -ItemType Directory -Path $ProofsRoot -Force | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
$TempConfigPath = Join-Path $ProofsRoot ".openclaw_transport_${Stamp}.json"
$DiagnosticStateDir = Join-Path $ProofsRoot ".openclaw_transport_state_${Stamp}"
$CapturePath = Join-Path $ProofsRoot "openclaw_transport_${Stamp}.jsonl"
$SummaryPath = Join-Path $ProofsRoot "openclaw_transport_${Stamp}.summary.json"
$ProxyStdoutPath = Join-Path $ProofsRoot ".openclaw_transport_proxy_${Stamp}.stdout.tmp"
$ProxyStderrPath = Join-Path $ProofsRoot ".openclaw_transport_proxy_${Stamp}.stderr.tmp"
$AgentStdoutPath = Join-Path $ProofsRoot "openclaw_transport_agent_${Stamp}.stdout.txt"
$AgentStderrPath = Join-Path $ProofsRoot "openclaw_transport_agent_${Stamp}.stderr.txt"
$SessionKey = "transport-capture-$Stamp-$AgentId"
$Expected = "TRANSPORT_CAPTURE_OK $AgentId"
$Prompt = "N'utilise aucun outil. Réponds immédiatement en une ligne avec exactement: $Expected"

New-Item -ItemType Directory -Path $DiagnosticStateDir -Force | Out-Null
$TempConfig = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$TempProviderProperty = $TempConfig.models.providers.PSObject.Properties[$ProviderId]
if (-not $TempProviderProperty -or -not $TempProviderProperty.Value) {
    throw "Provider absent de la copie temporaire: $ProviderId"
}
$TempProviderProperty.Value.baseUrl = $ProxyUrl
$TempConfig | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $TempConfigPath -Encoding utf8

$EnvNames = @(
    'OPENCLAW_CONFIG_PATH',
    'OPENCLAW_STATE_DIR',
    'OLLAMA_API_KEY',
    'OPENCLAW_LOCAL_CLOUD_ENABLED',
    'OPENCLAW_CONFIG_READONLY'
)
$OriginalEnv = @{}
foreach ($Name in $EnvNames) {
    $OriginalEnv[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process')
}

$ProxyProcess = $null
$ExitCode = $null
$ResolvedConfigPath = ''
$ResolvedBaseUrl = ''
try {
    $ProxyProcess = Start-Process -FilePath $Python -ArgumentList @(
        $ProxyScript,
        '--listen-host', '127.0.0.1',
        '--listen-port', [string]$ProxyPort,
        '--upstream', $OriginalBaseUrl,
        '--output', $CapturePath
    ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $ProxyStdoutPath `
        -RedirectStandardError $ProxyStderrPath

    $Ready = $false
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
        }
        else { '' }
        throw "Proxy de diagnostic non prêt. stderr=$ProxyError"
    }

    Invoke-ProcessEnvironmentValue -Name 'OPENCLAW_CONFIG_PATH' -Value $TempConfigPath
    Invoke-ProcessEnvironmentValue -Name 'OPENCLAW_STATE_DIR' -Value $DiagnosticStateDir
    Invoke-ProcessEnvironmentValue -Name 'OLLAMA_API_KEY' -Value 'ollama-local'
    Invoke-ProcessEnvironmentValue -Name 'OPENCLAW_LOCAL_CLOUD_ENABLED' -Value 'false'
    Invoke-ProcessEnvironmentValue -Name 'OPENCLAW_CONFIG_READONLY' -Value '1'

    $ConfigFileRaw = (& $OpenClaw 'config' 'file' '--json' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Lecture du chemin de config OpenClaw en échec: $ConfigFileRaw"
    }
    $ResolvedConfigPath = [string](($ConfigFileRaw | ConvertFrom-Json).path)

    $BaseUrlRaw = (& $OpenClaw 'config' 'get' $ProviderConfigPath '--json' 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Lecture de $ProviderConfigPath en échec: $BaseUrlRaw"
    }
    $ResolvedBaseUrl = [string]($BaseUrlRaw | ConvertFrom-Json)

    Write-Host "TRANSPORT_CAPTURE_AGENT=$AgentId"
    Write-Host "TRANSPORT_CAPTURE_REQUESTED_MODEL=$ModelRef"
    Write-Host "TRANSPORT_CAPTURE_PROVIDER=$ProviderId"
    Write-Host "TRANSPORT_CAPTURE_UPSTREAM=$OriginalBaseUrl"
    Write-Host "TRANSPORT_CAPTURE_CONFIG_PATH=$ResolvedConfigPath"
    Write-Host "TRANSPORT_CAPTURE_STATE_DIR=$DiagnosticStateDir"
    Write-Host "TRANSPORT_CAPTURE_BASE_URL=$ResolvedBaseUrl"
    Write-Host "TRANSPORT_CAPTURE_PROXY=$ProxyUrl"
    Write-Host "TRANSPORT_CAPTURE_SESSION=$SessionKey"

    if ([IO.Path]::GetFullPath($ResolvedConfigPath) -ne [IO.Path]::GetFullPath($TempConfigPath)) {
        throw "OpenClaw n'utilise pas la config temporaire attendue. Résolu=$ResolvedConfigPath Attendu=$TempConfigPath"
    }
    if ($ResolvedBaseUrl.TrimEnd('/') -ne $ProxyUrl) {
        throw "OpenClaw ne résout pas la base URL proxy attendue. Résolu=$ResolvedBaseUrl Attendu=$ProxyUrl"
    }

    & $OpenClaw 'agent' '--local' '--agent' $AgentId `
        '--session-key' $SessionKey '--message' $Prompt '--thinking' 'off' `
        '--timeout' ([string]$TimeoutSeconds) '--json' 1> $AgentStdoutPath 2> $AgentStderrPath
    $ExitCode = $LASTEXITCODE
}
finally {
    foreach ($Name in $OriginalEnv.Keys) {
        Invoke-ProcessEnvironmentValue -Name $Name -Value $OriginalEnv[$Name]
    }
    if ($ProxyProcess -and -not $ProxyProcess.HasExited) {
        Stop-Process -Id $ProxyProcess.Id -Force -ErrorAction SilentlyContinue
        $ProxyProcess.WaitForExit(5000) | Out-Null
    }
    Remove-Item -LiteralPath $TempConfigPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $DiagnosticStateDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ProxyStdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $ProxyStderrPath -Force -ErrorAction SilentlyContinue
}

$AgentStdout = if (Test-Path -LiteralPath $AgentStdoutPath) {
    Get-Content -Raw -LiteralPath $AgentStdoutPath
}
else { '' }
$AgentStderr = if (Test-Path -LiteralPath $AgentStderrPath) {
    Get-Content -Raw -LiteralPath $AgentStderrPath
}
else { '' }
$Records = @(
    if (Test-Path -LiteralPath $CapturePath) {
        Get-Content -LiteralPath $CapturePath |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_ | ConvertFrom-Json }
    }
)

$PrimaryRecords = @($Records | Where-Object { [string]$_.request.model -eq $PrimaryModel })
$RecordCount = @($Records).Count
$PrimaryRecordCount = @($PrimaryRecords).Count

[ordered]@{
    schema_version = '1.2.0'
    timestamp_utc = [DateTime]::UtcNow.ToString('o')
    agent = $AgentId
    requested_provider = $ProviderId
    requested_model_ref = $ModelRef
    requested_model = $PrimaryModel
    upstream_base_url = $OriginalBaseUrl
    session_key = $SessionKey
    diagnostic_state_dir = $DiagnosticStateDir
    resolved_config_path = $ResolvedConfigPath
    resolved_provider_base_url = $ResolvedBaseUrl
    openclaw_exit_code = $ExitCode
    request_count = $RecordCount
    primary_request_count = $PrimaryRecordCount
    capture_path = $CapturePath
    agent_stdout_path = $AgentStdoutPath
    agent_stderr_path = $AgentStderrPath
    agent_stdout_chars = $AgentStdout.Length
    agent_stderr_chars = $AgentStderr.Length
    requests = $Records
} | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $SummaryPath -Encoding utf8

foreach ($Record in $Records) {
    $Roles = @($Record.request.roles) -join ' -> '
    Write-Host "TRANSPORT_CAPTURE_REQUEST path=$($Record.path) http=$($Record.response_status) model=$($Record.request.model) roles=[$Roles]"
}

Write-Host "TRANSPORT_CAPTURE_OPENCLAW_EXIT_CODE=$ExitCode"
Write-Host "TRANSPORT_CAPTURE_REQUESTS=$RecordCount"
Write-Host "TRANSPORT_CAPTURE_PRIMARY_REQUESTS=$PrimaryRecordCount"
Write-Host "TRANSPORT_CAPTURE_EVIDENCE=$SummaryPath"
Write-Host "TRANSPORT_CAPTURE_STDOUT=$AgentStdoutPath"
Write-Host "TRANSPORT_CAPTURE_STDERR=$AgentStderrPath"

if ($RecordCount -eq 0) {
    if ($AgentStderr) {
        Write-Host 'TRANSPORT_CAPTURE_STDERR_TAIL_BEGIN'
        Write-Host $AgentStderr.Substring([Math]::Max(0, $AgentStderr.Length - [Math]::Min(4000, $AgentStderr.Length)))
        Write-Host 'TRANSPORT_CAPTURE_STDERR_TAIL_END'
    }
    throw 'Aucune requête n a atteint le proxy; les preuves stdout/stderr ont été conservées.'
}
