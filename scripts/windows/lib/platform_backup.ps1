Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# OpenClaw 2026.9.4 classe ces sous-arbres du state comme ressources gérées et
# reconstructibles dans sa propre politique de backup. plugin-skills est un
# index de junctions/symlinks entièrement généré depuis les métadonnées des
# plugins actifs. Ils ne constituent donc pas un état durable à restaurer.
$script:OpenClawBackupExcludedRelativePaths = @(
    'state/dev',
    'state/git',
    'state/npm',
    'state/npm-runtime',
    'state/tmp',
    'state/tools',
    'state/plugin-skills'
)

function Test-OpenClawBackupPathExcluded {
    param([Parameter(Mandatory)][string]$LogicalPath)

    $Normalized = ($LogicalPath -replace '\\', '/').Trim('/')
    foreach ($Excluded in $script:OpenClawBackupExcludedRelativePaths) {
        $Needle = ([string]$Excluded).Trim('/')
        if (
            $Normalized.Equals($Needle, [StringComparison]::OrdinalIgnoreCase) -or
            $Normalized.StartsWith("$Needle/", [StringComparison]::OrdinalIgnoreCase)
        ) {
            return $true
        }
    }
    return $false
}

function Get-OpenClawBackupFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Prefix
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    $RootItem = Get-Item -Force -LiteralPath $Root
    if (($RootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Backup pré-upgrade refusé: reparse point détecté: $($RootItem.FullName)"
    }

    $Files = [System.Collections.Generic.List[object]]::new()
    $Pending = [System.Collections.Generic.Stack[string]]::new()
    $Pending.Push($RootItem.FullName)

    while ($Pending.Count -gt 0) {
        $Current = $Pending.Pop()
        foreach ($Item in Get-ChildItem -Force -LiteralPath $Current -ErrorAction Stop) {
            $Relative = [IO.Path]::GetRelativePath($Root, $Item.FullName).Replace('\\', '/')
            $LogicalPath = "$Prefix/$Relative"

            if (Test-OpenClawBackupPathExcluded -LogicalPath $LogicalPath) {
                continue
            }
            if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Backup pré-upgrade refusé: reparse point détecté: $($Item.FullName)"
            }
            if ($Item.PSIsContainer) {
                $Pending.Push($Item.FullName)
            }
            else {
                $Files.Add($Item)
            }
        }
    }

    return @($Files)
}

function Test-OpenClawBackupTreeSafe {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Prefix
    )

    $null = @(Get-OpenClawBackupFile -Root $Root -Prefix $Prefix)
    return $true
}

function Get-OpenClawBackupManifestEntry {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Prefix
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    $Entries = foreach ($File in Get-OpenClawBackupFile -Root $Root -Prefix $Prefix) {
        $Relative = [IO.Path]::GetRelativePath($Root, $File.FullName).Replace('\\', '/')
        [pscustomobject]@{
            path = "$Prefix/$Relative"
            size = [int64]$File.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $File.FullName).Hash.ToLowerInvariant()
        }
    }
    return @($Entries | Sort-Object path)
}

function Copy-OpenClawBackupRoot {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Prefix
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($File in Get-OpenClawBackupFile -Root $Source -Prefix $Prefix) {
        $Relative = [IO.Path]::GetRelativePath($Source, $File.FullName)
        $Target = Join-Path $Destination $Relative
        $Parent = Split-Path -Parent $Target
        if (-not (Test-Path -LiteralPath $Parent)) {
            New-Item -ItemType Directory -Path $Parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $File.FullName -Destination $Target -Force -ErrorAction Stop
    }
}

function New-OpenClawPreUpgradeBackup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([Parameter(Mandatory)][string]$PlatformRoot)

    $SourceNames = @('projects', 'state', 'proofs')
    $PresentNames = @(
        $SourceNames | Where-Object {
            Test-Path -LiteralPath (Join-Path $PlatformRoot $_)
        }
    )
    if ($PresentNames.Count -eq 0) {
        Write-Host 'INFO Première installation détectée: aucun état géré à sauvegarder avant upgrade.'
        return $null
    }

    foreach ($Name in $PresentNames) {
        $Source = Join-Path $PlatformRoot $Name
        $null = Test-OpenClawBackupTreeSafe -Root $Source -Prefix $Name
    }

    $BeforeEntries = foreach ($Name in $PresentNames) {
        Get-OpenClawBackupManifestEntry -Root (Join-Path $PlatformRoot $Name) -Prefix $Name
    }
    $BeforeEntries = @($BeforeEntries | Sort-Object path)

    $Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $BackupRoot = Join-Path $PlatformRoot "backup\pre-upgrade-$Stamp"
    if (Test-Path -LiteralPath $BackupRoot) {
        throw "Collision de chemin backup inattendue: $BackupRoot"
    }
    if (-not $PSCmdlet.ShouldProcess($BackupRoot, 'Créer un backup pré-upgrade vérifié')) {
        throw 'Backup pré-upgrade requis: l opération ne peut pas être ignorée.'
    }
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

    try {
        foreach ($Name in $PresentNames) {
            $Source = Join-Path $PlatformRoot $Name
            $Destination = Join-Path $BackupRoot $Name
            Copy-OpenClawBackupRoot -Source $Source -Destination $Destination -Prefix $Name
        }

        $AfterEntries = foreach ($Name in $PresentNames) {
            Get-OpenClawBackupManifestEntry -Root (Join-Path $PlatformRoot $Name) -Prefix $Name
        }
        $AfterEntries = @($AfterEntries | Sort-Object path)

        $BackupEntries = foreach ($Name in $PresentNames) {
            Get-OpenClawBackupManifestEntry -Root (Join-Path $BackupRoot $Name) -Prefix $Name
        }
        $BackupEntries = @($BackupEntries | Sort-Object path)

        $BeforeFingerprint = @($BeforeEntries | ForEach-Object { "$($_.path)|$($_.size)|$($_.sha256)" })
        $AfterFingerprint = @($AfterEntries | ForEach-Object { "$($_.path)|$($_.size)|$($_.sha256)" })
        $BackupFingerprint = @($BackupEntries | ForEach-Object { "$($_.path)|$($_.size)|$($_.sha256)" })

        if (@(Compare-Object -ReferenceObject $BeforeFingerprint -DifferenceObject $AfterFingerprint).Count -ne 0) {
            throw (
                'État OPENCLAW_LOCAL modifié pendant le snapshot. ' +
                'Arrêtez les processus qui écrivent dans projects/state/proofs puis relancez install-full.'
            )
        }
        if (@(Compare-Object -ReferenceObject $BeforeFingerprint -DifferenceObject $BackupFingerprint).Count -ne 0) {
            throw 'Backup pré-upgrade rejeté: la vérification SHA256 de la copie a échoué.'
        }

        $Manifest = [ordered]@{
            schema_version = '1.2.0'
            kind = 'openclaw-local-pre-upgrade-backup'
            created_at_utc = (Get-Date).ToUniversalTime().ToString('o')
            source_root = $PlatformRoot
            included_roots = @($PresentNames)
            excluded_paths = @($script:OpenClawBackupExcludedRelativePaths)
            verified = $true
            file_count = $BeforeEntries.Count
            files = @($BeforeEntries)
        }
        $ManifestPath = Join-Path $BackupRoot 'backup-manifest.json'
        $Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
        Set-Content -LiteralPath (Join-Path $BackupRoot 'VERIFIED') `
            -Value "verified_at_utc=$((Get-Date).ToUniversalTime().ToString('o'))" -Encoding utf8

        Write-Host "OK  Backup pré-upgrade vérifié: $BackupRoot"
        Write-Host "INFO Backup exclut les artefacts reconstructibles: $($script:OpenClawBackupExcludedRelativePaths -join ', ')"
        Write-Host "OPENCLAW_PREUPGRADE_BACKUP=$BackupRoot"
        return [pscustomobject]@{
            path = $BackupRoot
            manifest = $ManifestPath
            file_count = $BeforeEntries.Count
            verified = $true
        }
    }
    catch {
        if (Test-Path -LiteralPath $BackupRoot) {
            Remove-Item -LiteralPath $BackupRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}
