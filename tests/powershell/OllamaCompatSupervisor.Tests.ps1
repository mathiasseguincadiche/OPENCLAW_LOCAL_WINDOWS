Describe 'Ollama OpenClaw compatibility supervisor' {
    BeforeAll {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:Supervisor = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\28_ollama_compat_supervisor.ps1'
        )
        $script:Installer = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\11_install_full.ps1'
        )
        $script:Configurator = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\08_configure_openclaw.ps1'
        )
    }

    It 'locks the compatibility proxy to loopback and the exact Ministral model' {
        $script:Supervisor | Should -Match ([regex]::Escape(
            "`$TaskName = 'OPENCLAW_LOCAL Ollama Compat'"
        ))
        $script:Supervisor | Should -Match '\$ListenPort = 11436'
        $script:Supervisor | Should -Match ([regex]::Escape(
            "`$ExpectedUpstream = 'http://127.0.0.1:11434'"
        ))
        $script:Supervisor | Should -Match 'Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M'
        $script:Supervisor | Should -Match '__openclaw_compat_health'
    }

    It 'installs a managed Task Scheduler wrapper and verified proxy copy' {
        $script:Supervisor | Should -Match ([regex]::Escape(
            'Register-ScheduledTask -TaskName $TaskName'
        ))
        $script:Supervisor | Should -Match 'ollama_openclaw_compat_proxy\.py'
        $script:Supervisor | Should -Match '55_ollama_openclaw_compat_proxy\.py'
        $script:Supervisor | Should -Match 'Get-FileHash -Algorithm SHA256'
        $script:Supervisor | Should -Match 'RestartCount 5'
        $script:Supervisor | Should -Match 'MultipleInstances IgnoreNew'
    }

    It 'requires Ollama upstream before declaring the compat supervisor ready' {
        $script:Supervisor | Should -Match 'function Test-OllamaUpstreamReady'
        $script:Supervisor | Should -Match '\$ExpectedUpstream/api/tags'
        $script:Supervisor | Should -Match 'upstream_ready'
        $script:Supervisor | Should -Match ([regex]::Escape(
            '.\menu.ps1 -Action configure-local'
        ))
        $script:Supervisor | Should -Match (
            '(?s)function Start-OllamaCompatSupervisor.*' +
            'Test-OllamaUpstreamReady.*Test-OllamaCompatHealth'
        )
    }

    It 'starts the compatibility proxy before OpenClaw configuration in install-full' {
        $script:Installer | Should -Match '28_ollama_compat_supervisor\.ps1'
        $InstallIndex = $script:Installer.IndexOf(
            "Action = 'install'",
            [System.StringComparison]::Ordinal
        )
        $StartIndex = $script:Installer.IndexOf(
            "Action = 'start'",
            [System.StringComparison]::Ordinal
        )
        $ConfigureIndex = $script:Installer.IndexOf(
            'Invoke-OpenClawConfigWriteWindow',
            [System.StringComparison]::Ordinal
        )
        $InstallIndex | Should -BeGreaterThan -1
        $StartIndex | Should -BeGreaterThan $InstallIndex
        $ConfigureIndex | Should -BeGreaterThan $StartIndex
    }

    It 'requires compatibility health before nominal ollama-vulkan admission' {
        $script:Configurator | Should -Match 'Test-OllamaCompatReady'
        $script:Configurator | Should -Match 'http://127\.0\.0\.1:11436/__openclaw_compat_health'
        $script:Configurator | Should -Match (
            '(?s)if \(\$BackendId -eq ''ollama-vulkan''\).*' +
            'Test-OllamaReady.*Test-OllamaCompatReady'
        )
    }
}
