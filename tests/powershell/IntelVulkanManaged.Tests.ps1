Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Intel Vulkan managed B580 hybrid runtime' {
    BeforeAll {
        $script:HybridRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:HybridRuntime = Get-Content -Raw -LiteralPath (
            Join-Path $script:HybridRepoRoot 'config\v1\runtime_versions.json'
        ) | ConvertFrom-Json
        $script:HybridBackends = Get-Content -Raw -LiteralPath (
            Join-Path $script:HybridRepoRoot 'config\v1\runtime_backends.yaml'
        )
        $script:VulkanHelper = Get-Content -Raw -LiteralPath (
            Join-Path $script:HybridRepoRoot 'scripts\windows\lib\intel_vulkan.ps1'
        )
        $script:B580Helper = Get-Content -Raw -LiteralPath (
            Join-Path $script:HybridRepoRoot 'scripts\windows\lib\intel_b580.ps1'
        )
        $script:HybridConfigure = Get-Content -Raw -LiteralPath (
            Join-Path $script:HybridRepoRoot 'scripts\windows\08_configure_openclaw.ps1'
        )
        $script:HybridE2E = Get-Content -Raw -LiteralPath (
            Join-Path $script:HybridRepoRoot 'scripts\windows\10_test_openclaw_e2e.ps1'
        )
        $script:HybridMenu = Get-Content -Raw -LiteralPath (
            Join-Path $script:HybridRepoRoot 'menu.ps1'
        )
    }

    It 'verrouille le runtime Vulkan géré sur son endpoint local' {
        [string]$script:HybridRuntime.llama_cpp_vulkan.release | Should -Be 'b10621'
        [string]$script:HybridRuntime.llama_cpp_vulkan.asset |
            Should -Be 'llama-b10621-bin-win-vulkan-x64.zip'
        [string]$script:HybridRuntime.llama_cpp_vulkan.sha256 |
            Should -Be '2672d85bf87c8280d94dee01eb6a86280046878f70a07d786a93637fa9081163'
        [string]$script:HybridRuntime.llama_cpp_vulkan.endpoint |
            Should -Be 'http://127.0.0.1:8081/v1'
        [int]$script:HybridRuntime.llama_cpp_vulkan.listen_port | Should -Be 8081
        [int]$script:HybridRuntime.llama_cpp_vulkan.models_max | Should -Be 1
        [int]$script:HybridRuntime.llama_cpp_vulkan.parallel | Should -Be 1
        [int]$script:HybridRuntime.llama_cpp_vulkan.context_tokens | Should -Be 8192
        [string]$script:HybridRuntime.llama_cpp_vulkan.gpu_layers | Should -Be 'auto'
        @($script:HybridRuntime.llama_cpp_vulkan.managed_models) |
            Should -Be @(
                'gemma4:12b-it-q4_K_M',
                'hf.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M'
            )
    }

    It 'gère intégrité B580 mono-modèle et réutilise les blobs GGUF Ollama' {
        $script:VulkanHelper | Should -Match 'Get-FileHash'
        $script:VulkanHelper | Should -Match 'runtime-manifest\.json'
        $script:VulkanHelper | Should -Match 'server\.json'
        $script:VulkanHelper | Should -Match 'Get-NetTCPConnection'
        $script:VulkanHelper | Should -Match "'--models-max'"
        $script:VulkanHelper | Should -Match "'--models-autoload'"
        $script:VulkanHelper | Should -Match "'--gpu-layers'"
        $script:VulkanHelper | Should -Match "'--fit', 'on'"
        $script:VulkanHelper | Should -Match "'--device'"
        $script:VulkanHelper | Should -Match 'LLAMA_ARG_N_PARALLEL'
        $script:VulkanHelper | Should -Match 'Arc.*B580'
        $script:VulkanHelper | Should -Match 'Resolve-OllamaGgufPath'
        $script:VulkanHelper | Should -Match 'Invoke-IntelVulkanModelUnload'
        $script:VulkanHelper | Should -Match 'Get-IntelVulkanManagedModel'
        $script:B580Helper | Should -Match 'Resolve-OllamaGgufPath'
        $script:B580Helper | Should -Match 'ollama show'
    }

    It 'encode le profil Qwen Ollama et Gemma Ministral llama.cpp en Vulkan' {
        $script:HybridBackends | Should -Match 'b580-hybrid:'
        $script:HybridBackends | Should -Match 'qwen-max:\s*ollama-vulkan'
        $script:HybridBackends | Should -Match 'gemma-deep:\s*llama-cpp-vulkan'
        $script:HybridBackends | Should -Match 'devstral-devops:\s*llama-cpp-vulkan'
        $script:HybridBackends | Should -Match 'recommended_profile:\s*b580-hybrid'
        $script:HybridBackends | Should -Match 'gpu_llm_acceleration:\s*vulkan'
        $script:HybridBackends | Should -Match 'backend_choice_locked:\s*true'
        $script:HybridBackends | Should -Match 'default_backend:\s*ollama-vulkan'
        $script:HybridBackends | Should -Match 'no_automatic_promotion:\s*true'
        $script:HybridBackends | Should -Match 'rollback_backend:\s*ollama-vulkan'
        $script:HybridBackends | Should -Match 'nominal_context_tokens:\s*8192'
    }

    It 'limite les profils OpenClaw au nominal et à l hybride Vulkan' {
        $script:HybridConfigure | Should -Match "ValidateSet\('ollama-vulkan', 'b580-hybrid'\)"
        $script:HybridConfigure | Should -Match 'INTEL_VULKAN_API_KEY'
        $script:HybridConfigure | Should -Match 'llama_cpp_vulkan'
        $script:HybridE2E | Should -Match "ValidateSet\('ollama-vulkan', 'b580-hybrid'\)"
        $script:HybridE2E | Should -Match 'Get-AgentPrimaryModelRef'
        $script:HybridE2E | Should -Match 'provider_by_agent'
        $script:HybridE2E | Should -Match 'intel-vulkan/hf\.co/mistralai/Ministral-3-14B-Reasoning-2512-GGUF:Q4_K_M'
        $script:HybridE2E | Should -Match 'vulkan-tool-ok\.txt'
        $script:HybridE2E | Should -Match 'Test-ExpectedProvider'
        $script:HybridE2E | Should -Match 'Test-GatewayTransport'
        $script:HybridE2E | Should -Match "gpu_llm_acceleration = 'vulkan'"
        $script:HybridE2E | Should -Match 'backend_choice_locked = \$true'
    }

    It 'valide le succès applicatif, affiche un heartbeat et évite exec unattended' {
        $script:HybridE2E | Should -Match 'Test-OpenClawAgentSuccess'
        $script:HybridE2E | Should -Match 'finalAssistantVisibleText'
        $script:HybridE2E | Should -Match 'liveness invalide'
        $script:HybridE2E | Should -Match '\$SmokeText -ne \$ExpectedSmokeText'
        $script:HybridE2E | Should -Match "N'utilise aucun outil"
        $script:HybridE2E | Should -Match "'--thinking', 'off'"
        $script:HybridE2E | Should -Match "N'utilise pas exec"
        $script:HybridE2E | Should -Match 'N''utilise jamais exec'
        $script:HybridE2E | Should -Match 'Ne fais aucune vérification supplémentaire'
        $script:HybridE2E | Should -Match '\$ToolText -ne ''TOOL_OK'''
        $script:HybridE2E | Should -Match 'HeartbeatSeconds = 15'
        $script:HybridE2E | Should -Match 'Start-Job'
        $script:HybridE2E | Should -Match 'Wait-Job'
        $script:HybridE2E | Should -Match 'E2E  WAIT'
        $script:HybridE2E | Should -Match 'Remove-Job'
    }

    It 'sépare le budget des smokes agents et conserve les probes ciblés bornés' {
        $script:HybridE2E | Should -Match 'AgentSmokeTimeoutSeconds = 300'
        $script:HybridE2E | Should -Match '\$SmokeTimeoutSeconds = \[Math\]::Max\(\$TimeoutSeconds, \$AgentSmokeTimeoutSeconds\)'
        $script:HybridE2E | Should -Match 'RepairTimeoutSeconds = \[Math\]::Min'
        $script:HybridE2E | Should -Match 'agent_smoke_timeout_seconds'
        $script:HybridE2E | Should -Match 'probe_timeout_seconds = \$TimeoutSeconds'
        $script:HybridE2E | Should -Match 'repair_timeout_seconds = \$RepairTimeoutSeconds'
        $script:HybridE2E | Should -Match '''--timeout'', \[string\]\$SmokeTimeoutSeconds'
        $script:HybridE2E | Should -Match '''--timeout'', \[string\]\$TimeoutSeconds'
        $script:HybridE2E | Should -Match '''--timeout'', \[string\]\$RepairTimeoutSeconds'
        $script:HybridE2E | Should -Not -Match 'ColdModelTimeoutSeconds'
        $script:HybridE2E | Should -Not -Match 'SeenModelRefs'
        $script:HybridE2E | Should -Match 'smokes groupés par modèle'
        $script:HybridE2E | Should -Match 'Ministral Reasoning reste résident'
        $script:HybridE2E | Should -Match "'auditeur-qualite',[\s\S]*'ingenieur-devops'"
    }

    It 'persiste le payload de diagnostic avant tout échec applicatif' {
        $script:HybridE2E | Should -Match 'Write-OpenClawFailureEvidence'
        $script:HybridE2E | Should -Match 'FailureEvidenceRoot'
        $script:HybridE2E | Should -Match 'openclaw_e2e_failure_'
        $script:HybridE2E | Should -Match 'E2E_FAILURE_DIAGNOSTIC='
        $script:HybridE2E | Should -Match 'payload = \$Payload'
        $script:HybridE2E | Should -Match '-FailureEvidenceRoot \$ProofsRoot'
    }

    It 'reste compatible avec la CLI OpenClaw verrouillée 2026.9.4' {
        [string]$script:HybridRuntime.openclaw.preferred | Should -Be '2026.9.4'
        $script:HybridE2E | Should -Not -Match "'agent', 'exec'"
        $script:HybridE2E | Should -Not -Match "'--cwd'"
        $script:HybridE2E | Should -Not -Match "'--auth-env-only'"
        $script:HybridE2E | Should -Match "'--agent'"
        $script:HybridE2E | Should -Match "'--model'"
        $script:HybridE2E | Should -Match "'--session-key'"
        $script:HybridE2E | Should -Match 'Get-AgentWorkspace'
        $script:HybridE2E | Should -Match "ToolAgentId = 'ingenieur-devops'"
        $script:HybridE2E | Should -Match 'agents\.entries'
        $script:HybridE2E | Should -Match 'progression visible pour chaque appel long'
    }

    It 'expose uniquement setup verify stop et le profil hybride Vulkan dans le menu' {
        foreach ($Action in @('intel-vulkan-setup', 'intel-vulkan-verify', 'intel-vulkan-stop')) {
            $script:HybridMenu | Should -Match ([regex]::Escape("'$Action'"))
            $Output = & pwsh -NoLogo -NoProfile -File (Join-Path $script:HybridRepoRoot 'menu.ps1') `
                -Action $Action -DryRun 2>&1
            $LASTEXITCODE | Should -Be 0 -Because $Action
            ($Output -join "`n") | Should -Match '(?i)DRY-RUN'
        }

        $Configure = & pwsh -NoLogo -NoProfile -File (Join-Path $script:HybridRepoRoot 'menu.ps1') `
            -Action configure-openclaw -Backend b580-hybrid -DryRun 2>&1
        $LASTEXITCODE | Should -Be 0
        ($Configure -join "`n") | Should -Match 'Qwen 3\.5.*Ollama/Vulkan.*Gemma 4.*Ministral.*llama\.cpp/Vulkan'

        $E2E = & pwsh -NoLogo -NoProfile -File (Join-Path $script:HybridRepoRoot 'menu.ps1') `
            -Action e2e -Backend b580-hybrid -DryRun 2>&1
        $LASTEXITCODE | Should -Be 0
        ($E2E -join "`n") | Should -Match 'mixed-local'
        ($E2E -join "`n") | Should -Match 'probes ciblés 300s'
        ($E2E -join "`n") | Should -Match 'réparation multi-outils 600s'
        ($E2E -join "`n") | Should -Match 'Vulkan est le seul chemin GPU LLM'
    }
}
