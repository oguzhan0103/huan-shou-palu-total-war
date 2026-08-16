package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local CommerceWindowLiveTest =
    require("pwft.commerce_window_live_test")

local qa = CommerceWindowLiveTest.create({
    enabled = true,
    key = "F12",
    windowPrefix = "qa-native-commerce",
    windowCount = 3,
}, {
    sessionId = "session-001",
})

assert(qa:window_id() == "qa-native-commerce:session-001:window-1")
local initial = qa:status()
assert(initial.windowIndex == 1)
assert(initial.windowCount == 3)
assert(initial.nativeTransactionsOnly == true)
assert(initial.directReputationWrites == false)
assert(initial.persistent == false)

local second = qa:advance()
assert(second.ok == true)
assert(second.previousWindowId == "qa-native-commerce:session-001:window-1")
assert(second.windowId == "qa-native-commerce:session-001:window-2")
local third = qa:advance()
assert(third.ok == true)
assert(third.windowId == "qa-native-commerce:session-001:window-3")
local blocked = qa:advance()
assert(blocked.ok == false)
assert(blocked.reason == "commerce-window-live-test-limit-reached")
assert(qa:window_id() == "qa-native-commerce:session-001:window-3")
assert(qa:status().transitionCount == 2)

local invalid = pcall(function()
    CommerceWindowLiveTest.create({
        enabled = false,
        key = "F12",
        windowPrefix = "qa-native-commerce",
        windowCount = 3,
    })
end)
assert(invalid == false)

print("PASS commerce window live-test uses three bounded native-only windows")
