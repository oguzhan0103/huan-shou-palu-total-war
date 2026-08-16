return {
    schemaVersion = "1.0.0",
    releaseId = "PalFactionTerritory0-mod0",
    expectedSteamBuildId = "24575825",
    defaultMapMode = "Original",

    -- The progression core owns reputation, independent human memberships,
    -- ranks, commerce caps, guard eligibility, and ending gates. Runtime
    -- Reputation is authoritative in a Mod-owned external sidecar.  The
    -- store is activated only after the native read-only identity probe has
    -- resolved a stable world/player profile key.  It never reads or writes
    -- Palworld's own SaveGames payload.
    factionProgression = {
        enabled = true,
        joinRepresentative = {
            nativeJoinRepresentativeEnabled = true,
            representativeInteractionDistance = 500,
            confirmationKeys = "F1/F2",
            storyContentIncluded = false,
        },
        playerGuard = {
            nativePlayerGuardEnabled = true,
            controllerClassPath =
                "/Game/Pal/Blueprint/Controller/NPC/"
                    .. "BP_NPCAIController_Visitor_Guardman."
                    .. "BP_NPCAIController_Visitor_Guardman_C",
            followIntervalMs = 1000,
            acceptanceRadius = 350,
            followFailureLimit = 8,
            storyContentIncluded = false,
            liveTest = {
                enabled = false,
                key = "F4",
                factionId = "pwft.faction.rayne_syndicate",
                characterId = "NPC_Hunter",
                characterClassPath =
                    "/Game/Pal/Blueprint/Character/NPC/Normal/"
                        .. "BP_NPC_Hunter.BP_NPC_Hunter_C",
                spawnBackDistance = 180,
                spawnSideDistance = 160,
            },
        },
        persistence = {
            enabled = true,
            mode = "mod-sidecar-json",
            deferredIdentity = true,
            companionLedgerEnabled = true,
            -- main.lua replaces this with the portable Mod-owned State
            -- directory derived from its own loaded source path.
            rootPath = nil,
            identityProbe = {
                enabled = true,
                readOnly = true,
                retryDelaysMs = {
                    1000,
                    3000,
                    8000,
                },
            },
        },
    },

    -- Finite Pal reconciliation is implemented as a Mod-owned service inside
    -- the progression snapshot. Fan content packs register each tribe's
    -- token quota, quests, and discourse content through its public API.
    -- Native raid results are observed through the manager-owned start/end
    -- broadcasts and the enemy incident's spawn/death callbacks. Events stay
    -- fail-closed until a content pack maps the native invader group to one
    -- Pal faction. The native dialogue presenter uses
    -- a Mod-owned text panel and only handles registered representative actors;
    -- it never supplies story content or mutates deterministic outcomes. The optional Agent
    -- adapter is active as a presentation-only bridge: unavailable or invalid
    -- responses fall back to the deterministic offline tree, and a model can
    -- never directly mutate affinity, quests, inventory, saves, or world state.
    palReconciliation = {
        enabled = true,
        normalizedRaidAdapterEnabled = true,
        nativeRaidResultBindingEnabled = true,
        attendanceRaidResultBindingEnabled = true,
        nativeRaidLiveTest = {
            enabled = false,
            groupName = "Invader_Group_Monster_Grade5_Basic",
            palFactionId = "pwft.faction.dark_nocturnal_pal_tribe",
            contentPackId = "pwft.qa.native-raid",
            contentVersion = "1.0.0",
            tokenQuota = 3,
            maximumAffinityPerDiscourse = 10,
        },
        leaderDesignation = "first-spawn-of-final-wave",
        offlineDialogueTreeEnabled = true,
        -- The router is data/UI-backend agnostic and may run before a cooked
        -- native presenter exists. It returns localization-key-only views and
        -- routes every choice back through the deterministic discourse Core.
        dialoguePresenterRouterEnabled = true,
        representativeInteractionRouterEnabled = true,
        representativeInteractionDistance = 500,
        nativeDialoguePresenterEnabled = true,
        agentAdapterEnabled = true,
        agentDefaultLocale = "zh-CN",
        -- The Ollama process stays outside Palworld.  This Mod writes only a
        -- strictly validated request into its own State directory and polls a
        -- presentation-only response.  main.lua derives both paths from the
        -- loaded Mod directory so Steam does not need environment variables.
        agentBridge = {
            enabled = true,
            rootPath = nil,
            operatorInputPath = nil,
            operatorStatusPath = nil,
            pollIntervalMs = 500,
            requestTtlSeconds = 600,
            operatorCommandTtlSeconds = 300,
        },
        storyContentIncluded = false,
    },

    -- Content authors install Lua data modules inside this Mod's Scripts
    -- search path and opt them in here. UE4SS isolates each Mod's Lua global
    -- environment, so cross-Mod _G registration is intentionally unsupported.
    -- The base ships with no enabled story pack: an empty list means the Core
    -- remains a mechanics-only foundation.
    contentModules = {
        enabled = true,
        modules = {},
        fallbackLocale = "zh-CN",
        storyContentIncludedByBase = false,
    },

    -- Native attitude and NPC-leader guard adapters are optional trusted
    -- providers.  The empty whitelist is fail-closed: the mechanics APIs are
    -- available, but no game object can be mutated until an installed content
    -- module explicitly opts in a provider ID + authority pair.
    factionNpcAttitudes = {
        providerWhitelist = {},
    },
    npcLeaderGuards = {
        providerWhitelist = {},
        maxPerLeader = 2,
        maxPerFaction = 6,
        maxPerScene = 12,
        maximumMembersPerFormation = 16,
    },

    -- Player-facing read-only faction panel. It uses a dedicated cooked
    -- WBP_PFT_FactionStatus asset with no map controls or map dependencies,
    -- is never created on the title screen, and appears only after the player
    -- explicitly presses F5. It never writes Palworld save data.
    factionUi = {
        enabled = true,
        key = "F5",
        zOrder = 90,
        -- 1080p-safe wide layout. The original 575x610 panel wrapped every
        -- faction row and clipped the Pal section below the viewport.
        panelPosition = { X = 435.0, Y = 35.0 },
        panelSize = { X = 1050.0, Y = 985.0 },
        minTextWidth = 1010.0,
        targetFontSize = 17,
    },

    -- Seven-faction commerce is driven by the versioned commerce contract.
    -- Native buy results are settled automatically only after Successed.
    -- Item-sale requests are observed but stay unawarded until a confirmed
    -- native/UI success adapter supplies the sold item IDs and counts.
    factionCommerce = {
        enabled = true,
        nativeBridgeEnabled = true,
        -- Palworld exposes no reflected sell-result RPC. Observe only the
        -- authoritative PalItemSlot replication that follows a UI-accepted
        -- sale. This probe logs the result but cannot award reputation while
        -- the economy contract settlement switch remains false.
        nativeSaleReplicationProbeEnabled = true,
        -- Merchant Guild economy counters use the generated PFT_Economy_*
        -- ItemShop rows. Their native spawn, interaction, seven-row binding,
        -- ground placement and cleanup all passed live review at FTPoint90.
        nativeEconomyMerchantSpawnEnabled = true,
        nativeEconomyMerchantSpawnReason =
            "ftpoint90-seven-counter-live-accepted-2026-08-11",
        nativeFactionMerchantSpawnEnabled = false,
        nativeFactionMerchantSpawnReason =
            "ftpoint90-market-island-live-ground-accepted-2026-08-11",
        nativeCharacterAdapter = {
            enabled = true,
            collisionHandlingOverride = 2,
            restockMinutes = 30,
            refreshVendorOnSpawn = true,
            -- Use APalNPCSpawnerBase's public external spawn request so the
            -- ordinary Trader receives a native individual handle and the
            -- same interaction lifecycle as map-authored NPCs.
            asyncMerchantSpawnerEnabled = false,
            -- Ordinary ItemShop counters must use the neutral base spawner.
            -- Boss subclasses reapply their authored character during their
            -- Blueprint tick and can silently turn a requested Trader into a
            -- boss Dark Trader.
            merchantSpawnerClassPath =
                "/Game/Pal/Blueprint/Spawner/BP_MonoNPCSpawner.BP_MonoNPCSpawner_C",
            merchantDefaultActionClassPath =
                "/Game/Pal/Blueprint/Controller/AIAction/NPC/Relax/BP_AIAction_NPC_Relax_SalesPerson.BP_AIAction_NPC_Relax_SalesPerson_C",
        },
        fallbackWindowMode = "real-calendar-day-until-world-day-adapter",
        unresolvedProductPriceAward = "minimum-successful-transaction-award",
        -- Temporary concentrated acceptance route. Ctrl+F9 toggles only one
        -- Merchant Guild counter six metres in front of the local player.
        -- It is reverted to false after live evidence has been captured.
        economyMerchantLiveTest = {
            enabled = false,
            key = "F9",
            factionId = "pwft.faction.rayne_syndicate",
            forwardDistance = 600,
        },
        -- Native transaction acceptance only. When temporarily enabled,
        -- Ctrl+F12 advances the window ID consumed by subsequent real shop
        -- confirmations. It never grants reputation itself, so three capped
        -- hostile-recovery windows can be exercised without waiting three
        -- UTC days. Production keeps this false.
        commerceWindowLiveTest = {
            enabled = false,
            key = "F12",
            windowPrefix = "qa-native-commerce",
            windowCount = 3,
        },
        -- Hostile-commerce acceptance only. When temporarily enabled,
        -- Ctrl+F2 joins the Free Pal Alliance through the normal faction API.
        -- The authored relationship pair then makes Rayne hostile at zero
        -- reputation. Recovery still requires 60 points from confirmed native
        -- Merchant Guild transactions across the three QA windows above.
        hostileCommerceLiveTest = {
            enabled = false,
            key = "F2",
            joinFactionId = "pwft.faction.free_pal_alliance",
            targetFactionId = "pwft.faction.rayne_syndicate",
            contentId = "pwft.qa.hostile-commerce-live-test",
        },
        -- Production lifecycle: load the accepted fixed market only while a
        -- local player is near the island, then destroy all owned counters
        -- after departure. The wider removal radius prevents border thrash.
        economyMerchantPresence = {
            enabled = true,
            -- The accepted market is offset from FTPoint90 and the tower's
            -- level-object origin is not its visible mesh pivot. UE units
            -- are centimetres, so use a forgiving 180 m island-arrival
            -- envelope with 240 m hysteresis.
            activationRadius = 18000,
            deactivationRadius = 24000,
            pollIntervalMs = 2000,
            initialDelayMs = 2500,
        },
    },

    -- Mod 0 is deliberately read-only until runtime IDs have been captured and checked.
    enableMapHookProbe = true,
    -- Postgame visual-only option. N cycles Original -> Human -> Pal while
    -- the live native world map is open. It never marks an area explored or
    -- writes save data.
    enableNativeFogVisualOverride = true,
    -- Human and Pal views share whole-island coastline geometry. Hostile is
    -- red, Friendly blue, Player green; sea and islands without an owner in
    -- the active layer remain transparent. Image_MapBody, map transform, and
    -- all native navigation remain untouched. The material is obtained via
    -- ModActor's cooked hard reference, never a loose external brush.
    enableNativeTerritoryMaterialOverlay = true,
    -- The one-region F9 experiment has served its purpose.  Leaving it off
    -- prevents it from replacing the complete three-state faction overlay.
    enableNativeMapPaintProbe = false,
    -- Development-only diagnostics stay disabled in the playable build.
    enableNativeMapMaterialAnchorProbe = false,
    -- Runtime tower binding is the live source of each map destination's
    -- territory identity; keep it enabled for hostile travel enforcement.
    enableTowerBindingProbe = true,
    -- Reads only reflected fields from the soft pointer.  It never calls Get,
    -- LoadSynchronous, or any method that can load an asset.
    enableSoftMaskPathProbe = false,
    -- Retains the native InvokeFastTravel observation hook alongside the
    -- availability rule; it never initiates travel or writes save data.
    enableFastTravelAudit = true,
    enableMapOverlayMutation = true,
    -- Uses Palworld's existing generic HUD warning channel.  It is separate
    -- from the crime/Wanted widgets and therefore cannot add a crime state.
    enableDangerAreaWarningUi = true,
    -- Runs when the player selects a native fast-travel icon, before
    -- Palworld opens its own confirmation dialog.  It only presents the
    -- existing generic warning; it neither captures input nor blocks travel.
    enableMapFastTravelSelectionWarning = true,
    -- Adds the warning to the already-live native map widget through its
    -- reflected public controls; no private WidgetTree lookup is used.
    enableNativeMapDangerBanner = true,
    -- Reuses Palworld's single native place-name card on region entry. It
    -- never creates a second warning panel and never writes player/save data.
    enableNativePlaceNamePresentation = true,
    -- F10 is a temporary, visual-only probe for the native warning channel.
    -- Keep it off in the release path: the real entry operation invokes the
    -- same warning route without reserving any player-facing key.
    enableDangerAreaWarningProbe = false,
    -- Temporary deterministic live validation only.  While true, F7 invokes
    -- the existing FTPoint24 map-icon click handler after the map is open.
    -- This temporary route is used to reach Small Settlement for the
    -- authorised raid test and is reverted before release.
    enableMapFastTravelSelectionProbe = false,
    mapFastTravelSelectionProbeTarget = "FTPoint24",
    -- Palworld queries this for every visible map point during refresh.  The
    -- gate may return false for hostile destinations, but must never create a
    -- warning widget or schedule UI work from that high-frequency path.
    enableFastTravelEnforcement = true,
    -- Temporary live-capture safety gate. The settlement raid stays isolated
    -- from Pal-faction rage and loaded-actor reconciliation. A later test may
    -- enable levelOverride by itself without re-enabling either risky feature.
    demoNativeRaidSafeMode = true,

    -- Rayne Syndicate post-game Pal merchant. The native Dark Trader class
    -- provides the existing Pal shop UI and combat-capable human AI. Its
    -- dedicated data-table row contains one canonical entry for every Paldex
    -- species/variant, at level 60-70 so prices remain native but expensive.
    rayneMerchant = {
        enabled = true,
        factionId = "pwft.faction.rayne_syndicate",
        towerFastTravelPointId = "WatchTower_1",
        merchantAssetPath = "/Game/Pal/Blueprint/Character/NPC/Fat/BP_NPC_DarkTrader.BP_NPC_DarkTrader",
        merchantClassPath = "/Game/Pal/Blueprint/Character/NPC/Fat/BP_NPC_DarkTrader.BP_NPC_DarkTrader_C",
        -- Reuse the official wanted Dark Trader spawner only as a native NPC
        -- lifecycle host. Before Spawn() runs, replace its wanted character,
        -- AI controller, and action with the ordinary Black Marketeer so the
        -- result has real collision, grounding, combat, and shop interaction.
        spawnerMode = "BossDarkTrader",
        spawnerAssetPath = "/Game/Pal/Blueprint/Spawner/HumanNPCBoss/BP_MonoNPCSpawnerBossBase_BOSS_DarkTrader.BP_MonoNPCSpawnerBossBase_BOSS_DarkTrader",
        spawnerClassPath = "/Game/Pal/Blueprint/Spawner/HumanNPCBoss/BP_MonoNPCSpawnerBossBase_BOSS_DarkTrader.BP_MonoNPCSpawnerBossBase_BOSS_DarkTrader_C",
        spawnerSaveKey = "PFT_Rayne_Merchant_Runtime",
        nativeCharacterId = "NPC_Male_DarkTrader",
        nativeUniqueNpcId = "DarkTrader",
        controllerAssetPath = "/Game/Pal/Blueprint/Controller/NPC/BP_NPCAIController.BP_NPCAIController",
        controllerClassPath = "/Game/Pal/Blueprint/Controller/NPC/BP_NPCAIController.BP_NPCAIController_C",
        defaultActionAssetPath = "/Game/Pal/Blueprint/Controller/AIAction/NPC/Relax/BP_AIAction_NPC_Relax_SalesPerson.BP_AIAction_NPC_Relax_SalesPerson",
        defaultActionClassPath = "/Game/Pal/Blueprint/Controller/AIAction/NPC/Relax/BP_AIAction_NPC_Relax_SalesPerson.BP_AIAction_NPC_Relax_SalesPerson_C",
        expectedActorClassToken = "BP_NPC_DarkTrader_C",
        merchantLevel = 80,
        merchantLevelCap = 80,

        -- The merchant uses the custom all-Paldex shop and follows the Rayne
        -- Syndicate relation: peaceful relations trade, Hostile attacks.
        enableCustomShop = true,
        enableFactionHostility = true,
        shopRowName = "PFT_Rayne_AllPaldex",
        spawnDelayMs = 12000,
        relationRespawnDelayMs = 500,
        -- Fixed from the player-selected point in the 2026-07-23 live run.
        -- The native spawner, rather than a raw character Actor, now owns
        -- final capsule placement and foot grounding.
        capturePlayerAnchorOnLoad = false,
        playerAnchorCaptureMaxDistance = 100000.0,
        fixedSpawnLocation = {
            X = -319082.076,
            Y = 208361.251,
            Z = -23.445,
        },
        fixedSpawnRotation = {
            Pitch = 0.0,
            Yaw = -115.274,
            Roll = 0.0,
        },
        spawnOffsetForward = 700.0,
        spawnOffsetRight = 200.0,
        spawnOffsetUp = 60.0,
        facingYawOffset = 180.0,
        nativeSetupRetryMs = 500,
        nativeSetupMaxAttempts = 40,
        -- Some native spawns produce the correct DarkTrader actor without
        -- publishing SpawnedHandle. Resolve that actor by class and proximity
        -- so the custom shop does not silently fall back to vanilla stock.
        nativeActorFallbackAttempt = 2,
        nativeActorFallbackRadius = 2500.0,
        hostileAwarenessRadius = 2200.0,
        hostilityCheckIntervalMs = 1000,
        restockMinutes = 1440,
        shopRegistrationRetryMs = 1000,
        shopRegistrationMaxAttempts = 12,
        -- Temporary relation round-trip acceptance route. Production keeps
        -- this disabled; when enabled, Ctrl+F11 toggles only the standalone
        -- Rayne Pal merchant between Friendly and Hostile without save writes.
        relationLiveTest = {
            enabled = false,
            key = "F11",
        },
        -- UE4SS 3.0.1 can crash in its TArray metamethod when Lua traverses
        -- the 288 live Pal product wrappers after a world reload. Keep the
        -- complete custom catalog enabled, but fail closed on this optional
        -- cosmetic enhancement until it moves to a native provider.
        enableRainbowPassives = false,
        rainbowChance = 0.70,
        rankFiveChance = 0.20,
        -- UE4SS 3.0.1 has an off-by-one resize bug after the first element of
        -- an initially empty TArray. Keep one guaranteed valid injected slot
        -- until the shop uses the native initializer for multi-passive arrays.
        secondRainbowChance = 0.0,
        traitInjectionRetryMs = 1500,
        traitInjectionMaxAttempts = 4,
        -- Rank-4 skills that are natively valid for ordinary Pals in 1.0.1.
        -- Unique boss, legend, mutation-only, and species-locked skills are
        -- intentionally excluded.
        rainbowPassives = {
            "CraftSpeed_up3",
            "Deffence_up3",
            "MoveSpeed_up_3",
            "PAL_ALLAttack_up3",
            "PAL_FullStomach_Down_3",
            "PAL_Sanity_Down_3",
            "RideJumpCount_Increase1",
            "SelfDeathAddItemDrop_up_3",
            "Stamina_Up_3",
            "SwimSpeed_up_3",
            "Vampire",
            "WorkSuitabilityAddRank_MonsterFarm_2",
        },
        -- Rank-5 pool deliberately combines the seven visible World Tree
        -- passives with the hidden development rows. This merchant is the
        -- one intentional source of these otherwise unobtainable experiments.
        rankFivePassives = {
            "WorldTree_ATK",
            "WorldTree_DEF",
            "WorldTree_CraftSpeed",
            "WorldTree_FullStomach",
            "WorldTree_Sanity",
            "WorldTree_MoveSpeed",
            "WorldTree_ATK_DEF",
            "Logging_up5",
            "Mining_up5",
            "Mining_up6",
            "Mining_up7",
            "Mining_up8",
            "Mining_up9",
            "Mining_up10",
            "Mute_5",
            "LifeSteal_5",
        },
    },

    -- Post-game world normalization is split into independent, fail-closed
    -- capabilities. No level, EXP, faction, HP, damage, or capture value is
    -- written into a save parameter. Keep every capability disabled until its
    -- own live-test phase is explicitly authorized.
    worldBalance = {
        enabled = true,
        targetLevel = 80,
        initializationReapplyDelayMs = 100,
        maxDetailLogCount = 24,
        levelOverride = {
            enabled = false,
            mode = "native-character-initialization-events-only",
        },
        palFactionRage = {
            enabled = false,
            mode = "native-character-initialization-events-only",
            -- Native Predator is Palworld's existing rampaging-Pal state.
            -- It supplies the native classification route and, together with
            -- SetUncapturable, preserves the intended "cannot capture" rule.
            makeUncapturable = true,
            hpMultiplier = 2.0,
            damageMultiplier = 2.0,
        },
        loadedActorReconcile = {
            enabled = false,
            delaysMs = { 5000, 15000 },
            reason = "disabled-after-bulk-world-scan-instability",
        },
    },

    -- Small Settlement is the first NPC-city assault slice. It is bound to
    -- the real Grass_Village_001 entry event and replaces player-base raids
    -- with a bounded, transient attack on the town. The whole island's
    -- nearest Pal faction is the dark/nocturnal tribe, so every participant
    -- is selected from that faction's released, non-boss night roster.
    settlementRaid = {
        enabled = true,
        replaceNativePlayerBaseInvasion = true,
        -- The game-owned incident API reports success on build 24467282 but
        -- creates no visitor or enemy incident at dense player bases. Use the
        -- live-accepted NPC-manager wave as the production route; its result
        -- bridge still requires an actual all-members-dead victory plus direct
        -- player/owned-Pal credit for the designated leader.
        executionMode = "attendance-simulation",
        -- Concentrated live-test switch only. Ctrl+F8 calls this module's
        -- existing force_start path with a five-second countdown; it does not
        -- own actor spawning, AI, targeting, cleanup, or save persistence.
        qaHotkeyEnabled = false,
        -- QA only: native invasion eligibility also checks world time inside
        -- PalInvaderManager. Move the protected test world to night through
        -- the public PalTimeManager API, wait one second, then request the
        -- same manager-owned invasion lifecycle. The preflight snapshot is
        -- restored after testing.
        qaForceNightHour = 23,
        qaAuthoritativeNightRpcEnabled = true,
        qaNightSettleDelayMs = 3000,
        nearestPalFactionId = "pwft.faction.dark_nocturnal_pal_tribe",
        -- Reuse Palworld's own Grade 5 meadow Pal invasion. The native data
        -- table contains several 61-80 compositions under this group, and the
        -- incident itself remains responsible for spawning, marching, AI,
        -- broadcast UI, and cleanup.
        nativeInvaderGroupName = "Invader_Group_Monster_Grade5_Basic",
        level = 80,
        nightOnly = true,
        cooldownSeconds = 3600,
        -- Build 24467282 may create the world-owned incident asynchronously.
        -- The native lifecycle first creates a visitor/negotiator incident
        -- and only creates the enemy incident after that stage completes.
        -- The short window confirms that one of those native stages exists;
        -- the longer timeout diagnoses a negotiator that cannot reach its
        -- destination without manufacturing a second invasion.
        nativeIncidentConfirmationDelayMs = 30000,
        nativeNegotiatorTimeoutMs = 180000,
        -- Dense player bases can make the manager's travel-stage open-ground
        -- search reject every visitor route even though the target camp and
        -- observer are valid.  After the normal request has had a full
        -- confirmation window, ask the same world-owned manager for its native
        -- visitor incident with declaration travel ignored.  If even that
        -- accepted request creates no incident, make one final manager-owned
        -- enemy-incident request for the same camp/observer.  Both routes keep
        -- the game's incident, wave, death and settlement callbacks.
        nativeDirectIncidentFallbackEnabled = true,
        nativeDirectIncidentConfirmationDelayMs = 15000,
        -- Repeated random/all launches can overlap the visitor and enemy
        -- phases. Keep the legacy diagnostic delays but disable those launch
        -- retries; one manager-owned base-camp request is the only production
        -- entry until live evidence proves a retry is necessary.
        nativeFallbackLaunchEnabled = false,
        nativeRandomFallbackDelayMs = 8000,
        nativeAllFallbackDelayMs = 16000,
        -- Optional second implementation route requested for investigation:
        -- create native Predator Pals at the settlement and give nearby human
        -- residents very high hate. It remains fail-closed until the native
        -- spawner/provider is proven in a separately authorised live test.
        rampagingPalFallback = {
            enabled = false,
            liveValidated = false,
            activationPolicy =
                "only-after-native-negotiator-route-live-fails",
            spawnMode =
                "native-predator-spawner-provider-required",
            predator = true,
            targetHate = 100000.0,
            makeUncapturable = true,
            saveWrites = false,
        },
        -- Route three: if the player reaches Small Settlement before the
        -- countdown ends, loaded world Pals inside a larger engagement radius
        -- are converted to transient Predator attackers and given explicit
        -- hate toward the player and every resident. If the player is absent,
        -- no actors are created or modified; only an in-memory/log settlement
        -- record is emitted for a future external backend adapter.
        attendanceSimulation = {
            enabled = true,
            qaOnly = false,
            liveValidated = true,
            resultBindingEnabled = true,
            playerPresentRadius = 22000.0,
            aggroRadius = 65000.0,
            -- When the countdown completes with the player in town, request
            -- several native NPC-manager Pal actors immediately around the
            -- player.  This avoids depending on field-spawner streaming
            -- distance or on a Pal walking in from outside the settlement.
            -- This route is the live-accepted production event source for
            -- Build 24467282; the separate QA hotkey remains disabled.
            nativeCountdownSpawn = {
                enabled = true,
                -- The accepted siege route must create its own attackers.
                -- Never turn an unrelated sleeping field Pal hostile when a
                -- native spawn request fails.
                loadedWorldFallbackEnabled = false,
                palIds = {
                    "NegativeKoala",
                    "MysteryMask",
                    "NegativeKoala",
                    "MysteryMask",
                },
                offsets = {
                    { X = 450.0, Y = 450.0, Z = 100.0 },
                    { X = -450.0, Y = 450.0, Z = 100.0 },
                    { X = 450.0, Y = -450.0, Z = 100.0 },
                    { X = -450.0, Y = -450.0, Z = 100.0 },
                },
                resolveIntervalMs = 250,
                maxResolveAttempts = 40,
                -- An individual handle can publish its actor before the
                -- parameter component, controller, hate system, and AI are
                -- all initialized. Retry the complete setup chain for every
                -- spawned attacker instead of treating the first actor
                -- pointer as readiness.
                attackerReadyRetryMs = 250,
                attackerReadyMaxAttempts = 32,
                saveWrites = false,
            },
            -- The QA spawner uses only these two species at this exact
            -- staging point.  Keeping the filter explicit prevents the
            -- attendance route from converting unrelated wild Pals around
            -- Small Settlement into temporary attackers during live tests.
            qaCandidateBlueprints = {
                "BP_NegativeKoala_C",
                "BP_MysteryMask_C",
            },
            qaSpawnAnchor = {
                X = -346100.0,
                Y = 191750.0,
                Z = -100.0,
            },
            qaSpawnRadius = 5000.0,
            targetPlayerHate = 125000.0,
            -- The event is a siege, not merely another player ambush. Keep
            -- human residents above the player in the hate ordering so the
            -- spawned wave visibly attacks the town while the player can
            -- still draw aggro by intervening.
            targetResidentHate = 175000.0,
            backgroundResolveWhenAbsent = true,
            noActorSpawnWhenAbsent = true,
            maxHistory = 32,
            retargetDelaysMs = {
                1000,
                5000,
                15000,
                30000,
                60000,
            },
        },
        -- Automatic town attacks always give the player a full fifteen-minute
        -- warning. The console-only self-test path can shorten this wait
        -- without changing the production rule.
        countdownSeconds = 15 * 60,
        spawnIntervalMs = 1300,
        spawnRadius = 6500.0,
        spawnHeightOffset = 120.0,
        targetHate = 100000.0,
        cleanupDelayMs = 15 * 60 * 1000,
        retargetDelaysMs = { 3000, 12000, 30000, 60000, 120000 },
        defaultApproachDirection = {
            X = -1.0,
            Y = 0.75,
        },
        settlement = {
            id = "pwft.settlement.small_settlement",
            displayNameZhHans = "小型聚落",
            nativeRegionNameId = "Grass_Village_001",
            fastTravelPointId = "FTPoint24",
            islandId = "pwft.island.central_southeast_archipelago",
            location = {
                X = -346617.56,
                Y = 191706.6,
                -- Runtime placement uses the entering player's proven ground
                -- height; this value is only the two-dimensional town centre.
                Z = 0.0,
            },
            triggerRadius = 22000.0,
            residentRadius = 18000.0,
        },
    },

    enableSaveWrites = false,
}
