local Keys = {
    pinkCat = "pwft.foundation.b7.loc.unique.pinkcat",
    anubis = "pwft.foundation.b7.loc.unique.anubis",
    weaselDragon = "pwft.foundation.b7.loc.unique.weasel-dragon",
    blackMetalDragon =
        "pwft.foundation.b7.loc.unique.black-metal-dragon",
    ronin = "pwft.foundation.b7.loc.unique.ronin",
    rayneCity = "pwft.foundation.b7.loc.city.rayne",
    pidfCity = "pwft.foundation.b7.loc.city.pidf",
    freePalCity = "pwft.foundation.b7.loc.city.free-pal-alliance",
    eternalPyreCity = "pwft.foundation.b7.loc.city.eternal-pyre",
    sakurajimaCity = "pwft.foundation.b7.loc.city.sakurajima",
    allLordRoute = "pwft.foundation.b7.loc.ending.all-unique-pals",
    allLordTitle = "pwft.foundation.b7.loc.title.all-unique-pals",
}

local Catalog = {}
for _, key in pairs(Keys) do Catalog[#Catalog + 1] = key end
table.sort(Catalog)

return {
    namespace = "pwft.foundation.b7.loc",
    byName = Keys,
    catalog = Catalog,
}
