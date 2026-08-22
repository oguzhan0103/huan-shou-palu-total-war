local ContentModuleLoader = {}

local API_VERSION = "1.0.0"

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local output = {}
    seen[value] = output
    for key, child in pairs(value) do
        output[copy(key, seen)] = copy(child, seen)
    end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function valid_module_name(value)
    return type(value) == "string"
        and value ~= ""
        and #value <= 256
        and string.match(value, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") ~= nil
        and not string.find(value, "..", 1, true)
end

function ContentModuleLoader.create(
    content_runtime,
    configuration,
    context,
    options
)
    assert(type(content_runtime) == "table"
        and type(content_runtime.register) == "function",
        "content runtime is required")
    configuration = configuration or {}
    assert(type(configuration.enabled or false) == "boolean",
        "content-module enabled flag must be boolean")
    assert(type(configuration.modules or {}) == "table",
        "content-module list must be an array")
    options = options or {}
    assert(options.logger == nil or type(options.logger) == "function",
        "content-module logger must be a function")
    return setmetatable({
        version = API_VERSION,
        contentRuntime = content_runtime,
        enabled = configuration.enabled == true,
        moduleNames = copy(configuration.modules or {}),
        context = context or {},
        logger = options.logger,
        loaded = false,
        records = {},
        activators = {},
        reactivationCount = 0,
        reactivationFailureCount = 0,
        lastReactivationReason = nil,
        capabilities = {
            internalRequireOnly = true,
            crossModGlobalsRequired = false,
            manifestMayExecuteCode = false,
            configuredTrustedActivation = true,
            baseStoryContentIncluded = false,
        },
    }, { __index = ContentModuleLoader })
end

function ContentModuleLoader:_log(message)
    if self.logger ~= nil then
        pcall(self.logger, message)
    end
end

function ContentModuleLoader:load()
    if self.loaded then
        return result(true, "content-modules-already-loaded", self:status())
    end
    self.loaded = true
    if not self.enabled then
        return result(true, "content-module-loader-disabled", self:status())
    end

    local seen = {}
    for index, module_name in ipairs(self.moduleNames) do
        local record = {
            index = index,
            moduleName = tostring(module_name),
            registered = false,
            activated = false,
        }
        self.records[#self.records + 1] = record
        if not valid_module_name(module_name) then
            record.reason = "invalid-content-module-name"
        elseif seen[module_name] then
            record.reason = "duplicate-content-module-name"
        else
            seen[module_name] = true
            local required, module_or_error = pcall(require, module_name)
            if not required then
                record.reason = "content-module-require-failed"
                record.error = tostring(module_or_error)
            elseif type(module_or_error) ~= "table" then
                record.reason = "content-module-invalid-export"
            else
                local bundle = module_or_error.bundle or module_or_error
                local registered = self.contentRuntime:register(bundle)
                record.registration = copy(registered)
                record.registered = registered.ok == true
                record.contentPackId = registered.contentPackId
                    or (bundle.manifest and bundle.manifest.contentPackId)
                if not record.registered then
                    record.reason = "content-module-registration-failed"
                elseif type(module_or_error.activate) == "function" then
                    self.activators[module_name] = {
                        moduleName = module_name,
                        activate = module_or_error.activate,
                        registration = copy(registered),
                    }
                    local activated, activation_or_error = pcall(
                        module_or_error.activate,
                        self.context,
                        copy(registered)
                    )
                    if not activated then
                        record.reason = "content-module-activation-failed"
                        record.error = tostring(activation_or_error)
                    elseif type(activation_or_error) == "table"
                        and activation_or_error.ok == false then
                        record.reason = "content-module-activation-rejected"
                        record.activation = copy(activation_or_error)
                    else
                        record.activated = true
                        record.reason = "content-module-registered-and-activated"
                        record.activation = copy(activation_or_error)
                    end
                else
                    record.activated = true
                    record.reason = "content-module-registered"
                end
            end
        end
        self:_log(string.format(
            "CONTENT_MODULE module=%s registered=%s activated=%s reason=%s pack=%s registrationReason=%s registrationError=%s",
            tostring(record.moduleName),
            tostring(record.registered),
            tostring(record.activated),
            tostring(record.reason),
            tostring(record.contentPackId or "none"),
            tostring(record.registration and record.registration.reason
                or "none"),
            tostring(record.registration
                and (record.registration.validationError
                    or record.registration.error)
                or "none")
        ))
    end

    local status = self:status()
    return result(status.failedCount == 0,
        status.failedCount == 0
            and "content-modules-loaded"
            or "content-module-load-failed",
        status)
end

-- Native providers and their UObject-bound target routes are generation
-- scoped.  A map unload intentionally clears them; the registered data bundle
-- remains valid, so re-run only the trusted activation function after the next
-- world loads.  This never registers story/content data a second time.
function ContentModuleLoader:reactivate(reason)
    if not self.loaded then
        return result(false, "content-modules-not-loaded")
    end
    if not self.enabled then
        return result(true, "content-module-loader-disabled", self:status())
    end
    self.reactivationCount = self.reactivationCount + 1
    self.lastReactivationReason = tostring(reason or "world-rebind")
    local failed = 0
    for _, record in ipairs(self.records) do
        local activator = self.activators[record.moduleName]
        if record.registered and activator ~= nil then
            local activated, activation_or_error = pcall(
                activator.activate,
                self.context,
                copy(activator.registration)
            )
            record.reactivationCount =
                (record.reactivationCount or 0) + 1
            if not activated then
                record.activated = false
                record.reason = "content-module-reactivation-failed"
                record.error = tostring(activation_or_error)
                failed = failed + 1
            elseif type(activation_or_error) == "table"
                and activation_or_error.ok == false then
                record.activated = false
                record.reason = "content-module-reactivation-rejected"
                record.activation = copy(activation_or_error)
                failed = failed + 1
            else
                record.activated = true
                record.reason = "content-module-reactivated"
                record.error = nil
                record.activation = copy(activation_or_error)
            end
            self:_log(string.format(
                "CONTENT_MODULE_REACTIVATE module=%s activated=%s reason=%s worldReason=%s",
                tostring(record.moduleName),
                tostring(record.activated),
                tostring(record.reason),
                self.lastReactivationReason
            ))
        end
    end
    self.reactivationFailureCount =
        self.reactivationFailureCount + failed
    local status = self:status()
    return result(failed == 0,
        failed == 0 and "content-modules-reactivated"
            or "content-module-reactivation-failed",
        status)
end

function ContentModuleLoader:status()
    local registered_count = 0
    local activated_count = 0
    local failed_count = 0
    for _, record in ipairs(self.records) do
        if record.registered then registered_count = registered_count + 1 end
        if record.activated then activated_count = activated_count + 1 end
        if not record.registered or not record.activated then
            failed_count = failed_count + 1
        end
    end
    return {
        apiVersion = self.version,
        enabled = self.enabled,
        loadAttempted = self.loaded,
        configuredModuleCount = #self.moduleNames,
        registeredCount = registered_count,
        activatedCount = activated_count,
        failedCount = failed_count,
        reactivationCount = self.reactivationCount,
        reactivationFailureCount = self.reactivationFailureCount,
        lastReactivationReason = self.lastReactivationReason,
        records = copy(self.records),
        internalRequireOnly = true,
        crossModGlobalsRequired = false,
        baseStoryContentIncluded = false,
    }
end

return ContentModuleLoader
