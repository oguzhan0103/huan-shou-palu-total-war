local ContentPackRegistry = {}

local API_VERSION = "1.0.0"
local SCHEMA_VERSION = "1.0.0"

local function copy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] ~= nil then
        return seen[value]
    end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do
        result[copy(key, seen)] = copy(item, seen)
    end
    return result
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function require_non_empty_string(value, label)
    assert(type(value) == "string" and value ~= "", label .. " is required")
    assert(not string.find(value, "%s"), label .. " cannot contain whitespace")
    return value
end

local function sorted_keys(values)
    local keys = {}
    for key, _ in pairs(values) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        if type(left) == type(right) then
            return left < right
        end
        return type(left) < type(right)
    end)
    return keys
end

local function split(value, separator)
    local values = {}
    local start_index = 1
    while true do
        local next_index = string.find(value, separator, start_index, true)
        if next_index == nil then
            values[#values + 1] = string.sub(value, start_index)
            return values
        end
        values[#values + 1] = string.sub(value, start_index, next_index - 1)
        start_index = next_index + #separator
    end
end

local function validate_namespaced_id(value, label)
    require_non_empty_string(value, label)
    local parts = split(value, ".")
    assert(#parts >= 2, label .. " must contain a namespace")
    for _, part in ipairs(parts) do
        assert(
            string.match(part, "^[a-z][a-z0-9_-]*$") ~= nil,
            label .. " contains an invalid namespace segment"
        )
    end
    return value
end

local function id_belongs_to_namespace(value, namespace)
    return value == namespace
        or string.sub(value, 1, #namespace + 1) == namespace .. "."
end

local function parse_semver(value, label)
    require_non_empty_string(value, label)
    local core, suffix = string.match(value, "^([0-9]+%.[0-9]+%.[0-9]+)(.*)$")
    assert(core ~= nil, label .. " must use semantic versioning")
    local core_parts = split(core, ".")
    for _, part in ipairs(core_parts) do
        assert(part == "0" or string.sub(part, 1, 1) ~= "0", label .. " has a leading zero")
    end

    local prerelease = nil
    local build = nil
    if suffix ~= "" then
        if string.sub(suffix, 1, 1) == "-" then
            local plus = string.find(suffix, "+", 2, true)
            if plus == nil then
                prerelease = string.sub(suffix, 2)
            else
                prerelease = string.sub(suffix, 2, plus - 1)
                build = string.sub(suffix, plus + 1)
            end
        elseif string.sub(suffix, 1, 1) == "+" then
            build = string.sub(suffix, 2)
        else
            error(label .. " has an invalid semantic-version suffix")
        end
    end

    local function validate_suffix(part, suffix_label)
        if part == nil then
            return
        end
        assert(part ~= "", suffix_label .. " cannot be empty")
        assert(
            string.match(part, "^[0-9A-Za-z.-]+$") ~= nil
                and not string.find(part, "..", 1, true),
            suffix_label .. " contains an invalid identifier"
        )
    end
    validate_suffix(prerelease, label .. " prerelease")
    validate_suffix(build, label .. " build metadata")

    return {
        major = tonumber(core_parts[1]),
        minor = tonumber(core_parts[2]),
        patch = tonumber(core_parts[3]),
        prerelease = prerelease,
        raw = value,
    }
end

local function compare_semver(left, right)
    for _, key in ipairs({ "major", "minor", "patch" }) do
        if left[key] < right[key] then
            return -1
        elseif left[key] > right[key] then
            return 1
        end
    end
    if left.prerelease == nil and right.prerelease ~= nil then
        return 1
    elseif left.prerelease ~= nil and right.prerelease == nil then
        return -1
    elseif left.prerelease == right.prerelease then
        return 0
    end
    if left.prerelease < right.prerelease then
        return -1
    end
    return 1
end

local function assert_only_fields(value, allowed, label)
    assert(type(value) == "table", label .. " must be a table")
    for key, _ in pairs(value) do
        assert(type(key) == "string" and allowed[key] == true, label .. " contains unsupported field: " .. tostring(key))
    end
end

local function normalize_string_array(values, label, validator)
    assert(values == nil or type(values) == "table", label .. " must be an array")
    local normalized = {}
    local seen = {}
    for index, value in ipairs(values or {}) do
        assert(type(index) == "number", label .. " must be an array")
        validator(value, label .. " entry")
        assert(seen[value] == nil, label .. " contains a duplicate: " .. value)
        seen[value] = true
        normalized[#normalized + 1] = value
    end
    table.sort(normalized)
    return normalized, seen
end

local function stable_encode(value)
    local value_type = type(value)
    if value_type == "nil" then
        return "n"
    elseif value_type == "boolean" then
        return value and "b1" or "b0"
    elseif value_type == "number" then
        return "d" .. tostring(value)
    elseif value_type == "string" then
        return "s" .. #value .. ":" .. value
    end
    assert(value_type == "table", "unsupported manifest value")
    local parts = { "t{" }
    for _, key in ipairs(sorted_keys(value)) do
        parts[#parts + 1] = stable_encode(key)
        parts[#parts + 1] = stable_encode(value[key])
    end
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

local MANIFEST_FIELDS = {
    schemaVersion = true,
    contentPackId = true,
    contentVersion = true,
    namespace = true,
    localizationNamespace = true,
    dependencies = true,
    conflicts = true,
    loadAfter = true,
    capabilities = true,
    localizationKeys = true,
}

local DEPENDENCY_FIELDS = {
    contentPackId = true,
    minimumVersion = true,
}

local function normalize_manifest(manifest)
    assert_only_fields(manifest, MANIFEST_FIELDS, "content-pack manifest")
    assert(manifest.schemaVersion == SCHEMA_VERSION, "unsupported content-pack manifest schema")
    local pack_id = validate_namespaced_id(manifest.contentPackId, "content-pack ID")
    local namespace = validate_namespaced_id(manifest.namespace, "content-pack namespace")
    assert(id_belongs_to_namespace(pack_id, namespace), "content-pack ID must belong to its namespace")
    local content_version = parse_semver(manifest.contentVersion, "content-pack version")
    local localization_namespace = validate_namespaced_id(
        manifest.localizationNamespace,
        "content-pack localization namespace"
    )
    assert(
        id_belongs_to_namespace(localization_namespace, namespace),
        "localization namespace must belong to the content-pack namespace"
    )

    local dependencies = {}
    local dependency_set = {}
    assert(manifest.dependencies == nil or type(manifest.dependencies) == "table", "content-pack dependencies must be an array")
    for _, dependency in ipairs(manifest.dependencies or {}) do
        assert_only_fields(dependency, DEPENDENCY_FIELDS, "content-pack dependency")
        local dependency_id = validate_namespaced_id(dependency.contentPackId, "dependency content-pack ID")
        assert(dependency_id ~= pack_id, "content pack cannot depend on itself")
        assert(dependency_set[dependency_id] == nil, "duplicate content-pack dependency: " .. dependency_id)
        dependency_set[dependency_id] = true
        dependencies[#dependencies + 1] = {
            contentPackId = dependency_id,
            minimumVersion = parse_semver(dependency.minimumVersion, "dependency minimum version").raw,
        }
    end
    table.sort(dependencies, function(left, right)
        return left.contentPackId < right.contentPackId
    end)

    local conflicts, conflict_set = normalize_string_array(
        manifest.conflicts,
        "content-pack conflicts",
        validate_namespaced_id
    )
    assert(conflict_set[pack_id] == nil, "content pack cannot conflict with itself")
    local load_after, load_after_set = normalize_string_array(
        manifest.loadAfter,
        "content-pack loadAfter",
        validate_namespaced_id
    )
    assert(load_after_set[pack_id] == nil, "content pack cannot load after itself")

    local capabilities, capability_set = normalize_string_array(
        manifest.capabilities,
        "content-pack capabilities",
        validate_namespaced_id
    )
    assert(#capabilities > 0, "content pack must declare at least one capability")

    local localization_keys, localization_key_set = normalize_string_array(
        manifest.localizationKeys,
        "content-pack localization keys",
        validate_namespaced_id
    )
    for _, key in ipairs(localization_keys) do
        assert(
            id_belongs_to_namespace(key, localization_namespace),
            "localization key must belong to the declared localization namespace"
        )
    end

    local normalized = {
        schemaVersion = SCHEMA_VERSION,
        contentPackId = pack_id,
        contentVersion = content_version.raw,
        namespace = namespace,
        localizationNamespace = localization_namespace,
        dependencies = dependencies,
        conflicts = conflicts,
        loadAfter = load_after,
        capabilities = capabilities,
        localizationKeys = localization_keys,
    }
    return normalized, {
        dependencySet = dependency_set,
        conflictSet = conflict_set,
        loadAfterSet = load_after_set,
        capabilitySet = capability_set,
        localizationKeySet = localization_key_set,
        fingerprint = stable_encode(normalized),
    }
end

local function make_public_record(record)
    if record == nil then
        return nil
    end
    local value = copy(record.manifest)
    value.loadIndex = record.loadIndex
    return value
end

function ContentPackRegistry.create(options)
    options = options or {}
    local core_version = parse_semver(options.coreVersion or API_VERSION, "content-pack core version")
    return setmetatable({
        version = API_VERSION,
        coreVersion = core_version.raw,
        packs = {},
        loadOrder = {},
        capabilities = {},
        capabilitiesByPack = {},
        capabilitiesPolicy = {
            declarationsRequired = true,
            codeExecutionFromManifest = false,
            inlineNarrativeText = false,
        },
    }, { __index = ContentPackRegistry })
end

function ContentPackRegistry:register(manifest)
    local outcome = self:register_batch({ manifest })
    if outcome.ok and outcome.registeredCount == 0 then
        outcome.reason = "content-pack-already-registered"
    elseif outcome.ok then
        outcome.reason = "content-pack-registered"
    end
    return outcome
end

function ContentPackRegistry:register_batch(manifests)
    if type(manifests) ~= "table" or #manifests == 0 then
        return result(false, "content-pack-batch-required")
    end

    local ok, normalized_or_error = pcall(function()
        local staged = {}
        local staged_by_id = {}
        for _, manifest in ipairs(manifests) do
            local normalized, metadata = normalize_manifest(manifest)
            assert(staged_by_id[normalized.contentPackId] == nil, "duplicate content-pack ID in batch: " .. normalized.contentPackId)
            local record = {
                manifest = normalized,
                metadata = metadata,
            }
            staged[#staged + 1] = record
            staged_by_id[normalized.contentPackId] = record
        end
        return {
            staged = staged,
            stagedById = staged_by_id,
        }
    end)
    if not ok then
        return result(false, "invalid-content-pack-manifest", {
            validationError = tostring(normalized_or_error),
        })
    end

    local staged = normalized_or_error.staged
    local staged_by_id = normalized_or_error.stagedById
    local pending = {}
    local combined = {}
    for pack_id, record in pairs(self.packs) do
        combined[pack_id] = record
    end
    for _, record in ipairs(staged) do
        local pack_id = record.manifest.contentPackId
        local existing = self.packs[pack_id]
        if existing ~= nil then
            if existing.metadata.fingerprint ~= record.metadata.fingerprint then
                return result(false, "content-pack-migration-required", {
                    contentPackId = pack_id,
                    currentVersion = existing.manifest.contentVersion,
                    requestedVersion = record.manifest.contentVersion,
                })
            end
        else
            pending[pack_id] = record
            combined[pack_id] = record
        end
    end

    for pack_id, record in pairs(combined) do
        for _, conflict_id in ipairs(record.manifest.conflicts) do
            if combined[conflict_id] ~= nil then
                return result(false, "content-pack-conflict", {
                    contentPackId = pack_id,
                    conflictingContentPackId = conflict_id,
                })
            end
        end
    end

    for pack_id, record in pairs(pending) do
        for _, dependency in ipairs(record.manifest.dependencies) do
            local target = combined[dependency.contentPackId]
            if target == nil then
                return result(false, "content-pack-dependency-missing", {
                    contentPackId = pack_id,
                    dependencyContentPackId = dependency.contentPackId,
                })
            end
            local actual = parse_semver(target.manifest.contentVersion, "installed dependency version")
            local minimum = parse_semver(dependency.minimumVersion, "dependency minimum version")
            if compare_semver(actual, minimum) < 0 then
                return result(false, "content-pack-dependency-version-unsatisfied", {
                    contentPackId = pack_id,
                    dependencyContentPackId = dependency.contentPackId,
                    installedVersion = actual.raw,
                    minimumVersion = minimum.raw,
                })
            end
        end
    end

    local indegree = {}
    local outgoing = {}
    for pack_id, _ in pairs(pending) do
        indegree[pack_id] = 0
        outgoing[pack_id] = {}
    end
    local function add_edge(before_id, after_id)
        if pending[before_id] == nil or pending[after_id] == nil then
            return
        end
        if outgoing[before_id][after_id] == nil then
            outgoing[before_id][after_id] = true
            indegree[after_id] = indegree[after_id] + 1
        end
    end
    for pack_id, record in pairs(pending) do
        for _, dependency in ipairs(record.manifest.dependencies) do
            add_edge(dependency.contentPackId, pack_id)
        end
        for _, before_id in ipairs(record.manifest.loadAfter) do
            add_edge(before_id, pack_id)
        end
    end

    local order = {}
    while #order < #sorted_keys(pending) do
        local ready = {}
        for pack_id, degree in pairs(indegree) do
            if degree == 0 then
                ready[#ready + 1] = pack_id
            end
        end
        table.sort(ready)
        if #ready == 0 then
            return result(false, "content-pack-load-order-cycle")
        end
        local selected = ready[1]
        order[#order + 1] = selected
        indegree[selected] = nil
        for target_id, _ in pairs(outgoing[selected]) do
            indegree[target_id] = indegree[target_id] - 1
        end
    end

    for _, pack_id in ipairs(order) do
        local record = pending[pack_id]
        local load_index = #self.loadOrder + 1
        record.loadIndex = load_index
        self.packs[pack_id] = record
        self.loadOrder[load_index] = pack_id
        self.capabilitiesByPack[pack_id] = copy(record.metadata.capabilitySet)
        for capability, _ in pairs(record.metadata.capabilitySet) do
            self.capabilities[capability] = self.capabilities[capability] or {}
            self.capabilities[capability][pack_id] = true
        end
    end

    return result(true, "content-pack-batch-registered", {
        requestedCount = #manifests,
        registeredCount = #order,
        skippedCount = #manifests - #order,
        loadOrder = copy(order),
    })
end

function ContentPackRegistry:manifest(content_pack_id)
    require_non_empty_string(content_pack_id, "content-pack ID")
    return make_public_record(self.packs[content_pack_id])
end

function ContentPackRegistry:has_capability(content_pack_id, capability)
    require_non_empty_string(content_pack_id, "content-pack ID")
    require_non_empty_string(capability, "content-pack capability")
    local values = self.capabilitiesByPack[content_pack_id]
    return values ~= nil and values[capability] == true
end

function ContentPackRegistry:owns_localization_key(content_pack_id, localization_key)
    require_non_empty_string(content_pack_id, "content-pack ID")
    require_non_empty_string(localization_key, "localization key")
    local record = self.packs[content_pack_id]
    return record ~= nil
        and record.metadata.localizationKeySet[localization_key] == true
end

function ContentPackRegistry:providers(capability)
    require_non_empty_string(capability, "content-pack capability")
    local providers = sorted_keys(self.capabilities[capability] or {})
    return providers
end

function ContentPackRegistry:status(content_pack_id)
    if content_pack_id ~= nil then
        require_non_empty_string(content_pack_id, "content-pack ID")
        local record = self.packs[content_pack_id]
        if record == nil then
            return nil
        end
        return {
            apiVersion = self.version,
            coreVersion = self.coreVersion,
            manifest = make_public_record(record),
            capabilityCount = #record.manifest.capabilities,
            localizationKeyCount = #record.manifest.localizationKeys,
        }
    end
    return {
        apiVersion = self.version,
        coreVersion = self.coreVersion,
        registeredPackCount = #self.loadOrder,
        loadOrder = copy(self.loadOrder),
        atomicBatchRegistration = true,
        dependencyValidation = true,
        conflictValidation = true,
        localizationKeysOnly = true,
        manifestMayExecuteCode = false,
    }
end

return ContentPackRegistry
