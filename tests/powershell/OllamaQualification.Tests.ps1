Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Qualification Ollama lisible et bornée' {
    It 'utilise l API chat locale pour le smoke test et non ollama run' {
        $TestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Verify = Get-Content -Raw -LiteralPath (
            Join-Path $TestRepoRoot 'scripts\windows\04_verify_local.ps1'
        )
        $Verify | Should -Match '/api/chat'
        $Verify | Should -Match '/api/ps'
        $Verify | Should -Match 'stream = \$false'
        $Verify | Should -Match 'think = \$false'
        $Verify | Should -Match '\$InitialSmokeMaxTokens = 64'
        $Verify | Should -Match '\$ReasoningRetryMaxTokens = 512'
        $Verify | Should -Match 'Invoke-OllamaSmokeRequest'
        $Verify | Should -Match 'thinking_length -gt 0'
        $Verify | Should -Match "done_reason -eq 'length'"
        $Verify | Should -Match 'Reasoning smoke retry'
        $Verify | Should -Match 'thinking_chars='
        $Verify | Should -Match 'done_reason='
        $Verify | Should -Not -Match "qwen3\.5:\*"
        $Verify | Should -Not -Match '/api/generate'
        $Verify | Should -Not -Match '& ollama run'
    }

    It 'exécute verify benchmark et qualification avec le Python géré OPENCLAW_LOCAL' {
        $TestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        foreach ($RelativePath in @(
            'scripts\windows\04_verify_local.ps1',
            'scripts\windows\05_benchmark.ps1',
            'scripts\windows\07_run_qualification.ps1'
        )) {
            $Script = Get-Content -Raw -LiteralPath (Join-Path $TestRepoRoot $RelativePath)
            $Script | Should -Match 'python_runtime\.ps1'
            $Script | Should -Match 'Enable-ClawLocalManagedPython'
            $Script | Should -Match '& \$ManagedPython'
            $Script | Should -Not -Match '&\s+python(?:\.exe)?\b'
        }
    }

    It 'auto-active le runtime géré dans les CLI Python sensibles sous Windows' {
        $TestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        foreach ($RelativePath in @(
            'scripts\20_list_models.py',
            'scripts\48_model_identity_lock.py'
        )) {
            $Script = Get-Content -Raw -LiteralPath (Join-Path $TestRepoRoot $RelativePath)
            $Script | Should -Match 'runtime.*venv.*Scripts.*python\.exe'
            $Script | Should -Match 'os\.execv'
            $Script | Should -Match 'sys\.executable'
        }
        $ListModels = Get-Content -Raw -LiteralPath (
            Join-Path $TestRepoRoot 'scripts\20_list_models.py'
        )
        $ListModels | Should -Match 'E:/AI/OpenClawLocal'
        $ListModels | Should -Match 'LOCALAPPDATA'
    }

    It 'transmet Quick au benchmark depuis le menu' {
        $TestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Output = & pwsh -NoLogo -NoProfile -File (Join-Path $TestRepoRoot 'menu.ps1') `
            -Action benchmark -Quick -DryRun 2>&1
        $LASTEXITCODE | Should -Be 0
        $Text = $Output -join "`n"
        $Text | Should -Match '--context 8192'
        $Text | Should -Match '--qwen-thinking off'
        $Text | Should -Match '36 cas'
        $Text | Should -Match 'Python géré OPENCLAW_LOCAL'
    }

    It 'annonce le plan complet HARD-40M à 30 cas' {
        $TestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Output = & pwsh -NoLogo -NoProfile -File (Join-Path $TestRepoRoot 'menu.ps1') `
            -Action qualification -DryRun 2>&1
        $LASTEXITCODE | Should -Be 0
        $Text = $Output -join "`n"
        $Text | Should -Match '24 cas 8K \+ 6 cas 16K = 30 cas'
        $Text | Should -Match '3 probes dédiés'
        $Text | Should -Match 'HARD LIMIT qualification complète: 2400 s'
        $Text | Should -Match 'premier token'
    }

    It 'verrouille le budget mural et la marge Qwen native' {
        $TestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Qualification = Get-Content -Raw -LiteralPath (
            Join-Path $TestRepoRoot 'scripts\windows\07_run_qualification.ps1'
        )
        $Benchmark = Get-Content -Raw -LiteralPath (
            Join-Path $TestRepoRoot 'scripts\windows\05_benchmark.ps1'
        )
        $Policy = Get-Content -Raw -LiteralPath (
            Join-Path $TestRepoRoot 'config\v1\qualification_policy.yaml'
        )
        $Launcher = Get-Content -Raw -LiteralPath (
            Join-Path $TestRepoRoot 'scripts\benchmark_qualification_40m_v2.py'
        )
        $Qualification | Should -Match '\$QualificationMaxWallSeconds = 2400'
        $Qualification | Should -Match '\$EvaluationReserveSeconds = 60'
        $Qualification | Should -Match 'Assert-QualificationBudget'
        $Qualification | Should -Match 'MaxWallSeconds \$BenchmarkBudgetSeconds'
        $Benchmark | Should -Match 'benchmark_qualification_40m_v2\.py'
        $Benchmark | Should -Match 'timeout par cas 210 s'
        $Policy | Should -Match 'max_case_wall_seconds: 210'
        $Launcher | Should -Match 'QWEN_NATIVE_MAX_OUTPUT_TOKENS = 1024'
    }

    It 'transmet Quick à la qualification depuis le menu' {
        $TestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Output = & pwsh -NoLogo -NoProfile -File (Join-Path $TestRepoRoot 'menu.ps1') `
            -Action qualification -Quick -DryRun 2>&1
        $LASTEXITCODE | Should -Be 0
        $Text = $Output -join "`n"
        $Text | Should -Match 'mode QUICK'
        $Text | Should -Match 'thinking Qwen désactivé'
        $Text | Should -Match '36 cas'
        $Text | Should -Match 'environnement géré OPENCLAW_LOCAL'
    }
}

Describe 'Inventaire VRAM Windows fiable' {
    It 'préfère QWORD et ne traite pas le fallback 32 bits comme fiable' {
        $TestRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $InventoryHelper = Get-Content -Raw -LiteralPath (
            Join-Path $TestRepoRoot 'scripts\windows\lib\hardware_inventory.ps1'
        )
        $InventoryHelper | Should -Match 'HardwareInformation\.qwMemorySize'
        $InventoryHelper | Should -Match 'windows_registry_hardware_information_qword'
        $InventoryHelper | Should -Match 'HardwareInformation\.MemorySize'
        $InventoryHelper | Should -Match 'windows_registry_hardware_information_legacy32'
        $InventoryHelper | Should -Match 'reliable = \$IsQword'
    }
}