local PalDialogueNativeBackend = {}

local PREFIX = "[PalFactionTerritory0][PalDialogueNative]"
local WIDGET_ASSET_PATH =
    "/Game/Mods/PalFactionTerritory0/UI/FactionStatus/WBP_PFT_FactionStatus.WBP_PFT_FactionStatus"
local WIDGET_CLASS_PATH = WIDGET_ASSET_PATH .. "_C"

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local function is_valid(object)
    if object == nil then
        return false
    end
    local ok, value = pcall(function()
        return object:IsValid()
    end)
    return ok and value == true
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
    local ok, value = pcall(function()
        return object[method_name](object, table.unpack(arguments))
    end)
    return ok, value
end

local function safe_full_name(object)
    if not is_valid(object) then
        return "<invalid>"
    end
    local ok, value = pcall(function()
        return object:GetFullName()
    end)
    return ok and tostring(value) or "<unreadable>"
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
        or safe_property(controller, "AcknowledgedPawn")
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
        for _, path in ipairs({
            WIDGET_CLASS_PATH,
            "WidgetBlueprintGeneratedClass " .. WIDGET_CLASS_PATH,
            "BlueprintGeneratedClass " .. WIDGET_CLASS_PATH,
        }) do
            local ok, value = pcall(function()
                return StaticFindObject(path)
            end)
            if ok and is_valid(value) then
                return value
            end
        end
        return nil
    end
    local widget_class = find_class()
    if is_valid(widget_class) then
        return widget_class
    end
    if type(LoadAsset) == "function" then
        for _, path in ipairs({
            WIDGET_ASSET_PATH,
            string.match(WIDGET_ASSET_PATH, "^([^%.]+)"),
        }) do
            pcall(function()
                LoadAsset(path)
            end)
            widget_class = find_class()
            if is_valid(widget_class) then
                return widget_class
            end
        end
    end
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
    local ok, values = pcall(function()
        return FindAllOf(class_name)
    end)
    if not ok or values == nil then
        return nil
    end
    for _, value in pairs(values) do
        local name = safe_full_name(value)
        if string.find(name, property_name, 1, true) ~= nil
            and string.find(
                name,
                "WBP_PFT_FactionStatus_C",
                1,
                true
            ) ~= nil then
            return value
        end
    end
    return nil
end

local function to_text(message)
    if type(StaticFindObject) ~= "function" then
        return message
    end
    local ok, library = pcall(function()
        return StaticFindObject(
            "/Script/Engine.Default__KismetTextLibrary"
        )
    end)
    if not ok or not is_valid(library) then
        return message
    end
    local converted, value = pcall(function()
        return library:Conv_StringToText(message)
    end)
    return converted and value or message
end

local function set_visibility(widget, value)
    if is_valid(widget) then
        safe_call(widget, "SetVisibility", value)
    end
end

local function set_canvas_layout(widget, position, size, z_order)
    local slot = safe_property(widget, "Slot")
    if not is_valid(slot) then
        return false
    end
    local positioned = safe_call(slot, "SetPosition", position)
    local sized = safe_call(slot, "SetSize", size)
    local layered = safe_call(slot, "SetZOrder", z_order)
    return positioned and sized and layered
end

local function find_runtime_font()
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
                    local distance = math.abs(font_size - 20)
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

local function resolve_key(key, locale)
    if type(key) ~= "string" or key == "" then
        return "<未配置文本>"
    end
    local bridge = rawget(_G, "PWFT_LOCALIZATION_RESOLVER_V1")
    if type(bridge) == "table"
        and type(bridge.resolve) == "function" then
        local ok, value = pcall(function()
            return bridge:resolve(locale or "zh-CN", key)
        end)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return "[" .. key .. "]"
end

local function format_offer(offer, locale)
    local token = offer.selectedToken or {}
    local lines = {
        "帕鲁论道：进入确认",
        "代表：" .. resolve_key(offer.representativeNameKey, locale),
        "阵营：" .. tostring(offer.factionId or "<unknown>"),
        "信物：" .. tostring(offer.tokenInstanceId or "<unknown>"),
        "对应城邦：" .. tostring(token.cityStateId or offer.cityStateId or "<unknown>"),
        "",
        "确认后本次信物将被保留给这一轮论道。",
        "主动中止会消耗机会；技术故障会退还机会。",
        "",
        "F1 确认进入    F2 取消（不消耗）",
    }
    if type(offer.readyTokenCount) == "number"
        and offer.readyTokenCount > 1 then
        table.insert(
            lines,
            "当前另有 " .. tostring(offer.readyTokenCount - 1)
                .. " 个可用信物，本次按获得顺序选择。"
        )
    end
    return table.concat(lines, "\n")
end

local function format_view(view, locale)
    local speaker = view.speakerRole == "player"
            and "玩家"
        or "帕鲁代表"
    local lines = {
        "帕鲁论道",
        "代表：" .. resolve_key(view.representativeNameKey, locale),
        "阵营：" .. tostring(view.factionId or "<unknown>"),
        "",
        speaker .. "：",
    }
    local agent = view.agent
    if type(agent) == "table"
        and type(agent.dialogue) == "string"
        and agent.dialogue ~= "" then
        table.insert(lines, agent.dialogue)
    else
        table.insert(lines, resolve_key(view.textKey, locale))
    end
    table.insert(lines, "")
    if #(view.choices or {}) > 0 then
        table.insert(lines, "可选回应：")
        for index, choice in ipairs(view.choices) do
            table.insert(
                lines,
                tostring(index) .. ". "
                    .. resolve_key(choice.textKey, locale)
            )
        end
        table.insert(lines, "按数字键 1-9 选择回应")
    end
    if type(agent) == "table" then
        if agent.state == "pending" then
            table.insert(lines, "大模型回应生成中，可在外部操作台刷新。")
        elseif agent.requiresPlayerConfirmation == true then
            table.insert(lines, "F3 确认采用大模型建议（结果仍由规则引擎执行）")
        end
    end
    table.insert(lines, "F4 主动结束本轮论道（会消耗机会）")
    table.insert(lines, "自由文本输入由外部操作台提交；游戏内面板同步显示回应。")
    return table.concat(lines, "\n")
end

function PalDialogueNativeBackend.create(configuration, options)
    options = options or {}
    return setmetatable({
        version = "1.0.0",
        enabled = configuration.nativeDialoguePresenterEnabled == true,
        locale = configuration.agentDefaultLocale or "zh-CN",
        zOrder = options.zOrder or 110,
        widget = nil,
        text = nil,
        viewportAdded = false,
        mode = "hidden",
        lastPayload = nil,
        lastError = nil,
        showCount = 0,
        updateCount = 0,
        hideCount = 0,
    }, { __index = PalDialogueNativeBackend })
end

function PalDialogueNativeBackend:_configure(widget)
    local panel = find_named_widget(
        widget,
        "BTN_FactionSummary",
        "Button"
    )
    set_visibility(panel, 0)
    set_canvas_layout(
        panel,
        { X = 590.0, Y = 70.0 },
        { X = 700.0, Y = 700.0 },
        0
    )
    if is_valid(panel) then
        safe_call(panel, "SetIsEnabled", false)
        safe_call(panel, "SetBackgroundColor", {
            R = 0.015,
            G = 0.025,
            B = 0.05,
            A = 0.96,
        })
    end
    self.text = find_named_widget(
        widget,
        "TXT_FactionSummary",
        "RichTextBlock"
    )
    if not is_valid(self.text) then
        return false, "pal-dialogue-text-control-unavailable"
    end
    set_visibility(self.text, 0)
    local slot = safe_property(self.text, "Slot")
    safe_call(slot, "SetHorizontalAlignment", 0)
    safe_call(slot, "SetVerticalAlignment", 0)
    safe_call(slot, "SetPadding", {
        Left = 20.0,
        Top = 20.0,
        Right = 20.0,
        Bottom = 20.0,
    })
    safe_call(self.text, "SetRenderOpacity", 1.0)
    safe_call(self.text, "SetDefaultColorAndOpacity", {
        SpecifiedColor = {
            R = 1.0,
            G = 1.0,
            B = 1.0,
            A = 1.0,
        },
        ColorUseRule = 0,
    })
    local runtime_font, runtime_font_size, runtime_font_source =
        find_runtime_font()
    local font_ready = false
    if runtime_font ~= nil then
        font_ready = safe_call(
            self.text,
            "SetDefaultFont",
            runtime_font
        )
    end
    safe_call(self.text, "SetMinDesiredWidth", 630.0)
    safe_call(self.text, "SetAutoWrapText", true)
    safe_call(self.text, "RefreshTextLayout")
    log(string.format(
        "WIDGET_CONFIG_READY widget=%s text=%s font=%s fontSize=%s fontSource=%s",
        safe_full_name(widget),
        safe_full_name(self.text),
        tostring(font_ready),
        tostring(runtime_font_size),
        tostring(runtime_font_source)
    ))
    return true, nil
end

function PalDialogueNativeBackend:_ensure_widget()
    if is_valid(self.widget) then
        return self.widget, nil
    end
    if not self.enabled then
        return nil, "native-pal-dialogue-presenter-disabled"
    end
    local controller, pawn, player_error = find_local_player()
    if not is_valid(controller) or not is_valid(pawn) then
        return nil, player_error
    end
    local widget_class = load_widget_class()
    if not is_valid(widget_class) then
        return nil, "pal-dialogue-widget-class-unavailable"
    end
    local ok, library = pcall(function()
        return StaticFindObject(
            "/Script/UMG.Default__WidgetBlueprintLibrary"
        )
    end)
    if not ok or not is_valid(library) then
        return nil, "WidgetBlueprintLibrary-unavailable"
    end
    local created, widget = pcall(function()
        return library:Create(pawn, widget_class, controller)
    end)
    if not created or not is_valid(widget) then
        return nil, "pal-dialogue-widget-create-failed"
    end
    local configured, configure_error = self:_configure(widget)
    if not configured then
        return nil, configure_error
    end
    self.widget = widget
    return widget, nil
end

function PalDialogueNativeBackend:_present(message, mode, payload)
    local widget, widget_error = self:_ensure_widget()
    if not is_valid(widget) then
        self.lastError = widget_error
        return false, widget_error
    end
    if not is_valid(self.text) then
        local configured, configure_error = self:_configure(widget)
        if not configured then
            self.lastError = configure_error
            return false, configure_error
        end
    end
    local updated = safe_call(self.text, "SetText", to_text(message))
    if not updated then
        self.lastError = "pal-dialogue-set-text-failed"
        return false, self.lastError
    end
    if not self.viewportAdded then
        local added = safe_call(widget, "AddToViewport", self.zOrder)
        if not added then
            self.lastError = "pal-dialogue-widget-add-failed"
            return false, self.lastError
        end
        self.viewportAdded = true
    end
    set_visibility(widget, 0)
    self.mode = mode
    self.lastPayload = payload
    self.lastError = nil
    log(string.format(
        "PRESENT mode=%s length=%d widget=%s",
        mode,
        #message,
        safe_full_name(widget)
    ))
    return true, nil
end

function PalDialogueNativeBackend:show(view)
    local shown, reason = self:_present(
        format_view(view, self.locale),
        "dialogue",
        view
    )
    if shown then
        self.showCount = self.showCount + 1
    end
    return shown, reason
end

function PalDialogueNativeBackend:update(view)
    local shown, reason = self:_present(
        format_view(view, self.locale),
        "dialogue",
        view
    )
    if shown then
        self.updateCount = self.updateCount + 1
    end
    return shown, reason
end

function PalDialogueNativeBackend:show_offer(offer)
    local shown, reason = self:_present(
        format_offer(offer, self.locale),
        "offer",
        offer
    )
    if shown then
        self.showCount = self.showCount + 1
    end
    return shown, reason
end

function PalDialogueNativeBackend:show_notice(message)
    return self:_present(
        "帕鲁论道\n\n" .. tostring(message) .. "\n\nF2 关闭",
        "notice",
        { message = tostring(message) }
    )
end

function PalDialogueNativeBackend:show_text(message, mode, payload)
    assert(type(message) == "string", "native dialogue text is required")
    local shown, reason = self:_present(
        message,
        mode or "system",
        payload or { message = message }
    )
    if shown then
        self.showCount = self.showCount + 1
    end
    return shown, reason
end

function PalDialogueNativeBackend:hide(payload)
    if is_valid(self.widget) then
        set_visibility(self.widget, 2)
    end
    self.mode = "hidden"
    self.lastPayload = payload
    self.lastError = nil
    self.hideCount = self.hideCount + 1
    log("HIDE reason=" .. tostring(
        type(payload) == "table" and payload.reason or "requested"
    ))
    return true, nil
end

function PalDialogueNativeBackend:status()
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        widgetReady = is_valid(self.widget),
        visible = self.mode ~= "hidden",
        mode = self.mode,
        showCount = self.showCount,
        updateCount = self.updateCount,
        hideCount = self.hideCount,
        lastError = self.lastError,
        localizationResolverAvailable =
            type(rawget(_G, "PWFT_LOCALIZATION_RESOLVER_V1"))
                == "table",
        storyContentIncluded = false,
        deterministicRuleEngineOwnsOutcome = true,
        genericSystemText = true,
    }
end

return PalDialogueNativeBackend
