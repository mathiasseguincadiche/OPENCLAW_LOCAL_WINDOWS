Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Contrat Parallel Search OpenClaw' {
    It 'verrouille le plugin officiel requis par parallel-free' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Lock = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'config\v1\runtime_versions.json') |
            ConvertFrom-Json
        [string]$Lock.openclaw.plugins.parallel.package | Should -Be '@openclaw/parallel-plugin'
        [string]$Lock.openclaw.plugins.parallel.preferred | Should -Be '2026.9.4'
        [string]$Lock.openclaw.plugins.parallel.provider | Should -Be 'parallel-free'
    }

    It 'converge le plugin avant la validation dry-run du patch OpenClaw' {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $Script = Get-Content -Raw -LiteralPath (
            Join-Path $RepoRoot 'scripts\windows\08_configure_openclaw.ps1'
        )
        $InitializeIndex = $Script.IndexOf('Initialize-ParallelSearchPlugin -OpenClaw')
        $PatchIndex = $Script.IndexOf("'config', 'patch', '--file', `$PatchPath, '--dry-run'")
        $InitializeIndex | Should -BeGreaterThan -1
        $PatchIndex | Should -BeGreaterThan -1
        $InitializeIndex | Should -BeLessThan $PatchIndex
        $Script | Should -Match "'plugins', 'install'"
        $Script | Should -Match "'plugins', 'update'"
        $Script | Should -Match "'plugins', 'enable'"
        $Script | Should -Match "'plugins'\s+'inspect'"
        $Script | Should -Match '--runtime'
        $Script | Should -Match '--pin'
        $Script | Should -Match 'Convergence du plugin Web requis'
    }
}
