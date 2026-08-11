local LocalizationRuntime = {}

local API_VERSION = "1.0.0"

local function copy(value)
    if type(value) ~= "table" then return value end
    local output = {}
    for key, child in pairs(value) do
        output[copy(key)] = copy(child)
    end
    return output
end

local function result(ok, reason, extra)
    local value = extra or {}
    value.ok = ok
    value.reason = reason
    return value
end

local function non_empty(value, label, maximum)
    assert(type(value) == "string" and value ~= "", label .. " is required")
    assert(maximum == nil or #value <= maximum, label .. " is too long")
    return value
end

local function stable_encode(value)
    if type(value) ~= "table" then
        return type(value) .. ":" .. tostring(value)
    end
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = { "{" }
    for _, key in ipairs(keys) do
        parts[#parts + 1] = stable_encode(key)
        parts[#parts + 1] = stable_encode(value[key])
    end
    parts[#parts + 1] = "}"
    return table.concat(parts, "|")
end

local function validate(instance, content_pack_id, catalogs)
    non_empty(content_pack_id, "localization content-pack ID", 256)
    assert(
        instance.contentPackRegistry:manifest(content_pack_id) ~= nil,
        "localization content pack is not registered"
    )
    assert(type(catalogs) == "table", "localization catalogs are required")
    local normalized = {}
    local locale_count = 0
    local message_count = 0
    for locale, messages in pairs(catalogs) do
        non_empty(locale, "localization locale", 32)
        assert(not string.find(locale, "%s"), "localization locale cannot contain whitespace")
        assert(type(messages) == "table", "localization locale catalog must be a table")
        normalized[locale] = {}
        locale_count = locale_count + 1
        for key, message in pairs(messages) do
            non_empty(key, "localization key", 512)
            non_empty(message, "localized message", 16384)
            assert(
                instance.contentPackRegistry:owns_localization_key(
                    content_pack_id,
                    key
                ),
                "localization key is not owned by content pack: " .. key
            )
            normalized[locale][key] = message
            message_count = message_count + 1
        end
    end
    assert(locale_count > 0, "at least one localization locale is required")
    assert(message_count > 0, "at least one localized message is required")
    return normalized, locale_count, message_count
end

function LocalizationRuntime.create(content_pack_registry, options)
    assert(type(content_pack_registry) == "table", "content-pack registry is required")
    options = options or {}
    return setmetatable({
        version = API_VERSION,
        contentPackRegistry = content_pack_registry,
        fallbackLocale = options.fallbackLocale or "zh-CN",
        packs = {},
        catalogs = {},
        owners = {},
    }, { __index = LocalizationRuntime })
end

function LocalizationRuntime:register_pack(content_pack_id, catalogs)
    local ok, normalized, locale_count, message_count = pcall(
        validate,
        self,
        content_pack_id,
        catalogs
    )
    if not ok then
        return result(false, "invalid-localization-pack", {
            validationError = tostring(normalized),
        })
    end
    local fingerprint = stable_encode(normalized)
    local existing = self.packs[content_pack_id]
    if existing ~= nil then
        if existing.fingerprint ~= fingerprint then
            return result(false, "localization-pack-migration-required", {
                contentPackId = content_pack_id,
            })
        end
        return result(true, "localization-pack-already-registered", {
            contentPackId = content_pack_id,
            localeCount = existing.localeCount,
            messageCount = existing.messageCount,
        })
    end
    for locale, messages in pairs(normalized) do
        self.owners[locale] = self.owners[locale] or {}
        for key in pairs(messages) do
            local owner = self.owners[locale][key]
            if owner ~= nil and owner ~= content_pack_id then
                return result(false, "localization-key-conflict", {
                    contentPackId = content_pack_id,
                    conflictingContentPackId = owner,
                    locale = locale,
                    localizationKey = key,
                })
            end
        end
    end
    for locale, messages in pairs(normalized) do
        self.catalogs[locale] = self.catalogs[locale] or {}
        self.owners[locale] = self.owners[locale] or {}
        for key, message in pairs(messages) do
            self.catalogs[locale][key] = message
            self.owners[locale][key] = content_pack_id
        end
    end
    self.packs[content_pack_id] = {
        contentPackId = content_pack_id,
        catalogs = copy(normalized),
        localeCount = locale_count,
        messageCount = message_count,
        fingerprint = fingerprint,
    }
    return result(true, "localization-pack-registered", {
        contentPackId = content_pack_id,
        localeCount = locale_count,
        messageCount = message_count,
    })
end

function LocalizationRuntime:resolve(locale, key)
    if type(key) ~= "string" or key == "" then return nil end
    locale = type(locale) == "string" and locale or self.fallbackLocale
    local exact = self.catalogs[locale]
    if exact ~= nil and exact[key] ~= nil then return exact[key] end
    local fallback = self.catalogs[self.fallbackLocale]
    return fallback and fallback[key] or nil
end

function LocalizationRuntime:export_snapshot()
    local output = {}
    for pack_id, record in pairs(self.packs) do
        output[pack_id] = copy(record.catalogs)
    end
    return output
end

function LocalizationRuntime:status()
    local pack_count = 0
    local locale_set = {}
    local message_count = 0
    for _, record in pairs(self.packs) do
        pack_count = pack_count + 1
        message_count = message_count + record.messageCount
        for locale in pairs(record.catalogs) do locale_set[locale] = true end
    end
    local locale_count = 0
    for _ in pairs(locale_set) do locale_count = locale_count + 1 end
    return {
        apiVersion = self.version,
        registeredPackCount = pack_count,
        localeCount = locale_count,
        messageCount = message_count,
        fallbackLocale = self.fallbackLocale,
        storyContentIncludedByBase = false,
    }
end

return LocalizationRuntime
