Describe 'OpenClaw agent transport diagnostic' {
    It 'verifies the temporary config selector and selected provider proxy base URL before the agent call' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Diagnostic = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\27_diagnose_openclaw_agent_transport.ps1'
        )

        $Diagnostic | Should -Match "'config' 'file' '--json'"
        $Diagnostic | Should -Match '\$ProviderConfigPath\s*=\s*"models\.providers\.\$ProviderId\.baseUrl"'
        $Diagnostic | Should -Match "'config' 'get' \$ProviderConfigPath '--json'"
        $Diagnostic | Should -Match 'TRANSPORT_CAPTURE_PROVIDER='
        $Diagnostic | Should -Match 'TRANSPORT_CAPTURE_UPSTREAM='
        $Diagnostic | Should -Match 'OPENCLAW_CONFIG_READONLY'
        $Diagnostic | Should -Match 'TRANSPORT_CAPTURE_CONFIG_PATH='
        $Diagnostic | Should -Match 'TRANSPORT_CAPTURE_BASE_URL='
    }

    It 'supports both direct Ollama and the managed Ministral compatibility endpoint' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Diagnostic = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\27_diagnose_openclaw_agent_transport.ps1'
        )

        $Diagnostic | Should -Match '11434\|11436'
        $Diagnostic | Should -Match '\$ProviderId = \$ModelRef\.Substring'
        $Diagnostic | Should -Match '\$TempProviderProperty\.Value\.baseUrl = \$ProxyUrl'
        $Diagnostic | Should -Not -Match '\$TempConfig\.models\.providers\.ollama\.baseUrl = \$ProxyUrl'
    }

    It 'preserves agent stdout and stderr evidence when no proxy request is observed' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Diagnostic = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\27_diagnose_openclaw_agent_transport.ps1'
        )

        $Diagnostic | Should -Match 'openclaw_transport_agent_\$\{Stamp\}\.stdout\.txt'
        $Diagnostic | Should -Match 'openclaw_transport_agent_\$\{Stamp\}\.stderr\.txt'
        $Diagnostic | Should -Match 'agent_stdout_path'
        $Diagnostic | Should -Match 'agent_stderr_path'
        $Diagnostic | Should -Not -Match 'Remove-Item -LiteralPath \$AgentStdoutPath'
        $Diagnostic | Should -Not -Match 'Remove-Item -LiteralPath \$AgentStderrPath'
    }

    It 'keeps exactly one captured request as an array under strict mode' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Diagnostic = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\27_diagnose_openclaw_agent_transport.ps1'
        )

        $Diagnostic | Should -Match '(?s)\$Records\s*=\s*@\(\s*if \(Test-Path -LiteralPath \$CapturePath\)'
        $Diagnostic | Should -Match '\$RecordCount\s*=\s*@\(\$Records\)\.Count'
        $Diagnostic | Should -Match '\$PrimaryRecordCount\s*=\s*@\(\$PrimaryRecords\)\.Count'
        $Diagnostic | Should -Not -Match '\$Records\s*=\s*if \(Test-Path -LiteralPath \$CapturePath\)'
    }

    It 'isolates the local agent state from a running canonical Gateway' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Diagnostic = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\27_diagnose_openclaw_agent_transport.ps1'
        )

        $Diagnostic | Should -Match '\$DiagnosticStateDir\s*=\s*Join-Path \$ProofsRoot "\.openclaw_transport_state_\$\{Stamp\}"'
        $Diagnostic | Should -Match ([regex]::Escape("Invoke-ProcessEnvironmentValue -Name 'OPENCLAW_STATE_DIR' -Value `$DiagnosticStateDir"))
        $Diagnostic | Should -Not -Match ([regex]::Escape("Invoke-ProcessEnvironmentValue -Name 'OPENCLAW_STATE_DIR' -Value `$CanonicalStateDir"))
        $Diagnostic | Should -Match 'TRANSPORT_CAPTURE_STATE_DIR='
        $Diagnostic | Should -Match 'Remove-Item -LiteralPath \$DiagnosticStateDir -Recurse -Force'
    }

    It 'keeps the canonical OpenClaw config untouched' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Diagnostic = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\27_diagnose_openclaw_agent_transport.ps1'
        )

        $Diagnostic | Should -Match '\.openclaw_transport_\$\{Stamp\}\.json'
        $Diagnostic | Should -Match 'Remove-Item -LiteralPath \$TempConfigPath'
        $Diagnostic | Should -Not -Match 'Set-Content -LiteralPath \$ConfigPath'
    }
}
