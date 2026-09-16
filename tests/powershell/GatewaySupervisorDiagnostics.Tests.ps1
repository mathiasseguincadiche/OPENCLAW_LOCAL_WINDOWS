Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Diagnostic superviseur Gateway Windows' {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:Diagnostic = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\27_gateway_supervisor_diagnostics.ps1'
        )
    }

    It 'reste strictement ciblé sur la tâche Gateway externe et le port loopback attendu' {
        $script:Diagnostic | Should -Match ([regex]::Escape("`$TaskName = 'OPENCLAW_LOCAL Gateway'"))
        $script:Diagnostic | Should -Match ([regex]::Escape("`$GatewayPort = 18789"))
        $script:Diagnostic | Should -Match 'Get-NetTCPConnection'
        $script:Diagnostic | Should -Match 'Get-CimInstance'
    }

    It 'classe les résultats Task Scheduler connus sans masquer les codes inattendus' {
        $script:Diagnostic | Should -Match '0x00041301'
        $script:Diagnostic | Should -Match 'running'
        $script:Diagnostic | Should -Match '0xC000013A'
        $script:Diagnostic | Should -Match 'control_event_termination'
        $script:Diagnostic | Should -Match 'unexpected'
    }

    It 'capture le journal Task Scheduler Operational de façon explicite' {
        $script:Diagnostic | Should -Match 'Microsoft-Windows-TaskScheduler/Operational'
        $script:Diagnostic | Should -Match 'EventLogConfiguration'
        $script:Diagnostic | Should -Match 'Get-WinEvent'
        $script:Diagnostic | Should -Match "ValidateSet\('status', 'enable-log', 'proof'\)"
    }

    It 'corrèle tâche listener et readiness RPC dans une preuve JSON' {
        $script:Diagnostic | Should -Match 'Get-ScheduledTaskInfo'
        $script:Diagnostic | Should -Match "'gateway' 'status' '--require-rpc' '--json'"
        $script:Diagnostic | Should -Match 'gateway_supervisor_diagnostic_'
        $script:Diagnostic | Should -Match 'ConvertTo-Json -Depth 8'
    }

    It 'supporte un DryRun sans mutation de la machine' {
        $script:Diagnostic | Should -Match '\[switch\]\$DryRun'
        $script:Diagnostic | Should -Match '\[DRY-RUN\] Diagnostic du superviseur Gateway externe Windows\.'
        $script:Diagnostic | Should -Match 'proof écrit sous <root>\\proofs\\gateway uniquement avec -Action proof\.'
    }
}
