[CmdletBinding()]
param(
    [ValidateSet('status', 'enable-log', 'proof')]
    [string]$Action = 'status',
    [switch]$DryRun,
    [string]$PlatformRootOverride,
    [ValidateRange(1, 168)][int]$HistoryHours = 24,
    [ValidateRange(1, 100)][int]$MaxEvents = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'OPENCLAW_LOCAL Gateway'
$GatewayPort = 18789
$TaskSchedulerOperationalLog = 'Microsoft-Windows-TaskScheduler/Operational'

function Get-PlatformRoot {
    if (-not [string]::IsNullOrWhiteSpace($PlatformRootOverride)) {
        return $PlatformRootOverride
    }
    if ($env:OPENCLAW_LOCAL_ROOT) {
        return $env:OPENCLAW_LOCAL_ROOT
    }
    if (Test-Path -LiteralPath 'E:\') {
        return 'E:\AI\OpenClawLocal'
    }
    return (Join-Path $env:LOCALAPPDATA 'OpenClawLocal')
}

function Convert-TaskResult {
    param($Value)

    if ($null -eq $Value) {
        return [ordered]@{
            raw = $null
            hex = $null
            classification = 'unknown'
        }
    }

    $Numeric = [int64]$Value
    $Unsigned = [uint32]($Numeric -band 4294967295)
    $Hex = '0x{0:X8}' -f $Unsigned
    $Classification = switch ($Hex) {
        '0x00000000' { 'success' }
        '0x00041301' { 'running' }
        '0xC000013A' { 'control_event_termination' }
        default { 'unexpected' }
    }

    return [ordered]@{
        raw = $Numeric
        hex = $Hex
        classification = $Classification
    }
}

function Get-OperationalLogState {
    try {
        $Configuration = [System.Diagnostics.Eventing.Reader.EventLogConfiguration]::new(
            $TaskSchedulerOperationalLog
        )
        try {
            return [ordered]@{
                available = $true
                enabled = [bool]$Configuration.IsEnabled
                log_name = $TaskSchedulerOperationalLog
            }
        }
        finally {
            $Configuration.Dispose()
        }
    }
    catch {
        return [ordered]@{
            available = $false
            enabled = $false
            log_name = $TaskSchedulerOperationalLog
            error = $_.Exception.Message
        }
    }
}

function Enable-OperationalLog {
    try {
        $Configuration = [System.Diagnostics.Eventing.Reader.EventLogConfiguration]::new(
            $TaskSchedulerOperationalLog
        )
        try {
            if (-not $Configuration.IsEnabled) {
                $Configuration.IsEnabled = $true
                $Configuration.SaveChanges()
            }
        }
        finally {
            $Configuration.Dispose()
        }
    }
    catch {
        throw "Impossible d'activer le journal Task Scheduler Operational: $($_.Exception.Message)"
    }
}

function Get-RecentTaskSchedulerEvents {
    $LogState = Get-OperationalLogState
    if (-not $LogState.available -or -not $LogState.enabled) {
        return @()
    }
    if (-not (Get-Command Get-WinEvent -ErrorAction SilentlyContinue)) {
        return @()
    }

    $StartTime = (Get-Date).AddHours(-$HistoryHours)
    $Candidates = @(
        Get-WinEvent `
            -FilterHashtable @{
                LogName = $TaskSchedulerOperationalLog
                StartTime = $StartTime
            } `
            -MaxEvents 500 `
            -ErrorAction SilentlyContinue
    )

    $Events = @()
    foreach ($Event in $Candidates) {
        $Xml = $Event.ToXml()
        if ($Xml.IndexOf($TaskName, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }

        $Events += [ordered]@{
            event_id = [int]$Event.Id
            record_id = [int64]$Event.RecordId
            time_created_utc = if ($Event.TimeCreated) {
                $Event.TimeCreated.ToUniversalTime().ToString('o')
            }
            else {
                $null
            }
            level = [string]$Event.LevelDisplayName
        }

        if ($Events.Count -ge $MaxEvents) {
            break
        }
    }

    return $Events
}

function Get-GatewayListenerDiagnostic {
    $Listeners = @(
        Get-NetTCPConnection `
            -State Listen `
            -LocalPort $GatewayPort `
            -ErrorAction SilentlyContinue
    )

    $Result = @()
    foreach ($Listener in $Listeners) {
        $Process = Get-CimInstance `
            Win32_Process `
            -Filter "ProcessId = $($Listener.OwningProcess)" `
            -ErrorAction SilentlyContinue

        $Result += [ordered]@{
            address = "$($Listener.LocalAddress):$($Listener.LocalPort)"
            pid = [int]$Listener.OwningProcess
            executable = if ($Process) { [string]$Process.ExecutablePath } else { $null }
            command_line = if ($Process) { [string]$Process.CommandLine } else { $null }
        }
    }

    return $Result
}

function Get-GatewayRpcDiagnostic {
    param([Parameter(Mandatory)][string]$PlatformRoot)

    $OpenClaw = Join-Path $PlatformRoot 'runtime\npm-global\openclaw.cmd'
    if (-not (Test-Path -LiteralPath $OpenClaw)) {
        return [ordered]@{
            attempted = $false
            ok = $false
            reason = 'managed_openclaw_missing'
        }
    }

    $StateDir = Join-Path $PlatformRoot 'state'
    $ConfigPath = Join-Path $StateDir 'openclaw.json'
    $PreviousStateDir = $env:OPENCLAW_STATE_DIR
    $PreviousConfigPath = $env:OPENCLAW_CONFIG_PATH

    try {
        $env:OPENCLAW_STATE_DIR = $StateDir
        $env:OPENCLAW_CONFIG_PATH = $ConfigPath
        $Output = @(& $OpenClaw 'gateway' 'status' '--require-rpc' '--json' 2>&1)
        $ExitCode = [int]$LASTEXITCODE
        $Raw = ($Output | Out-String).Trim()
        $Parsed = $null

        if ($ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($Raw)) {
            try {
                $Parsed = $Raw | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                $Parsed = $null
            }
        }

        return [ordered]@{
            attempted = $true
            exit_code = $ExitCode
            ok = [bool]($Parsed -and $Parsed.rpc -and $Parsed.rpc.ok)
            version = if ($Parsed -and $Parsed.rpc) { [string]$Parsed.rpc.version } else { $null }
            boot_id = if ($Parsed -and $Parsed.rpc -and $Parsed.rpc.server) {
                [string]$Parsed.rpc.server.bootId
            }
            else {
                $null
            }
        }
    }
    finally {
        if ($null -eq $PreviousStateDir) {
            Remove-Item Env:OPENCLAW_STATE_DIR -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENCLAW_STATE_DIR = $PreviousStateDir
        }

        if ($null -eq $PreviousConfigPath) {
            Remove-Item Env:OPENCLAW_CONFIG_PATH -ErrorAction SilentlyContinue
        }
        else {
            $env:OPENCLAW_CONFIG_PATH = $PreviousConfigPath
        }
    }
}

function Get-DiagnosticPayload {
    param([Parameter(Mandatory)][string]$PlatformRoot)

    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $Info = if ($Task) {
        Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    else {
        $null
    }
    $TaskResult = Convert-TaskResult -Value $(if ($Info) { $Info.LastTaskResult } else { $null })

    return [ordered]@{
        generated_utc = [DateTimeOffset]::UtcNow.ToString('o')
        platform_root = $PlatformRoot
        task = [ordered]@{
            name = $TaskName
            installed = [bool]$Task
            state = if ($Task) { [string]$Task.State } else { 'absent' }
            last_run_time = if ($Info) { $Info.LastRunTime } else { $null }
            last_task_result = $TaskResult
            next_run_time = if ($Info) { $Info.NextRunTime } else { $null }
        }
        task_scheduler_operational = Get-OperationalLogState
        task_scheduler_events = @(Get-RecentTaskSchedulerEvents)
        listeners = @(Get-GatewayListenerDiagnostic)
        rpc = Get-GatewayRpcDiagnostic -PlatformRoot $PlatformRoot
    }
}

$PlatformRoot = Get-PlatformRoot

if ($DryRun) {
    Write-Host '[DRY-RUN] Diagnostic du superviseur Gateway externe Windows.'
    Write-Host "[DRY-RUN] action=$Action task=$TaskName root=$PlatformRoot"
    Write-Host "[DRY-RUN] journal=$TaskSchedulerOperationalLog history_hours=$HistoryHours max_events=$MaxEvents"
    Write-Host '[DRY-RUN] 0x00041301=running; 0xC000013A=control_event_termination.'
    Write-Host '[DRY-RUN] proof écrit sous <root>\proofs\gateway uniquement avec -Action proof.'
    exit 0
}

if ($Action -eq 'enable-log') {
    Enable-OperationalLog
}

$Payload = Get-DiagnosticPayload -PlatformRoot $PlatformRoot
$Json = $Payload | ConvertTo-Json -Depth 8

if ($Action -eq 'proof') {
    $ProofDir = Join-Path $PlatformRoot 'proofs\gateway'
    New-Item -ItemType Directory -Path $ProofDir -Force | Out-Null
    $Stamp = Get-Date -Format 'yyyyMMdd_HHmmssfff'
    $ProofPath = Join-Path $ProofDir "gateway_supervisor_diagnostic_$Stamp.json"
    $Json | Set-Content -LiteralPath $ProofPath -Encoding utf8
    Write-Host "GATEWAY_SUPERVISOR_DIAGNOSTIC=$ProofPath"
}

$Json | Write-Host
exit 0
