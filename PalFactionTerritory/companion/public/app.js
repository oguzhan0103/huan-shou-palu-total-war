const FACTIONS = {
  "pwft.faction.rayne_syndicate": ["雷恩盗猎集团", "Rayne Syndicate"],
  "pwft.faction.free_pal_alliance": ["帕鲁保护团体", "Free Pal Alliance"],
  "pwft.faction.eternal_pyre": ["永炎同心会", "Eternal Pyre"],
  "pwft.faction.pidf": ["帕洛斯群岛自卫队", "PIDF"],
  "pwft.faction.pal_genetic_research_unit": ["基因研究部队", "Genetic Research Unit"],
  "pwft.faction.moonflower": ["月花会", "Moonflower"],
  "pwft.faction.feybreak_army": ["天坠军", "Feybreak Army"],
  "pwft.faction.desert_pal_tribe": ["沙漠帕鲁部落", "Desert Pal Tribe"],
  "pwft.faction.snow_pal_tribe": ["雪地帕鲁部落", "Snow Pal Tribe"],
  "pwft.faction.fire_pal_tribe": ["火焰帕鲁部落", "Fire Pal Tribe"],
  "pwft.faction.feybreak_composite_pal_tribe": ["天坠之地综合帕鲁部落", "Feybreak United Pal Tribe"],
  "pwft.faction.dark_nocturnal_pal_tribe": ["暗属性帕鲁部落", "Nocturnal Dark Pal Tribe"],
};

const RANKS = {
  Member: "成员",
  CoreMember: "核心成员",
  Leader: "领队",
  Lord: "领主",
};

const RELATIONS = {
  Friendly: "友好",
  Hostile: "敌对",
  Neutral: "中立",
  Player: "已加入",
};

const $ = (id) => document.getElementById(id);
let eventCache = [];

function nameOf(id) {
  return FACTIONS[id]?.[0] ?? id.replace("pwft.faction.", "");
}

function formatTime(epoch) {
  if (!epoch) return "—";
  return new Date(epoch * 1000).toLocaleString("zh-CN", { hour12: false });
}

function commerceText(record) {
  const commerce = record.commerce ?? {};
  const negative = commerce.negativeRecoveryAwarded ?? 0;
  const positive = commerce.nonNegativeAwarded ?? 0;
  return `商业额度：修复 ${negative} · 正向 ${positive}`;
}

function factionCard(record) {
  const human = record.kind === "Human";
  const min = human ? 0 : -100;
  const max = human ? 1200 : 0;
  const clamped = Math.max(min, Math.min(max, Number(record.reputation ?? min)));
  const progress = ((clamped - min) / (max - min)) * 100;
  const relation = record.relation ?? "Neutral";
  const rank = human ? (RANKS[record.rankId] ?? (record.joined ? "成员" : "可加入")) : "部落关系";
  return `
    <article class="faction-card ${relation.toLowerCase()}">
      <div class="faction-title">
        <div>
          <h3>${nameOf(record.factionId)}</h3>
          <small>${FACTIONS[record.factionId]?.[1] ?? record.factionId}</small>
        </div>
        <span class="relation-chip">${RELATIONS[relation] ?? relation}</span>
      </div>
      <div class="reputation-row">
        <strong>${record.reputation ?? 0}</strong>
        <span>${rank}</span>
      </div>
      <div class="progress"><i style="width:${progress}%"></i></div>
      <div class="faction-meta">
        <span>${human ? commerceText(record) : "红 → 蓝，不加入玩家势力"}</span>
        <span>${record.guardAccess ? "护卫已解锁" : human ? "护卫未解锁" : "有限论道"}</span>
      </div>
    </article>`;
}

function renderFactions(factions) {
  const values = Object.values(factions ?? {});
  const humans = values.filter((faction) => faction.kind === "Human");
  const pals = values.filter((faction) => faction.kind === "Pal");
  humans.sort((a, b) => nameOf(a.factionId).localeCompare(nameOf(b.factionId), "zh-CN"));
  pals.sort((a, b) => nameOf(a.factionId).localeCompare(nameOf(b.factionId), "zh-CN"));
  $("human-factions").innerHTML = humans.map(factionCard).join("");
  $("pal-factions").innerHTML = pals.map(factionCard).join("");
  return { humans, pals };
}

function publicItems(event) {
  if (event.productId) return `${event.productId} × ${event.buyNum ?? 1}`;
  if (!Array.isArray(event.items) || event.items.length === 0) return "—";
  return event.items.map((item) => `${item.itemId ?? "未知"} × ${item.count ?? 0}`).join("、");
}

function renderTransactions(events) {
  const rows = events
    .filter((event) => ["commerce-buy-result", "commerce-sale-confirmed"].includes(event.type))
    .sort((a, b) => (b.sequence ?? 0) - (a.sequence ?? 0));
  $("transaction-total").textContent = String(rows.filter((row) => row.ok).length);
  $("empty-transactions").classList.toggle("hidden", rows.length > 0);
  $("transactions").innerHTML = rows.map((event) => {
    const buy = event.type === "commerce-buy-result";
    const applied = Number(event.applied ?? 0);
    const status = !event.ok
      ? "失败/取消"
      : event.settlementEnabled === false
        ? "交易已确认 · 好感待验收"
        : applied > 0 ? "已入账" : (event.reason ?? "已确认");
    return `<tr>
      <td>${formatTime(event.epoch)}</td>
      <td>${nameOf(event.factionId ?? "")}</td>
      <td><span class="direction ${buy ? "buy" : "sell"}">${buy ? "玩家购买" : "玩家出售"}</span></td>
      <td>${publicItems(event)}</td>
      <td class="applied">${applied > 0 ? `+${applied}` : "0"}</td>
      <td>${status}</td>
    </tr>`;
  }).join("");
}

function setConnected(ok, detail) {
  $("connection-dot").classList.toggle("online", ok);
  $("connection-text").textContent = ok ? "账本连接正常" : "等待游戏账本";
  $("profile-text").textContent = detail;
}

async function refresh() {
  try {
    const [stateResponse, eventResponse] = await Promise.all([
      fetch("/api/state", { cache: "no-store" }),
      fetch("/api/events", { cache: "no-store" }),
    ]);
    const payload = await stateResponse.json();
    const eventPayload = await eventResponse.json();
    if (!payload.ok) {
      setConnected(false, payload.reason ?? "等待世界与玩家身份");
      $("waiting").classList.remove("hidden");
      $("dashboard").classList.add("hidden");
      return;
    }

    const state = payload.state;
    const progression = state.progression ?? {};
    const { humans, pals } = renderFactions(progression.factions);
    eventCache = eventPayload.ok ? (eventPayload.events ?? []) : eventCache;
    renderTransactions(eventCache);

    const humanLords = humans.filter((faction) => faction.joined && faction.rankId === "Lord").length;
    const palFriendly = pals.filter((faction) => faction.relation === "Friendly").length;
    $("human-lords").textContent = `${humanLords} / ${humans.length || 7}`;
    $("pal-friendly").textContent = `${palFriendly} / ${pals.length || 5}`;
    $("ending-status").textContent = state.gates?.ending3Unlocked ? "已解锁" : "未解锁";
    $("ending-status").classList.toggle("unlocked", Boolean(state.gates?.ending3Unlocked));
    $("revision-text").textContent = `账本修订 ${progression.revision ?? 0}`;
    $("updated-text").textContent = `更新 ${formatTime(state.updatedAtEpoch)}`;
    setConnected(true, `世界 ${state.identity?.worldDirectory?.slice(0, 8) ?? "—"} · 玩家 ${state.identity?.playerUid?.slice(0, 8) ?? "—"}`);
    $("waiting").classList.add("hidden");
    $("dashboard").classList.remove("hidden");
  } catch (error) {
    setConnected(false, `操作台连接失败：${error.message}`);
  }
}

$("refresh-button").addEventListener("click", refresh);
refresh();
setInterval(refresh, 2000);
