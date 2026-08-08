[CmdletBinding()]
param(
    [string]$ObjectDump = "E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\UE4SS_ObjectDump.txt",
    [string]$ModdingKitRoot = "E:\mod\PalworldModdingKit",
    [string]$CurrentExecutable = "E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\Palworld-Win64-Shipping.exe",
    [string]$AppManifest = "E:\SteamLibrary\steamapps\appmanifest_1623730.acf"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ManagerHeader = Join-Path $ModdingKitRoot "Source\Pal\Public\PalInvaderManager.h"
$UtilityHeader = Join-Path $ModdingKitRoot "Source\Pal\Public\PalUtility.h"
$BiomeHeader = Join-Path $ModdingKitRoot "Source\Pal\Public\EPalBiomeType.h"
$InvaderTable = Join-Path $ProjectRoot "evidence\asset_json\DT_PalInvader.mapped.json"
$CurrentAssetRoot = Join-Path $ProjectRoot "evidence\build24467282\raid-assets"
$CurrentInvaderUasset = Join-Path $CurrentAssetRoot "Pal\Content\Pal\DataTable\Invader\DT_PalInvader.uasset"
$CurrentInvaderUexp = Join-Path $CurrentAssetRoot "Pal\Content\Pal\DataTable\Invader\DT_PalInvader.uexp"
$CurrentBaseUasset = Join-Path $CurrentAssetRoot "Pal\Content\Pal\Blueprint\Incident\Invader\BP_PalIncidentInvaderBase.uasset"
$CurrentBaseUexp = Join-Path $CurrentAssetRoot "Pal\Content\Pal\Blueprint\Incident\Invader\BP_PalIncidentInvaderBase.uexp"
$CurrentEnemyUasset = Join-Path $CurrentAssetRoot "Pal\Content\Pal\Blueprint\Incident\Invader\BP_PalIncidentInvaderEnemy.uasset"
$CurrentEnemyUexp = Join-Path $CurrentAssetRoot "Pal\Content\Pal\Blueprint\Incident\Invader\BP_PalIncidentInvaderEnemy.uexp"
$RaidSource = Join-Path $ProjectRoot "mod0\ue4ss\PalFactionTerritory0\Scripts\pwft\settlement_raid.lua"
$EvidenceRoot = Join-Path $ProjectRoot "evidence\contracts"
$EvidencePath = Join-Path $EvidenceRoot "settlement-raid-negotiator-lifecycle-build24467282.json"

foreach ($Path in @(
    $ObjectDump,
    $CurrentExecutable,
    $AppManifest,
    $ManagerHeader,
    $UtilityHeader,
    $BiomeHeader,
    $InvaderTable,
    $RaidSource,
    $CurrentInvaderUasset,
    $CurrentInvaderUexp,
    $CurrentBaseUasset,
    $CurrentBaseUexp,
    $CurrentEnemyUasset,
    $CurrentEnemyUexp
)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required native-contract input is missing: $Path"
    }
}

function Require-Match {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )
    if (-not [regex]::IsMatch(
        $Text,
        $Pattern,
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )) {
        throw $Message
    }
}

$ManagerText = Get-Content -LiteralPath $ManagerHeader -Raw -Encoding utf8
$UtilityText = Get-Content -LiteralPath $UtilityHeader -Raw -Encoding utf8
$BiomeText = Get-Content -LiteralPath $BiomeHeader -Raw -Encoding utf8
$InvaderText = Get-Content -LiteralPath $InvaderTable -Raw -Encoding utf8
$RaidText = Get-Content -LiteralPath $RaidSource -Raw -Encoding utf8
$AppManifestText = Get-Content -LiteralPath $AppManifest -Raw -Encoding utf8

Require-Match $AppManifestText `
    '"buildid"\s+"24467282"' `
    "Steam appmanifest does not target Build 24467282"

Require-Match $ManagerText `
    'UFUNCTION\(BlueprintCallable\)\s+void StartInvaderMarchForBaseCamp\(FGuid campID\);' `
    "Public PalInvaderManager base-camp lifecycle entry was not found"
Require-Match $ManagerText `
    'UPalInvaderIncidentBase\* RequestIncidentVisitorNPC_BP' `
    "Native visitor/negotiator incident stage was not found"
Require-Match $ManagerText `
    'UFUNCTION\(BlueprintCallable, BlueprintImplementableEvent\)\s+UPalInvaderIncidentBase\* RequestIncidentInvaderEnemy_BP' `
    "Protected internal Incident request signature was not found"
Require-Match $ManagerText `
    'UFUNCTION\(BlueprintCallable\)\s+bool RequestIncidentInvaderEnemy\(const FGuid& Guid, UPalInvaderBaseCampObserver\* Observer\);' `
    "Private Observer-dependent Incident request signature was not found"
Require-Match $UtilityText `
    'static UPalInvaderManager\* GetInvaderManager\(const UObject\* WorldContextObject\);' `
    "PalUtility world-owned InvaderManager accessor was not found"
Require-Match $BiomeText `
    'Undefined,\s+Meadow,' `
    "EPalBiomeType Meadow enum ordering was not found"
Require-Match $InvaderText `
    '"Name": "GroupName".{0,700}"Value": "Invader_Group_Monster_Grade5_Basic".{0,700}"Name": "BiomeID".{0,700}"Value": "Meadow".{0,700}"Name": "InvadeGradeMin".{0,700}"Value": 61.{0,700}"Name": "InvadeGradeMax".{0,700}"Value": 80' `
    "Grade-5 Basic Meadow table row with the 61-80 selection band was not found"

$DumpRequirements = @(
    "/Script/Pal.PalUtility:GetInvaderManager",
    "/Script/Pal.PalInvaderManager:StartInvaderMarchForBaseCamp",
    "/Script/Pal.PalInvaderManager:StartInvaderMarchForBaseCamp:campID",
    "/Script/Pal.PalInvaderIncidentBase:SelectInvaders:Grade",
    "/Script/Pal.PalInvaderIncidentBase:SelectInvaders:Biome",
    "/Script/Pal.PalInvaderIncidentBase:GetInvaderStartPoint",
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderVisitorNPC.BP_PalIncidentInvaderVisitorNPC_C:GetInvaderStartPoint",
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderVisitorNPC.BP_PalIncidentInvaderVisitorNPC_C:OnAllCharacterSpawned",
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderBase.BP_PalIncidentInvaderBase_C:GetTargetBaseCampPosition",
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderBase.BP_PalIncidentInvaderBase_C:OnCharacterSpawned",
    "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderEnemy.BP_PalIncidentInvaderEnemy_C:OnCharacterSpawned",
    "EPalBiomeType::Meadow"
)
foreach ($Pattern in $DumpRequirements) {
    if (-not (Select-String -LiteralPath $ObjectDump -SimpleMatch -Quiet -Pattern $Pattern)) {
        throw "Retail object dump contract is missing: $Pattern"
    }
}

foreach ($CurrentBinaryToken in @(
    "GetInvaderManager",
    "StartInvaderMarchForBaseCamp",
    "SelectInvaders",
    "GetInvaderInfo"
)) {
    & rg.exe -a -F -q -m 1 -- $CurrentBinaryToken $CurrentExecutable
    if ($LASTEXITCODE -ne 0) {
        throw "Current Build 24467282 executable is missing reflected name: $CurrentBinaryToken"
    }
}

$ExpectedCurrentAssetHashes = @{
    $CurrentInvaderUasset = "A34A2D74979D5FECD7EBBA84F9CF588181EFC5F48E7F977CA9EEC5E6BA09B3F5"
    $CurrentInvaderUexp = "10AD158A1AB0A2D24EFF5EF39A49BCCA19083BD382D94481D89ECA5A47658422"
    $CurrentBaseUasset = "FE4EE1ADAF88B96F76FD4587AF0CFF31E597810F4F02717391401FBF38B7F1CC"
    $CurrentBaseUexp = "250F1C7CC1A990BEDE43EA198E152D021BEAA0487D17EAF82E139F64739175CA"
    $CurrentEnemyUasset = "0EBA099AFE2B54AD76B78A40420E40889981DDCF1188E92830AFCB6FCF8ED525"
    $CurrentEnemyUexp = "03E286F452AAA38CE70E03949A52846EB55156B9BF287AA7997B82B2AD372F97"
}
foreach ($Entry in $ExpectedCurrentAssetHashes.GetEnumerator()) {
    $ActualHash = (Get-FileHash -LiteralPath $Entry.Key -Algorithm SHA256).Hash
    if ($ActualHash -ne $Entry.Value) {
        throw "Current Build 24467282 native asset drifted: $($Entry.Key)"
    }
}

foreach ($RequiredSourceToken in @(
    "GetInvaderManager",
    "StartInvaderMarchForBaseCamp",
    "/Script/Pal.PalInvaderIncidentBase:SelectInvaders",
    "NATIVE_MEADOW_BIOME_VALUE = 1",
    "BP_PalIncidentInvaderVisitorNPC",
    "NATIVE_NEGOTIATOR_ACTIVE",
    "start-point-success-set-failed",
    "NATIVE_HOOK_REGISTRATION",
    'attempt_native_hook_registration(instance, "pre-launch")'
)) {
    if (-not $RaidText.Contains($RequiredSourceToken)) {
        throw "Settlement raid source is missing: $RequiredSourceToken"
    }
}
foreach ($ForbiddenSourceToken in @(
    "RequestIncidentInvaderEnemy_BP",
    "RequestIncidentInvaderEnemy(",
    "Debug_InvaderMarchForNearCamp",
    "InvaderMarchForNearestCamp",
    "StaticConstructObject",
    "PalCheatManager"
)) {
    if ($RaidText.Contains($ForbiddenSourceToken)) {
        throw "Settlement raid source still contains unsafe lifecycle token: $ForbiddenSourceToken"
    }
}

New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[ordered]@{
    schemaVersion = "1.0.0"
    verifiedAt = (Get-Date).ToString("o")
    gameBuild = "24467282"
    sourceContractBuild = "24181527"
    verificationMode = "offline-only"
    result = "PASS_OFFLINE_CONTRACT"
    liveStatus = "pending-authorised-game-test"
    managerAccessor = "PalUtility.GetInvaderManager"
    lifecycleEntry = "PalInvaderManager.StartInvaderMarchForBaseCamp"
    lifecyclePhases = @(
        "manager-requested",
        "negotiator-created",
        "negotiator-active",
        "assault"
    )
    startPointOverride = @{
        vector = $true
        successReturnValue = $true
    }
    duplicateFallbackLaunchesEnabled = $false
    negotiatorTimeoutMs = 180000
    rampagingPalFallback = @{
        enabled = $false
        liveValidated = $false
        activationPolicy = "only-after-native-negotiator-route-live-fails"
        nativePredator = $true
        targetHatePerResident = 100000.0
        makeUncapturable = $true
        nativeSpawnerProvider = "pending-live-proof"
        saveWrites = $false
    }
    selectionHook = "/Script/Pal.PalInvaderIncidentBase:SelectInvaders"
    runtimeHookPaths = @(
        "/Script/Pal.PalInvaderIncidentBase:SelectInvaders",
    "/Script/Pal.PalInvaderIncidentBase:GetInvaderStartPoint",
        "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderVisitorNPC.BP_PalIncidentInvaderVisitorNPC_C:GetInvaderStartPoint",
        "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderVisitorNPC.BP_PalIncidentInvaderVisitorNPC_C:OnAllCharacterSpawned",
        "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderBase.BP_PalIncidentInvaderBase_C:GetTargetBaseCampPosition",
        "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderBase.BP_PalIncidentInvaderBase_C:OnCharacterSpawned",
        "/Game/Pal/Blueprint/Incident/Invader/BP_PalIncidentInvaderEnemy.BP_PalIncidentInvaderEnemy_C:OnCharacterSpawned"
    )
    hookRegistrationPolicy = @{
        startupFiniteRetriesMs = @(0, 250, 1000, 3000, 8000)
        worldLoadedFiniteRetriesMs = @(0, 250, 1000, 3000, 8000)
        preLaunchSynchronousRetry = $true
        failClosedUnlessAllSevenReady = $true
    }
    selectionGrade = 80
    selectionBiome = "Meadow"
    selectionBiomeValue = 1
    selectedNativeGroup = "Invader_Group_Monster_Grade5_Basic"
    selectedNativeGradeBand = @{
        min = 61
        max = 80
    }
    rejectedRoutes = @(
        "RequestIncidentInvaderEnemy_BP",
        "RequestIncidentInvaderEnemy",
        "Debug_InvaderMarchForNearCamp",
        "InvaderMarchForNearestCamp",
        "PalCheatManager",
        "StaticConstructObject"
    )
    inputs = @{
        appManifest = $AppManifest
        currentExecutable = $CurrentExecutable
        objectDump = $ObjectDump
        managerHeader = $ManagerHeader
        utilityHeader = $UtilityHeader
        biomeHeader = $BiomeHeader
        invaderTable = $InvaderTable
        raidSource = $RaidSource
        currentInvaderUasset = $CurrentInvaderUasset
        currentInvaderUexp = $CurrentInvaderUexp
        currentInvaderBaseUasset = $CurrentBaseUasset
        currentInvaderBaseUexp = $CurrentBaseUexp
        currentInvaderEnemyUasset = $CurrentEnemyUasset
        currentInvaderEnemyUexp = $CurrentEnemyUexp
    }
    currentExecutableSha256 = (Get-FileHash -LiteralPath $CurrentExecutable -Algorithm SHA256).Hash
    currentNativeAssetHashes = @{
        invaderUasset = (Get-FileHash -LiteralPath $CurrentInvaderUasset -Algorithm SHA256).Hash
        invaderUexp = (Get-FileHash -LiteralPath $CurrentInvaderUexp -Algorithm SHA256).Hash
        invaderBaseUasset = (Get-FileHash -LiteralPath $CurrentBaseUasset -Algorithm SHA256).Hash
        invaderBaseUexp = (Get-FileHash -LiteralPath $CurrentBaseUexp -Algorithm SHA256).Hash
        invaderEnemyUasset = (Get-FileHash -LiteralPath $CurrentEnemyUasset -Algorithm SHA256).Hash
        invaderEnemyUexp = (Get-FileHash -LiteralPath $CurrentEnemyUexp -Algorithm SHA256).Hash
    }
    liveTestPerformed = $false
    saveFilesChanged = $false
    originalGamePakChanged = $false
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EvidencePath -Encoding utf8

Write-Host "PASS settlement raid native lifecycle contract"
Write-Host "Evidence: $EvidencePath"
Write-Host "No game process was started and no save or original PAK was changed."
