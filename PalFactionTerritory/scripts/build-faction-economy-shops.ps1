$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$UAssetGui = Join-Path $ProjectRoot "tools\vendor\UAssetGUI-v1.1.0\UAssetGUI.exe"
$Mapping = Join-Path $ProjectRoot "tools\vendor\UAssetGUI-v1.1.0\Data\Mappings\Palworld_1_0_1.usmap"
$WorkspaceRoot = Split-Path -Parent $ProjectRoot
$RepakCandidates = Get-ChildItem -LiteralPath $WorkspaceRoot -Directory |
    ForEach-Object {
        Join-Path $_.FullName "_tools\repak-v0.2.3\repak.exe"
    } |
    Where-Object { Test-Path -LiteralPath $_ }
if (@($RepakCandidates).Count -ne 1) {
    throw "expected exactly one workspace repak v0.2.3 executable"
}
$Repak = @($RepakCandidates)[0]
$GeneratedRoot = Join-Path $ProjectRoot "generated\faction-economy-shops"
$CompiledRoot = Join-Path $ProjectRoot "build\faction-economy-shops-data"
$CompiledData = Join-Path $CompiledRoot "Pal\Content\Pal\DataTable\ItemShop"
$RoundtripRoot = Join-Path $ProjectRoot "build\faction-economy-shops-roundtrip"
$PakRoot = Join-Path $ProjectRoot "build\faction-economy-shops-pakroot"
$PakData = Join-Path $PakRoot "Pal\Content\Pal\DataTable\ItemShop"
$ArtifactRoot = Join-Path $ProjectRoot "artifacts\faction-economy-shops"
$PakPath = Join-Path $ArtifactRoot "PalFactionTerritory_FactionEconomyShops_P.pak"

if (-not (Test-Path -LiteralPath $UAssetGui)) {
    throw "UAssetGUI is missing: $UAssetGui"
}
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $UAssetGui).Hash -ne
    "B7D75C0893F1A60E565853AE638BC21F2416CD12C2D9D854E297ABB87CEB3263") {
    throw "UAssetGUI v1.1.0 hash mismatch"
}
if (-not (Test-Path -LiteralPath $Mapping)) {
    throw "Palworld_1_0_1 mapping is missing: $Mapping"
}
if (-not (Test-Path -LiteralPath $Repak)) {
    throw "repak v0.2.3 is missing: $Repak"
}

Push-Location $ProjectRoot
try {
    & node `
        "tools\build_faction_economy_shops.mjs" `
        "contracts\faction_economy.v1.json" `
        "contracts\faction_economy_shops.v1.json" `
        "evidence\faction-economy-assets-20260729\Pal\Content\Pal\DataTable\ItemShop\DT_ItemShopCreateData.json" `
        "evidence\faction-economy-assets-20260729\Pal\Content\Pal\DataTable\ItemShop\DT_ItemShopCreateData_Common.json" `
        "evidence\faction-economy-assets-20260729\Pal\Content\Pal\DataTable\ItemShop\DT_ItemShopLotteryData.json" `
        "evidence\faction-economy-assets-20260729\Pal\Content\Pal\DataTable\ItemShop\DT_ItemShopLotteryData_Common.json" `
        "generated\faction-economy-shops"
    if ($LASTEXITCODE -ne 0) {
        throw "economy shop JSON generation failed"
    }

    New-Item -ItemType Directory -Path $CompiledData -Force | Out-Null
    New-Item -ItemType Directory -Path $RoundtripRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $PakData -Force | Out-Null
    New-Item -ItemType Directory -Path $ArtifactRoot -Force | Out-Null

    $Tables = @(
        @{
            Source = "DT_ItemShopCreateData.PFT_Economy.json"
            Asset = "DT_ItemShopCreateData"
        },
        @{
            Source = "DT_ItemShopCreateData_Common.PFT_Economy.json"
            Asset = "DT_ItemShopCreateData_Common"
        },
        @{
            Source = "DT_ItemShopLotteryData.PFT_Economy.json"
            Asset = "DT_ItemShopLotteryData"
        },
        @{
            Source = "DT_ItemShopLotteryData_Common.PFT_Economy.json"
            Asset = "DT_ItemShopLotteryData_Common"
        }
    )

    foreach ($Table in $Tables) {
        $SourceJson = Join-Path $GeneratedRoot $Table.Source
        $TargetAsset = Join-Path $CompiledData ($Table.Asset + ".uasset")
        $Process = Start-Process `
            -FilePath $UAssetGui `
            -ArgumentList @(
                "fromjson",
                $SourceJson,
                $TargetAsset,
                "Palworld_1_0_1"
            ) `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        if ($Process.ExitCode -ne 0) {
            throw "UAssetGUI fromjson failed: $($Table.Source)"
        }

        $RoundtripJson = Join-Path $RoundtripRoot ($Table.Asset + ".roundtrip.json")
        $Process = Start-Process `
            -FilePath $UAssetGui `
            -ArgumentList @(
                "tojson",
                $TargetAsset,
                $RoundtripJson,
                "VER_UE5_1",
                "Palworld_1_0_1"
            ) `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
        if ($Process.ExitCode -ne 0) {
            throw "UAssetGUI tojson failed: $($Table.Asset)"
        }

        foreach ($Extension in @(".uasset", ".uexp")) {
            $CompiledFile = Join-Path $CompiledData ($Table.Asset + $Extension)
            if (-not (Test-Path -LiteralPath $CompiledFile)) {
                throw "compiled asset is missing: $CompiledFile"
            }
            Copy-Item `
                -LiteralPath $CompiledFile `
                -Destination (Join-Path $PakData ($Table.Asset + $Extension)) `
                -Force
        }
    }

    $ExpectedNames = $Tables | ForEach-Object {
        $_.Asset + ".uasset"
        $_.Asset + ".uexp"
    } | Sort-Object
    $ActualNames = Get-ChildItem -LiteralPath $PakData -File |
        Select-Object -ExpandProperty Name |
        Sort-Object
    if (($ExpectedNames -join "`n") -ne ($ActualNames -join "`n")) {
        throw "PAK staging root contains unexpected or missing files"
    }

    & $Repak pack $PakRoot $PakPath
    if ($LASTEXITCODE -ne 0) {
        throw "repak pack failed"
    }

    $ExpectedEntries = $ExpectedNames | ForEach-Object {
        "Pal/Content/Pal/DataTable/ItemShop/$_"
    } | Sort-Object
    $ActualEntries = & $Repak list $PakPath
    if ($LASTEXITCODE -ne 0) {
        throw "repak list failed"
    }
    $ActualEntries = $ActualEntries |
        ForEach-Object { $_ -replace "\\", "/" } |
        Sort-Object
    if (($ExpectedEntries -join "`n") -ne ($ActualEntries -join "`n")) {
        throw "PAK entry list does not match the eight expected assets"
    }

    & python "tools\verify_faction_economy_shops.py"
    if ($LASTEXITCODE -ne 0) {
        throw "economy shop verification failed"
    }

    Write-Output (
        "BUILT faction economy shops: " +
        "7 representatives, 26 products, 37 requested items, " +
        "8 PAK entries; runtime activation remains disabled"
    )
}
finally {
    Pop-Location
}
