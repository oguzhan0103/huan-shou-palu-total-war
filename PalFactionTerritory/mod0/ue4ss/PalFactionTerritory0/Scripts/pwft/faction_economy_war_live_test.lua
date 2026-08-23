local FactionEconomyWarLiveTest = {}

local API_VERSION = "1.0.0"
local STATE_SCHEMA_VERSION = "1.0.0"

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function non_empty(value)
    return type(value) == "string" and value ~= ""
end

local function make_boot_token()
    return tostring(os.time()) .. ":" .. tostring({})
end

local function validate(
    progression,
    ledger,
    economy,
    war,
    merchant_runtime,
    options
)
    assert(type(progression) == "table"
            and type(progression.state) == "table",
        "progression state is required")
    assert(type(ledger) == "table"
            and type(ledger.apply_event) == "function",
        "resource ledger is required")
    assert(type(economy) == "table"
            and type(economy.commodity_signal) == "function",
        "dynamic economy is required")
    assert(type(war) == "table"
            and type(war.advance_shortage) == "function",
        "economy-war runtime is required")
    assert(type(merchant_runtime) == "table"
            and type(merchant_runtime.refresh_dynamic_market) == "function",
        "economy merchant runtime is required")
    for _, key in ipairs({
        "runId",
        "factionId",
        "resourceId",
        "productItemId",
    }) do
        assert(non_empty(options[key]), key .. " is required")
    end
    assert(type(options.initialQuantity) == "number"
            and options.initialQuantity > 1,
        "initial resource quantity must be above one")
    assert(type(options.firstReduction) == "number"
            and options.firstReduction > 0,
        "first resource reduction must be positive")
    assert(type(options.secondReduction) == "number"
            and options.secondReduction > 0,
        "second resource reduction must be positive")
end

local function ensure_state(progression, run_id)
    local root = progression.state
    if type(root.factionEconomyWarLiveTest) ~= "table"
        or root.factionEconomyWarLiveTest.runId ~= run_id then
        root.factionEconomyWarLiveTest = {
            schemaVersion = STATE_SCHEMA_VERSION,
            runId = run_id,
            phase = "baseline",
            stepCount = 0,
            persistenceConfirmed = false,
            warBootToken = nil,
        }
    end
    local state = root.factionEconomyWarLiveTest
    assert(state.schemaVersion == STATE_SCHEMA_VERSION,
        "unsupported economy-war live-test snapshot")
    return state
end

function FactionEconomyWarLiveTest.create(
    progression,
    ledger,
    economy,
    war,
    merchant_runtime,
    options
)
    options = options or {}
    validate(
        progression,
        ledger,
        economy,
        war,
        merchant_runtime,
        options
    )
    local instance = setmetatable({
        version = API_VERSION,
        progression = progression,
        ledger = ledger,
        economy = economy,
        war = war,
        merchantRuntime = merchant_runtime,
        options = options,
        bootToken = options.bootToken or make_boot_token(),
        persist = options.persist,
        capabilities = {
            stagedResourceEvents = true,
            nativeMerchantRefreshRequired =
                options.nativeMerchantRequired == true,
            shortageTradeThreatWar = true,
            restartPersistenceGate = true,
            ceasefireRecovery = true,
            merchantIdentityPreserved = true,
            storyContentIncluded = false,
            palworldSaveMutation = false,
        },
    }, { __index = FactionEconomyWarLiveTest })
    instance.state = ensure_state(progression, options.runId)
    if type(progression.register_restore_listener) == "function" then
        local registered = progression:register_restore_listener(
            "pwft.faction-economy-war-live-test.v1",
            function()
                instance.state = ensure_state(
                    progression,
                    options.runId
                )
                return result(true, "economy-war-live-test-state-rebound")
            end
        )
        assert(registered.ok, registered.reason)
    end
    return instance
end

function FactionEconomyWarLiveTest:_persist()
    if type(self.persist) ~= "function" then
        return true, "persistence-callback-not-configured"
    end
    local ok, persisted = pcall(
        self.persist,
        self.progression:export_snapshot()
    )
    if not ok then return false, tostring(persisted) end
    if type(persisted) == "table" and persisted.ok ~= true then
        return false, tostring(persisted.reason)
    end
    return true, "live-test-state-persisted"
end

function FactionEconomyWarLiveTest:_market_snapshot()
    local signal, reason = self.economy:commodity_signal(
        self.options.factionId,
        self.options.productItemId
    )
    if signal == nil then return nil, reason end
    local conflict = self.war:conflict_status(
        self.options.factionId,
        self.options.resourceId
    )
    local merchant_status = self.merchantRuntime:status()
    local record = self.merchantRuntime.records[
        self.options.factionId
    ]
    return {
        phase = self.state.phase,
        quantity = signal.resourceQuantities[
            self.options.resourceId
        ],
        supplyBand = signal.effectiveSupplyBand,
        direction = signal.direction,
        sellPrice = signal.exactSellPrice,
        stock = signal.exactStockCount,
        procurementPrice = signal.exactProcurementPrice,
        procurementQuota = signal.exactProcurementQuota,
        resourceLedgerRevision = signal.resourceLedgerRevision,
        conflictStatus = conflict and conflict.status or "none",
        supplierFactionId = conflict and conflict.supplierFactionId,
        merchantActiveCount = merchant_status.activeCount,
        merchantActor = record and record.actor or nil,
        merchantActorIdentity = record and tostring(record.actor)
            or "none",
        dynamicMarketRefreshCount =
            merchant_status.dynamicMarketRefreshCount,
        persistenceConfirmed = self.state.persistenceConfirmed,
    }
end

function FactionEconomyWarLiveTest:_refresh_native(before_actor)
    local refreshed = self.merchantRuntime:refresh_dynamic_market(
        self.options.factionId
    )
    local record = self.merchantRuntime.records[
        self.options.factionId
    ]
    local after_actor = record and record.actor or nil
    refreshed.sameMerchantActor = before_actor == after_actor
    refreshed.merchantActorIdentity = tostring(after_actor)
    if self.options.nativeMerchantRequired == true then
        if refreshed.ok ~= true or refreshed.active ~= true then
            return result(false, "native-merchant-refresh-required", {
                nativeRefresh = refreshed,
            })
        end
        if refreshed.sameMerchantActor ~= true then
            return result(false, "merchant-actor-was-replaced", {
                nativeRefresh = refreshed,
            })
        end
    end
    return result(true, "native-dynamic-market-refreshed", {
        nativeRefresh = refreshed,
    })
end

function FactionEconomyWarLiveTest:_operation(suffix)
    return self.options.runId .. "." .. suffix
end

function FactionEconomyWarLiveTest:_finish_step(reason, extra)
    self.state.stepCount = self.state.stepCount + 1
    local persisted, persist_reason = self:_persist()
    if not persisted then
        return result(false, "live-test-state-persist-failed", {
            detail = persist_reason,
        })
    end
    local snapshot, snapshot_error = self:_market_snapshot()
    if snapshot == nil then
        return result(false, "live-test-market-snapshot-failed", {
            detail = snapshot_error,
        })
    end
    extra = extra or {}
    extra.stepCount = self.state.stepCount
    extra.snapshot = snapshot
    extra.persistReason = persist_reason
    return result(true, reason, extra)
end

function FactionEconomyWarLiveTest:advance()
    local phase = self.state.phase
    local options = self.options
    if phase == "complete" then
        return self:_finish_step("economy-war-live-test-already-complete")
    end

    if phase == "awaiting_restart" then
        if self.state.warBootToken == self.bootToken then
            local snapshot = assert(self:_market_snapshot())
            return result(false, "game-restart-required", {
                snapshot = snapshot,
                stepCount = self.state.stepCount,
            })
        end
        local snapshot = assert(self:_market_snapshot())
        if snapshot.quantity
                ~= options.initialQuantity
                    - options.firstReduction
                    - options.secondReduction
            or snapshot.direction ~= "procure"
            or snapshot.conflictStatus ~= "war" then
            return result(false, "restart-persistence-check-failed", {
                snapshot = snapshot,
            })
        end
        self.state.phase = "restart_confirmed"
        self.state.persistenceConfirmed = true
        return self:_finish_step(
            "restart-persistence-confirmed"
        )
    end

    local record = self.merchantRuntime.records[options.factionId]
    local before_actor = record and record.actor or nil
    if options.nativeMerchantRequired == true
        and before_actor == nil then
        return result(false, "native-merchant-must-be-active")
    end

    if phase == "baseline" then
        local baseline = assert(self:_market_snapshot())
        if baseline.quantity ~= options.initialQuantity
            or baseline.direction ~= "sell" then
            return result(false, "live-test-baseline-drifted", {
                snapshot = baseline,
            })
        end
        self.state.phase = "limited_sale"
        local event = self.ledger:apply_event({
            operationId = self:_operation("limited-sale"),
            type = "consumption",
            factionId = options.factionId,
            resourceId = options.resourceId,
            amount = options.firstReduction,
        })
        if not event.ok then return result(false, event.reason) end
        local native = self:_refresh_native(before_actor)
        if not native.ok then return native end
        return self:_finish_step("limited-sale-applied", {
            resourceEvent = event,
            nativeRefresh = native.nativeRefresh,
        })
    elseif phase == "limited_sale" then
        self.state.phase = "trade_requested"
        local event = self.ledger:apply_event({
            operationId = self:_operation("scarcity"),
            type = "loss",
            factionId = options.factionId,
            resourceId = options.resourceId,
            amount = options.secondReduction,
        })
        if not event.ok then return result(false, event.reason) end
        local transition = self.war:advance_shortage(
            options.factionId,
            options.resourceId,
            self:_operation("trade-request"),
            0
        )
        if not transition.ok then
            return result(false, transition.reason)
        end
        local native = self:_refresh_native(before_actor)
        if not native.ok then return native end
        return self:_finish_step("procurement-and-trade-request-applied", {
            resourceEvent = event,
            warTransition = transition,
            nativeRefresh = native.nativeRefresh,
        })
    elseif phase == "trade_requested" then
        self.state.phase = "threat"
        local transition = self.war:advance_shortage(
            options.factionId,
            options.resourceId,
            self:_operation("threat"),
            3
        )
        if not transition.ok then
            return result(false, transition.reason)
        end
        return self:_finish_step("shortage-threat-issued", {
            warTransition = transition,
        })
    elseif phase == "threat" then
        self.state.phase = "awaiting_restart"
        self.state.warBootToken = self.bootToken
        local transition = self.war:advance_shortage(
            options.factionId,
            options.resourceId,
            self:_operation("war"),
            6
        )
        if not transition.ok then
            return result(false, transition.reason)
        end
        return self:_finish_step("shortage-war-declared-restart-required", {
            warTransition = transition,
            restartRequired = true,
        })
    elseif phase == "restart_confirmed" then
        self.state.phase = "ceasefire"
        local restore_amount = options.firstReduction
            + options.secondReduction
        local event = self.ledger:apply_event({
            operationId = self:_operation("supply-restored"),
            type = "import",
            factionId = options.factionId,
            resourceId = options.resourceId,
            amount = restore_amount,
        })
        if not event.ok then return result(false, event.reason) end
        local transition = self.war:advance_shortage(
            options.factionId,
            options.resourceId,
            self:_operation("ceasefire"),
            7
        )
        if not transition.ok then
            return result(false, transition.reason)
        end
        local native = self:_refresh_native(before_actor)
        if not native.ok then return native end
        return self:_finish_step("supply-restored-ceasefire", {
            resourceEvent = event,
            warTransition = transition,
            nativeRefresh = native.nativeRefresh,
        })
    elseif phase == "ceasefire" then
        self.state.phase = "complete"
        local transition = self.war:advance_shortage(
            options.factionId,
            options.resourceId,
            self:_operation("stable"),
            10
        )
        if not transition.ok then
            return result(false, transition.reason)
        end
        return self:_finish_step("economy-war-live-test-complete", {
            warTransition = transition,
        })
    end
    return result(false, "unknown-live-test-phase")
end

function FactionEconomyWarLiveTest:status()
    local snapshot = self:_market_snapshot()
    return {
        apiVersion = self.version,
        runId = self.state.runId,
        phase = self.state.phase,
        stepCount = self.state.stepCount,
        persistenceConfirmed = self.state.persistenceConfirmed,
        snapshot = snapshot,
    }
end

return FactionEconomyWarLiveTest
