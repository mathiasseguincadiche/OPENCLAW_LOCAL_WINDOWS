Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Gateway OpenClaw relocalisé sous superviseur externe' {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:Supervisor = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\26_gateway_external_supervisor.ps1'
        )
        $script:Installer = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\11_install_full.ps1'
        )
    }

    It 'déclare explicitement le contrat de supervision externe OpenClaw 2026.9.4' {
        $script:Supervisor | Should -Match ([regex]::Escape("`$env:OPENCLAW_SUPERVISOR_MODE = 'external'"))
        $script:Supervisor | Should -Match ([regex]::Escape("`$env:OPENCLAW_SERVICE_REPAIR_POLICY = 'external'"))
        $script:Supervisor | Should -Match ([regex]::Escape("`$env:OPENCLAW_CONFIG_READONLY = '1'"))
        $script:Supervisor | Should -Match 'OPENCLAW_STATE_DIR'
        $script:Supervisor | Should -Match 'OPENCLAW_CONFIG_PATH'
    }

    It 'lance le Gateway avec le runtime géré et non avec le service natif OpenClaw' {
        $script:Supervisor | Should -Match ([regex]::Escape("& `$OpenClaw 'gateway' 'run'"))
        $script:Supervisor | Should -Match 'runtime\\npm-global\\openclaw\.cmd'
        $script:Supervisor | Should -Not -Match 'gateway\s+install'
        $script:Supervisor | Should -Not -Match 'gateway\s+start'
    }

    It 'installe un Scheduled Task au logon avec reprise bornée' {
        $script:Supervisor | Should -Match 'Register-ScheduledTask'
        $script:Supervisor | Should -Match 'New-ScheduledTaskTrigger -AtLogOn'
        $script:Supervisor | Should -Match 'RestartCount 5'
        $script:Supervisor | Should -Match 'MultipleInstances IgnoreNew'
        $script:Supervisor | Should -Match 'OPENCLAW_LOCAL Gateway'
    }

    It 'fait utiliser le superviseur externe par install-full' {
        $script:Installer | Should -Match '26_gateway_external_supervisor\.ps1'
        $script:Installer | Should -Match ([regex]::Escape("Action = 'install'"))
        $script:Installer | Should -Match ([regex]::Escape("Action = 'start'"))
        $script:Installer | Should -Match ([regex]::Escape("`$env:OPENCLAW_SUPERVISOR_MODE = 'external'"))
        $script:Installer | Should -Match ([regex]::Escape("`$env:OPENCLAW_SERVICE_REPAIR_POLICY = 'external'"))
        $script:Installer | Should -Not -Match 'gateway install --runtime node'
        $script:Installer | Should -Not -Match 'gateway start --json'
    }

    It 'conserve la readiness RPC et le diagnostic fail-closed' {
        $script:Installer | Should -Match 'Wait-OpenClawGatewayReady'
        $script:Installer | Should -Match 'Write-OpenClawGatewayDiagnostic'
        $script:Installer | Should -Match 'GATEWAY_FAILURE_CLASS='
        $script:Installer | Should -Match 'GATEWAY_DIAGNOSTIC='
    }
}
