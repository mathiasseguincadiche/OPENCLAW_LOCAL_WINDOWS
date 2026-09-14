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
        [string]$Manifest.schema_version | Should -Be '1.2.0'
        @($Manifest.included_roots).Count | Should -Be 3
        foreach ($Excluded in @(
            'state/dev',
            'state/git',
            'state/npm',
            'state/npm-runtime',
            'state/tmp',
            'state/tools',
            'state/plugin-skills'
        )) {
            @($Manifest.excluded_paths) | Should -Contain $Excluded
        }
        foreach ($Name in @('projects', 'state', 'proofs')) {
            @($Manifest.included_roots) | Should -Contain $Name
            $Original = Join-Path $Root "$Name\$Name.txt"
            $Copy = Join-Path $Result.path "$Name\$Name.txt"
            Test-Path -LiteralPath $Copy | Should -BeTrue
            (Get-FileHash -Algorithm SHA256 -LiteralPath $Copy).Hash |
                Should -Be (Get-FileHash -Algorithm SHA256 -LiteralPath $Original).Hash
        }
    }

    It 'exclut les racines state gérées et reconstructibles d OpenClaw 2026.9.4' {
        $Root = Join-Path $TestDrive 'platform-with-managed-state'
        $State = Join-Path $Root 'state'
        New-Item -ItemType Directory -Path $State -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $State 'openclaw.json') -Value '{"ok":true}' -Encoding utf8

        foreach ($Relative in @('dev', 'git', 'npm', 'npm-runtime', 'tmp', 'tools', 'plugin-skills')) {
            $Dir = Join-Path $State $Relative
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Dir 'reconstructible.txt') -Value $Relative -Encoding utf8
        }

        $Result = New-OpenClawPreUpgradeBackup -PlatformRoot $Root

        [bool]$Result.verified | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Result.path 'state\openclaw.json') | Should -BeTrue
        foreach ($Relative in @('dev', 'git', 'npm', 'npm-runtime', 'tmp', 'tools', 'plugin-skills')) {
            Test-Path -LiteralPath (Join-Path $Result.path "state\$Relative") | Should -BeFalse
        }
        $Manifest = Get-Content -Raw -LiteralPath $Result.manifest | ConvertFrom-Json
        @($Manifest.files.path | Where-Object {
            $_ -like 'state/dev/*' -or
            $_ -like 'state/git/*' -or
            $_ -like 'state/npm/*' -or
            $_ -like 'state/npm-runtime/*' -or
            $_ -like 'state/tmp/*' -or
            $_ -like 'state/tools/*' -or
            $_ -like 'state/plugin-skills/*'
        }).Count | Should -Be 0
    }

    It 'exclut state/npm reconstructible même s il contient une junction npm' -Skip:(-not $IsWindows) {
        $Root = Join-Path $TestDrive 'platform-with-npm-junction'
        $State = Join-Path $Root 'state'
        $NpmTree = Join-Path $State 'npm\projects\parallel\node_modules\@openclaw\parallel-plugin\node_modules'
        New-Item -ItemType Directory -Path $NpmTree -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $State 'openclaw.json') -Value '{"ok":true}' -Encoding utf8

        $Target = Join-Path $TestDrive 'junction-target'
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Target 'package.json') -Value '{"name":"openclaw"}' -Encoding utf8
        $Junction = Join-Path $NpmTree 'openclaw'
        New-Item -ItemType Junction -Path $Junction -Target $Target | Out-Null

        $Result = New-OpenClawPreUpgradeBackup -PlatformRoot $Root

        [bool]$Result.verified | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Result.path 'state\openclaw.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Result.path 'state\npm') | Should -BeFalse
        $Manifest = Get-Content -Raw -LiteralPath $Result.manifest | ConvertFrom-Json
        @($Manifest.excluded_paths) | Should -Contain 'state/npm'
        @($Manifest.files.path | Where-Object { $_ -like 'state/npm/*' }).Count | Should -Be 0
    }

    It 'exclut l index plugin-skills généré même s il contient une junction Windows' -Skip:(-not $IsWindows) {
        $Root = Join-Path $TestDrive 'platform-with-plugin-skill-junction'
        $State = Join-Path $Root 'state'
        $PluginSkills = Join-Path $State 'plugin-skills'
        New-Item -ItemType Directory -Path $PluginSkills -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $State 'openclaw.json') -Value '{"ok":true}' -Encoding utf8

        $Target = Join-Path $TestDrive 'browser-automation-skill'
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Target 'SKILL.md') -Value '# browser-automation' -Encoding utf8
        New-Item -ItemType Junction -Path (Join-Path $PluginSkills 'browser-automation') -Target $Target | Out-Null

        $Result = New-OpenClawPreUpgradeBackup -PlatformRoot $Root

        [bool]$Result.verified | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Result.path 'state\openclaw.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Result.path 'state\plugin-skills') | Should -BeFalse
        $Manifest = Get-Content -Raw -LiteralPath $Result.manifest | ConvertFrom-Json
        @($Manifest.excluded_paths) | Should -Contain 'state/plugin-skills'
        @($Manifest.files.path | Where-Object { $_ -like 'state/plugin-skills/*' }).Count | Should -Be 0
    }

    It 'refuse toujours un reparse point hors des chemins reconstructibles' -Skip:(-not $IsWindows) {
        $Root = Join-Path $TestDrive 'platform-with-unexpected-junction'
        $State = Join-Path $Root 'state'
        New-Item -ItemType Directory -Path $State -Force | Out-Null

        $Target = Join-Path $TestDrive 'unexpected-target'
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Target 'payload.txt') -Value 'outside' -Encoding utf8
        New-Item -ItemType Junction -Path (Join-Path $State 'unexpected-link') -Target $Target | Out-Null

        { New-OpenClawPreUpgradeBackup -PlatformRoot $Root } |
            Should -Throw '*reparse point détecté*'
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
        foreach ($Expected in @(
            'state/dev',
            'state/git',
            'state/npm',
            'state/npm-runtime',
            'state/tmp',
            'state/tools',
            'state/plugin-skills'
        )) {
            $script:BackupLibraryText | Should -Match [regex]::Escape($Expected)
        }
        $Script | Should -Match 'Invoke-OpenClawConfigWriteWindow'
        $Script | Should -Match 'Assert-OpenClawReadOnlySteadyState'
    }
}
