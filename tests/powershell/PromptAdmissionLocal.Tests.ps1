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

    It 'sépare le JSON stdout des diagnostics stderr OpenClaw' {
        $script:Admission | Should -Not -Match ([regex]::Escape('2>&1'))
        $script:Admission | Should -Match ([regex]::Escape('1> $StdoutPath 2> $StderrPath'))
        $script:Admission | Should -Match ([regex]::Escape('$Payload = $StdoutText | ConvertFrom-Json'))
        $script:Admission | Should -Match ([regex]::Escape("schema_version = '1.2.0'"))
        $script:Admission | Should -Match ([regex]::Escape('stderr = $StderrText'))
        $script:Admission | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $StdoutPath'))
        $script:Admission | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $StderrPath'))
    }

    It 'lit meta à la racine de l enveloppe locale OpenClaw 2026.9.4 avant le fallback result.meta' {
        $script:Admission | Should -Match 'function Get-AgentMeta'
        $RootMetaIndex = $script:Admission.IndexOf("`$RootMeta = `$Payload.PSObject.Properties['meta']")
        $NestedMetaIndex = $script:Admission.IndexOf("`$NestedMeta = `$Result.Value.PSObject.Properties['meta']")
        $RootMetaIndex | Should -BeGreaterOrEqual 0
        $NestedMetaIndex | Should -BeGreaterThan $RootMetaIndex
        $script:Admission | Should -Match ([regex]::Escape('$Meta = Get-AgentMeta -Payload $Payload'))
        $script:Admission | Should -Match ([regex]::Escape("`$ReportProperty = `$Meta.PSObject.Properties['systemPromptReport']"))
    }

    It 'conserve la mesure runtime stricte du prompt skills à zéro' {
        $script:Admission | Should -Match 'PROMPT_ADMISSION_SKILLS_CHARS='
        $script:Admission | Should -Match 'systemPromptReport\.skills\.promptChars absent'
        $script:Admission | Should -Match 'skillsPromptChars=.*attendu=0'
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