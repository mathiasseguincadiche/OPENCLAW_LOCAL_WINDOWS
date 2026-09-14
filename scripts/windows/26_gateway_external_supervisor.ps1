[CmdletBinding()]
param(
    [ValidateSet('install', 'start', 'stop', 'status', 'run')]
    [string]$Action = 'status',
    [switch]$DryRun,
    [string]$PlatformRootOverride,
    [ValidateRange(5, 120)][int]$StopTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'OPENCLAW_LOCAL Gateway'
$RestartBackoffSeconds = 2
$RequestedPlatformRoot = $PlatformRootOverride
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

function Get-ManagedOpenClawCommand {
    param([Parameter(Mandatory)][string]$PlatformRoot)

    $Managed = Join-Path $PlatformRoot 'runtime\npm-global\openclaw.cmd'
    if (Test-Path -LiteralPath $Managed) {
        return $Managed
    }
    $Found = Get-Command openclaw -ErrorAction SilentlyContinue
    if ($Found) {
        return $Found.Source
    }
    throw 'OpenClaw est introuvable pour le superviseur Gateway.'
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
    throw 'PowerShell 7 (pwsh.exe) est requis pour le superviseur Gateway.'
}

function Initialize-ExternalGatewayEnvironment {
    param([Parameter(Mandatory)][string]$PlatformRoot)

    $StateDir = Join-Path $PlatformRoot 'state'
    $ConfigPath = Join-Path $StateDir 'openclaw.json'

    $env:OPENCLAW_LOCAL_ROOT = $PlatformRoot
    $env:OPENCLAW_STATE_DIR = $StateDir
    $env:OPENCLAW_CONFIG_PATH = $ConfigPath
    $env:OPENCLAW_SUPERVISOR_MODE = 'external'
    $env:OPENCLAW_SERVICE_REPAIR_POLICY = 'external'
    $env:OPENCLAW_CONFIG_READONLY = '1'
    $env:OPENCLAW_LOCAL_CLOUD_ENABLED = 'false'
    $env:OLLAMA_API_KEY = 'ollama-local'
    $env:INTEL_VULKAN_API_KEY = 'intel-vulkan-local'
    $env:INTEL_SYCL_API_KEY = 'intel-sycl-local'
    Remove-Item Env:OPENCLAW_HOME -ErrorAction SilentlyContinue
}

function Get-InstalledSupervisorPath {
    param([Parameter(Mandatory)][string]$PlatformRoot)
    return (Join-Path $PlatformRoot 'runtime\gateway_external_supervisor.ps1')
}

function Install-ExternalGatewaySupervisor {
    param([Parameter(Mandatory)][string]$PlatformRoot)

    foreach ($Required in @(
        'Get-ScheduledTask',
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
        Write-Host "INFO Mise à niveau du superviseur Gateway: arrêt de l'instance existante avant remplacement."
        Invoke-ExternalGatewaySupervisorStop
    }

    $RuntimeDir = Join-Path $PlatformRoot 'runtime'
    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
    $InstalledScript = Get-InstalledSupervisorPath -PlatformRoot $PlatformRoot
    $SourcePath = [System.IO.Path]::GetFullPath($PSCommandPath)
    $DestinationPath = [System.IO.Path]::GetFullPath($InstalledScript)
    if ($SourcePath -ne $DestinationPath) {
        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    }

    $Pwsh = Get-PowerShell7Command
    $Identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ([string]::IsNullOrWhiteSpace($Identity)) {
        throw 'Impossible de déterminer le compte Windows courant pour le superviseur Gateway.'
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
            'OPENCLAW_LOCAL external Gateway supervisor for relocated OpenClaw state. ' +
            'Managed by OPENCLAW_LOCAL; OpenClaw native service management is intentionally not used.'
        )

    Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null
    Write-Host "OK  Superviseur Gateway externe installé: Task Scheduler '$TaskName'."
    Write-Host "GATEWAY_SUPERVISOR=external"
    Write-Host "GATEWAY_SUPERVISOR_TASK=$TaskName"
    Write-Host "GATEWAY_SUPERVISOR_SCRIPT=$InstalledScript"
}

function Invoke-ExternalGatewaySupervisorStart {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'Get-ScheduledTask indisponible.'
    }
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    if ([string]$Task.State -eq 'Running') {
        Write-Host "OK  Superviseur Gateway externe déjà actif: $TaskName."
        return
    }
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Host "OK  Démarrage demandé au superviseur Gateway externe: $TaskName."
}

function Invoke-ExternalGatewaySupervisorStop {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $Task) {
        Write-Host "INFO Superviseur Gateway externe absent: $TaskName."
        return
    }
    if ([string]$Task.State -ne 'Running') {
        Write-Host "OK  Superviseur Gateway externe déjà arrêté: $TaskName."
        return
    }

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $Deadline = (Get-Date).AddSeconds($RequestedStopTimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        if ([string]$Task.State -ne 'Running') {
            Write-Host "OK  Superviseur Gateway externe arrêté: $TaskName."
            return
        }
    } while ((Get-Date) -lt $Deadline)

    throw "Le superviseur Gateway externe ne s'est pas arrêté dans le délai: $TaskName"
}

function Show-ExternalGatewaySupervisorStatus {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $Task) {
        [ordered]@{
            installed = $false
            task_name = $TaskName
            state = 'absent'
        } | ConvertTo-Json -Compress | Write-Host
        return
    }
    $Info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    [ordered]@{
        installed = $true
        task_name = $TaskName
        state = [string]$Task.State
        last_run_time = if ($Info) { $Info.LastRunTime } else { $null }
        last_task_result = if ($Info) { $Info.LastTaskResult } else { $null }
        next_run_time = if ($Info) { $Info.NextRunTime } else { $null }
    } | ConvertTo-Json -Compress | Write-Host
}

function Invoke-ExternalGateway {
    param([Parameter(Mandatory)][string]$PlatformRoot)

    Initialize-ExternalGatewayEnvironment -PlatformRoot $PlatformRoot
    $StateDir = Join-Path $PlatformRoot 'state'
    $ConfigPath = Join-Path $StateDir 'openclaw.json'
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration OpenClaw absente pour le Gateway externe: $ConfigPath"
    }

    $OpenClaw = Get-ManagedOpenClawCommand -PlatformRoot $PlatformRoot
    $LogDir = Join-Path $PlatformRoot 'proofs\gateway'
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    $Stamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $LogPath = Join-Path $LogDir "gateway_external_$Stamp.log"
    "STARTED_UTC=$([DateTimeOffset]::UtcNow.ToString('o'))" | Set-Content -LiteralPath $LogPath -Encoding utf8
    "SUPERVISOR=external" | Add-Content -LiteralPath $LogPath -Encoding utf8
    "STATE_DIR=$StateDir" | Add-Content -LiteralPath $LogPath -Encoding utf8
    "RESTART_BACKOFF_SECONDS=$RestartBackoffSeconds" | Add-Content -LiteralPath $LogPath -Encoding utf8

    $Cycle = 0
    while ($true) {
        $Cycle++
        "GATEWAY_CYCLE=$Cycle STARTED_UTC=$([DateTimeOffset]::UtcNow.ToString('o'))" |
            Add-Content -LiteralPath $LogPath -Encoding utf8
        $ExitCode = 1
        try {
            & $OpenClaw 'gateway' 'run' *>> $LogPath
            $ExitCode = [int]$LASTEXITCODE
        }
        catch {
            $_ | Out-String | Add-Content -LiteralPath $LogPath -Encoding utf8
            $ExitCode = 1
        }
        "GATEWAY_CYCLE=$Cycle EXIT_CODE=$ExitCode FINISHED_UTC=$([DateTimeOffset]::UtcNow.ToString('o'))" |
            Add-Content -LiteralPath $LogPath -Encoding utf8
        # Le Task Scheduler possède le wrapper, pas le processus Gateway. Tant que
        # la tâche n'est pas explicitement arrêtée par OPENCLAW_LOCAL, une sortie
        # Gateway (y compris un redémarrage demandé) est relancée avec backoff.
        Start-Sleep -Seconds $RestartBackoffSeconds
    }
}

$PlatformRoot = Get-PlatformRoot

if ($DryRun) {
    Write-Host "[DRY-RUN] Gateway OpenClaw relocalisé: superviseur externe Windows Task Scheduler."
    Write-Host "[DRY-RUN] Task=$TaskName root=$PlatformRoot action=$Action"
    Write-Host '[DRY-RUN] OPENCLAW_SUPERVISOR_MODE=external et OPENCLAW_SERVICE_REPAIR_POLICY=external.'
    Write-Host '[DRY-RUN] Le processus Gateway utilisera OPENCLAW_STATE_DIR=<root>\state et OPENCLAW_CONFIG_PATH=<root>\state\openclaw.json.'
    Write-Host '[DRY-RUN] Le wrapper relance gateway run après toute sortie tant que la tâche reste active.'
    Write-Host '[DRY-RUN] Une réinstallation arrête d abord le wrapper existant avant de remplacer le script et la définition de tâche.'
    Write-Host '[DRY-RUN] Aucun service natif OpenClaw install/start ne sera utilisé pour cet état relocalisé.'
    exit 0
}

switch ($Action) {
    'install' {
        Install-ExternalGatewaySupervisor -PlatformRoot $PlatformRoot
    }
    'start' {
        Invoke-ExternalGatewaySupervisorStart
    }
    'stop' {
        Invoke-ExternalGatewaySupervisorStop
    }
    'status' {
        Show-ExternalGatewaySupervisorStatus
    }
    'run' {
        Invoke-ExternalGateway -PlatformRoot $PlatformRoot
    }
}

exit 0
