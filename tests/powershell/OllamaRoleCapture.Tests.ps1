Describe 'Ollama full-agent role capture diagnostic' {
    It 'uses a temporary OpenClaw config selector instead of rewriting canonical state' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $DiagnosticScript = Join-Path $RepoRoot 'scripts\windows\26_diagnose_openclaw_ollama_roles.ps1'
        $Text = Get-Content -Raw -LiteralPath $DiagnosticScript
        $Text | Should -Match 'OPENCLAW_CONFIG_PATH'
        $Text | Should -Match '\.openclaw_role_capture_'
        $Text | Should -Match 'Remove-Item -LiteralPath \$TempConfigPath'
        $Text | Should -Not -Match 'Set-Content -LiteralPath \$ConfigPath'
    }

    It 'runs the same embedded agent path with a fresh session key' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $DiagnosticScript = Join-Path $RepoRoot 'scripts\windows\26_diagnose_openclaw_ollama_roles.ps1'
        $Text = Get-Content -Raw -LiteralPath $DiagnosticScript
        $AgentCall = "'agent' '--local' '--agent' `$AgentId"
        $Text | Should -Match ([regex]::Escape($AgentCall))
        $Text | Should -Match ([regex]::Escape('role-capture-$Stamp-$AgentId'))
        $Text | Should -Match ([regex]::Escape("'--thinking' 'off'"))
    }

    It 'preflights Ollama separately and detects proxy readiness without traversing upstream' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $DiagnosticScript = Join-Path $RepoRoot 'scripts\windows\26_diagnose_openclaw_ollama_roles.ps1'
        $Text = Get-Content -Raw -LiteralPath $DiagnosticScript
        $Text | Should -Match '\$OllamaTagsUri'
        $Text | Should -Match 'Backend Ollama non prêt pour le diagnostic'
        $Text | Should -Match 'ROLE_CAPTURE_READY='
        $Text | Should -Not -Match 'Invoke-RestMethod[^\r\n]+\$ProxyUrl/api/tags'
    }

    It 'captures request shape without persisting prompt text' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $ProxyScript = Join-Path $RepoRoot 'scripts\54_capture_ollama_request_roles.py'
        $Text = Get-Content -Raw -LiteralPath $ProxyScript
        $Text | Should -Match 'content_chars'
        $Text | Should -Match 'duplicate_non_tool_roles'
        $Text | Should -Match 'tool_names'
        $Text | Should -Not -Match 'record\["prompt"\]'
        $Text | Should -Not -Match 'record\["content"\]'
    }
}
