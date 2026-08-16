local Json = require("pwft.json")

local CompanionLedger = {}

local SCHEMA_VERSION = "1.0.0"

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[copy(key)] = copy(item)
    end
    return result
end

local function require_text(value, name)
    assert(
        type(value) == "string" and value ~= "",
        name .. " must be a non-empty string"
    )
    return value
end

local function normalize_root(root_path)
    require_text(root_path, "companion ledger root")
    return (string.gsub(root_path, "[/\\]+$", ""))
end

local function join(root_path, leaf)
    local separator = "\\"
    if string.find(root_path, "/", 1, true) ~= nil
        and string.find(root_path, "\\", 1, true) == nil then
        separator = "/"
    end
    return root_path .. separator .. leaf
end

local function default_filesystem()
    return {
        write = function(path, content)
            local handle, open_error = io.open(path, "wb")
            if handle == nil then
                return false, open_error
            end
            local ok, write_error = handle:write(content)
            if ok then
                handle:flush()
            end
            handle:close()
            if not ok then
                return false, write_error
            end
            return true
        end,
        append = function(path, content)
            local handle, open_error = io.open(path, "ab")
            if handle == nil then
                return false, open_error
            end
            local ok, write_error = handle:write(content)
            if ok then
                handle:flush()
            end
            handle:close()
            if not ok then
                return false, write_error
            end
            return true
        end,
        exists = function(path)
            local handle = io.open(path, "rb")
            if handle == nil then
                return false
            end
            handle:close()
            return true
        end,
        rename = function(source, target)
            local ok, rename_error = os.rename(source, target)
            if ok == nil then
                return false, rename_error
            end
            return true
        end,
        remove = function(path)
            local ok, remove_error = os.remove(path)
            if ok == nil then
                return false, remove_error
            end
            return true
        end,
    }
end

local function safe_call(callback, ...)
    local ok, first, second = pcall(callback, ...)
    if not ok then
        return false, tostring(first)
    end
    if first == false or first == nil then
        return false, tostring(second or "operation-failed")
    end
    return true, first
end

local function safe_copy(value)
    local ok, result = pcall(copy, value)
    if not ok then
        return false, tostring(result)
    end
    return true, result
end

local function atomic_write(instance, path, value)
    local temporary_path = path .. ".tmp"
    local backup_path = path .. ".bak"
    local encode_ok, encoded = pcall(Json.encode, value)
    if not encode_ok then
        local field = "root"
        if type(value) == "table" then
            local inspect_ok = pcall(function()
                for key, item in pairs(value) do
                    local item_ok = pcall(Json.encode, item)
                    if not item_ok then
                        field = tostring(key)
                        break
                    end
                end
            end)
            if not inspect_ok then
                field = "root-diagnostic"
            end
        end
        return false, "encode-failed:" .. field .. ":" .. tostring(encoded)
    end
    local write_ok, write_error = safe_call(
        instance.filesystem.write,
        temporary_path,
        encoded
    )
    if not write_ok then
        return false, "temporary-write-failed:" .. write_error
    end
    if not instance.filesystem.exists(path)
        and instance.filesystem.exists(backup_path) then
        local recover_ok, recover_error = safe_call(
            instance.filesystem.rename,
            backup_path,
            path
        )
        if not recover_ok then
            pcall(instance.filesystem.remove, temporary_path)
            return false, "previous-recovery-failed:" .. recover_error
        end
    end
    local had_previous = instance.filesystem.exists(path)
    if had_previous and instance.filesystem.exists(backup_path) then
        local remove_ok, remove_error = safe_call(
            instance.filesystem.remove,
            backup_path
        )
        if not remove_ok then
            pcall(instance.filesystem.remove, temporary_path)
            return false, "stale-backup-remove-failed:" .. remove_error
        end
    end
    if had_previous then
        local rotate_ok, rotate_error = safe_call(
            instance.filesystem.rename,
            path,
            backup_path
        )
        if not rotate_ok then
            pcall(instance.filesystem.remove, temporary_path)
            return false, "previous-rotate-failed:" .. rotate_error
        end
    end
    local rename_ok, rename_error = safe_call(
        instance.filesystem.rename,
        temporary_path,
        path
    )
    if not rename_ok then
        pcall(instance.filesystem.remove, temporary_path)
        if had_previous then
            local restore_ok, restore_error = safe_call(
                instance.filesystem.rename,
                backup_path,
                path
            )
            if not restore_ok then
                return false,
                    "temporary-promote-failed:" .. rename_error
                        .. ";previous-restore-failed:" .. restore_error
            end
        end
        return false, "temporary-promote-failed:" .. rename_error
    end
    return true
end

function CompanionLedger.create(config, filesystem)
    assert(type(config) == "table", "companion ledger configuration is required")
    local instance = {
        enabled = config.enabled == true,
        rootPath = normalize_root(config.rootPath),
        reason = config.reason,
        filesystem = filesystem or default_filesystem(),
        now = config.now or os.time,
        active = false,
        identity = nil,
        statePath = nil,
        eventsPath = nil,
        activePath = nil,
        sequence = 0,
        lastError = nil,
    }
    for _, name in ipairs({
        "write",
        "append",
        "exists",
        "rename",
        "remove",
    }) do
        assert(
            type(instance.filesystem[name]) == "function",
            "companion ledger filesystem is missing " .. name
        )
    end
    assert(type(instance.now) == "function", "companion ledger clock is required")
    instance.activePath = join(
        instance.rootPath,
        "pwft-companion-active-v1.json"
    )
    return setmetatable(instance, { __index = CompanionLedger })
end

function CompanionLedger:activate(identity)
    if not self.enabled then
        return false, self.reason or "disabled-by-configuration"
    end
    assert(type(identity) == "table", "companion identity is required")
    local profile_key = require_text(identity.profileKey, "companion profile key")
    assert(
        string.find(profile_key, "^[A-Za-z0-9._%-]+$") ~= nil,
        "companion profile key contains unsafe characters"
    )
    self.identity = copy(identity)
    self.statePath = join(
        self.rootPath,
        "pwft-companion-state-v1-" .. profile_key .. ".json"
    )
    self.eventsPath = join(
        self.rootPath,
        "pwft-companion-events-v1-" .. profile_key .. ".jsonl"
    )
    self.active = true
    local ok, write_error = atomic_write(self, self.activePath, {
        schemaVersion = SCHEMA_VERSION,
        profileKey = profile_key,
        worldDirectory = identity.worldDirectory,
        playerUid = identity.playerUid,
        stateFile = string.match(self.statePath, "[^/\\]+$"),
        eventsFile = string.match(self.eventsPath, "[^/\\]+$"),
        activatedAtEpoch = self.now(),
    })
    if not ok then
        self.active = false
        self.lastError = write_error
        return false, write_error
    end
    self:record({
        type = "profile-activated",
        profileKey = profile_key,
    })
    return true, "activated"
end

function CompanionLedger:record(event)
    if not self.active then
        return false, "profile-not-active"
    end
    assert(type(event) == "table", "companion event must be a table")
    local copied, envelope_or_error = safe_copy(event)
    if not copied then
        self.lastError = "event-copy-failed:" .. envelope_or_error
        return false, self.lastError
    end
    local next_sequence = self.sequence + 1
    local envelope = envelope_or_error
    envelope.schemaVersion = SCHEMA_VERSION
    envelope.profileKey = self.identity.profileKey
    envelope.sequence = next_sequence
    envelope.epoch = self.now()
    local encode_ok, encoded = pcall(Json.encode, envelope)
    if not encode_ok then
        self.lastError = "event-encode-failed:" .. tostring(encoded)
        return false, self.lastError
    end
    local ok, append_error = safe_call(
        self.filesystem.append,
        self.eventsPath,
        encoded .. "\n"
    )
    if not ok then
        self.lastError = "event-append-failed:" .. append_error
        return false, self.lastError
    end
    self.sequence = next_sequence
    self.lastError = nil
    return true, envelope
end

function CompanionLedger:publish(payload)
    if not self.active then
        return false, "profile-not-active"
    end
    assert(type(payload) == "table", "companion state payload must be a table")
    local copied, envelope_or_error = safe_copy(payload)
    if not copied then
        self.lastError = "state-copy-failed:" .. envelope_or_error
        return false, self.lastError
    end
    local envelope = envelope_or_error
    envelope.schemaVersion = SCHEMA_VERSION
    envelope.profileKey = self.identity.profileKey
    envelope.identity = copy(self.identity)
    envelope.updatedAtEpoch = self.now()
    envelope.eventSequence = self.sequence
    local ok, write_error = atomic_write(
        self,
        self.statePath,
        envelope
    )
    if not ok then
        self.lastError = "state-publish-failed:" .. write_error
        return false, self.lastError
    end
    self.lastError = nil
    return true, "published"
end

function CompanionLedger:status()
    return {
        enabled = self.enabled,
        active = self.active,
        profileKey = self.identity and self.identity.profileKey or nil,
        activePath = self.activePath,
        statePath = self.statePath,
        eventsPath = self.eventsPath,
        eventSequence = self.sequence,
        lastError = self.lastError,
    }
end

return CompanionLedger
