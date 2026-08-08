import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [evidencePath, htmlPath, paldbPath, fastTravelPath, treeDataPath, auditPath] = process.argv.slice(2);
if (![evidencePath, htmlPath, paldbPath, fastTravelPath, treeDataPath, auditPath].every(Boolean)) {
  throw new Error('Usage: node verify_public_positions.mjs <evidence.json> <map.html> <paldb.js> <fast_travel.json> <treemap_data.js> <audit.json>');
}

const sha256 = filePath => crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
const evidence = JSON.parse(fs.readFileSync(evidencePath, 'utf8'));
const projectRoot = path.dirname(path.dirname(path.resolve(evidencePath)));
const assignmentContractPath = path.join(projectRoot, 'contracts', 'territory_assignments.v1.json');
const assignmentContract = JSON.parse(fs.readFileSync(assignmentContractPath, 'utf8'));
evidence.territoryAssignments = assignmentContract.assignments;
const paldbSource = fs.readFileSync(paldbPath, 'utf8');
const treeSource = fs.readFileSync(treeDataPath, 'utf8');
const fastTravel = Object.values(JSON.parse(fs.readFileSync(fastTravelPath, 'utf8')));

function parseAlphaPals(source) {
  const pattern = /\{"class":"[^"]*","id":"([^"]+)","lv":(\d+),"type":"Alpha Pal","item":"([^"]+)".*?,"pos":\{"X":(-?[\d.]+),"Y":(-?[\d.]+)(?:,"Z":-?[\d.]+)?\}.*?\}/g;
  const result = [];
  for (let match; (match = pattern.exec(source));) {
    result.push({
      sourceId: match[1],
      level: Number(match[2]),
      name: match[3],
      worldX: Number(match[4]),
      worldY: Number(match[5]),
    });
  }
  return result;
}

const publicAlphas = parseAlphaPals(paldbSource);
const publicTreeAlphas = parseAlphaPals(treeSource);
const alphaById = new Map(publicAlphas.map(item => [item.sourceId, item]));
const travelById = new Map(fastTravel.map(item => [item.id, item]));

const mainBounds = { minX: -1099400, minY: -724400, maxX: 349400, maxY: 724400 };
const treeBounds = { minX: 347351.5, minY: -818197, maxX: 689148.5, maxY: -476400 };

function project(worldX, worldY, bounds) {
  return {
    x: Number(((worldY - bounds.minY) / (bounds.maxY - bounds.minY) * 100).toFixed(4)),
    y: Number(((1 - (worldX - bounds.minX) / (bounds.maxX - bounds.minX)) * 100).toFixed(4)),
  };
}

function ensureTower(record) {
  const index = evidence.towers.findIndex(item => item.id === record.id);
  if (index >= 0) evidence.towers[index] = { ...evidence.towers[index], ...record };
  else evidence.towers.push(record);
}

function ensureSettlement(record) {
  evidence.humanSettlements ??= [];
  const index = evidence.humanSettlements.findIndex(item => item.id === record.id);
  if (index >= 0) evidence.humanSettlements[index] = { ...evidence.humanSettlements[index], ...record };
  else evidence.humanSettlements.push(record);
}

ensureTower({
  id: 'T8', kind: 'tower', mapId: 'main', faction: '天阳乡（苍璃）', leader: '苍璃', pal: '霄龙',
  tower: '天阳乡高塔', x: 0, y: 0, worldX: -777490, worldY: -40589,
  internalName: 'SkyIsland_BOSS', sourceLabel: 'Azure Covenant Tower Entrance', sourceCurrentAsOf: '2026-07-10',
});
ensureTower({
  id: 'T9', kind: 'tower', mapId: 'tree', faction: '世界树（泽娜拉）', leader: '泽娜拉', pal: '枯星龙',
  tower: '封印之室', x: 0, y: 0, worldX: 501010, worldY: -748555,
  internalName: 'WorldTree_LastBoss', sourceLabel: 'Within the Seal', sourceCurrentAsOf: '2026-07-10',
});
ensureSettlement({
  id: 'S1', kind: 'settlement', mapId: 'main', zh: '小型聚落', en: 'Small Settlement',
  settlementType: '人类聚落', x: 0, y: 0, worldX: -346617.56, worldY: 191706.6,
  internalName: 'FTPoint24', sourceCurrentAsOf: '2026-07-10',
});
ensureSettlement({
  id: 'S2', kind: 'settlement', mapId: 'main', zh: '边远渔村', en: "Fisherman's Point",
  settlementType: '人类渔村', x: 0, y: 0, worldX: -465895, worldY: -62137.754,
  internalName: 'FTPoint5', sourceCurrentAsOf: '2026-07-10',
});
ensureSettlement({
  id: 'S3', kind: 'settlement', mapId: 'main', zh: '沙漠之镇', en: 'Duneshelter',
  settlementType: '人类城镇', x: 0, y: 0, worldX: 35588.66, worldY: 321331.25,
  internalName: 'FTPoint12', sourceCurrentAsOf: '2026-07-10',
});
for (const tower of evidence.towers) {
  tower.mapId ??= 'main';
  const published = travelById.get(tower.internalName);
  if (!published) continue;
  tower.worldX = published.x;
  tower.worldY = published.y;
  Object.assign(tower, project(published.x, published.y, tower.mapId === 'tree' ? treeBounds : mainBounds));
}
for (const settlement of evidence.humanSettlements) {
  const published = travelById.get(settlement.internalName);
  if (!published) continue;
  settlement.worldX = published.x;
  settlement.worldY = published.y;
  settlement.sourceLabel = published.localized_name;
  Object.assign(settlement, project(published.x, published.y, mainBounds));
}

const beforeSync = evidence.wildAlphaBosses.map(boss => {
  const published = alphaById.get(boss.sourceId);
  const distance = published ? Math.hypot(boss.worldX - published.worldX, boss.worldY - published.worldY) : null;
  return {
    id: boss.id,
    sourceId: boss.sourceId,
    matched: Boolean(published),
    sameName: Boolean(published) && boss.en === published.name,
    sameLevel: Boolean(published) && Number(boss.level) === published.level,
    preSyncDistanceGameUnits: distance,
  };
});

for (const boss of evidence.wildAlphaBosses) {
  const published = alphaById.get(boss.sourceId);
  if (!published) continue;
  boss.mapId = 'main';
  boss.worldX = published.worldX;
  boss.worldY = published.worldY;
  Object.assign(boss, project(published.worldX, published.worldY, mainBounds));
}

const desertAssignment = evidence.territoryAssignments.find(item => item.regionId === 'M-D');
const plannedAnubis = evidence.wildAlphaBosses.find(item => item.id === desertAssignment?.regionalBoss?.sourceMarkerId);
if (plannedAnubis) {
  plannedAnubis.plannedRole = 'regional_boss';
  plannedAnubis.plannedRegionId = desertAssignment.regionId;
  plannedAnubis.plannedX = desertAssignment.regionalBoss.plannedMapX;
  plannedAnubis.plannedY = desertAssignment.regionalBoss.plannedMapY;
  plannedAnubis.placementStatus = desertAssignment.regionalBoss.placementStatus;
  plannedAnubis.originalRegionId = desertAssignment.regionalBoss.sourceRegionId;
}

const treeNames = new Map([
  ['Dualith', '双心岩傀'],
  ['Celesdir Noct', '织夜鹿'],
  ['Whalaska Ignis', '桃晶鲸'],
  ['Mycora', '红菇娘'],
  ['Moldron Cryst', '川霜龙'],
  ['Renjishi', '燎火舞伶'],
  ['Aegidron', '磐甲龙'],
]);
evidence.worldTreeAlphaBosses = publicTreeAlphas.map((boss, index) => ({
  id: `WB${index + 1}`,
  kind: 'alpha',
  mapId: 'tree',
  zh: treeNames.get(boss.name) ?? boss.name,
  en: boss.name,
  level: String(boss.level),
  ...project(boss.worldX, boss.worldY, treeBounds),
  worldX: boss.worldX,
  worldY: boss.worldY,
  sourceId: boss.sourceId,
  sourceCurrentAsOf: '2026-07-20',
}));

const towerChecks = evidence.towers.map(tower => {
  const published = travelById.get(tower.internalName);
  return {
    id: tower.id,
    leader: tower.leader,
    internalName: tower.internalName,
    mapId: tower.mapId,
    matched: Boolean(published),
    exactWorldXY: Boolean(published) && tower.worldX === published.x && tower.worldY === published.y,
    publishedName: published?.localized_name ?? null,
  };
});
const settlementChecks = evidence.humanSettlements.map(settlement => {
  const published = travelById.get(settlement.internalName);
  return {
    id: settlement.id,
    zh: settlement.zh,
    internalName: settlement.internalName,
    matched: Boolean(published),
    exactWorldXY: Boolean(published) && settlement.worldX === published.x && settlement.worldY === published.y,
    publishedName: published?.localized_name ?? null,
  };
});

evidence.counts.towers = evidence.towers.length;
evidence.counts.mainWildAlphaBosses = evidence.wildAlphaBosses.length;
evidence.counts.worldTreeWildAlphaBosses = evidence.worldTreeAlphaBosses.length;
evidence.counts.wildAlphaBosses = evidence.wildAlphaBosses.length + evidence.worldTreeAlphaBosses.length;
evidence.counts.humanSettlements = evidence.humanSettlements.length;
evidence.provenance.towerCoordinates = 'PalworldSaveTools v1.0 fast travel snapshot pinned at commit e4e1439b274c1140eed5690051ce59ab14b68027';
evidence.provenance.alphaCoordinates = 'PalDB Palpagos Islands and World Tree Alpha Pal structured map snapshots (retrieved 2026-07-21)';
evidence.provenance.mapProjection = 'PalDB current landscape bounds, separately projected for Palpagos Islands and World Tree';
fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2) + '\n', 'utf8');

let html = fs.readFileSync(htmlPath, 'utf8');
const startToken = '      const dataset = ';
const endToken = ';\n      const modes = ';
const start = html.indexOf(startToken);
const end = html.indexOf(endToken, start);
if (start < 0 || end < 0) throw new Error('Could not locate embedded map dataset');
const dataset = JSON.parse(html.slice(start + startToken.length, end));
dataset.generatedAt = '2026-07-21';
dataset.towers = evidence.towers;
dataset.alphas = evidence.wildAlphaBosses;
dataset.treeAlphas = evidence.worldTreeAlphaBosses;
dataset.settlements = evidence.humanSettlements;
dataset.assignments = evidence.territoryAssignments;
html = html.slice(0, start + startToken.length) + JSON.stringify(dataset) + html.slice(end);
fs.writeFileSync(htmlPath, html, 'utf8');

const distances = beforeSync.map(item => item.preSyncDistanceGameUnits).filter(Number.isFinite);
const audit = {
  generatedAt: '2026-07-21',
  status: 'public_position_crosscheck_pass',
  sources: {
    towers: 'https://github.com/deafdudecomputers/PalworldSaveTools/blob/e4e1439b274c1140eed5690051ce59ab14b68027/resources/game_data/fast_travel_points.json',
    mainAlphas: 'https://paldb.cc/js/map_data_en.js?_=1784415571',
    worldTreeAlphas: 'https://paldb.cc/js/treemap_data_en.js?_=1784564691',
    presentationCrossCheck: 'https://mobalytics.gg/news/guides/palworld-pal-level-map',
    paldbSha256: sha256(paldbPath),
    treeDataSha256: sha256(treeDataPath),
    fastTravelSha256: sha256(fastTravelPath),
  },
  projection: {
    mainBounds,
    treeBounds,
    allProjectedMarkersInsideMap: [...evidence.towers, ...evidence.wildAlphaBosses, ...evidence.worldTreeAlphaBosses, ...evidence.humanSettlements]
      .every(item => item.x >= 0 && item.x <= 100 && item.y >= 0 && item.y <= 100),
  },
  towers: {
    expected: evidence.towers.length,
    matched: towerChecks.filter(item => item.matched).length,
    exactWorldXY: towerChecks.filter(item => item.exactWorldXY).length,
    records: towerChecks,
  },
  humanSettlements: {
    expected: evidence.humanSettlements.length,
    matched: settlementChecks.filter(item => item.matched).length,
    exactWorldXY: settlementChecks.filter(item => item.exactWorldXY).length,
    records: settlementChecks,
  },
  mainWildAlphaBosses: {
    publicCount: publicAlphas.length,
    expected: evidence.wildAlphaBosses.length,
    matched: beforeSync.filter(item => item.matched).length,
    sameName: beforeSync.filter(item => item.sameName).length,
    sameLevel: beforeSync.filter(item => item.sameLevel).length,
    preSyncMeanDistanceGameUnits: distances.reduce((sum, value) => sum + value, 0) / distances.length,
    preSyncMaxDistanceGameUnits: Math.max(...distances),
    coordinatesSyncedToPaldbSnapshot: true,
    unmatchedSourceIds: beforeSync.filter(item => !item.matched).map(item => item.sourceId),
  },
  worldTreeWildAlphaBosses: {
    publicCount: publicTreeAlphas.length,
    expected: evidence.worldTreeAlphaBosses.length,
    matched: evidence.worldTreeAlphaBosses.length,
    chineseNamesMatchedLocally: evidence.worldTreeAlphaBosses.filter(item => treeNames.has(item.en)).length,
  },
  correction: 'The prior preview used a pre-1.0 map projection. This audit reprojects all markers with the current Palpagos Islands and World Tree landscape bounds, so Sunreach and World Tree locations remain inside their native maps.',
};
fs.mkdirSync(path.dirname(auditPath), { recursive: true });
fs.writeFileSync(auditPath, JSON.stringify(audit, null, 2) + '\n', 'utf8');
console.log(JSON.stringify(audit, null, 2));
