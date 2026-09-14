Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Admission prompt OpenClaw avant Gateway' {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:Admission = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\24_test_openclaw_prompt_admission.ps1'
        )
        $script:Configure = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\08_configure_openclaw.ps1'
        )
        $script:InstallFull = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\11_install_full.ps1'
        )
    }

    It 'exécute l admission directement en mode local sans dépendre du Gateway' {
        $script:Admission | Should -Match ([regex]::Escape("& `$OpenClaw 'agent' '--local' '--agent'"))
        $script:Admission | Should -Match 'PROMPT_ADMISSION_MODE='
        $script:Admission | Should -Match ([regex]::Escape("`$ExecutionMode = 'local'"))
    }

    It 'conserve le vrai gate trois familles dans configure-openclaw' {
        $script:Configure | Should -Match '24_test_openclaw_prompt_admission\.ps1'
        $script:Configure | Should -Match "'chef-operations', 'architecte-solutions', 'ingenieur-devops'"
    }

    It 'documente explicitement que le gate précède le démarrage Gateway dans install-full' {
        $ConfigureIndex = $script:InstallFull.IndexOf(
            'Invoke-ScriptChecked -Path $ConfigureOpenClaw -Description'
        )
        $GatewayIndex = $script:InstallFull.IndexOf("gateway install --runtime node --force --json")
        $ConfigureIndex | Should -BeGreaterOrEqual 0
        $GatewayIndex | Should -BeGreaterThan $ConfigureIndex
        $script:Admission | Should -Match 'précède le démarrage du Gateway'
    }
}
