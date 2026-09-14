[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($DryRun -and $Apply) {
    throw 'Les options -DryRun et -Apply sont mutuellement exclusives.'
}

$Repository = 'mathiasseguincadiche/OPENCLAW_LOCAL_WINDOWS'
$TargetDescription = 'Plateforme IA multi-agents local-only côté LLM pour Windows 11 : OpenClaw + Ollama, routage local hybride et qualification Intel Arc B580.'
$TargetTopics = @(
    'openclaw',
    'ollama',
    'local-ai',
    'local-llm',
    'multi-agent',
    'windows-11',
    'intel-arc',
    'powershell',
    'python',
    'devops',
    'llm'
)

function Invoke-GhJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh a échoué : $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') est requis. Installer puis exécuter 'gh auth login'."
}

& gh auth status --hostname github.com *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Aucune authentification GitHub CLI valide. Exécuter 'gh auth login' puis relancer."
}

$current = Invoke-GhJson -Arguments @('api', "repos/$Repository") | ConvertFrom-Json
$currentTopics = @($current.topics | Sort-Object)
$expectedTopics = @($TargetTopics | Sort-Object)

$descriptionMatches = [string]$current.description -eq $TargetDescription
$topicsMatch = ($currentTopics.Count -eq $expectedTopics.Count) -and -not (Compare-Object -ReferenceObject $expectedTopics -DifferenceObject $currentTopics)

Write-Host "REPOSITORY=$Repository"
Write-Host "CURRENT_DESCRIPTION=$($current.description)"
Write-Host "TARGET_DESCRIPTION=$TargetDescription"
Write-Host "CURRENT_TOPICS=$($currentTopics -join ',')"
Write-Host "TARGET_TOPICS=$($expectedTopics -join ',')"

if ($descriptionMatches -and $topicsMatch) {
    Write-Host 'GITHUB_METADATA=ALREADY_COMPLIANT'
    exit 0
}

if ($DryRun -or -not $Apply) {
    Write-Host 'GITHUB_METADATA=DRIFT_DETECTED'
    Write-Host 'DRY_RUN=true'
    Write-Host 'Relancer avec -Apply pour corriger la description et les topics.'
    exit 0
}

Invoke-GhJson -Arguments @(
    'api',
    '--method', 'PATCH',
    "repos/$Repository",
    '-f', "description=$TargetDescription"
) | Out-Null

$topicsPayload = @{ names = $TargetTopics } | ConvertTo-Json -Compress
$topicsResult = $topicsPayload | & gh api --method PUT "repos/$Repository/topics" --input - 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Mise à jour des topics échouée : $($topicsResult -join [Environment]::NewLine)"
}

$verified = Invoke-GhJson -Arguments @('api', "repos/$Repository") | ConvertFrom-Json
$verifiedTopics = @($verified.topics | Sort-Object)
$verifiedDescriptionMatches = [string]$verified.description -eq $TargetDescription
$verifiedTopicsMatch = ($verifiedTopics.Count -eq $expectedTopics.Count) -and -not (Compare-Object -ReferenceObject $expectedTopics -DifferenceObject $verifiedTopics)

if (-not ($verifiedDescriptionMatches -and $verifiedTopicsMatch)) {
    throw 'La vérification post-écriture indique que les métadonnées GitHub ne correspondent pas à la cible.'
}

Write-Host 'GITHUB_METADATA=COMPLIANT'
Write-Host 'DESCRIPTION_UPDATED=true'
Write-Host 'TOPICS_UPDATED=true'
