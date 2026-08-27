[CmdletBinding()]
param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ExpectedBuildId = "24575825"
$SourceMod = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0"
$TargetMod = Join-Path $GameRoot `
    "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0"
$SteamManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
$EvidenceRoot = Join-Path $ProjectRoot "evidence\deployments"
$EvidencePath = Join-Path $EvidenceRoot "mod0-dev-build24575825.json"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = Join-Path $EvidenceRoot `
    ("mod0-runtime-script-backups\" + $Stamp)

$Blocking = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @(
        "Palworld",
        "Palworld-Win64-Shipping",
        "UnrealEditor",
        "UnrealEditor-Cmd",
        "UAssetGUI",
        "FModel"
    )
})
if ($Blocking.Count -gt 0) {
    throw "A game or asset-editing process is active; Mod update refused"
}
foreach ($Path in @($SourceMod, $TargetMod, $SteamManifest)) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Mod update input is missing: $Path"
    }
}
$ManifestText = Get-Content -LiteralPath $SteamManifest -Raw -Encoding utf8
foreach ($Field in @("buildid", "TargetBuildID")) {
    if ($ManifestText -notmatch (
        '"' + $Field + '"\s+"' + [regex]::Escape($ExpectedBuildId) + '"'
    )) {
        throw "Steam $Field does not match audited Build $ExpectedBuildId"
    }
}

$ResolvedSource = (Resolve-Path -LiteralPath $SourceMod).Path.TrimEnd('\')
$ResolvedTarget = (Resolve-Path -LiteralPath $TargetMod).Path.TrimEnd('\')
$SourceFiles = @(
    Get-ChildItem -LiteralPath $ResolvedSource -Recurse -File -Force |
        Sort-Object FullName
)
$SourceRelative = @{}
foreach ($File in $SourceFiles) {
    $Relative = $File.FullName.Substring($ResolvedSource.Length + 1)
    $SourceRelative[$Relative] = $true
}
$Unexpected = @(
    Get-ChildItem -LiteralPath $ResolvedTarget -Recurse -File -Force |
        ForEach-Object {
            $Relative = $_.FullName.Substring($ResolvedTarget.Length + 1)
            if (-not $SourceRelative.ContainsKey($Relative) -and
                -not $Relative.StartsWith(
                    "State\",
                    [System.StringComparison]::OrdinalIgnoreCase
                )) {
                $Relative
            }
        }
)
if ($Unexpected.Count -gt 0) {
    throw "Installed Mod has unmanaged files; update refused: $($Unexpected -join ', ')"
}
if (Test-Path -LiteralPath $BackupRoot) {
    throw "Backup target already exists: $BackupRoot"
}

New-Item -ItemType Directory -Path `
    (Split-Path -Parent $BackupRoot) -Force | Out-Null
Copy-Item -LiteralPath $ResolvedTarget -Destination $BackupRoot -Recurse

foreach ($SourceFile in $SourceFiles) {
    $Relative = $SourceFile.FullName.Substring($ResolvedSource.Length + 1)
    $Destination = [System.IO.Path]::GetFullPath(
        (Join-Path $ResolvedTarget $Relative)
    )
    if (-not $Destination.StartsWith(
        $ResolvedTarget + "\",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Resolved deployment target escaped Mod root: $Destination"
    }
    $Parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $Parent)) {
        New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    }
    Copy-Item -LiteralPath $SourceFile.FullName `
        -Destination $Destination -Force
}

$InstalledFiles = @(
    foreach ($SourceFile in $SourceFiles) {
        $Relative = $SourceFile.FullName.Substring($ResolvedSource.Length + 1)
        $Installed = Get-Item -LiteralPath (Join-Path $ResolvedTarget $Relative)
        [ordered]@{
            relativePath = $Relative
            path = $Installed.FullName
            bytes = $Installed.Length
            sha256 = (Get-FileHash -LiteralPath $Installed.FullName `
                -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
)
$Deployment = [ordered]@{
    schemaVersion = "1.1.0"
    releaseId = "PalFactionTerritory0-mod0"
    steamBuildId = $ExpectedBuildId
    mode = "development-update"
    installedAt = (Get-Date).ToString("o")
    gameRoot = $GameRoot
    targetMod = $ResolvedTarget
    backupRoot = $BackupRoot
    installedFiles = $InstalledFiles
}
$Json = $Deployment | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText(
    $EvidencePath,
    $Json,
    [System.Text.UTF8Encoding]::new($false)
)

& (Join-Path $PSScriptRoot "check-mod0-deployment.ps1") `
    -GameRoot $GameRoot
$DeploymentCheckSucceeded = $?
if (-not $DeploymentCheckSucceeded) {
    throw "Deployment parity check failed; backup retained at $BackupRoot"
}
Write-Host "PASS updated Build $ExpectedBuildId Mod runtime"
Write-Host "Backup: $BackupRoot"
Write-Host "State preserved in place and copied into the backup"
