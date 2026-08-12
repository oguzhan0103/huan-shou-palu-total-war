local FactionJoinNativePresenter = {}

local function count(values)
    return type(values) == "table" and #values or 0
end

local function format_offer(offer)
    local preview = offer.preview or {}
    local diplomacy_changes = preview.diplomacyChanges or {}
    local lines = {
        "势力加入确认",
        "",
        "目标势力：" .. tostring(offer.factionId or "<unknown>"),
        "当前好感：" .. tostring(preview.reputation or 0),
        "加入门槛：" .. tostring(preview.requiredReputation or 0),
        "加入身份：" .. tostring(preview.projectedRankId or "Member"),
        "允许同时加入多个势力："
            .. (preview.multipleMembershipsAllowed == true and "是" or "否"),
        "外交变化数量：" .. tostring(count(diplomacy_changes)),
    }
    for _, change in ipairs(diplomacy_changes) do
        table.insert(
            lines,
            "- " .. tostring(change.factionId)
                .. "：" .. tostring(change.before)
                .. " -> " .. tostring(change.after)
        )
    end
    table.insert(lines, "")
    table.insert(lines, "F1 二次确认并加入    F2 取消")
    table.insert(lines, "确认前不会改变势力、好感或世界状态。")
    return table.concat(lines, "\n")
end

local function format_resolution(resolution)
    local outcome = resolution.outcome or {}
    local lines = { "势力加入结果", "" }
    if resolution.joined == true then
        table.insert(
            lines,
            "已加入：" .. tostring(resolution.factionId or "<unknown>")
        )
        table.insert(
            lines,
            "当前身份：" .. tostring(outcome.rankId or "Member")
        )
        table.insert(
            lines,
            "外交变化数量："
                .. tostring(count(outcome.diplomacyChanges))
        )
    else
        table.insert(lines, "本次加入已取消或未完成。")
        if resolution.eligibilityReason ~= nil then
            table.insert(
                lines,
                "原因：" .. tostring(resolution.eligibilityReason)
            )
        end
    end
    table.insert(lines, "")
    table.insert(lines, "F2 关闭")
    return table.concat(lines, "\n")
end

function FactionJoinNativePresenter.create(backend)
    assert(
        type(backend) == "table"
            and type(backend.show_text) == "function",
        "native text backend is required"
    )
    return setmetatable({
        version = "1.0.0",
        native = true,
        backend = backend,
        offerCount = 0,
        resolutionCount = 0,
        lastError = nil,
    }, { __index = FactionJoinNativePresenter })
end

function FactionJoinNativePresenter:present_offer(offer)
    local shown, reason = self.backend:show_text(
        format_offer(offer),
        "human-faction-join-offer",
        offer
    )
    if shown then
        self.offerCount = self.offerCount + 1
        self.lastError = nil
    else
        self.lastError = reason
    end
    return {
        ok = shown == true,
        reason = shown and "join-offer-presented" or reason,
    }
end

function FactionJoinNativePresenter:present_resolution(resolution)
    local shown, reason = self.backend:show_text(
        format_resolution(resolution),
        "human-faction-join-resolution",
        resolution
    )
    if shown then
        self.resolutionCount = self.resolutionCount + 1
        self.lastError = nil
    else
        self.lastError = reason
    end
    return {
        ok = shown == true,
        reason = shown and "join-resolution-presented" or reason,
    }
end

function FactionJoinNativePresenter:status()
    return {
        apiVersion = self.version,
        native = true,
        offerCount = self.offerCount,
        resolutionCount = self.resolutionCount,
        lastError = self.lastError,
        storyContentIncluded = false,
        deterministicRuleEngineOwnsOutcome = true,
    }
end

return FactionJoinNativePresenter
