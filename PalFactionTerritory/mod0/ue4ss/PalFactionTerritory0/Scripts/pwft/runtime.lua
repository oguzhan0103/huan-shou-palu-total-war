local Runtime = {}
local CompanionLedger = require("pwft.companion_ledger")
local CommerceBridge = require("pwft.commerce_bridge")
local ContentPackRegistry = require("pwft.content_pack_registry")
local ContentRuntime = require("pwft.content_runtime")
local ContentModuleLoader = require("pwft.content_module_loader")
local EndingRuntime = require("pwft.ending_runtime")
local FactionApi = require("pwft.faction_api")
local FactionCommerce = require("pwft.faction_commerce")
local FactionDefense = require("pwft.faction_defense")
local FactionEconomy = require("pwft.faction_economy")
local FactionEconomyShopCatalog =
    require("pwft.faction_economy_shop_catalog")
local FactionEconomyMerchantRuntime =
    require("pwft.faction_economy_merchant_runtime")
local FactionEconomyMerchantPresence =
    require("pwft.faction_economy_merchant_presence")
local FactionGuard = require("pwft.faction_guard")
local FactionJoin = require("pwft.faction_join")
local FactionJoinNativePresenter =
    require("pwft.faction_join_native_presenter")
local FactionJoinNativeRouter =
    require("pwft.faction_join_native_router")
local FactionMerchantRuntime = require("pwft.faction_merchant_runtime")
local FactionProgression = require("pwft.faction_progression")
local FactionUiModel = require("pwft.faction_ui_model")
local FactionUiPresenter = require("pwft.faction_ui_presenter")
local NativeCharacterAdapter =
    require("pwft.native_character_adapter")
local LocalizationRuntime = require("pwft.localization_runtime")
local PalReconciliation = require("pwft.pal_reconciliation")
local PalDiscourseRuntime =
    require("pwft.pal_discourse_runtime")
local PalDialogueController =
    require("pwft.pal_dialogue_controller")
local PalDialoguePresenter =
    require("pwft.pal_dialogue_presenter")
local PalDialogueNativeBackend =
    require("pwft.pal_dialogue_native_backend")
local PalRepresentativeInteraction =
    require("pwft.pal_representative_interaction")
local PalRepresentativeNativeRouter =
    require("pwft.pal_representative_native_router")
local PalRaidResultAdapter =
    require("pwft.pal_raid_result_adapter")
local PalRaidNativeBinding =
    require("pwft.pal_raid_native_binding")
local ProgressionIdentity = require("pwft.progression_identity")
local ProgressionStore = require("pwft.progression_store")
local QuestRuntime = require("pwft.quest_runtime")
local RayneMerchant = require("pwft.rayne_merchant")
local SettlementRaid = require("pwft.settlement_raid")
local StrategicWorld = require("pwft.strategic_world")
local WorldBalance = require("pwft.world_balance")

local PREFIX = "[PalFactionTerritory0]"
-- A UI material, rather than a bare texture, is required here.  UMG's
-- SetBrushFromTexture path rendered this specific native mask white even
-- after the source texture's alpha had been verified.  The material samples
-- the same RGBA texture and explicitly sends its alpha to the UI opacity pin.
local NATIVE_TERRITORY_OVERLAY_MATERIAL_ASSET = "/Game/Mods/PalFactionTerritory0/UI/Materials/M_PFT_IslandGeometryOverlay.M_PFT_IslandGeometryOverlay"
-- This cooked UI material contains no terrain, recreated map art, fog state,
-- player data, or save data.  Its five baked packs are Mod-owned political
-- island geometry: whole coast-aligned islands with transparent sea.  It is
-- applied only to the existing map
-- widget Image_MapMask above the real Image_MapBody, so native pan, zoom,
-- icons, and fast-travel interaction remain unchanged.
local NATIVE_MAP_LAYER_PROBE_MATERIAL_ASSET = NATIVE_TERRITORY_OVERLAY_MATERIAL_ASSET
-- Both assets below are shipped by Palworld itself.  The M-A probe uses them
-- on the existing fog Image, so the terrain, map transform, icons, pan, and
-- zoom remain wholly native to the game.
local NATIVE_WORLD_MAP_MASK_PAINT_MATERIAL_ASSET = "/Game/Pal/Blueprint/UI/WorldMap/M_WorldMapMaskPaint_FixedTexture.M_WorldMapMaskPaint_FixedTexture"
local NATIVE_WORLD_MAP_MASK_A_TEXTURE_ASSET = "/Game/Pal/Texture/UI/UnlockMapAreaMask/T_MapMask_a.T_MapMask_a"
-- The island material uses emissive UI colour.  The alpha of Color_01..20 is
-- also the per-layer visibility gate, so sea and islands without an owner in
-- the active Human/Pal view remain completely transparent.
local FACTION_OVERLAY_OPACITY = 0.40

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function log_to_console(output_device, message)
    log(message)
    if output_device ~= nil then
        pcall(function()
            output_device:Log(string.format("%s %s", PREFIX, tostring(message)))
        end)
    end
end

local function safe_to_string(value)
    if value == nil then
        return "<nil>"
    end
    local value_type = type(value)
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        return tostring(value)
    end
    local ok, rendered = pcall(function()
        if value.ToString ~= nil then
            return value:ToString()
        end
        return tostring(value)
    end)
    return ok and rendered or "<unreadable>"
end

local function safe_property(object, name)
    if object == nil then
        return nil
    end
    local ok, value = pcall(function()
        return object[name]
    end)
    if ok then
        return value
    end
    return nil
end

local function safe_param_get(parameter)
    if parameter == nil then
        return nil
    end
    local ok, value = pcall(function()
        return parameter:get()
    end)
    if ok then
        return value
    end
    return nil
end

local function safe_param_set(parameter, value)
    if parameter == nil then
        return false, "parameter-is-nil"
    end
    local ok, error_message = pcall(function()
        parameter:set(value)
    end)
    if ok then
        return true, nil
    end
    return false, tostring(error_message)
end

local function safe_full_name(object)
    if object == nil then
        return "<nil>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and safe_to_string(value) or "<unreadable>"
end

-- Reads the parameter state from Palworld's already-created map DMI.  This is
-- deliberately diagnostic-only: K2_Get* reads the values without re-binding
-- the brush, changing the render target, or writing a material parameter.
local function describe_native_mask_material(material)
    if material == nil then
        return "material=<nil>"
    end

    local material_name = safe_full_name(material)
    if string.find(material_name, "MaterialInstanceDynamic", 1, true) == nil then
        return string.format("material=%s", material_name)
    end

    local ok, color, target_texture, default_mask_texture = pcall(function()
        local color_name = FName("Color")
        local target_name = FName("TargetTexture")
        local default_mask_name = FName("DefaultMaskTexture")
        return material:K2_GetVectorParameterValue(color_name),
            material:K2_GetTextureParameterValue(target_name),
            material:K2_GetTextureParameterValue(default_mask_name)
    end)
    if not ok then
        return string.format("material=%s readError=%s", material_name, tostring(color))
    end

    return string.format(
        "material=%s color=(R=%s,G=%s,B=%s,A=%s) target=%s defaultMask=%s",
        material_name,
        safe_to_string(safe_property(color, "R")),
        safe_to_string(safe_property(color, "G")),
        safe_to_string(safe_property(color, "B")),
        safe_to_string(safe_property(color, "A")),
        safe_full_name(target_texture),
        safe_full_name(default_mask_texture)
    )
end

local function is_valid_object(object)
    if object == nil then
        return false
    end
    local ok, value = pcall(function()
        return object:IsValid()
    end)
    return ok and value == true
end

local function validate_registry(registry)
    assert(registry.schemaVersion == "1.0.0", "unsupported registry schema")
    assert(registry.baselineStatus == "user_approved_active_baseline", "island territory baseline is not active")
    assert(registry.counts.factions == 12, "unexpected faction count")
    assert(registry.counts.regions == 22, "unexpected region count")
    assert(registry.counts.nativeWatchtowers == 24, "unexpected native watchtower count")
    assert(registry.counts.mappedFastTravelPoints == 109, "unexpected fast-travel territory mapping count")
    assert(type(registry.progression) == "table", "faction progression registry is missing")
    assert(
        registry.progression.baselineStatus == "user_confirmed_mechanics_baseline_2026-07-28",
        "faction progression baseline is not active"
    )

    local faction_count = 0
    local human_faction_count = 0
    local pal_faction_count = 0
    for id, faction in pairs(registry.factions) do
        assert(id == faction.id, "faction key/id mismatch: " .. tostring(id))
        assert(faction.kind == "Human" or faction.kind == "Pal", "faction kind missing: " .. tostring(id))
        if faction.kind == "Human" then
            assert(faction.membershipAllowed == true, "human faction must allow membership: " .. tostring(id))
            human_faction_count = human_faction_count + 1
        else
            assert(faction.membershipAllowed == false, "Pal faction cannot allow membership: " .. tostring(id))
            pal_faction_count = pal_faction_count + 1
        end
        faction_count = faction_count + 1
    end
    assert(faction_count == registry.counts.factions, "faction table count mismatch")
    assert(human_faction_count == 7, "unexpected human faction count")
    assert(pal_faction_count == 5, "unexpected Pal faction count")

    local runtime_tower_count = 0
    for fast_travel_id, native_tower_id in pairs(registry.watchtowerByFastTravelId) do
        assert(type(fast_travel_id) == "string" and fast_travel_id ~= "", "invalid runtime fast-travel ID")
        assert(type(native_tower_id) == "string" and native_tower_id ~= "", "invalid native tower ID")
        runtime_tower_count = runtime_tower_count + 1
    end
    assert(runtime_tower_count == registry.counts.runtimeConfirmedWatchtowers, "runtime tower mapping count mismatch")

    local region_count = 0
    for id, territory in pairs(registry.territories) do
        assert(id == territory.id, "territory key/id mismatch: " .. tostring(id))
        if territory.ownerFactionId ~= nil then
            assert(registry.factions[territory.ownerFactionId] ~= nil, "unknown territory owner: " .. territory.ownerFactionId)
        end
        assert(registry.maskToRegion[territory.nativeMaskAsset] == id, "mask/region mismatch: " .. id)
        region_count = region_count + 1
    end
    assert(region_count == registry.counts.regions, "territory table count mismatch")

    local island_count = 0
    for id, island in pairs(registry.islands) do
        assert(id == island.id, "island key/id mismatch: " .. tostring(id))
        if island.humanOwnerFactionId ~= nil then
            assert(registry.factions[island.humanOwnerFactionId] ~= nil, "unknown human island owner: " .. island.humanOwnerFactionId)
        end
        if island.palOwnerFactionId ~= nil then
            assert(registry.factions[island.palOwnerFactionId] ~= nil, "unknown Pal island owner: " .. island.palOwnerFactionId)
        end
        island_count = island_count + 1
    end
    assert(island_count == registry.counts.islands, "island table count mismatch")
    assert(#registry.islandOrder == registry.counts.islands, "island order count mismatch")

    local fast_travel_count = 0
    for fast_travel_id, island_id in pairs(registry.fastTravelPointToIsland) do
        assert(type(fast_travel_id) == "string" and fast_travel_id ~= "", "invalid fast-travel point ID")
        assert(registry.islands[island_id] ~= nil, "fast-travel point references unknown island: " .. tostring(island_id))
        fast_travel_count = fast_travel_count + 1
    end
    assert(fast_travel_count == registry.counts.mappedFastTravelPoints, "fast-travel territory mapping count mismatch")
end

local function make_state(config, registry)
    local fast_travel_to_island = {}
    for fast_travel_id, island_id in pairs(registry.fastTravelPointToIsland) do
        fast_travel_to_island[fast_travel_id] = island_id
    end
    return {
        mapMode = config.defaultMapMode,
        relationEvents = {},
        relations = {},
        dangerWarningCount = 0,
        lastDangerTerritoryId = nil,
        lastDangerPresentationKey = nil,
        placeNameDisplayCount = 0,
        placeNamePresentationCount = 0,
        placeNameUnmappedCount = 0,
        placeNameConstructDiagnosticCount = 0,
        seenUnmappedRegionNameIds = {},
        lastPlaceNamePresentationKey = nil,
        mapCreateCount = 0,
        mapWidgetProbeCount = 0,
        towerProbeCount = 0,
        softMaskProbeCount = 0,
        fastTravelAuditCount = 0,
        fastTravelAvailabilityQueryCount = 0,
        fastTravelAvailabilityDeniedCount = 0,
        fastTravelAvailabilityDenialLogged = false,
        hostileFastTravelOperationCount = 0,
        pendingHostileFastTravel = nil,
        nativeFogOverrideCount = 0,
        nativeTerritoryOverlayCount = 0,
        nativeTerritoryOverlayMaterial = nil,
        nativeTerritoryOverlayLoadAttempted = false,
        nativeMapLayerProbeCount = 0,
        nativeMapLayerProbeMaterial = nil,
        nativeMapLayerProbeLoadAttempted = false,
        nativeFactionMaskAssets = nil,
        nativeFactionMaskLoadAttempted = false,
        nativeFactionMapOverlayCount = 0,
        nativeMapPaintProbeCount = 0,
        nativeMapPaintProbeMaterial = nil,
        nativeMapPaintProbeTexture = nil,
        nativeMapPaintProbeLoadAttempted = false,
        fastTravelToIsland = fast_travel_to_island,
        progressionIdentity = {
            status = "waiting-for-world",
            readOnly = true,
            attempts = 0,
            generation = 0,
            lastError = nil,
            value = nil,
            sidecarRootPath =
                config.factionProgression.persistence.rootPath,
        },
        hooks = {},
        callbacks = {},
    }
end

local function sync_progression_relations(policy, state)
    assert(state.factionProgression ~= nil, "faction progression state is unavailable")
    local events = state.factionProgression:relation_events()
    state.relationEvents = events
    state.relations = policy.latest_relations(events)
    return events
end

-- Convert a normal Lua string through Unreal's own Kismet text library.  This
-- produces a genuine FText return value on UE4SS builds that do not expose an
-- FText Lua constructor.  It avoids passing raw string bytes into an FText
-- struct field (the old route that could crash the game).
local function make_native_warning_ftext(message)
    -- Prefer Unreal's own conversion library.  It constructs the FText on the
    -- game side and is therefore the safest path through a reflected struct
    -- parameter.  UE4SS's FText constructor remains a compatible fallback.
    if type(StaticFindObject) == "function" then
        local found, text_library = pcall(function()
            return StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        end)
        if found and is_valid_object(text_library) then
            local converted, warning_text = pcall(function()
                return text_library:Conv_StringToText(message)
            end)
            if converted and warning_text ~= nil then
                return warning_text, nil, "kismet"
            end
        end
    end
    if type(FText) == "function" then
        local constructed, warning_text = pcall(function()
            return FText(message)
        end)
        if constructed and warning_text ~= nil then
            return warning_text, nil, "ue4ss-ftext"
        end
    end
    return nil, "native-ftext-construction-unavailable", "none"
end

local function show_native_map_danger_banner(config, warning_text, territory_id, source)
    if config.enableNativeMapDangerBanner ~= true
        or (source ~= "map-fast-travel-selection" and source ~= "map-fast-travel-blocked") then
        return false
    end
    -- Do not use WidgetTree / FindObject: resolving private child controls
    -- through that path crashes on this game build.  The dump confirms that
    -- these are live, public UMG instances, so locate them via FindAllOf and
    -- constrain the result to the current transient WBP_Map_Base instance.
    local function find_map_widget(class_name, widget_name)
        local found_ok, widgets = pcall(function()
            return FindAllOf(class_name)
        end)
        if not found_ok or widgets == nil then
            return nil, nil
        end
        for _, widget in pairs(widgets) do
            if is_valid_object(widget) then
                local full_name = safe_full_name(widget)
                if string.find(full_name, "/Engine/Transient", 1, true) ~= nil
                    and string.find(full_name, "WBP_Map_Base_C", 1, true) ~= nil
                    and string.find(full_name, widget_name, 1, true) ~= nil then
                    return widget, full_name
                end
            end
        end
        return nil, nil
    end

    local text_block, text_name = find_map_widget("BP_PalTextBlock_C", "Text_Warning_1")
    local warning_box, box_name = find_map_widget("SizeBox", "SizeBox_Warning_1")
    local warning_canvas, canvas_name = find_map_widget("CanvasPanel", "Canvas_Warning")
    if not is_valid_object(text_block) or (not is_valid_object(warning_box) and not is_valid_object(warning_canvas)) then
        log("MAP_DANGER_BANNER_SKIPPED reason=live-warning-controls-unavailable")
        return false
    end

    local set_ok = pcall(function()
        text_block:SetText(warning_text)
        text_block:SetVisibility(0) -- ESlateVisibility::Visible
    end)
    local visible_ok = false
    if is_valid_object(warning_box) then
        visible_ok = pcall(function()
            warning_box:SetVisibility(0) -- ESlateVisibility::Visible
        end)
    end
    if is_valid_object(warning_canvas) then
        local canvas_ok = pcall(function()
            warning_canvas:SetVisibility(0) -- ESlateVisibility::Visible
        end)
        visible_ok = visible_ok or canvas_ok
    end
    log(string.format(
        "MAP_DANGER_BANNER_WRITE region=%s text=%s box=%s canvas=%s textSet=%s visible=%s",
        territory_id,
        tostring(text_name),
        tostring(box_name),
        tostring(canvas_name),
        tostring(set_ok),
        tostring(visible_ok)
    ))
    return set_ok and visible_ok
end

-- PalHUDService reliably opens the game's WBP_CommonWarning but, on this
-- UE4SS build, loses the struct's FText payload.  Patch only the text block
-- that already belongs to that native warning widget; no custom widget is
-- created and no input/UI stack state is changed.
local function set_native_danger_warning_text(warning_text)
    local found_ok, warnings = pcall(function()
        return FindAllOf("WBP_CommonWarning_C")
    end)
    if not found_ok or warnings == nil then
        return 0
    end
    local updated = 0
    for _, warning in pairs(warnings) do
        if is_valid_object(warning) then
            local warning_name = safe_full_name(warning)
            local got_text_block, text_block = pcall(function()
                return warning.BP_PalRichTextBlock
            end)
            if got_text_block and is_valid_object(text_block) then
                local text_block_name = safe_full_name(text_block)
                local set_ok = pcall(function()
                    text_block:SetText(warning_text)
                end)
                -- The native warning panel can be visible while its rich-text
                -- child remains collapsed after ShowCommonWarning receives an
                -- empty payload on this build.  Make only that already-live
                -- child visible; no new widget or UI layer is created.
                local visible_ok = pcall(function()
                    text_block:SetVisibility(0) -- ESlateVisibility::Visible
                end)
                local read_ok, current_text = pcall(function()
                    return text_block:GetText()
                end)
                log(string.format(
                    "DANGER_WARNING_TEXT_WRITE warning=%s textBlock=%s set=%s visible=%s read=%s",
                    warning_name,
                    text_block_name,
                    tostring(set_ok),
                    tostring(visible_ok),
                    read_ok and safe_to_string(current_text) or "unreadable"
                ))
                if set_ok and visible_ok then
                    updated = updated + 1
                end
            else
                log(string.format(
                    "DANGER_WARNING_TEXT_WRITE_SKIPPED warning=%s reason=text-block-unavailable",
                    warning_name
                ))
            end
        end
    end
    return updated
end

-- ShowCommonWarning constructs/updates its native widget after the service
-- call returns.  Reapply the text one frame later so that its empty default
-- value cannot overwrite the territory warning.  This touches only the
-- already-visible WBP_CommonWarning text block.
local function schedule_native_danger_warning_text(state, warning_text)
    if type(ExecuteWithDelay) ~= "function" then
        return false
    end
    local refresh_callback = function()
        local apply_text = function()
            local updated = set_native_danger_warning_text(warning_text)
            log(string.format("DANGER_WARNING_TEXT_REFRESH textBlocks=%d", updated))
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(apply_text)
        else
            apply_text()
        end
    end
    state.callbacks.dangerWarningTextRefresh = refresh_callback
    ExecuteWithDelay(100, refresh_callback)
    return true
end

-- This follows Palworld's normal generic HUD-warning route instead of the
-- WBP_Crime family.  The warning struct is passed directly to an already
-- constructed WBP_PalOverallUILayout instance; no UMG widget is created by
-- Lua, no input is captured, and no Wanted/Crime value is touched.
local function show_native_danger_warning(config, registry, policy, state, territory_id, source)
    if config.enableDangerAreaWarningUi ~= true then
        return false, "disabled"
    end
    local territory = registry.islands[territory_id] or registry.territories[territory_id]
    if territory == nil then
        return false, "unknown-territory"
    end
    local relation = policy.resolve_relation(territory, state.relations, false)
    if relation ~= "Hostile" then
        return false, "not-hostile"
    end
    -- The map container and the icon widget can both report the same click.
    -- Deduplicate that one operation, but key the guard by source so a later
    -- completed native fast-travel can still show its visible entry warning.
    local source_key = tostring(source or "unknown")
    local presentation_key = source_key .. ":" .. territory_id
    if state.lastDangerPresentationKey == presentation_key then
        return false, "already-presented"
    end
    if type(FindAllOf) ~= "function" then
        log("DANGER_WARNING_UNAVAILABLE missing=FindAllOf")
        return false, "runtime-api-unavailable"
    end
    local faction_id = territory.humanOwnerFactionId or territory.ownerFactionId
    local faction = faction_id and registry.factions[faction_id] or nil
    local owner_name = faction and faction.displayNameZhHans
        or territory.ownerDisplayNameZhHans
        or "未知势力"
    local message
    if source == "map-fast-travel-blocked" then
        -- The hostile destination's native confirmation has already been
        -- cancelled in the same click callback. State the actual result.
        message = "无法传送到敌方阵营。"
    elseif source == "map-fast-travel-selection" then
        message = string.format(
            "即将前往敌对势力领地：%s。请谨慎行动。",
            tostring(owner_name)
        )
    else
        message = string.format(
            "已进入敌对势力领地：%s。请谨慎行动。",
            tostring(owner_name)
        )
    end
    local warning_text, text_error, text_source = make_native_warning_ftext(message)
    if warning_text == nil then
        log(string.format("DANGER_WARNING_UNAVAILABLE native-text-construction-failed error=%s", tostring(text_error)))
        return false, "native-text-construction-failed"
    end
    -- Prefer the native HUD service.  WBP_PalOverallUILayout exposes the same
    -- function but can acknowledge a call without actually putting a toast on
    -- the live HUD layer.  The service is Palworld's own routing surface for
    -- FPalUICommonWarningDisplayData; retain the layout only as a fallback.
    local warning_surfaces = {}
    local function add_warning_surfaces(class_name, route)
        local found_ok, found = pcall(function()
            return FindAllOf(class_name)
        end)
        if not found_ok or found == nil then
            return
        end
        for _, object in pairs(found) do
            if is_valid_object(object) then
                table.insert(warning_surfaces, { object = object, route = route })
            end
        end
    end
    add_warning_surfaces("PalHUDService", "hud-service")
    if #warning_surfaces == 0 then
        add_warning_surfaces("WBP_PalOverallUILayout_C", "layout-fallback")
    end
    if #warning_surfaces == 0 then
        log("DANGER_WARNING_UNAVAILABLE no-live-native-warning-surface")
        return false, "warning-surface-unavailable"
    end

    for _, surface in ipairs(warning_surfaces) do
        if is_valid_object(surface.object) then
            local shown, error_message = pcall(function()
                surface.object:ShowCommonWarning({
                    -- ShowCommonWarning expects FPalUICommonWarningDisplayData.
                    -- Its Message field must receive a real UE4SS FText object,
                    -- never a Lua string (see the ftext guard above).
                    Message = warning_text,
                    DisplayType = 0, -- EPalUICommonWarningType::Default
                })
            end)
            if shown then
                local updated_text_blocks = set_native_danger_warning_text(warning_text)
                local text_refresh_scheduled = schedule_native_danger_warning_text(state, warning_text)
                local map_banner_shown = show_native_map_danger_banner(
                    config,
                    warning_text,
                    territory_id,
                    source
                )
                state.lastDangerTerritoryId = territory_id
                state.lastDangerPresentationKey = presentation_key
                if type(ExecuteWithDelay) == "function" then
                    local clear_presentation_key = presentation_key
                    local clear_callback = function()
                        if state.lastDangerPresentationKey == clear_presentation_key then
                            state.lastDangerPresentationKey = nil
                        end
                    end
                    state.callbacks.dangerWarningDedup = clear_callback
                    ExecuteWithDelay(1500, clear_callback)
                end
                state.dangerWarningCount = state.dangerWarningCount + 1
                log(string.format(
                    "DANGER_WARNING_PRESENTED count=%d region=%s source=%s textSource=%s surface=%s route=%s textBlocks=%d textRefresh=%s mapBanner=%s",
                    state.dangerWarningCount,
                    territory_id,
                    tostring(source or "unknown"),
                    tostring(text_source),
                    safe_full_name(surface.object),
                    surface.route,
                    updated_text_blocks,
                    tostring(text_refresh_scheduled),
                    tostring(map_banner_shown)
                ))
                return true, "shown"
            end
            log(string.format(
                "DANGER_WARNING_ERROR region=%s source=%s error=%s",
                territory_id,
                tostring(source or "unknown"),
                tostring(error_message)
            ))
            return false, "presentation-error"
        end
    end
    log("DANGER_WARNING_UNAVAILABLE warning-surface-not-live")
    return false, "warning-surface-not-live"
end

local function try_register_hook(state, path, callback, post_callback)
    -- Blueprint UFunctions can be registered only after their widget class is
    -- loaded.  The map creates several icons in one frame, so an activation
    -- listener may ask for the same function more than once.  Keep the first
    -- successful hook and never install duplicate callbacks.
    if state.hooks[path] ~= nil then
        return true
    end
    local ok, pre_id, post_id = pcall(function()
        -- UE4SS c838a8ac supports a third callback for native /Script/
        -- functions.  Its first callback runs before the native body and the
        -- optional third callback runs after it with the original return value.
        -- Blueprint functions remain on the two-argument post-hook route.
        if post_callback ~= nil then
            return RegisterHook(path, callback, post_callback)
        end
        return RegisterHook(path, callback)
    end)
    if not ok then
        log(string.format("HOOK_UNAVAILABLE path=%s error=%s", path, tostring(pre_id)))
        return false
    end
    state.hooks[path] = {
        preId = pre_id,
        postId = post_id,
        callback = callback,
        postCallback = post_callback,
    }
    log(string.format("HOOK_READY path=%s", path))
    return true
end

local PLACE_NAME_DISPLAY_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/InGame/PlaceName/WBP_IngamePlaceName.WBP_IngamePlaceName_C:Display Region"

local function presentation_linear_color(hex)
    if type(hex) ~= "string" or string.sub(hex, 1, 1) ~= "#" or #hex ~= 7 then
        return { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
    end
    local red = tonumber(string.sub(hex, 2, 3), 16)
    local green = tonumber(string.sub(hex, 4, 5), 16)
    local blue = tonumber(string.sub(hex, 6, 7), 16)
    if red == nil or green == nil or blue == nil then
        return { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
    end
    return {
        R = red / 255.0,
        G = green / 255.0,
        B = blue / 255.0,
        A = 1.0,
    }
end

local function presentation_slate_color(linear_color)
    -- FSlateColor owns a specified FLinearColor.  Passing a structured value
    -- keeps the TextBlock route type-correct instead of assigning raw bytes to
    -- a reflected FSlateColor property.
    return {
        SpecifiedColor = linear_color,
        ColorUseRule = 0, -- ESlateColorStylingMode::UseColor_Specified
    }
end

local function apply_native_place_name_presentation(config, registry, policy, state, place_widget, native_region_name_id, phase)
    if config.enableNativePlaceNamePresentation ~= true then
        return false, "disabled"
    end
    if not is_valid_object(place_widget) then
        return false, "widget-invalid"
    end

    local current_name_id = safe_to_string(safe_property(place_widget, "CachedRegionNameID"))
    if current_name_id ~= "" and current_name_id ~= "None" and current_name_id ~= "<nil>"
        and current_name_id ~= native_region_name_id then
        return false, "superseded-by-newer-region"
    end

    local presentation = policy.resolve_region_name_presentation(
        registry,
        native_region_name_id,
        state.relations,
        false
    )
    if presentation == nil then
        if state.seenUnmappedRegionNameIds[native_region_name_id] ~= true then
            state.seenUnmappedRegionNameIds[native_region_name_id] = true
            state.placeNameUnmappedCount = state.placeNameUnmappedCount + 1
            log(string.format(
                "PLACE_NAME_UNMAPPED count=%d nativeRegionNameId=%s action=keep-vanilla",
                state.placeNameUnmappedCount,
                native_region_name_id
            ))
        end
        return false, "unmapped"
    end

    local linear_color = presentation_linear_color(presentation.color)
    local slate_color = presentation_slate_color(linear_color)
    local text_block = safe_property(place_widget, "Text_RegionName")
    local text_ok = false
    if is_valid_object(text_block) then
        text_ok = pcall(function()
            text_block:SetColorAndOpacity(slate_color)
        end)
    end

    local image_count = 0
    for _, field_name in ipairs({
        "Base",
        "BaseLineC",
        "BaseLineC_1",
        "BaseLineL",
        "BaseLineL_1",
        "BaseLineR",
        "BaseLineR_1",
        "Flare",
    }) do
        local image = safe_property(place_widget, field_name)
        if is_valid_object(image) then
            local image_ok = pcall(function()
                image:SetColorAndOpacity(linear_color)
            end)
            if image_ok then
                image_count = image_count + 1
            end
        end
    end

    if text_ok or image_count > 0 then
        state.placeNamePresentationCount = state.placeNamePresentationCount + 1
        state.lastPlaceNamePresentationKey = native_region_name_id .. ":" .. presentation.territoryId
        log(string.format(
            "PLACE_NAME_PRESENTED count=%d nativeRegionNameId=%s territory=%s relation=%s color=%s phase=%s text=%s images=%d widget=%s",
            state.placeNamePresentationCount,
            native_region_name_id,
            presentation.territoryId,
            presentation.relation,
            presentation.color,
            tostring(phase),
            tostring(text_ok),
            image_count,
            safe_full_name(place_widget)
        ))
        return true, "presented"
    end

    log(string.format(
        "PLACE_NAME_PRESENTATION_SKIPPED nativeRegionNameId=%s territory=%s reason=no-live-controls",
        native_region_name_id,
        presentation.territoryId
    ))
    return false, "controls-unavailable"
end

local function schedule_native_place_name_presentation(config, registry, policy, state, place_widget, native_region_name_id, delay_ms, phase)
    local apply = function()
        apply_native_place_name_presentation(
            config,
            registry,
            policy,
            state,
            place_widget,
            native_region_name_id,
            phase
        )
    end
    local callback = function()
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(apply)
        else
            apply()
        end
    end
    state.callbacks.placeNamePresentation = callback
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(delay_ms, callback)
    else
        callback()
    end
end

local function ensure_native_place_name_display_hook(config, registry, policy, state)
    if config.enableNativePlaceNamePresentation ~= true then
        return false
    end
    return try_register_hook(
        state,
        PLACE_NAME_DISPLAY_PATH,
        function(context, region_name_id_param)
            local ok, error_message = pcall(function()
                local place_widget = safe_param_get(context)
                local native_region_name_id = safe_to_string(safe_param_get(region_name_id_param))
                if native_region_name_id == "" or native_region_name_id == "None" or native_region_name_id == "<nil>" then
                    log("PLACE_NAME_DISPLAY_SKIPPED reason=region-name-id-unresolved")
                    return
                end
                state.placeNameDisplayCount = state.placeNameDisplayCount + 1
                log(string.format(
                    "PLACE_NAME_DISPLAY count=%d nativeRegionNameId=%s widget=%s",
                    state.placeNameDisplayCount,
                    native_region_name_id,
                    safe_full_name(place_widget)
                ))
                -- The hook runs before the original Blueprint fills its native
                -- card. Apply once immediately after that dispatch, then once
                -- after its opening animation has initialized. These are two
                -- one-shot callbacks for this entry, never a polling loop.
                schedule_native_place_name_presentation(config, registry, policy, state, place_widget, native_region_name_id, 1, "after-native-display")
                schedule_native_place_name_presentation(config, registry, policy, state, place_widget, native_region_name_id, 120, "animation-refresh")
                if state.settlementRaid ~= nil then
                    state.settlementRaid:on_region_display(
                        native_region_name_id
                    )
                end
            end)
            if not ok then
                log("PLACE_NAME_DISPLAY_ERROR " .. tostring(error_message))
            end
        end
    )
end

-- On the live Steam build the top-level HUD is named WBP_PalOverallUILayout_C,
-- not WBP_PlayerUI_C.  It constructs the place-name child, so treat it as an
-- activation point as well.  Keep a short bounded diagnostic trail for any
-- future UI rename; this is event-driven UserWidget construction, never a
-- repeated timer or player-position poll.
local function observe_place_name_hook_activation(config, registry, policy, state, widget)
    if state.hooks[PLACE_NAME_DISPLAY_PATH] ~= nil then
        return
    end

    local widget_name = safe_full_name(widget)
    state.placeNameConstructDiagnosticCount = state.placeNameConstructDiagnosticCount + 1
    if state.placeNameConstructDiagnosticCount <= 24 then
        log(string.format(
            "PLACE_NAME_CONSTRUCT_OBSERVED count=%d widget=%s",
            state.placeNameConstructDiagnosticCount,
            widget_name
        ))
    end

    local activation_candidate = string.find(widget_name, "WBP_IngamePlaceName", 1, true) ~= nil
        or string.find(widget_name, "WBP_PlayerUI", 1, true) ~= nil
        or string.find(widget_name, "WBP_PalOverallUILayout", 1, true) ~= nil
    if activation_candidate then
        local ready = ensure_native_place_name_display_hook(config, registry, policy, state)
        log(string.format(
            "PLACE_NAME_HOOK_ACTIVATION widget=%s ready=%s",
            widget_name,
            tostring(ready)
        ))
    end
end

local function register_console_commands(config, registry, policy, state)
    if type(RegisterConsoleCommandGlobalHandler) ~= "function" then
        log("CONSOLE_COMMANDS_UNAVAILABLE")
        return
    end

    local function refresh_after_progression_change(faction_id)
        sync_progression_relations(policy, state)
        if state.rayneMerchant ~= nil
            and faction_id == config.rayneMerchant.factionId then
            local relation = state.relations[faction_id]
            state.rayneMerchant:on_relation_changed(relation and relation.state or "Friendly")
        end
    end

    RegisterConsoleCommandGlobalHandler("pwft.status", function(_, _, ar)
        log_to_console(ar, string.format(
            "STATUS release=%s build=Steam/%s sourceContractBuild=%s baseline=%s mapMode=%s regions=%d factions=%d placeNameDisplays=%d placeNamePresentations=%d placeNameUnmapped=%d mapCreates=%d towerProbes=%d fastTravelAudits=%d nativeFogOverrides=%d nativeTerritoryOverlays=%d overlayMutation=%s nativeFogVisualOverride=%s fastTravelEnforcement=%s saveWrites=%s",
            config.releaseId,
            config.expectedSteamBuildId,
            registry.gameBuild,
            registry.baselineId,
            state.mapMode,
            registry.counts.regions,
            registry.counts.factions,
            state.placeNameDisplayCount,
            state.placeNamePresentationCount,
            state.placeNameUnmappedCount,
            state.mapCreateCount,
            state.towerProbeCount,
            state.fastTravelAuditCount,
            state.nativeFogOverrideCount,
            state.nativeTerritoryOverlayCount,
            tostring(config.enableMapOverlayMutation),
            tostring(config.enableNativeFogVisualOverride),
            tostring(config.enableFastTravelEnforcement),
            tostring(config.enableSaveWrites)
        ))
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.map", function(_, parts, ar)
        if #parts < 2 then
            log_to_console(ar, "MAP_MODE " .. state.mapMode)
            return true
        end
        local requested = parts[2]
        if requested == "original" or requested == "Original" then
            state.mapMode = "Original"
        elseif requested == "human" or requested == "Human"
            or requested == "territory" or requested == "Territory" then
            state.mapMode = "Human"
        elseif requested == "pal" or requested == "Pal" then
            state.mapMode = "Pal"
        else
            log_to_console(ar, "USAGE pwft.map original|human|pal")
            return true
        end
        log_to_console(ar, "MAP_MODE_SET " .. state.mapMode .. " (press N while the world map is open to apply)")
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.relation", function(_, parts, ar)
        if #parts < 3 then
            log_to_console(ar, "USAGE pwft.relation <factionId> Neutral|Friendly|Hostile|Player")
            return true
        end
        local faction_id = parts[2]
        local relation = parts[3]
        if registry.factions[faction_id] == nil then
            log_to_console(ar, "UNKNOWN_FACTION " .. tostring(faction_id))
            return true
        end
        local ok, latest_or_error = pcall(function()
            local revision = #state.relationEvents + 1
            table.insert(state.relationEvents, {
                factionId = faction_id,
                state = relation,
                revision = revision,
            })
            return policy.latest_relations(state.relationEvents)
        end)
        if not ok then
            table.remove(state.relationEvents)
            log_to_console(ar, "RELATION_REJECTED " .. tostring(latest_or_error))
            return true
        end
        state.relations = latest_or_error
        if state.rayneMerchant ~= nil
            and faction_id == config.rayneMerchant.factionId then
            state.rayneMerchant:on_relation_changed(relation)
        end
        log_to_console(ar, string.format(
            "RELATION_SET faction=%s state=%s (cycle N while the world map is open to refresh)",
            faction_id,
            relation
        ))
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.progress", function(_, parts, ar)
        if state.factionProgression == nil then
            log_to_console(ar, "PROGRESSION unavailable")
            return true
        end
        local operation = parts[2] or "status"
        if operation == "status" then
            local faction_id = parts[3]
            local status = state.factionProgression:status(faction_id)
            if status == nil then
                log_to_console(ar, "UNKNOWN_FACTION " .. tostring(faction_id))
            elseif faction_id == nil then
                log_to_console(ar, string.format(
                    "PROGRESSION revision=%d events=%d palReconciliation=%s ending3=%s persistence=%s",
                    status.revision,
                    status.eventCount,
                    tostring(status.palReconciliationUnlocked),
                    tostring(status.ending3Unlocked),
                    status.persistence
                ))
            else
                log_to_console(ar, string.format(
                    "PROGRESSION_FACTION faction=%s kind=%s reputation=%s relation=%s joined=%s rank=%s guard=%s joinEligible=%s",
                    faction_id,
                    status.kind,
                    tostring(status.reputation),
                    status.relation,
                    tostring(status.joined),
                    tostring(status.rankId or "none"),
                    tostring(status.guardAccess),
                    tostring(status.joinEligible)
                ))
            end
        elseif operation == "join" then
            local faction_id = parts[3]
            if faction_id == nil then
                log_to_console(ar, "USAGE pwft.progress join <humanFactionId>")
                return true
            end
            local outcome = state.factionProgression:join(faction_id)
            if outcome.ok then
                refresh_after_progression_change(faction_id)
            end
            log_to_console(ar, string.format(
                "PROGRESSION_JOIN faction=%s ok=%s reason=%s rank=%s",
                tostring(faction_id),
                tostring(outcome.ok),
                outcome.reason,
                tostring(outcome.rankId or "none")
            ))
        elseif operation == "grant" then
            local faction_id = parts[3]
            local source = parts[4]
            local amount = tonumber(parts[5])
            if faction_id == nil or source == nil or amount == nil then
                log_to_console(ar, "USAGE pwft.progress grant <humanFactionId> task|defense|commerce <positiveAmount> [commerceWindowId]")
                return true
            end
            local outcome = state.factionProgression:grant_reputation(
                faction_id,
                source,
                amount,
                {
                    windowId = parts[6],
                    contextId = "console-offline-probe",
                }
            )
            if outcome.ok and outcome.applied ~= nil and outcome.applied > 0 then
                refresh_after_progression_change(faction_id)
            end
            log_to_console(ar, string.format(
                "PROGRESSION_GRANT faction=%s source=%s ok=%s reason=%s requested=%s applied=%s after=%s rank=%s",
                tostring(faction_id),
                tostring(source),
                tostring(outcome.ok),
                outcome.reason,
                tostring(outcome.requested or amount),
                tostring(outcome.applied or 0),
                tostring(outcome.after or "unchanged"),
                tostring(outcome.rankId or "none")
            ))
        elseif operation == "reconcile" then
            local faction_id = parts[3]
            if faction_id == nil then
                log_to_console(ar, "USAGE pwft.progress reconcile <palFactionId>")
                return true
            end
            local outcome = state.factionProgression:reconcile_pal(
                faction_id,
                { contextId = "console-offline-probe" }
            )
            if outcome.ok then
                refresh_after_progression_change(faction_id)
            end
            log_to_console(ar, string.format(
                "PROGRESSION_RECONCILE faction=%s ok=%s reason=%s relation=%s",
                tostring(faction_id),
                tostring(outcome.ok),
                outcome.reason,
                tostring(outcome.relation or "unchanged")
            ))
        elseif operation == "gate" then
            local gate = state.factionProgression:gate_status()
            log_to_console(ar, string.format(
                "PROGRESSION_GATE palReconciliation=%s ending3=%s missingHumanLords=%d missingPalFriendly=%d",
                tostring(gate.palReconciliationUnlocked),
                tostring(gate.ending3Unlocked),
                #gate.missingHumanLords,
                #gate.missingPalFriendly
            ))
        else
            log_to_console(ar, "USAGE pwft.progress status [factionId]|join <humanFactionId>|grant <humanFactionId> task|defense|commerce <positiveAmount> [commerceWindowId]|reconcile <palFactionId>|gate")
        end
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.factions", function(_, parts, ar)
        if state.factionUiModel == nil then
            log_to_console(ar, "FACTION_UI_MODEL unavailable")
            return true
        end
        local faction_id = parts[2]
        if faction_id ~= nil then
            local row = state.factionUiModel:faction_row(faction_id)
            if row == nil then
                log_to_console(ar, "UNKNOWN_FACTION " .. tostring(faction_id))
                return true
            end
            log_to_console(ar, string.format(
                "FACTION_ROW faction=%s kind=%s reputation=%s relation=%s joined=%s rank=%s guard=%s colour=%s",
                row.factionId,
                row.kind,
                tostring(row.reputation),
                row.relation,
                tostring(row.joined),
                tostring(row.rankId or "none"),
                tostring(row.guardAccess),
                tostring(row.relationColour)
            ))
            return true
        end
        local model = state.factionUiModel:build()
        log_to_console(ar, string.format(
            "FACTION_UI_MODEL rows=%d human=%d pal=%d palReconciliation=%s ending3=%s renderer=%s",
            #model.rows,
            model.humanFactionCount,
            model.palFactionCount,
            tostring(model.gates.palReconciliationUnlocked),
            tostring(model.gates.ending3Unlocked),
            model.renderingStatus
        ))
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.commerce", function(_, parts, ar)
        if state.factionCommerce == nil
            or state.commerceBridge == nil
            or state.factionMerchantRuntime == nil then
            log_to_console(ar, "FACTION_COMMERCE unavailable")
            return true
        end
        local operation = parts[2] or "status"
        if operation == "status" then
            local commerce_status = state.factionCommerce:status()
            local bridge_status = state.commerceBridge:status()
            local merchant_status = state.factionMerchantRuntime:status()
            local economy_merchant_status =
                state.factionEconomyMerchantRuntime:status()
            log_to_console(ar, string.format(
                "FACTION_COMMERCE factions=%d shops=%d transactions=%d awarded=%d requestSource=%s hooks=%d successfulBuys=%d failedBuys=%d confirmedSales=%d guildAuthorised=%s guildCounters=%d legacySpawn=%s adapter=%s legacyFixed=%d caravans=%d island=%s sell=%s",
                commerce_status.factionCount,
                commerce_status.registeredShopCount,
                commerce_status.transactionCount,
                commerce_status.awardedTransactionCount,
                commerce_status.requestedItemSource,
                bridge_status.hookCount,
                bridge_status.successfulBuyCount,
                bridge_status.failedBuyCount,
                bridge_status.confirmedSellCount,
                tostring(
                    economy_merchant_status
                        .activationAuthorized
                ),
                economy_merchant_status.activeCount,
                tostring(
                    config.factionCommerce.nativeFactionMerchantSpawnEnabled
                ),
                tostring(merchant_status.adapterReady),
                merchant_status.fixedActiveCount,
                merchant_status.caravanActiveCount,
                merchant_status.marketPlacementStatus,
                commerce_status.sellSettlementStatus
            ))
        elseif operation == "faction" then
            local faction_id = parts[3]
            if faction_id == nil then
                log_to_console(
                    ar,
                    "USAGE pwft.commerce faction <humanFactionId>"
                )
                return true
            end
            local merchant = state.factionCommerce:merchant_status(faction_id)
            if merchant == nil then
                log_to_console(
                    ar,
                    "UNKNOWN_COMMERCE_FACTION " .. tostring(faction_id)
                )
                return true
            end
            local shop = state.factionEconomyShops
                :shop_catalog(faction_id)
            local procurement = state.factionEconomyShops
                :procurement_catalog(faction_id)
            if shop ~= nil and procurement ~= nil then
                log_to_console(ar, string.format(
                    "FACTION_MERCHANT faction=%s organisation=%s channel=ItemShop character=%s shop=%s colour=%s stock=%d requested=%d requestSource=%s rows=%s binding=%s palMerchantSpecial=false",
                    faction_id,
                    shop.merchantOrganisationId,
                    shop.nativeCharacterId,
                    shop.lotteryRowName,
                    shop.clothingColour,
                    #shop.products,
                    #procurement.requested,
                    state.factionCommerce:status()
                        .requestedItemSource,
                    tostring(shop.rowsEnabled),
                    tostring(shop.nativeShopBindingEnabled)
                ))
            else
                log_to_console(
                    ar,
                    "FACTION_MERCHANT catalog-unavailable faction="
                        .. faction_id
                )
            end
        else
            log_to_console(
                ar,
                "USAGE pwft.commerce status|faction <humanFactionId>"
            )
        end
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.economy", function(_, parts, ar)
        if state.factionEconomy == nil
            or state.factionEconomyShops == nil then
            log_to_console(ar, "FACTION_ECONOMY unavailable")
            return true
        end
        local operation = parts[2] or "status"
        if operation == "status" then
            local economy_status = state.factionEconomy:status()
            local shop_status = state.factionEconomyShops:status()
            log_to_console(ar, string.format(
                "FACTION_ECONOMY factions=%d resources=%d products=%d closedLoop=%d merchantInputs=%d unresolved=%d organisation=%s customRowsReady=%s customRows=%s shopProducts=%d requested=%d signals=%d shopBinding=%s dynamicPrices=%s settlement=%s balanceProfile=%s balanceRuntime=%s balance=%s",
                economy_status.factionCount,
                economy_status.resourceCount,
                economy_status.auditedProductCount,
                economy_status.closedLoopProductCount,
                economy_status.merchantSuppliedInputProductCount,
                economy_status.unresolvedProductCount,
                economy_status.merchantOrganisationDisplayNameZhHans,
                tostring(shop_status.customProductRowsReady),
                tostring(economy_status.customProductRowsEnabled),
                shop_status.productRowCount,
                shop_status.requestedItemCount,
                shop_status.marketSignalCount,
                tostring(shop_status.nativeShopBindingEnabled),
                tostring(economy_status.dynamicPriceRuntimeEnabled),
                tostring(
                    economy_status
                        .requestedSaleReputationSettlementEnabled
                ),
                economy_status.balanceProfileId,
                tostring(economy_status.balanceRuntimeAuthority),
                economy_status.balanceStatus
            ))
        elseif operation == "faction" then
            local faction_id = parts[3]
            if faction_id == nil then
                log_to_console(
                    ar,
                    "USAGE pwft.economy faction <humanFactionId>"
                )
                return true
            end
            local market, reason =
                state.factionEconomy:faction_market(faction_id)
            if market == nil then
                log_to_console(
                    ar,
                    "FACTION_ECONOMY unavailable reason="
                        .. tostring(reason)
                )
                return true
            end
            local function product_lines(rows)
                local values = {}
                for _, row in ipairs(rows) do
                    local price = row.direction == "sell"
                        and row.exactSellPrice
                        or row.exactProcurementPrice
                    local quantity = row.direction == "sell"
                        and row.exactStockCount
                        or row.exactProcurementQuota
                    table.insert(
                        values,
                        string.format(
                            "%s@%sx%s[%s]",
                            row.productItemId,
                            tostring(price),
                            tostring(quantity),
                            row.effectiveSupplyBand
                        )
                    )
                end
                return table.concat(values, ",")
            end
            log_to_console(ar, string.format(
                "FACTION_ECONOMY_MARKET faction=%s sell=%s procure=%s unresolved=%s",
                faction_id,
                product_lines(market.sell),
                product_lines(market.procure),
                product_lines(market.unresolved)
            ))
        elseif operation == "shop" then
            local faction_id = parts[3]
            if faction_id == nil then
                log_to_console(
                    ar,
                    "USAGE pwft.economy shop <humanFactionId>"
                )
                return true
            end
            local shop, reason =
                state.factionEconomyShops:shop_catalog(faction_id)
            if shop == nil then
                log_to_console(
                    ar,
                    "FACTION_ECONOMY_SHOP unavailable reason="
                        .. tostring(reason)
                )
                return true
            end
            local procurement =
                assert(
                    state.factionEconomyShops
                        :procurement_catalog(faction_id)
                )
            local function catalog_lines(rows, price_key, quantity_key)
                local values = {}
                for _, row in ipairs(rows) do
                    table.insert(
                        values,
                        string.format(
                            "%s@%sx%s[%s]",
                            row.itemId,
                            tostring(row[price_key]),
                            tostring(row[quantity_key]),
                            row.supplyBand
                        )
                    )
                end
                return table.concat(values, ",")
            end
            log_to_console(ar, string.format(
                "FACTION_ECONOMY_SHOP faction=%s character=%s lottery=%s products=%s requested=%s rowsReady=%s rowsEnabled=%s binding=%s settlement=%s",
                faction_id,
                shop.nativeCharacterId,
                shop.lotteryRowName,
                catalog_lines(shop.products, "price", "stock"),
                catalog_lines(
                    procurement.requested,
                    "targetPrice",
                    "quota"
                ),
                tostring(shop.rowsReady),
                tostring(shop.rowsEnabled),
                tostring(shop.nativeShopBindingEnabled),
                procurement.serverSuccessSignalStatus
            ))
        else
            log_to_console(
                ar,
                "USAGE pwft.economy status|faction|shop <humanFactionId>"
            )
        end
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.merchant", function(_, parts, ar)
        if state.rayneMerchant == nil then
            log_to_console(ar, "RAYNE_MERCHANT unavailable")
            return true
        end
        local operation = parts[2] or "status"
        if operation == "status" then
            log_to_console(ar, "RAYNE_MERCHANT " .. state.rayneMerchant:status())
        elseif operation == "respawn" then
            local scheduled = state.rayneMerchant:respawn("console-respawn")
            log_to_console(ar, "RAYNE_MERCHANT_RESPAWN scheduled=" .. tostring(scheduled))
        elseif operation == "traits" then
            local applied, reason = state.rayneMerchant:inject_traits()
            log_to_console(ar, string.format(
                "RAYNE_MERCHANT_TRAITS applied=%s reason=%s",
                tostring(applied),
                tostring(reason or "none")
            ))
        else
            log_to_console(ar, "USAGE pwft.merchant status|respawn|traits")
        end
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.region", function(_, parts, ar)
        if #parts < 2 then
            log_to_console(ar, "USAGE pwft.region <regionId>")
            return true
        end
        local territory = registry.territories[parts[2]]
        if territory == nil then
            log_to_console(ar, "UNKNOWN_REGION " .. tostring(parts[2]))
            return true
        end
        local info = policy.map_info(registry, territory, state.relations, false)
        log_to_console(ar, string.format(
            "REGION id=%s map=%s mask=%s faction=%s controller=%s relation(day)=%s",
            territory.id,
            territory.mapId,
            territory.nativeMaskAsset,
            tostring(info.factionId or "neutral"),
            tostring(info.controllerNameZhHans or "none"),
            info.relation
        ))
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.place", function(_, parts, ar)
        if #parts < 2 then
            log_to_console(ar, "USAGE pwft.place <nativeRegionNameId>")
            return true
        end
        local native_region_name_id = parts[2]
        local presentation = policy.resolve_region_name_presentation(
            registry,
            native_region_name_id,
            state.relations,
            false
        )
        if presentation == nil then
            log_to_console(ar, "PLACE_UNMAPPED nativeRegionNameId=" .. tostring(native_region_name_id))
            return true
        end
        log_to_console(ar, string.format(
            "PLACE nativeRegionNameId=%s territory=%s faction=%s relation=%s color=%s",
            native_region_name_id,
            presentation.territoryId,
            tostring(presentation.factionId or "neutral"),
            presentation.relation,
            presentation.color
        ))
        return true
    end)

    RegisterConsoleCommandGlobalHandler("pwft.danger", function(_, parts, ar)
        if #parts < 2 then
            log_to_console(ar, "USAGE pwft.danger <regionId>")
            return true
        end
        local shown, reason = show_native_danger_warning(config, registry, policy, state, parts[2], "console")
        log_to_console(ar, string.format("DANGER_WARNING region=%s shown=%s reason=%s", tostring(parts[2]), tostring(shown), tostring(reason)))
        return true
    end)
end

local function load_native_territory_overlay_material(state)
    if state.nativeTerritoryOverlayMaterial ~= nil then
        return state.nativeTerritoryOverlayMaterial
    end
    if state.nativeTerritoryOverlayLoadAttempted then
        return nil
    end
    state.nativeTerritoryOverlayLoadAttempted = true

    if type(LoadAsset) ~= "function" then
        log("NATIVE_TERRITORY_OVERLAY_UNAVAILABLE LoadAsset missing")
        return nil
    end

    local ok, material_or_error = pcall(function()
        return LoadAsset(NATIVE_TERRITORY_OVERLAY_MATERIAL_ASSET)
    end)
    if not ok or material_or_error == nil then
        log(string.format(
            "NATIVE_TERRITORY_OVERLAY_LOAD_ERROR path=%s error=%s",
            NATIVE_TERRITORY_OVERLAY_MATERIAL_ASSET,
            tostring(material_or_error)
        ))
        return nil
    end

    state.nativeTerritoryOverlayMaterial = material_or_error
    log(string.format(
        "NATIVE_TERRITORY_OVERLAY_READY path=%s material=%s",
        NATIVE_TERRITORY_OVERLAY_MATERIAL_ASSET,
        safe_full_name(material_or_error)
    ))
    return material_or_error
end

-- The ModActor has a hidden, non-rendering material anchor.  Prefer its
-- already-loaded cooked hard reference over trying to load a loose PAK asset
-- at runtime.  This function only resolves the material; the caller decides
-- whether the live native Image_MapMask is changed.
local function load_native_map_layer_probe_material(state)
    if state.nativeMapLayerProbeMaterial ~= nil then
        return state.nativeMapLayerProbeMaterial
    end
    if state.nativeMapLayerProbeLoadAttempted then
        return nil
    end
    state.nativeMapLayerProbeLoadAttempted = true

    if type(FindAllOf) == "function" then
        local actors_ok, actors_or_error = pcall(function()
            return FindAllOf("ModActor_C")
        end)
        if actors_ok and actors_or_error ~= nil then
            for _, actor in pairs(actors_or_error) do
                if is_valid_object(actor) then
                    local component = safe_property(actor, "PFT_MaterialAnchor")
                        or safe_property(actor, "StaticMesh")
                    if is_valid_object(component) then
                        local material_ok, material_or_error = pcall(function()
                            return component:GetMaterial(0)
                        end)
                        if material_ok and is_valid_object(material_or_error) then
                            state.nativeMapLayerProbeMaterial = material_or_error
                            log(string.format(
                                "NATIVE_MAP_MATERIAL_ANCHOR_READY source=ModActor.GetMaterial actor=%s material=%s",
                                safe_full_name(actor),
                                safe_full_name(material_or_error)
                            ))
                            return material_or_error
                        end
                    end
                end
            end
            log("NATIVE_MAP_MATERIAL_ANCHOR_COMPONENT_NOT_READY source=ModActor")
        end
    end

    if type(FindObject) == "function" then
        local found, material_or_error = pcall(function()
            return FindObject("Material", "M_PFT_IslandGeometryOverlay")
        end)
        if found and is_valid_object(material_or_error) then
            state.nativeMapLayerProbeMaterial = material_or_error
            log(string.format(
                "NATIVE_MAP_MATERIAL_ANCHOR_READY source=FindObject material=%s",
                safe_full_name(material_or_error)
            ))
            return material_or_error
        end
        if found and material_or_error ~= nil then
            log(string.format(
                "NATIVE_MAP_MATERIAL_ANCHOR_CANDIDATE_INVALID source=FindObject raw=%s",
                safe_to_string(material_or_error)
            ))
        end
    end

    if type(LoadAsset) ~= "function" then
        log("NATIVE_MAP_MATERIAL_ANCHOR_MISSING LoadAsset unavailable")
        return nil
    end

    local loaded, material_or_error = pcall(function()
        return LoadAsset(NATIVE_MAP_LAYER_PROBE_MATERIAL_ASSET)
    end)
    if not loaded or material_or_error == nil then
        log(string.format(
            "NATIVE_MAP_MATERIAL_ANCHOR_MISSING path=%s error=%s",
            NATIVE_MAP_LAYER_PROBE_MATERIAL_ASSET,
            tostring(material_or_error)
        ))
        return nil
    end

    if not is_valid_object(material_or_error) then
        log(string.format(
            "NATIVE_MAP_MATERIAL_ANCHOR_CANDIDATE_INVALID source=LoadAsset raw=%s",
            safe_to_string(material_or_error)
        ))
        return nil
    end

    state.nativeMapLayerProbeMaterial = material_or_error
    log(string.format(
            "NATIVE_MAP_MATERIAL_ANCHOR_READY source=LoadAsset path=%s material=%s",
            NATIVE_MAP_LAYER_PROBE_MATERIAL_ASSET,
            safe_full_name(material_or_error)
    ))
    return material_or_error
end

-- The packaged material is intentionally referenced by the generated
-- ModActor component instead of being discovered through the loose PAK asset
-- registry.  F8 logs that direct Blueprint-reference route only; it performs
-- no brush, map, save, or gameplay mutation.
local function inspect_native_map_material_anchor(state)
    if type(FindAllOf) ~= "function" then
        log("NATIVE_MAP_MATERIAL_ANCHOR_PROBE_UNAVAILABLE FindAllOf missing")
        return 0
    end

    local found, actors_or_error = pcall(function()
        return FindAllOf("ModActor_C")
    end)
    if not found or actors_or_error == nil then
        log(string.format(
            "NATIVE_MAP_MATERIAL_ANCHOR_PROBE_UNAVAILABLE actor-scan=%s",
            tostring(actors_or_error)
        ))
        return 0
    end

    local checked = 0
    local component_fields = { "PFT_MaterialAnchor", "StaticMesh" }
    for _, actor in pairs(actors_or_error) do
        if is_valid_object(actor) then
            for _, field_name in ipairs(component_fields) do
                local component_ok, component_or_error = pcall(function()
                    return actor[field_name]
                end)
                if component_ok and is_valid_object(component_or_error) then
                    checked = checked + 1
                    -- UE4SS exposes this build's TArray<UMaterialInterface*>
                    -- as unreadable userdata.  UMeshComponent:GetMaterial is
                    -- the engine accessor for that same serialized override
                    -- slot, so prefer it before attempting array indexing.
                    -- F8 remains read-only: this only asks the hidden anchor
                    -- which material it already owns.
                    local getter_ok, getter_or_error = pcall(function()
                        return component_or_error:GetMaterial(0)
                    end)
                    if getter_ok and is_valid_object(getter_or_error) then
                        state.nativeMapLayerProbeMaterial = getter_or_error
                        log(string.format(
                            "NATIVE_MAP_MATERIAL_ANCHOR_COMPONENT_READY actor=%s component=%s source=GetMaterial index=0 material=%s",
                            safe_full_name(actor),
                            field_name,
                            safe_full_name(getter_or_error)
                        ))
                        return 1
                    end
                    log(string.format(
                        "NATIVE_MAP_MATERIAL_ANCHOR_COMPONENT_GETMATERIAL_RESULT actor=%s component=%s valid=%s raw=%s",
                        safe_full_name(actor),
                        field_name,
                        tostring(getter_ok and is_valid_object(getter_or_error)),
                        safe_to_string(getter_or_error)
                    ))
                    local materials_ok, materials_or_error = pcall(function()
                        return component_or_error.OverrideMaterials
                    end)
                    if materials_ok and materials_or_error ~= nil then
                        for _, index in ipairs({ 0, 1, 2, 3 }) do
                            local material_ok, material_or_error = pcall(function()
                                return materials_or_error[index]
                            end)
                            if material_ok and is_valid_object(material_or_error) then
                                state.nativeMapLayerProbeMaterial = material_or_error
                                log(string.format(
                                    "NATIVE_MAP_MATERIAL_ANCHOR_COMPONENT_READY actor=%s component=%s index=%d material=%s",
                                    safe_full_name(actor),
                                    field_name,
                                    index,
                                    safe_full_name(material_or_error)
                                ))
                                return 1
                            end
                        end
                        log(string.format(
                            "NATIVE_MAP_MATERIAL_ANCHOR_COMPONENT_EMPTY actor=%s component=%s materials=%s",
                            safe_full_name(actor),
                            field_name,
                            safe_to_string(materials_or_error)
                        ))
                    else
                        log(string.format(
                            "NATIVE_MAP_MATERIAL_ANCHOR_COMPONENT_ERROR actor=%s component=%s error=%s",
                            safe_full_name(actor),
                            field_name,
                            tostring(materials_or_error)
                        ))
                    end
                end
            end
        end
    end

    log(string.format("NATIVE_MAP_MATERIAL_ANCHOR_PROBE_DONE components=%d found=false", checked))
    return 0
end

-- Loads only assets that already belong to Palworld's original content.  A
-- failed load is deliberately non-destructive: the function returns nil and
-- the caller keeps the proven no-fog fallback instead of changing any brush.
local function load_native_map_paint_probe_assets(state)
    if state.nativeMapPaintProbeMaterial ~= nil and state.nativeMapPaintProbeTexture ~= nil then
        return state.nativeMapPaintProbeMaterial, state.nativeMapPaintProbeTexture
    end
    if state.nativeMapPaintProbeLoadAttempted then
        return nil, nil
    end
    state.nativeMapPaintProbeLoadAttempted = true

    if type(LoadAsset) ~= "function" then
        log("NATIVE_MAP_PAINT_PROBE_UNAVAILABLE LoadAsset missing")
        return nil, nil
    end

    local material_ok, material_or_error = pcall(function()
        return LoadAsset(NATIVE_WORLD_MAP_MASK_PAINT_MATERIAL_ASSET)
    end)
    if not material_ok or not is_valid_object(material_or_error) then
        log(string.format(
            "NATIVE_MAP_PAINT_PROBE_MATERIAL_ERROR path=%s raw=%s",
            NATIVE_WORLD_MAP_MASK_PAINT_MATERIAL_ASSET,
            safe_to_string(material_or_error)
        ))
        return nil, nil
    end

    local texture_ok, texture_or_error = pcall(function()
        return LoadAsset(NATIVE_WORLD_MAP_MASK_A_TEXTURE_ASSET)
    end)
    if not texture_ok or not is_valid_object(texture_or_error) then
        log(string.format(
            "NATIVE_MAP_PAINT_PROBE_TEXTURE_ERROR path=%s raw=%s",
            NATIVE_WORLD_MAP_MASK_A_TEXTURE_ASSET,
            safe_to_string(texture_or_error)
        ))
        return nil, nil
    end

    state.nativeMapPaintProbeMaterial = material_or_error
    state.nativeMapPaintProbeTexture = texture_or_error
    log(string.format(
        "NATIVE_MAP_PAINT_PROBE_ASSETS_READY material=%s mask=%s",
        safe_full_name(material_or_error),
        safe_full_name(texture_or_error)
    ))
    return material_or_error, texture_or_error
end

-- F9 is a one-region material-contract test, not the final territory system.
-- It changes only the already existing Image_MapMask of the active MW5 map;
-- Image_MapBody is never touched.  The material and the region mask are both
-- native game assets.  If a method call fails, hide this one fog widget so a
-- player remains on the known-good original full-map view.
local function apply_native_map_paint_probe(state)
    local material, mask_texture = load_native_map_paint_probe_assets(state)
    if material == nil or mask_texture == nil then
        -- Asset loading happens before the native-fog helper is declared.
        -- Leave the original widget untouched if this probe cannot load its
        -- own native material inputs; that makes this failure a no-op.
        log("NATIVE_MAP_PAINT_PROBE_NOOP reason=assets-unavailable")
        return 0
    end
    if type(FindAllOf) ~= "function" then
        log("NATIVE_MAP_PAINT_PROBE_UNAVAILABLE FindAllOf missing")
        return 0
    end

    local ok, images = pcall(function()
        return FindAllOf("Image")
    end)
    if not ok or images == nil then
        log("NATIVE_MAP_PAINT_PROBE_UNAVAILABLE Image scan failed")
        return 0
    end

    local changed = 0
    for _, image in pairs(images) do
        if is_valid_object(image) then
            local full_name = safe_full_name(image)
            local is_main_world_mask = string.find(full_name, ".WBP_Map_Body_MW5.", 1, true) ~= nil
                and string.find(full_name, ".Image_MapMask", 1, true) ~= nil
            if is_main_world_mask then
                local applied, dynamic_or_error = pcall(function()
                    image:SetBrushFromMaterial(material)
                    local dynamic_material = image:GetDynamicMaterial()
                    if not is_valid_object(dynamic_material) then
                        error("GetDynamicMaterial returned invalid object")
                    end
                    -- These exact names were verified live against
                    -- Palworld's native mask-paint material.  This probe is
                    -- disabled in normal operation; preserve its known-good
                    -- contract for future read-only diagnostics.
                    dynamic_material:SetTextureParameterValue(FName("MaskTexture"), mask_texture)
                    dynamic_material:SetVectorParameterValue(FName("SelectionColor"), {
                        R = 0.92,
                        G = 0.05,
                        B = 0.05,
                        A = 0.42,
                    })
                    pcall(function()
                        log(string.format(
                            "NATIVE_MAP_PAINT_PROBE_READBACK mask=%s",
                            safe_full_name(dynamic_material:K2_GetTextureParameterValue(FName("MaskTexture")))
                        ))
                    end)
                    image:SetOpacity(1.0)
                    image:SetVisibility(0) -- ESlateVisibility::Visible
                    return dynamic_material
                end)
                if applied then
                    changed = changed + 1
                    state.nativeMapPaintProbeCount = state.nativeMapPaintProbeCount + 1
                    log(string.format(
                        "NATIVE_MAP_PAINT_PROBE_APPLIED count=%d image=%s material=%s mask=%s dynamic=%s",
                        state.nativeMapPaintProbeCount,
                        full_name,
                        safe_full_name(material),
                        safe_full_name(mask_texture),
                        safe_full_name(dynamic_or_error)
                    ))
                else
                    -- Do not leave an unsupported brush above the map.
                    pcall(function()
                        image:SetVisibility(2) -- ESlateVisibility::Hidden
                    end)
                    log(string.format(
                        "NATIVE_MAP_PAINT_PROBE_ERROR image=%s error=%s fallback=hidden-mask",
                        full_name,
                        tostring(dynamic_or_error)
                    ))
                end
            end
        end
    end

    log(string.format("NATIVE_MAP_PAINT_PROBE_DONE changed=%d", changed))
    return changed
end

-- This deliberately touches only the Slate visibility of the transient
-- Image_MapMask widgets which the game has already created for an open map.
-- It does not call unlock APIs, alter RT_WorldMapMask, change fast travel, or
-- persist any exploration result.  Using the original Image_MapBody keeps the
-- game's pan, zoom, map art, icons, and interactions intact.
local function hide_active_native_map_masks(state)
    if type(FindAllOf) ~= "function" then
        log("NATIVE_FOG_OVERRIDE_UNAVAILABLE FindAllOf missing")
        return 0
    end

    local ok, images = pcall(function()
        return FindAllOf("Image")
    end)
    if not ok or images == nil then
        log("NATIVE_FOG_OVERRIDE_UNAVAILABLE Image scan failed")
        return 0
    end

    local changed = 0
    for _, image in pairs(images) do
        if is_valid_object(image) then
            local full_name = safe_full_name(image)
            local is_native_map_body = string.find(full_name, ".WBP_Map_Body_", 1, true) ~= nil
                and string.find(full_name, ".Image_MapBody", 1, true) ~= nil
            local is_native_map_mask = string.find(full_name, ".WBP_Map_Body_", 1, true) ~= nil
                and string.find(full_name, ".Image_MapMask", 1, true) ~= nil
            if is_native_map_body then
                -- The real terrain image is a separate native widget under
                -- the same transform as Image_MapMask.  Read it here so the
                -- territory layer can be anchored above the actual game map,
                -- rather than substituting a standalone approximation.
                local body_brush = safe_property(image, "Brush")
                log(string.format(
                    "NATIVE_MAP_BODY_DIAGNOSTIC image=%s brush=%s resource=%s",
                    full_name,
                    safe_to_string(body_brush),
                    safe_full_name(safe_property(body_brush, "ResourceObject"))
                ))
            end
            if is_native_map_mask then
                -- Diagnostic only: capture the native Slate brush before it is
                -- hidden.  This is intentionally a property read, not a brush
                -- mutation, so it cannot affect exploration, map state, or the
                -- currently proven no-fog fallback.  The result tells us which
                -- native render-target/material contract must be preserved for
                -- later territory colouring.
                local native_brush = safe_property(image, "Brush")
                local native_resource = safe_property(native_brush, "ResourceObject")
                log(string.format(
                    "NATIVE_MASK_BRUSH_DIAGNOSTIC image=%s brush=%s resource=%s %s",
                    full_name,
                    safe_to_string(native_brush),
                    safe_full_name(native_resource),
                    describe_native_mask_material(native_resource)
                ))
                -- ESlateVisibility::Hidden is 2.  Calling this reflected
                -- UWidget method is a visual operation only; unlike the
                -- previous failed experiment, it creates no UMG object and
                -- does not send a FName/UFunction construction payload.
                local applied, error_message = pcall(function()
                    image:SetVisibility(2)
                end)
                if applied then
                    changed = changed + 1
                    state.nativeFogOverrideCount = state.nativeFogOverrideCount + 1
                    log(string.format(
                        "NATIVE_FOG_OVERRIDE_APPLIED count=%d image=%s visibility=Hidden",
                        state.nativeFogOverrideCount,
                        full_name
                    ))
                else
                    log(string.format(
                        "NATIVE_FOG_OVERRIDE_ERROR image=%s error=%s",
                        full_name,
                        tostring(error_message)
                    ))
                end
            end
        end
    end

    log(string.format("NATIVE_FOG_OVERRIDE_DONE changed=%d", changed))
    return changed
end

-- J is a deliberately narrow material-contract probe for the main world map.
-- It never creates UMG, changes exploration, writes a save, changes a PAK, or
-- uses legacy PNG terrain.  It first preserves the known-good postgame no-fog
-- view, then rebinds only Image_MapBody to a material whose BaseMapTexture is
-- the Image_MapBody's existing native T_WorldMap resource.  If an engine
-- update rejects this external brush contract, closing and reopening M makes
-- Palworld recreate the untouched native widget; N remains the safe fallback.
local function apply_native_map_layer_probe(state)
    local material = load_native_map_layer_probe_material(state)
    if material == nil then
        log("NATIVE_MAP_LAYER_PROBE_FALLBACK_FOG_HIDDEN")
        return hide_active_native_map_masks(state)
    end

    hide_active_native_map_masks(state)

    if type(FindAllOf) ~= "function" then
        log("NATIVE_MAP_LAYER_PROBE_UNAVAILABLE FindAllOf missing")
        return 0
    end

    local ok, images = pcall(function()
        return FindAllOf("Image")
    end)
    if not ok or images == nil then
        log("NATIVE_MAP_LAYER_PROBE_UNAVAILABLE Image scan failed")
        return 0
    end

    local changed = 0
    for _, image in pairs(images) do
        if is_valid_object(image) then
            local full_name = safe_full_name(image)
            local is_main_world_body = string.find(full_name, ".WBP_Map_Body_MW5.", 1, true) ~= nil
                and string.find(full_name, ".Image_MapBody", 1, true) ~= nil
            if is_main_world_body then
                local original_brush = safe_property(image, "Brush")
                local original_texture = safe_property(original_brush, "ResourceObject")
                if original_texture == nil then
                    log(string.format(
                        "NATIVE_MAP_LAYER_PROBE_SKIPPED image=%s reason=no-original-resource",
                        full_name
                    ))
                else
                    local applied, dynamic_or_error = pcall(function()
                        image:SetBrushFromMaterial(material)
                        local dynamic_material = image:GetDynamicMaterial()
                        if dynamic_material == nil then
                            error("GetDynamicMaterial returned nil")
                        end
                        dynamic_material:SetTextureParameterValue(FName("BaseMapTexture"), original_texture)
                        image:SetOpacity(1.0)
                        image:SetVisibility(0) -- ESlateVisibility::Visible
                        return dynamic_material
                    end)
                    if applied then
                        changed = changed + 1
                        state.nativeMapLayerProbeCount = state.nativeMapLayerProbeCount + 1
                        log(string.format(
                            "NATIVE_MAP_LAYER_PROBE_APPLIED count=%d image=%s source=%s dynamic=%s",
                            state.nativeMapLayerProbeCount,
                            full_name,
                            safe_full_name(original_texture),
                            safe_full_name(dynamic_or_error)
                        ))
                    else
                        log(string.format(
                            "NATIVE_MAP_LAYER_PROBE_ERROR image=%s error=%s recovery=close-and-reopen-M",
                            full_name,
                            tostring(dynamic_or_error)
                        ))
                    end
                end
            end
        end
    end

    log(string.format("NATIVE_MAP_LAYER_PROBE_DONE changed=%d", changed))
    return changed
end

local function hex_to_linear_color(hex, alpha)
    assert(type(hex) == "string" and string.match(hex, "^#%x%x%x%x%x%x$"), "invalid palette colour")
    return {
        R = tonumber(string.sub(hex, 2, 3), 16) / 255.0,
        G = tonumber(string.sub(hex, 4, 5), 16) / 255.0,
        B = tonumber(string.sub(hex, 6, 7), 16) / 255.0,
        A = alpha == nil and 1.0 or alpha,
    }
end

-- Reuse Image_MapMask rather than adding a second map, replacing no terrain
-- or gameplay widget.  Its transform is already exactly aligned with
-- Image_MapBody, so the coast-aligned island masks follow Palworld's own pan
-- and zoom. Failure always hides this layer and leaves the original map usable.
local function apply_native_faction_map_overlay(registry, policy, state)
    if state.enableNativeTerritoryMaterialOverlay ~= true then
        log("NATIVE_FACTION_MAP_DISABLED fallback=hide-native-fog")
        return hide_active_native_map_masks(state)
    end

    local material = load_native_map_layer_probe_material(state)
    if material == nil then
        log("NATIVE_FACTION_MAP_FALLBACK reason=material-unavailable action=hide-native-fog")
        return hide_active_native_map_masks(state)
    end
    log(string.format(
        "NATIVE_FACTION_PACKED_MASKS_READY packs=5 islands=%d source=Mod-owned-T_WorldMap-coastline mode=%s",
        #registry.islandOrder,
        state.mapMode
    ))

    if type(FindAllOf) ~= "function" then
        log("NATIVE_FACTION_MAP_UNAVAILABLE FindAllOf missing")
        return 0
    end

    local ok, images = pcall(function()
        return FindAllOf("Image")
    end)
    if not ok or images == nil then
        log("NATIVE_FACTION_MAP_UNAVAILABLE Image scan failed")
        return 0
    end

    local changed = 0
    for _, image in pairs(images) do
        if is_valid_object(image) then
            local full_name = safe_full_name(image)
            local is_native_map_mask = string.find(full_name, ".WBP_Map_Body_", 1, true) ~= nil
                and string.find(full_name, ".Image_MapMask", 1, true) ~= nil
            if is_native_map_mask then
                local applied, dynamic_or_error = pcall(function()
                    image:SetBrushFromMaterial(material)
                    local dynamic_material = image:GetDynamicMaterial()
                    if not is_valid_object(dynamic_material) then
                        error("GetDynamicMaterial returned invalid object")
                    end
                    for index = 1, 20 do
                        local suffix = string.format("%02d", index)
                        local island_id = registry.islandOrder[index]
                        local colour = hex_to_linear_color(registry.palette.Locked, 1.0)
                        local visibility = 0.0
                        if island_id ~= nil then
                            local island = registry.islands[island_id]
                            local presentation = policy.resolve_island_presentation(
                                registry,
                                island,
                                state.mapMode,
                                state.relations,
                                false
                            )
                            if presentation.visible then
                                colour = hex_to_linear_color(presentation.color, 1.0)
                                visibility = 1.0
                            end
                        end
                        dynamic_material:SetVectorParameterValue(FName("Color_" .. suffix), colour)
                        dynamic_material:SetScalarParameterValue(FName("Visibility_" .. suffix), visibility)
                    end
                    dynamic_material:SetScalarParameterValue(FName("OverlayOpacity"), FACTION_OVERLAY_OPACITY)
                    -- A single global border would reveal islands that are
                    -- unowned in the active layer, so coastlines are expressed
                    -- only by the visible colour fill.
                    dynamic_material:SetScalarParameterValue(FName("BorderOpacity"), 0.0)
                    -- Read back one hostile and one friendly parameter without
                    -- changing the map.  This distinguishes a material channel
                    -- problem from a UE4SS parameter-marshalling problem.
                    pcall(function()
                        local first_colour = dynamic_material:K2_GetVectorParameterValue(FName("Color_01"))
                        local second_colour = dynamic_material:K2_GetVectorParameterValue(FName("Color_02"))
                        local first_visibility = dynamic_material:K2_GetScalarParameterValue(FName("Visibility_01"))
                        local second_visibility = dynamic_material:K2_GetScalarParameterValue(FName("Visibility_02"))
                        log(string.format(
                            "NATIVE_FACTION_MAP_PARAM_READBACK c01=(%s,%s,%s,%s) c02=(%s,%s,%s,%s) v01=%s v02=%s",
                            safe_to_string(safe_property(first_colour, "R")),
                            safe_to_string(safe_property(first_colour, "G")),
                            safe_to_string(safe_property(first_colour, "B")),
                            safe_to_string(safe_property(first_colour, "A")),
                            safe_to_string(safe_property(second_colour, "R")),
                            safe_to_string(safe_property(second_colour, "G")),
                            safe_to_string(safe_property(second_colour, "B")),
                            safe_to_string(safe_property(second_colour, "A")),
                            safe_to_string(first_visibility),
                            safe_to_string(second_visibility)
                        ))
                    end)
                    image:SetOpacity(1.0)
                    image:SetVisibility(0) -- ESlateVisibility::Visible
                    return dynamic_material
                end)
                if applied then
                    changed = changed + 1
                    state.nativeFactionMapOverlayCount = state.nativeFactionMapOverlayCount + 1
                    log(string.format(
                        "NATIVE_FACTION_MAP_APPLIED count=%d mode=%s islands=%d opacity=%.2f image=%s dynamic=%s",
                        state.nativeFactionMapOverlayCount,
                        state.mapMode,
                        #registry.islandOrder,
                        FACTION_OVERLAY_OPACITY,
                        full_name,
                        safe_full_name(dynamic_or_error)
                    ))
                else
                    -- A bad external brush must never block the real map.
                    pcall(function()
                        image:SetVisibility(2) -- ESlateVisibility::Hidden
                    end)
                    log(string.format(
                        "NATIVE_FACTION_MAP_ERROR image=%s error=%s fallback=hidden-mask",
                        full_name,
                        tostring(dynamic_or_error)
                    ))
                end
            end
        end
    end

    log(string.format("NATIVE_FACTION_MAP_DONE changed=%d", changed))
    return changed
end

local function run_native_map_fast_travel_icon_probe(config)
    if type(FindAllOf) ~= "function" then
        log("MAP_ICON_CLICK_PROBE_UNAVAILABLE reason=FindAllOf-missing")
        return false
    end

    local target_fast_travel_id = config.mapFastTravelSelectionProbeTarget
    if type(target_fast_travel_id) ~= "string" or target_fast_travel_id == "" then
        log("MAP_ICON_CLICK_PROBE_UNAVAILABLE reason=target-missing")
        return false
    end

    local ok, icons = pcall(function()
        return FindAllOf("WBP_Map_IconFTTower_C")
    end)
    if not ok or icons == nil then
        log("MAP_ICON_CLICK_PROBE_UNAVAILABLE reason=icons-not-live")
        return false
    end

    for _, icon in pairs(icons) do
        if is_valid_object(icon) then
            local fast_travel_id = safe_to_string(safe_property(icon, "Fast Travel Point ID"))
            if fast_travel_id == target_fast_travel_id then
                -- Call the existing icon's own Blueprint handler.  This is
                -- deliberately the same route that reaches WBP_Map_Base's
                -- On Icon Clicked event; it does not invoke FastTravel or
                -- confirm Palworld's dialog.
                local clicked, click_error = pcall(function()
                    return icon:ClickEvent()
                end)
                log(string.format(
                    "MAP_ICON_CLICK_PROBE target=%s clicked=%s error=%s",
                    fast_travel_id,
                    tostring(clicked),
                    tostring(click_error or "none")
                ))
                return clicked
            end
        end
    end

    log("MAP_ICON_CLICK_PROBE_UNAVAILABLE reason=target-icon-not-live target=" .. target_fast_travel_id)
    return false
end

local function register_native_map_keybinds(config, registry, policy, state)
    if config.enableNativeFogVisualOverride ~= true then
        log("NATIVE_FOG_OVERRIDE_DISABLED config=false")
        return
    end
    if type(RegisterKeyBind) ~= "function" then
        log("NATIVE_FOG_OVERRIDE_UNAVAILABLE RegisterKeyBind missing")
        return
    end

    local callback = function()
        local apply = function()
            if state.mapMode == "Original" then
                state.mapMode = "Human"
                local applied = apply_native_faction_map_overlay(registry, policy, state)
                log(string.format("NATIVE_FACTION_MAP_MODE mode=Human changed=%d", applied))
            elseif state.mapMode == "Human" then
                state.mapMode = "Pal"
                local applied = apply_native_faction_map_overlay(registry, policy, state)
                log(string.format("NATIVE_FACTION_MAP_MODE mode=Pal changed=%d", applied))
            else
                state.mapMode = "Original"
                local hidden = hide_active_native_map_masks(state)
                log(string.format("NATIVE_FACTION_MAP_MODE mode=Original changed=%d", hidden))
            end
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(apply)
        else
            apply()
        end
    end
    state.callbacks.nativeMapFogOverride = callback
    RegisterKeyBind(Key.N, callback)
    log("NATIVE_FACTION_MAP_KEY_READY key=N behaviour=Original->Human->Pal->Original scope=native-map-open-only")

    if config.enableDangerAreaWarningProbe == true then
        local warning_probe_callback = function()
            local present = function()
                -- M-A is a deliberately hostile, frozen assignment and is
                -- used only to validate that the native generic HUD warning
                -- is visible.  It does not teleport, move, or alter a save.
                show_native_danger_warning(config, registry, policy, state, "M-A", "F10-native-warning-probe")
            end
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(present)
            else
                present()
            end
        end
        state.callbacks.dangerAreaWarningProbe = warning_probe_callback
        RegisterKeyBind(Key.F10, warning_probe_callback)
        log("DANGER_WARNING_PROBE_KEY_READY key=F10 scope=native-common-warning")
    else
        log("DANGER_WARNING_PROBE_DISABLED config=false")
    end

    if config.enableMapFastTravelSelectionProbe == true then
        local map_icon_probe_callback = function()
            local trigger = function()
                run_native_map_fast_travel_icon_probe(config)
            end
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(trigger)
            else
                trigger()
            end
        end
        state.callbacks.mapFastTravelSelectionProbe = map_icon_probe_callback
        RegisterKeyBind(Key.F7, map_icon_probe_callback)
        log("MAP_ICON_CLICK_PROBE_KEY_READY key=F7 scope=requires-native-map-open")
    else
        log("MAP_ICON_CLICK_PROBE_DISABLED config=false")
    end

    -- The direct replacement probe is intentionally not bound.  The live
    -- validation showed that it replaces the cached native Image_MapBody
    -- brush even when its packaged material cannot be loaded.  Keep the
    -- function only as diagnostic history; a future overlay must be a new
    -- transparent sibling layer and must never replace Image_MapBody.
    log("NATIVE_MAP_LAYER_PROBE_DISABLED reason=do-not-replace-native-map-body")

    if config.enableNativeMapMaterialAnchorProbe == true then
        local anchor_probe_callback = function()
            local inspect = function()
                inspect_native_map_material_anchor(state)
            end
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(inspect)
            else
                inspect()
            end
        end
        state.callbacks.nativeMapMaterialAnchorProbe = anchor_probe_callback
        RegisterKeyBind(Key.F8, anchor_probe_callback)
        log("NATIVE_MAP_MATERIAL_ANCHOR_PROBE_KEY_READY key=F8 scope=read-only")
    else
        log("NATIVE_MAP_MATERIAL_ANCHOR_PROBE_DISABLED config=false")
    end

    if config.enableNativeMapPaintProbe == true then
        local probe_callback = function()
            local apply = function()
                apply_native_map_paint_probe(state)
            end
            if type(ExecuteInGameThread) == "function" then
                ExecuteInGameThread(apply)
            else
                apply()
            end
        end
        state.callbacks.nativeMapPaintProbe = probe_callback
        RegisterKeyBind(Key.F9, probe_callback)
        log("NATIVE_MAP_PAINT_PROBE_KEY_READY key=F9 scope=native-MW5-map-only")
    else
        log("NATIVE_MAP_PAINT_PROBE_DISABLED config=false")
    end
end

local function describe_soft_object_path(value)
    if value == nil then
        return "value=<nil>"
    end

    -- TSoftObjectPtr is returned by this Palworld/UE4SS build as userdata,
    -- rather than as the path string suggested by the generated annotation.
    -- Only read candidate reflected fields here.  Calling Get or
    -- LoadSynchronous may resolve/load an asset and is deliberately excluded
    -- from Mod 0's read-only probe.
    local fields = { "AssetPath", "AssetPathName", "PackageName", "LongPackageName", "Path", "SubPathString" }
    local parts = {
        "luaType=" .. type(value),
        "rendered=" .. safe_to_string(value),
    }
    for _, field_name in ipairs(fields) do
        local field_value = safe_property(value, field_name)
        if field_value ~= nil then
            table.insert(parts, field_name .. "=" .. safe_to_string(field_value))
        end
    end
    return table.concat(parts, " ")
end

-- UE4SS represents a reflected TSoftObjectPtr as userdata on this Palworld
-- build, so tostring() only exposes its address.  The engine's own conversion
-- library accepts that reflected value directly and returns the stable asset
-- path without loading the asset.  This lets the entry-operation route bind a
-- native fast-travel destination to the same map-mask territory used by the
-- visual faction layer.
local function soft_object_reference_to_string(value)
    if value == nil or type(StaticFindObject) ~= "function" then
        return nil
    end
    local found, system_library = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end)
    if not found or not is_valid_object(system_library) then
        return nil
    end
    local converted, path = pcall(function()
        return system_library:Conv_SoftObjectReferenceToString(value)
    end)
    if not converted or path == nil then
        return nil
    end
    local path_string = safe_to_string(path)
    if path_string == "" or path_string == "None" or path_string == "<nil>" then
        return nil
    end
    return path_string
end

local function scan_tower_bindings(config, registry, state)
    if type(FindAllOf) ~= "function" then
        log("TOWER_SCAN_UNAVAILABLE FindAllOf missing")
        return
    end
    local ok, towers = pcall(function()
        return FindAllOf("PalLevelObjectUnlockableFastTravelPoint")
    end)
    if not ok or towers == nil then
        log("TOWER_SCAN_EMPTY")
        return
    end

    for _, tower in pairs(towers) do
        if is_valid_object(tower) then
            local fast_travel_id = safe_to_string(safe_property(tower, "FastTravelPointID"))
            local soft_mask = safe_property(tower, "SoftUnlockMapMaskTexture")
            local mask_value = soft_object_reference_to_string(soft_mask) or safe_to_string(soft_mask)
            local native_tower_id = registry.watchtowerByFastTravelId[fast_travel_id]
            local region_id = nil
            for mask_asset, candidate_region_id in pairs(registry.maskToRegion) do
                if string.find(mask_value, mask_asset, 1, true) ~= nil then
                    region_id = candidate_region_id
                    break
                end
            end
            local island_id = region_id ~= nil and registry.regionToIsland[region_id] or nil
            if island_id ~= nil and fast_travel_id ~= "<nil>" and fast_travel_id ~= "None" then
                state.fastTravelToIsland[fast_travel_id] = island_id
            end
            state.towerProbeCount = state.towerProbeCount + 1
            log(string.format(
                "TOWER_BINDING actor=%s fastTravelId=%s nativeTowerId=%s mask=%s region=%s island=%s",
                safe_full_name(tower),
                fast_travel_id,
                tostring(native_tower_id or "unresolved"),
                mask_value,
                tostring(region_id or "unresolved"),
                tostring(island_id or "unowned")
            ))
            if config.enableSoftMaskPathProbe and native_tower_id ~= nil then
                state.softMaskProbeCount = state.softMaskProbeCount + 1
                log(string.format(
                    "SOFT_MASK_PROBE count=%d fastTravelId=%s nativeTowerId=%s %s",
                    state.softMaskProbeCount,
                    fast_travel_id,
                    native_tower_id,
                    describe_soft_object_path(soft_mask)
                ))
            end
        end
    end
end

local function find_local_player_transform()
    local controllers = {}
    local seen = {}
    local function append_controller(controller)
        if is_valid_object(controller) then
            local key = safe_full_name(controller)
            if seen[key] ~= true then
                seen[key] = true
                table.insert(controllers, controller)
            end
        end
    end

    -- Prefer the same local-player routes already proven by progression and
    -- settlement runtime. FindAllOf can retain a stale controller across a
    -- fast-travel/world-partition transition even though FindFirstOf and
    -- UEHelpers already expose the new local pawn.
    if UEHelpers ~= nil
        and type(UEHelpers.GetPlayerController) == "function" then
        pcall(function()
            append_controller(UEHelpers.GetPlayerController())
        end)
    end
    if type(FindFirstOf) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController",
            "PalPlayerController_C",
            "PlayerController",
        }) do
            local ok, controller = pcall(FindFirstOf, class_name)
            if ok then
                append_controller(controller)
            end
        end
    end
    if type(FindAllOf) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController",
            "PlayerController",
        }) do
            local ok, found = pcall(FindAllOf, class_name)
            if ok and type(found) == "table" then
                for _, controller in pairs(found) do
                    append_controller(controller)
                end
            end
        end
    end

    for _, controller in ipairs(controllers) do
                    local local_ok, is_local = pcall(function()
                        if controller.IsLocalPlayerController ~= nil then
                            return controller:IsLocalPlayerController()
                        end
                        return true
                    end)
                    if local_ok and is_local then
                        local pawn = safe_property(controller, "Pawn")
                        if not is_valid_object(pawn) then
                            pawn = safe_property(
                                controller,
                                "AcknowledgedPawn"
                            )
                        end
                        if is_valid_object(pawn) then
                            local location_ok, location = pcall(function()
                                return pawn:K2_GetActorLocation()
                            end)
                            local rotation_ok, rotation = pcall(function()
                                return pawn:K2_GetActorRotation()
                            end)
                            if location_ok and rotation_ok
                                and location ~= nil
                                and rotation ~= nil then
                                return {
                                    X = tonumber(safe_property(location, "X")),
                                    Y = tonumber(safe_property(location, "Y")),
                                    Z = tonumber(safe_property(location, "Z")),
                                }, {
                                    Pitch = tonumber(safe_property(rotation, "Pitch")) or 0,
                                    Yaw = tonumber(safe_property(rotation, "Yaw")) or 0,
                                    Roll = tonumber(safe_property(rotation, "Roll")) or 0,
                                }, nil, pawn
                            end
                        end
                    end
    end
    return nil, nil, "local-player-transform-unavailable"
end

local function resolve_economy_merchant_live_root(state)
    local presence = state.factionEconomyMerchantPresence
    if presence == nil or type(FindAllOf) ~= "function" then
        return nil, "merchant-presence-ftpoint-scan-unavailable"
    end
    local player_location, _, player_error, player_pawn =
        find_local_player_transform()
    if not is_valid_object(player_pawn) then
        return nil, player_error or "merchant-presence-player-unavailable"
    end
    local target_id = state.runtimeRegistry.commerce.merchantIsland
        .selectionDecision.referenceFastTravelPointId
    local merchant_island = state.runtimeRegistry.commerce.merchantIsland
    local reference_location = merchant_island.selectionDecision
        .referenceWorldLocation
    local accepted_root = merchant_island.rootLocation
    local root_offset = {
        X = accepted_root.X - reference_location.X,
        Y = accepted_root.Y - reference_location.Y,
        Z = accepted_root.Z - reference_location.Z,
    }
    -- Prefer PalLocationPointFastTravel. Its GetLocation result is the same
    -- runtime coordinate used by the game's fast-travel UI. Level-object
    -- tower actors expose persistent-map coordinates and are only a fallback
    -- for confirming that FTPoint90's partition is loaded.
    local partition_marker = nil
    for _, class_name in ipairs({
        "PalLocationPointFastTravel",
        "BP_LevelObject_TowerFastTravelPoint_C",
        "BP_MapObject_TowerFastTravelPoint_C",
    }) do
        local ok, candidates = pcall(FindAllOf, class_name)
        if ok and type(candidates) == "table" then
            for _, candidate in pairs(candidates) do
                if is_valid_object(candidate)
                    and safe_to_string(safe_property(
                        candidate,
                        "FastTravelPointID"
                    )) == target_id then
                    partition_marker = candidate
                    local is_location_point = class_name
                        == "PalLocationPointFastTravel"
                    local location_ok, location = pcall(function()
                        if is_location_point then
                            return candidate:GetLocation()
                        end
                        return candidate:K2_GetActorLocation()
                    end)
                    if location_ok and location ~= nil and is_location_point then
                        -- PalLocationPoint:GetLocation is the coordinate route
                        -- used by Palworld's own fast-travel UI.  Unlike the
                        -- level-object actor transform, it is already in the
                        -- same runtime space as the local player pawn.
                        local live_anchor = {
                            X = tonumber(safe_property(location, "X")),
                            Y = tonumber(safe_property(location, "Y")),
                            Z = tonumber(safe_property(location, "Z")),
                        }
                        local live_location = {
                            X = live_anchor.X + root_offset.X,
                            Y = live_anchor.Y + root_offset.Y,
                            Z = live_anchor.Z + root_offset.Z,
                        }
                        local coordinate_gap = math.sqrt(
                            (live_anchor.X - player_location.X) ^ 2
                                + (live_anchor.Y - player_location.Y) ^ 2
                                + (live_anchor.Z - player_location.Z) ^ 2
                        )
                        -- World-origin rebasing is translational. Preserve the
                        -- accepted merchant-facing yaw and only translate the
                        -- FTPoint90-to-market offset into the live partition.
                        local live_rotation = merchant_island.rootRotation
                        -- Build 24575825 can expose PalLocationPoint in the
                        -- persistent-map coordinate space while the pawn is in
                        -- a world-partition-local space. Accept it only when
                        -- both are plausibly co-located; otherwise fall through
                        -- to the partition-presence calibration below.
                        local updated = coordinate_gap <= 50000 and
                            presence:set_live_root(
                                live_location,
                                live_rotation,
                                class_name .. ":" .. target_id
                            ) or nil
                        if updated ~= nil and updated.ok then
                            log(string.format(
                                "ECONOMY_MERCHANT_PRESENCE_LIVE_ROOT fastTravelId=%s actor=%s anchor=(%s,%s,%s) root=(%s,%s,%s) yaw=%s coordinateRoute=PalLocationPoint.GetLocation",
                                target_id,
                                safe_full_name(candidate),
                                tostring(live_anchor.X),
                                tostring(live_anchor.Y),
                                tostring(live_anchor.Z),
                                tostring(live_location.X),
                                tostring(live_location.Y),
                                tostring(live_location.Z),
                                tostring(live_rotation.Yaw)
                            ))
                            return live_location, nil
                        end
                    end
                end
            end
        end
    end
    if partition_marker ~= nil and type(player_location) == "table" then
        -- Seeing FTPoint90 proves its world partition is resident. The user
        -- arrives beside the tower, so translate the already accepted
        -- tower-to-market offset into the pawn's live coordinate space. This
        -- deliberately preserves the simple fixed market while avoiding
        -- fragile NPC navigation or persistent-coordinate assumptions.
        local live_location = {
            X = player_location.X + root_offset.X,
            Y = player_location.Y + root_offset.Y,
            Z = player_location.Z + root_offset.Z,
        }
        local live_rotation = merchant_island.rootRotation
        local updated = presence:set_live_root(
            live_location,
            live_rotation,
            "partition-loaded-player-calibration:" .. target_id
        )
        if updated.ok then
            log(string.format(
                "ECONOMY_MERCHANT_PRESENCE_LIVE_ROOT fastTravelId=%s actor=%s anchor=(%s,%s,%s) root=(%s,%s,%s) yaw=%s coordinateRoute=partition-loaded-player-calibration",
                target_id,
                safe_full_name(partition_marker),
                tostring(player_location.X),
                tostring(player_location.Y),
                tostring(player_location.Z),
                tostring(live_location.X),
                tostring(live_location.Y),
                tostring(live_location.Z),
                tostring(live_rotation.Yaw)
            ))
            return live_location, nil
        end
    end
    return nil, "merchant-presence-ftpoint-not-loaded"
end

local function schedule_economy_merchant_presence_poll(state, generation)
    local presence = state.factionEconomyMerchantPresence
    if presence == nil or presence.enabled ~= true then
        return
    end
    local use_loop_async = type(LoopAsync) == "function"
    if (not use_loop_async and type(ExecuteWithDelay) ~= "function")
        or type(ExecuteInGameThread) ~= "function" then
        log("ECONOMY_MERCHANT_PRESENCE_UNAVAILABLE scheduler-api")
        return
    end
    local callback = function()
        -- LoopAsync owns the durable clock on UE4SS' async thread.  Recursive
        -- ExecuteWithDelay calls made from an ExecuteInGameThread callback can
        -- silently stop after the first hop on the live Palworld build.
        if presence.generation ~= generation then
            return true
        end
        ExecuteInGameThread(function()
            if presence.generation ~= generation then
                return
            end
            if presence.liveRootSource == nil then
                -- World-partition actors do not always exist when the load-map
                -- callback first fires.  Keep resolving FTPoint90 until its
                -- live, world-origin-rebased transform becomes available.
                resolve_economy_merchant_live_root(state)
            end
            local player_location, _, player_error =
                find_local_player_transform()
            local previous_reason = presence.lastReason
            local outcome = presence:tick(player_location)
            local status = presence:status()
            if status.tickCount <= 5
                or outcome.reason ~= previous_reason
                or outcome.transitioned == true
                or outcome.reason == "economy-market-runtime-disabled"
                or outcome.reason == "economy-merchant-spawn-failed" then
                log(string.format(
                    "ECONOMY_MERCHANT_PRESENCE_POLL tick=%d ok=%s reason=%s player=(%s,%s,%s) distance=%s active=%d pending=%d generation=%d transitioned=%s playerError=%s",
                    status.tickCount,
                    tostring(outcome.ok),
                    tostring(outcome.reason),
                    tostring(player_location and player_location.X or "none"),
                    tostring(player_location and player_location.Y or "none"),
                    tostring(player_location and player_location.Z or "none"),
                    tostring(outcome.distance or "none"),
                    status.activeCount,
                    status.pendingCount,
                    generation,
                    tostring(outcome.transitioned == true),
                    tostring(player_error or "none")
                ))
            end
            if not use_loop_async
                and presence.generation == generation then
                schedule_economy_merchant_presence_poll(
                    state,
                    generation
                )
            end
        end)
        return false
    end
    state.callbacks.economyMerchantPresencePoll = callback
    if use_loop_async then
        LoopAsync(presence.pollIntervalMs, callback)
        log(string.format(
            "ECONOMY_MERCHANT_PRESENCE_SCHEDULER_READY mode=LoopAsync generation=%d intervalMs=%d",
            generation,
            presence.pollIntervalMs
        ))
    else
        ExecuteWithDelay(presence.pollIntervalMs, callback)
        log(string.format(
            "ECONOMY_MERCHANT_PRESENCE_SCHEDULER_READY mode=ExecuteWithDelay-fallback generation=%d intervalMs=%d",
            generation,
            presence.pollIntervalMs
        ))
    end
end

local function start_economy_merchant_presence(
    config,
    state,
    source
)
    local presence = state.factionEconomyMerchantPresence
    if presence == nil or presence.enabled ~= true then
        log("ECONOMY_MERCHANT_PRESENCE_DISABLED config=false")
        return
    end
    local loaded = presence:on_world_loaded(source)
    resolve_economy_merchant_live_root(state)
    log(string.format(
        "ECONOMY_MERCHANT_PRESENCE_WORLD_READY source=%s generation=%d activationRadius=%d deactivationRadius=%d pollIntervalMs=%d cleanup=%s",
        tostring(source or "unknown"),
        loaded.generation,
        presence.activationRadius,
        presence.deactivationRadius,
        presence.pollIntervalMs,
        tostring(loaded.removed ~= nil)
    ))
    if type(ExecuteWithDelay) ~= "function" then
        log("ECONOMY_MERCHANT_PRESENCE_UNAVAILABLE scheduler-api")
        return
    end
    local generation = loaded.generation
    local initial_delay = config.factionCommerce
        .economyMerchantPresence.initialDelayMs
    ExecuteWithDelay(initial_delay, function()
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function()
                if presence.generation == generation then
                    if presence.liveRootSource == nil then
                        resolve_economy_merchant_live_root(state)
                    end
                    local player_location = find_local_player_transform()
                    local outcome = presence:tick(player_location)
                    local status = presence:status()
                    log(string.format(
                        "ECONOMY_MERCHANT_PRESENCE_POLL tick=%d ok=%s reason=%s player=(%s,%s,%s) distance=%s active=%d pending=%d generation=%d transitioned=%s initial=true",
                        status.tickCount,
                        tostring(outcome.ok),
                        tostring(outcome.reason),
                        tostring(player_location and player_location.X or "none"),
                        tostring(player_location and player_location.Y or "none"),
                        tostring(player_location and player_location.Z or "none"),
                        tostring(outcome.distance or "none"),
                        status.activeCount,
                        status.pendingCount,
                        generation,
                        tostring(outcome.transitioned == true)
                    ))
                    schedule_economy_merchant_presence_poll(
                        state,
                        generation
                    )
                end
            end)
        end
    end)
end

local function register_guard_console_command(state)
    if type(RegisterConsoleCommandGlobalHandler) ~= "function" then
        log("PLAYER_GUARD_COMMAND_UNAVAILABLE console-api")
        return
    end
    state.guardRequestSequence = state.guardRequestSequence or 0
    RegisterConsoleCommandGlobalHandler(
        "pwft.guard",
        function(_, parts, ar)
            local operation = parts[2] or "status"
            local faction_id = parts[3]
            if operation == "status" then
                local status = state.factionGuard:status()
                if faction_id == nil then
                    log_to_console(ar, string.format(
                        "PLAYER_GUARD_STATUS providers=%d active=%d",
                        status.providerCount,
                        status.activeGuardCount
                    ))
                else
                    local entitlement =
                        state.factionGuard:entitlement(faction_id)
                    log_to_console(ar, string.format(
                        "PLAYER_GUARD_FACTION faction=%s ok=%s reason=%s rank=%s slots=%d provider=%s active=%s",
                        tostring(faction_id),
                        tostring(entitlement.ok),
                        tostring(entitlement.reason),
                        tostring(entitlement.rankId or "none"),
                        tonumber(entitlement.slotCount) or 0,
                        tostring(entitlement.providerReady),
                        tostring(entitlement.active)
                    ))
                end
                return true
            end
            if faction_id == nil then
                log_to_console(
                    ar,
                    "USAGE pwft.guard status [humanFactionId]|deploy <humanFactionId>|recall <humanFactionId>"
                )
                return true
            end
            if operation == "recall" then
                local outcome = state.factionGuard:recall(
                    faction_id,
                    "player-console-request"
                )
                log_to_console(ar, string.format(
                    "PLAYER_GUARD_RECALL faction=%s ok=%s reason=%s",
                    tostring(faction_id),
                    tostring(outcome.ok),
                    tostring(outcome.reason)
                ))
                return true
            end
            if operation ~= "deploy" then
                log_to_console(
                    ar,
                    "USAGE pwft.guard status [humanFactionId]|deploy <humanFactionId>|recall <humanFactionId>"
                )
                return true
            end

            local location, rotation, transform_error, pawn =
                find_local_player_transform()
            if location == nil or not is_valid_object(pawn) then
                log_to_console(
                    ar,
                    "PLAYER_GUARD_DEPLOY ok=false reason="
                        .. tostring(transform_error)
                )
                return true
            end
            local yaw = math.rad(rotation.Yaw)
            local spawn_location = {
                X = location.X
                    - math.cos(yaw) * 180
                    - math.sin(yaw) * 160,
                Y = location.Y
                    - math.sin(yaw) * 180
                    + math.cos(yaw) * 160,
                Z = location.Z,
            }
            state.guardRequestSequence =
                state.guardRequestSequence + 1
            local request_id = string.format(
                "player-%04d",
                state.guardRequestSequence
            )
            local outcome = state.factionGuard:deploy(
                faction_id,
                request_id,
                {
                    location = spawn_location,
                    rotation = {
                        Pitch = 0,
                        Yaw = rotation.Yaw,
                        Roll = 0,
                    },
                    followTarget = pawn,
                }
            )
            log_to_console(ar, string.format(
                "PLAYER_GUARD_DEPLOY faction=%s request=%s ok=%s reason=%s follow=%s actor=%s",
                tostring(faction_id),
                request_id,
                tostring(outcome.ok),
                tostring(outcome.reason),
                tostring(
                    outcome.handle
                        and outcome.handle.followBehaviourStatus
                        or "none"
                ),
                safe_full_name(
                    outcome.handle and outcome.handle.actor
                )
            ))
            return true
        end
    )
    log(
        "PLAYER_GUARD_COMMAND_READY command=pwft.guard operations=status,deploy,recall entitlement=LeaderOrLord"
    )
end

local function register_guard_live_test(config, state)
    local qa = config.factionProgression.playerGuard.liveTest
    if qa.enabled ~= true then
        log("PLAYER_GUARD_LIVE_TEST_DISABLED config=false")
        return
    end
    if state.nativeCharacterAdapter == nil
        or type(RegisterKeyBind) ~= "function"
        or Key == nil
        or Key[qa.key] == nil
        or ModifierKey == nil
        or ModifierKey.CONTROL == nil then
        log("PLAYER_GUARD_LIVE_TEST_UNAVAILABLE native-adapter-or-keybind-api")
        return
    end
    state.guardLiveTestSequence = 0
    state.guardLiveTestHandle = nil
    state.guardLiveTestProvider =
        state.nativeCharacterAdapter:create_guard_provider(
            qa.characterId,
            qa.characterClassPath
        )
    local callback = function()
        local execute = function()
            if state.guardLiveTestHandle ~= nil then
                local recalled = state.guardLiveTestProvider.recall(
                    state.guardLiveTestHandle,
                    "live-test-toggle"
                )
                log(string.format(
                    "PLAYER_GUARD_LIVE_TEST_RECALL faction=%s ok=%s actor=%s saveWrites=0",
                    qa.factionId,
                    tostring(recalled),
                    safe_full_name(state.guardLiveTestHandle.actor)
                ))
                if recalled then
                    state.guardLiveTestHandle = nil
                end
                return
            end
            local location, rotation, transform_error, pawn =
                find_local_player_transform()
            if location == nil or not is_valid_object(pawn) then
                log(
                    "PLAYER_GUARD_LIVE_TEST_FAILED reason="
                        .. tostring(transform_error)
                )
                return
            end
            local yaw = math.rad(rotation.Yaw)
            local spawn_location = {
                X = location.X
                    - math.cos(yaw) * qa.spawnBackDistance
                    - math.sin(yaw) * qa.spawnSideDistance,
                Y = location.Y
                    - math.sin(yaw) * qa.spawnBackDistance
                    + math.cos(yaw) * qa.spawnSideDistance,
                Z = location.Z,
            }
            state.guardLiveTestSequence =
                state.guardLiveTestSequence + 1
            local request_id = string.format(
                "qa-%04d",
                state.guardLiveTestSequence
            )
            local deployed, handle_or_error = pcall(
                state.guardLiveTestProvider.deploy,
                qa.factionId,
                request_id,
                {
                    location = spawn_location,
                    rotation = {
                        Pitch = 0,
                        Yaw = rotation.Yaw,
                        Roll = 0,
                    },
                    followTarget = pawn,
                    onTerminated = function(detail)
                        local live_handle =
                            state.guardLiveTestHandle
                        local matches =
                            type(live_handle) == "table"
                            and type(detail) == "table"
                            and live_handle.runtimeId
                                == detail.runtimeId
                        if matches then
                            state.guardLiveTestHandle = nil
                        end
                        log(string.format(
                            "PLAYER_GUARD_LIVE_TEST_TERMINATED faction=%s runtime=%s actor=%s reason=%s slotReleased=%s saveWrites=0",
                            qa.factionId,
                            tostring(detail and detail.runtimeId),
                            safe_full_name(detail and detail.actor),
                            tostring(detail and detail.reason),
                            tostring(matches)
                        ))
                    end,
                }
            )
            if not deployed or type(handle_or_error) ~= "table" then
                log(string.format(
                    "PLAYER_GUARD_LIVE_TEST_FAILED reason=%s saveWrites=0",
                    tostring(handle_or_error)
                ))
                return
            end
            state.guardLiveTestHandle = handle_or_error
            log(string.format(
                "PLAYER_GUARD_LIVE_TEST_DEPLOYED faction=%s request=%s actor=%s follow=%s player=(%.2f,%.2f,%.2f) spawn=(%.2f,%.2f,%.2f) saveWrites=0",
                qa.factionId,
                request_id,
                safe_full_name(handle_or_error.actor),
                tostring(handle_or_error.followBehaviourStatus),
                location.X,
                location.Y,
                location.Z,
                spawn_location.X,
                spawn_location.Y,
                spawn_location.Z
            ))
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(execute)
        else
            execute()
        end
    end
    state.callbacks.playerGuardLiveTest = callback
    RegisterKeyBind(
        Key[qa.key],
        { ModifierKey.CONTROL },
        callback
    )
    log(string.format(
        "PLAYER_GUARD_LIVE_TEST_READY key=Ctrl+%s faction=%s character=%s entitlementBypass=qa-only saveWrites=0",
        qa.key,
        qa.factionId,
        qa.characterId
    ))
end

local function register_economy_merchant_interaction_router(state)
    if type(RegisterKeyBind) ~= "function"
        or Key == nil
        or Key.F6 == nil then
        log("ECONOMY_MERCHANT_INTERACTION_ROUTER_UNAVAILABLE keybind-api")
        return
    end
    local callback = function()
        local apply = function()
            local _, _, player_error, pawn =
                find_local_player_transform()
            if not is_valid_object(pawn) then
                log(
                    "ECONOMY_MERCHANT_INTERACTION_ROUTED ok=false reason="
                        .. tostring(player_error)
                )
                return
            end
            local outcome = state.factionEconomyMerchantRuntime
                :interact_nearest(pawn, 350)
            if outcome.ok
                or outcome.reason ~= "no-economy-merchant-in-range" then
                log(string.format(
                    "ECONOMY_MERCHANT_INTERACTION_ROUTED ok=%s reason=%s faction=%s actor=%s distance=%s route=%s detail=%s",
                    tostring(outcome.ok),
                    tostring(outcome.reason),
                    tostring(outcome.factionId or "none"),
                    safe_full_name(outcome.actor),
                    tostring(outcome.distance or "none"),
                    tostring(outcome.route or "none"),
                    tostring(outcome.detail or "none")
                ))
            end
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(apply)
        else
            apply()
        end
    end
    state.callbacks.economyMerchantInteractionRouter = callback
    -- Keep the Merchant Guild interaction route on its own key.  Palworld's
    -- ordinary F action is context-sensitive (beds, containers, workbenches)
    -- and consumes the key before UE4SS when one of those indicators is
    -- active.  F6 remains deterministic without replacing native actions.
    RegisterKeyBind(Key.F6, callback)
    log(
        "ECONOMY_MERCHANT_INTERACTION_ROUTER_READY key=F6 radius=350 route=refresh_merchant_shop->PalHUDService.Push(WBP_ItemShop_C,native-parameter) darkTraderPalShopBypassed=true"
    )
end

local function register_economy_merchant_live_test(config, state)
    local qa = config.factionCommerce.economyMerchantLiveTest
    if type(qa) ~= "table" or qa.enabled ~= true then
        log("ECONOMY_MERCHANT_LIVE_TEST_DISABLED config=false")
        return
    end
    if type(RegisterKeyBind) ~= "function"
        or Key == nil
        or Key[qa.key] == nil
        or ModifierKey == nil
        or ModifierKey.CONTROL == nil then
        log("ECONOMY_MERCHANT_LIVE_TEST_UNAVAILABLE keybind-api")
        return
    end
    local callback = function()
        local apply = function()
            local runtime = state.factionEconomyMerchantRuntime
            local status = runtime:status()
            local all_counters = qa.allCounters == true
                or qa.factionId == "all"
            if all_counters
                and (status.activeCount > 0
                    or status.pendingCount > 0) then
                local removed = runtime:deactivate_market(
                    "live-test-toggle-all"
                )
                local after = runtime:status()
                log(string.format(
                    "ECONOMY_MERCHANT_LIVE_TEST_DEACTIVATE mode=all ok=%s reason=%s removed=%d active=%d pending=%d",
                    tostring(removed.ok),
                    tostring(removed.reason),
                    #(removed.removedFactionIds or {}),
                    after.activeCount,
                    after.pendingCount
                ))
                return
            end
            local existing = runtime.records[qa.factionId]
            if existing ~= nil and existing.actor ~= nil then
                local removed = runtime:deactivate_faction(
                    qa.factionId,
                    "live-test-toggle"
                )
                log(string.format(
                    "ECONOMY_MERCHANT_LIVE_TEST_DEACTIVATE faction=%s ok=%s reason=%s active=%d",
                    qa.factionId,
                    tostring(removed.ok),
                    tostring(removed.reason),
                    runtime:status().activeCount
                ))
                return
            end

            local player_location, player_rotation, transform_error =
                find_local_player_transform()
            if player_location == nil
                or player_location.X == nil
                or player_location.Y == nil
                or player_location.Z == nil then
                log(
                    "ECONOMY_MERCHANT_LIVE_TEST_FAILED reason="
                        .. tostring(transform_error)
                )
                return
            end
            local market_rotation = {
                Pitch = 0,
                Yaw = player_rotation.Yaw + 180,
                Roll = 0,
            }
            local player_yaw = math.rad(player_rotation.Yaw)
            local desired = {
                X = player_location.X
                    + math.cos(player_yaw) * qa.forwardDistance,
                Y = player_location.Y
                    + math.sin(player_yaw) * qa.forwardDistance,
                Z = player_location.Z,
            }
            local root = desired
            local shop = nil
            if not all_counters then
                local shop_error = nil
                shop, shop_error =
                    state.factionEconomyShops
                        :shop_catalog(qa.factionId)
                if shop == nil then
                    log(
                        "ECONOMY_MERCHANT_LIVE_TEST_FAILED reason="
                            .. tostring(shop_error)
                    )
                    return
                end
                local slot = runtime.commerceContract.merchantIsland
                    .slotOffsets[shop.slotIndex + 1]
                local market_yaw = math.rad(market_rotation.Yaw)
                local market_forward_x = math.cos(market_yaw)
                local market_forward_y = math.sin(market_yaw)
                local market_right_x = -market_forward_y
                local market_right_y = market_forward_x
                root = {
                    X = desired.X
                        - market_forward_x * (slot.forward or 0)
                        - market_right_x * (slot.right or 0),
                    Y = desired.Y
                        - market_forward_y * (slot.forward or 0)
                        - market_right_y * (slot.right or 0),
                    Z = desired.Z - (slot.up or 0),
                }
            end
            local outcome = all_counters
                    and runtime:activate_market(root, market_rotation)
                or runtime:activate_faction(
                    qa.factionId,
                    root,
                    market_rotation
                )
            local after = runtime:status()
            log(string.format(
                "ECONOMY_MERCHANT_LIVE_TEST_ACTIVATE mode=%s faction=%s ok=%s reason=%s detail=%s player=(%.2f,%.2f,%.2f) target=(%.2f,%.2f,%.2f) yaw=%.2f row=%s queued=%d actor=%s activeBefore=%d activeAfter=%d pendingAfter=%d",
                all_counters and "all" or "single",
                tostring(qa.factionId),
                tostring(outcome.ok),
                tostring(outcome.reason),
                tostring(outcome.detail or "none"),
                player_location.X,
                player_location.Y,
                player_location.Z,
                desired.X,
                desired.Y,
                desired.Z,
                market_rotation.Yaw,
                tostring(shop and shop.lotteryRowName or "all-7-unique-rows"),
                #(outcome.spawned or {}),
                safe_full_name(outcome.actor),
                status.activeCount,
                after.activeCount,
                after.pendingCount
            ))
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(apply)
        else
            apply()
        end
    end
    state.callbacks.economyMerchantLiveTest = callback
    RegisterKeyBind(
        Key[qa.key],
        { ModifierKey.CONTROL },
        callback
    )
    log(string.format(
        "ECONOMY_MERCHANT_LIVE_TEST_READY key=Ctrl+%s mode=%s faction=%s forwardDistance=%d counters=%d saveWrites=0",
        qa.key,
        (qa.allCounters == true or qa.factionId == "all")
                and "all" or "single",
        tostring(qa.factionId),
        qa.forwardDistance,
        (qa.allCounters == true or qa.factionId == "all")
                and 7 or 1
    ))
end

-- WBP_Map_Base receives the original PalUIWorldMapIcon as its Icon argument
-- before it opens Palworld's normal fast-travel confirmation dialog.  Resolve
-- the associated PalLocationPoint through the public parent method rather
-- than poking into the widget's generated Blueprint state.
local function resolve_fast_travel_id_from_map_icon(icon_param)
    local icon = safe_param_get(icon_param)
    if not is_valid_object(icon) then
        return nil, nil
    end
    local got_location, location = pcall(function()
        return icon:GetLocationPoint()
    end)
    if not got_location or not is_valid_object(location) then
        return nil, nil
    end
    local fast_travel_id = safe_to_string(safe_property(location, "FastTravelPointID"))
    if fast_travel_id == "" or fast_travel_id == "None" or fast_travel_id == "<nil>" then
        return nil, location
    end
    return fast_travel_id, location
end

-- WBP_Map_IconFTTower_C stores the same native ID directly on the icon.  Its
-- ClickEvent is the concrete path fired by the map button, so this resolver
-- remains valid even on builds where WBP_Map_Base's container event is not
-- dispatched to UE4SS Blueprint hooks.
local function resolve_fast_travel_id_from_ft_tower_icon(icon_param)
    local icon = safe_param_get(icon_param)
    if not is_valid_object(icon) then
        return nil, nil
    end
    local fast_travel_id = safe_to_string(safe_property(icon, "Fast Travel Point ID"))
    if fast_travel_id == "" or fast_travel_id == "None" or fast_travel_id == "<nil>" then
        return nil, icon
    end
    return fast_travel_id, icon
end

local MAP_FAST_TRAVEL_ICON_CLICK_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconFTTower.WBP_Map_IconFTTower_C:ClickEvent"
local MAP_FAST_TRAVEL_CONTAINER_CLICK_PATH =
    "/Game/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_Base.WBP_Map_Base_C:On Icon Clicked"
local FAST_TRAVEL_AVAILABILITY_PATH =
    "/Script/Pal.PalLocationPoint:IsEnableFastTravel"

local function active_hostile_fast_travel_operation(state)
    local operation = state.pendingHostileFastTravel
    if operation == nil then
        return nil
    end
    if os.clock() - operation.startedAt > 5.0 then
        state.pendingHostileFastTravel = nil
        log(string.format(
            "HOSTILE_FAST_TRAVEL_OPERATION_EXPIRED fastTravelId=%s island=%s token=%s",
            tostring(operation.fastTravelId),
            tostring(operation.territoryId),
            tostring(operation.token)
        ))
        return nil
    end
    return operation
end

local function remember_hostile_fast_travel_operation(state, fast_travel_id, territory_id, route)
    local now = os.clock()
    local current = active_hostile_fast_travel_operation(state)
    if current ~= nil
        and current.fastTravelId == fast_travel_id
        and current.territoryId == territory_id
        and now - current.startedAt < 1.0 then
        current.routes[route] = true
        return current
    end

    state.hostileFastTravelOperationCount = (state.hostileFastTravelOperationCount or 0) + 1
    local operation = {
        token = state.hostileFastTravelOperationCount,
        fastTravelId = fast_travel_id,
        territoryId = territory_id,
        startedAt = now,
        routes = { [route] = true },
        dialogCancelScheduled = false,
    }
    state.pendingHostileFastTravel = operation

    if type(ExecuteWithDelay) == "function" then
        local expire_callback = function()
            local pending = state.pendingHostileFastTravel
            if pending ~= nil and pending.token == operation.token then
                state.pendingHostileFastTravel = nil
                log(string.format(
                    "HOSTILE_FAST_TRAVEL_OPERATION_EXPIRED fastTravelId=%s island=%s token=%s",
                    tostring(operation.fastTravelId),
                    tostring(operation.territoryId),
                    tostring(operation.token)
                ))
            end
        end
        state.callbacks.hostileFastTravelOperationExpiry = expire_callback
        ExecuteWithDelay(5000, expire_callback)
    end
    return operation
end

local function cancel_hostile_fast_travel_dialog_object(state, dialog, phase)
    local operation = active_hostile_fast_travel_operation(state)
    if operation == nil then
        return false, "no-pending-hostile-operation"
    end
    if not is_valid_object(dialog) then
        return false, "invalid-dialog"
    end

    local dialog_name = safe_full_name(dialog)
    local cancel_ok, cancel_error = pcall(function()
        -- This is the exact WBP_PalDialog instance delivered by Construct or
        -- OnSetup. Its native cancel action invokes the map callback with
        -- bOK=false and closes Palworld's own modal/input stack cleanly.
        dialog:OnCancelAction()
    end)
    if not cancel_ok then
        log(string.format(
            "HOSTILE_FAST_TRAVEL_DIALOG_CANCEL_ERROR fastTravelId=%s island=%s token=%s phase=%s dialog=%s error=%s",
            tostring(operation.fastTravelId),
            tostring(operation.territoryId),
            tostring(operation.token),
            tostring(phase),
            dialog_name,
            tostring(cancel_error)
        ))
        return false, tostring(cancel_error)
    end

    operation.dialogCancelSucceeded = true
    log(string.format(
        "HOSTILE_FAST_TRAVEL_DIALOG_CANCELLED fastTravelId=%s island=%s token=%s phase=%s dialog=%s",
        tostring(operation.fastTravelId),
        tostring(operation.territoryId),
        tostring(operation.token),
        tostring(phase),
        dialog_name
    ))
    return true, "cancelled"
end

local function schedule_hostile_fast_travel_dialog_cancel(state, dialog, phase)
    local operation = active_hostile_fast_travel_operation(state)
    if operation == nil then
        return false
    end
    if operation.dialogCancelScheduled == true then
        return true
    end
    operation.dialogCancelScheduled = true

    local cancel_callback = function()
        local invoke = function()
            cancel_hostile_fast_travel_dialog_object(state, dialog, phase)
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(invoke)
        else
            invoke()
        end
    end
    state.callbacks.hostileFastTravelDialogCancel = cancel_callback
    if type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(1, cancel_callback)
    else
        cancel_callback()
    end
    log(string.format(
        "HOSTILE_FAST_TRAVEL_DIALOG_CANCEL_SCHEDULED fastTravelId=%s island=%s token=%s phase=%s dialog=%s",
        tostring(operation.fastTravelId),
        tostring(operation.territoryId),
        tostring(operation.token),
        tostring(phase),
        safe_full_name(dialog)
    ))
    return true
end

local function observe_hostile_fast_travel_dialog_construct(state, widget)
    if active_hostile_fast_travel_operation(state) == nil then
        return false
    end
    local widget_name = safe_full_name(widget)
    if string.find(widget_name, "WBP_PalDialog_C", 1, true) == nil then
        return false
    end
    return schedule_hostile_fast_travel_dialog_cancel(state, widget, "user-widget-construct")
end

local function block_hostile_fast_travel_selection(config, registry, policy, state, fast_travel_id, territory_id, route)
    local territory = registry.islands[territory_id] or registry.territories[territory_id]
    if territory == nil then
        return false, "unknown-territory"
    end
    local decision = policy.can_use_public_fast_travel(territory, true, state.relations, false)
    if decision.allowed then
        state.pendingHostileFastTravel = nil
        return false, "allowed"
    end

    if config.enableFastTravelEnforcement ~= true then
        show_native_danger_warning(config, registry, policy, state, territory_id, "map-fast-travel-selection")
        return false, "enforcement-disabled"
    end

    -- The real enforcement gate is PalLocationPoint:IsEnableFastTravel.  Map
    -- Blueprint hooks run after their bytecode and therefore remain
    -- observation/presentation-only; never arm a later dialog cancellation.
    state.pendingHostileFastTravel = nil
    log(string.format(
        "FAST_TRAVEL_HOSTILE_SELECTION_OBSERVED fastTravelId=%s island=%s relation=%s reason=%s route=%s",
        tostring(fast_travel_id),
        tostring(territory_id),
        tostring(decision.relation),
        tostring(decision.reasonCode),
        tostring(route)
    ))
    return true, "hostile-territory"
end

-- Palworld calls this native boolean query from WBP_Map_Base before it creates
-- the confirmation dialog.  UE4SS's native post callback receives the original
-- return value and may replace it by returning a Lua value.  Returning false
-- here makes the original Blueprint take its own unavailable branch; no dialog
-- exists and InvokeFastTravel is never reached.
local function register_native_fast_travel_availability_gate(config, registry, policy, state)
    if config.enableFastTravelEnforcement ~= true then
        return false
    end

    local pre_callback = function(_)
        -- Deliberately empty.  The original value does not exist until the
        -- native function has run; enforcement belongs in post_callback.
    end
    local post_callback = function(context, original_return_value)
        local override = nil
        local ok, error_message = pcall(function()
            state.fastTravelAvailabilityQueryCount = state.fastTravelAvailabilityQueryCount + 1
            local location = safe_param_get(context)
            local fast_travel_id = safe_to_string(safe_property(location, "FastTravelPointID"))
            local territory_id = state.fastTravelToIsland[fast_travel_id]
            local original_enabled = safe_param_get(original_return_value)

            if territory_id == nil then
                return
            end

            local territory = registry.islands[territory_id] or registry.territories[territory_id]
            if territory == nil then
                return
            end

            local decision = policy.can_use_public_fast_travel(territory, true, state.relations, false)
            if decision.allowed then
                return
            end

            override = false
            state.pendingHostileFastTravel = nil
            state.fastTravelAvailabilityDeniedCount = state.fastTravelAvailabilityDeniedCount + 1
            -- This query runs hundreds of times while the map is built.  Log
            -- one proof line per session and perform no UMG work here.
            if state.fastTravelAvailabilityDenialLogged ~= true then
                state.fastTravelAvailabilityDenialLogged = true
                log(string.format(
                    "FAST_TRAVEL_AVAILABILITY_DENIED fastTravelId=%s island=%s relation=%s reason=%s original=%s override=false ui=false",
                    fast_travel_id,
                    tostring(territory_id),
                    tostring(decision.relation),
                    tostring(decision.reasonCode),
                    tostring(original_enabled)
                ))
                log("FAST_TRAVEL_BLOCK_APPLIED route=IsEnableFastTravel:return-false ui=false")
            end
        end)
        if not ok then
            log("FAST_TRAVEL_AVAILABILITY_GATE_ERROR " .. tostring(error_message))
        end
        return override
    end

    state.callbacks.fastTravelAvailabilityPre = pre_callback
    state.callbacks.fastTravelAvailabilityPost = post_callback
    return try_register_hook(
        state,
        FAST_TRAVEL_AVAILABILITY_PATH,
        pre_callback,
        post_callback
    )
end

-- Registering a Blueprint function at mod start is too early: UE4SS requires
-- the UFunction to exist in memory and Palworld only loads these map widgets
-- after the player opens M.  This helper is therefore called both at startup
-- (for already-loaded maps) and from the native UserWidget construct hook.
local function ensure_map_fast_travel_selection_hooks(config, registry, policy, state)
    if config.enableMapFastTravelSelectionWarning ~= true
        and config.enableFastTravelEnforcement ~= true then
        return false
    end

    local icon_ready = try_register_hook(
        state,
        MAP_FAST_TRAVEL_ICON_CLICK_PATH,
        function(context)
            local ok, error_message = pcall(function()
                local fast_travel_id, icon = resolve_fast_travel_id_from_ft_tower_icon(context)
                if fast_travel_id == nil then
                    log("MAP_FAST_TRAVEL_ICON_CLICK_SKIPPED reason=id-unresolved")
                    return
                end
                local territory_id = state.fastTravelToIsland[fast_travel_id]
                log(string.format(
                    "MAP_FAST_TRAVEL_ICON_CLICK object=%s fastTravelId=%s island=%s",
                    safe_full_name(icon),
                    fast_travel_id,
                    tostring(territory_id or "unresolved")
                ))
                if territory_id ~= nil then
                    block_hostile_fast_travel_selection(
                        config,
                        registry,
                        policy,
                        state,
                        fast_travel_id,
                        territory_id,
                        "tower-icon-click"
                    )
                end
            end)
            if not ok then
                log("MAP_FAST_TRAVEL_ICON_CLICK_ERROR " .. tostring(error_message))
            end
        end
    )

    -- Arm the guard before Palworld creates its native confirmation. The
    -- dialog lifecycle and reply hooks below consume this pending operation.
    local container_ready = try_register_hook(
        state,
        MAP_FAST_TRAVEL_CONTAINER_CLICK_PATH,
        function(_, icon)
            local ok, error_message = pcall(function()
                local fast_travel_id, location = resolve_fast_travel_id_from_map_icon(icon)
                if fast_travel_id == nil then
                    state.pendingHostileFastTravel = nil
                    log("MAP_FAST_TRAVEL_SELECT_SKIPPED reason=location-unresolved")
                    return
                end
                local territory_id = state.fastTravelToIsland[fast_travel_id]
                log(string.format(
                    "MAP_FAST_TRAVEL_SELECT object=%s fastTravelId=%s island=%s",
                    safe_full_name(location),
                    fast_travel_id,
                    tostring(territory_id or "unresolved")
                ))
                if territory_id ~= nil then
                    block_hostile_fast_travel_selection(
                        config,
                        registry,
                        policy,
                        state,
                        fast_travel_id,
                        territory_id,
                        "map-container-click"
                    )
                else
                    state.pendingHostileFastTravel = nil
                end
            end)
            if not ok then
                log("MAP_FAST_TRAVEL_SELECT_ERROR " .. tostring(error_message))
            end
        end
    )

    return icon_ready or container_ready
end

local function probe_map_widget_instances(state)
    if type(FindAllOf) ~= "function" then
        log("MAP_WIDGET_SCAN_UNAVAILABLE FindAllOf missing")
        return 0
    end

    local found = 0
    local classes = { "WBP_Map_Body_C", "WBP_Map_Base_C" }
    for _, class_name in ipairs(classes) do
        local ok, widgets = pcall(function()
            return FindAllOf(class_name)
        end)
        if not ok or widgets == nil then
            log("MAP_WIDGET_SCAN_EMPTY class=" .. class_name)
        else
            for _, widget in pairs(widgets) do
                if is_valid_object(widget) then
                    found = found + 1
                    local widget_tree = safe_property(widget, "WidgetTree")
                    if class_name == "WBP_Map_Base_C" then
                        state.mapWidgetProbeCount = state.mapWidgetProbeCount + 1
                        log(string.format(
                            "MAP_WIDGET_PROBE count=%d class=%s widget=%s widgetTree=%s",
                            state.mapWidgetProbeCount,
                            class_name,
                            safe_full_name(widget),
                            safe_full_name(widget_tree)
                        ))
                    else
            -- The named UMG children are held by the UUserWidget's WidgetTree,
            -- not exposed as direct reflected fields of WBP_Map_Body_C.  The
            -- object dump from the live test save confirms this exact path for
            -- both map bodies (main world and tree/island layer).
            local map_body = safe_property(widget_tree, "Image_MapBody")
            local map_mask = safe_property(widget_tree, "Image_MapMask")
            local canvas = safe_property(widget_tree, "Canvas_MapBody")
            local outer_canvas = safe_property(widget_tree, "Canvas_Outer")
            local icon_mask_canvas = safe_property(widget_tree, "Canvas_ForIcon_Mask")
            local icon_nomask_canvas = safe_property(widget_tree, "Canvas_ForIcon_NoMask")
            local body_brush = safe_property(map_body, "Brush")
            local mask_brush = safe_property(map_mask, "Brush")
            state.mapWidgetProbeCount = state.mapWidgetProbeCount + 1
            log(string.format(
                "MAP_WIDGET_PROBE count=%d widget=%s widgetTree=%s canvas=%s outerCanvas=%s iconMaskCanvas=%s iconNoMaskCanvas=%s body=%s bodySlot=%s bodyBrushResource=%s mask=%s maskSlot=%s maskBrushResource=%s maskMaterial=%s",
                state.mapWidgetProbeCount,
                safe_full_name(widget),
                safe_full_name(widget_tree),
                safe_full_name(canvas),
                safe_full_name(outer_canvas),
                safe_full_name(icon_mask_canvas),
                safe_full_name(icon_nomask_canvas),
                safe_full_name(map_body),
                safe_full_name(safe_property(map_body, "Slot")),
                safe_full_name(safe_property(body_brush, "ResourceObject")),
                safe_full_name(map_mask),
                safe_full_name(safe_property(map_mask, "Slot")),
                safe_full_name(safe_property(mask_brush, "ResourceObject")),
                safe_full_name(safe_property(widget, "MaskTextureMaterial"))
            ))
                    end
                end
            end
        end
    end

    log(string.format("MAP_WIDGET_SCAN_DONE classes=WBP_Map_Body_C,WBP_Map_Base_C found=%d", found))
    if found > 0 and state.runtimeConfig ~= nil then
        -- Either live map root proves that the Blueprint package is resident.
        -- Register the icon callback here rather than at startup: UE4SS
        -- rejects Blueprint UFunctions that have not been loaded yet.
        local ready = ensure_map_fast_travel_selection_hooks(
            state.runtimeConfig,
            state.runtimeRegistry,
            state.runtimePolicy,
            state
        )
        log(string.format("MAP_FAST_TRAVEL_HOOK_MAP_READY found=%d ready=%s", found, tostring(ready)))
    end
    return found
end

local function schedule_map_widget_probe(state, delay_ms)
    if type(ExecuteWithDelay) ~= "function" or type(ExecuteInGameThread) ~= "function" then
        log("MAP_WIDGET_PROBE_UNAVAILABLE scheduler missing")
        return
    end
    local delayed_callback = function()
        ExecuteInGameThread(function()
            probe_map_widget_instances(state)
        end)
    end
    state.callbacks.mapWidgetProbe = delayed_callback
    ExecuteWithDelay(delay_ms, delayed_callback)
    log(string.format("MAP_WIDGET_PROBE_READY delayMs=%d", delay_ms))
end

-- On this Steam build, pressing M creates the map through a path that does
-- not reliably invoke the reflected CreateWorldMapData hook.  Poll briefly
-- after world entry instead.  This reads only the live widget properties and
-- stops immediately once the native map body is observed.
local function schedule_map_widget_poll(state, attempts_remaining, delay_ms)
    if type(ExecuteWithDelay) ~= "function" or type(ExecuteInGameThread) ~= "function" then
        log("MAP_WIDGET_POLL_UNAVAILABLE scheduler missing")
        return
    end

    local delayed_callback = function()
        ExecuteInGameThread(function()
            local found = probe_map_widget_instances(state)
            if found > 0 then
                log("MAP_WIDGET_POLL_DONE reason=found")
            elseif attempts_remaining > 1 then
                schedule_map_widget_poll(state, attempts_remaining - 1, delay_ms)
            else
                log("MAP_WIDGET_POLL_DONE reason=timeout")
            end
        end)
    end
    state.callbacks.mapWidgetPoll = delayed_callback
    ExecuteWithDelay(delay_ms, delayed_callback)
end

local schedule_progression_identity_attempt

local function attempt_progression_identity(
    config,
    state,
    generation,
    attempt
)
    if generation ~= state.progressionIdentity.generation then
        return
    end
    state.progressionIdentity.attempts = attempt
    local identity, identity_error =
        ProgressionIdentity.resolve_native()
    if identity ~= nil then
        state.progressionIdentity.status = "ready"
        state.progressionIdentity.lastError = nil
        state.progressionIdentity.value = identity
        local sidecar_ready = false
        local sidecar_reason = "activation-callback-unavailable"
        if type(state.onProgressionIdentityReady) == "function" then
            local callback_ok, callback_ready, callback_reason = pcall(
                state.onProgressionIdentityReady,
                identity
            )
            sidecar_ready = callback_ok and callback_ready == true
            sidecar_reason = callback_ok
                    and tostring(callback_reason)
                or "activation-error:" .. tostring(callback_ready)
        end
        state.progressionIdentity.sidecarReady = sidecar_ready
        state.progressionIdentity.sidecarReason = sidecar_reason
        log(string.format(
            "PROGRESSION_IDENTITY_READY attempt=%d readOnly=true world=%s player=%s profile=%s root=%s controllerSource=%s worldSource=%s playerSource=%s sidecarWrites=%s sidecarReason=%s",
            attempt,
            identity.worldDirectory,
            identity.playerUid,
            identity.profileKey,
            state.progressionIdentity.sidecarRootPath,
            identity.sources.controller,
            identity.sources.world,
            identity.sources.player,
            tostring(sidecar_ready),
            tostring(sidecar_reason)
        ))
        return
    end

    state.progressionIdentity.lastError =
        tostring(identity_error)
    local retry_delays =
        config.factionProgression.persistence.identityProbe
            .retryDelaysMs
    if attempt < #retry_delays then
        state.progressionIdentity.status = "retry-pending"
        log(string.format(
            "PROGRESSION_IDENTITY_PENDING attempt=%d/%d reason=%s nextDelayMs=%d sidecarWrites=false",
            attempt,
            #retry_delays,
            tostring(identity_error),
            retry_delays[attempt + 1]
        ))
        schedule_progression_identity_attempt(
            config,
            state,
            generation,
            attempt + 1
        )
    else
        state.progressionIdentity.status = "unavailable"
        log(string.format(
            "PROGRESSION_IDENTITY_UNAVAILABLE attempts=%d reason=%s sidecarWrites=false",
            attempt,
            tostring(identity_error)
        ))
    end
end

schedule_progression_identity_attempt = function(
    config,
    state,
    generation,
    attempt
)
    local retry_delays =
        config.factionProgression.persistence.identityProbe
            .retryDelaysMs
    local delay_ms = retry_delays[attempt]
    if type(ExecuteWithDelay) ~= "function"
        or type(ExecuteInGameThread) ~= "function" then
        state.progressionIdentity.status =
            "scheduler-unavailable"
        state.progressionIdentity.lastError =
            "scheduler-unavailable"
        log(
            "PROGRESSION_IDENTITY_UNAVAILABLE reason=scheduler-unavailable sidecarWrites=false"
        )
        return
    end
    local callback = function()
        ExecuteInGameThread(function()
            attempt_progression_identity(
                config,
                state,
                generation,
                attempt
            )
        end)
    end
    state.callbacks[
        "progressionIdentityAttempt" .. tostring(attempt)
    ] = callback
    ExecuteWithDelay(delay_ms, callback)
end

local function begin_progression_identity_probe(config, state)
    local probe_config =
        config.factionProgression.persistence.identityProbe
    if probe_config.enabled ~= true then
        state.progressionIdentity.status = "disabled"
        state.progressionIdentity.lastError =
            "disabled-by-configuration"
        log("PROGRESSION_IDENTITY_DISABLED sidecarWrites=false")
        return
    end
    state.progressionIdentity.generation =
        state.progressionIdentity.generation + 1
    state.progressionIdentity.status = "probing"
    state.progressionIdentity.attempts = 0
    state.progressionIdentity.lastError = nil
    state.progressionIdentity.value = nil
    schedule_progression_identity_attempt(
        config,
        state,
        state.progressionIdentity.generation,
        1
    )
end

local function register_runtime_probes(config, registry, policy, state)
    -- Map-body polling runs after this setup.  Retain the exact startup inputs
    -- so that the delayed map-loaded callback can install the proper warning
    -- hooks without reaching for globals.
    state.runtimeConfig = config
    state.runtimeRegistry = registry
    state.runtimePolicy = policy
    if config.enableMapHookProbe then
        try_register_hook(
            state,
            "/Script/Pal.PalUIWorldMap:CreateWorldMapData",
            function(_, map_type)
                local ok, error_message = pcall(function()
                    state.mapCreateCount = state.mapCreateCount + 1
                    log(string.format(
                        "MAP_CREATE count=%d mapType=%s mode=%s mutation=false",
                        state.mapCreateCount,
                        safe_to_string(safe_param_get(map_type)),
                        state.mapMode
                    ))
                    -- The title-screen probe intentionally finds no world-map
                    -- widget.  Re-scan only after the native map factory runs,
                    -- so the test-save session records the real Image_MapMask
                    -- material and render-target bindings without changing them.
                    schedule_map_widget_probe(state, 750)
                end)
                if not ok then
                    log("MAP_CREATE_PROBE_ERROR " .. tostring(error_message))
                end
            end
        )
    end

    -- This Blueprint may already be resident on a reload. Otherwise the
    -- generic UserWidget construct observer below retries once PlayerUI builds
    -- its native place-name child.
    ensure_native_place_name_display_hook(config, registry, policy, state)

    local fast_travel_availability_ready =
        register_native_fast_travel_availability_gate(config, registry, policy, state)

    if config.enableMapFastTravelSelectionWarning == true
        or config.enableFastTravelEnforcement == true then
        -- The first attempt is useful when a map was already constructed by a
        -- reload.  Normally it is unavailable here and becomes available from
        -- the UserWidget construct listener below.
        ensure_map_fast_travel_selection_hooks(config, registry, policy, state)
        try_register_hook(
            state,
            "/Script/UMG.UserWidget:Construct",
            function(context)
                local widget = safe_param_get(context)
                local widget_name = safe_full_name(widget)
                if string.find(widget_name, "WBP_Map_IconFTTower_C", 1, true) ~= nil
                    or string.find(widget_name, "WBP_Map_Base_C", 1, true) ~= nil then
                    local ready = ensure_map_fast_travel_selection_hooks(config, registry, policy, state)
                    log(string.format(
                        "MAP_FAST_TRAVEL_HOOK_ACTIVATION widget=%s ready=%s",
                        widget_name,
                        tostring(ready)
                    ))
                end
                observe_place_name_hook_activation(config, registry, policy, state, widget)
            end
        )

        -- The Steam build can construct its map without firing the reflected
        -- factory hook above.  This observer leaves M to Palworld unchanged;
        -- it only waits for the real map root to exist, then installs the
        -- click-time hostile-destination guard.
        if type(RegisterKeyBind) == "function" then
            local map_open_observer = function()
                schedule_map_widget_probe(state, 750)
            end
            state.callbacks.nativeMapOpenObserver = map_open_observer
            RegisterKeyBind(Key.M, map_open_observer)
            log("MAP_OPEN_OBSERVER_KEY_READY key=M action=post-open-widget-probe")
        else
            log("MAP_OPEN_OBSERVER_KEY_UNAVAILABLE RegisterKeyBind missing")
        end
    else
        log("MAP_FAST_TRAVEL_SELECT_WARNING_DISABLED config=false")
    end

    -- When map-selection warnings are disabled, keep the place-name retry
    -- listener independently available. If the map listener above already
    -- registered it, try_register_hook simply retains that same callback.
    if config.enableNativePlaceNamePresentation == true then
        try_register_hook(
            state,
            "/Script/UMG.UserWidget:Construct",
            function(context)
                local widget = safe_param_get(context)
                observe_place_name_hook_activation(config, registry, policy, state, widget)
            end
        )
    else
        log("PLACE_NAME_PRESENTATION_DISABLED config=false")
    end

    if config.enableFastTravelEnforcement == true then
        log(string.format(
            "FAST_TRAVEL_ENFORCEMENT_READY route=IsEnableFastTravel:return-false hostileOnly=true hookReady=%s",
            tostring(fast_travel_availability_ready)
        ))
    else
        log("FAST_TRAVEL_ENFORCEMENT_DISABLED config=false")
    end

    if config.enableFastTravelAudit then
        try_register_hook(
            state,
            "/Script/Pal.PalLocationPoint:InvokeFastTravel",
            function(context)
                local ok, error_message = pcall(function()
                    state.fastTravelAuditCount = state.fastTravelAuditCount + 1
                    local location = safe_param_get(context)
                    local fast_travel_id = safe_to_string(safe_property(location, "FastTravelPointID"))
                    log(string.format(
                        "FAST_TRAVEL_AUDIT count=%d object=%s fastTravelId=%s enforcement=%s",
                        state.fastTravelAuditCount,
                        safe_full_name(location),
                        fast_travel_id,
                        tostring(config.enableFastTravelEnforcement)
                    ))
                    local territory_id = state.fastTravelToIsland[fast_travel_id]
                    if territory_id ~= nil then
                        -- The native travel hook is a valid entry-operation
                        -- source only after a live tower-to-mask mapping has
                        -- been captured.  Until then it remains an audit;
                        -- no travel is intercepted or changed.
                        show_native_danger_warning(config, registry, policy, state, territory_id, "public-fast-travel")
                    else
                        log(string.format("DANGER_WARNING_DEFERRED fastTravelId=%s reason=territory-unresolved", fast_travel_id))
                    end
                end)
                if not ok then
                    log("FAST_TRAVEL_PROBE_ERROR " .. tostring(error_message))
                end
            end
        )
    end

    local identity_probe_enabled =
        config.factionProgression.persistence.identityProbe
            .enabled == true
    local native_raid_hook_retry_enabled =
        state.palRaidNativeBinding ~= nil
        and config.palReconciliation ~= nil
        and config.palReconciliation
            .nativeRaidResultBindingEnabled == true
    if config.factionCommerce.economyMerchantPresence.enabled == true
        and type(RegisterLoadMapPreHook) == "function" then
        local load_map_pre_callback = function()
            local presence = state.factionEconomyMerchantPresence
            if presence == nil then
                return
            end
            local outcome = presence:on_world_unloading("load-map-pre")
            log(string.format(
                "ECONOMY_MERCHANT_PRESENCE_WORLD_UNLOADING ok=%s generation=%d cleanup=%s reason=%s",
                tostring(outcome.ok == true),
                outcome.generation,
                tostring(outcome.removed ~= nil
                    and outcome.removed.ok == true),
                tostring(outcome.removed
                    and outcome.removed.reason or "none")
            ))
        end
        state.callbacks.loadMapPre = load_map_pre_callback
        RegisterLoadMapPreHook(load_map_pre_callback)
        log("ECONOMY_MERCHANT_PRESENCE_PRE_UNLOAD_FENCE_READY readOnly=true")
    end

    if (config.enableTowerBindingProbe
        or identity_probe_enabled
        or native_raid_hook_retry_enabled
        or (config.factionCommerce.economyMerchantPresence
            .enabled == true))
        and type(RegisterLoadMapPostHook) == "function" then
        local load_map_post_callback = function()
            if state.settlementRaid ~= nil then
                state.settlementRaid:on_world_loaded("load-map-post")
            end
            if native_raid_hook_retry_enabled then
                state.palRaidNativeBinding
                    :on_world_loaded("load-map-post")
            end
            if identity_probe_enabled then
                begin_progression_identity_probe(config, state)
            end
            start_economy_merchant_presence(
                config,
                state,
                "load-map-post"
            )
            if type(ExecuteWithDelay) == "function" and type(ExecuteInGameThread) == "function" then
                ExecuteWithDelay(10000, function()
                    ExecuteInGameThread(function()
                        -- The live Steam build does not dispatch the generic
                        -- UserWidget:Construct hook for its already-created
                        -- player HUD.  By this one-shot post-world-load point,
                        -- WBP_IngamePlaceName and Display Region are resident,
                        -- so register against the real function here instead
                        -- of polling for it.
                        if config.enableNativePlaceNamePresentation == true then
                            local place_name_ready = ensure_native_place_name_display_hook(config, registry, policy, state)
                            log(string.format(
                                "PLACE_NAME_HOOK_WORLD_READY source=load-map-post ready=%s",
                                tostring(place_name_ready)
                            ))
                        end
                        scan_tower_bindings(config, registry, state)
                        resolve_economy_merchant_live_root(state)
                        if state.rayneMerchant ~= nil then
                            state.rayneMerchant:schedule_spawn(
                                "load-map-post",
                                config.rayneMerchant.spawnDelayMs
                            )
                        end
                    end)
                end)
            end
        end
        state.callbacks.loadMapPost = load_map_post_callback
        RegisterLoadMapPostHook(load_map_post_callback)
        log(string.format(
            "WORLD_LOAD_CALLBACK_READY towerProbe=%s towerDelayMs=10000 progressionIdentityProbe=%s merchantPresence=%s readOnly=true",
            tostring(config.enableTowerBindingProbe),
            tostring(identity_probe_enabled),
            tostring(config.factionCommerce
                .economyMerchantPresence.enabled == true)
        ))
    end
end

function Runtime.start(config, registry, policy)
    validate_registry(registry)
    assert(config.enableMapOverlayMutation == true, "faction map overlay must be explicitly enabled")
    assert(type(config.enableFastTravelEnforcement) == "boolean", "fast-travel enforcement must be explicitly configured")
    assert(type(config.enableNativePlaceNamePresentation) == "boolean", "place-name presentation must be explicitly configured")
    assert(type(config.rayneMerchant) == "table", "rayne merchant must be explicitly configured")
    assert(type(config.settlementRaid) == "table", "settlement raid must be explicitly configured")
    assert(type(config.factionProgression) == "table", "faction progression must be explicitly configured")
    assert(config.factionProgression.enabled == true, "faction progression core must be enabled")
    assert(type(config.palReconciliation) == "table", "Pal reconciliation must be explicitly configured")
    assert(config.palReconciliation.enabled == true, "Pal reconciliation core must be enabled")
    assert(config.palReconciliation.normalizedRaidAdapterEnabled == true, "normalized Pal raid-result adapter must be enabled")
    assert(config.palReconciliation.nativeRaidResultBindingEnabled == true, "Pal raid-result native binding must be enabled")
    assert(config.palReconciliation.attendanceRaidResultBindingEnabled == true, "Pal raid-result attendance binding must be enabled")
    assert(type(config.palReconciliation.nativeRaidLiveTest) == "table", "Pal raid native live-test configuration is required")
    assert(type(config.palReconciliation.nativeRaidLiveTest.enabled) == "boolean", "Pal raid native live-test flag is required")
    assert(config.palReconciliation.leaderDesignation == "first-spawn-of-final-wave", "unsupported Pal raid leader designation")
    assert(config.palReconciliation.offlineDialogueTreeEnabled == true, "offline Pal dialogue-tree runtime must be enabled")
    assert(config.palReconciliation.dialoguePresenterRouterEnabled == true, "Pal dialogue presenter router must be enabled")
    assert(config.palReconciliation.representativeInteractionRouterEnabled == true, "Pal representative interaction router must be enabled")
    assert(type(config.palReconciliation.representativeInteractionDistance) == "number", "Pal representative interaction distance is required")
    assert(config.palReconciliation.nativeDialoguePresenterEnabled == true, "Pal dialogue presenter must be enabled")
    assert(config.palReconciliation.agentAdapterEnabled == true, "presentation-only Pal Agent adapter must be enabled")
    assert(config.palReconciliation.storyContentIncluded == false, "base Mod cannot include authored Pal reconciliation stories")
    assert(type(config.factionUi) == "table", "faction UI must be explicitly configured")
    assert(type(config.factionUi.enabled) == "boolean", "faction UI enabled flag is required")
    assert(type(config.factionUi.key) == "string", "faction UI key is required")
    assert(type(config.factionCommerce) == "table", "faction commerce must be explicitly configured")
    assert(config.factionCommerce.enabled == true, "faction commerce core must be enabled")
    assert(type(config.factionCommerce.nativeBridgeEnabled) == "boolean", "native commerce bridge flag is required")
    assert(type(config.factionCommerce.nativeSaleReplicationProbeEnabled) == "boolean", "native sale replication probe flag is required")
    assert(type(config.factionCommerce.nativeEconomyMerchantSpawnEnabled) == "boolean", "native economy merchant spawn flag is required")
    assert(type(config.factionCommerce.nativeFactionMerchantSpawnEnabled) == "boolean", "native faction merchant spawn flag is required")
    assert(type(config.factionCommerce.nativeCharacterAdapter) == "table", "native character adapter configuration is required")
    assert(type(config.factionCommerce.nativeCharacterAdapter.enabled) == "boolean", "native character adapter enabled flag is required")
    assert(type(config.factionCommerce.nativeCharacterAdapter.merchantSpawnerClassPath) == "string" and config.factionCommerce.nativeCharacterAdapter.merchantSpawnerClassPath ~= "", "ordinary merchant spawner class is required")
    assert(type(config.factionCommerce.nativeCharacterAdapter.merchantDefaultActionClassPath) == "string" and config.factionCommerce.nativeCharacterAdapter.merchantDefaultActionClassPath ~= "", "merchant salesperson action class is required")
    assert(type(config.factionCommerce.economyMerchantLiveTest) == "table", "economy merchant live-test configuration is required")
    assert(type(config.factionCommerce.economyMerchantLiveTest.enabled) == "boolean", "economy merchant live-test flag is required")
    assert(type(config.factionCommerce.economyMerchantPresence) == "table", "economy merchant presence configuration is required")
    assert(type(config.factionCommerce.economyMerchantPresence.enabled) == "boolean", "economy merchant presence flag is required")
    assert(type(config.factionCommerce.economyMerchantPresence.activationRadius) == "number", "economy merchant activation radius is required")
    assert(type(config.factionCommerce.economyMerchantPresence.deactivationRadius) == "number", "economy merchant deactivation radius is required")
    assert(type(config.factionCommerce.economyMerchantPresence.pollIntervalMs) == "number", "economy merchant poll interval is required")
    assert(type(config.factionCommerce.economyMerchantPresence.initialDelayMs) == "number", "economy merchant initial delay is required")
    if config.factionCommerce.economyMerchantPresence.enabled == true then
        assert(config.factionCommerce.nativeEconomyMerchantSpawnEnabled == true, "merchant presence requires native economy merchant spawn")
    end
    assert(type(config.factionProgression.playerGuard) == "table", "player guard configuration is required")
    assert(type(config.factionProgression.playerGuard.nativePlayerGuardEnabled) == "boolean", "native player guard flag is required")
    assert(type(config.factionProgression.playerGuard.controllerClassPath) == "string" and config.factionProgression.playerGuard.controllerClassPath ~= "", "player guard controller class is required")
    assert(type(config.factionProgression.playerGuard.liveTest) == "table", "player guard live-test configuration is required")
    assert(type(config.factionProgression.playerGuard.liveTest.enabled) == "boolean", "player guard live-test flag is required")
    assert(type(config.factionProgression.persistence) == "table", "progression persistence must be explicitly configured")
    assert(config.factionProgression.persistence.mode == "mod-sidecar-json", "unsupported progression persistence mode")
    assert(type(config.factionProgression.persistence.identityProbe) == "table", "progression identity probe must be explicitly configured")
    assert(type(config.factionProgression.persistence.identityProbe.enabled) == "boolean", "progression identity probe flag is required")
    assert(config.factionProgression.persistence.identityProbe.readOnly == true, "progression identity probe must remain read-only")
    assert(type(config.factionProgression.persistence.identityProbe.retryDelaysMs) == "table", "progression identity retry delays are required")
    assert(#config.factionProgression.persistence.identityProbe.retryDelaysMs > 0, "progression identity retry delays cannot be empty")
    assert(type(config.factionProgression.persistence.rootPath) == "string" and config.factionProgression.persistence.rootPath ~= "", "Mod-owned progression sidecar root is required")
    assert(config.factionProgression.persistence.enabled == true, "external progression sidecar must be enabled")
    assert(config.factionProgression.persistence.deferredIdentity == true, "external progression sidecar must wait for native identity")
    assert(type(config.factionProgression.persistence.companionLedgerEnabled) == "boolean", "companion ledger flag is required")
    assert(config.enableSaveWrites == false, "Mod 0 must not write save data")

    local state = make_state(config, registry)
    state.progressionStore = ProgressionStore.create(
        {
            enabled = false,
            mode = config.factionProgression.persistence.mode,
            reason = "native-world-player-identity-pending",
        }
    )
    state.companionLedger = CompanionLedger.create({
        enabled = config.factionProgression.persistence
            .companionLedgerEnabled,
        rootPath = config.factionProgression.persistence.rootPath,
        reason = "native-world-player-identity-pending",
    })
    local restored_snapshot = nil
    local restore_source = "initial"
    if state.progressionStore.enabled then
        local restored, restore_error = state.progressionStore:load()
        if restored ~= nil then
            restored_snapshot = restored.snapshot
            restore_source = restored.source
        elseif restore_error ~= "primary=not-found;backup=not-found" then
            error("progression sidecar recovery failed: " .. tostring(restore_error))
        end
    end
    state.factionProgression = FactionProgression.create(
        registry.progression,
        restored_snapshot
    )
    local progression_events = sync_progression_relations(policy, state)
    local function publish_companion_state(reason)
        if state.companionLedger == nil
            or not state.companionLedger:status().active then
            return false, "companion-profile-not-active"
        end
        return state.companionLedger:publish({
            releaseId = config.releaseId,
            expectedSteamBuildId = config.expectedSteamBuildId,
            reason = reason or "state-refresh",
            progression =
                state.factionProgression:export_snapshot(),
            gates = state.factionProgression:gate_status(),
            commerce = state.factionCommerce
                    and state.factionCommerce:status()
                or nil,
            commerceBridge = state.commerceBridge
                    and state.commerceBridge:status()
                or nil,
        })
    end
    state.publishCompanionState = publish_companion_state

    local function on_faction_state_changed(
        faction_id,
        outcome,
        faction_status
    )
            sync_progression_relations(policy, state)
            if state.progressionStore.enabled then
                local save_result = state.progressionStore:save(
                    state.factionProgression:export_snapshot()
                )
                if not save_result.ok then
                    log(
                        "FACTION_PROGRESSION_SAVE_FAILED reason="
                            .. tostring(save_result.reason)
                    )
                end
            end
            if state.companionLedger ~= nil
                and state.companionLedger:status().active then
                state.companionLedger:record({
                    type = "progression-changed",
                    factionId = faction_id,
                    outcome = outcome,
                    faction = faction_status,
                })
                publish_companion_state("progression-changed")
            end
            if state.rayneMerchant ~= nil
                and faction_id == config.rayneMerchant.factionId then
                local relation = state.relations[faction_id]
                state.rayneMerchant:on_relation_changed(
                    relation and relation.state or "Friendly"
                )
            end
            if state.factionMerchantRuntime ~= nil then
                state.factionMerchantRuntime
                    :refresh_relations()
            end
            if state.factionUiPresenter ~= nil then
                state.factionUiPresenter:refresh()
            end
    end
    state.factionApi = FactionApi.create(
        state.factionProgression,
        on_faction_state_changed
    )
    _G.PWFT_FACTION_API_V1 = state.factionApi
    state.palReconciliation = PalReconciliation.create(
        registry.palReconciliation,
        state.factionProgression,
        {
            onChange = on_faction_state_changed,
        }
    )
    _G.PWFT_PAL_RECONCILIATION_API_V1 =
        state.palReconciliation
    state.palRaidResultAdapter =
        PalRaidResultAdapter.create(
            state.palReconciliation,
            config.palReconciliation
        )
    _G.PWFT_PAL_RAID_RESULT_ADAPTER_V1 =
        state.palRaidResultAdapter
    state.palRaidNativeBinding =
        PalRaidNativeBinding.create(
            state.palRaidResultAdapter,
            config.palReconciliation,
            {
                logger = log,
            }
        )
    _G.PWFT_PAL_RAID_NATIVE_BINDING_V1 =
        state.palRaidNativeBinding
    state.palDiscourseRuntime =
        PalDiscourseRuntime.create(
            state.palReconciliation,
            config.palReconciliation
        )
    _G.PWFT_PAL_DISCOURSE_API_V1 =
        state.palDiscourseRuntime
    state.palDialogueController =
        PalDialogueController.create(
            state.palDiscourseRuntime,
            config.palReconciliation
        )
    _G.PWFT_PAL_DIALOGUE_CONTROLLER_V1 =
        state.palDialogueController
    state.palDialogueNativeBackend =
        PalDialogueNativeBackend.create(
            config.palReconciliation
        )
    _G.PWFT_PAL_DIALOGUE_PRESENTER_BRIDGE_V1 =
        state.palDialogueNativeBackend
    state.palDialoguePresenter =
        PalDialoguePresenter.create(
            state.palDialogueController,
            config.palReconciliation
        )
    _G.PWFT_PAL_DIALOGUE_PRESENTER_V1 =
        state.palDialoguePresenter
    state.palRepresentativeInteraction =
        PalRepresentativeInteraction.create(
            state.palDiscourseRuntime,
            state.palDialoguePresenter,
            config.palReconciliation
        )
    _G.PWFT_PAL_REPRESENTATIVE_INTERACTION_V1 =
        state.palRepresentativeInteraction
    state.palRepresentativeNativeRouter =
        PalRepresentativeNativeRouter.create(
            state.palRepresentativeInteraction,
            state.palDialoguePresenter,
            state.palDialogueNativeBackend,
            config.palReconciliation
        )
    local pal_native_router_started,
        pal_native_router_error =
            state.palRepresentativeNativeRouter:start()
    _G.PWFT_PAL_REPRESENTATIVE_NATIVE_ROUTER_V1 =
        state.palRepresentativeNativeRouter
    state.contentPackRegistry = ContentPackRegistry.create({
        coreVersion = config.schemaVersion,
    })
    state.localizationRuntime = LocalizationRuntime.create(
        state.contentPackRegistry,
        {
            fallbackLocale = config.contentModules.fallbackLocale,
        }
    )
    state.questRuntime = QuestRuntime.create(
        state.factionProgression,
        state.contentPackRegistry,
        {
            onChange = on_faction_state_changed,
        }
    )
    state.strategicWorld = StrategicWorld.create(
        state.factionProgression,
        {
            onChange = on_faction_state_changed,
            contentPackRegistry = state.contentPackRegistry,
        }
    )
    state.endingRuntime = EndingRuntime.create(
        state.factionProgression,
        state.strategicWorld,
        {
            onChange = on_faction_state_changed,
            contentPackRegistry = state.contentPackRegistry,
        }
    )
    state.contentRuntime = ContentRuntime.create(
        state.factionProgression,
        state.contentPackRegistry,
        state.questRuntime,
        state.strategicWorld,
        state.endingRuntime,
        {
            palDiscourseRuntime = state.palDiscourseRuntime,
            localizationRuntime = state.localizationRuntime,
        }
    )
    _G.PWFT_CONTENT_PACK_API_V1 = state.contentPackRegistry
    _G.PWFT_CONTENT_RUNTIME_API_V1 = state.contentRuntime
    _G.PWFT_QUEST_API_V1 = state.questRuntime
    _G.PWFT_STRATEGIC_WORLD_API_V1 = state.strategicWorld
    _G.PWFT_ENDING_API_V1 = state.endingRuntime
    _G.PWFT_LOCALIZATION_RESOLVER_V1 =
        state.localizationRuntime
    state.contentModuleLoader = ContentModuleLoader.create(
        state.contentRuntime,
        config.contentModules,
        {
            contentRuntime = state.contentRuntime,
            contentPackRegistry = state.contentPackRegistry,
            localizationRuntime = state.localizationRuntime,
            questRuntime = state.questRuntime,
            strategicWorld = state.strategicWorld,
            endingRuntime = state.endingRuntime,
            palReconciliation = state.palReconciliation,
            palDiscourseRuntime = state.palDiscourseRuntime,
            palRepresentativeInteraction =
                state.palRepresentativeInteraction,
        },
        {
            logger = log,
        }
    )
    state.contentModuleLoadResult =
        state.contentModuleLoader:load()
    _G.PWFT_CONTENT_MODULE_LOADER_V1 =
        state.contentModuleLoader
    for _, source in ipairs(
        state.palDiscourseRuntime:export_native_raid_sources()
    ) do
        local registered = state.palRaidNativeBinding
            :register_source(
                source.groupName,
                source.factionId,
                source
            )
        assert(
            registered.ok,
            "Pal native raid content binding failed: "
                .. tostring(source.groupName)
        )
    end
    local raid_live_test =
        config.palReconciliation.nativeRaidLiveTest
    if raid_live_test.enabled == true then
        local current = state.palReconciliation:status(
            raid_live_test.palFactionId
        )
        if current.configured ~= true then
            local qa_content = state.palReconciliation
                :register_content(
                    raid_live_test.palFactionId,
                    {
                        contentPackId =
                            raid_live_test.contentPackId,
                        contentVersion =
                            raid_live_test.contentVersion,
                        tokenQuota = raid_live_test.tokenQuota,
                        maximumAffinityPerDiscourse =
                            raid_live_test
                                .maximumAffinityPerDiscourse,
                    }
                )
            assert(
                qa_content.ok,
                "Pal native raid QA content registration failed"
            )
        end
        local qa_source = state.palRaidNativeBinding
            :register_source(
                raid_live_test.groupName,
                raid_live_test.palFactionId,
                {
                    contentPackId =
                        raid_live_test.contentPackId,
                    contentVersion =
                        raid_live_test.contentVersion,
                }
            )
        assert(
            qa_source.ok,
            "Pal native raid QA source registration failed"
        )
        log(string.format(
            "PAL_RAID_NATIVE_LIVE_TEST_ARMED group=%s faction=%s quota=%d",
            raid_live_test.groupName,
            raid_live_test.palFactionId,
            raid_live_test.tokenQuota
        ))
    end
    state.palRaidNativeStartResult =
        state.palRaidNativeBinding:start()
    state.factionJoin = FactionJoin.create(
        state.factionApi,
        registry.progression.membershipPolicy
            .joinInteraction
    )
    for _, faction_id in ipairs(
        registry.progression.humanFactionIds
    ) do
        local source_suffix = string.gsub(
            faction_id,
            "^pwft%.faction%.",
            ""
        )
        local registration =
            state.factionJoin:register_source(
                "pwft.join.source." .. source_suffix,
                faction_id,
                {
                    sourceKind =
                        "content-faction-representative",
                    bindingStatus =
                        "native-router-ready-content-actor-binding-required",
                }
            )
        assert(
            registration.ok,
            "join source registration failed: "
                .. faction_id
        )
    end
    _G.PWFT_JOIN_API_V1 = state.factionJoin
    state.factionJoinNativePresenter =
        FactionJoinNativePresenter.create(
            state.palDialogueNativeBackend
        )
    local join_presenter_registration =
        state.factionJoin:register_presenter(
            state.factionJoinNativePresenter
        )
    assert(
        join_presenter_registration.ok,
        "native faction join presenter registration failed"
    )
    state.factionJoinNativeRouter =
        FactionJoinNativeRouter.create(
            state.factionJoin,
            state.factionJoinNativePresenter,
            state.palDialogueNativeBackend,
            config.factionProgression.joinRepresentative
        )
    local join_native_started, join_native_error =
        state.factionJoinNativeRouter:start()
    state.factionJoinNativeStartError = join_native_error
    _G.PWFT_FACTION_JOIN_NATIVE_ROUTER_V1 =
        state.factionJoinNativeRouter
    state.factionEconomy = FactionEconomy.create(
        registry.economy
    )
    state.factionEconomyShops =
        FactionEconomyShopCatalog.create(
            registry.economyShops,
            state.factionEconomy
        )
    state.factionCommerce = FactionCommerce.create(
        registry.commerce,
        state.factionApi,
        {
            requestedItemResolver = function(
                faction_id,
                item_id
            )
                return state.factionEconomyShops
                    :is_requested_item(
                        faction_id,
                        item_id
                    )
            end,
            requestedItemSource =
                "faction-economy-commodity-signals-v1",
        }
    )
    state.commerceBridge = CommerceBridge.create(
        state.factionCommerce,
        {
            logger = log,
            eventSink = function(event)
                if state.companionLedger ~= nil
                    and state.companionLedger:status().active then
                    state.companionLedger:record(event)
                    publish_companion_state("commerce-event")
                end
            end,
            nativeSaleReplicationProbeEnabled =
                config.factionCommerce
                    .nativeSaleReplicationProbeEnabled,
            nativeSaleReputationSettlementEnabled =
                registry.economy.runtimeActivation
                    .requestedSaleReputationSettlementEnabled,
        }
    )
    if config.factionCommerce.nativeBridgeEnabled then
        state.commerceBridge:start()
    end
    state.factionDefense = FactionDefense.create(state.factionApi)
    state.factionGuard = FactionGuard.create(state.factionApi)
    state.nativeCharacterAdapter = nil
    if config.factionCommerce.nativeCharacterAdapter.enabled then
        state.nativeCharacterAdapter = NativeCharacterAdapter.create({
            -- UE4SS resolves FName lazily through its Lua global resolver.
            -- Keep the lookup inside the live callback instead of capturing
            -- the resolver value while the adapter module is initialising.
            fName = function(value)
                return FName(value)
            end,
            collisionHandlingOverride =
                config.factionCommerce.nativeCharacterAdapter
                    .collisionHandlingOverride,
            restockMinutes =
                config.factionCommerce.nativeCharacterAdapter
                    .restockMinutes,
            refreshVendorOnSpawn =
                config.factionCommerce.nativeCharacterAdapter
                    .refreshVendorOnSpawn,
            controllerClassPath =
                "/Game/Pal/Blueprint/Controller/NPC/BP_NPCAIController.BP_NPCAIController_C",
            guardControllerClassPath =
                config.factionProgression.playerGuard
                    .controllerClassPath,
            guardFollowIntervalMs =
                config.factionProgression.playerGuard
                    .followIntervalMs,
            guardAcceptanceRadius =
                config.factionProgression.playerGuard
                    .acceptanceRadius,
            guardFollowMaxFailures =
                config.factionProgression.playerGuard
                    .followFailureLimit,
            merchantSpawnerClassPath =
                config.factionCommerce.nativeCharacterAdapter
                    .merchantSpawnerClassPath,
            merchantDefaultActionClassPath =
                config.factionCommerce.nativeCharacterAdapter
                    .merchantDefaultActionClassPath,
            asyncMerchantSpawnerEnabled =
                config.factionCommerce.nativeCharacterAdapter
                    .asyncMerchantSpawnerEnabled,
            merchantLevel = 30,
            nativeSetupRetryMs =
                config.rayneMerchant.nativeSetupRetryMs,
            nativeSetupMaxAttempts =
                config.rayneMerchant.nativeSetupMaxAttempts,
            nativeActorFallbackAttempt =
                config.rayneMerchant.nativeActorFallbackAttempt,
            nativeActorFallbackRadius =
                config.rayneMerchant.nativeActorFallbackRadius,
            logger = log,
        })
        for _, merchant in ipairs(registry.commerce.factions) do
            local guard_id = merchant.guardCharacterIds[1]
            local guard_class_path =
                merchant.guardCharacterClassPaths[1]
            if config.factionProgression.playerGuard
                    .nativePlayerGuardEnabled
                and guard_id ~= nil
                and guard_class_path ~= nil then
                local provider =
                    state.nativeCharacterAdapter
                        :create_guard_provider(
                            guard_id,
                            guard_class_path
                        )
                local registered =
                    state.factionGuard:register_provider(
                        merchant.factionId,
                        provider
                    )
                assert(
                    registered.ok,
                    "native guard provider registration failed:"
                        .. merchant.factionId
                )
            end
        end
    end
    state.factionMerchantRuntime = FactionMerchantRuntime.create(
        registry.commerce,
        state.factionApi,
        state.commerceBridge,
        state.nativeCharacterAdapter
    )
    state.factionEconomyMerchantRuntime =
        FactionEconomyMerchantRuntime.create(
            state.factionEconomyShops,
            registry.commerce,
            state.factionApi,
            state.commerceBridge,
            state.nativeCharacterAdapter,
            {
                activationAuthorized =
                    config.factionCommerce
                        .nativeEconomyMerchantSpawnEnabled,
            }
        )
    state.factionEconomyMerchantPresence =
        FactionEconomyMerchantPresence.create(
            state.factionEconomyMerchantRuntime,
            registry.commerce,
            config.factionCommerce.economyMerchantPresence
        )
    state.factionUiModel = FactionUiModel.create(
        registry,
        state.factionProgression,
        state.factionCommerce,
        state.factionGuard,
        state.palReconciliation
    )
    state.factionUiPresenter = FactionUiPresenter.create(
        state.factionUiModel,
        config.factionUi
    )
    local faction_ui_bound, faction_ui_bind_reason =
        state.factionUiPresenter:start()
    state.onProgressionIdentityReady = function(identity)
        if state.progressionStore.enabled
            and state.progressionStore.profileKey
                == identity.profileKey then
            return true, "already-active"
        end
        local store = ProgressionStore.create({
            enabled = true,
            mode = config.factionProgression.persistence.mode,
            profileKey = identity.profileKey,
            rootPath = config.factionProgression.persistence.rootPath,
        })
        local restored, restore_error = store:load()
        local restore_source = "initial"
        if restored ~= nil then
            local current = state.factionProgression:status()
            if current.revision == 0 then
                state.factionProgression:restore_snapshot(
                    restored.snapshot
                )
                sync_progression_relations(policy, state)
                restore_source = restored.source
            else
                restore_source = "live-state-newer-than-sidecar"
            end
        elseif restore_error
            ~= "primary=not-found;backup=not-found" then
            log(
                "FACTION_PROGRESSION_RECOVERY_BLOCKED reason="
                    .. tostring(restore_error)
            )
            return false, "sidecar-recovery-blocked"
        end

        state.progressionStore = store
        local save_result = store:save(
            state.factionProgression:export_snapshot()
        )
        if not save_result.ok then
            return false, save_result.reason
        end
        local ledger_ok, ledger_reason =
            state.companionLedger:activate(identity)
        if not ledger_ok then
            return false, ledger_reason
        end
        state.companionLedger:record({
            type = "progression-sidecar-ready",
            restoreSource = restore_source,
            revision = state.factionProgression:status().revision,
        })
        publish_companion_state("identity-ready")
        if state.factionMerchantRuntime ~= nil then
            state.factionMerchantRuntime:refresh_relations()
        end
        if state.factionUiPresenter ~= nil then
            state.factionUiPresenter:refresh()
        end
        return true, "active:" .. restore_source
    end
    _G.PWFT_COMMERCE_API_V1 = state.factionCommerce
    _G.PWFT_ECONOMY_API_V1 = state.factionEconomy
    _G.PWFT_ECONOMY_SHOP_API_V1 =
        state.factionEconomyShops
    _G.PWFT_COMMERCE_BRIDGE_V1 = state.commerceBridge
    _G.PWFT_DEFENSE_API_V1 = state.factionDefense
    _G.PWFT_GUARD_API_V1 = state.factionGuard
    _G.PWFT_NATIVE_CHARACTER_ADAPTER_V1 =
        state.nativeCharacterAdapter
    _G.PWFT_MERCHANT_RUNTIME_V1 = state.factionMerchantRuntime
    _G.PWFT_ECONOMY_MERCHANT_RUNTIME_V1 =
        state.factionEconomyMerchantRuntime
    _G.PWFT_ECONOMY_MERCHANT_PRESENCE_V1 =
        state.factionEconomyMerchantPresence
    _G.PWFT_FACTION_UI_MODEL_V1 = state.factionUiModel
    _G.PWFT_FACTION_UI_V1 = state.factionUiPresenter
    _G.PWFT_COMPANION_LEDGER_V1 = state.companionLedger
    log(string.format(
        "FACTION_PROGRESSION_READY api=%s factions=%d human=%d pal=%d persistence=%s restore=%s",
        state.factionApi.version,
        #progression_events,
        #registry.progression.humanFactionIds,
        #registry.progression.palFactionIds,
        state.progressionStore.enabled and config.factionProgression.persistence.mode or "disabled",
        restore_source
    ))
    local pal_reconciliation_status =
        state.palReconciliation:status()
    log(string.format(
        "PAL_RECONCILIATION_READY api=%s configured=%d/%d nativeRaid=%s nativeDialogue=%s agent=%s recovered=%d",
        state.palReconciliation.version,
        pal_reconciliation_status.configuredFactionCount,
        pal_reconciliation_status.palFactionCount,
        tostring(pal_reconciliation_status.nativeRaidResultBindingEnabled),
        tostring(pal_reconciliation_status.nativeDialoguePresenterEnabled),
        tostring(pal_reconciliation_status.agentAdapterEnabled),
        pal_reconciliation_status.recoveredInterruptedSessionCount
    ))
    local pal_raid_adapter_status =
        state.palRaidResultAdapter:status()
    log(string.format(
        "PAL_RAID_RESULT_ADAPTER_READY api=%s normalized=%s nativeBinding=%s leader=%s timerSettlement=%s",
        pal_raid_adapter_status.apiVersion,
        tostring(pal_raid_adapter_status.normalizedRaidAdapterEnabled),
        tostring(pal_raid_adapter_status.nativeRaidResultBindingEnabled),
        pal_raid_adapter_status.leaderDesignation,
        tostring(pal_raid_adapter_status.timerCleanupMaySettleRaid)
    ))
    local pal_raid_native_status =
        state.palRaidNativeBinding:status()
    log(string.format(
        "PAL_RAID_NATIVE_BINDING_STATUS api=%s enabled=%s ready=%s hooks=%d/%d sources=%d active=%d failures=%d",
        pal_raid_native_status.apiVersion,
        tostring(pal_raid_native_status.enabled),
        tostring(pal_raid_native_status.ready),
        pal_raid_native_status.hookCount,
        pal_raid_native_status.requiredHookCount,
        pal_raid_native_status.sourceCount,
        pal_raid_native_status.activeEventCount,
        pal_raid_native_status.failures
    ))
    local pal_discourse_status =
        state.palDiscourseRuntime:status()
    log(string.format(
        "PAL_DISCOURSE_RUNTIME_READY api=%s factions=%d representatives=%d offlineTree=%s nativePresenter=%s story=%s localizationKeysOnly=%s",
        pal_discourse_status.apiVersion,
        pal_discourse_status.registeredFactionCount,
        pal_discourse_status.registeredRepresentativeCount,
        tostring(pal_discourse_status.offlineDialogueTreeEnabled),
        tostring(pal_discourse_status.nativeDialoguePresenterEnabled),
        tostring(pal_discourse_status.baseStoryContentIncluded),
        tostring(pal_discourse_status.localizationKeysOnly)
    ))
    local pal_dialogue_status =
        state.palDialogueController:status()
    log(string.format(
        "PAL_DIALOGUE_CONTROLLER_READY api=%s agent=%s bridge=%s offlineFallback=%s playerConfirmation=%s directAgentMutation=%s nativePresenter=%s",
        pal_dialogue_status.apiVersion,
        tostring(pal_dialogue_status.enabled),
        tostring(pal_dialogue_status.bridgeAvailable),
        tostring(pal_dialogue_status.offlineTreeFallback),
        tostring(pal_dialogue_status.proposalRequiresPlayerConfirmation),
        tostring(pal_dialogue_status.directAgentStateMutation),
        tostring(pal_dialogue_status.nativePresenterEnabled)
    ))
    local pal_dialogue_presenter_status =
        state.palDialoguePresenter:status()
    log(string.format(
        "PAL_DIALOGUE_PRESENTER_READY api=%s router=%s backend=%s native=%s localizationKeys=%s generatedDialogue=%s explicitAbort=%s directMutation=%s",
        pal_dialogue_presenter_status.apiVersion,
        tostring(pal_dialogue_presenter_status.enabled),
        tostring(pal_dialogue_presenter_status.backendAvailable),
        tostring(pal_dialogue_presenter_status.nativePresenterEnabled),
        tostring(pal_dialogue_presenter_status.localizationKeyPresentation),
        tostring(pal_dialogue_presenter_status.generatedDialoguePresentation),
        tostring(pal_dialogue_presenter_status.explicitAbortRequired),
        tostring(pal_dialogue_presenter_status.directPresenterStateMutation)
    ))
    local representative_interaction_status =
        state.palRepresentativeInteraction:status()
    log(string.format(
        "PAL_REPRESENTATIVE_INTERACTION_READY api=%s router=%s bindings=%d proximity=%s distance=%.0f confirmation=%s presenterGate=%s nativeDelegate=%s directMutation=%s",
        representative_interaction_status.apiVersion,
        tostring(representative_interaction_status.enabled),
        representative_interaction_status.registeredBindingCount,
        tostring(representative_interaction_status.proximityGate),
        representative_interaction_status.defaultMaximumDistance,
        tostring(representative_interaction_status.explicitIrreversibleConfirmation),
        tostring(representative_interaction_status.presenterReadinessBeforeTokenConsume),
        tostring(representative_interaction_status.nativeDelegateBinding),
        tostring(representative_interaction_status.directInteractionStateMutation)
    ))
    local native_dialogue_backend_status =
        state.palDialogueNativeBackend:status()
    local native_representative_status =
        state.palRepresentativeNativeRouter:status()
    log(string.format(
        "PAL_NATIVE_DIALOGUE_READY backend=%s widget=%s routerStarted=%s hook=%s keys=%d exactActor=%s confirmation=%s story=%s error=%s",
        tostring(native_dialogue_backend_status.enabled),
        tostring(native_dialogue_backend_status.widgetReady),
        tostring(pal_native_router_started),
        tostring(native_representative_status.nativeHookReady),
        native_representative_status.keyBindingCount,
        tostring(native_representative_status.exactRegisteredActorOnly),
        tostring(native_representative_status.explicitIrreversibleConfirmation),
        tostring(native_representative_status.storyContentIncluded),
        tostring(pal_native_router_error or "none")
    ))
    local strategic_world_status = state.strategicWorld:status()
    local content_pack_status = state.contentPackRegistry:status()
    local content_runtime_status = state.contentRuntime:status()
    local localization_status = state.localizationRuntime:status()
    local content_module_status = state.contentModuleLoader:status()
    local quest_status = state.questRuntime:status()
    log(string.format(
        "CONTENT_PACK_RUNTIME_READY api=%s core=%s packs=%d manifestsDataOnly=%s",
        content_pack_status.apiVersion,
        content_pack_status.coreVersion,
        content_pack_status.registeredPackCount,
        tostring(not content_pack_status.manifestMayExecuteCode)
    ))
    log(string.format(
        "CONTENT_RUNTIME_READY api=%s bundles=%d atomic=%s modelRegister=%s story=false",
        content_runtime_status.apiVersion,
        content_runtime_status.registeredBundleCount,
        tostring(content_runtime_status.atomicCrossDomainValidation),
        tostring(content_runtime_status.modelMayRegisterContent)
    ))
    log(string.format(
        "LOCALIZATION_RUNTIME_READY api=%s packs=%d locales=%d messages=%d fallback=%s story=false",
        localization_status.apiVersion,
        localization_status.registeredPackCount,
        localization_status.localeCount,
        localization_status.messageCount,
        localization_status.fallbackLocale
    ))
    log(string.format(
        "CONTENT_MODULE_LOADER_READY api=%s enabled=%s configured=%d registered=%d activated=%d failed=%d internalRequire=%s crossModGlobals=%s story=false",
        content_module_status.apiVersion,
        tostring(content_module_status.enabled),
        content_module_status.configuredModuleCount,
        content_module_status.registeredCount,
        content_module_status.activatedCount,
        content_module_status.failedCount,
        tostring(content_module_status.internalRequireOnly),
        tostring(content_module_status.crossModGlobalsRequired)
    ))
    log(string.format(
        "QUEST_RUNTIME_READY api=%s templates=%d instances=%d active=%d story=false localizationKeysOnly=%s",
        quest_status.apiVersion,
        quest_status.templateCount,
        quest_status.questInstanceCount,
        quest_status.activeQuestCount,
        tostring(quest_status.localizationKeysOnly)
    ))
    log(string.format(
        "STRATEGIC_WORLD_READY api=%s packs=%d uniquePals=%d cities=%d ultimatums=%d story=false",
        strategic_world_status.apiVersion,
        strategic_world_status.contentPackCount,
        strategic_world_status.uniquePalCount,
        strategic_world_status.cityCount,
        strategic_world_status.ultimatumCount
    ))
    local ending_status = state.endingRuntime:status()
    log(string.format(
        "ENDING_RUNTIME_READY api=%s packs=%d routes=%d completed=%s story=false modelCommit=false",
        ending_status.apiVersion,
        ending_status.contentPackCount,
        ending_status.routeCount,
        tostring(ending_status.completedRouteId)
    ))
    local join_status = state.factionJoin:status()
    log(string.format(
        "FACTION_JOIN_READY api=%s sources=%d presenter=%s nativeRouter=%s bindings=%d confirmation=F1/F2 dialogue=false story=false",
        state.factionJoin.version,
        join_status.sourceCount,
        tostring(join_status.presenterReady),
        tostring(join_native_started == true),
        state.factionJoinNativeRouter:status().bindingCount
    ))
    local commerce_status = state.factionCommerce:status()
    log(string.format(
        "FACTION_COMMERCE_READY api=%s factions=%d hooks=%d island=%s sell=%s",
        state.factionCommerce.version,
        commerce_status.factionCount,
        state.commerceBridge:status().hookCount,
        commerce_status.merchantIslandPlacementStatus,
        commerce_status.sellSettlementStatus
    ))
    local economy_status = state.factionEconomy:status()
    log(string.format(
        "FACTION_ECONOMY_READY api=%s factions=%d resources=%d products=%d closedLoop=%d merchantInputs=%d unresolved=%d customRows=%s dynamicPrices=%s settlement=%s balanceProfile=%s balanceRuntime=%s",
        state.factionEconomy.version,
        economy_status.factionCount,
        economy_status.resourceCount,
        economy_status.auditedProductCount,
        economy_status.closedLoopProductCount,
        economy_status.merchantSuppliedInputProductCount,
        economy_status.unresolvedProductCount,
        tostring(economy_status.customProductRowsEnabled),
        tostring(economy_status.dynamicPriceRuntimeEnabled),
        tostring(
            economy_status.requestedSaleReputationSettlementEnabled
        ),
        economy_status.balanceProfileId,
        tostring(economy_status.balanceRuntimeAuthority)
    ))
    local economy_shop_status =
        state.factionEconomyShops:status()
    log(string.format(
        "FACTION_ECONOMY_SHOPS_READY api=%s representatives=%d products=%d requested=%d signals=%d rowsReady=%s rowsEnabled=%s nativeSpawn=%s shopBinding=%s restock=%s moneyBonus=%s reputation=%s placement=%s serverSuccess=%s",
        state.factionEconomyShops.version,
        economy_shop_status.representativeCount,
        economy_shop_status.productRowCount,
        economy_shop_status.requestedItemCount,
        economy_shop_status.marketSignalCount,
        tostring(economy_shop_status.customProductRowsReady),
        tostring(economy_shop_status.customProductRowsEnabled),
        tostring(economy_shop_status.nativeMerchantSpawnEnabled),
        tostring(economy_shop_status.nativeShopBindingEnabled),
        tostring(economy_shop_status.dynamicRestockEnabled),
        tostring(economy_shop_status.procurementMoneyBonusEnabled),
        tostring(
            economy_shop_status
                .procurementCommerceReputationEnabled
        ),
        economy_shop_status.merchantIslandPlacementStatus,
        economy_shop_status.serverSuccessSignalStatus
    ))
    local merchant_runtime_status = state.factionMerchantRuntime:status()
    log(string.format(
        "FACTION_MERCHANT_RUNTIME_READY api=%s nativeSpawn=%s adapter=%s fixedActive=%d caravans=%d placement=%s reason=%s",
        state.factionMerchantRuntime.version,
        tostring(
            config.factionCommerce.nativeFactionMerchantSpawnEnabled
        ),
        tostring(merchant_runtime_status.adapterReady),
        merchant_runtime_status.fixedActiveCount,
        merchant_runtime_status.caravanActiveCount,
        merchant_runtime_status.marketPlacementStatus,
        config.factionCommerce.nativeFactionMerchantSpawnReason
    ))
    local economy_merchant_runtime_status =
        state.factionEconomyMerchantRuntime:status()
    log(string.format(
        "FACTION_ECONOMY_MERCHANT_RUNTIME_READY api=%s authorised=%s counters=%d active=%d rows=%s binding=%s placement=%s reason=%s",
        state.factionEconomyMerchantRuntime.version,
        tostring(
            economy_merchant_runtime_status
                .activationAuthorized
        ),
        economy_merchant_runtime_status.representativeCount,
        economy_merchant_runtime_status.activeCount,
        tostring(
            economy_merchant_runtime_status
                .customProductRowsEnabled
        ),
        tostring(
            economy_merchant_runtime_status
                .nativeShopBindingEnabled
        ),
        economy_merchant_runtime_status.placementStatus,
        config.factionCommerce.nativeEconomyMerchantSpawnReason
    ))
    log(string.format(
        "FACTION_UI_READY api=%s enabled=%s key=%s bound=%s status=%s",
        state.factionUiPresenter.version,
        tostring(config.factionUi.enabled),
        config.factionUi.key,
        tostring(faction_ui_bound),
        tostring(
            faction_ui_bind_reason
                or state.factionUiPresenter:status().renderingStatus
        )
    ))
    state.rayneMerchant = RayneMerchant.create(config.rayneMerchant, state)
    state.settlementRaid = SettlementRaid.start(
        config.settlementRaid,
        {
            palRaidResultAdapter = state.palRaidResultAdapter,
            attendanceAttributionResolver = function(attacker)
                return state.palRaidNativeBinding
                    :attribute_attacker(attacker)
            end,
            attendanceDeathObserver = function(victim)
                if state.nativeCharacterAdapter ~= nil then
                    state.nativeCharacterAdapter
                        :observe_character_death(victim)
                end
            end,
        }
    )
    _G.PWFT_ATTENDANCE_RAID_RESULT_BRIDGE_V1 =
        state.settlementRaid.attendanceResultBridge
    if state.settlementRaid.attendanceResultBridge ~= nil then
        local bridge_status = state.settlementRaid
            .attendanceResultBridge:status()
        log(string.format(
            "ATTENDANCE_RAID_RESULT_BRIDGE_READY api=%s eventAuthority=%s spawnAuthority=%s deathAuthority=%s outcomeAuthority=%s timerSettlement=%s",
            bridge_status.apiVersion,
            bridge_status.eventAuthority,
            bridge_status.spawnAuthority,
            bridge_status.deathAuthority,
            bridge_status.outcomeAuthority,
            tostring(bridge_status.timerCleanupMaySettleRaid)
        ))
    end
    local world_balance_config = config.worldBalance
    local unsafe_world_batch_requested =
        world_balance_config.palFactionRage.enabled == true
        or world_balance_config.loadedActorReconcile.enabled == true
    if config.demoNativeRaidSafeMode == true
        and unsafe_world_batch_requested then
        state.worldBalance = nil
        log("DEMO_NATIVE_RAID_SAFE_MODE worldBalance=false reason=rage-or-reconcile-requested nativeSettlementRaid=true customSpawner=false")
    elseif WorldBalance.has_enabled_feature(world_balance_config) then
        state.worldBalance = WorldBalance.start(world_balance_config)
    else
        state.worldBalance = nil
        log(string.format(
            "WORLD_BALANCE_DISABLED level80=%s palFactionRage=%s loadedActorReconcile=%s nativeSettlementRaid=true",
            tostring(world_balance_config.levelOverride.enabled == true),
            tostring(world_balance_config.palFactionRage.enabled == true),
            tostring(world_balance_config.loadedActorReconcile.enabled == true)
        ))
    end
    state.enableNativeTerritoryMaterialOverlay = config.enableNativeTerritoryMaterialOverlay == true
    register_console_commands(config, registry, policy, state)
    register_guard_console_command(state)
    register_guard_live_test(config, state)
    register_economy_merchant_interaction_router(state)
    register_economy_merchant_live_test(config, state)
    register_native_map_keybinds(config, registry, policy, state)
    register_runtime_probes(config, registry, policy, state)
    schedule_map_widget_poll(state, 120, 1000)
    log(string.format(
        "READY release=%s build=Steam/%s sourceContractBuild=%s baseline=%s regions=%d factions=%d mode=%s nativeFactionMap=true",
        config.releaseId,
        config.expectedSteamBuildId,
        registry.gameBuild,
        registry.baselineId,
        registry.counts.regions,
        registry.counts.factions,
        state.mapMode
    ))
    return state
end

return Runtime
