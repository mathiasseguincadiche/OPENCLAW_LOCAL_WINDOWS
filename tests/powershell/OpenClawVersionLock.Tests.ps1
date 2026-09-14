Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $RuntimeLockPath = Join-Path $RepoRoot 'config\v1\runtime_versions.json'
    $script:RuntimeLock = Get-Content -Raw -LiteralPath $RuntimeLockPath | ConvertFrom-Json
    $script:ConfigureScript = Join-Path $RepoRoot 'scripts\windows\08_configure_openclaw.ps1'
    $script:InstallFull = Get-Content -Raw -LiteralPath (
        Join-Path $RepoRoot 'scripts\windows\11_install_full.ps1'
    )
}

Describe 'Contrat OpenClaw 2026.9.4' {
    It 'verrouille exactement OpenClaw 2026.9.4 et son artefact npm' {
        [string]$script:RuntimeLock.openclaw.package | Should -Be 'openclaw'
        [string]$script:RuntimeLock.openclaw.preferred | Should -Be '2026.9.4'
        [string]$script:RuntimeLock.openclaw.release_sha | Should -Be '3a9d69db306cd7f081e06254cb89c4bcc14a7107'
        [string]$script:RuntimeLock.openclaw.integrity | Should -Be (
            'sha512-lTQpEEe1Xm3u2PCHaPEr+vP8paGk1vLdHuzdItsNToaLI6hAqRVvgJYg+GxukJhETJp4tPy/S1Gftl4KuB8n7A=='
        )
    }

    It 'aligne exactement le plugin Parallel sur OpenClaw 2026.9.4' {
        [string]$script:RuntimeLock.openclaw.plugins.parallel.package |
            Should -Be '@openclaw/parallel-plugin'
        [string]$script:RuntimeLock.openclaw.plugins.parallel.preferred | Should -Be '2026.9.4'
        [string]$script:RuntimeLock.openclaw.plugins.parallel.integrity | Should -Be (
            'sha512-/6XIzmiF1iJtXzKYZxO+v92xTzOvTnSQJh89tTQfpZkyk5SxsaQtBAeBwFT7sv3blGIYhGEVhs3+hf4rKVIqtA=='
        )
        [string]$script:RuntimeLock.openclaw.plugins.parallel.provider | Should -Be 'parallel-free'
    }

    It 'verrouille Node 26.1.0 compatible et répare le Gateway sur le runtime Node géré' {
        [string]$script:RuntimeLock.node.preferred | Should -Be '26.1.0'
        [string]$script:RuntimeLock.node.sha256_win_x64_zip | Should -Be (
            '089a02c4c687451c9f0b7f1bfd252dae85a7ba27df0295a14096bdcc956fdc92'
        )
        $Node26 = @($script:RuntimeLock.node.supported | Where-Object { [int]$_.major -eq 26 })
        $Node26.Count | Should -Be 1
        [string]$Node26[0].minimum | Should -Be '26.1.0'
        $script:InstallFull | Should -Match (
            'gateway\s+install\s+--runtime\s+node\s+--force\s+--json'
        )
    }

    It 'affiche 2026.9.4 comme version verrouillée dans configure-openclaw DryRun' {
        $Output = & pwsh -NoLogo -NoProfile -File $script:ConfigureScript -DryRun 2>&1
        $Text = $Output -join "`n"

        $LASTEXITCODE | Should -Be 0 -Because $Text
        $Text | Should -Match ([regex]::Escape('OpenClaw   : 2026.9.4 (version verrouillée)'))
        $Text | Should -Not -Match '2026\.9\.2'
    }
}
