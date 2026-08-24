[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunRoot,
    [Parameter(Mandatory = $true)]
    [string]$GameRoot,
    [Parameter(Mandatory = $true)]
    [string]$SaveTarget
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$AllowedRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $ProjectRoot "outputs\a9-reward-live-test")
).TrimEnd('\')
$ResolvedRunRoot = (Resolve-Path -LiteralPath $RunRoot).Path.TrimEnd('\')
if (-not $ResolvedRunRoot.StartsWith(
    $AllowedRoot + '\',
    [System.StringComparison]::OrdinalIgnoreCase
)) {
    throw "A9 restore RunRoot is outside the allowed output directory: $ResolvedRunRoot"
}
$ManifestPath = Join-Path $ResolvedRunRoot "staging-manifest.json"
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "A9 staging manifest is missing: $ManifestPath"
}
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding utf8 |
    ConvertFrom-Json

$ExpectedSaveTarget = [System.IO.Path]::GetFullPath($SaveTarget).TrimEnd('\')
$ExpectedSaveRoot = [System.IO.Path]::GetFullPath(
    (Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) `
        "Pal\Saved\SaveGames")
).TrimEnd('\')
$SaveParent = [System.IO.Path]::GetDirectoryName($ExpectedSaveTarget).TrimEnd('\')
$SaveLeaf = [System.IO.Path]::GetFileName($ExpectedSaveTarget)
if ($SaveParent -ne $ExpectedSaveRoot -or $SaveLeaf -notmatch '^\d{17}$') {
    throw "A9 restore SaveTarget is outside the current user's Steam SaveGames root"
}
$ExpectedTargetMod = [System.IO.Path]::GetFullPath(
    (Join-Path $GameRoot `
        "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0")
).TrimEnd('\')
$ExpectedStateTarget = [System.IO.Path]::GetFullPath(
    (Join-Path $ExpectedTargetMod "State")
).TrimEnd('\')
$ExpectedConfigTarget = [System.IO.Path]::GetFullPath(
    (Join-Path $ExpectedTargetMod "Scripts\pwft\config.lua")
)
if (-not (Test-Path -LiteralPath `
    (Join-Path $GameRoot "Pal\Binaries\Win64\Palworld-Win64-Shipping.exe") `
    -PathType Leaf)) {
    throw "A9 restore GameRoot does not contain the Palworld executable"
}
$SaveTarget = [System.IO.Path]::GetFullPath([string]$Manifest.saveTarget).TrimEnd('\')
$StateTarget = [System.IO.Path]::GetFullPath([string]$Manifest.stateTarget).TrimEnd('\')
$TargetConfig = [System.IO.Path]::GetFullPath([string]$Manifest.targetConfig)
if ($SaveTarget -ne $ExpectedSaveTarget -or
    $StateTarget -ne $ExpectedStateTarget -or
    $TargetConfig -ne $ExpectedConfigTarget) {
    throw "A9 restore manifest names an unexpected destructive target"
}

$Blocking = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @("Palworld", "Palworld-Win64-Shipping")
})
if ($Blocking.Count -gt 0) {
    throw "Palworld is active; A9 baseline restore refused"
}

$SaveSnapshot = Join-Path $ResolvedRunRoot "snapshot\SaveGames"
$StateSnapshot = Join-Path $ResolvedRunRoot "snapshot\ModState"
$PreStageConfig = Join-Path $ResolvedRunRoot "installed-config-before.lua"
foreach ($Path in @(
    $SaveSnapshot,
    $StateSnapshot,
    $PreStageConfig,
    $SaveTarget,
    $StateTarget,
    $TargetConfig
)) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "A9 restore input is missing: $Path"
    }
}

function Get-TreeManifest([string]$Root) {
    $ResolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    return @(
        Get-ChildItem -LiteralPath $ResolvedRoot -Recurse -File -Force |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    path = $_.FullName.Substring(
                        $ResolvedRoot.Length + 1
                    ).Replace('\', '/')
                    length = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
    )
}

function Assert-ManifestEqual(
    [object[]]$Expected,
    [object[]]$Actual,
    [string]$Label
) {
    if ($Expected.Count -ne $Actual.Count) {
        throw "$Label file-count mismatch: expected=$($Expected.Count) actual=$($Actual.Count)"
    }
    for ($Index = 0; $Index -lt $Expected.Count; $Index++) {
        $Left = $Expected[$Index]
        $Right = $Actual[$Index]
        if ($Left.path -ne $Right.path -or
            [int64]$Left.length -ne [int64]$Right.length -or
            $Left.sha256 -ne $Right.sha256) {
            throw "$Label mismatch at index ${Index}: expected=$($Left.path) actual=$($Right.path)"
        }
    }
}

$ExpectedSaveManifest = @($Manifest.saveFiles)
$ExpectedStateManifest = @($Manifest.stateFiles)
Assert-ManifestEqual $ExpectedSaveManifest `
    (Get-TreeManifest $SaveSnapshot) "A9 SaveGames snapshot pre-restore"
Assert-ManifestEqual $ExpectedStateManifest `
    (Get-TreeManifest $StateSnapshot) "A9 Mod-State snapshot pre-restore"
$PreStageHash = (Get-FileHash -LiteralPath $PreStageConfig `
    -Algorithm SHA256).Hash.ToLowerInvariant()
if ($PreStageHash -ne [string]$Manifest.installedConfigBeforeSha256) {
    throw "A9 pre-stage configuration snapshot hash drifted"
}

# Preserve the changed test result before replacing only the two exact targets.
$PostRunRoot = Join-Path $ResolvedRunRoot `
    ("postrun-" + (Get-Date -Format "yyyyMMdd-HHmmssfff"))
New-Item -ItemType Directory -Path $PostRunRoot -Force | Out-Null
Copy-Item -LiteralPath $SaveTarget -Destination `
    (Join-Path $PostRunRoot "SaveGames") -Recurse -Force
Copy-Item -LiteralPath $StateTarget -Destination `
    (Join-Path $PostRunRoot "ModState") -Recurse -Force
Copy-Item -LiteralPath $TargetConfig -Destination `
    (Join-Path $PostRunRoot "installed-config-after.lua") -Force

# Targets were resolved and compared with the two explicit narrow paths above.
Remove-Item -LiteralPath $SaveTarget -Recurse -Force
New-Item -ItemType Directory -Path $SaveTarget -Force | Out-Null
Get-ChildItem -LiteralPath $SaveSnapshot -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $SaveTarget `
        -Recurse -Force
}
Remove-Item -LiteralPath $StateTarget -Recurse -Force
New-Item -ItemType Directory -Path $StateTarget -Force | Out-Null
Get-ChildItem -LiteralPath $StateSnapshot -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $StateTarget `
        -Recurse -Force
}
Copy-Item -LiteralPath $PreStageConfig -Destination $TargetConfig -Force

Assert-ManifestEqual $ExpectedSaveManifest `
    (Get-TreeManifest $SaveTarget) "A9 restored SaveGames"
Assert-ManifestEqual $ExpectedStateManifest `
    (Get-TreeManifest $StateTarget) "A9 restored Mod-State"
$RestoredConfigHash = (Get-FileHash -LiteralPath $TargetConfig `
    -Algorithm SHA256).Hash.ToLowerInvariant()
if ($RestoredConfigHash -ne [string]$Manifest.installedConfigBeforeSha256) {
    throw "A9 installed configuration did not restore exactly"
}

[ordered]@{
    schemaVersion = "1.0.0"
    restoredAt = (Get-Date).ToString("o")
    result = "PASS"
    saveFileCount = $ExpectedSaveManifest.Count
    stateFileCount = $ExpectedStateManifest.Count
    restoredConfigSha256 = $RestoredConfigHash
    changedRunQuarantine = $PostRunRoot
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath `
    (Join-Path $ResolvedRunRoot "restore-verification.json") -Encoding utf8

Write-Host "PASS restored exact A9 SaveGames, Mod State, and formal installed config"
Write-Host "Changed run preserved at: $PostRunRoot"
