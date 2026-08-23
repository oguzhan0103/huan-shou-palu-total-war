[CmdletBinding()]
param(
    [string]$GameRoot = "E:\SteamLibrary\steamapps\common\Palworld"
)

$ErrorActionPreference = "Stop"
$ExpectedBuildId = "24575825"
$ExpectedObjectDumpSha256 =
    "3e84e8a6936b7d1c33de6cfc034c4a200655a3e762cbc2ec4c6a57516476ec78"
$SteamManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
$ObjectDump = Join-Path $GameRoot `
    "Pal\Binaries\Win64\ue4ss\UE4SS_ObjectDump.txt"

foreach ($Path in @($SteamManifest, $ObjectDump)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Dynamic economy native-contract input is missing: $Path"
    }
}
$ManifestText = Get-Content -LiteralPath $SteamManifest -Raw -Encoding utf8
foreach ($Field in @("buildid", "TargetBuildID")) {
    if ($ManifestText -notmatch (
        '"' + $Field + '"\s+"' + $ExpectedBuildId + '"'
    )) {
        throw "Steam $Field does not match Build $ExpectedBuildId"
    }
}
$ObjectDumpSha256 = (
    Get-FileHash -LiteralPath $ObjectDump -Algorithm SHA256
).Hash.ToLowerInvariant()
if ($ObjectDumpSha256 -ne $ExpectedObjectDumpSha256) {
    throw "Build $ExpectedBuildId ObjectDump hash drifted: $ObjectDumpSha256"
}

$RequiredPatterns = @(
    "ArrayProperty /Script/Pal.PalShopBase:ProductArray",
    "Function /Script/Pal.PalShopBase:OnRep_ProductArray",
    "ObjectProperty /Script/Pal.PalShopProductBase:MyProductGiver",
    "NameProperty /Script/Pal.PalShopProductGiver_StaticItem:ProductStaticItemID",
    "IntProperty /Script/Pal.PalShopProductGiver_StaticItem:OverridePrice",
    "BoolProperty /Script/Pal.PalShopProductGiverBase:bIsInfinityStockFlag",
    "IntProperty /Script/Pal.PalShopProductGiverBase:StockNum",
    "IntProperty /Script/Pal.PalShopProductGiverBase:MaxStockNum",
    "Function /Script/Pal.PalShopProductGiverBase:OnRep_StockNum",
    "Function /Script/Pal.PalShopProductGiverBase:OnRep_MaxStockNum",
    "StructProperty /Script/Pal.PalShopProductGiverBase:ProductCreateData",
    "IntProperty /Script/Pal.PalItemShopCreateDataStruct:OverridePrice",
    "IntProperty /Script/Pal.PalItemShopCreateDataStruct:Stock"
)
foreach ($Pattern in $RequiredPatterns) {
    if (-not (Select-String -LiteralPath $ObjectDump `
            -SimpleMatch -Quiet -Pattern $Pattern)) {
        throw "Build $ExpectedBuildId dynamic shop contract missing: $Pattern"
    }
}

Write-Host (
    "PASS Build {0} dynamic ItemShop contract: {1} reflected price/stock/product fields; ObjectDump={2}" `
        -f $ExpectedBuildId, $RequiredPatterns.Count, $ObjectDumpSha256
)
