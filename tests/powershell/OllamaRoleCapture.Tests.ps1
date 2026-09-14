$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$DiagnosticScript = Join-Path $RepoRoot 'scripts\windows\26_diagnose_openclaw_ollama_roles.ps1'
$ProxyScript = Join-Path $RepoRoot 'scripts\54_capture_ollama_request_roles.py'
$DiagnosticText = Get-Content -Raw -LiteralPath $DiagnosticScript
$ProxyText = Get-Content -Raw -LiteralPath $ProxyScript

Describe 'Ollama full-agent role capture diagnostic' {
    It 'uses a temporary OpenClaw config selector instead of rewriting canonical state' {
        $DiagnosticText | Should -Match 'OPENCLAW_CONFIG_PATH'
        $DiagnosticText | Should -Match '\.openclaw_role_capture_'
        $DiagnosticText | Should -Match 'Remove-Item -LiteralPath \$TempConfigPath'
        $DiagnosticText | Should -Not -Match 'Set-Content -LiteralPath \$ConfigPath'
    }

    It 'runs the same embedded agent path with a fresh session key' {
        $DiagnosticText | Should -Match "'agent' '--local' '--agent' \$AgentId"
        $DiagnosticText | Should -Match 'role-capture-\$Stamp-\$AgentId'
        $DiagnosticText | Should -Match "'--thinking' 'off'"
    }

    It 'captures request shape without persisting prompt text' {
        $ProxyText | Should -Match 'content_chars'
        $ProxyText | Should -Match 'duplicate_non_tool_roles'
        $ProxyText | Should -Match 'tool_names'
        $ProxyText | Should -Not -Match 'record\["prompt"\]'
        $ProxyText | Should -Not -Match 'record\["content"\]'
    }
}
