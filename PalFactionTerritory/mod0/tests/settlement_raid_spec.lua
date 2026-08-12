package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?/init.lua",
    package.path,
}, ";")

local Config = require("pwft.config")
local SettlementRaid = require("pwft.settlement_raid")

assert(SettlementRaid.validate_config(Config.settlementRaid))
assert(Config.settlementRaid.replaceNativePlayerBaseInvasion == true)
assert(Config.settlementRaid.executionMode == "attendance-simulation")
assert(Config.settlementRaid.nearestPalFactionId
    == "pwft.faction.dark_nocturnal_pal_tribe")
assert(Config.settlementRaid.settlement.nativeRegionNameId
    == "Grass_Village_001")
assert(Config.settlementRaid.settlement.fastTravelPointId
    == "FTPoint24")
assert(Config.settlementRaid.nightOnly == true)
assert(Config.settlementRaid.qaAuthoritativeNightRpcEnabled == true)
assert(Config.settlementRaid.qaNightSettleDelayMs == 3000)
assert(Config.settlementRaid.level == 80)
assert(Config.settlementRaid.countdownSeconds == 15 * 60)
assert(Config.settlementRaid.nativeRandomFallbackDelayMs == 8000)
assert(Config.settlementRaid.nativeFallbackLaunchEnabled == false)
assert(Config.settlementRaid.nativeNegotiatorTimeoutMs == 180000)
assert(Config.settlementRaid.nativeDirectIncidentFallbackEnabled == true)
assert(Config.settlementRaid.nativeDirectIncidentConfirmationDelayMs == 15000)
assert(Config.settlementRaid.cleanupDelayMs == 15 * 60 * 1000)
assert(Config.settlementRaid.rampagingPalFallback.enabled == false)
assert(Config.settlementRaid.rampagingPalFallback.liveValidated == false)
assert(Config.settlementRaid.rampagingPalFallback.predator == true)
assert(Config.settlementRaid.rampagingPalFallback.targetHate == 100000.0)
assert(Config.settlementRaid.rampagingPalFallback.makeUncapturable == true)
assert(Config.settlementRaid.rampagingPalFallback.saveWrites == false)
assert(Config.settlementRaid.attendanceSimulation.enabled == true)
assert(Config.settlementRaid.attendanceSimulation.qaOnly == false)
assert(Config.settlementRaid.attendanceSimulation.liveValidated == true)
assert(Config.settlementRaid.attendanceSimulation.resultBindingEnabled == true)
assert(Config.settlementRaid.attendanceSimulation.playerPresentRadius
    == 22000.0)
assert(Config.settlementRaid.attendanceSimulation.aggroRadius
    == 65000.0)
assert(Config.settlementRaid.attendanceSimulation.nativeCountdownSpawn.enabled
    == true)
assert(Config.settlementRaid.attendanceSimulation.nativeCountdownSpawn
    .loadedWorldFallbackEnabled == false)
assert(#Config.settlementRaid.attendanceSimulation.nativeCountdownSpawn.palIds
    == 4)
assert(#Config.settlementRaid.attendanceSimulation.nativeCountdownSpawn.offsets
    == 4)
assert(Config.settlementRaid.attendanceSimulation.nativeCountdownSpawn.saveWrites
    == false)
assert(Config.settlementRaid.attendanceSimulation.nativeCountdownSpawn
    .maxResolveAttempts == 40)
assert(Config.settlementRaid.attendanceSimulation.nativeCountdownSpawn
    .attackerReadyRetryMs == 250)
assert(Config.settlementRaid.attendanceSimulation.nativeCountdownSpawn
    .attackerReadyMaxAttempts == 32)
assert(#Config.settlementRaid.attendanceSimulation.qaCandidateBlueprints == 2)
assert(Config.settlementRaid.attendanceSimulation.qaCandidateBlueprints[1]
    == "BP_NegativeKoala_C")
assert(Config.settlementRaid.attendanceSimulation.qaSpawnAnchor.X
    == -346100.0)
assert(Config.settlementRaid.attendanceSimulation.qaSpawnRadius == 5000.0)
assert(Config.settlementRaid.attendanceSimulation.targetPlayerHate
    == 125000.0)
assert(Config.settlementRaid.attendanceSimulation.targetResidentHate
    == 175000.0)
assert(Config.settlementRaid.attendanceSimulation.targetResidentHate
    > Config.settlementRaid.attendanceSimulation.targetPlayerHate)
assert(Config.settlementRaid.attendanceSimulation.noActorSpawnWhenAbsent
    == true)

assert(SettlementRaid.classify_incident_name(
    "BP_PalIncidentInvaderVisitorNPC_C /Game/Test.Visitor"
) == "visitor")
assert(SettlementRaid.classify_incident_name(
    "BP_PalIncidentInvaderEnemy_C /Game/Test.Enemy"
) == "assault")
assert(SettlementRaid.classify_incident_name(
    "BP_UnrelatedIncident_C /Game/Test.Unknown"
) == "unknown")

local contract = SettlementRaid.native_contract(
    Config.settlementRaid
)
assert(contract.groupName
    == "Invader_Group_Monster_Grade5_Basic")
assert(contract.executionMode == "attendance-simulation")
assert(contract.managerAccessor
    == "PalUtility.GetInvaderManager")
assert(contract.managerLaunch
    == "PalInvaderManager.StartInvaderMarchForBaseCamp")
assert(contract.selectionPath
    == "/Script/Pal.PalInvaderIncidentBase:SelectInvaders")
assert(contract.selectionGrade == 80)
assert(contract.selectionBiome == "Meadow")
assert(contract.startPointPath
    == "/Script/Pal.PalInvaderIncidentBase:GetInvaderStartPoint")
assert(string.find(
    contract.visitorStartPointPath,
    "BP_PalIncidentInvaderVisitorNPC",
    1,
    true
) ~= nil)
assert(string.find(
    contract.visitorAllSpawnedPath,
    "OnAllCharacterSpawned",
    1,
    true
) ~= nil)
assert(contract.startPointOverridesSuccessFlag == true)
assert(contract.fallbackLaunchEnabled == false)
assert(contract.negotiatorTimeoutMs == 180000)
assert(contract.directIncidentFallback.enabled == true)
assert(contract.directIncidentFallback.request
    == "PalInvaderManager.RequestIncidentVisitorNPC(campId, observer, true) -> PalInvaderManager.RequestIncidentInvaderEnemy(campId, observer)")
assert(contract.directIncidentFallback.activationPolicy
    == "after-native-negotiator-open-ground-confirmation-fails")
assert(contract.directIncidentFallback.confirmationDelayMs == 15000)
assert(contract.directIncidentFallback.ownsCharacterLifecycle == false)
assert(contract.directIncidentFallback.saveWrites == false)
assert(#contract.lifecyclePhases == 4)
assert(contract.lifecyclePhases[2] == "negotiator-created")
assert(contract.lifecyclePhases[4] == "assault")
assert(contract.rampagingPalFallback.enabled == false)
assert(contract.rampagingPalFallback.liveValidated == false)
assert(contract.rampagingPalFallback.predator == true)
assert(contract.rampagingPalFallback.targetHate == 100000.0)
assert(contract.rampagingPalFallback.saveWrites == false)
assert(contract.rampagingPalFallback.providerInterface
    == "spawn_wave(request, on_spawn_actor)")
assert(contract.attendanceSimulation.enabled == true)
assert(contract.attendanceSimulation.liveValidated == true)
assert(contract.attendanceSimulation.resultBindingEnabled == true)
assert(contract.attendanceSimulation.resultBridge.deathPath
    == "/Script/Pal.PalCharacter:OnDeadCharacter")
assert(contract.attendanceSimulation.resultBridge.participationRule
    == "designated-leader-killed-by-local-player-or-owned-pal")
assert(contract.attendanceSimulation.resultBridge.victoryRule
    == "all-registered-attackers-dead")
assert(contract.attendanceSimulation.resultBridge.timerCleanupMaySettleRaid
    == false)
assert(contract.attendanceSimulation.aggroRadius == 65000.0)
assert(contract.attendanceSimulation.qaSpawnRadius == 5000.0)
assert(contract.attendanceSimulation.nativeCountdownSpawn.enabled == true)
assert(contract.attendanceSimulation.nativeCountdownSpawn
    .loadedWorldFallbackEnabled == false)
assert(contract.attendanceSimulation.nativeCountdownSpawn.count == 4)
assert(contract.attendanceSimulation.nativeCountdownSpawn.managerAccessor
    == "PalUtility.GetNPCManager")
assert(contract.attendanceSimulation.nativeCountdownSpawn.spawnCall
    == "PalNPCManager.SpawnNPCForServer")
assert(contract.attendanceSimulation.nativeCountdownSpawn.nameConstruction
    == "KismetStringLibrary.Conv_StringToName")
assert(contract.attendanceSimulation.nativeCountdownSpawn.readinessRetryMs
    == 250)
assert(contract.attendanceSimulation.nativeCountdownSpawn.readinessMaxAttempts
    == 32)
assert(contract.attendanceSimulation.nativeCountdownSpawn.cleanupMethod
    == "Actor.K2_DestroyActor")
assert(contract.attendanceSimulation.combatActivation.initializer
    == "PalAIController.SetInitialValue(false, true)")
assert(contract.attendanceSimulation.combatActivation.controller
    == "PalAIController.SetActiveAI(true)")
assert(contract.attendanceSimulation.combatActivation.actor
    == "PalCharacter.ChangeBattleModeFlag_ToAll(true)")
assert(contract.attendanceSimulation.targetPlayerHate == 125000.0)
assert(contract.attendanceSimulation.targetResidentHate == 175000.0)
assert(contract.attendanceSimulation.absentResolution
    == "background-record-only")
assert(contract.attendanceSimulation.actorSpawnsWhenAbsent == false)
assert(contract.attendanceSimulation.recorderInterface
    == "record(background_raid_record)")
assert(contract.attendanceSimulation.saveWrites == false)

Config.settlementRaid.rampagingPalFallback.enabled = true
local unvalidated_ok = pcall(function()
    SettlementRaid.validate_config(Config.settlementRaid)
end)
assert(unvalidated_ok == false)
Config.settlementRaid.rampagingPalFallback.liveValidated = true
assert(SettlementRaid.validate_config(Config.settlementRaid))
Config.settlementRaid.rampagingPalFallback.enabled = false
Config.settlementRaid.rampagingPalFallback.liveValidated = false

Config.settlementRaid.executionMode = "attendance-simulation"
Config.settlementRaid.attendanceSimulation.enabled = false
local attendance_disabled_ok = pcall(function()
    SettlementRaid.validate_config(Config.settlementRaid)
end)
assert(attendance_disabled_ok == false)
Config.settlementRaid.attendanceSimulation.enabled = true
assert(SettlementRaid.validate_config(Config.settlementRaid))
assert(string.find(
    contract.targetPositionPath,
    "GetTargetBaseCampPosition",
    1,
    true
) ~= nil)
assert(#contract.spawnedPaths == 2)
assert(contract.ownsCharacterLifecycle == true)
assert(contract.saveWrites == false)
assert(Config.settlementRaid.allowedCharacterIds == nil)
assert(Config.settlementRaid.waves == nil)

print("PASS settlement raid contract (live-validated NPC-manager siege, resident-first combat, authoritative death/result bridge, and no save writes)")
