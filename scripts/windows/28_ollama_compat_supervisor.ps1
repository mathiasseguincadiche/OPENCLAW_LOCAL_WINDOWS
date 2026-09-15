[CmdletBinding()]
param(
    [ValidateSet('install', 'start', 'stop', 'status', 'run')]
    [string]$Action = 'status',
    [switch]$DryRun,
    [string]$PlatformRootOverride,
    [ValidateRange(5, 120)][int]$ReadyTimeoutSeconds = 30,
    [ValidateRange(5, 120)][int]$StopTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'OPENCLAW_LOCAL Ollama Compat'
$ListenPort = 11436
$HealthUrl = "http://127.0.0.1:$ListenPort/__openclaw_compat_health"
$ExpectedModel = 'hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M'
$ExpectedUpstream = 'http://127.0.0.1:11434'
$RestartBackoffSeconds = 2
$RequestedPlatformRoot = $PlatformRootOverride
$RequestedReadyTimeoutSeconds = $ReadyTimeoutSeconds
$RequestedStopTimeoutSeconds = $StopTimeoutSeconds

function Get-PlatformRoot {
    if (-not [string]::IsNullOrWhiteSpace($RequestedPlatformRoot)) {
        return $RequestedPlatformRoot
    }
    if ($env:OPENCLAW_LOCAL_ROOT) {
        return $env:OPENCLAW_LOCAL_ROOT
    }
    if (Test-Path -LiteralPath 'E:\') {
        return 'E:\AI\OpenClawLocal'
    }
    return (Join-Path $env:LOCALAPPDATA 'OpenClawLocal')
}

function Get-ManagedPythonCommand {
    param([Parameter(Mandatory)][string]$PlatformRoot)

    $Managed = Join-Path $PlatformRoot 'runtime\venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $Managed) {
        return $Managed
    }
    throw "Python géré OPENCLAW_LOCAL introuvable: $Managed"
}

function Get-PowerShell7Command {
    $Found = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($Found) {
        return $Found.Source
    }
    $Candidate = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $Candidate) {
        return $Candidate
    }
    throw 'PowerShell 7 (pwsh.exe) est requis pour le superviseur Ollama compat.'
}

function Get-InstalledSupervisorPath {
    param([Parameter(Mandatory)][string]$PlatformRoot)
    return (Join-Path $PlatformRoot 'runtime\ollama_compat_supervisor.ps1')
}

function Get-InstalledProxyPath {
    param([Parameter(Mandatory)][string]$PlatformRoot)
    return (Join-Path $PlatformRoot 'runtime\ollama_openclaw_compat_proxy.py')
}

function Test-OllamaCompatHealth {
    try {
        $Health = Invoke-RestMethod -Method Get -Uri $HealthUrl -TimeoutSec 2
    }
    catch {
        return $false
    }

    return (
        $Health.ok -eq $true -and
        [string]$Health.model -eq $ExpectedModel -and
        [string]$Health.upstream -eq $ExpectedUpstream
    )
}

function Install-OllamaCompatSupervisor {
    param([Parameter(Mandatory)][string]$PlatformRoot)

    foreach ($Required in @(
        'Get-ScheduledTask',
        'Get-ScheduledTaskInfo',
        'Register-ScheduledTask',
        'Start-ScheduledTask',
        'Stop-ScheduledTask',
        'New-ScheduledTask',
        'New-ScheduledTaskAction',
        'New-ScheduledTaskTrigger',
        'New-ScheduledTaskPrincipal',
        'New-ScheduledTaskSettingsSet'
    )) {
        if (-not (Get-Command $Required -ErrorAction SilentlyContinue)) {
            throw "API Task Scheduler Windows absente: $Required"
        }
    }

    $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($ExistingTask) {
        Write-Host "INFO Mise à niveau du superviseur Ollama compat: arrêt avant remplacement."
        Stop-OllamaCompatSupervisor
    }

    $RuntimeDir = Join-Path $PlatformRoot 'runtime'
    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null

    $InstalledScript = Get-InstalledSupervisorPath -PlatformRoot $PlatformRoot
    $InstalledProxy = Get-InstalledProxyPath -PlatformRoot $PlatformRoot
    $SourceScript = [System.IO.Path]::GetFullPath($PSCommandPath)
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $SourceProxy = Join-Path $RepoRoot 'scripts\55_ollama_openclaw_compat_proxy.py'
    if (-not (Test-Path -LiteralPath $SourceProxy)) {
        throw "Proxy Ollama compat source introuvable: $SourceProxy"
    }

    if ($SourceScript -ne [System.IO.Path]::GetFullPath($InstalledScript)) {
        Copy-Item -LiteralPath $SourceScript -Destination $InstalledScript -Force
    }
    Copy-Item -LiteralPath $SourceProxy -Destination $InstalledProxy -Force

    $SourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SourceProxy).Hash
    $InstalledHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstalledProxy).Hash
    if ($SourceHash -ne $InstalledHash) {
        throw 'Copie du proxy Ollama compat non conforme au SHA256 source.'
    }

    $Pwsh = Get-PowerShell7Command
    $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($Identity)) {
        throw 'Impossible de déterminer le compte Windows courant pour Ollama compat.'
    }

    $Arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $InstalledScript),
        '-Action', 'run',
        '-PlatformRootOverride', ('"{0}"' -f $PlatformRoot)
    ) -join ' '

    $TaskAction = New-ScheduledTaskAction -Execute $Pwsh -Argument $Arguments `
        -WorkingDirectory $PlatformRoot
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $Identity
    $Principal = New-ScheduledTaskPrincipal -UserId $Identity -LogonType Interactive -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 5 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew
    $Task = New-ScheduledTask -Action $TaskAction -Trigger $Trigger -Principal $Principal `
        -Settings $Settings -Description (
            'OPENCLAW_LOCAL local Ollama compatibility proxy for strict Ministral chat roles. ' +
            'Loopback only; exact-model normalization; no cloud transport.'
        )

    Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null
    Write-Host "OK  Superviseur Ollama compat installé: Task Scheduler '$TaskName'."
    Write-Host "OLLAMA_COMPAT_TASK=$TaskName"
    Write-Host "OLLAMA_COMPAT_ENDPOINT=http://127.0.0.1:$ListenPort"
    Write-Host "OLLAMA_COMPAT_PROXY=$InstalledProxy"
    Write-Host "OLLAMA_COMPAT_PROXY_SHA256=$InstalledHash"
}

function Start-OllamaCompatSupervisor {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if ([string]$Task.State -ne 'Running') {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    }

    $Deadline = (Get-Date).AddSeconds($RequestedReadyTimeoutSeconds)
    do {
        if (Test-OllamaCompatHealth) {
            Write-Host "OK  Ollama compat prêt sur http://127.0.0.1:$ListenPort."
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $Deadline)

    throw "Ollama compat non prêt après $RequestedReadyTimeoutSeconds s: $HealthUrl"
}

function Stop-OllamaCompatSupervisor {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $Task) {
        Write-Host "INFO Superviseur Ollama compat absent: $TaskName."
        return
    }
    if ([string]$Task.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    }

    $Deadline = (Get-Date).AddSeconds($RequestedStopTimeoutSeconds)
    do {
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $Stopped = (-not $Task) -or ([string]$Task.State -ne 'Running')
        if ($Stopped -and -not (Test-OllamaCompatHealth)) {
            Write-Host "OK  Superviseur Ollama compat arrêté: $TaskName."
            return
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $Deadline)

    throw "Le superviseur Ollama compat ou son listener ne s'est pas arrêté dans le délai: $TaskName"
}

function Get-OllamaCompatSupervisorStatus {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $Installed = $null -ne $Task
    $Info = if ($Installed) {
        Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    else {
        $null
    }
    [ordered]@{
        installed = $Installed
        task_name = $TaskName
        state = if ($Installed) { [string]$Task.State } else { 'absent' }
        endpoint = "http://127.0.0.1:$ListenPort"
        healthy = [bool](Test-OllamaCompatHealth)
        last_run_time = if ($Info) { $Info.LastRunTime } else { $null }
        last_task_result = if ($Info) { $Info.LastTaskResult } else { $null }
    } | ConvertTo-Json -Compress | Write-Host
}

function Invoke-OllamaCompatProxy {
    param([Parameter(Mandatory)][string]$PlatformRoot)

    $Python = Get-ManagedPythonCommand -PlatformRoot $PlatformRoot
    $Proxy = Get-InstalledProxyPath -PlatformRoot $PlatformRoot
    if (-not (Test-Path -LiteralPath $Proxy)) {
        throw "Proxy Ollama compat installé introuvable: $Proxy"
    }

    $LogDir = Join-Path $PlatformRoot 'proofs\ollama-compat'
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $Stamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $LogPath = Join-Path $LogDir "ollama_compat_$Stamp.log"
    "STARTED_UTC=$([DateTimeOffset]::UtcNow.ToString('o'))" | Set-Content -LiteralPath $LogPath -Encoding utf8
    "ENDPOINT=http://127.0.0.1:$ListenPort" | Add-Content -LiteralPath $LogPath -Encoding utf8
    "UPSTREAM=$ExpectedUpstream" | Add-Content -LiteralPath $LogPath -Encoding utf8
    "MODEL=$ExpectedModel" | Add-Content -LiteralPath $LogPath -Encoding utf8

    $Cycle = 0
    while ($true) {
        $Cycle++
        "COMPAT_CYCLE=$Cycle STARTED_UTC=$([DateTimeOffset]::UtcNow.ToString('o'))" |
            Add-Content -LiteralPath $LogPath -Encoding utf8
        $ExitCode = 1
        try {
            & $Python $Proxy '--listen-port' ([string]$ListenPort) *>> $LogPath
            $ExitCode = [int]$LASTEXITCODE
        }
        catch {
            $_ | Out-String | Add-Content -LiteralPath $LogPath -Encoding utf8
            $ExitCode = 1
        }
        "COMPAT_CYCLE=$Cycle EXIT_CODE=$ExitCode FINISHED_UTC=$([DateTimeOffset]::UtcNow.ToString('o'))" |
            Add-Content -LiteralPath $LogPath -Encoding utf8
        Start-Sleep -Seconds $RestartBackoffSeconds
    }
}

$PlatformRoot = Get-PlatformRoot

if ($DryRun) {
    Write-Host '[DRY-RUN] Superviseur Ollama compat local-only pour OpenClaw 2026.9.4.'
    Write-Host "[DRY-RUN] Task=$TaskName root=$PlatformRoot action=$Action"
    Write-Host "[DRY-RUN] Endpoint=http://127.0.0.1:$ListenPort upstream=$ExpectedUpstream"
    Write-Host "[DRY-RUN] Normalisation limitée au modèle exact: $ExpectedModel"
    Write-Host '[DRY-RUN] Fusionner uniquement les messages user adjacents; tous les autres modèles et endpoints sont relayés sans transformation sémantique.'
    Write-Host '[DRY-RUN] Le proxy et le superviseur seront copiés sous <root>\runtime et relancés par Task Scheduler.'
    Write-Host '[DRY-RUN] Aucun prompt n est journalisé; seuls les événements de normalisation et erreurs techniques sont écrits.'
    exit 0
}

switch ($Action) {
    'install' {
        Install-OllamaCompatSupervisor -PlatformRoot $PlatformRoot
    }
    'start' {
        Start-OllamaCompatSupervisor
    }
    'stop' {
        Stop-OllamaCompatSupervisor
    }
    'status' {
        Get-OllamaCompatSupervisorStatus
    }
    'run' {
        Invoke-OllamaCompatProxy -PlatformRoot $PlatformRoot
    }
}

exit 0
