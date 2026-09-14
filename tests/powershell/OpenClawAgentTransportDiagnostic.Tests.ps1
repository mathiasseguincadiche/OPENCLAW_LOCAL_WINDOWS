Describe 'OpenClaw agent transport diagnostic' {
    It 'verifies the temporary config selector and proxy base URL before the agent call' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Diagnostic = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\27_diagnose_openclaw_agent_transport.ps1'
        )

        $Diagnostic | Should -Match "'config' 'file' '--json'"
        $Diagnostic | Should -Match "'config' 'get' 'models.providers.ollama.baseUrl' '--json'"
        $Diagnostic | Should -Match 'OPENCLAW_CONFIG_READONLY'
        $Diagnostic | Should -Match 'TRANSPORT_CAPTURE_CONFIG_PATH='
        $Diagnostic | Should -Match 'TRANSPORT_CAPTURE_BASE_URL='
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
