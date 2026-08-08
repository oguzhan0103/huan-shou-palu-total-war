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
local provider_handle = provider.deploy(
    "pwft.faction.free_pal_alliance",
    "leader-guard-001",
    {
        location = { X = 100, Y = 200, Z = 5 },
        rotation = { Pitch = 0, Yaw = 180, Roll = 0 },
        followTarget = "local-player",
    }
)
assert(provider_handle.actor:IsValid())
assert(
    provider_handle.followBehaviourStatus
        == "native-follow-controller-pending-live-validation"
)
assert(provider.recall(provider_handle, "test-recall"))
assert(not provider_handle.actor:IsValid())

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
