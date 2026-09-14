Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:BackupLibrary = Join-Path $RepoRoot 'scripts\windows\lib\platform_backup.ps1'
    $script:Menu = Join-Path $RepoRoot 'menu.ps1'
    . $script:BackupLibrary
}

Describe 'Transcript actif et backup pré-upgrade' {
    It 'ignore uniquement le transcript actif verrouillé et conserve les logs historiques' {
        $Previous = $env:OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE
        $Root = Join-Path $TestDrive 'platform'
        $LogsRoot = Join-Path $Root 'proofs\logs'
        New-Item -ItemType Directory -Path $LogsRoot -Force | Out-Null

        $HistoricalName = '20260914_080000000_audit.log'
        $HistoricalPath = Join-Path $LogsRoot $HistoricalName
        Set-Content -LiteralPath $HistoricalPath -Value 'historical-proof' -Encoding utf8

        $ActiveName = '20260914_093917480_install-full.log'
        $ActivePath = Join-Path $LogsRoot $ActiveName
        Set-Content -LiteralPath $ActivePath -Value 'active-proof' -Encoding utf8
        $Stream = [IO.File]::Open(
            $ActivePath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )

        try {
            $env:OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE = "proofs/logs/$ActiveName"
            $Result = New-OpenClawPreUpgradeBackup -PlatformRoot $Root

            [bool]$Result.verified | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Result.path "proofs\logs\$HistoricalName") |
                Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Result.path "proofs\logs\$ActiveName") |
                Should -BeFalse

            $Manifest = Get-Content -Raw -LiteralPath $Result.manifest | ConvertFrom-Json
            @($Manifest.excluded_paths) | Should -Contain "proofs/logs/$ActiveName"
            @($Manifest.files.path) | Should -Contain "proofs/logs/$HistoricalName"
            @($Manifest.files.path) | Should -Not -Contain "proofs/logs/$ActiveName"
        }
        finally {
            $Stream.Dispose()
            if ($null -eq $Previous) {
                Remove-Item Env:OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE -ErrorAction SilentlyContinue
            }
            else {
                $env:OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE = $Previous
            }
        }
    }

    It 'refuse d utiliser une exclusion de transcript hors proofs logs' {
        $Previous = $env:OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE
        try {
            $env:OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE = '../state/openclaw.json'
            @(Get-OpenClawBackupExcludedPath) | Should -Not -Contain '../state/openclaw.json'
            Test-OpenClawBackupPathExcluded -LogicalPath 'state/openclaw.json' | Should -BeFalse
        }
        finally {
            if ($null -eq $Previous) {
                Remove-Item Env:OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE -ErrorAction SilentlyContinue
            }
            else {
                $env:OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE = $Previous
            }
        }
    }

    It 'publie et nettoie le chemin relatif du transcript dans le menu' {
        $MenuText = Get-Content -Raw -LiteralPath $script:Menu
        $MenuText | Should -Match 'OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE'
        $MenuText | Should -Match 'proofs/logs/'
        $MenuText | Should -Match 'Remove-Item Env:OPENCLAW_LOCAL_ACTIVE_TRANSCRIPT_RELATIVE'
    }
}
