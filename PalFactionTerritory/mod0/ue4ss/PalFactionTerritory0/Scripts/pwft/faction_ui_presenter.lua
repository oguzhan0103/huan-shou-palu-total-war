local FactionUiPresenter = {}

local PREFIX = "[PalFactionTerritory0][FactionUi]"
local WIDGET_ASSET_PATH =
    "/Game/Mods/PalFactionTerritory0/UI/FactionStatus/WBP_PFT_FactionStatus.WBP_PFT_FactionStatus"
local WIDGET_CLASS_PATH = WIDGET_ASSET_PATH .. "_C"

local RANK_LABELS = {
    Member = "成员",
    CoreMember = "核心成员",
    Leader = "领队",
    Lord = "领主",
}

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function is_valid(object)
    if object == nil then
        return false
    end
    local ok, result = pcall(function()
        return object:IsValid()
    end)
    return ok and result == true
end

local function safe_property(object, property_name)
    if object == nil then
        return nil
    end
    local ok, value = pcall(function()
        return object[property_name]
    end)
    return ok and value or nil
end

local function safe_call(object, method_name, ...)
    if not is_valid(object) then
        return false, nil
    end
    local arguments = { ... }
    local ok, result = pcall(function()
        return object[method_name](
            object,
            table.unpack(arguments)
        )
    end)
    return ok, result
end

local function safe_full_name(object)
    if not is_valid(object) then
        return "<invalid>"
    end
    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(name) or "<unreadable>"
end

local function find_local_player()
    local helpers = nil
    pcall(function()
        helpers = require("UEHelpers")
    end)
    local controller = nil
    if helpers ~= nil
        and type(helpers.GetPlayerController) == "function" then
        pcall(function()
            controller = helpers.GetPlayerController()
        end)
    end
    if not is_valid(controller)
        and type(FindFirstOf) == "function" then
        for _, class_name in ipairs({
            "PalPlayerController",
            "PalPlayerController_C",
        }) do
            local ok, candidate = pcall(function()
                return FindFirstOf(class_name)
            end)
            if ok and is_valid(candidate) then
                controller = candidate
                break
            end
        end
    end
    if not is_valid(controller) then
        return nil, nil, "player-controller-not-ready"
    end
    local pawn = safe_property(controller, "Pawn")
    if not is_valid(pawn) then
        pawn = safe_property(controller, "AcknowledgedPawn")
    end
    if not is_valid(pawn) then
        return controller, nil, "player-pawn-not-ready"
    end
    return controller, pawn, nil
end

local function load_widget_class()
    if type(StaticFindObject) ~= "function" then
        return nil
    end

    local function find_class()
        for _, object_path in ipairs({
            WIDGET_CLASS_PATH,
            "WidgetBlueprintGeneratedClass " .. WIDGET_CLASS_PATH,
            "BlueprintGeneratedClass " .. WIDGET_CLASS_PATH,
        }) do
            local found, widget_class = pcall(function()
                return StaticFindObject(object_path)
            end)
            if found and is_valid(widget_class) then
                log(string.format(
                    "WIDGET_CLASS_READY source=StaticFindObject path=%s class=%s",
                    object_path,
                    safe_full_name(widget_class)
                ))
                return widget_class
            end
        end
        return nil
    end

    local widget_class = find_class()
    if is_valid(widget_class) then
        return widget_class
    end

    if type(LoadAsset) == "function" then
        for _, asset_path in ipairs({
            WIDGET_ASSET_PATH,
            string.match(WIDGET_ASSET_PATH, "^([^%.]+)"),
            WIDGET_CLASS_PATH,
        }) do
            local load_ok, loaded_asset = pcall(function()
                return LoadAsset(asset_path)
            end)
            local generated_class = safe_property(
                loaded_asset,
                "GeneratedClass"
            )
            log(string.format(
                "WIDGET_ASSET_LOAD path=%s ok=%s asset=%s generatedClass=%s",
                tostring(asset_path),
                tostring(load_ok),
                safe_full_name(loaded_asset),
                safe_full_name(generated_class)
            ))
            if is_valid(generated_class) then
                return generated_class
            end
            widget_class = find_class()
            if is_valid(widget_class) then
                return widget_class
            end
        end
    end
    log("WIDGET_CLASS_UNAVAILABLE path=" .. WIDGET_CLASS_PATH)
    return nil
end

local function find_named_widget(owner, property_name, class_name)
    local direct = safe_property(owner, property_name)
    if is_valid(direct) then
        return direct
    end
    if type(FindAllOf) ~= "function" then
        return nil
    end
    local found, objects = pcall(function()
        return FindAllOf(class_name)
    end)
    if not found or objects == nil then
        return nil
    end
    for _, object in pairs(objects) do
        local full_name = safe_full_name(object)
        if string.find(full_name, property_name, 1, true) ~= nil
            and string.find(
                full_name,
                "WBP_PFT_FactionStatus_C",
                1,
                true
            ) ~= nil then
            return object
        end
    end
    return nil
end

local function to_text(message)
    if type(StaticFindObject) ~= "function" then
        return message
    end
    local found, text_library = pcall(function()
        return StaticFindObject(
            "/Script/Engine.Default__KismetTextLibrary"
        )
    end)
    if not found or not is_valid(text_library) then
        return message
    end
    local converted, value = pcall(function()
        return text_library:Conv_StringToText(message)
    end)
    return converted and value or message
end

local function set_widget_visibility(widget, visibility)
    if is_valid(widget) then
        safe_call(widget, "SetVisibility", visibility)
    end
end

local function set_widget_z_order(widget, z_order)
    if not is_valid(widget) then
        return false
    end
    local slot = safe_property(widget, "Slot")
    if not is_valid(slot) then
        return false
    end
    local updated = safe_call(slot, "SetZOrder", z_order)
    return updated == true
end

local function set_canvas_layout(widget, position, size, z_order)
    if not is_valid(widget) then
        return false
    end
    local slot = safe_property(widget, "Slot")
    if not is_valid(slot) then
        return false
    end
    local positioned = safe_call(slot, "SetPosition", position)
    local sized = safe_call(slot, "SetSize", size)
    local layered = safe_call(slot, "SetZOrder", z_order)
    return positioned == true
        and sized == true
        and layered == true
end

local function find_runtime_font(target_size)
    if type(FindAllOf) ~= "function" then
        return nil, nil, nil
    end
    local found, text_blocks = pcall(function()
        return FindAllOf("TextBlock")
    end)
    if not found or text_blocks == nil then
        return nil, nil, nil
    end
    local best_font = nil
    local best_size = nil
    local best_source = nil
    local best_distance = nil
    for _, text_block in pairs(text_blocks) do
        if is_valid(text_block) then
            local font = safe_property(text_block, "Font")
            if font ~= nil then
                local size_ok, font_size = pcall(function()
                    return font.Size
                end)
                if size_ok
                    and type(font_size) == "number"
                    and font_size >= 12
                    and font_size <= 64 then
                    local distance = math.abs(
                        font_size - (target_size or 17)
                    )
                    if best_distance == nil
                        or distance < best_distance then
                        best_font = font
                        best_size = font_size
                        best_source = safe_full_name(text_block)
                        best_distance = distance
                    end
                end
            end
        end
    end
    return best_font, best_size, best_source
end

local NativeBackend = {}

function NativeBackend.create(options)
    local panel_position = options.panelPosition or {}
    local panel_size = options.panelSize or {}
    return setmetatable({
        widget = nil,
        summaryText = nil,
        viewportAdded = false,
        zOrder = options.zOrder or 90,
        panelPosition = {
            X = panel_position.X or 435.0,
            Y = panel_position.Y or 35.0,
        },
        panelSize = {
            X = panel_size.X or 1050.0,
            Y = panel_size.Y or 985.0,
        },
        minTextWidth = options.minTextWidth or 1010.0,
        targetFontSize = options.targetFontSize or 17,
        lastError = nil,
    }, { __index = NativeBackend })
end

function NativeBackend:_configure(widget)
    local panel = find_named_widget(
        widget,
        "BTN_FactionSummary",
        "Button"
    )
    set_widget_visibility(panel, 0)
    local panel_z_ready = set_canvas_layout(
        panel,
        self.panelPosition,
        self.panelSize,
        0
    )
    if is_valid(panel) then
        safe_call(panel, "SetIsEnabled", false)
        safe_call(panel, "SetBackgroundColor", {
            R = 0.02,
            G = 0.04,
            B = 0.08,
            A = 0.94,
        })
    end
    self.summaryText = find_named_widget(
        widget,
        "TXT_FactionSummary",
        "RichTextBlock"
    )
    set_widget_visibility(self.summaryText, 0)
    if not is_valid(self.summaryText) then
        return false, "summary-text-control-unavailable"
    end
    local text_slot = safe_property(self.summaryText, "Slot")
    local horizontal_ready = safe_call(
        text_slot,
        "SetHorizontalAlignment",
        0
    )
    local vertical_ready = safe_call(
        text_slot,
        "SetVerticalAlignment",
        0
    )
    local padding_ready = safe_call(text_slot, "SetPadding", {
        Left = 15.0,
        Top = 15.0,
        Right = 15.0,
        Bottom = 15.0,
    })
    local opacity_ready = safe_call(
        self.summaryText,
        "SetRenderOpacity",
        1.0
    )
    local color_ready = safe_call(
        self.summaryText,
        "SetDefaultColorAndOpacity",
        {
        SpecifiedColor = {
            R = 1.0,
            G = 1.0,
            B = 1.0,
            A = 1.0,
        },
        ColorUseRule = 0,
        }
    )
    local runtime_font, runtime_font_size, runtime_font_source =
        find_runtime_font(self.targetFontSize)
    local font_ready = false
    if runtime_font ~= nil then
        font_ready = safe_call(
            self.summaryText,
            "SetDefaultFont",
            runtime_font
        )
    end
    local width_ready = safe_call(
        self.summaryText,
        "SetMinDesiredWidth",
        self.minTextWidth
    )
    local wrap_ready = safe_call(
        self.summaryText,
        "SetAutoWrapText",
        true
    )
    safe_call(self.summaryText, "RefreshTextLayout")
    log(string.format(
        "WIDGET_CONFIG panel=%s panelZ=%s panelPosition=%.0f,%.0f "
            .. "panelSize=%.0f,%.0f text=%s horizontal=%s "
            .. "vertical=%s padding=%s opacity=%s color=%s font=%s "
            .. "fontSize=%s targetFontSize=%s fontSource=%s "
            .. "minTextWidth=%.0f width=%s wrap=%s",
        safe_full_name(panel),
        tostring(panel_z_ready),
        self.panelPosition.X,
        self.panelPosition.Y,
        self.panelSize.X,
        self.panelSize.Y,
        safe_full_name(self.summaryText),
        tostring(horizontal_ready),
        tostring(vertical_ready),
        tostring(padding_ready),
        tostring(opacity_ready),
        tostring(color_ready),
        tostring(font_ready),
        tostring(runtime_font_size),
        tostring(self.targetFontSize),
        tostring(runtime_font_source),
        self.minTextWidth,
        tostring(width_ready),
        tostring(wrap_ready)
    ))
    return true, nil
end

function NativeBackend:_ensure_widget()
    if is_valid(self.widget) then
        return self.widget, nil
    end
    local controller, pawn, player_error = find_local_player()
    if not is_valid(controller) or not is_valid(pawn) then
        return nil, player_error
    end
    local widget_class = load_widget_class()
    if not is_valid(widget_class) then
        return nil, "faction-widget-class-unavailable"
    end
    local found, widget_library = pcall(function()
        return StaticFindObject(
            "/Script/UMG.Default__WidgetBlueprintLibrary"
        )
    end)
    if not found or not is_valid(widget_library) then
        return nil, "WidgetBlueprintLibrary-unavailable"
    end
    local created, widget = pcall(function()
        return widget_library:Create(
            pawn,
            widget_class,
            controller
        )
    end)
    if not created or not is_valid(widget) then
        return nil, "faction-widget-create-failed"
    end
    local configured, configure_error = self:_configure(widget)
    if not configured then
        return nil, configure_error
    end
    self.widget = widget
    return widget, nil
end

function NativeBackend:update(message)
    local widget, widget_error = self:_ensure_widget()
    if not is_valid(widget) then
        self.lastError = widget_error
        return false, widget_error
    end
    if not is_valid(self.summaryText) then
        local configured, configure_error = self:_configure(widget)
        if not configured then
            self.lastError = configure_error
            return false, configure_error
        end
    end
    local updated = safe_call(
        self.summaryText,
        "SetText",
        to_text(message)
    )
    if not updated then
        self.lastError = "faction-summary-set-text-failed"
        return false, self.lastError
    end
    log(string.format(
        "TEXT_UPDATE length=%d target=%s",
        string.len(message),
        safe_full_name(self.summaryText)
    ))
    self.lastError = nil
    return true, nil
end

function NativeBackend:show(message)
    local updated, update_error = self:update(message)
    if not updated then
        return false, update_error
    end
    if not self.viewportAdded then
        local added = safe_call(
            self.widget,
            "AddToViewport",
            self.zOrder
        )
        if not added then
            self.lastError = "faction-widget-add-failed"
            return false, self.lastError
        end
        self.viewportAdded = true
    end
    set_widget_visibility(self.widget, 0)
    self.lastError = nil
    return true, nil
end

function NativeBackend:hide()
    if is_valid(self.widget) then
        set_widget_visibility(self.widget, 2)
    end
    self.lastError = nil
    return true, nil
end

local function relation_tag(relation)
    if relation == "Player" then
        return "[绿]"
    elseif relation == "Hostile" then
        return "[红]"
    end
    return "[蓝]"
end

local function format_rank_progress(row)
    if row.joined ~= true then
        return row.joinEligible and "可加入" or "未达到加入条件"
    end
    local rank_label = RANK_LABELS[row.rankId]
        or tostring(row.rankId)
    local progress = row.rankProgress
    if progress == nil or progress.nextRankId == nil then
        return rank_label
    end
    return string.format(
        "%s -> %s %d/%d",
        rank_label,
        RANK_LABELS[progress.nextRankId]
            or tostring(progress.nextRankId),
        progress.current,
        progress.target
    )
end

local function format_diplomacy(row)
    local recovery = row.commerce
        and row.commerce.diplomacyRecovery
    if row.relation ~= "Hostile"
        or recovery == nil
        or recovery.activeSourceFactionId == nil then
        return nil
    end
    return string.format(
        "外交修复 %d/%d 本窗口余%d",
        recovery.activeProgress or 0,
        recovery.requiredPerSource or 0,
        recovery.windowRemaining or 0
    )
end

local function format_human_row(row)
    local details = {
        relation_tag(row.relation) .. row.displayNameZhHans,
        "好感 " .. tostring(row.reputation),
        format_rank_progress(row),
    }
    local diplomacy = format_diplomacy(row)
    if diplomacy ~= nil then
        table.insert(details, diplomacy)
    elseif row.commerce ~= nil then
        table.insert(
            details,
            "商业额度 "
                .. tostring(row.commerce.nonNegativeRemaining)
        )
    end
    if row.guard ~= nil and row.guard.eligible then
        local guard_state = "护卫未配置"
        if row.guard.active then
            guard_state = "护卫已出战"
        elseif row.guard.providerReady then
            guard_state = "护卫可用"
        end
        table.insert(details, guard_state)
    end
    return table.concat(details, " | ")
end

local function format_pal_row(row)
    local reconciliation = row.reconciliation or {}
    local reconciliation_text = "论道服务未启用"
    if reconciliation.serviceReady then
        if reconciliation.reconciled then
            reconciliation_text = "已和解"
        elseif reconciliation.permanentlyLocked then
            reconciliation_text = "和解永久失败"
        elseif not reconciliation.configured then
            reconciliation_text = "论道内容待配置"
        else
            reconciliation_text = string.format(
                "论道机会%d/%d | 信物%d/%d | 可论道%d",
                reconciliation.totalAttemptsRemaining or 0,
                reconciliation.tokenQuota or 0,
                reconciliation.tokensAwarded or 0,
                reconciliation.tokenQuota or 0,
                reconciliation.discourseReadyCount or 0
            )
        end
    end
    return string.format(
        "%s%s | %s | %s",
        relation_tag(row.relation),
        row.displayNameZhHans,
        row.relationLabelZhHans,
        reconciliation_text
    )
end

local function format_model(model, key_name)
    local lines = {
        "势力关系与身份",
        "[绿] 已加入  [蓝] 中立友好  [红] 敌对",
        "",
        "人类势力",
    }
    for index, row in ipairs(model.rows or {}) do
        if index <= (model.humanFactionCount or 0) then
            table.insert(lines, format_human_row(row))
        end
    end
    table.insert(lines, "")
    table.insert(lines, "帕鲁势力")
    for index, row in ipairs(model.rows or {}) do
        if index > (model.humanFactionCount or 0) then
            table.insert(lines, format_pal_row(row))
        end
    end
    local gates = model.gates or {}
    table.insert(lines, "")
    table.insert(lines, string.format(
        "帕鲁和解：%s（还差%d个人类领主）",
        gates.palReconciliationUnlocked and "已解锁" or "未解锁",
        #(gates.missingHumanLords or {})
    ))
    table.insert(lines, string.format(
        "结局三：%s（还差%d个帕鲁友好势力）",
        gates.ending3Unlocked and "已解锁" or "未解锁",
        #(gates.missingPalFriendly or {})
    ))
    table.insert(lines, tostring(key_name) .. " 关闭")
    return table.concat(lines, "\n")
end

function FactionUiPresenter.create(model, config, backend)
    assert(type(model) == "table", "faction UI model is required")
    config = config or {}
    return setmetatable({
        version = "1.1.0",
        model = model,
        enabled = config.enabled ~= false,
        key = config.key or "F5",
        backend = backend or NativeBackend.create(config),
        visible = false,
        keyBound = false,
        lastError = nil,
        lastText = nil,
        callbacks = {},
    }, { __index = FactionUiPresenter })
end

function FactionUiPresenter:render()
    local text = format_model(self.model:build(), self.key)
    self.lastText = text
    return text
end

function FactionUiPresenter:show()
    if not self.enabled then
        self.lastError = "faction-ui-disabled"
        return false, self.lastError
    end
    local shown, show_error = self.backend:show(self:render())
    if not shown then
        self.lastError = show_error or "faction-ui-show-failed"
        log("SHOW_UNAVAILABLE error=" .. tostring(self.lastError))
        return false, self.lastError
    end
    self.visible = true
    self.lastError = nil
    return true, nil
end

function FactionUiPresenter:hide()
    local hidden, hide_error = self.backend:hide()
    if not hidden then
        self.lastError = hide_error or "faction-ui-hide-failed"
        return false, self.lastError
    end
    self.visible = false
    self.lastError = nil
    return true, nil
end

function FactionUiPresenter:toggle()
    if self.visible then
        return self:hide()
    end
    return self:show()
end

function FactionUiPresenter:refresh()
    local message = self:render()
    if not self.visible then
        return true, nil, message
    end
    local updated, update_error = self.backend:update(message)
    if not updated then
        self.lastError = update_error or "faction-ui-refresh-failed"
        return false, self.lastError, message
    end
    self.lastError = nil
    return true, nil, message
end

function FactionUiPresenter:start()
    if not self.enabled then
        return false, "faction-ui-disabled"
    end
    if self.keyBound then
        return true, "already-bound"
    end
    if type(RegisterKeyBind) ~= "function"
        or type(Key) ~= "table"
        or Key[self.key] == nil then
        self.lastError = "keybind-api-unavailable"
        return false, self.lastError
    end
    local callback = function()
        local operation = function()
            local ok, error_message = pcall(function()
                self:toggle()
            end)
            if not ok then
                self.lastError = tostring(error_message)
                log("KEY_CALLBACK_ERROR error=" .. self.lastError)
            end
        end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(operation)
        else
            operation()
        end
    end
    RegisterKeyBind(Key[self.key], callback)
    self.callbacks.toggle = callback
    self.keyBound = true
    self.lastError = nil
    return true, nil
end

function FactionUiPresenter:status()
    return {
        version = self.version,
        enabled = self.enabled,
        key = self.key,
        keyBound = self.keyBound,
        visible = self.visible,
        renderingStatus =
            "dedicated-faction-panel-ready-live-acceptance-pending",
        lastError = self.lastError,
    }
end

return FactionUiPresenter
