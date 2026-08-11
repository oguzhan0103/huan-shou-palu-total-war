package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local NativeBackend = require("pwft.pal_dialogue_native_backend")

local function valid_object(name)
    local value = { valid = true, name = name }
    function value:IsValid() return self.valid end
    function value:GetFullName() return self.name end
    return value
end

local slot = valid_object("CanvasPanelSlot TestSlot")
function slot:SetPosition(value) self.position = value end
function slot:SetSize(value) self.size = value end
function slot:SetZOrder(value) self.zOrder = value end
function slot:SetHorizontalAlignment(value) self.horizontal = value end
function slot:SetVerticalAlignment(value) self.vertical = value end
function slot:SetPadding(value) self.padding = value end

local panel = valid_object("Button TestWidget.BTN_FactionSummary")
panel.Slot = slot
function panel:SetVisibility(value) self.visibility = value end
function panel:SetIsEnabled(value) self.enabled = value end
function panel:SetBackgroundColor(value) self.background = value end

local text = valid_object("RichTextBlock TestWidget.TXT_FactionSummary")
text.Slot = slot
function text:SetVisibility(value) self.visibility = value end
function text:SetRenderOpacity(value) self.opacity = value end
function text:SetDefaultColorAndOpacity(value) self.color = value end
function text:SetDefaultFont(value) self.defaultFont = value end
function text:SetMinDesiredWidth(value) self.minimumWidth = value end
function text:SetAutoWrapText(value) self.autoWrap = value end
function text:RefreshTextLayout() self.refreshCount = (self.refreshCount or 0) + 1 end
function text:SetText(value) self.value = value end

local widget = valid_object("WBP_PFT_FactionStatus_C TestWidget")
widget.BTN_FactionSummary = panel
widget.TXT_FactionSummary = text
function widget:AddToViewport(z_order)
    self.addCount = (self.addCount or 0) + 1
    self.viewportZ = z_order
end
function widget:SetVisibility(value) self.visibility = value end

local controller = valid_object("PalPlayerController TestController")
local pawn = valid_object("BP_Player_C TestPawn")
controller.Pawn = pawn

package.preload.UEHelpers = function()
    return {
        GetPlayerController = function() return controller end,
    }
end

local widget_class = valid_object(
    "WidgetBlueprintGeneratedClass WBP_PFT_FactionStatus_C"
)
local widget_library = valid_object("WidgetBlueprintLibrary")
function widget_library:Create(world_context, class, owning_player)
    assert(world_context == pawn)
    assert(class == widget_class)
    assert(owning_player == controller)
    return widget
end
local text_library = valid_object("KismetTextLibrary")
function text_library:Conv_StringToText(value) return value end
local runtime_text = valid_object("TextBlock RuntimeChineseText")
runtime_text.Font = { Size = 24, TypefaceFontName = "Regular" }

function FindAllOf(class_name)
    if class_name == "TextBlock" then return { runtime_text } end
    return {}
end

function StaticFindObject(path)
    if string.find(path, "WBP_PFT_FactionStatus", 1, true) then
        return widget_class
    elseif path == "/Script/UMG.Default__WidgetBlueprintLibrary" then
        return widget_library
    elseif path == "/Script/Engine.Default__KismetTextLibrary" then
        return text_library
    end
    return nil
end

PWFT_LOCALIZATION_RESOLVER_V1 = {
    resolve = function(_, locale, key)
        assert(locale == "zh-CN")
        local values = {
            ["fan.rep.name"] = "测试帕鲁代表",
            ["fan.node.opening"] = "我们坐下来谈谈。",
            ["fan.choice.peace"] = "谈谈和平。",
            ["fan.choice.leave"] = "就此离开。",
        }
        return values[key]
    end,
}

local backend = NativeBackend.create({
    nativeDialoguePresenterEnabled = true,
    agentDefaultLocale = "zh-CN",
})

local offered, offer_error = backend:show_offer({
    representativeNameKey = "fan.rep.name",
    factionId = "pwft.faction.desert_pal_tribe",
    tokenInstanceId = "pwft.pal-token.test.000001",
    selectedToken = {
        cityStateId = "pwft.faction.rayne_syndicate",
    },
    readyTokenCount = 2,
})
assert(offered and offer_error == nil)
assert(widget.addCount == 1 and widget.viewportZ == 110)
assert(widget.visibility == 0)
assert(text.defaultFont == runtime_text.Font)
assert(string.find(text.value, "帕鲁论道：进入确认", 1, true))
assert(string.find(text.value, "测试帕鲁代表", 1, true))
assert(string.find(text.value, "F1 确认进入", 1, true))
assert(string.find(text.value, "F2 取消（不消耗）", 1, true))
assert(string.find(text.value, "当前另有 1 个可用信物", 1, true))

local shown = backend:show({
    representativeNameKey = "fan.rep.name",
    factionId = "pwft.faction.desert_pal_tribe",
    speakerRole = "pal-representative",
    textKey = "fan.node.opening",
    choices = {
        { textKey = "fan.choice.peace" },
        { textKey = "fan.choice.leave" },
    },
    agent = nil,
})
assert(shown)
assert(widget.addCount == 1)
assert(string.find(text.value, "我们坐下来谈谈。", 1, true))
assert(string.find(text.value, "1. 谈谈和平。", 1, true))
assert(string.find(text.value, "2. 就此离开。", 1, true))
assert(string.find(text.value, "按数字键 1-9", 1, true))
assert(string.find(text.value, "外部操作台", 1, true))

local updated = backend:update({
    representativeNameKey = "fan.rep.name",
    factionId = "pwft.faction.desert_pal_tribe",
    speakerRole = "pal-representative",
    textKey = "fan.node.opening",
    choices = {},
    agent = {
        state = "ready",
        dialogue = "我听见了。",
        requiresPlayerConfirmation = true,
    },
})
assert(updated)
assert(string.find(text.value, "我听见了。", 1, true))
assert(string.find(text.value, "F3 确认采用大模型建议", 1, true))

local system_text_shown = backend:show_text(
    "势力加入系统文本",
    "human-faction-join-offer",
    { factionId = "pwft.faction.rayne_syndicate" }
)
assert(system_text_shown)
assert(text.value == "势力加入系统文本")

assert(backend:hide({ reason = "test-complete" }))
assert(widget.visibility == 2)
local status = backend:status()
assert(status.enabled == true)
assert(status.widgetReady == true)
assert(status.visible == false)
assert(status.showCount == 3)
assert(status.updateCount == 1)
assert(status.hideCount == 1)
assert(status.localizationResolverAvailable == true)
assert(status.storyContentIncluded == false)
assert(status.deterministicRuleEngineOwnsOutcome == true)
assert(status.genericSystemText == true)

print("PASS native Pal dialogue backend reuses the cooked panel, resolves fan localization, presents confirmation/choices/Agent text, and hides safely")
