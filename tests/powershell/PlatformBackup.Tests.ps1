Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:BackupLibrary = Join-Path $RepoRoot 'scripts\windows\lib\platform_backup.ps1'
    $script:InstallFull = Join-Path $RepoRoot 'scripts\windows\11_install_full.ps1'
    $script:BackupLibraryText = Get-Content -Raw -LiteralPath $script:BackupLibrary
    . $script:BackupLibrary
}

Describe 'Backup pré-upgrade OPENCLAW_LOCAL' {
    It 'copie projects state proofs et vérifie chaque fichier par SHA256' {
        $Root = Join-Path $TestDrive 'platform'
        foreach ($Name in @('projects', 'state', 'proofs')) {
            $Dir = Join-Path $Root $Name
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Dir "$Name.txt") -Value "payload-$Name" -Encoding utf8
        }

        $Result = New-OpenClawPreUpgradeBackup -PlatformRoot $Root

        $Result | Should -Not -BeNullOrEmpty
        [bool]$Result.verified | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Result.path 'VERIFIED') | Should -BeTrue
        Test-Path -LiteralPath $Result.manifest | Should -BeTrue
        $Manifest = Get-Content -Raw -LiteralPath $Result.manifest | ConvertFrom-Json
        [bool]$Manifest.verified | Should -BeTrue
        [int]$Manifest.file_count | Should -Be 3
        @($Manifest.included_roots).Count | Should -Be 3
        foreach ($Name in @('projects', 'state', 'proofs')) {
            @($Manifest.included_roots) | Should -Contain $Name
            $Original = Join-Path $Root "$Name\$Name.txt"
            $Copy = Join-Path $Result.path "$Name\$Name.txt"
            Test-Path -LiteralPath $Copy | Should -BeTrue
            (Get-FileHash -Algorithm SHA256 -LiteralPath $Copy).Hash |
                Should -Be (Get-FileHash -Algorithm SHA256 -LiteralPath $Original).Hash
        }
    }

    It 'autorise une première installation sans état existant' {
        $Root = Join-Path $TestDrive 'fresh-platform'
        New-Item -ItemType Directory -Path $Root -Force | Out-Null

        $Result = New-OpenClawPreUpgradeBackup -PlatformRoot $Root

        $Result | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $Root 'backup') | Should -BeFalse
    }

    It 'est exécuté avant le bootstrap dans install-full' {
        $Script = Get-Content -Raw -LiteralPath $script:InstallFull
        $BackupIndex = $Script.IndexOf('New-OpenClawPreUpgradeBackup -PlatformRoot $PlatformRoot')
        $BootstrapIndex = $Script.IndexOf('Invoke-ScriptChecked -Path $Bootstrap -Parameters @{', $BackupIndex)
        $BackupIndex | Should -BeGreaterThan -1
        $BootstrapIndex | Should -BeGreaterThan -1
        $BackupIndex | Should -BeLessThan $BootstrapIndex
        $script:BackupLibraryText | Should -Match 'OPENCLAW_PREUPGRADE_BACKUP='
        $Script | Should -Match 'Invoke-OpenClawConfigWriteWindow'
        $Script | Should -Match 'Assert-OpenClawReadOnlySteadyState'
    }
}
