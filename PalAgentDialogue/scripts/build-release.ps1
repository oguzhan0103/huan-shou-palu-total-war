$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Version = "1.0.0"
$PackageName = "PalAgentDialogue-Experimental-v$Version-windows-x64"
$ReleaseRoot = Join-Path $ProjectRoot "release"
$StageRoot = Join-Path $ReleaseRoot $PackageName
$ArchivePath = Join-Path $ReleaseRoot ($PackageName + ".zip")

$ResolvedProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$ResolvedReleaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
$ResolvedStageRoot = [System.IO.Path]::GetFullPath($StageRoot)
if (-not $ResolvedReleaseRoot.StartsWith($ResolvedProjectRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
    -not $ResolvedStageRoot.StartsWith($ResolvedReleaseRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to build outside the project release directory"
}

Push-Location $ProjectRoot
try {
    & cargo fmt --all -- --check
    if ($LASTEXITCODE -ne 0) { throw "cargo fmt failed" }
    & cargo test --all-targets --locked
    if ($LASTEXITCODE -ne 0) { throw "cargo test failed" }
    & cargo clippy --all-targets --locked -- -D warnings
    if ($LASTEXITCODE -ne 0) { throw "cargo clippy failed" }
    & cargo build --release --locked
    if ($LASTEXITCODE -ne 0) { throw "release build failed" }

    if (Test-Path -LiteralPath $ResolvedStageRoot) {
        [System.IO.Directory]::Delete($ResolvedStageRoot, $true)
    }
    New-Item -ItemType Directory -Path $ResolvedStageRoot -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ResolvedStageRoot "bin") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ResolvedStageRoot "ue4ss") -Force | Out-Null

    Copy-Item -LiteralPath (Join-Path $ProjectRoot "target\release\pal-agent-dialogue.exe") -Destination (Join-Path $ResolvedStageRoot "bin")
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "ue4ss\PalAgentDialogueBridge0") -Destination (Join-Path $ResolvedStageRoot "ue4ss\PalAgentDialogueBridge0") -Recurse
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "contracts") -Destination $ResolvedStageRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "character-packs") -Destination $ResolvedStageRoot -Recurse
    foreach ($File in @("README.md", "PRIVACY.md", "SECURITY.md", "THIRD_PARTY_NOTICES.md", "CHANGELOG.md", "LICENSE", ".env.example")) {
        Copy-Item -LiteralPath (Join-Path $ProjectRoot $File) -Destination $ResolvedStageRoot
    }

    Compress-Archive -Path (Join-Path $ResolvedStageRoot "*") -DestinationPath $ArchivePath -CompressionLevel Optimal -Force
    $ArchiveHash = Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath
    $ChecksumLine = $ArchiveHash.Hash.ToLowerInvariant() + "  " + [System.IO.Path]::GetFileName($ArchivePath)
    [System.IO.File]::WriteAllText((Join-Path $ReleaseRoot "SHA256SUMS.txt"), $ChecksumLine + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

    Write-Output ("PASS package=" + $ArchivePath)
    Write-Output ("SHA256 " + $ArchiveHash.Hash)
}
finally {
    Pop-Location
}
