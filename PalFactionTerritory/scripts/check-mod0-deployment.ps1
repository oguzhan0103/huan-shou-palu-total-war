param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ExpectedBuildId = "24575825"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceMod = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0"
$TargetMod = Join-Path $GameRoot "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0"
$SteamManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
$EvidencePath = Join-Path $ProjectRoot "evidence\deployments\mod0-dev-build24575825.json"

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
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeRelativePrefixes = @()
    )

    $ResolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $Map = @{}
    foreach ($File in Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -File) {
        $RelativePath = $File.FullName.Substring($ResolvedRoot.Length + 1)
        $IsExcluded = $false
        foreach ($Prefix in $ExcludeRelativePrefixes) {
            if ($RelativePath.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $IsExcluded = $true
                break
            }
        }
        if ($IsExcluded) {
            continue
        }
        $Map[$RelativePath] = $File
    }
    return $Map
}

$SourceFiles = Get-RelativeFileMap -Root $SourceMod
# State\ is runtime-owned: it contains the external progression/companion ledgers
# produced by the installed Mod. It is intentionally preserved across deployments
# and is not part of the source-tree parity contract. Source-managed files under
# State\ (currently README.txt) are still verified normally.
$TargetFiles = Get-RelativeFileMap -Root $TargetMod
$MissingFiles = @($SourceFiles.Keys | Where-Object { -not $TargetFiles.ContainsKey($_) } | Sort-Object)
$UnexpectedFiles = @($TargetFiles.Keys | Where-Object {
    -not $SourceFiles.ContainsKey($_) -and
    -not $_.StartsWith("State\", [System.StringComparison]::OrdinalIgnoreCase)
} | Sort-Object)
if ($MissingFiles.Count -gt 0) {
    throw "Installed Mod is missing current source files: $($MissingFiles -join ', ')"
}
if ($UnexpectedFiles.Count -gt 0) {
    throw "Installed Mod contains files absent from current source: $($UnexpectedFiles -join ', ')"
}

$VerifiedFiles = @()
foreach ($RelativePath in @($SourceFiles.Keys | Sort-Object)) {
    $SourceHash = (Get-FileHash -LiteralPath $SourceFiles[$RelativePath].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $TargetHash = (Get-FileHash -LiteralPath $TargetFiles[$RelativePath].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($SourceHash -ne $TargetHash) {
        throw "Deployment differs from current source: $RelativePath"
    }
    $VerifiedFiles += [ordered]@{
        relativePath = $RelativePath
        path = $TargetFiles[$RelativePath].FullName
        bytes = $TargetFiles[$RelativePath].Length
        sha256 = $TargetHash
    }
}

$Deployment = Get-Content -LiteralPath $EvidencePath -Raw -Encoding utf8 | ConvertFrom-Json
if ([string]$Deployment.steamBuildId -ne $ExpectedBuildId) {
    throw "Deployment evidence belongs to Build $($Deployment.steamBuildId), not $ExpectedBuildId"
}
if (@($Deployment.installedFiles).Count -ne $VerifiedFiles.Count) {
    throw "Deployment evidence file count does not match the installed source tree"
}
$EvidenceByRelativePath = @{}
foreach ($File in @($Deployment.installedFiles)) {
    $EvidenceByRelativePath[[string]$File.relativePath] = $File
}
foreach ($File in $VerifiedFiles) {
    if (-not $EvidenceByRelativePath.ContainsKey($File.relativePath)) {
        throw "Deployment evidence is missing: $($File.relativePath)"
    }
    $Recorded = $EvidenceByRelativePath[$File.relativePath]
    if ([string]$Recorded.sha256 -ne $File.sha256 -or [long]$Recorded.bytes -ne [long]$File.bytes) {
        throw "Deployment evidence drifted from installed file: $($File.relativePath)"
    }
}

Write-Host "PASS Build $ExpectedBuildId deployment matches manifest, current source, and $($VerifiedFiles.Count) recorded hashes"
Write-Host "Target: $TargetMod"
