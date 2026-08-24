package.path = table.concat({
    "mod0/ue4ss/PalFactionTerritory0/Scripts/?.lua",
    package.path,
}, ";")

local Json = require("pwft.json")

local encoded = Json.encode({
    boolean = true,
    count = 12,
    factions = { "Human", "Pal" },
    label = "势力商业",
    nested = {
        newline = "first\nsecond",
        quote = "\"",
    },
})
local decoded = Json.decode(encoded)
assert(decoded.boolean == true)
assert(decoded.count == 12)
assert(decoded.factions[1] == "Human")
assert(decoded.factions[2] == "Pal")
assert(decoded.label == "势力商业")
assert(decoded.nested.newline == "first\nsecond")
assert(decoded.nested.quote == "\"")

local surrogate = Json.decode([["\uD83D\uDEE1"]])
assert(#surrogate == 4)
assert(Json.decode("null") == Json.null)

local heterogeneous = Json.decode(
    [[{"history":[true,false,null,"owned",115,{"phase":"owned"}]}]]
)
assert(heterogeneous.history[1] == true)
assert(heterogeneous.history[2] == false)
assert(heterogeneous.history[3] == Json.null)
assert(heterogeneous.history[4] == "owned")
assert(heterogeneous.history[5] == 115)
assert(heterogeneous.history[6].phase == "owned")

local invalid_ok = pcall(Json.decode, [[{"broken":}]])
assert(invalid_ok == false)

local cycle = {}
cycle.self = cycle
local cycle_ok = pcall(Json.encode, cycle)
assert(cycle_ok == false)

print("PASS deterministic JSON codec")
