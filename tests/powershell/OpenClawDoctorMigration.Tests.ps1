Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Migration OpenClaw doctor avant configuration' {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:InstallFull = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\11_install_full.ps1'
        )
    }

    It 'exécute doctor fix non-interactif dans la fenêtre d écriture' {
        $script:InstallFull | Should -Match ([regex]::Escape(
            '& $OpenClaw doctor --fix --non-interactive'
        ))
        $script:InstallFull | Should -Match 'Invoke-OpenClawConfigWriteWindow -Operation'
        $script:InstallFull | Should -Match 'Migration OpenClaw doctor --fix --non-interactive en échec'
    }

    It 'prépare l état local avant doctor puis configure OpenClaw après la migration' {
        $StateIndex = $script:InstallFull.IndexOf("`$env:OPENCLAW_STATE_DIR = Join-Path `$PlatformRoot 'state'")
        $DoctorIndex = $script:InstallFull.IndexOf('& $OpenClaw doctor --fix --non-interactive')
        $ConfigureIndex = $script:InstallFull.IndexOf(
            "Invoke-ScriptChecked -Path `$ConfigureOpenClaw -Description 'Configuration OpenClaw'"
        )
        $ReadOnlyIndex = $script:InstallFull.IndexOf('Assert-OpenClawReadOnlySteadyState', $ConfigureIndex)

        $StateIndex | Should -BeGreaterOrEqual 0
        $DoctorIndex | Should -BeGreaterThan $StateIndex
        $ConfigureIndex | Should -BeGreaterThan $DoctorIndex
        $ReadOnlyIndex | Should -BeGreaterThan $ConfigureIndex
    }

    It 'annonce la migration dans le dry-run sans contourner le gate' {
        $script:InstallFull | Should -Match 'DRY-RUN.*doctor --fix --non-interactive'
        $script:InstallFull | Should -Match 'process READONLY=0 uniquement pendant doctor/configure-openclaw'
        $script:InstallFull | Should -Not -Match 'AllowRuntimeDrift.*doctor'
    }
}
