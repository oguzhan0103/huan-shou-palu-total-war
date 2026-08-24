$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Uninstaller = Join-Path $ProjectRoot `
    "player-tools\Quick-Uninstall-PalFactionTerritory.ps1"
if (-not (Test-Path -LiteralPath $Uninstaller -PathType Leaf)) {
    throw "Quick uninstaller is missing: $Uninstaller"
}

$TempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$TestRoot = Join-Path $TempBase ("pwft-uninstall-test-" + [guid]::NewGuid().ToString("N"))
$GameRoot = Join-Path $TestRoot "SteamLibrary\steamapps\common\Palworld"
$Win64Root = Join-Path $GameRoot "Pal\Binaries\Win64"
$ModsRoot = Join-Path $Win64Root "ue4ss\Mods"
$CoreMod = Join-Path $ModsRoot "PalFactionTerritory0"
$StateRoot = Join-Path $CoreMod "State"
$QaHarness = Join-Path $ModsRoot "PalFactionTerritoryQAHarness0"
$OtherMod = Join-Path $ModsRoot "SomeOtherMod0"
$Addon = Join-Path $ModsRoot "PalMultiOtomo0"
$LogicRoot = Join-Path $GameRoot "Pal\Content\Paks\LogicMods"
$AssetRoot = Join-Path $GameRoot "Pal\Content\Paks\~mods"
$BackupRoot = Join-Path $TestRoot "Backups"

function Write-FixtureFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Assert-Exists {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Expected path to exist: $Path"
    }
}

function Assert-Missing {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        throw "Expected path to be absent: $Path"
    }
}

try {
    Write-FixtureFile `
        (Join-Path $Win64Root "Palworld-Win64-Shipping.exe") "fake executable"
    Write-FixtureFile (Join-Path $Win64Root "ue4ss\UE4SS.dll") "shared"
    Write-FixtureFile (Join-Path $StateRoot "progression.json") "state-data"
    Write-FixtureFile (Join-Path $QaHarness "Scripts\main.lua") "qa"
    Write-FixtureFile (Join-Path $OtherMod "Scripts\main.lua") "other"
    Write-FixtureFile (Join-Path $Addon "Scripts\main.lua") "addon"
    Write-FixtureFile (Join-Path $LogicRoot "PalFactionTerritory0.pak") "logic"
    Write-FixtureFile (Join-Path $LogicRoot "Pal-Windows.pak") "original"
    Write-FixtureFile `
        (Join-Path $AssetRoot "PalFactionTerritory_FactionEconomyShops_P.pak") `
        "economy"
    Write-FixtureFile `
        (Join-Path $AssetRoot "PalFactionTerritory_RayneMerchant_P.pak") `
        "rayne"
    Write-FixtureFile (Join-Path $AssetRoot "OtherAuthor_P.pak") "other-pak"

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $Uninstaller -GameRoot $GameRoot -BackupRoot $BackupRoot -PreviewOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Preview-only uninstall failed."
    }
    Assert-Exists $CoreMod
    Assert-Exists (Join-Path $LogicRoot "PalFactionTerritory0.pak")
    Assert-Missing $BackupRoot

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $Uninstaller -GameRoot $GameRoot -BackupRoot $BackupRoot -Yes
    if ($LASTEXITCODE -ne 0) {
        throw "Fixture uninstall failed."
    }

    Assert-Missing $CoreMod
    Assert-Missing $QaHarness
    Assert-Missing (Join-Path $LogicRoot "PalFactionTerritory0.pak")
    Assert-Missing `
        (Join-Path $AssetRoot "PalFactionTerritory_FactionEconomyShops_P.pak")
    Assert-Missing `
        (Join-Path $AssetRoot "PalFactionTerritory_RayneMerchant_P.pak")
    Assert-Exists (Join-Path $Win64Root "ue4ss\UE4SS.dll")
    Assert-Exists $OtherMod
    Assert-Exists $Addon
    Assert-Exists (Join-Path $LogicRoot "Pal-Windows.pak")
    Assert-Exists (Join-Path $AssetRoot "OtherAuthor_P.pak")

    $Backups = @(Get-ChildItem -LiteralPath $BackupRoot -Directory)
    if ($Backups.Count -ne 1) {
        throw "Expected exactly one state backup, found $($Backups.Count)."
    }
    $BackedUpState = Join-Path $Backups[0].FullName "State\progression.json"
    Assert-Exists $BackedUpState
    if ([System.IO.File]::ReadAllText($BackedUpState) -ne "state-data") {
        throw "The backed-up State file changed."
    }
    Assert-Exists (Join-Path $Backups[0].FullName "backup-manifest.json")

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $Uninstaller -GameRoot $GameRoot -BackupRoot $BackupRoot `
        -Yes -SkipStateBackup
    if ($LASTEXITCODE -ne 0) {
        throw "Idempotent second uninstall failed."
    }
    Assert-Exists $OtherMod
    Assert-Exists $Addon

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $Uninstaller -GameRoot $GameRoot -BackupRoot $BackupRoot `
        -Yes -SkipStateBackup -RemoveOfficialAddons
    if ($LASTEXITCODE -ne 0) {
        throw "Optional add-on removal failed."
    }
    Assert-Missing $Addon
    Assert-Exists $OtherMod

    Write-Host "PASS quick uninstaller preview, exact removal, State backup, idempotency, and shared-file preservation"
}
finally {
    $ResolvedTestRoot = [System.IO.Path]::GetFullPath($TestRoot)
    $ExpectedPrefix = $TempBase + [System.IO.Path]::DirectorySeparatorChar + `
        "pwft-uninstall-test-"
    if ($ResolvedTestRoot.StartsWith(
        $ExpectedPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -and (Test-Path -LiteralPath $ResolvedTestRoot)) {
        Remove-Item -LiteralPath $ResolvedTestRoot -Recurse -Force
    }
}
