param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ExpectedBuildId = "24467282"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceMod = Join-Path $ProjectRoot "mod0\ue4ss\PalMultiOtomo0"
$TargetMod = Join-Path $GameRoot "Pal\Binaries\Win64\ue4ss\Mods\PalMultiOtomo0"
$SteamManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
$EvidencePath = Join-Path $ProjectRoot "evidence\deployments\PalMultiOtomo0-build24467282.json"

foreach ($RequiredPath in @($SteamManifest, $SourceMod, $TargetMod, $EvidencePath)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Deployment check input is missing: $RequiredPath"
    }
}
$ManifestText = Get-Content -LiteralPath $SteamManifest -Raw -Encoding utf8
foreach ($ManifestField in @("buildid", "TargetBuildID")) {
    if ($ManifestText -notmatch ('"' + $ManifestField + '"\s+"' + [regex]::Escape($ExpectedBuildId) + '"')) {
        throw "Steam $ManifestField does not match audited Build $ExpectedBuildId"
    }
}

function Get-RelativeFileMap {
    param([Parameter(Mandatory = $true)][string]$Root)
    $ResolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $Map = @{}
    foreach ($File in Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -File) {
        $Map[$File.FullName.Substring($ResolvedRoot.Length + 1)] = $File
    }
    return $Map
}

$SourceFiles = Get-RelativeFileMap -Root $SourceMod
$TargetFiles = Get-RelativeFileMap -Root $TargetMod
$Missing = @($SourceFiles.Keys | Where-Object { -not $TargetFiles.ContainsKey($_) } | Sort-Object)
$Unexpected = @($TargetFiles.Keys | Where-Object { -not $SourceFiles.ContainsKey($_) } | Sort-Object)
if ($Missing.Count -gt 0) { throw "Installed Mod is missing current source files: $($Missing -join ', ')" }
if ($Unexpected.Count -gt 0) { throw "Installed Mod contains files absent from current source: $($Unexpected -join ', ')" }

$Verified = @()
foreach ($RelativePath in @($SourceFiles.Keys | Sort-Object)) {
    $SourceHash = (Get-FileHash -LiteralPath $SourceFiles[$RelativePath].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $TargetHash = (Get-FileHash -LiteralPath $TargetFiles[$RelativePath].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($SourceHash -ne $TargetHash) { throw "Deployment differs from current source: $RelativePath" }
    $Verified += [ordered]@{ relativePath = $RelativePath; bytes = $TargetFiles[$RelativePath].Length; sha256 = $TargetHash }
}

$Deployment = Get-Content -LiteralPath $EvidencePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$Deployment.steamBuildId -ne $ExpectedBuildId) {
    throw "Deployment evidence belongs to Build $($Deployment.steamBuildId), not $ExpectedBuildId"
}
$EvidenceFiles = @($Deployment.installedFiles)
if ($EvidenceFiles.Count -ne $Verified.Count) { throw "Deployment evidence file count differs from current source" }
$EvidenceByPath = @{}
foreach ($File in $EvidenceFiles) { $EvidenceByPath[[string]$File.relativePath] = $File }
foreach ($File in $Verified) {
    if (-not $EvidenceByPath.ContainsKey($File.relativePath)) { throw "Deployment evidence is missing $($File.relativePath)" }
    $Recorded = $EvidenceByPath[$File.relativePath]
    if ([string]$Recorded.sha256 -ne $File.sha256 -or [long]$Recorded.bytes -ne [long]$File.bytes) {
        throw "Deployment evidence drifted for $($File.relativePath)"
    }
}

Write-Host "PASS PalMultiOtomo0 Build $ExpectedBuildId deployment matches manifest, workspace, and evidence"
Write-Host "Target: $TargetMod"
