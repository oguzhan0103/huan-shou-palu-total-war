$ErrorActionPreference = 'Stop'

$gameRoot = 'E:\SteamLibrary\steamapps\common\Palworld'
$vsWhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnetSdks = if ($null -ne $dotnetCommand) {
    @(& $dotnetCommand.Source --list-sdks 2>$null)
} else {
    @()
}

$checks = [ordered]@{
    GameRoot = Test-Path -LiteralPath $gameRoot
    PalWindowsPak = Test-Path -LiteralPath (Join-Path $gameRoot 'Pal\Content\Paks\Pal-Windows.pak')
    PalModSettings = Test-Path -LiteralPath (Join-Path $gameRoot 'Mods\PalModSettings.ini')
    DotnetRuntimeCommand = $null -ne $dotnetCommand
    DotnetSdk = $dotnetSdks.Count -gt 0
    VisualStudioCpp = if (Test-Path -LiteralPath $vsWhere) {
        -not [string]::IsNullOrWhiteSpace((& $vsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath))
    } else { $false }
    UnrealEditor = $null -ne (Get-Command UnrealEditor -ErrorAction SilentlyContinue)
    UE4SS = Test-Path -LiteralPath (Join-Path $gameRoot 'Pal\Binaries\Win64\ue4ss')
    PalSchema = Test-Path -LiteralPath (Join-Path $gameRoot 'Pal\Binaries\Win64\ue4ss\Mods\PalSchema')
    CurrentUsmap = @(Get-ChildItem -LiteralPath $gameRoot -Recurse -Filter '*.usmap' -ErrorAction SilentlyContinue).Count -gt 0
}

[pscustomobject]$checks | ConvertTo-Json
