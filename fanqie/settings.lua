local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local H = require("fanqie.helper")

local Settings = {}
Settings.__index = Settings

local defaults = {
    cookies = {},
    config_auth_fingerprint = "",
    config_preferences_fingerprint = "",
    curl_payload = {},
    books = {},
    downloads = {},
    sync = {
        pull_on_open = true,
        upload_on_close = true,
        ask_on_conflict = true,
        upload_interval_minutes = 0,
    },
    cache = {
        download_book_images = true,
        download_underlines_and_thoughts = false,
        show_annotations = true,
        max_size_mb = 1024,
        pre_download_chapters = 3,
        pre_download_groups = 2,
    },
    read_report = {
        enabled = false,
        mode = "manual",
        book_id = "",
        book_title = "",
        interval_seconds = 30,
        report_on_open = true,
    },
    advanced = {
        developer_logs = false,
    },
    shelf = {
        sort_order = "time_desc",
    },
    -- 段评开关（持久化到用户设置，重启后保持）
    para_review_enabled = false,
    download_dir = "",
    config_loaded = true,
    -- Legacy qingtian config (kept for migration; new code reads sources.qingtian)
    qingtian = {
        server_url = "https://v1.gyks.cf/",
        username = "",
        password = "",
        token = "",
        device_id = "",
        auto_login = true,
        rate_limit = {
            max_requests = 5,
            window_seconds = 30,
        },
    },
    -- Book source management (replaces hardcoded qingtian->official fallback)
    sources = {
        qingtian = {
            enabled = true,
            order = 1,
            server_url = "https://v1.gyks.cf/",
            username = "",
            password = "",
            token = "",
            device_id = "",
            auto_login = true,
            rate_limit = { max_requests = 5, window_seconds = 30 },
        },
        dahuilang = {
            enabled = true,
            order = 2,
            server_url = "https://v2.czyl.cf",
            username = "",
            password = "",
            key = "",
            token = "",
            device_id = "",
            auto_login = true,
            source = "番茄",
            tab = "小说",
            tone_id = "4",
            rate_limit = { max_requests = 5, window_seconds = 30 },
        },
        official = {
            enabled = true,
            order = 3,
            rate_limit = { max_requests = 0, window_seconds = 0 },
        },
    },
    sources_version = 1,
}

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    setmetatable(out, getmetatable(value))
    return out
end

-- One-time migration: merge legacy `qingtian` settings into `sources.qingtian`.
-- Only runs when sources_version < 1. Overwrites default empty values with the
-- user's actual legacy config (so real account/password/token are carried over).
local function migrate_legacy_qingtian(store)
    local legacy = store:readSetting("qingtian", nil)
    if legacy and type(legacy) == "table" then
        local sources = store:readSetting("sources", deepcopy(defaults.sources))
        local qt = sources.qingtian or {}
        -- Carry over non-empty legacy values (overwrite default empty strings)
        for _, key in ipairs({"server_url", "username", "password", "token", "device_id"}) do
            if legacy[key] ~= nil and legacy[key] ~= "" then
                qt[key] = legacy[key]
            end
        end
        -- auto_login is a boolean, preserve legacy setting
        if legacy.auto_login ~= nil then
            qt.auto_login = legacy.auto_login
        end
        if type(legacy.rate_limit) == "table" then
            qt.rate_limit = qt.rate_limit or {}
            if legacy.rate_limit.max_requests ~= nil then
                qt.rate_limit.max_requests = legacy.rate_limit.max_requests
            end
            if legacy.rate_limit.window_seconds ~= nil then
                qt.rate_limit.window_seconds = legacy.rate_limit.window_seconds
            end
        end
        sources.qingtian = qt
        store:saveSetting("sources", sources)
    end
    store:saveSetting("sources_version", 1)
    store:flush()
end

local function migrate_legacy_dahuilang(store)
    local legacy = store:readSetting("dahuilang", nil)
    if legacy and type(legacy) == "table" then
        local sources = store:readSetting("sources", deepcopy(defaults.sources))
        local dl = sources.dahuilang or {}
        for _, key in ipairs({"server_url", "username", "password", "key", "token", "device_id", "source", "tab", "tone_id"}) do
            if legacy[key] ~= nil and legacy[key] ~= "" then
                dl[key] = legacy[key]
            end
        end
        if legacy.auto_login ~= nil then
            dl.auto_login = legacy.auto_login
        end
        if legacy.enabled ~= nil then
            dl.enabled = legacy.enabled
        end
        if legacy.order ~= nil then
            dl.order = legacy.order
        end
        if type(legacy.rate_limit) == "table" then
            dl.rate_limit = dl.rate_limit or {}
            if legacy.rate_limit.max_requests ~= nil then
                dl.rate_limit.max_requests = legacy.rate_limit.max_requests
            end
            if legacy.rate_limit.window_seconds ~= nil then
                dl.rate_limit.window_seconds = legacy.rate_limit.window_seconds
            end
        end
        sources.dahuilang = dl
        store:saveSetting("sources", sources)
    end
    store:saveSetting("sources_version", 2)
    store:flush()
end

function Settings:new()
    local data_dir = DataStorage:getFullDataDir() .. "/fanqie"
    H.make_dir(data_dir)
    local obj = {
        data_dir = data_dir,
        default_cache_dir = data_dir .. "/cache",
        settings_file = DataStorage:getSettingsDir() .. "/fanqie.lua",
    }
    obj.store = LuaSettings:open(obj.settings_file)

    -- Only write defaults on first run, don't flush otherwise
    if not obj.store:has("config_loaded") then
        obj.store:saveSetting("config_loaded", true)
        obj.store:flush()
    end

    -- Migrate legacy qingtian config into sources.qingtian (once)
    local sv = obj.store:readSetting("sources_version", 0) or 0
    if sv < 1 then
        migrate_legacy_qingtian(obj.store)
    end
    -- Migrate legacy dahuilang config into sources.dahuilang (once)
    sv = obj.store:readSetting("sources_version", 0) or 0
    if sv < 2 then
        migrate_legacy_dahuilang(obj.store)
    end

    local download_dir = obj.store:readSetting("download_dir", "")
    obj.cache_dir = (H.is_str(download_dir) and download_dir ~= "") and download_dir or obj.default_cache_dir
    H.make_dir(obj.cache_dir)

    return setmetatable(obj, self)
end

function Settings:get(key, default)
    if default == nil then
        default = defaults[key]
    end
    local result = self.store:readSetting(key, deepcopy(default))
    return result
end

function Settings:set(key, value)
    self.store:saveSetting(key, value)
end

function Settings:flush()
    self.store:flush()
end

function Settings:get_all()
    local all = {}
    for key in pairs(defaults) do
        all[key] = self:get(key)
    end
    return all
end

function Settings:get_download_dir()
    return self.cache_dir
end

function Settings:set_download_dir(path)
    if type(path) ~= "string" or path == "" then
        self:set("download_dir", "")
        self.cache_dir = self.default_cache_dir
    else
        self:set("download_dir", path)
        self.cache_dir = path
    end
    self:flush()
    H.make_dir(self.cache_dir)
    return self.cache_dir
end

function Settings:reset_account()
    self:set("cookies", {})
    self:set("curl_payload", {})
    self:flush()
end

function Settings:is_cookie_configured()
    local cookies = self:get("cookies", {})
    for key in pairs(cookies) do
        if cookies[key] and #tostring(cookies[key]) >= 8 then
            return true
        end
    end
    return false
end

-- === Book source management ===
-- These accessors read/write `sources.<id>` (the new unified config).
-- Legacy get_qingtian_* APIs are kept for backward compatibility; they
-- now delegate to sources.qingtian.

function Settings:get_sources()
    return self:get("sources", {})
end

function Settings:get_source(source_id)
    local sources = self:get("sources", {})
    return sources[source_id] or {}
end

function Settings:set_source(source_id, cfg)
    local sources = self:get("sources", {})
    sources[source_id] = cfg
    self:set("sources", sources)
    self:flush()
end

function Settings:set_source_field(source_id, key, value)
    local sources = self:get("sources", {})
    local cfg = sources[source_id] or {}
    cfg[key] = value
    sources[source_id] = cfg
    self:set("sources", sources)
    self:flush()
end

-- Swap a source's order with its neighbor. direction: -1 = up, +1 = down.
function Settings:move_source(source_id, direction)
    local sources = self:get("sources", {})
    local ordered = {}
    for id, cfg in pairs(sources) do
        table.insert(ordered, { id = id, order = cfg.order or 999 })
    end
    table.sort(ordered, function(a, b) return a.order < b.order end)
    local idx = nil
    for i, item in ipairs(ordered) do
        if item.id == source_id then idx = i break end
    end
    if not idx then return false end
    local target = idx + direction
    if target < 1 or target > #ordered then return false end
    local a, b = ordered[idx], ordered[target]
    local cfg_a = sources[a.id]
    local cfg_b = sources[b.id]
    if cfg_a and cfg_b then
        cfg_a.order, cfg_b.order = cfg_b.order, cfg_a.order
        sources[a.id] = cfg_a
        sources[b.id] = cfg_b
        self:set("sources", sources)
        self:flush()
        return true
    end
    return false
end

function Settings:get_qingtian_configured()
    local qt = self:get_source("qingtian")
    local server_url = H.trim(qt.server_url or "")
    local username = H.trim(qt.username or "")
    local token = H.trim(qt.token or "")
    return server_url ~= "" and (token ~= "" or username ~= "")
end

function Settings:get_qingtian_token()
    local qt = self:get_source("qingtian")
    return H.trim(qt.token or "")
end

function Settings:set_qingtian_token(token, device_id)
    local qt = self:get_source("qingtian")
    qt.token = token
    if device_id then
        qt.device_id = device_id
    end
    self:set_source("qingtian", qt)
end

function Settings:clear_qingtian_token()
    local qt = self:get_source("qingtian")
    qt.token = ""
    qt.device_id = ""
    self:set_source("qingtian", qt)
end

function Settings:get_dahuilang_token()
    local dl = self:get_source("dahuilang")
    return H.trim(dl.token or "")
end

function Settings:set_dahuilang_token(token, device_id)
    local dl = self:get_source("dahuilang")
    dl.token = token
    if device_id then
        dl.device_id = device_id
    end
    self:set_source("dahuilang", dl)
end

function Settings:clear_dahuilang_token()
    local dl = self:get_source("dahuilang")
    dl.token = ""
    dl.device_id = ""
    self:set_source("dahuilang", dl)
end

-- Compute a simple hash of the config table for change detection.
-- Uses a very simple hash: sum of string lengths + table key count.
-- Good enough to detect if the config.lua file has been edited.
function Settings:compute_config_hash(config)
    if type(config) ~= "table" then
        return ""
    end
    local parts = {}
    local function flatten(t, prefix)
        if type(t) ~= "table" then return end
        for k, v in pairs(t) do
            local key_str = prefix or ""
            key_str = key_str .. tostring(k)
            if type(v) == "table" then
                table.insert(parts, key_str .. "={}")
                flatten(v, key_str .. ".")
            elseif type(v) == "string" then
                table.insert(parts, key_str .. "=" .. v)
            elseif type(v) == "number" or type(v) == "boolean" then
                table.insert(parts, key_str .. "=" .. tostring(v))
            end
        end
    end
    flatten(config, "")
    local raw = table.concat(parts, "&")
    return raw
end

local function parse_cookie_string(cookie_string)
    if not cookie_string or cookie_string == "" then
        return {}
    end
    local cookies = {}
    for part in cookie_string:gmatch("([^;]+)") do
        local key, value = part:match("^%s*([^=]+)=(.-)%s*$")
        if key and value then
            cookies[key] = value
        end
    end
    return cookies
end

function Settings:apply_config(config, options)
    options = options or {}
    if type(config) ~= "table" then
        return false, "config must return a table"
    end
    
    local apply_preferences = options.apply_preferences ~= false
    local override_existing = options.override_existing or false
    local force = options.force or false

    -- If not forced, check config hash to avoid re-applying unchanged config
    if not force then
        local config_hash = self:compute_config_hash(config)
        local saved_hash = self:get("config_hash", "")
        if config_hash == saved_hash and saved_hash ~= "" then
            return true, "config unchanged, skipped"
        end
    end
    
    local cookies = {}
    if H.is_str(config.cookie_string) and config.cookie_string ~= "" then
        cookies = parse_cookie_string(config.cookie_string)
    elseif H.is_tbl(config.cookies) then
        cookies = config.cookies
    end
    if next(cookies) ~= nil then
        self:set("cookies", cookies)
    end
    
    if apply_preferences and H.is_tbl(config.sync) then
        local sync = self:get("sync")
        if override_existing then
            for key, value in pairs(config.sync) do
                sync[key] = value
            end
        else
            for key, value in pairs(config.sync) do
                if sync[key] == nil then
                    sync[key] = value
                end
            end
        end
        self:set("sync", sync)
    end
    
    if apply_preferences and H.is_tbl(config.cache) then
        local cache = self:get("cache")
        if override_existing then
            for key, value in pairs(config.cache) do
                cache[key] = value
            end
        else
            for key, value in pairs(config.cache) do
                if cache[key] == nil then
                    cache[key] = value
                end
            end
        end
        self:set("cache", cache)
    end
    
    if apply_preferences and H.is_tbl(config.read_report) then
        local rr = self:get("read_report")
        if override_existing then
            if config.read_report.interval_seconds then
                rr.interval_seconds = config.read_report.interval_seconds
            end
            if config.read_report.report_on_open ~= nil then
                rr.report_on_open = config.read_report.report_on_open
            end
            if H.is_str(config.read_report.book_id) and config.read_report.book_id ~= "" then
                rr.book_id = config.read_report.book_id
                rr.book_title = config.read_report.book_title or rr.book_title
                if config.read_report.enabled ~= nil then
                    rr.enabled = config.read_report.enabled
                end
            end
        end
        self:set("read_report", rr)
    end
    
    if apply_preferences and H.is_tbl(config.shelf) then
        local shelf = self:get("shelf")
        if override_existing then
            for key, value in pairs(config.shelf) do
                shelf[key] = value
            end
        else
            for key, value in pairs(config.shelf) do
                if shelf[key] == nil then
                    shelf[key] = value
                end
            end
        end
        self:set("shelf", shelf)
    end
    
    -- New unified sources config (nil-only: don't overwrite user-edited values)
    if H.is_tbl(config.sources) then
        local sources = self:get("sources")
        for source_id, cfg in pairs(config.sources) do
            local existing = sources[source_id] or {}
            for key, value in pairs(cfg) do
                -- Protect token/device_id: config file never overwrites login state
                if key ~= "token" and key ~= "device_id" then
                    -- nil-only: only apply if user hasn't set this key yet
                    if existing[key] == nil or force then
                        existing[key] = value
                    end
                end
            end
            sources[source_id] = existing
        end
        self:set("sources", sources)
    end

    -- Legacy qingtian config: merge into sources.qingtian (nil-only)
    if H.is_tbl(config.qingtian) then
        local sources = self:get("sources")
        local qt = sources.qingtian or {}
        for key, value in pairs(config.qingtian) do
            if key ~= "token" and key ~= "device_id" then
                if qt[key] == nil or force then
                    qt[key] = value
                end
            end
        end
        if config.qingtian.auto_login ~= nil then
            if qt.auto_login == nil or force then
                qt.auto_login = config.qingtian.auto_login
            end
        end
        sources.qingtian = qt
        self:set("sources", sources)
    end

    -- Legacy dahuilang config: merge into sources.dahuilang (nil-only)
    if H.is_tbl(config.dahuilang) then
        local sources = self:get("sources")
        local dl = sources.dahuilang or {}
        for key, value in pairs(config.dahuilang) do
            -- Protect token/device_id from being overwritten by config file
            if key ~= "token" and key ~= "device_id" then
                if dl[key] == nil or force then
                    dl[key] = value
                end
            end
        end
        if config.dahuilang.auto_login ~= nil then
            if dl.auto_login == nil or force then
                dl.auto_login = config.dahuilang.auto_login
            end
        end
        if config.dahuilang.enabled ~= nil then
            if dl.enabled == nil or force then
                dl.enabled = config.dahuilang.enabled
            end
        end
        if config.dahuilang.order ~= nil then
            if dl.order == nil or force then
                dl.order = config.dahuilang.order
            end
        end
        sources.dahuilang = dl
        self:set("sources", sources)
    end

    -- Save config hash so next call can skip if unchanged
    local config_hash = self:compute_config_hash(config)
    self:set("config_hash", config_hash)
    
    self:set("config_loaded", true)
    self:flush()
    return true
end

function Settings:reset_config_loaded()
    self:set("config_loaded", false)
    self:flush()
end

function Settings:clear_book_cache(book_id)
    local book_dir = self.cache_dir .. "/" .. book_id
    H.delete_dir(book_dir)
    return true
end

function Settings:clear_all_cache()
    local lfs = require("libs/libkoreader-lfs")
    for entry in lfs.dir(self.cache_dir) do
        if entry ~= "." and entry ~= ".." then
            local full_path = H.join_path(self.cache_dir, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                H.delete_dir(full_path)
            else
                H.delete_file(full_path)
            end
        end
    end
    return true
end

function Settings:get_cache_stats()
    local lfs = require("libs/libkoreader-lfs")
    local stats = {
        book_count = 0,
        total_size = 0,
        chapter_count = 0
    }
    if not H.dir_exists(self.cache_dir) then
        return stats
    end
    for entry in lfs.dir(self.cache_dir) do
        if entry ~= "." and entry ~= ".." then
            local full_path = H.join_path(self.cache_dir, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                stats.book_count = stats.book_count + 1
                local book_size = 0
                local chapter_count = 0
                for file_entry in lfs.dir(full_path) do
                    if file_entry ~= "." and file_entry ~= ".." then
                        local file_path = H.join_path(full_path, file_entry)
                        local file_mode = lfs.attributes(file_path, "mode")
                        if file_mode == "file" then
                            local size = lfs.attributes(file_path, "size") or 0
                            book_size = book_size + size
                            if file_path:match("%.html$") then
                                chapter_count = chapter_count + 1
                            end
                        end
                    end
                end
                stats.total_size = stats.total_size + book_size
                stats.chapter_count = stats.chapter_count + chapter_count
            end
        end
    end
    return stats
end

-- 段评开关持久化读写
function Settings:getParaReviewEnabled()
    return self:get("para_review_enabled", false) == true
end

function Settings:setParaReviewEnabled(enabled)
    self:set("para_review_enabled", enabled == true)
    self:flush()
end

return Settings