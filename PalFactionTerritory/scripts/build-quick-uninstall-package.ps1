param(
    [string]$OutputRoot = "",
    [string]$ReleaseVersion = "1.0.5"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $ProjectRoot "artifacts\releases"
}
if ($ReleaseVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "ReleaseVersion must use semantic x.y.z form."
}

& powershell -NoLogo -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $ProjectRoot "tools\test_quick_uninstall.ps1")
if ($LASTEXITCODE -ne 0) {
    throw "Quick uninstaller safety test failed; package was not created."
}

$OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot)
New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$PackageName = "PalworldTotalWar-v$ReleaseVersion-Quick-Uninstall"
$StageRoot = Join-Path $OutputRoot "$PackageName-staging"
$ZipPath = Join-Path $OutputRoot "$PackageName.zip"
$HashPath = "$ZipPath.sha256.json"

foreach ($Candidate in @($StageRoot, $ZipPath, $HashPath)) {
    $Resolved = [System.IO.Path]::GetFullPath($Candidate)
    $ExpectedPrefix = $OutputRoot.TrimEnd('\', '/') + `
        [System.IO.Path]::DirectorySeparatorChar
    if (-not $Resolved.StartsWith(
        $ExpectedPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to clean outside the selected release directory: $Resolved"
    }
    if (Test-Path -LiteralPath $Resolved) {
        Remove-Item -LiteralPath $Resolved -Recurse -Force
    }
}

New-Item -ItemType Directory -Path $StageRoot -Force | Out-Null
$PlayerToolsRoot = Join-Path $ProjectRoot "player-tools"
$PlayerToolFiles = @(Get-ChildItem -LiteralPath $PlayerToolsRoot -File)
if ($PlayerToolFiles.Count -ne 4) {
    throw "Expected four reviewed player-tool files, found $($PlayerToolFiles.Count)."
}
foreach ($PlayerTool in $PlayerToolFiles) {
    Copy-Item -LiteralPath $PlayerTool.FullName `
        -Destination (Join-Path $StageRoot $PlayerTool.Name)
}

Compress-Archive -Path (Join-Path $StageRoot "*") `
    -DestinationPath $ZipPath -CompressionLevel Optimal

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $EntryNames = @($Archive.Entries | ForEach-Object {
        $_.FullName.Replace('\', '/')
    })
    foreach ($Required in @(
        "Quick-Uninstall-PalFactionTerritory.ps1",
        "Quick-Uninstall-PalFactionTerritory.cmd"
    )) {
        if ($EntryNames -notcontains $Required) {
            throw "Quick-uninstall package is missing: $Required"
        }
    }
    if ($EntryNames.Count -ne 4 -or
        @($EntryNames | Where-Object { $_ -like "*.cmd" }).Count -ne 2 -or
        @($EntryNames | Where-Object { $_ -like "*.md" }).Count -ne 1) {
        throw "Quick-uninstall package does not contain the reviewed four-file layout."
    }
}
finally {
    $Archive.Dispose()
}

$ZipHash = Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256
$HashRecord = [ordered]@{
    file = [System.IO.Path]::GetFileName($ZipPath)
    bytes = (Get-Item -LiteralPath $ZipPath).Length
    sha256 = $ZipHash.Hash.ToLowerInvariant()
}
$HashRecord | ConvertTo-Json | Set-Content -LiteralPath $HashPath -Encoding UTF8

Write-Host "PASS quick-uninstall package: $ZipPath"
Write-Host "SHA256 $($HashRecord.sha256)"
