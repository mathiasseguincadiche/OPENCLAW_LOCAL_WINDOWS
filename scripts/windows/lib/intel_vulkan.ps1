Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'intel_b580.ps1')

function Get-IntelVulkanRuntimeLock {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $LockPath = Join-Path $RepoRoot 'config\v1\runtime_versions.json'
    $Lock = Get-Content -Raw -LiteralPath $LockPath | ConvertFrom-Json
    if (-not $Lock.llama_cpp_vulkan) {
        throw 'Contrat llama_cpp_vulkan absent de runtime_versions.json.'
    }
    return $Lock.llama_cpp_vulkan
}

function Get-IntelVulkanPathSet {
    param(
        [Parameter(Mandatory)][string]$PlatformRoot,
        [Parameter(Mandatory)]$RuntimeLock
    )

    $Root = Join-Path $PlatformRoot 'runtime\llama.cpp-vulkan'
    $VersionRoot = Join-Path $Root ([string]$RuntimeLock.release)
    $StateRoot = Join-Path $PlatformRoot 'state\intel-vulkan'
    $ProofRoot = Join-Path $PlatformRoot 'proofs\intel-vulkan'
    return [pscustomobject]@{
        Root = $Root
        VersionRoot = $VersionRoot
        StateRoot = $StateRoot
        ProofRoot = $ProofRoot
        Archive = Join-Path $Root ([string]$RuntimeLock.asset)
        Manifest = Join-Path $StateRoot 'runtime-manifest.json'
        Preset = Join-Path $StateRoot 'models.ini'
        ProcessState = Join-Path $StateRoot 'server.json'
        StdoutLog = Join-Path $ProofRoot 'llama-server.stdout.log'
        StderrLog = Join-Path $ProofRoot 'llama-server.stderr.log'
    }
}

function Get-IntelVulkanServerBinary {
    param([Parameter(Mandatory)][string]$VersionRoot)

    if (-not (Test-Path -LiteralPath $VersionRoot)) {
        return $null
    }
    $Binary = Get-ChildItem -LiteralPath $VersionRoot -Filter 'llama-server.exe' -File -Recurse |
        Select-Object -First 1
    if ($Binary) {
        return $Binary.FullName
    }
    return $null
}

function Install-IntelVulkanRuntime {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PlatformRoot
    )

    $RuntimeLock = Get-IntelVulkanRuntimeLock -RepoRoot $RepoRoot
    $Paths = Get-IntelVulkanPathSet -PlatformRoot $PlatformRoot -RuntimeLock $RuntimeLock
    New-Item -ItemType Directory -Path $Paths.Root -Force | Out-Null
    New-Item -ItemType Directory -Path $Paths.StateRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $Paths.ProofRoot -Force | Out-Null

    $ExpectedHash = ([string]$RuntimeLock.sha256).ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $Paths.Archive)) {
        $Curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if (-not $Curl) {
            throw 'curl.exe est requis pour télécharger le runtime llama.cpp Vulkan.'
        }
        $Partial = "$($Paths.Archive).partial"
        Write-Host "Téléchargement llama.cpp Vulkan $($RuntimeLock.release) (reprenable)..."
        & $Curl.Source '--location' '--fail' '--retry' '3' '--retry-delay' '5' `
            '--continue-at' '-' '--output' $Partial ([string]$RuntimeLock.url)
        if ($LASTEXITCODE -ne 0) {
            throw "Téléchargement llama.cpp Vulkan en échec (curl code $LASTEXITCODE)."
        }
        $PartialHash = (Get-FileHash -LiteralPath $Partial -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($PartialHash -ne $ExpectedHash) {
            Remove-Item -LiteralPath $Partial -Force -ErrorAction SilentlyContinue
            throw "SHA-256 Vulkan invalide. Attendu=$ExpectedHash Reçu=$PartialHash"
        }
        Move-Item -LiteralPath $Partial -Destination $Paths.Archive -Force
    }

    $ArchiveHash = (Get-FileHash -LiteralPath $Paths.Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ArchiveHash -ne $ExpectedHash) {
        throw "Archive llama.cpp Vulkan corrompue. Attendu=$ExpectedHash Reçu=$ArchiveHash"
    }
    Write-Host "OK  SHA-256 archive llama.cpp Vulkan vérifié: $ArchiveHash"

    $Existing = Get-IntelVulkanServerBinary -VersionRoot $Paths.VersionRoot
    if ($Existing -and (Test-Path -LiteralPath $Paths.Manifest)) {
        try {
            $Manifest = Get-Content -Raw -LiteralPath $Paths.Manifest | ConvertFrom-Json
            $BinaryHash = (Get-FileHash -LiteralPath $Existing -Algorithm SHA256).Hash.ToLowerInvariant()
            if (
                [string]$Manifest.release -eq [string]$RuntimeLock.release -and
                ([string]$Manifest.archive_sha256).ToLowerInvariant() -eq $ExpectedHash -and
                ([string]$Manifest.server_sha256).ToLowerInvariant() -eq $BinaryHash
            ) {
                Write-Host "OK  Runtime Intel Vulkan $($RuntimeLock.release) intact: $Existing (SHA-256=$BinaryHash)"
                return $Existing
            }
        }
        catch {
            Write-Warning 'Manifeste Intel Vulkan incohérent; réextraction depuis l''archive vérifiée.'
        }
    }

    if (Test-Path -LiteralPath $Paths.VersionRoot) {
        Remove-Item -LiteralPath $Paths.VersionRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Paths.VersionRoot -Force | Out-Null
    Expand-Archive -LiteralPath $Paths.Archive -DestinationPath $Paths.VersionRoot -Force
    $Binary = Get-IntelVulkanServerBinary -VersionRoot $Paths.VersionRoot
    if (-not $Binary) {
        throw 'llama-server.exe absent du runtime Vulkan extrait.'
    }
    $BinaryHash = (Get-FileHash -LiteralPath $Binary -Algorithm SHA256).Hash.ToLowerInvariant()
    [ordered]@{
        schema_version = '1.0.0'
        release = [string]$RuntimeLock.release
        release_commit = [string]$RuntimeLock.release_commit
        archive_sha256 = $ExpectedHash
        server_sha256 = $BinaryHash
        binary = $Binary
        installed_at = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Paths.Manifest -Encoding utf8
    Write-Host "OK  Runtime Intel Vulkan installé: $Binary (SHA-256=$BinaryHash)"
    return $Binary
}

function Test-IntelArcB580VulkanDevice {
    param([Parameter(Mandatory)][string]$ServerBinary)

    $Output = @(& $ServerBinary --list-devices 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "llama-server Vulkan --list-devices a échoué (code $LASTEXITCODE)."
    }
    $Line = $Output |
        Where-Object { [string]$_ -match '(?i)Intel.*Arc.*B580|Arc.*B580.*Intel' } |
        Select-Object -First 1
    if (-not $Line) {
        throw "Intel Arc B580 absente des devices Vulkan.`n$($Output -join "`n")"
    }
    $Match = [regex]::Match([string]$Line, '^\s*([A-Za-z]+\d+)\s*:')
    if (-not $Match.Success) {
        throw "Impossible d'extraire l'ID Vulkan depuis: $Line"
    }
    $Device = $Match.Groups[1].Value
    Write-Host "OK  Intel Arc B580 détectée via Vulkan: $Device"
    Write-Host ($Output -join "`n")
    return [pscustomobject]@{ id = $Device; evidence = ($Output -join "`n") }
}

function Get-IntelVulkanManagedModel {
    param([Parameter(Mandatory)]$RuntimeLock)

    $Models = @($RuntimeLock.managed_models | ForEach-Object { [string]$_ })
    if ($Models.Count -ne 2) {
        throw "Le profil hybride exige exactement 2 modèles llama.cpp/Vulkan; détectés=$($Models.Count)."
    }
    return $Models
}

function ConvertTo-IntelVulkanRouterModelId {
    param([Parameter(Mandatory)][string]$LogicalModel)

    $ColonIndex = $LogicalModel.LastIndexOf(':')
    if ($ColonIndex -lt 0) {
        return $LogicalModel
    }

    $Prefix = $LogicalModel.Substring(0, $ColonIndex)
    $Tag = $LogicalModel.Substring($ColonIndex + 1)
    $Match = [regex]::Match(
        $Tag,
        '[-.]([A-Z0-9_]+)$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $CanonicalTag = if ($Match.Success) {
        $Match.Groups[1].Value.ToUpperInvariant()
    }
    else {
        $Tag.ToUpperInvariant()
    }
    return "${Prefix}:$CanonicalTag"
}

function Get-IntelVulkanManagedRuntimeModel {
    param([Parameter(Mandatory)]$RuntimeLock)

    $LogicalModels = Get-IntelVulkanManagedModel -RuntimeLock $RuntimeLock
    $RuntimeModels = @(
        $RuntimeLock.managed_runtime_models | ForEach-Object { [string]$_ }
    )
    if ($RuntimeModels.Count -ne $LogicalModels.Count) {
        throw (
            'Contrat managed_runtime_models incohérent: ' +
            "sources=$($LogicalModels.Count) runtime=$($RuntimeModels.Count)."
        )
    }

    for ($Index = 0; $Index -lt $LogicalModels.Count; $Index++) {
        $Derived = ConvertTo-IntelVulkanRouterModelId -LogicalModel $LogicalModels[$Index]
        if (-not [string]::Equals(
            $Derived,
            $RuntimeModels[$Index],
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw (
                "Contrat ID routeur Vulkan incohérent pour $($LogicalModels[$Index]): " +
                "déclaré=$($RuntimeModels[$Index]) dérivé=$Derived."
            )
        }
    }
    return $RuntimeModels
}

function New-IntelVulkanModelPreset {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PlatformRoot,
        [Parameter(Mandatory)]$RuntimeLock,
        [Parameter(Mandatory)][string]$PresetPath
    )

    $null = $RepoRoot
    $null = $PlatformRoot
    $Models = Get-IntelVulkanManagedModel -RuntimeLock $RuntimeLock
    $null = Get-IntelVulkanManagedRuntimeModel -RuntimeLock $RuntimeLock
    $Lines = @(
        'version = 1',
        '',
        '; Généré par OPENCLAW_LOCAL pour le profil B580 hybride Vulkan.',
        '; Qwen reste volontairement sur Ollama/Vulkan.',
        ''
    )
    foreach ($Model in $Models) {
        $Path = Resolve-OllamaGgufPath -Model $Model
        $Normalized = $Path -replace '\\', '/'
        $Lines += "[$Model]"
        $Lines += "model = $Normalized"
        $Lines += 'load-on-startup = false'
        $Lines += 'stop-timeout = 30'
        $Lines += ''
        Write-Host "OK  GGUF Vulkan $Model -> $Path"
    }
    if ($PSCmdlet.ShouldProcess($PresetPath, 'Generate Intel Vulkan model preset')) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $PresetPath) -Force | Out-Null
        Set-Content -LiteralPath $PresetPath -Value $Lines -Encoding utf8
    }
    return $Models
}

function Stop-IntelVulkanServer {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$StatePath)

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return
    }
    if (-not $PSCmdlet.ShouldProcess($StatePath, 'Stop tracked Intel Vulkan server')) {
        return
    }
    try {
        $State = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
        $Process = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
        if ($Process) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            $null = $Process.WaitForExit(10000)
            Write-Host "OK  llama-server Intel Vulkan arrêté (PID=$($Process.Id))."
        }
    }
    finally {
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    }
}

function Wait-IntelVulkanApi {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [int]$TimeoutSeconds = 180
    )

    $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $Response = Invoke-RestMethod -Method Get -Uri "$BaseUrl/models?reload=1" -TimeoutSec 5
            if ($Response.data) {
                return $Response
            }
        }
        catch {
            Start-Sleep -Milliseconds 1000
        }
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)
    throw "API llama.cpp Intel Vulkan non prête après $TimeoutSeconds s: $BaseUrl"
}

function Resolve-IntelVulkanRuntimeModelId {
    param(
        [Parameter(Mandatory)]$Inventory,
        [Parameter(Mandatory)][string]$LogicalModel
    )

    $ExpectedRuntimeModel = ConvertTo-IntelVulkanRouterModelId -LogicalModel $LogicalModel
    $Ids = @($Inventory.data | ForEach-Object { [string]$_.id })
    $Resolved = $Ids |
        Where-Object { $_ -ieq $ExpectedRuntimeModel } |
        Select-Object -First 1
    if (-not $Resolved) {
        throw (
            "Modèle Vulkan absent du routeur: logique=$LogicalModel " +
            "runtime_attendu=$ExpectedRuntimeModel (disponibles=$($Ids -join ','))."
        )
    }
    return [string]$Resolved
}

function Start-IntelVulkanServer {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PlatformRoot,
        [int]$TimeoutSeconds = 180
    )

    $RuntimeLock = Get-IntelVulkanRuntimeLock -RepoRoot $RepoRoot
    $Paths = Get-IntelVulkanPathSet -PlatformRoot $PlatformRoot -RuntimeLock $RuntimeLock
    $Binary = Get-IntelVulkanServerBinary -VersionRoot $Paths.VersionRoot
    if (-not $Binary) {
        throw 'Runtime llama.cpp Vulkan absent. Exécutez intel-vulkan-setup.'
    }
    $Driver = Get-IntelArcB580DriverInfo
    Write-Host "OK  Pilote Intel B580 détecté: $($Driver.driver_version)"
    $Device = Test-IntelArcB580VulkanDevice -ServerBinary $Binary
    if (-not $PSCmdlet.ShouldProcess([string]$RuntimeLock.endpoint, 'Start Intel Vulkan llama-server')) {
        return $null
    }

    $Models = New-IntelVulkanModelPreset -RepoRoot $RepoRoot -PlatformRoot $PlatformRoot `
        -RuntimeLock $RuntimeLock -PresetPath $Paths.Preset -Confirm:$false
    $RuntimeModels = Get-IntelVulkanManagedRuntimeModel -RuntimeLock $RuntimeLock
    $null = Stop-IntelVulkanServer -StatePath $Paths.ProcessState -Confirm:$false

    $Listeners = @(Get-NetTCPConnection -LocalPort ([int]$RuntimeLock.listen_port) `
        -State Listen -ErrorAction SilentlyContinue)
    if ($Listeners.Count -gt 0) {
        $OwnerIds = @($Listeners | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique)
        throw "Port $($RuntimeLock.listen_port) occupé par PID=$($OwnerIds -join ',')."
    }

    New-Item -ItemType Directory -Path $Paths.ProofRoot -Force | Out-Null
    Remove-Item -LiteralPath $Paths.StdoutLog, $Paths.StderrLog -Force -ErrorAction SilentlyContinue
    $Arguments = @(
        '--models-preset', $Paths.Preset,
        '--models-max', [string]$RuntimeLock.models_max,
        '--models-autoload',
        '--host', [string]$RuntimeLock.listen_host,
        '--port', [string]$RuntimeLock.listen_port,
        '--ctx-size', [string]$RuntimeLock.context_tokens,
        '--gpu-layers', [string]$RuntimeLock.gpu_layers,
        '--fit', 'on',
        '--device', [string]$Device.id,
        '--jinja',
        '--metrics',
        '--offline'
    )

    $PreviousParallel = $env:LLAMA_ARG_N_PARALLEL
    try {
        $env:LLAMA_ARG_N_PARALLEL = [string]$RuntimeLock.parallel
        $Process = Start-Process -FilePath $Binary -ArgumentList $Arguments `
            -WorkingDirectory (Split-Path -Parent $Binary) `
            -RedirectStandardOutput $Paths.StdoutLog `
            -RedirectStandardError $Paths.StderrLog `
            -WindowStyle Hidden -PassThru
    }
    finally {
        if ($null -eq $PreviousParallel) {
            Remove-Item Env:LLAMA_ARG_N_PARALLEL -ErrorAction SilentlyContinue
        }
        else {
            $env:LLAMA_ARG_N_PARALLEL = $PreviousParallel
        }
    }

    [ordered]@{
        schema_version = '1.0.0'
        pid = $Process.Id
        endpoint = [string]$RuntimeLock.endpoint
        device = [string]$Device.id
        models = @($Models)
        runtime_models = @($RuntimeModels)
        started_at = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Paths.ProcessState -Encoding utf8

    try {
        $Inventory = Wait-IntelVulkanApi -BaseUrl ([string]$RuntimeLock.endpoint) -TimeoutSeconds $TimeoutSeconds
        foreach ($Model in $Models) {
            $null = Resolve-IntelVulkanRuntimeModelId -Inventory $Inventory -LogicalModel $Model
        }
    }
    catch {
        $null = Stop-IntelVulkanServer -StatePath $Paths.ProcessState -Confirm:$false
        $Tail = if (Test-Path -LiteralPath $Paths.StderrLog) {
            (Get-Content -LiteralPath $Paths.StderrLog -Tail 120) -join "`n"
        }
        else { '<stderr absent>' }
        throw "$($_.Exception.Message)`nDernières lignes Vulkan:`n$Tail"
    }

    Write-Host "OK  Routeur llama.cpp Intel Vulkan prêt PID=$($Process.Id) endpoint=$($RuntimeLock.endpoint)."
    return [pscustomobject]@{
        Process = $Process
        RuntimeLock = $RuntimeLock
        Paths = $Paths
        Device = $Device
        Models = @($Models)
        RuntimeModels = @($RuntimeModels)
        Inventory = $Inventory
    }
}

function Invoke-IntelVulkanChatSmoke {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model,
        [int]$TimeoutSeconds = 180
    )

    $Inventory = Invoke-RestMethod -Method Get -Uri "$BaseUrl/models?reload=1" -TimeoutSec 10
    $RuntimeModel = Resolve-IntelVulkanRuntimeModelId -Inventory $Inventory -LogicalModel $Model
    $Body = @{
        model = $RuntimeModel
        messages = @(@{ role = 'user'; content = 'Réponds uniquement LOCAL_OK.' })
        temperature = 0
        max_tokens = 32
        stream = $false
        chat_template_kwargs = @{ enable_thinking = $false }
    } | ConvertTo-Json -Depth 8 -Compress
    $Started = [DateTimeOffset]::UtcNow
    $Response = Invoke-RestMethod -Method Post -Uri "$BaseUrl/chat/completions" `
        -ContentType 'application/json' -Body $Body -TimeoutSec $TimeoutSeconds
    $WallMs = ([DateTimeOffset]::UtcNow - $Started).TotalMilliseconds
    $Content = [string]$Response.choices[0].message.content
    if (-not $Content.Trim()) {
        throw "Smoke Vulkan vide pour $RuntimeModel."
    }
    return [pscustomobject]@{
        model = $Model
        runtime_model = $RuntimeModel
        wall_ms = [math]::Round($WallMs, 1)
        tokens_per_second = $Response.timings.predicted_per_second
        prompt_tokens_per_second = $Response.timings.prompt_per_second
        content = $Content.Trim()
    }
}

function Invoke-IntelVulkanModelUnload {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Model,
        [int]$TimeoutSeconds = 90
    )

    $RouterBase = $BaseUrl -replace '/v1/?$', ''
    $Body = @{ model = $Model } | ConvertTo-Json -Compress
    $null = Invoke-RestMethod -Method Post -Uri "$RouterBase/models/unload" `
        -ContentType 'application/json' -Body $Body -TimeoutSec 15
    $Deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $Inventory = Invoke-RestMethod -Method Get -Uri "$BaseUrl/models?reload=1" -TimeoutSec 10
        $Entry = @($Inventory.data | Where-Object { [string]$_.id -ieq $Model }) | Select-Object -First 1
        if (-not $Entry -or [string]$Entry.status.value -eq 'unloaded') {
            Write-Host "OK  Intel Vulkan modèle déchargé avant switch: $Model"
            return
        }
        Start-Sleep -Milliseconds 750
    } while ([DateTimeOffset]::UtcNow -lt $Deadline)
    throw "Timeout déchargement Vulkan du modèle $Model."
}
