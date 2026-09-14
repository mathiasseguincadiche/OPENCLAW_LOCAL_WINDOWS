[CmdletBinding()]
param(
    [switch]$DryRun,
    [ValidateSet('ollama-vulkan', 'b580-hybrid')]
    [string]$Backend = 'ollama-vulkan'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Configure = Join-Path $PSScriptRoot '08_configure_openclaw.ps1'
$ReadOnlyGuard = Join-Path $PSScriptRoot 'lib\openclaw_readonly.ps1'

if (-not (Test-Path -LiteralPath $Configure)) {
    throw "Configurateur OpenClaw introuvable: $Configure"
}
if (-not (Test-Path -LiteralPath $ReadOnlyGuard)) {
    throw "Garde READONLY OpenClaw introuvable: $ReadOnlyGuard"
}
. $ReadOnlyGuard

if ($DryRun) {
    & $Configure -DryRun -Backend $Backend
    exit $LASTEXITCODE
}

Invoke-OpenClawConfigWriteWindow -Operation {
    & $Configure -Backend $Backend
    if ($LASTEXITCODE -ne 0) {
        throw "Configuration OpenClaw en échec (code $LASTEXITCODE)."
    }
}
Assert-OpenClawReadOnlySteadyState
exit 0
