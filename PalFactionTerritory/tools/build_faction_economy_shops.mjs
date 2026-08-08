import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";

function fail(message) {
    throw new Error(message);
}

function requireValue(condition, message) {
    if (!condition) fail(message);
}

function readJson(filePath) {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, value) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function sha256(filePath) {
    return crypto.createHash("sha256")
        .update(fs.readFileSync(filePath))
        .digest("hex")
        .toUpperCase();
}

function field(row, name) {
    const property = row.Value.find((candidate) => candidate.Name === name);
    if (property === undefined) {
        fail(`row ${row.Name} is missing ${name}`);
    }
    return property;
}

function tableRows(asset, label) {
    const rows = asset.Exports?.[0]?.Table?.Data;
    if (!Array.isArray(rows) || rows.length === 0) {
        fail(`${label} does not contain a mapped DataTable export`);
    }
    return rows;
}

function addNames(asset, names) {
    requireValue(Array.isArray(asset.NameMap), "asset has no NameMap");
    const known = new Set(asset.NameMap);
    for (const name of names) {
        if (!known.has(name)) {
            asset.NameMap.push(name);
            known.add(name);
        }
    }
}

function roundToStep(value, step) {
    return Math.floor((value + step / 2) / step) * step;
}

function clampInteger(value, minimum, maximum) {
    return Math.max(minimum, Math.min(maximum, Math.floor(value)));
}

function buildEconomyMarkets(economy) {
    const profile = economy.marketRules.balanceProfile;
    const bandOrder = new Map(
        economy.supplyBands.orderedLowToHigh.map((band, index) => [band, index]),
    );
    const resourceByItem = new Map(
        economy.resources.map((resource) => [resource.nativeItemId, resource]),
    );
    const merchantInputByItem = new Map(
        economy.merchantInputPolicy.inputs.map((input) => [input.itemId, input]),
    );
    const markets = new Map();
    for (const faction of economy.factions) {
        const sell = [];
        const procure = [];
        for (const product of economy.auditedProducts) {
            const territorialMaterials = product.materials.filter(
                (material) => resourceByItem.has(material.itemId),
            );
            requireValue(
                territorialMaterials.length > 0,
                `${product.productItemId} has no territorial material`,
            );
            const observations = territorialMaterials.map((material) => {
                const resource = resourceByItem.get(material.itemId);
                const observation = faction.resourceBaseline[resource.resourceId];
                requireValue(
                    observation !== undefined,
                    `${faction.factionId} has no ${resource.resourceId} baseline`,
                );
                return observation;
            });
            const effectiveSupplyBand = observations.reduce((lowest, current) =>
                bandOrder.get(current.supplyBand) < bandOrder.get(lowest)
                    ? current.supplyBand
                    : lowest,
            observations[0].supplyBand);
            const parameters = profile.bands[effectiveSupplyBand];
            requireValue(parameters !== undefined, `missing ${effectiveSupplyBand} balance`);

            const merchantInputNativeCost = product.materials.reduce(
                (total, material) => {
                    const input = merchantInputByItem.get(material.itemId);
                    return total + (
                        input === undefined
                            ? 0
                            : input.nativeBasePrice * material.count
                    );
                },
                0,
            );
            const merchantInputCostFloor = roundToStep(
                merchantInputNativeCost
                    * profile.merchantInputCostFloorMultiplier,
                profile.priceRoundingStep,
            );
            if (parameters.direction === "sell") {
                const price = Math.max(
                    roundToStep(
                        product.nativeBasePrice * parameters.sellPriceMultiplier,
                        profile.priceRoundingStep,
                    ),
                    merchantInputCostFloor,
                );
                const stock = clampInteger(
                    parameters.stockValueBudget / price,
                    profile.minimumUnitsPerActiveLine,
                    profile.maximumUnitsPerActiveLine,
                );
                sell.push({
                    itemId: product.productItemId,
                    displayNameZhHans: product.displayNameZhHans,
                    effectiveSupplyBand,
                    nativeBasePrice: product.nativeBasePrice,
                    overridePrice: price,
                    productNum: 1,
                    stock,
                    stockValueBudget: parameters.stockValueBudget,
                    merchantInputNativeCost,
                    merchantInputCostFloor,
                });
            } else if (parameters.direction === "procure") {
                const targetUnitPrice = roundToStep(
                    product.nativeBasePrice
                        * parameters.procurementPriceMultiplier,
                    profile.priceRoundingStep,
                );
                const quota = clampInteger(
                    parameters.procurementValueBudget / targetUnitPrice,
                    profile.minimumUnitsPerActiveLine,
                    profile.maximumUnitsPerActiveLine,
                );
                procure.push({
                    itemId: product.productItemId,
                    displayNameZhHans: product.displayNameZhHans,
                    effectiveSupplyBand,
                    nativeBasePrice: product.nativeBasePrice,
                    targetUnitPrice,
                    quota,
                    procurementValueBudget: parameters.procurementValueBudget,
                    nativePriceOverrideAvailable: false,
                });
            } else {
                fail(`unsupported market direction ${parameters.direction}`);
            }
        }
        requireValue(
            sell.length + procure.length === economy.auditedProducts.length,
            `${faction.factionId} market is incomplete`,
        );
        markets.set(faction.factionId, { sell, procure });
    }
    return markets;
}

function makeProductEntry(template, product, index) {
    const entry = structuredClone(template);
    entry.Name = String(index);
    field(entry, "StaticItemId").Value = product.itemId;
    field(entry, "ProductType").Value = "Normal";
    const price = field(entry, "OverridePrice");
    price.Value = product.overridePrice;
    price.IsZero = false;
    const productNum = field(entry, "ProductNum");
    productNum.Value = product.productNum;
    productNum.IsZero = false;
    const stock = field(entry, "Stock");
    stock.Value = product.stock;
    stock.IsZero = false;
    return entry;
}

function appendProductGroup(asset, rowName, products) {
    const rows = tableRows(asset, "item-shop create asset");
    requireValue(
        !rows.some((row) => row.Name === rowName),
        `duplicate product group ${rowName}`,
    );
    const templateRow = rows.find((row) =>
        Array.isArray(field(row, "productDataArray").Value)
        && field(row, "productDataArray").Value.length > 0);
    requireValue(templateRow !== undefined, "create asset has no product template");
    const entryTemplate = field(templateRow, "productDataArray").Value[0];
    const row = structuredClone(templateRow);
    row.Name = rowName;
    field(row, "productDataArray").Value = products.map(
        (product, index) => makeProductEntry(entryTemplate, product, index),
    );
    rows.push(row);
    addNames(asset, [rowName, ...products.map((product) => product.itemId)]);
}

function appendLotteryRow(asset, rowName, productGroupRowName, weight) {
    const rows = tableRows(asset, "item-shop lottery asset");
    requireValue(
        !rows.some((row) => row.Name === rowName),
        `duplicate lottery row ${rowName}`,
    );
    const templateRow = rows.find((row) =>
        Array.isArray(field(row, "lotteryDataArray").Value)
        && field(row, "lotteryDataArray").Value.length > 0);
    requireValue(templateRow !== undefined, "lottery asset has no entry template");
    const row = structuredClone(templateRow);
    row.Name = rowName;
    const entry = structuredClone(field(templateRow, "lotteryDataArray").Value[0]);
    entry.Name = "0";
    field(entry, "ShopGroupName").Value = productGroupRowName;
    const weightField = field(entry, "Weight");
    weightField.Value = weight;
    weightField.IsZero = false;
    field(row, "lotteryDataArray").Value = [entry];
    rows.push(row);
    addNames(asset, [rowName, productGroupRowName]);
}

const [
    economyPath,
    shopsPath,
    createDataPath,
    createDataCommonPath,
    lotteryDataPath,
    lotteryDataCommonPath,
    outputDirectory,
] = process.argv.slice(2);

if ([
    economyPath,
    shopsPath,
    createDataPath,
    createDataCommonPath,
    lotteryDataPath,
    lotteryDataCommonPath,
    outputDirectory,
].some((value) => !value)) {
    fail(
        "usage: node build_faction_economy_shops.mjs "
        + "<economy-contract> <shop-contract> "
        + "<create-json> <create-common-json> "
        + "<lottery-json> <lottery-common-json> <output-directory>",
    );
}

const economy = readJson(economyPath);
const shops = readJson(shopsPath);
requireValue(
    economy.gameBuild === shops.gameBuild,
    "economy and shop contracts target different game builds",
);
requireValue(
    shops.runtimeActivation.customProductRowsReady === true,
    "shop assets can only be built from a ready product-row contract",
);

const createData = readJson(createDataPath);
const createDataCommon = readJson(createDataCommonPath);
const lotteryData = readJson(lotteryDataPath);
const lotteryDataCommon = readJson(lotteryDataCommonPath);
const originalCreateRows = tableRows(createData, "create data").length;
const originalCreateCommonRows = tableRows(
    createDataCommon,
    "create common data",
).length;
const originalLotteryRows = tableRows(lotteryData, "lottery data").length;
const originalLotteryCommonRows = tableRows(
    lotteryDataCommon,
    "lottery common data",
).length;
const markets = buildEconomyMarkets(economy);
const representatives = [...shops.representatives].sort(
    (left, right) => left.slotIndex - right.slotIndex,
);
requireValue(representatives.length === 7, "expected seven economy representatives");
requireValue(
    new Set(representatives.map((row) => row.representedFactionId)).size === 7,
    "economy representatives must cover seven unique factions",
);
requireValue(
    new Set(representatives.map((row) => row.slotIndex)).size === 7,
    "economy representative slot indices must be unique",
);

const catalogRepresentatives = [];
for (const representative of representatives) {
    const market = markets.get(representative.representedFactionId);
    requireValue(
        market !== undefined,
        `no economy market for ${representative.representedFactionId}`,
    );
    for (const asset of [createData, createDataCommon]) {
        appendProductGroup(
            asset,
            representative.productGroupRowName,
            market.sell,
        );
    }
    for (const asset of [lotteryData, lotteryDataCommon]) {
        appendLotteryRow(
            asset,
            representative.lotteryRowName,
            representative.productGroupRowName,
            shops.nativeItemShopAssets.lotteryWeight,
        );
    }
    catalogRepresentatives.push({
        ...structuredClone(representative),
        salesChannel: "ItemShop",
        merchantAffiliation: shops.designPolicy.merchantOrganisationId,
        products: market.sell,
        requestedItems: market.procure,
    });
}

const createOutput = path.join(
    outputDirectory,
    "DT_ItemShopCreateData.PFT_Economy.json",
);
const createCommonOutput = path.join(
    outputDirectory,
    "DT_ItemShopCreateData_Common.PFT_Economy.json",
);
const lotteryOutput = path.join(
    outputDirectory,
    "DT_ItemShopLotteryData.PFT_Economy.json",
);
const lotteryCommonOutput = path.join(
    outputDirectory,
    "DT_ItemShopLotteryData_Common.PFT_Economy.json",
);
const catalogOutput = path.join(outputDirectory, "catalog.v1.json");

writeJson(createOutput, createData);
writeJson(createCommonOutput, createDataCommon);
writeJson(lotteryOutput, lotteryData);
writeJson(lotteryCommonOutput, lotteryDataCommon);
writeJson(catalogOutput, {
    schemaVersion: "1.0.0",
    gameBuild: economy.gameBuild,
    baselineId: shops.baselineId,
    balanceProfileId: economy.marketRules.balanceProfile.profileId,
    economyContractSha256: sha256(economyPath),
    shopContractSha256: sha256(shopsPath),
    sourceTables: {
        createData: {
            path: createDataPath,
            originalRows: originalCreateRows,
            outputRows: tableRows(createData, "create output").length,
        },
        createDataCommon: {
            path: createDataCommonPath,
            originalRows: originalCreateCommonRows,
            outputRows: tableRows(createDataCommon, "create common output").length,
        },
        lotteryData: {
            path: lotteryDataPath,
            originalRows: originalLotteryRows,
            outputRows: tableRows(lotteryData, "lottery output").length,
        },
        lotteryDataCommon: {
            path: lotteryDataCommonPath,
            originalRows: originalLotteryCommonRows,
            outputRows: tableRows(
                lotteryDataCommon,
                "lottery common output",
            ).length,
        },
    },
    totals: {
        representatives: catalogRepresentatives.length,
        productRows: catalogRepresentatives.reduce(
            (total, row) => total + row.products.length,
            0,
        ),
        requestedRows: catalogRepresentatives.reduce(
            (total, row) => total + row.requestedItems.length,
            0,
        ),
        marketSignals: catalogRepresentatives.reduce(
            (total, row) =>
                total + row.products.length + row.requestedItems.length,
            0,
        ),
    },
    procurementSettlement: structuredClone(shops.procurementAdapter),
    runtimeActivation: structuredClone(shops.runtimeActivation),
    representatives: catalogRepresentatives,
    generatedFiles: {
        createDataJson: createOutput,
        createDataCommonJson: createCommonOutput,
        lotteryDataJson: lotteryOutput,
        lotteryDataCommonJson: lotteryCommonOutput,
        catalogJson: catalogOutput,
    },
});

console.log(JSON.stringify({
    representatives: catalogRepresentatives.length,
    productRows: catalogRepresentatives.reduce(
        (total, row) => total + row.products.length,
        0,
    ),
    requestedRows: catalogRepresentatives.reduce(
        (total, row) => total + row.requestedItems.length,
        0,
    ),
    createRows: tableRows(createData, "create output").length,
    lotteryRows: tableRows(lotteryData, "lottery output").length,
    outputDirectory,
}));
