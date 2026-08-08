package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Registry = require("pwft.registry")
local FactionApi = require("pwft.faction_api")
local FactionCommerce = require("pwft.faction_commerce")
local FactionGuard = require("pwft.faction_guard")
local FactionProgression = require("pwft.faction_progression")
local FactionUiModel = require("pwft.faction_ui_model")
local FactionUiPresenter = require("pwft.faction_ui_presenter")
local PalReconciliation = require("pwft.pal_reconciliation")

local progression = FactionProgression.create(Registry.progression)
local api = FactionApi.create(progression)
local commerce = FactionCommerce.create(Registry.commerce, api)
local guard = FactionGuard.create(api)
local pal_reconciliation = PalReconciliation.create(
    Registry.palReconciliation,
    progression
)
local model = FactionUiModel.create(
    Registry,
    progression,
    commerce,
    guard,
    pal_reconciliation
)

local backend = {
    shown = false,
    showCount = 0,
    updateCount = 0,
    hideCount = 0,
    text = nil,
}

function backend:show(message)
    self.shown = true
    self.showCount = self.showCount + 1
    self.text = message
    return true, nil
end

function backend:update(message)
    self.updateCount = self.updateCount + 1
    self.text = message
    return true, nil
end

function backend:hide()
    self.shown = false
    self.hideCount = self.hideCount + 1
    return true, nil
end

local bound_key = nil
local bound_callback = nil
Key = { F5 = "F5" }
function RegisterKeyBind(key, callback)
    bound_key = key
    bound_callback = callback
end

local presenter = FactionUiPresenter.create(
    model,
    {
        enabled = true,
        key = "F5",
    },
    backend
)

assert(presenter:start())
assert(bound_key == "F5")
assert(type(bound_callback) == "function")
assert(presenter:status().keyBound == true)
assert(presenter:status().visible == false)

bound_callback()
assert(presenter:status().visible == true)
assert(backend.shown == true)
assert(backend.showCount == 1)
assert(string.find(backend.text, "势力关系与身份", 1, true))
assert(string.find(backend.text, "[绿] 已加入", 1, true))
assert(string.find(backend.text, "[蓝] 中立友好", 1, true))
assert(string.find(backend.text, "[红] 敌对", 1, true))
assert(string.find(backend.text, "人类势力", 1, true))
assert(string.find(backend.text, "帕鲁势力", 1, true))
assert(string.find(backend.text, "雷恩盗猎团", 1, true))
assert(string.find(backend.text, "帕鲁保护团体", 1, true))
assert(string.find(backend.text, "永炎同心会", 1, true))
assert(string.find(backend.text, "帕洛斯群岛自卫队", 1, true))
assert(string.find(backend.text, "基因研究部队", 1, true))
assert(string.find(backend.text, "月花众", 1, true))
assert(string.find(backend.text, "天坠军", 1, true))
assert(string.find(backend.text, "沙漠帕鲁部落", 1, true))
assert(string.find(backend.text, "雪地帕鲁部落", 1, true))
assert(string.find(backend.text, "火焰属性帕鲁部落", 1, true))
assert(string.find(
    backend.text,
    "天坠之地综合帕鲁部落",
    1,
    true
))
assert(string.find(backend.text, "暗属性帕鲁部落", 1, true))
assert(string.find(backend.text, "论道内容待配置", 1, true))
assert(string.find(
    backend.text,
    "帕鲁和解：未解锁（还差7个人类领主）",
    1,
    true
))
assert(string.find(
    backend.text,
    "结局三：未解锁（还差5个帕鲁友好势力）",
    1,
    true
))
assert(string.find(backend.text, "F5 关闭", 1, true))

local rayne = "pwft.faction.rayne_syndicate"
local free_pal = "pwft.faction.free_pal_alliance"
assert(api:join_human(rayne, "ui-presenter-join-rayne").ok)
assert(api:award_task(
    rayne,
    300,
    "ui-presenter-rank-001"
).ok)
assert(api:award_task(
    rayne,
    300,
    "ui-presenter-rank-002"
).ok)
assert(api:award_task(
    rayne,
    100,
    "ui-presenter-rank-003"
).ok)
assert(presenter:refresh())
assert(backend.updateCount == 1)
assert(string.find(
    backend.text,
    "[绿]雷恩盗猎团 | 好感 700 | 领队",
    1,
    true
))
assert(string.find(backend.text, "护卫待接入", 1, true))
assert(string.find(
    backend.text,
    "[红]帕鲁保护团体 | 好感 0 | 未达到加入条件",
    1,
    true
))
assert(string.find(
    backend.text,
    "外交修复 0/60 本窗口余20",
    1,
    true
))

local recovery = api:award_commerce(
    free_pal,
    20,
    "ui-presenter-recovery-001",
    "ui-presenter-window-001",
    {
        diplomacyRecoveryEligible = true,
        venueMode = "fixed-market",
    }
)
assert(recovery.ok)
assert(presenter:refresh())
assert(string.find(
    backend.text,
    "外交修复 20/60 本窗口余0",
    1,
    true
))

bound_callback()
assert(presenter:status().visible == false)
assert(backend.shown == false)
assert(backend.hideCount == 1)
local refreshed, refresh_error, hidden_text = presenter:refresh()
assert(refreshed)
assert(refresh_error == nil)
assert(type(hidden_text) == "string")
assert(backend.updateCount == 2)

print("PASS faction UI presenter formatting, refresh, and explicit F5 toggle")
