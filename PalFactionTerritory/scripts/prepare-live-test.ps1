[CmdletBinding()]
param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld",
    [Parameter(Mandatory = $true)][string]$SaveRoot,
    [Parameter(Mandatory = $true)][string]$WorldName
)

$ErrorActionPreference = "Stop"
$ExpectedBuildId = "24575825"
$ExpectedExeSha256 = "fe3c15064524bae1947852467c4f92bc22469acc033a3d3c8031eab4324e41e8"
$ExpectedMainPakSha256 = "c0a7d3a756ec57d3ca38d81b252d8645532bfae300c26d18426515c670531bdf"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $ProjectRoot
$SteamAppsRoot = Split-Path -Parent (Split-Path -Parent $GameRoot)
$AppManifest = Join-Path $SteamAppsRoot "appmanifest_1623730.acf"
$Win64Root = Join-Path $GameRoot "Pal\Binaries\Win64"
$ShippingExe = Join-Path $Win64Root "Palworld-Win64-Shipping.exe"
$ProxyDll = Join-Path $Win64Root "dwmapi.dll"
$UE4SSRoot = Join-Path $Win64Root "ue4ss"
$PaksRoot = Join-Path $GameRoot "Pal\Content\Paks"
$MainPak = Join-Path $PaksRoot "Pal-Windows.pak"
$AssetModsRoot = Join-Path $PaksRoot "~mods"
$LogicModsRoot = Join-Path $PaksRoot "LogicMods"
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
$BackupRoot = Join-Path $WorkspaceRoot "outputs\live-test-preflight\build24575825-$Timestamp"
$SnapshotRoot = Join-Path $BackupRoot "snapshot"
$EvidencePath = Join-Path $BackupRoot "preflight-manifest.json"

$BlockingProcesses = @(
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @(
            "Palworld",
            "Palworld-Win64-Shipping",
            "UnrealEditor",
            "UnrealEditor-Cmd",
            "UAssetGUI",
            "FModel"
        )
    }
)
if ($BlockingProcesses.Count -gt 0) {
    throw "A game or asset-editing process is active; preflight snapshot refused"
}

foreach ($RequiredPath in @(
    $AppManifest,
    $ShippingExe,
    $MainPak,
    $ProxyDll,
    $UE4SSRoot,
    $AssetModsRoot,
    $LogicModsRoot,
    $SaveRoot
)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Required preflight input is missing: $RequiredPath"
    }
}

$AppManifestText = Get-Content -LiteralPath $AppManifest -Raw -Encoding utf8
foreach ($ManifestField in @("buildid", "TargetBuildID")) {
    if ($AppManifestText -notmatch ('"' + $ManifestField + '"\s+"' + [regex]::Escape($ExpectedBuildId) + '"')) {
        throw "Steam $ManifestField does not match audited Build $ExpectedBuildId"
    }
}

$ExeSha256 = (Get-FileHash -LiteralPath $ShippingExe -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ExeSha256 -ne $ExpectedExeSha256) {
    throw "Build $ExpectedBuildId executable hash drifted: $ExeSha256"
}
$MainPakSha256 = (Get-FileHash -LiteralPath $MainPak -Algorithm SHA256).Hash.ToLowerInvariant()
if ($MainPakSha256 -ne $ExpectedMainPakSha256) {
    throw "Build $ExpectedBuildId original Pal-Windows.pak hash drifted: $MainPakSha256"
}

$DesignatedWorld = $null
foreach ($WorldDirectory in Get-ChildItem -LiteralPath $SaveRoot -Directory) {
    $LevelMeta = Join-Path $WorldDirectory.FullName "LevelMeta.sav"
    if (-not (Test-Path -LiteralPath $LevelMeta -PathType Leaf)) {
        continue
    }
    $RawText = [System.Text.Encoding]::ASCII.GetString(
        [System.IO.File]::ReadAllBytes($LevelMeta)
    )
    if ([regex]::IsMatch(
        $RawText,
        "WorldName.{0,64}StrProperty.{0,32}$([regex]::Escape($WorldName)).{0,32}HostPlayerName",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        if ($null -ne $DesignatedWorld) {
            throw "More than one top-level world named '$WorldName' was found; snapshot refused"
        }
        $DesignatedWorld = $WorldDirectory.FullName
    }
}
if ($null -eq $DesignatedWorld) {
    throw "The designated top-level world '$WorldName' was not found; snapshot refused"
}

function Get-FileManifest {
    param([Parameter(Mandatory = $true)][string]$Root)

    $ResolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    return @(
        Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -File |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    relativePath = $_.FullName.Substring($ResolvedRoot.Length + 1)
                    bytes = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
    )
}

function Assert-SameManifest {
    param(
        [Parameter(Mandatory = $true)]$SourceManifest,
        [Parameter(Mandatory = $true)]$SnapshotManifest,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (@($SourceManifest).Count -ne @($SnapshotManifest).Count) {
        throw "$Label snapshot file count differs from source"
    }
    $SnapshotByPath = @{}
    foreach ($File in @($SnapshotManifest)) {
        $SnapshotByPath[[string]$File.relativePath] = $File
    }
    foreach ($File in @($SourceManifest)) {
        $RelativePath = [string]$File.relativePath
        if (-not $SnapshotByPath.ContainsKey($RelativePath)) {
            throw "$Label snapshot is missing $RelativePath"
        }
        $SnapshotFile = $SnapshotByPath[$RelativePath]
        if ([long]$File.bytes -ne [long]$SnapshotFile.bytes -or [string]$File.sha256 -ne [string]$SnapshotFile.sha256) {
            throw "$Label snapshot hash differs for $RelativePath"
        }
    }
}

function Copy-VerifiedDirectorySnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $SourceManifest = Get-FileManifest -Root $Source
    New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
    $SnapshotManifest = Get-FileManifest -Root $Destination
    Assert-SameManifest -SourceManifest $SourceManifest -SnapshotManifest $SnapshotManifest -Label $Label
    $TotalBytes = 0
    foreach ($File in @($SourceManifest)) {
        $TotalBytes += [long]$File['bytes']
    }
    return [ordered]@{
        label = $Label
        source = (Resolve-Path -LiteralPath $Source).Path
        snapshot = (Resolve-Path -LiteralPath $Destination).Path
        fileCount = @($SourceManifest).Count
        bytes = $TotalBytes
        files = $SourceManifest
    }
}

New-Item -ItemType Directory -Path $SnapshotRoot -Force | Out-Null

$SaveSnapshot = Copy-VerifiedDirectorySnapshot `
    -Source $SaveRoot `
    -Destination (Join-Path $SnapshotRoot "SaveGames") `
    -Label "Steam user save root"
$UE4SSSnapshot = Copy-VerifiedDirectorySnapshot `
    -Source $UE4SSRoot `
    -Destination (Join-Path $SnapshotRoot "ue4ss") `
    -Label "complete UE4SS installation"
$AssetModsSnapshot = Copy-VerifiedDirectorySnapshot `
    -Source $AssetModsRoot `
    -Destination (Join-Path $SnapshotRoot "paks\~mods") `
    -Label "asset Mod PAK directory"
$LogicModsSnapshot = Copy-VerifiedDirectorySnapshot `
    -Source $LogicModsRoot `
    -Destination (Join-Path $SnapshotRoot "paks\LogicMods") `
    -Label "LogicMod PAK directory"

$ManifestSnapshot = Join-Path $SnapshotRoot "appmanifest_1623730.acf"
$ProxySnapshot = Join-Path $SnapshotRoot "dwmapi.dll"
Copy-Item -LiteralPath $AppManifest -Destination $ManifestSnapshot
Copy-Item -LiteralPath $ProxyDll -Destination $ProxySnapshot
foreach ($Pair in @(
    @($AppManifest, $ManifestSnapshot, "Steam appmanifest"),
    @($ProxyDll, $ProxySnapshot, "UE4SS proxy DLL")
)) {
    $SourceHash = (Get-FileHash -LiteralPath $Pair[0] -Algorithm SHA256).Hash.ToLowerInvariant()
    $SnapshotHash = (Get-FileHash -LiteralPath $Pair[1] -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($SourceHash -ne $SnapshotHash) {
        throw "$($Pair[2]) snapshot hash differs from source"
    }
}

$ResolvedSaveRoot = (Resolve-Path -LiteralPath $SaveRoot).Path.TrimEnd('\')
$ResolvedDesignatedWorld = (Resolve-Path -LiteralPath $DesignatedWorld).Path
if (-not $ResolvedDesignatedWorld.StartsWith(
    $ResolvedSaveRoot + '\',
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "Resolved designated world is outside the configured save root"
}
$DesignatedRelativePath = $ResolvedDesignatedWorld.Substring($ResolvedSaveRoot.Length).TrimStart('\')
$CriticalHashes = [ordered]@{}
foreach ($RelativePath in @("Level.sav", "LevelMeta.sav")) {
    $CriticalPath = Join-Path $DesignatedWorld $RelativePath
    if (-not (Test-Path -LiteralPath $CriticalPath -PathType Leaf)) {
        throw "Designated world '$WorldName' is missing $RelativePath"
    }
    $CriticalHashes[$RelativePath] =
        (Get-FileHash -LiteralPath $CriticalPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

[ordered]@{
    schemaVersion = "2.0.0"
    preparedAt = (Get-Date).ToString("o")
    result = "PASS"
    gameBuild = $ExpectedBuildId
    sourceContractBuild = "24181527"
    gameOrEditorProcessRunning = $false
    gameStarted = $false
    liveTestPerformed = $false
    installationMutated = $false
    designatedSave = [ordered]@{
        name = $WorldName
        relativeWorldPath = $DesignatedRelativePath
        sourceRoot = $SaveRoot
        criticalHashes = $CriticalHashes
        completeSaveSnapshot = $SaveSnapshot
    }
    protectedOriginals = [ordered]@{
        shippingExe = [ordered]@{
            path = $ShippingExe
            bytes = (Get-Item -LiteralPath $ShippingExe).Length
            sha256 = $ExeSha256
        }
        mainPak = [ordered]@{
            path = $MainPak
            bytes = (Get-Item -LiteralPath $MainPak).Length
            sha256 = $MainPakSha256
            copiedOrModified = $false
        }
    }
    restoreSnapshot = [ordered]@{
        root = $SnapshotRoot
        appManifest = $ManifestSnapshot
        proxyDll = $ProxySnapshot
        ue4ss = $UE4SSSnapshot
        assetModPaks = $AssetModsSnapshot
        logicModPaks = $LogicModsSnapshot
    }
    qaHarnessesChanged = $false
    saveFilesModified = $false
    originalGamePakChanged = $false
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $EvidencePath -Encoding utf8

Write-Host "PASS full recoverable live-test snapshot for Steam Build $ExpectedBuildId"
Write-Host "Designated world '$WorldName' save snapshot: $($SaveSnapshot.snapshot)"
Write-Host "UE4SS and Mod PAK snapshot: $SnapshotRoot"
Write-Host "Evidence: $EvidencePath"
Write-Host "No game was started and no installed file or save was changed."
