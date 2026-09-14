Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'GitHub repository metadata sync helper' {
    BeforeAll {
        $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $script:HelperPath = Join-Path $script:RepoRoot 'scripts\windows\25_sync_github_metadata.ps1'
        $script:Helper = Get-Content -Raw -LiteralPath $script:HelperPath
    }

    It 'fixe la description Architecture V2 local-only' {
        $ExpectedDescription = [regex]::Escape('Plateforme IA multi-agents local-only côté LLM pour Windows 11 : OpenClaw + Ollama, routage local hybride et qualification Intel Arc B580.')
        $script:Helper | Should -Match $ExpectedDescription
        $script:Helper | Should -Not -Match 'escalade cloud contrôlée'
    }

    It 'retire OpenRouter de la cible et ajoute les topics V2' {
        $script:Helper | Should -Not -Match "'openrouter'"
        $script:Helper | Should -Match "'local-llm'"
        $script:Helper | Should -Match "'intel-arc'"
        $script:Helper | Should -Match "'openclaw'"
        $script:Helper | Should -Match "'ollama'"
    }

    It 'reste en lecture seule sans Apply et vérifie après écriture' {
        $script:Helper | Should -Match '\[switch\]\$DryRun'
        $script:Helper | Should -Match '\[switch\]\$Apply'
        $script:Helper | Should -Match "--method', 'PATCH'"
        $script:Helper | Should -Match '--method PUT'
        $script:Helper | Should -Match 'GITHUB_METADATA=DRIFT_DETECTED'
        $script:Helper | Should -Match 'GITHUB_METADATA=COMPLIANT'
    }
}
