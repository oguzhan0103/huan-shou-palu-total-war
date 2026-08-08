[CmdletBinding()]
param(
    [string]$ObjectDump = "E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\UE4SS_ObjectDump.txt",
    [string]$AppManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$BridgeSource = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\commerce_bridge.lua"
$ConfigSource = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\config.lua"
$EconomyContract = Join-Path $ProjectRoot "contracts\faction_economy.v1.json"
$EvidenceRoot = Join-Path $ProjectRoot "evidence\contracts"
$EvidencePath = Join-Path $EvidenceRoot "commerce-sale-replication-build24370881.json"

foreach ($Path in @(
    $ObjectDump,
    $AppManifest,
    $BridgeSource,
    $ConfigSource,
    $EconomyContract
)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required commerce sale contract input is missing: $Path"
    }
}

$ManifestText = Get-Content -LiteralPath $AppManifest -Raw -Encoding utf8
if ($ManifestText -notmatch '"buildid"\s+"24370881"') {
    throw "Steam appmanifest does not target Build 24370881"
}

$DumpRequirements = @(
    "/Script/Pal.PalNetworkShopComponent:RequestSellItems_ToServer",
    "/Script/Pal.PalNetworkShopComponent:RequestSellItems_ToServer:SellItemSlotIDArray",
    "/Script/Pal.PalUIItemShopBase:TrySell",
    "/Script/Pal.PalUIItemShopBase:TrySell:ReturnValue",
    "/Script/Pal.PalItemSlot:StackCount",
    "/Script/Pal.PalItemSlot:ItemId",
    "/Script/Pal.PalItemSlot:OnRep_StackCount",
    "/Script/Pal.PalItemSlot:OnRep_ItemId",
    "/Script/Pal.PalItemSlot:GetStackCount",
    "/Script/Pal.PalItemSlot:GetItemId",
    "EPalShopSellResultType::Successed",
    "EPalShopSellResultType::Failed"
)
foreach ($Pattern in $DumpRequirements) {
    if (-not (Select-String -LiteralPath $ObjectDump -SimpleMatch -Quiet -Pattern $Pattern)) {
        throw "Retail object dump commerce sale contract is missing: $Pattern"
    }
}

$BridgeText = Get-Content -LiteralPath $BridgeSource -Raw -Encoding utf8
$ConfigText = Get-Content -LiteralPath $ConfigSource -Raw -Encoding utf8
$Economy = Get-Content -LiteralPath $EconomyContract -Raw -Encoding utf8 |
    ConvertFrom-Json
foreach ($RequiredSourceToken in @(
    "ITEM_SLOT_STACK_REPLICATION_HOOK",
    "ITEM_SLOT_ID_REPLICATION_HOOK",
    "sale_item_replication_confirms",
    "NATIVE_SELL_REPLICATION_CONFIRMED",
    "native-sale-replication-confirmed-probe-only"
)) {
    if (-not $BridgeText.Contains($RequiredSourceToken)) {
        throw "Commerce sale replication source is missing: $RequiredSourceToken"
    }
}
if (-not $ConfigText.Contains("nativeSaleReplicationProbeEnabled = true")) {
    throw "Read-only native sale replication probe is not enabled"
}
if ($Economy.runtimeActivation.requestedSaleReputationSettlementEnabled -ne $false) {
    throw "Sale reputation settlement was enabled before live acceptance"
}

New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[ordered]@{
    schemaVersion = "1.0.0"
    verifiedAt = (Get-Date).ToString("o")
    gameBuild = "24370881"
    result = "PASS"
    reflectedSellResultRpc = "not-exposed"
    authoritativeObservation = @(
        "PalItemSlot.OnRep_StackCount",
        "PalItemSlot.OnRep_ItemId"
    )
    acceptanceRequirements = @(
        "PalUIItemShopBase.TrySell returned true",
        "RequestSellItems_ToServer was associated with a registered faction shop",
        "every captured sold slot replicated the requested decrement or item replacement"
    )
    probeEnabled = $true
    reputationSettlementEnabled = $false
    objectDump = @{
        path = $ObjectDump
        sha256 = (Get-FileHash -LiteralPath $ObjectDump -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    source = @{
        path = $BridgeSource
        sha256 = (Get-FileHash -LiteralPath $BridgeSource -Algorithm SHA256).Hash.ToLowerInvariant()
    }
} | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath $EvidencePath -Encoding utf8

Write-Host "PASS commerce sale replication contract (Build 24370881; settlement disabled)"
Write-Host "Evidence: $EvidencePath"
