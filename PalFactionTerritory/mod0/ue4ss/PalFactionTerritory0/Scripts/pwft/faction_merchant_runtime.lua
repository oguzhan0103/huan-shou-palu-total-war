local FactionMerchantRuntime = {}

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

local function require_non_empty_string(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function validate_contract(contract)
    assert(type(contract) == "table", "commerce contract is required")
    assert(#contract.factions == 7, "merchant runtime expects seven human factions")
    assert(
        contract.designPolicy.fixedMarketCommercialTruceForHostileRecovery
            == true,
        "fixed market must remain available for hostile recovery"
    )
    assert(
        contract.designPolicy.visitingCaravansRequireNonHostileRelation
            == true,
        "hostile visiting caravans must remain disabled"
    )
    assert(
        #contract.merchantIsland.slotOffsets == 7,
        "merchant island requires seven placement slots"
    )
    local selection = contract.merchantIsland.selectionDecision
    assert(
        type(selection) == "table"
            and selection.referenceFastTravelPointId == "FTPoint90",
        "merchant island must remain anchored to the user-selected FTPoint90 island"
    )
    assert(
        selection.factionTerritoryPolicy
            == "neutral_commercial_public_zone",
        "fixed market island must remain a neutral commercial public zone"
    )
    assert(
        selection.publicFastTravelPolicy
            == "preserve_native_unrestricted",
        "fixed market fast travel must remain natively accessible"
    )
    for _, merchant in ipairs(contract.factions) do
        require_non_empty_string(merchant.factionId, "merchant faction ID")
        require_non_empty_string(merchant.nativeCharacterId, "native merchant character ID")
        require_non_empty_string(merchant.nativeCharacterClassPath, "native merchant class path")
        require_non_empty_string(merchant.nativeShopRowName, "native merchant shop row")
        assert(type(merchant.guardCharacterIds) == "table", "merchant guard roster is required")
        assert(
            type(merchant.guardCharacterClassPaths) == "table",
            "merchant guard class paths are required"
        )
        assert(
            #merchant.guardCharacterIds
                == #merchant.guardCharacterClassPaths,
            "merchant guard ID/class path count mismatch"
        )
    end
end

local function offset_location(root, rotation, offset)
    local yaw = math.rad((rotation and rotation.Yaw) or 0)
    local forward_x = math.cos(yaw)
    local forward_y = math.sin(yaw)
    local right_x = -forward_y
    local right_y = forward_x
    return {
        X = root.X
            + forward_x * (offset.forward or 0)
            + right_x * (offset.right or 0),
        Y = root.Y
            + forward_y * (offset.forward or 0)
            + right_y * (offset.right or 0),
        Z = root.Z + (offset.up or 0),
    }
end

function FactionMerchantRuntime.create(
    commerce_contract,
    faction_api,
    commerce_bridge,
    native_adapter
)
    validate_contract(commerce_contract)
    assert(type(faction_api) == "table", "faction API is required")
    assert(type(commerce_bridge) == "table", "commerce bridge is required")
    assert(
        native_adapter == nil or type(native_adapter) == "table",
        "native merchant adapter must be a table"
    )
    if native_adapter ~= nil then
        assert(type(native_adapter.spawn_merchant) == "function", "native adapter lacks merchant spawn")
        assert(type(native_adapter.spawn_guard) == "function", "native adapter lacks guard spawn")
        assert(type(native_adapter.despawn) == "function", "native adapter lacks despawn")
    end
    local merchants = {}
    for index, merchant in ipairs(commerce_contract.factions) do
        merchants[merchant.factionId] = {
            index = index,
            config = copy(merchant),
            fixedActor = nil,
            fixedOwned = false,
            fixedGuardActors = {},
            caravan = nil,
        }
    end
    return setmetatable({
        version = "1.0.0",
        contract = copy(commerce_contract),
        factionApi = faction_api,
        commerceBridge = commerce_bridge,
        adapter = native_adapter,
        merchants = merchants,
        fixedSpawnCount = 0,
        caravanDispatchCount = 0,
        guardSpawnCount = 0,
        recalledCaravanCount = 0,
        marketDeactivateCount = 0,
        activeCaravanEventIds = {},
        completedCaravanEventIds = {},
        capabilities = {
            fixedSevenFactionMarket = true,
            commercialTruceForHostileRecovery = true,
            visitingFactionCaravans = true,
            factionGuardRosters = true,
            nativeMerchantVariants = true,
            neutralPublicMarketIsland = true,
            existingMerchantBinding = true,
            relationDrivenCaravanRecall = true,
            idempotentCaravanEvents = true,
            marketDeactivation = true,
            PalworldSaveMutation = false,
        },
    }, { __index = FactionMerchantRuntime })
end

function FactionMerchantRuntime:bind_existing_fixed(
    faction_id,
    actor,
    metadata
)
    local record = self.merchants[
        require_non_empty_string(
            faction_id,
            "merchant faction ID"
        )
    ]
    if record == nil then
        return result(false, "unknown-commerce-faction")
    end
    if actor == nil then
        return result(false, "invalid-existing-merchant-actor")
    end
    if record.fixedActor ~= nil then
        return result(true, "fixed-merchant-already-bound", {
            factionId = faction_id,
            actor = record.fixedActor,
        })
    end
    metadata = metadata or {}
    self.commerceBridge:register_vendor_actor(
        faction_id,
        actor,
        {
            mode = "fixed-market",
            commercialTruce = true,
            existingRuntimeBinding =
                metadata.existingRuntimeBinding
                or record.config.existingRuntimeBinding,
        }
    )
    record.fixedActor = actor
    record.fixedOwned = false
    return result(true, "existing-fixed-merchant-bound", {
        factionId = faction_id,
        actor = actor,
    })
end

function FactionMerchantRuntime:unbind_existing_fixed(
    faction_id,
    actor,
    reason
)
    local record = self.merchants[
        require_non_empty_string(
            faction_id,
            "merchant faction ID"
        )
    ]
    if record == nil then
        return result(false, "unknown-commerce-faction")
    end
    if record.fixedActor == nil then
        return result(true, "no-existing-fixed-merchant")
    end
    if record.fixedOwned then
        return result(false, "fixed-merchant-owned-by-runtime")
    end
    if actor ~= nil and record.fixedActor ~= actor then
        return result(false, "existing-fixed-merchant-mismatch")
    end
    if type(
        self.commerceBridge.unregister_vendor_actor
    ) == "function" then
        self.commerceBridge:unregister_vendor_actor(
            record.fixedActor
        )
    end
    record.fixedActor = nil
    return result(true, "existing-fixed-merchant-unbound", {
        factionId = faction_id,
        reason = reason,
    })
end

function FactionMerchantRuntime:set_native_adapter(adapter)
    assert(type(adapter) == "table", "native merchant adapter is required")
    assert(type(adapter.spawn_merchant) == "function", "native adapter lacks merchant spawn")
    assert(type(adapter.spawn_guard) == "function", "native adapter lacks guard spawn")
    assert(type(adapter.despawn) == "function", "native adapter lacks despawn")
    self.adapter = adapter
    return result(true, "native-adapter-ready")
end

function FactionMerchantRuntime:fixed_plan(faction_id, root_location, root_rotation)
    local record = self.merchants[
        require_non_empty_string(faction_id, "merchant faction ID")
    ]
    if record == nil then
        return nil, "unknown-commerce-faction"
    end
    root_location = root_location or self.contract.merchantIsland.rootLocation
    root_rotation = root_rotation or self.contract.merchantIsland.rootRotation
    if type(root_location) ~= "table"
        or type(root_rotation) ~= "table" then
        return nil, "market-island-placement-pending"
    end
    local merchant = record.config
    return {
        runtimeId = "fixed:" .. merchant.merchantId,
        mode = "fixed-market",
        factionId = faction_id,
        merchantId = merchant.merchantId,
        characterId = merchant.nativeCharacterId,
        characterClassPath = merchant.nativeCharacterClassPath,
        shopRowName = merchant.nativeShopRowName,
        salesChannel = merchant.salesChannel,
        clothingColour = merchant.clothingColour,
        nativeAppearanceStatus = merchant.nativeAppearanceStatus,
        commercialTruce = true,
        location = offset_location(
            root_location,
            root_rotation,
            self.contract.merchantIsland.slotOffsets[record.index]
        ),
        rotation = copy(root_rotation),
    }
end

function FactionMerchantRuntime:activate_market(
    root_location,
    root_rotation
)
    if self.adapter == nil then
        return result(false, "native-merchant-adapter-pending")
    end
    local spawned = {}
    local skipped = {}
    for _, merchant in ipairs(self.contract.factions) do
        local record = self.merchants[merchant.factionId]
        if merchant.existingRuntimeBinding ~= nil then
            table.insert(skipped, {
                factionId = merchant.factionId,
                reason = "existing-runtime-binding:"
                    .. merchant.existingRuntimeBinding,
            })
        elseif record.fixedActor ~= nil then
            table.insert(skipped, {
                factionId = merchant.factionId,
                reason = "already-spawned",
            })
        else
            local plan, plan_error = self:fixed_plan(
                merchant.factionId,
                root_location,
                root_rotation
            )
            if plan == nil then
                return result(false, plan_error, {
                    spawned = spawned,
                    skipped = skipped,
                })
            end
            local ok, actor_or_error = pcall(
                self.adapter.spawn_merchant,
                self.adapter,
                plan
            )
            if ok and actor_or_error ~= nil then
                record.fixedActor = actor_or_error
                record.fixedOwned = true
                self.fixedSpawnCount = self.fixedSpawnCount + 1
                self.commerceBridge:register_vendor_actor(
                    merchant.factionId,
                    actor_or_error,
                    {
                        mode = "fixed-market",
                        commercialTruce = true,
                    }
                )
                table.insert(spawned, {
                    factionId = merchant.factionId,
                    actor = actor_or_error,
                })
            else
                table.insert(skipped, {
                    factionId = merchant.factionId,
                    reason = "native-spawn-failed:"
                        .. tostring(actor_or_error),
                })
            end
        end
    end
    return result(true, "market-activation-complete", {
        spawned = spawned,
        skipped = skipped,
    })
end

function FactionMerchantRuntime:deactivate_market(reason)
    local removed = {}
    local preserved = {}
    for faction_id, record in pairs(self.merchants) do
        if record.fixedActor ~= nil then
            if record.fixedOwned then
                if type(
                    self.commerceBridge
                        .unregister_vendor_actor
                ) == "function" then
                    self.commerceBridge
                        :unregister_vendor_actor(
                            record.fixedActor
                        )
                end
                pcall(
                    self.adapter.despawn,
                    self.adapter,
                    record.fixedActor,
                    reason
                )
                for _, actor in ipairs(
                    record.fixedGuardActors
                ) do
                    pcall(
                        self.adapter.despawn,
                        self.adapter,
                        actor,
                        reason
                    )
                end
                table.insert(removed, faction_id)
                record.fixedActor = nil
                record.fixedOwned = false
                record.fixedGuardActors = {}
            else
                table.insert(preserved, faction_id)
            end
        end
    end
    self.marketDeactivateCount =
        self.marketDeactivateCount + 1
    return result(true, "market-deactivated", {
        removedFactionIds = removed,
        preservedExternalFactionIds = preserved,
    })
end

function FactionMerchantRuntime:dispatch_caravan(
    faction_id,
    event_id,
    base_location,
    base_rotation
)
    require_non_empty_string(event_id, "caravan event ID")
    local record = self.merchants[
        require_non_empty_string(faction_id, "caravan faction ID")
    ]
    if record == nil then
        return result(false, "unknown-commerce-faction")
    end
    if self.adapter == nil then
        return result(false, "native-merchant-adapter-pending")
    end
    local faction = self.factionApi:faction_status(faction_id)
    if faction == nil or faction.kind ~= "Human" then
        return result(false, "unknown-human-faction")
    end
    if faction.relation == "Hostile" then
        return result(false, "hostile-faction-caravan-unavailable")
    end
    if record.caravan ~= nil then
        return result(false, "caravan-already-active")
    end
    local previous_faction =
        self.activeCaravanEventIds[event_id]
    if previous_faction ~= nil then
        return result(
            previous_faction == faction_id,
            previous_faction == faction_id
                and "caravan-event-already-active"
                or "caravan-event-id-conflict"
        )
    end
    if self.completedCaravanEventIds[event_id] ~= nil then
        return result(false, "caravan-event-already-completed")
    end
    assert(type(base_location) == "table", "caravan base location is required")
    base_rotation = base_rotation or { Pitch = 0, Yaw = 0, Roll = 0 }
    local merchant = record.config
    local plan = {
        runtimeId = "caravan:" .. event_id,
        mode = "visiting-caravan",
        eventId = event_id,
        factionId = faction_id,
        merchantId = merchant.merchantId,
        characterId = merchant.nativeCharacterId,
        characterClassPath = merchant.nativeCharacterClassPath,
        shopRowName = merchant.nativeShopRowName,
        salesChannel = merchant.salesChannel,
        clothingColour = merchant.clothingColour,
        commercialTruce = false,
        location = copy(base_location),
        rotation = copy(base_rotation),
    }
    local merchant_ok, actor_or_error = pcall(
        self.adapter.spawn_merchant,
        self.adapter,
        plan
    )
    if not merchant_ok or actor_or_error == nil then
        return result(false, "caravan-merchant-spawn-failed", {
            detail = tostring(actor_or_error),
        })
    end
    self.commerceBridge:register_vendor_actor(
        faction_id,
        actor_or_error,
        {
            mode = "visiting-caravan",
            commercialTruce = false,
        }
    )

    local guards = {}
    for index, character_id in ipairs(
        merchant.guardCharacterIds
    ) do
        local guard_plan = {
            runtimeId = string.format(
                "caravan-guard:%s:%d",
                event_id,
                index
            ),
            mode = "visiting-caravan-guard",
            eventId = event_id,
            factionId = faction_id,
            characterId = character_id,
            characterClassPath =
                merchant.guardCharacterClassPaths[index],
            location = offset_location(
                base_location,
                base_rotation,
                {
                    forward = -180,
                    right = index == 1 and -160 or 160,
                    up = 0,
                }
            ),
            rotation = copy(base_rotation),
        }
        local guard_ok, guard_actor = pcall(
            self.adapter.spawn_guard,
            self.adapter,
            guard_plan
        )
        if guard_ok and guard_actor ~= nil then
            table.insert(guards, guard_actor)
            self.guardSpawnCount = self.guardSpawnCount + 1
        end
    end
    record.caravan = {
        eventId = event_id,
        merchantActor = actor_or_error,
        guardActors = guards,
    }
    self.activeCaravanEventIds[event_id] = faction_id
    self.caravanDispatchCount = self.caravanDispatchCount + 1
    return result(true, "caravan-dispatched", {
        factionId = faction_id,
        eventId = event_id,
        merchantActor = actor_or_error,
        guardActors = guards,
    })
end

function FactionMerchantRuntime:recall_caravan(faction_id, reason)
    local record = self.merchants[
        require_non_empty_string(faction_id, "caravan faction ID")
    ]
    if record == nil then
        return result(false, "unknown-commerce-faction")
    end
    if record.caravan == nil then
        return result(true, "no-active-caravan")
    end
    local caravan = record.caravan
    if type(
        self.commerceBridge.unregister_vendor_actor
    ) == "function" then
        self.commerceBridge:unregister_vendor_actor(
            caravan.merchantActor
        )
    end
    pcall(
        self.adapter.despawn,
        self.adapter,
        caravan.merchantActor,
        reason
    )
    for _, actor in ipairs(caravan.guardActors) do
        pcall(
            self.adapter.despawn,
            self.adapter,
            actor,
            reason
        )
    end
    record.caravan = nil
    self.activeCaravanEventIds[caravan.eventId] = nil
    self.completedCaravanEventIds[
        caravan.eventId
    ] = faction_id
    self.recalledCaravanCount =
        self.recalledCaravanCount + 1
    return result(true, "caravan-recalled", {
        factionId = faction_id,
        eventId = caravan.eventId,
    })
end

function FactionMerchantRuntime:on_relation_changed(
    faction_id
)
    local record = self.merchants[
        require_non_empty_string(
            faction_id,
            "merchant faction ID"
        )
    ]
    if record == nil then
        return result(false, "unknown-commerce-faction")
    end
    local faction =
        self.factionApi:faction_status(faction_id)
    if faction == nil then
        return result(false, "unknown-human-faction")
    end
    if faction.relation == "Hostile"
        and record.caravan ~= nil then
        local recalled = self:recall_caravan(
            faction_id,
            "relation-became-hostile"
        )
        recalled.relation = faction.relation
        return recalled
    end
    return result(true, "merchant-relation-refreshed", {
        factionId = faction_id,
        relation = faction.relation,
        caravanActive = record.caravan ~= nil,
    })
end

function FactionMerchantRuntime:refresh_relations()
    local recalled = {}
    for _, faction_id in ipairs(
        self.contract.factions
    ) do
        local outcome = self:on_relation_changed(
            faction_id.factionId
        )
        if outcome.reason == "caravan-recalled" then
            table.insert(recalled, faction_id.factionId)
        end
    end
    return result(true, "merchant-relations-refreshed", {
        recalledFactionIds = recalled,
    })
end

function FactionMerchantRuntime:status()
    local fixed_active = 0
    local caravan_active = 0
    for _, record in pairs(self.merchants) do
        if record.fixedActor ~= nil then
            fixed_active = fixed_active + 1
        end
        if record.caravan ~= nil then
            caravan_active = caravan_active + 1
        end
    end
    return {
        version = self.version,
        adapterReady = self.adapter ~= nil,
        marketPlacementStatus =
            self.contract.merchantIsland.placementStatus,
        marketReferenceFastTravelPointId =
            self.contract.merchantIsland.selectionDecision
                .referenceFastTravelPointId,
        marketPublicFastTravelPolicy =
            self.contract.merchantIsland.selectionDecision
                .publicFastTravelPolicy,
        fixedActiveCount = fixed_active,
        fixedSpawnCount = self.fixedSpawnCount,
        caravanActiveCount = caravan_active,
        caravanDispatchCount = self.caravanDispatchCount,
        guardSpawnCount = self.guardSpawnCount,
        recalledCaravanCount =
            self.recalledCaravanCount,
        marketDeactivateCount =
            self.marketDeactivateCount,
    }
end

return FactionMerchantRuntime
