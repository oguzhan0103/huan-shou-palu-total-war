local Policy = {}

local VALID_RELATIONS = {
    Neutral = true,
    Friendly = true,
    Hostile = true,
    Player = true,
}

local VALID_MAP_MODES = {
    Original = true,
    Human = true,
    Pal = true,
}

local function require_relation(value)
    if not VALID_RELATIONS[value] then
        error("invalid relationship state: " .. tostring(value))
    end
    return value
end

local function require_map_mode(value)
    if not VALID_MAP_MODES[value] then
        error("invalid map mode: " .. tostring(value))
    end
    return value
end

function Policy.latest_relations(events)
    local latest = {}
    for _, event in ipairs(events or {}) do
        local faction_id = assert(event.factionId, "relation event is missing factionId")
        local revision = assert(event.revision, "relation event is missing revision")
        require_relation(event.state)
        if revision < 0 then
            error("relation revision must be non-negative")
        end
        local current = latest[faction_id]
        if current == nil or revision > current.revision then
            latest[faction_id] = {
                factionId = faction_id,
                state = event.state,
                revision = revision,
            }
        end
    end
    return latest
end

function Policy.resolve_relation(territory, relations, is_night)
    -- Island-based gameplay rules always use the Human ownership layer.
    -- Legacy 22-region records still expose ownerFactionId directly.
    local owner_faction_id = territory.ownerFactionId or territory.humanOwnerFactionId
    if owner_faction_id == nil then
        return "Neutral"
    end
    if territory.fixedRelationState ~= nil then
        return require_relation(territory.fixedRelationState)
    end
    if territory.dayRelationOverride ~= nil and not is_night then
        return require_relation(territory.dayRelationOverride)
    end
    local event = (relations or {})[owner_faction_id]
    if event == nil then
        return "Neutral"
    end
    return require_relation(event.state)
end

-- This is the one presentation model for all territory surfaces. The map
-- reads `color`, the native place-name card reads the same `color` and
-- `relation`, and other gameplay rules continue to derive from that relation.
function Policy.resolve_presentation(registry, territory, relations, is_night)
    assert(territory ~= nil, "territory presentation requires a territory")
    local faction = nil
    if territory.ownerFactionId ~= nil then
        faction = registry.factions[territory.ownerFactionId]
    end
    local relation = Policy.resolve_relation(territory, relations, is_night)
    return {
        territoryId = territory.id,
        nativeMaskAsset = territory.nativeMaskAsset,
        factionId = territory.ownerFactionId,
        factionNameZhHans = faction and faction.displayNameZhHans or territory.ownerDisplayNameZhHans,
        controllerNameZhHans = territory.controllerNameZhHans,
        relation = relation,
        color = registry.palette[relation],
    }
end

-- Human and Pal ownership share one coastline mask but are rendered as two
-- separate views.  A nil owner means that this island is completely
-- transparent in that view; it is not a blue "neutral" territory.
function Policy.resolve_island_presentation(registry, island, map_mode, relations, is_night)
    require_map_mode(map_mode)
    assert(island ~= nil, "island presentation requires an island")
    if map_mode == "Original" then
        return {
            islandId = island.id,
            visible = false,
            factionId = nil,
            factionNameZhHans = nil,
            relation = nil,
            color = registry.palette.Locked,
        }
    end
    local faction_id = nil
    if map_mode == "Human" then
        faction_id = island.humanOwnerFactionId
    else
        faction_id = island.palOwnerFactionId
    end
    if faction_id == nil then
        return {
            islandId = island.id,
            visible = false,
            factionId = nil,
            factionNameZhHans = nil,
            relation = nil,
            color = registry.palette.Locked,
        }
    end
    local surface = {
        id = island.id,
        ownerFactionId = faction_id,
        fixedRelationState = nil,
        dayRelationOverride = nil,
    }
    local relation = Policy.resolve_relation(surface, relations, is_night)
    return {
        islandId = island.id,
        visible = true,
        factionId = faction_id,
        factionNameZhHans = registry.factions[faction_id].displayNameZhHans,
        relation = relation,
        color = registry.palette[relation],
    }
end

function Policy.resolve_region_name_presentation(registry, native_region_name_id, relations, is_night)
    if native_region_name_id == nil then
        return nil
    end
    local island_id = registry.regionNameIdToIsland[native_region_name_id]
    if island_id == nil then
        return nil
    end
    local island = registry.islands[island_id]
    if island == nil then
        error("RegionNameID resolves to an unknown island: " .. tostring(island_id))
    end
    local presentation = Policy.resolve_island_presentation(
        registry,
        island,
        "Human",
        relations,
        is_night
    )
    if not presentation.visible then
        return nil
    end
    -- Keep territoryId as a compatibility alias for the native place-card and
    -- warning code while the internal source of truth is now islandId.
    presentation.territoryId = island_id
    return presentation
end

function Policy.resolve_overlay(registry, island, map_mode, native_unlocked, relations, is_night)
    require_map_mode(map_mode)
    if map_mode == "Original" then
        return {
            visible = false,
            preserveNativeFog = true,
            relation = nil,
            color = registry.palette.Locked,
        }
    end
    if not native_unlocked then
        return {
            visible = false,
            preserveNativeFog = true,
            relation = nil,
            color = registry.palette.Locked,
        }
    end
    local presentation = Policy.resolve_island_presentation(
        registry,
        island,
        map_mode,
        relations,
        is_night
    )
    if not presentation.visible then
        return {
            visible = false,
            preserveNativeFog = true,
            relation = nil,
            color = registry.palette.Locked,
        }
    end
    return {
        visible = true,
        preserveNativeFog = true,
        relation = presentation.relation,
        color = presentation.color,
    }
end

function Policy.can_use_public_fast_travel(territory, native_unlocked, relations, is_night)
    if not native_unlocked then
        return {
            allowed = false,
            reasonCode = "native_region_locked",
            relation = nil,
        }
    end
    local relation = Policy.resolve_relation(territory, relations, is_night)
    if relation == "Hostile" then
        return {
            allowed = false,
            reasonCode = "hostile_territory",
            relation = relation,
        }
    end
    return {
        allowed = true,
        reasonCode = "allowed",
        relation = relation,
    }
end

function Policy.map_info(registry, territory, relations, is_night)
    local presentation = Policy.resolve_presentation(registry, territory, relations, is_night)
    local faction = nil
    if territory.ownerFactionId ~= nil then
        faction = registry.factions[territory.ownerFactionId]
    end
    return {
        territoryId = presentation.territoryId,
        factionId = presentation.factionId,
        factionNameZhHans = faction and faction.displayNameZhHans or "中立区",
        controllerNameZhHans = presentation.controllerNameZhHans,
        relation = presentation.relation,
        color = presentation.color,
    }
end

return Policy
