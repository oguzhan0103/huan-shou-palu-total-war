[CmdletBinding()]
param(
    [string]$GameRoot = "",
    [string]$BackupRoot = "",
    [switch]$PreviewOnly,
    [switch]$Yes,
    [switch]$SkipStateBackup,
    [switch]$RemoveOfficialAddons
)

$ErrorActionPreference = "Stop"

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    ).TrimEnd('\', '/')
}

function Test-PalworldRoot {
    param([Parameter(Mandatory = $true)][string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $false
    }
    try {
        $Full = Get-FullPath $Candidate
    }
    catch {
        return $false
    }
    return Test-Path -LiteralPath (
        Join-Path $Full "Pal\Binaries\Win64\Palworld-Win64-Shipping.exe"
    ) -PathType Leaf
}

function Add-Candidate {
    param(
        [Parameter(Mandatory = $true)][System.Collections.ArrayList]$List,
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return
    }
    try {
        $Full = Get-FullPath $Candidate
    }
    catch {
        return
    }
    if (-not $List.Contains($Full)) {
        [void]$List.Add($Full)
    }
}

function Get-SteamRoots {
    $Roots = New-Object System.Collections.ArrayList
    foreach ($RegistryLocation in @(
        @{ Path = "HKCU:\Software\Valve\Steam"; Name = "SteamPath" },
        @{ Path = "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam"; Name = "InstallPath" },
        @{ Path = "HKLM:\SOFTWARE\Valve\Steam"; Name = "InstallPath" }
    )) {
        try {
            $Value = Get-ItemPropertyValue -LiteralPath $RegistryLocation.Path `
                -Name $RegistryLocation.Name -ErrorAction Stop
            Add-Candidate -List $Roots -Candidate $Value
        }
        catch {
            # Steam is not required to be registered when GameRoot is explicit.
        }
    }

    foreach ($ProgramRoot in @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles
    )) {
        if (-not [string]::IsNullOrWhiteSpace($ProgramRoot)) {
            Add-Candidate -List $Roots -Candidate (Join-Path $ProgramRoot "Steam")
        }
    }

    $InitialRoots = @($Roots)
    foreach ($SteamRoot in $InitialRoots) {
        $LibraryFile = Join-Path $SteamRoot "steamapps\libraryfolders.vdf"
        if (-not (Test-Path -LiteralPath $LibraryFile -PathType Leaf)) {
            continue
        }
        try {
            $Text = [System.IO.File]::ReadAllText($LibraryFile)
            foreach ($Match in [regex]::Matches($Text, '"path"\s+"([^"]+)"')) {
                $LibraryRoot = $Match.Groups[1].Value.Replace('\\', '\')
                Add-Candidate -List $Roots -Candidate $LibraryRoot
            }
        }
        catch {
            # A malformed Steam library file should not widen uninstall scope.
        }
    }
    return @($Roots)
}

function Resolve-GameRoot {
    param([string]$ExplicitRoot)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitRoot)) {
        if (-not (Test-PalworldRoot $ExplicitRoot)) {
            throw "Palworld executable was not found below the supplied GameRoot."
        }
        return Get-FullPath $ExplicitRoot
    }

    $Candidates = New-Object System.Collections.ArrayList

    $Cursor = Get-FullPath $PSScriptRoot
    while (-not [string]::IsNullOrWhiteSpace($Cursor)) {
        Add-Candidate -List $Candidates -Candidate $Cursor
        $Parent = Split-Path -Parent $Cursor
        if ([string]::IsNullOrWhiteSpace($Parent) -or $Parent -eq $Cursor) {
            break
        }
        $Cursor = $Parent
    }

    foreach ($SteamRoot in Get-SteamRoots) {
        Add-Candidate -List $Candidates -Candidate (
            Join-Path $SteamRoot "steamapps\common\Palworld"
        )
    }

    $Valid = @($Candidates | Where-Object { Test-PalworldRoot $_ })
    if ($Valid.Count -gt 0) {
        $WithCore = @($Valid | Where-Object {
            Test-Path -LiteralPath (
                Join-Path $_ "Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0"
            )
        })
        if ($WithCore.Count -eq 1) {
            return Get-FullPath $WithCore[0]
        }
        if ($Valid.Count -eq 1) {
            return Get-FullPath $Valid[0]
        }
    }

    if ($Yes) {
        throw "Palworld could not be located automatically. Pass -GameRoot explicitly."
    }

    Write-Host "Palworld could not be selected automatically."
    $Entered = Read-Host "Enter the Palworld game root (the folder containing Pal)"
    if (-not (Test-PalworldRoot $Entered)) {
        throw "The selected folder is not a valid Palworld game root."
    }
    return Get-FullPath $Entered
}

function Assert-ExactChild {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$AllowedRoot
    )

    $FullCandidate = Get-FullPath $Candidate
    $FullAllowedRoot = Get-FullPath $AllowedRoot
    $Prefix = $FullAllowedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $FullCandidate.StartsWith(
        $Prefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing a target outside the expected Palworld subdirectory: $FullCandidate"
    }
    if ($FullCandidate -eq $FullAllowedRoot) {
        throw "Refusing to remove an allowed root directory itself: $FullCandidate"
    }
    return $FullCandidate
}

function Assert-NotReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to recursively remove a junction or symbolic link: $Path"
    }
}

$ResolvedGameRoot = Resolve-GameRoot $GameRoot
$Win64Root = Get-FullPath (Join-Path $ResolvedGameRoot "Pal\Binaries\Win64")
$ModsRoot = Get-FullPath (Join-Path $Win64Root "ue4ss\Mods")
$PaksRoot = Get-FullPath (Join-Path $ResolvedGameRoot "Pal\Content\Paks")
$LogicModsRoot = Get-FullPath (Join-Path $PaksRoot "LogicMods")
$AssetModsRoot = Get-FullPath (Join-Path $PaksRoot "~mods")

$CoreMod = Assert-ExactChild `
    (Join-Path $ModsRoot "PalFactionTerritory0") $ModsRoot
$QaHarness = Assert-ExactChild `
    (Join-Path $ModsRoot "PalFactionTerritoryQAHarness0") $ModsRoot
$LogicPak = Assert-ExactChild `
    (Join-Path $LogicModsRoot "PalFactionTerritory0.pak") $LogicModsRoot
$EconomyPak = Assert-ExactChild `
    (Join-Path $AssetModsRoot "PalFactionTerritory_FactionEconomyShops_P.pak") `
    $AssetModsRoot
$RaynePak = Assert-ExactChild `
    (Join-Path $AssetModsRoot "PalFactionTerritory_RayneMerchant_P.pak") `
    $AssetModsRoot

$Targets = @(
    [pscustomobject]@{ Label = "Core UE4SS mod"; Path = $CoreMod; Kind = "Directory" },
    [pscustomobject]@{ Label = "Project QA harness"; Path = $QaHarness; Kind = "Directory" },
    [pscustomobject]@{ Label = "LogicMod PAK"; Path = $LogicPak; Kind = "File" },
    [pscustomobject]@{ Label = "Economy PAK"; Path = $EconomyPak; Kind = "File" },
    [pscustomobject]@{ Label = "Rayne merchant PAK"; Path = $RaynePak; Kind = "File" }
)

if ($RemoveOfficialAddons) {
    $MultiPalAddon = Assert-ExactChild `
        (Join-Path $ModsRoot "PalMultiOtomo0") $ModsRoot
    $Targets += [pscustomobject]@{
        Label = "Optional official multi-Pal add-on"
        Path = $MultiPalAddon
        Kind = "Directory"
    }
}

Write-Host ""
Write-Host "PalFactionTerritory quick uninstall"
Write-Host "Game root: $ResolvedGameRoot"
Write-Host ""
Write-Host "Exact project-owned targets:"
foreach ($Target in $Targets) {
    $Status = if (Test-Path -LiteralPath $Target.Path) { "present" } else { "absent" }
    Write-Host "  [$Status] $($Target.Label): $($Target.Path)"
}
Write-Host ""
Write-Host "Never removed: Palworld SaveGames, UE4SS itself, dwmapi.dll,"
Write-Host "other Mods, original PAK files, or uninstall backups."
if (-not $RemoveOfficialAddons) {
    Write-Host "PalMultiOtomo0 is preserved. Use -RemoveOfficialAddons to remove it."
}

if ($PreviewOnly) {
    Write-Host "PASS preview only; no files were changed."
    return
}

$BlockingProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -in @(
        "Palworld-Win64-Shipping",
        "Palworld",
        "UnrealEditor",
        "UnrealEditor-Cmd"
    )
})
if ($BlockingProcesses.Count -gt 0) {
    throw "Close Palworld and Unreal Editor before uninstalling."
}

if (-not $Yes) {
    $Confirmation = Read-Host "Type UNINSTALL to remove the listed project files"
    if ($Confirmation -cne "UNINSTALL") {
        Write-Host "Cancelled; no files were changed."
        return
    }
}

$BackupLocation = $null
$StateRoot = Join-Path $CoreMod "State"
if (-not $SkipStateBackup -and (Test-Path -LiteralPath $StateRoot -PathType Container)) {
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $Documents = [Environment]::GetFolderPath("MyDocuments")
        if ([string]::IsNullOrWhiteSpace($Documents)) {
            throw "Documents could not be resolved. Pass -BackupRoot or use -SkipStateBackup."
        }
        $BackupRoot = Join-Path $Documents "PalFactionTerritory-UninstallBackups"
    }
    $ResolvedBackupRoot = Get-FullPath $BackupRoot
    $CorePrefix = $CoreMod + [System.IO.Path]::DirectorySeparatorChar
    if ($ResolvedBackupRoot.StartsWith(
        $CorePrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    ) -or $ResolvedBackupRoot -eq $CoreMod) {
        throw "The backup directory cannot be inside the Mod directory being removed."
    }

    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $BackupLocation = Join-Path $ResolvedBackupRoot $Timestamp
    $BackupState = Join-Path $BackupLocation "State"
    New-Item -ItemType Directory -Path $BackupLocation -Force | Out-Null
    Copy-Item -LiteralPath $StateRoot -Destination $BackupState -Recurse -Force

    $BackedUpFiles = @(
        Get-ChildItem -LiteralPath $BackupState -Recurse -File -Force |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    path = $_.FullName.Substring($BackupState.Length + 1).Replace('\', '/')
                    bytes = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
    )
    $BackupManifest = [ordered]@{
        schemaVersion = "1.0.0"
        createdAt = (Get-Date).ToString("o")
        gameRoot = $ResolvedGameRoot
        sourceState = $StateRoot
        files = $BackedUpFiles
    }
    $BackupManifest | ConvertTo-Json -Depth 5 | Set-Content `
        -LiteralPath (Join-Path $BackupLocation "backup-manifest.json") `
        -Encoding UTF8
    Write-Host "State backup created: $BackupLocation"
}

$Removed = 0
foreach ($Target in $Targets) {
    if (-not (Test-Path -LiteralPath $Target.Path)) {
        continue
    }
    if ($Target.Kind -eq "Directory") {
        Assert-NotReparsePoint $Target.Path
        Remove-Item -LiteralPath $Target.Path -Recurse -Force
    }
    else {
        Remove-Item -LiteralPath $Target.Path -Force
    }
    if (Test-Path -LiteralPath $Target.Path) {
        throw "A target still exists after removal: $($Target.Path)"
    }
    $Removed++
    Write-Host "Removed: $($Target.Label)"
}

Write-Host ""
Write-Host "PASS PalFactionTerritory uninstall completed. Removed targets: $Removed"
if ($null -ne $BackupLocation) {
    Write-Host "State backup: $BackupLocation"
}
Write-Host "Shared UE4SS and Palworld SaveGames were not changed."
