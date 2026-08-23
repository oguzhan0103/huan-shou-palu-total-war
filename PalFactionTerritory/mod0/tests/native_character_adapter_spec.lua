package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local NativeCharacterAdapter =
    require("pwft.native_character_adapter")

local function valid_object(full_name)
    local object = {
        fullName = full_name,
        destroyed = false,
    }
    function object:IsValid()
        return not self.destroyed
    end
    function object:GetFullName()
        return self.fullName
    end
    function object:K2_DestroyActor()
        self.destroyed = true
    end
    function object:K2_GetActorLocation()
        return self.location
    end
    return object
end

local world = valid_object("PalPlayerController TestWorld")
local math_library =
    valid_object("KismetMathLibrary Default")
function math_library:MakeTransform(location, rotation, scale)
    return {
        location = location,
        rotation = rotation,
        scale = scale,
    }
end
local string_library =
    valid_object("KismetStringLibrary Default")
function string_library:Conv_StringToName(value)
    return "FName:" .. value
end
local merchant_class = valid_object(
    "BlueprintGeneratedClass BP_NPC_Male_Trader01_v04_C"
)
local guard_class = valid_object(
    "BlueprintGeneratedClass BP_NPC_Believer_C"
)
local guard_controller_class = valid_object(
    "BlueprintGeneratedClass BP_NPCAIController_Visitor_Guardman_C"
)
local guard_controller_path =
    "/Game/Pal/Blueprint/Controller/NPC/"
        .. "BP_NPCAIController_Visitor_Guardman."
        .. "BP_NPCAIController_Visitor_Guardman_C"
local salesperson_action_class = valid_object(
    "BlueprintGeneratedClass BP_AIAction_NPC_Relax_SalesPerson_C"
)
local salesperson_action_path =
    "/Game/Pal/Blueprint/Controller/AIAction/NPC/Relax/"
        .. "BP_AIAction_NPC_Relax_SalesPerson."
        .. "BP_AIAction_NPC_Relax_SalesPerson_C"
local class_by_path = {
    ["/Game/Pal/Blueprint/Character/NPC/Normal/BP_NPC_Male_Trader01_v04.BP_NPC_Male_Trader01_v04_C"] =
        merchant_class,
    ["/Game/Pal/Blueprint/Character/NPC/Normal/BP_NPC_Believer.BP_NPC_Believer_C"] =
        guard_class,
    [guard_controller_path] = guard_controller_class,
    [salesperson_action_path] = salesperson_action_class,
}

local begin_count = 0
local gameplay = valid_object("GameplayStatics Default")
function gameplay:BeginDeferredActorSpawnFromClass(
    _,
    character_class,
    transform
)
    begin_count = begin_count + 1
    local actor = valid_object(character_class.fullName)
    actor.spawnTransform = transform
    actor.location = {
        X = transform.location.X,
        Y = transform.location.Y,
        Z = transform.location.Z,
    }
    if character_class == merchant_class then
        local controller = valid_object("BP_NPCAIController_C Test")
        function controller:OverrideDefaultAction(action_class)
            self.overriddenActionClass = action_class
        end
        function controller:StartDefaultAIAction()
            self.defaultActionStartCount =
                (self.defaultActionStartCount or 0) + 1
        end
        function controller:SetAutoDefaultAIAction()
            self.autoDefaultActionCount =
                (self.autoDefaultActionCount or 0) + 1
        end
        actor.controller = controller
        function actor:GetController()
            return self.controller
        end
        local vendor = valid_object(
            "BP_PalShopVenderDataComponent Test"
        )
        vendor.itemShopSimpleLotteryTableName = {
            Key = "before",
        }
        vendor.palShopSimpleLotteryTableName = {
            Key = "before",
        }
        vendor.setupCount = 0
        function vendor:SetupShopData()
            self.setupCount = self.setupCount + 1
        end
        actor.BP_PalShopVenderDataComponent = vendor
        local interaction = valid_object(
            "BP_NPCInteractionComponent Test"
        )
        interaction.bDisableTalk = true
        interaction.bDisableTalkWhenCaptured = true
        function interaction:Initialize()
            self.initializeCount =
                (self.initializeCount or 0) + 1
        end
        function interaction:OnRep_DisableTalk()
            self.replicationCount =
                (self.replicationCount or 0) + 1
        end
        actor.BP_NPCInteractionComponent = interaction
        actor.BP_InteractableSphere = valid_object(
            "BP_InteractableSphere Test"
        )
        function actor:SetupInteraction()
            self.setupInteractionCount =
                (self.setupInteractionCount or 0) + 1
            self.BP_InteractableSphere.indicatorBound = true
        end
        function actor:SetActive_Interact_ToAll(active)
            self.setActiveInteractCount =
                (self.setActiveInteractCount or 0) + 1
            self.interactActive = active
        end
    elseif character_class == guard_class then
        local controller = valid_object(
            "BP_NPCAIController_Visitor_Guardman_C Test"
        )
        local hate_system = valid_object("PalHate GuardTest")
        function hate_system:FindMostHateTarget()
            return self.target
        end
        function controller:GetHateSystem()
            return hate_system
        end
        function controller:SetInitialValue(is_squad, not_sleep)
            self.initialValueCount =
                (self.initialValueCount or 0) + 1
            self.isSquad = is_squad
            self.notSleep = not_sleep
        end
        function controller:SetActiveAI(active)
            self.activeAICount =
                (self.activeAICount or 0) + 1
            self.activeAI = active
        end
        function controller:MoveToActor(
            goal,
            acceptance_radius,
            stop_on_overlap,
            use_pathfinding,
            can_strafe,
            filter_class,
            allow_partial_path
        )
            self.moveCount = (self.moveCount or 0) + 1
            self.lastMove = {
                goal = goal,
                acceptanceRadius = acceptance_radius,
                stopOnOverlap = stop_on_overlap,
                usePathfinding = use_pathfinding,
                canStrafe = can_strafe,
                filterClass = filter_class,
                allowPartialPath = allow_partial_path,
            }
            return 1
        end
        actor.controller = controller
        actor.hateSystem = hate_system
        function actor:GetController()
            return self.controller
        end
        local parameters = valid_object(
            "PalCharacterParameterComponent GuardTest"
        )
        parameters.dead = false
        function parameters:IsDead()
            return self.dead
        end
        actor.characterParameters = parameters
        function actor:GetCharacterParameterComponent()
            return self.characterParameters
        end
    end
    return actor
end
function gameplay:FinishSpawningActor(actor, transform)
    actor.finishedTransform = transform
    return actor
end

local static_objects = {
    ["/Script/Engine.Default__KismetMathLibrary"] =
        math_library,
    ["/Script/Engine.Default__GameplayStatics"] = gameplay,
}
for path, object in pairs(class_by_path) do
    static_objects[path] = object
end

local adapter_logs = {}
local delayed_callbacks = {}
local adapter = NativeCharacterAdapter.create({
    staticFindObject = function(path)
        return static_objects[path]
    end,
    loadAsset = function()
        return true
    end,
    fName = function(value)
        return "FName:" .. value
    end,
    worldContextProvider = function()
        return world
    end,
    restockMinutes = 45,
    merchantDefaultActionClassPath = salesperson_action_path,
    guardControllerClassPath = guard_controller_path,
    guardFollowIntervalMs = 750,
    guardAcceptanceRadius = 325,
    guardFollowMaxFailures = 3,
    executeWithDelay = function(delay_ms, callback)
        table.insert(delayed_callbacks, {
            delayMs = delay_ms,
            callback = callback,
        })
    end,
    executeInGameThread = function(callback)
        callback()
    end,
    logger = function(message)
        table.insert(adapter_logs, message)
    end,
})

local merchant = adapter:spawn_merchant({
    runtimeId = "fixed:merchant-test",
    mode = "fixed-market",
    characterId = "NPC_Male_Trader01_v04",
    characterClassPath =
        "/Game/Pal/Blueprint/Character/NPC/Normal/BP_NPC_Male_Trader01_v04.BP_NPC_Male_Trader01_v04_C",
    salesChannel = "ItemShop",
    shopRowName = "CaravanShop4",
    location = { X = 10, Y = 20, Z = 30 },
    rotation = { Pitch = 0, Yaw = 90, Roll = 0 },
})
assert(merchant:IsValid())
local vendor = merchant.BP_PalShopVenderDataComponent
assert(vendor.itemShopLotteryType == 1)
assert(
    vendor.itemShopSimpleLotteryTableName.Key
        == "FName:CaravanShop4"
)
assert(vendor.ItemShopRestockMinute == 45)
assert(vendor.setupCount == 1)
assert(merchant.spawnTransform.location.X == 10)
assert(merchant.spawnTransform.rotation.Yaw == 90)
assert(merchant.controller.DefaultActionClass == salesperson_action_class)
assert(
    merchant.controller.overriddenActionClass
        == salesperson_action_class
)
assert(merchant.controller.defaultActionStartCount == 1)
assert(merchant.controller.autoDefaultActionCount == 1)
local interaction = merchant.BP_NPCInteractionComponent
assert(interaction.bDisableTalk == false)
assert(interaction.bDisableTalkWhenCaptured == false)
assert(interaction.initializeCount == 1)
assert(interaction.replicationCount == 1)
assert(merchant.setupInteractionCount == 1)
assert(merchant.BP_InteractableSphere.indicatorBound == true)
assert(merchant.setActiveInteractCount == 1)
assert(merchant.interactActive == true)

-- Build-24575825 dynamic economy route: mutate only audited products in the
-- transient PalItemShop. Sell lines receive exact price/stock; products that
-- became procurement requests remain visible as sold out so the native Sell
-- tab and confirmed replication bridge can accept them from the player.
local function dynamic_product(item_id, initial_price, initial_stock)
    local giver = valid_object(
        "PalShopProductGiver_StaticItem " .. item_id
    )
    giver.ProductStaticItemID = "FName:" .. item_id
    giver.OverridePrice = initial_price
    giver.StockNum = initial_stock
    giver.MaxStockNum = initial_stock
    giver.bIsInfinityStockFlag = true
    giver.ProductCreateData = {
        ItemShopCreateData = {
            OverridePrice = initial_price,
            Stock = initial_stock,
        },
    }
    function giver:OnRep_StockNum()
        self.stockRepCount = (self.stockRepCount or 0) + 1
    end
    function giver:OnRep_MaxStockNum()
        self.maxStockRepCount =
            (self.maxStockRepCount or 0) + 1
    end
    local product = valid_object("PalShopProductBase " .. item_id)
    product.MyProductGiver = giver
    function product:OnUpdateProductStock(stock)
        self.updatedStock = stock
    end
    function product:OnUpdateProductMaxStock(stock)
        self.updatedMaxStock = stock
    end
    return product, giver
end

local copper_product, copper_giver =
    dynamic_product("CopperIngot", 240, 66)
local iron_product, iron_giver =
    dynamic_product("IronIngot", 720, 12)
local unrelated_product, unrelated_giver =
    dynamic_product("PalSphere", 120, 99)
local dynamic_shop = valid_object("PalItemShop DynamicTest")
dynamic_shop.ProductArray = {
    copper_product,
    iron_product,
    unrelated_product,
}
function dynamic_shop.ProductArray:GetArrayNum()
    return 3
end
function dynamic_shop:OnRep_ProductArray()
    self.productArrayRepCount =
        (self.productArrayRepCount or 0) + 1
end
vendor.MyItemShop = dynamic_shop
local dynamic_ok, dynamic_reason, dynamic_detail =
    adapter:apply_dynamic_item_shop_market(merchant, {
        factionId = "pwft.faction.rayne_syndicate",
        salesChannel = "ItemShop",
        dynamicMarketEnabled = true,
        resourceLedgerRevision = 2,
        marketUniverseItemIds = {
            "CopperIngot",
            "IronIngot",
        },
        products = {
            { itemId = "CopperIngot", price = 280, stock = 25 },
        },
        requested = {
            { itemId = "IronIngot", targetPrice = 860, quota = 20 },
        },
    })
assert(dynamic_ok, dynamic_reason)
assert(dynamic_reason == "dynamic-item-shop-applied")
assert(dynamic_detail.inspectedCount == 3)
assert(dynamic_detail.matchedCount == 2)
assert(dynamic_detail.changedCount == 2)
assert(dynamic_detail.sellLineCount == 1)
assert(dynamic_detail.procurementSoldOutLineCount == 1)
assert(copper_giver.OverridePrice == 280)
assert(copper_giver.StockNum == 25)
assert(copper_giver.MaxStockNum == 25)
assert(copper_giver.bIsInfinityStockFlag == false)
assert(copper_giver.ProductCreateData.ItemShopCreateData.OverridePrice == 280)
assert(copper_giver.ProductCreateData.ItemShopCreateData.Stock == 25)
assert(copper_product.updatedStock == 25)
assert(copper_product.updatedMaxStock == 25)
assert(iron_giver.OverridePrice == 860)
assert(iron_giver.StockNum == 0 and iron_giver.MaxStockNum == 0)
assert(iron_product.updatedStock == 0)
assert(unrelated_giver.OverridePrice == 120)
assert(unrelated_giver.StockNum == 99)
assert(dynamic_shop.productArrayRepCount == 1)
assert(adapter.capabilities.itemShopDynamicProductMutationRoute)

-- Re-entry must reactivate the route without rebinding the Blueprint
-- OnTriggerInteract delegate or reinitialising the interaction component.
local interaction_reentry_ok, interaction_reentry_error =
    adapter:_initialize_merchant_interaction(merchant)
assert(interaction_reentry_ok, interaction_reentry_error)
assert(interaction.initializeCount == 1)
assert(interaction.replicationCount == 1)
assert(merchant.setupInteractionCount == 1)
assert(merchant.setActiveInteractCount == 2)
assert(merchant.interactActive == true)
local initial_route_logged = false
local reentry_route_logged = false
for _, message in ipairs(adapter_logs) do
    if string.find(
        message,
        "MERCHANT_INTERACTION_ROUTE_READY",
        1,
        true
    ) and string.find(message, "setup=true", 1, true)
        and string.find(message, "active=true", 1, true) then
        if string.find(message, "alreadyBound=false", 1, true) then
            initial_route_logged = true
        elseif string.find(message, "alreadyBound=true", 1, true) then
            reentry_route_logged = true
        end
    end
end
assert(initial_route_logged)
assert(reentry_route_logged)

local guard = adapter:spawn_guard({
    runtimeId = "caravan-guard:test:1",
    mode = "visiting-caravan-guard",
    characterId = "NPC_Believer",
    characterClassPath =
        "/Game/Pal/Blueprint/Character/NPC/Normal/BP_NPC_Believer.BP_NPC_Believer_C",
    location = { X = -10, Y = -20, Z = 0 },
    rotation = { Pitch = 0, Yaw = 0, Roll = 0 },
})
assert(guard:IsValid())
assert(begin_count == 2)
assert(adapter:status().activeCount == 2)
assert(adapter:status().merchantSpawnCount == 1)
assert(adapter:status().guardSpawnCount == 1)

local duplicate_ok = pcall(function()
    adapter:spawn_guard({
        runtimeId = "caravan-guard:test:1",
        characterId = "NPC_Believer",
        characterClassPath =
            "/Game/Pal/Blueprint/Character/NPC/Normal/BP_NPC_Believer.BP_NPC_Believer_C",
        location = { X = 0, Y = 0, Z = 0 },
    })
end)
assert(not duplicate_ok)

local removed = adapter:despawn(
    guard,
    "test-complete"
)
assert(removed.ok)
assert(not guard:IsValid())
assert(adapter:status().activeCount == 1)
assert(adapter:status().despawnCount == 1)
assert(adapter:status().saveWrites == 0)

local provider = adapter:create_guard_provider(
    "NPC_Believer",
    "/Game/Pal/Blueprint/Character/NPC/Normal/BP_NPC_Believer.BP_NPC_Believer_C"
)
local local_player = valid_object("BP_Player_Female_C LocalPlayer")
local_player.location = { X = 100, Y = 200, Z = 5 }
local guard_terminated_count = 0
local guard_terminated_detail = nil
local provider_handle = provider.deploy(
    "pwft.faction.free_pal_alliance",
    "leader-guard-001",
    {
        location = { X = 100, Y = 200, Z = 5 },
        rotation = { Pitch = 0, Yaw = 180, Roll = 0 },
        followTarget = local_player,
        onTerminated = function(detail)
            guard_terminated_count = guard_terminated_count + 1
            guard_terminated_detail = detail
        end,
    }
)
assert(provider_handle.actor:IsValid())
assert(
    provider_handle.followBehaviourStatus
        == "native-visitor-leader-follow-active-live-combat-validation-pending"
)
local provider_controller = provider_handle.actor.controller
assert(provider_controller.VisitorLeader == local_player)
assert(provider_controller.initialValueCount == 1)
assert(provider_controller.isSquad == false)
assert(provider_controller.notSleep == true)
assert(provider_controller.activeAI == true)
assert(provider_controller.moveCount == 1)
assert(provider_controller.lastMove.goal == local_player)
assert(provider_controller.lastMove.acceptanceRadius == 325)
assert(#delayed_callbacks == 1)
assert(delayed_callbacks[1].delayMs == 750)

-- Each pulse follows while idle, preserves the NPC's native combat target,
-- then resumes following after combat.  The next callback is lifecycle scoped
-- and stops permanently once the actor is dead.
local function run_next_guard_pulse()
    local scheduled = table.remove(delayed_callbacks, 1)
    assert(scheduled ~= nil)
    scheduled.callback()
end

run_next_guard_pulse()
assert(provider_controller.moveCount == 2)
provider_handle.actor.location = { X = 250, Y = 200, Z = 5 }
local_player.location = { X = 500, Y = 200, Z = 5 }
local hostile = valid_object("BP_NPC_Hostile_C Test")
local hostile_parameters = valid_object(
    "PalCharacterParameterComponent HostileTest"
)
hostile_parameters.dead = false
function hostile_parameters:IsDead()
    return self.dead
end
hostile.CharacterParameterComponent = hostile_parameters
function hostile:GetCharacterParameterComponent()
    error("real Pal raid actors expose the reflected property")
end
provider_handle.actor.hateSystem.target = hostile
run_next_guard_pulse()
assert(provider_controller.moveCount == 2)
-- The native hate system may select the local player's summoned Pal after
-- the hostile target dies.  That actor is an ally, not ongoing combat.
local owned_pal = valid_object("BP_PlayerOwnedPal_C Test")
owned_pal.StaticCharacterParameterComponent = valid_object(
    "PalStaticCharacterParameterComponent OwnedPalTest"
)
owned_pal.StaticCharacterParameterComponent.IsPal = true
owned_pal.CharacterParameterComponent = valid_object(
    "PalCharacterParameterComponent OwnedPalTest"
)
function owned_pal.CharacterParameterComponent:IsPlayersOtomo()
    return true
end
provider_handle.actor.hateSystem.target = owned_pal
run_next_guard_pulse()
assert(provider_controller.moveCount == 3)
-- The engine keeps the dead actor as FindMostHateTarget until cleanup.  The
-- follower must ignore that stale reference and immediately resume.
provider_handle.actor.hateSystem.target = hostile
hostile_parameters.dead = true
local observed, observed_reason = adapter:observe_character_death(hostile)
assert(observed == true)
assert(observed_reason == "authoritative-death-recorded")
run_next_guard_pulse()
assert(provider_controller.moveCount == 4)
provider_handle.actor.characterParameters.dead = true
run_next_guard_pulse()
assert(#delayed_callbacks == 0)
assert(adapter.records[provider_handle.runtimeId] == nil)
assert(guard_terminated_count == 1)
assert(guard_terminated_detail.reason == "guard-downed")
-- Palworld may remove a dead body before the player requests recall.  The
-- adapter must still clear its runtime record so that faction can redeploy.
provider_handle.actor:K2_DestroyActor()
assert(provider.recall(provider_handle, "test-recall"))
assert(not provider_handle.actor:IsValid())
assert(adapter.records[provider_handle.runtimeId] == nil)
local follow_ready_logged = false
local combat_preserved_logged = false
local downed_logged = false
local runtime_released_logged = false
local pulse_logged = false
local movement_logged = false
local resumed_logged = false
local friendly_target_ignored_logged = false
for _, message in ipairs(adapter_logs) do
    follow_ready_logged = follow_ready_logged
        or string.find(
            message,
            "PLAYER_GUARD_FOLLOW_READY",
            1,
            true
        ) ~= nil
    combat_preserved_logged = combat_preserved_logged
        or string.find(
            message,
            "PLAYER_GUARD_COMBAT_PRESERVED",
            1,
            true
        ) ~= nil
    downed_logged = downed_logged
        or string.find(
            message,
            "PLAYER_GUARD_DOWNED",
            1,
            true
        ) ~= nil
    runtime_released_logged = runtime_released_logged
        or string.find(
            message,
            "PLAYER_GUARD_RUNTIME_RELEASED",
            1,
            true
        ) ~= nil
    pulse_logged = pulse_logged
        or string.find(
            message,
            "PLAYER_GUARD_FOLLOW_PULSE",
            1,
            true
        ) ~= nil
    movement_logged = movement_logged
        or string.find(
            message,
            "PLAYER_GUARD_FOLLOW_MOVEMENT_CONFIRMED",
            1,
            true
        ) ~= nil
    resumed_logged = resumed_logged
        or (string.find(
            message,
            "PLAYER_GUARD_FOLLOW_READY",
            1,
            true
        ) ~= nil and string.find(
            message,
            "resumedAfterCombat=true",
            1,
            true
        ) ~= nil)
    friendly_target_ignored_logged = friendly_target_ignored_logged
        or (string.find(
            message,
            "PLAYER_GUARD_FRIENDLY_TARGET_IGNORED",
            1,
            true
        ) ~= nil and string.find(
            message,
            "reason=player-owned-pal",
            1,
            true
        ) ~= nil)
end
assert(follow_ready_logged)
assert(combat_preserved_logged)
assert(downed_logged)
assert(runtime_released_logged)
assert(pulse_logged)
assert(movement_logged)
assert(resumed_logged)
assert(friendly_target_ignored_logged)

-- UE4SS can return another Lua wrapper for the same native actor.  Recall
-- must cancel the authoritative runtime record, not depend on actor-wrapper
-- identity; an already queued follow callback must become inert.
local wrapper_handle = provider.deploy(
    "pwft.faction.free_pal_alliance",
    "leader-guard-002",
    {
        location = { X = 100, Y = 200, Z = 5 },
        rotation = { Pitch = 0, Yaw = 180, Roll = 0 },
        followTarget = local_player,
    }
)
local wrapper_record = adapter.records[wrapper_handle.runtimeId]
local wrapper_controller = wrapper_record.controller
local wrapper_move_count = wrapper_controller.moveCount
assert(#delayed_callbacks == 1)
wrapper_handle.actor = valid_object("BP_NPC_Believer_C WrapperAlias")
assert(provider.recall(wrapper_handle, "wrapper-recall"))
assert(adapter.records[wrapper_handle.runtimeId] == nil)
run_next_guard_pulse()
assert(wrapper_controller.moveCount == wrapper_move_count)
assert(#delayed_callbacks == 0)

local generated_blueprint = valid_object("Blueprint BP_NPC_Male_Trader01_v04")
generated_blueprint.GeneratedClass = merchant_class
local loaded_paths = {}
local generated_class_adapter = NativeCharacterAdapter.create({
    staticFindObject = function(path)
        return static_objects[path]
            and (path == "/Script/Engine.Default__KismetMathLibrary"
                or path == "/Script/Engine.Default__GameplayStatics"
                or path == salesperson_action_path)
            and static_objects[path]
            or nil
    end,
    loadAsset = function(path)
        table.insert(loaded_paths, path)
        if path == "/Game/Pal/Blueprint/Character/NPC/Normal/"
                .. "BP_NPC_Male_Trader01_v04."
                .. "BP_NPC_Male_Trader01_v04" then
            return generated_blueprint
        end
        return nil
    end,
    fName = function(value)
        return "FName:" .. value
    end,
    worldContextProvider = function()
        return world
    end,
    merchantDefaultActionClassPath = salesperson_action_path,
})
local generated_class_merchant = generated_class_adapter:spawn_merchant({
    runtimeId = "fixed:generated-class-merchant-test",
    mode = "fixed-market",
    characterId = "NPC_Male_Trader01_v04",
    characterClassPath =
        "/Game/Pal/Blueprint/Character/NPC/Normal/BP_NPC_Male_Trader01_v04.BP_NPC_Male_Trader01_v04_C",
    salesChannel = "ItemShop",
    shopRowName = "CaravanShop4",
    location = { X = 0, Y = 0, Z = 0 },
    rotation = { Pitch = 0, Yaw = 0, Roll = 0 },
})
assert(generated_class_merchant:IsValid())
assert(#loaded_paths == 1)

-- The asynchronous native NPC path must enter through
-- APalNPCSpawnerBase::SpawnRequest_ByOutside.  A direct Spawn() helper does
-- not create the individual handle that merchant interaction depends on.
local spawner_class_path =
    "/Game/Pal/Blueprint/Spawner/BP_MonoNPCSpawner."
        .. "BP_MonoNPCSpawner_C"
local controller_class_path =
    "/Game/Pal/Blueprint/Controller/NPC/BP_NPCAIController."
        .. "BP_NPCAIController_C"
local spawner_class = valid_object(
    "BlueprintGeneratedClass BP_MonoNPCSpawner_C"
)
local controller_class = valid_object(
    "BlueprintGeneratedClass BP_NPCAIController_C"
)
local delayed_callbacks = {}
local last_spawner = nil
local async_gameplay = valid_object("GameplayStatics Async Default")
function async_gameplay:BeginDeferredActorSpawnFromClass(
    _,
    character_class,
    transform
)
    assert(character_class == spawner_class)
    local spawner = valid_object(character_class.fullName)
    spawner.spawnTransform = transform
    spawner.Spawned = false
    spawner.IsLoading = false
    spawner.SpawnedHandle = nil
    spawner.compatibilitySpawnCount = 0
    local function complete_native_spawn(target)
        local actor = gameplay:BeginDeferredActorSpawnFromClass(
            world,
            merchant_class,
            transform
        )
        local handle = valid_object(
            "PalIndividualCharacterHandle Test"
        )
        function handle:TryGetIndividualActor()
            return actor
        end
        target.SpawnedHandle = handle
        target.Spawned = true
    end
    function spawner:Spawn()
        self.compatibilitySpawnCount =
            self.compatibilitySpawnCount + 1
        complete_native_spawn(self)
    end
    function spawner:SpawnRequest_ByOutside(delete_alive)
        self.outsideRequestCount =
            (self.outsideRequestCount or 0) + 1
        self.deleteAlive = delete_alive
        complete_native_spawn(self)
    end
    last_spawner = spawner
    return spawner
end
function async_gameplay:FinishSpawningActor(actor, transform)
    actor.finishedTransform = transform
    return actor
end

local async_static_objects = {
    ["/Script/Engine.Default__KismetMathLibrary"] =
        math_library,
    ["/Script/Engine.Default__GameplayStatics"] =
        async_gameplay,
    [spawner_class_path] = spawner_class,
    [controller_class_path] = controller_class,
    [salesperson_action_path] = salesperson_action_class,
    ["/Script/Engine.Default__KismetStringLibrary"] =
        string_library,
}
local ready_actor = nil
local async_adapter = NativeCharacterAdapter.create({
    staticFindObject = function(path)
        return async_static_objects[path]
    end,
    loadAsset = function()
        return nil
    end,
    -- Build 24467282 may not expose the global FName constructor.  The
    -- adapter must fall back to KismetStringLibrary.Conv_StringToName.
    fName = false,
    worldContextProvider = function()
        return world
    end,
    merchantSpawnerClassPath = spawner_class_path,
    controllerClassPath = controller_class_path,
    merchantDefaultActionClassPath = salesperson_action_path,
    asyncMerchantSpawnerEnabled = true,
    nativeSetupMaxAttempts = 5,
    executeWithDelay = function(_, callback)
        table.insert(delayed_callbacks, callback)
    end,
    executeInGameThread = function(callback)
        callback()
    end,
})
local pending = async_adapter:spawn_merchant_async({
    runtimeId = "async:merchant-test",
    mode = "fixed-market",
    characterId = "NPC_Male_Trader01_v04",
    uniqueNpcId = "None",
    characterClassPath =
        "/Game/Pal/Blueprint/Character/NPC/Normal/"
            .. "BP_NPC_Male_Trader01_v04."
            .. "BP_NPC_Male_Trader01_v04_C",
    salesChannel = "ItemShop",
    shopRowName = "PFT_Economy_Test",
    location = { X = 10, Y = 20, Z = 30 },
    rotation = { Pitch = 0, Yaw = 90, Roll = 0 },
}, {
    onReady = function(actor)
        ready_actor = actor
    end,
})
while #delayed_callbacks > 0 do
    local callback = table.remove(delayed_callbacks, 1)
    callback()
end
assert(pending.ready == true)
assert(#pending.gameThreadCallbacks >= 1)
assert(pending.spawnRequestRoute ==
    "SpawnRequest_ByOutside(true)")
assert(last_spawner.outsideRequestCount == 1)
assert(last_spawner.deleteAlive == true)
assert(last_spawner.compatibilitySpawnCount == 0)
assert(ready_actor ~= nil and ready_actor:IsValid())
assert(
    ready_actor.BP_PalShopVenderDataComponent
        .itemShopSimpleLotteryTableName.Key
        == "FName:PFT_Economy_Test"
)
local removed_async = async_adapter:despawn(
    pending,
    "async-native-reentry-test"
)
assert(removed_async.ok)
assert(async_adapter:status().activeCount == 0)
local reentered = async_adapter:spawn_merchant_async({
    runtimeId = "async:merchant-test",
    mode = "fixed-market",
    characterId = "NPC_Male_Trader01_v04",
    uniqueNpcId = "None",
    characterClassPath =
        "/Game/Pal/Blueprint/Character/NPC/Normal/"
            .. "BP_NPC_Male_Trader01_v04."
            .. "BP_NPC_Male_Trader01_v04_C",
    salesChannel = "ItemShop",
    shopRowName = "PFT_Economy_Test",
    location = { X = 10, Y = 20, Z = 30 },
    rotation = { Pitch = 0, Yaw = 90, Roll = 0 },
}, {})
while #delayed_callbacks > 0 do
    local callback = table.remove(delayed_callbacks, 1)
    callback()
end
assert(reentered.ready == true)
assert(async_adapter:status().activeCount == 1)
assert(async_adapter:despawn(reentered, "boss-route-test").ok)

local boss_route = async_adapter:spawn_merchant_async({
    runtimeId = "async:boss-dark-trader-test",
    mode = "fixed-market",
    characterId = "NPC_Male_Trader01_v04",
    uniqueNpcId = "None",
    characterClassPath =
        "/Game/Pal/Blueprint/Character/NPC/Normal/"
            .. "BP_NPC_Male_Trader01_v04."
            .. "BP_NPC_Male_Trader01_v04_C",
    salesChannel = "ItemShop",
    shopRowName = "PFT_Economy_Test",
    provenNativeSpawnerRoute = "BossDarkTrader",
    location = { X = 10, Y = 20, Z = 30 },
    rotation = { Pitch = 0, Yaw = 90, Roll = 0 },
}, {})
while #delayed_callbacks > 0 do
    local callback = table.remove(delayed_callbacks, 1)
    callback()
end
assert(boss_route.ready == true)
assert(boss_route.spawnRequestRoute ==
    "Spawn() proven BossDarkTrader route")
assert(last_spawner.compatibilitySpawnCount == 1)
assert(last_spawner.outsideRequestCount == nil)

print("PASS inactive native merchant and guard blueprint adapter")
