local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local H = require("lib.helper")

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
    download_dir = "",
    config_loaded = true,
    fanqie_api_endpoint = "http://101.35.133.34:5000",
    fanqie_proxy_base = "",
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
    if not obj.store:has("fanqie_api_endpoint") then
        obj.store:saveSetting("fanqie_api_endpoint", defaults.fanqie_api_endpoint)
        obj.store:saveSetting("fanqie_proxy_base", defaults.fanqie_proxy_base)
        obj.store:saveSetting("config_loaded", true)
        obj.store:flush()
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

function Settings:get_fanqie_api_endpoints()
    local endpoint = self:get("fanqie_api_endpoint", "")
    if endpoint and H.trim(endpoint) ~= "" then
        return { H.trim(endpoint) }
    end
    return {}
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
    
    if H.is_str(config.fanqie_api_endpoint) then
        self:set("fanqie_api_endpoint", config.fanqie_api_endpoint)
    end
    
    if H.is_str(config.fanqie_proxy_base) then
        self:set("fanqie_proxy_base", config.fanqie_proxy_base)
    end
    
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

return Settings