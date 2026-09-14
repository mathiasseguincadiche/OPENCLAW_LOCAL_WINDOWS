[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Model,
    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ListModels = Join-Path $RepoRoot 'scripts\20_list_models.py'
$ModelIdentity = Join-Path $RepoRoot 'scripts\48_model_identity_lock.py'
$OllamaEndpoint = 'http://127.0.0.1:11434'
$PythonRuntime = Join-Path $PSScriptRoot 'lib\python_runtime.ps1'
$InitialSmokeMaxTokens = 64
$ReasoningRetryMaxTokens = 512

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

function Invoke-OllamaSmokeRequest {
    param(
        [Parameter(Mandatory)][string]$ModelName,
        [Parameter(Mandatory)][int]$MaxTokens,
        [Parameter(Mandatory)][int]$RequestTimeoutSeconds
    )

    $Prompt = 'Reply only with LOCAL_OK, without punctuation or explanation.'
    $RequestBody = [ordered]@{
        model = $ModelName
        messages = @(
            [ordered]@{
                role = 'user'
                content = $Prompt
            }
        )
        stream = $false
        think = $false
        keep_alive = '15m'
        options = [ordered]@{
            num_ctx = 2048
            temperature = 0
            num_predict = $MaxTokens
        }
    }
    $Body = $RequestBody | ConvertTo-Json -Depth 6 -Compress
    $ChatRequest = @{
        Method = 'Post'
        Uri = $OllamaEndpoint + '/api/chat'
        ContentType = 'application/json'
        Body = $Body
        TimeoutSec = $RequestTimeoutSeconds
    }
    try {
        return Invoke-RestMethod @ChatRequest
    }
    catch {
        throw ('Ollama inference failed for {0}: {1}' -f $ModelName, $_.Exception.Message)
    }
}

function Get-OllamaSmokeSummary {
    param([Parameter(Mandatory)]$Response)

    $Output = ([string]$Response.message.content).Trim()
    $ThinkingLength = 0
    if ($Response.message.PSObject.Properties['thinking']) {
        $ThinkingLength = ([string]$Response.message.thinking).Length
    }
    $DoneReason = ''
    if ($Response.PSObject.Properties['done_reason']) {
        $DoneReason = [string]$Response.done_reason
    }
    $EvalCount = 0
    if ($Response.PSObject.Properties['eval_count']) {
        $EvalCount = [int]$Response.eval_count
    }

    return [pscustomobject]@{
        output = $Output
        thinking_length = $ThinkingLength
        done_reason = $DoneReason
        eval_count = $EvalCount
    }
}

$PlatformRoot = Get-PlatformRoot

if ($DryRun) {
    $DisplayModel = if ($Model) { $Model } else { '<required model from catalog>' }
    Write-Host ('[DRY-RUN] Managed OPENCLAW_LOCAL Python is mandatory for catalog and model identity checks.')
    Write-Host ('[DRY-RUN] Verify Ollama and run /api/chat smoke test with {0}.' -f $DisplayModel)
    Write-Host '[DRY-RUN] Disable thinking at the Ollama API level for every minimal smoke request.'
    Write-Host (('[DRY-RUN] Start with {0} output tokens; if a reasoning model still consumes that budget in ' +
        'message.thinking and stops on length, retry once with {1} tokens.') -f $InitialSmokeMaxTokens, $ReasoningRetryMaxTokens)
    Write-Host '[DRY-RUN] Read /api/ps to expose the actual VRAM-loaded share.'
    Write-Host '[DRY-RUN] Check digest, format and quantization against qualified identity.'
    exit 0
}

$ManagedPython = Enable-ClawLocalManagedPython -PlatformRoot $PlatformRoot
Write-Host "OK  Runtime Python géré: $ManagedPython"

if (-not $Model) {
    $RequiredModels = @(& $ManagedPython $ListModels --provider ollama --required)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read model_catalog.yaml.'
    }
    $RequiredModels = @($RequiredModels | Where-Object { $_ -and $_.Trim() })
    if ($RequiredModels.Count -eq 0) {
        throw 'No required Ollama model found in model_catalog.yaml.'
    }
    $Model = $RequiredModels[0]
}

$TagRequest = @{
    Method = 'Get'
    Uri = $OllamaEndpoint + '/api/tags'
    TimeoutSec = 5
}
try {
    $Tags = Invoke-RestMethod @TagRequest
}
catch {
    throw ('Ollama API unavailable on loopback: {0}' -f $_.Exception.Message)
}

$AvailableModels = @(
    $Tags.models |
        ForEach-Object { [string]$_.name } |
        Where-Object { $_ -and $_.Trim() }
)
if ($AvailableModels -notcontains $Model) {
    throw ('Required Ollama model is not installed locally: {0}' -f $Model)
}

$Response = Invoke-OllamaSmokeRequest -ModelName $Model -MaxTokens $InitialSmokeMaxTokens `
    -RequestTimeoutSeconds $TimeoutSeconds
$Summary = Get-OllamaSmokeSummary -Response $Response

if (
    $Summary.output -notmatch 'LOCAL_OK' -and
    [string]::IsNullOrWhiteSpace($Summary.output) -and
    $Summary.thinking_length -gt 0 -and
    $Summary.done_reason -eq 'length'
) {
    Write-Host ('INFO Reasoning smoke retry for {0}: first pass exhausted {1} tokens in thinking; retry={2}.' -f `
        $Model, $Summary.eval_count, $ReasoningRetryMaxTokens)
    $Response = Invoke-OllamaSmokeRequest -ModelName $Model -MaxTokens $ReasoningRetryMaxTokens `
        -RequestTimeoutSeconds $TimeoutSeconds
    $Summary = Get-OllamaSmokeSummary -Response $Response
}

$Output = [string]$Summary.output
if ($Output -notmatch 'LOCAL_OK') {
    $FailureMessage = 'Unexpected smoke result for {0}. output={1}; thinking_chars={2}; done_reason={3}; eval_count={4}' -f `
        $Model, $Output, $Summary.thinking_length, $Summary.done_reason, $Summary.eval_count
    throw $FailureMessage
}

$EvalCount = [int]$Summary.eval_count
$EvalDuration = 0L
if ($Response.PSObject.Properties['eval_duration']) {
    $EvalDuration = [long]$Response.eval_duration
}
$TokensPerSecond = $null
if ($EvalCount -gt 0 -and $EvalDuration -gt 0) {
    $TokensPerSecond = [math]::Round($EvalCount / $EvalDuration * 1000000000, 2)
}

$Metric = ''
if ($null -ne $TokensPerSecond) {
    $Metric = ' ({0} tok/s)' -f $TokensPerSecond
}
Write-Host ('OK local inference with {0} via Ollama API{1}.' -f $Model, $Metric)

$PsRequest = @{
    Method = 'Get'
    Uri = $OllamaEndpoint + '/api/ps'
    TimeoutSec = 5
}
try {
    $Running = Invoke-RestMethod @PsRequest
    $Loaded = $Running.models |
        Where-Object { $_.name -eq $Model -or $_.model -eq $Model } |
        Select-Object -First 1
    if ($null -ne $Loaded) {
        $SizeBytes = [double]$Loaded.size
        $VramBytes = [double]$Loaded.size_vram
        $SizeGiB = [math]::Round($SizeBytes / 1GB, 2)
        $VramGiB = [math]::Round($VramBytes / 1GB, 2)
        $GpuPercent = 0
        if ($SizeBytes -gt 0) {
            $GpuPercent = [math]::Round(($VramBytes / $SizeBytes) * 100, 1)
        }
        $ContextLength = $Loaded.context_length
        $MemoryMessage = 'INFO Ollama memory {0}: VRAM={1}/{2} GiB (~{3}% GPU), context={4}.' -f $Model, $VramGiB, $SizeGiB, $GpuPercent, $ContextLength
        Write-Host $MemoryMessage
    }
}
catch {
    Write-Host ('INFO Ollama memory metrics unavailable for {0}.' -f $Model)
}

& $ManagedPython $ModelIdentity --root $PlatformRoot --action check --allow-unqualified
if ($LASTEXITCODE -ne 0) {
    throw 'Qualified model identity is INVALIDATED; full qualification is required.'
}

exit 0