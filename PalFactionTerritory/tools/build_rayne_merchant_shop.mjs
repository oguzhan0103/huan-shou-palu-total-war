import fs from "node:fs";
import path from "node:path";

function fail(message) {
    throw new Error(message);
}

function readJson(filePath) {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, value) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function field(row, name) {
    const property = row.Value.find((candidate) => candidate.Name === name);
    if (property === undefined) {
        fail(`row ${row.Name} is missing ${name}`);
    }
    return property;
}

function canonicalPenalty(id) {
    let penalty = 0;
    if (id.startsWith("Quest_")) penalty += 1000;
    if (id.startsWith("SUMMON_")) penalty += 1000;
    if (id.endsWith("_Oilrig")) penalty += 500;
    if (id.endsWith("_Flower")) penalty += 100;
    penalty += id.length / 1000;
    return penalty;
}

function selectPaldexEntries(monsterAsset) {
    const rows = monsterAsset.Exports?.[0]?.Table?.Data;
    if (!Array.isArray(rows)) {
        fail("monster asset does not contain a DataTable export");
    }

    const eligible = rows
        .map((row) => ({
            id: row.Name,
            zukanIndex: field(row, "ZukanIndex").Value,
            zukanIndexSuffix: field(row, "ZukanIndexSuffix").Value ?? "",
            isPal: field(row, "IsPal").Value,
            isBoss: field(row, "IsBoss").Value,
        }))
        .filter((entry) => entry.isPal === true && entry.isBoss === false && entry.zukanIndex > 0);

    const grouped = new Map();
    for (const entry of eligible) {
        const key = `${entry.zukanIndex}:${entry.zukanIndexSuffix}`;
        const candidates = grouped.get(key) ?? [];
        candidates.push(entry);
        grouped.set(key, candidates);
    }

    const entries = [];
    const duplicateGroups = [];
    for (const [paldexKey, candidates] of grouped) {
        candidates.sort((left, right) => {
            const scoreDifference = canonicalPenalty(left.id) - canonicalPenalty(right.id);
            return scoreDifference !== 0 ? scoreDifference : left.id.localeCompare(right.id);
        });
        entries.push(candidates[0]);
        if (candidates.length > 1) {
            duplicateGroups.push({
                paldexKey,
                selected: candidates[0].id,
                excluded: candidates.slice(1).map((entry) => entry.id),
            });
        }
    }

    entries.sort((left, right) =>
        left.zukanIndex - right.zukanIndex
        || String(left.zukanIndexSuffix).localeCompare(String(right.zukanIndexSuffix))
        || left.id.localeCompare(right.id));

    if (eligible.length !== 300) {
        fail(`expected 300 eligible raw Pal rows, got ${eligible.length}`);
    }
    if (entries.length !== 288) {
        fail(`expected 288 unique Paldex entries, got ${entries.length}`);
    }
    return { entries, duplicateGroups, eligibleCount: eligible.length };
}

function makeCharacterIdEntry(template, id, index) {
    const result = structuredClone(template);
    result.Name = String(index);
    field(result, "Key").Value = id;
    return result;
}

function appendMerchantRow(shopAsset, palIds, options) {
    const rows = shopAsset.Exports?.[0]?.Table?.Data;
    if (!Array.isArray(rows) || rows.length === 0) {
        fail("shop asset does not contain a DataTable export");
    }
    if (rows.some((row) => row.Name === options.rowName)) {
        fail(`shop row ${options.rowName} already exists`);
    }

    const row = structuredClone(rows[0]);
    row.Name = options.rowName;
    field(row, "MaxLostPalNum").Value = options.maxLostPalNum;
    field(row, "CharacterNum").Value = palIds.length;
    field(row, "MinCharacterLevel").Value = options.minLevel;
    field(row, "MaxCharacterLevel").Value = options.maxLevel;

    const characterArray = field(row, "CharacterIDArray");
    const entryTemplate = characterArray.Value?.[0];
    if (entryTemplate === undefined) {
        fail("shop template row has no CharacterIDArray entry");
    }
    characterArray.Value = palIds.map((id, index) =>
        makeCharacterIdEntry(entryTemplate, id, index));

    rows.push(row);

    if (!Array.isArray(shopAsset.NameMap)) {
        fail("shop asset does not contain a NameMap");
    }
    const knownNames = new Set(shopAsset.NameMap);
    for (const name of [options.rowName, ...palIds]) {
        if (!knownNames.has(name)) {
            shopAsset.NameMap.push(name);
            knownNames.add(name);
        }
    }
    return row;
}

const [
    monsterAssetPath,
    shopAssetPath,
    outputShopJsonPath,
    outputManifestPath,
] = process.argv.slice(2);

if ([monsterAssetPath, shopAssetPath, outputShopJsonPath, outputManifestPath].some((value) => !value)) {
    fail(
        "usage: node build_rayne_merchant_shop.mjs "
        + "<monster-json> <shop-json> <output-shop-json> <output-manifest-json>",
    );
}

const options = {
    schemaVersion: "1.0.0",
    gameBuild: "24181527",
    rowName: "PFT_Rayne_AllPaldex",
    minLevel: 60,
    maxLevel: 70,
    maxLostPalNum: 5,
};

const monsterAsset = readJson(monsterAssetPath);
const shopAsset = readJson(shopAssetPath);
const selection = selectPaldexEntries(monsterAsset);
const palIds = selection.entries.map((entry) => entry.id);
appendMerchantRow(shopAsset, palIds, options);

writeJson(outputShopJsonPath, shopAsset);
writeJson(outputManifestPath, {
    schemaVersion: options.schemaVersion,
    gameBuild: options.gameBuild,
    shopRowName: options.rowName,
    sourceEligibleRowCount: selection.eligibleCount,
    uniquePaldexEntryCount: palIds.length,
    levelRange: {
        min: options.minLevel,
        max: options.maxLevel,
    },
    nativePricePolicy: "unchanged; higher prices result from level 60-70 products",
    entries: selection.entries,
    duplicateGroups: selection.duplicateGroups,
});

console.log(JSON.stringify({
    shopRowName: options.rowName,
    uniquePaldexEntryCount: palIds.length,
    duplicateGroupCount: selection.duplicateGroups.length,
    minLevel: options.minLevel,
    maxLevel: options.maxLevel,
    outputShopJsonPath,
    outputManifestPath,
}));
