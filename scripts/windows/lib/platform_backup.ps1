Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-OpenClawBackupTreeSafe {
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) {
        return $true
    }

    $Items = @((Get-Item -Force -LiteralPath $Root)) + @(
        Get-ChildItem -Force -Recurse -LiteralPath $Root -ErrorAction Stop
    )
    foreach ($Item in $Items) {
        if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Backup pré-upgrade refusé: reparse point détecté: $($Item.FullName)"
        }
    }
    return $true
}

function Get-OpenClawBackupManifestEntries {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Prefix
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return @()
    }

    $Entries = foreach ($File in Get-ChildItem -Force -File -Recurse -LiteralPath $Root -ErrorAction Stop) {
        $Relative = [IO.Path]::GetRelativePath($Root, $File.FullName).Replace('\\', '/')
        [pscustomobject]@{
            path = "$Prefix/$Relative"
            size = [int64]$File.Length
            sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $File.FullName).Hash.ToLowerInvariant()
        }
    }
    return @($Entries | Sort-Object path)
}

function New-OpenClawPreUpgradeBackup {
    [CmdletBinding()]
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
        $null = Test-OpenClawBackupTreeSafe -Root $Source
    }

    $BeforeEntries = foreach ($Name in $PresentNames) {
        Get-OpenClawBackupManifestEntries -Root (Join-Path $PlatformRoot $Name) -Prefix $Name
    }
    $BeforeEntries = @($BeforeEntries | Sort-Object path)

    $Stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmssfff')
    $BackupRoot = Join-Path $PlatformRoot "backup\pre-upgrade-$Stamp"
    if (Test-Path -LiteralPath $BackupRoot) {
        throw "Collision de chemin backup inattendue: $BackupRoot"
    }
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

    try {
        foreach ($Name in $PresentNames) {
            $Source = Join-Path $PlatformRoot $Name
            $Destination = Join-Path $BackupRoot $Name
            Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force -ErrorAction Stop
        }

        $AfterEntries = foreach ($Name in $PresentNames) {
            Get-OpenClawBackupManifestEntries -Root (Join-Path $PlatformRoot $Name) -Prefix $Name
        }
        $AfterEntries = @($AfterEntries | Sort-Object path)

        $BackupEntries = foreach ($Name in $PresentNames) {
            Get-OpenClawBackupManifestEntries -Root (Join-Path $BackupRoot $Name) -Prefix $Name
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
            schema_version = '1.0.0'
            kind = 'openclaw-local-pre-upgrade-backup'
            created_at_utc = (Get-Date).ToUniversalTime().ToString('o')
            source_root = $PlatformRoot
            included_roots = @($PresentNames)
            verified = $true
            file_count = $BeforeEntries.Count
            files = @($BeforeEntries)
        }
        $ManifestPath = Join-Path $BackupRoot 'backup-manifest.json'
        $Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding utf8
        Set-Content -LiteralPath (Join-Path $BackupRoot 'VERIFIED') `
            -Value "verified_at_utc=$((Get-Date).ToUniversalTime().ToString('o'))" -Encoding utf8

        Write-Host "OK  Backup pré-upgrade vérifié: $BackupRoot"
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
