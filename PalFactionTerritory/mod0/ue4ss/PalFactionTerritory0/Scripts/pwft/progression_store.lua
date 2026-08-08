local Json = require("pwft.json")

local ProgressionStore = {}

local ENVELOPE_SCHEMA_VERSION = "1.0.0"

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

local function require_non_empty_string(value, name)
    assert(type(value) == "string" and value ~= "", name .. " must be a non-empty string")
    return value
end

local function validate_profile_key(profile_key)
    require_non_empty_string(profile_key, "progression profile key")
    assert(
        string.find(profile_key, "^[A-Za-z0-9._%-]+$") ~= nil,
        "progression profile key contains unsafe characters"
    )
    assert(profile_key ~= "." and profile_key ~= "..", "progression profile key cannot traverse directories")
    return profile_key
end

local function normalize_root(root_path)
    require_non_empty_string(root_path, "progression sidecar root")
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
        read = function(path)
            local handle, open_error = io.open(path, "rb")
            if handle == nil then
                return nil, open_error
            end
            local content = handle:read("*a")
            handle:close()
            return content
        end,
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

local function decode_envelope(instance, encoded)
    local ok, envelope = pcall(Json.decode, encoded)
    if not ok then
        return nil, "invalid-json:" .. tostring(envelope)
    end
    if type(envelope) ~= "table"
        or envelope.schemaVersion ~= ENVELOPE_SCHEMA_VERSION then
        return nil, "unsupported-envelope-schema"
    end
    if envelope.profileKey ~= instance.profileKey then
        return nil, "profile-key-mismatch"
    end
    if type(envelope.payload) ~= "table" then
        return nil, "missing-progression-payload"
    end
    return envelope
end

local function read_candidate(instance, path, source)
    if not instance.filesystem.exists(path) then
        return nil, "not-found"
    end
    local encoded, read_error = instance.filesystem.read(path)
    if encoded == nil then
        return nil, "read-failed:" .. tostring(read_error)
    end
    local envelope, decode_error = decode_envelope(instance, encoded)
    if envelope == nil then
        return nil, decode_error
    end
    return {
        snapshot = copy(envelope.payload),
        source = source,
        savedAtEpoch = envelope.savedAtEpoch,
        revision = envelope.revision,
    }
end

function ProgressionStore.create(config, filesystem)
    assert(type(config) == "table", "progression persistence configuration is required")
    local enabled = config.enabled == true
    if not enabled then
        return setmetatable({
            enabled = false,
            mode = config.mode or "mod-sidecar-json",
            reason = config.reason or "disabled-by-configuration",
        }, { __index = ProgressionStore })
    end

    local profile_key = validate_profile_key(config.profileKey)
    local root_path = normalize_root(config.rootPath)
    local filename = "pwft-progression-v1-" .. profile_key .. ".json"
    local instance = {
        enabled = true,
        mode = config.mode or "mod-sidecar-json",
        reason = nil,
        profileKey = profile_key,
        rootPath = root_path,
        primaryPath = join(root_path, filename),
        temporaryPath = join(root_path, filename .. ".tmp"),
        backupPath = join(root_path, filename .. ".bak"),
        filesystem = filesystem or default_filesystem(),
        now = config.now or os.time,
    }
    for _, name in ipairs({ "read", "write", "exists", "rename", "remove" }) do
        assert(type(instance.filesystem[name]) == "function", "persistence filesystem is missing " .. name)
    end
    assert(type(instance.now) == "function", "progression persistence clock must be a function")
    return setmetatable(instance, { __index = ProgressionStore })
end

function ProgressionStore:status()
    return {
        enabled = self.enabled,
        mode = self.mode,
        reason = self.reason,
        profileKey = self.profileKey,
        primaryPath = self.primaryPath,
        backupPath = self.backupPath,
    }
end

function ProgressionStore:load()
    if not self.enabled then
        return nil, self.reason
    end
    local primary, primary_error = read_candidate(self, self.primaryPath, "primary")
    if primary ~= nil then
        return primary
    end
    local backup, backup_error = read_candidate(self, self.backupPath, "backup")
    if backup ~= nil then
        backup.primaryError = primary_error
        return backup
    end
    return nil, string.format(
        "primary=%s;backup=%s",
        tostring(primary_error),
        tostring(backup_error)
    )
end

function ProgressionStore:save(snapshot)
    if not self.enabled then
        return {
            ok = false,
            reason = self.reason,
            skipped = true,
        }
    end
    assert(type(snapshot) == "table", "progression snapshot must be a table")
    local envelope = {
        schemaVersion = ENVELOPE_SCHEMA_VERSION,
        profileKey = self.profileKey,
        savedAtEpoch = self.now(),
        revision = snapshot.revision,
        payload = copy(snapshot),
    }
    local encoded = Json.encode(envelope)
    local write_ok, write_error = safe_call(
        self.filesystem.write,
        self.temporaryPath,
        encoded
    )
    if not write_ok then
        return { ok = false, reason = "temporary-write-failed:" .. write_error }
    end

    local temporary, verify_error = read_candidate(
        self,
        self.temporaryPath,
        "temporary"
    )
    if temporary == nil then
        pcall(self.filesystem.remove, self.temporaryPath)
        return { ok = false, reason = "temporary-verify-failed:" .. tostring(verify_error) }
    end

    local rotated_primary = false
    if self.filesystem.exists(self.primaryPath) then
        if self.filesystem.exists(self.backupPath) then
            local remove_ok, remove_error = safe_call(
                self.filesystem.remove,
                self.backupPath
            )
            if not remove_ok then
                pcall(self.filesystem.remove, self.temporaryPath)
                return { ok = false, reason = "backup-remove-failed:" .. remove_error }
            end
        end
        local rotate_ok, rotate_error = safe_call(
            self.filesystem.rename,
            self.primaryPath,
            self.backupPath
        )
        if not rotate_ok then
            pcall(self.filesystem.remove, self.temporaryPath)
            return { ok = false, reason = "primary-rotate-failed:" .. rotate_error }
        end
        rotated_primary = true
    end

    local promote_ok, promote_error = safe_call(
        self.filesystem.rename,
        self.temporaryPath,
        self.primaryPath
    )
    if not promote_ok then
        if rotated_primary and not self.filesystem.exists(self.primaryPath) then
            pcall(self.filesystem.rename, self.backupPath, self.primaryPath)
        end
        pcall(self.filesystem.remove, self.temporaryPath)
        return { ok = false, reason = "temporary-promote-failed:" .. promote_error }
    end

    return {
        ok = true,
        reason = "saved",
        revision = snapshot.revision,
        primaryPath = self.primaryPath,
        backupPath = rotated_primary and self.backupPath or nil,
    }
end

return ProgressionStore
