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
    -- 记录「用户用插件菜单显式改过哪些 cache 键」（config.lua 不得覆盖，见 apply_config）
    cache_user_set = {},
    sync = {
        pull_on_open = true,
        upload_on_close = true,
        ask_on_conflict = true,
        -- 阅读中定期上传进度的间隔（分钟）：0 = 关闭。
        -- 默认 3 分钟 —— 以前只在「末页翻章 / 关文档 / 开目录」上传，
        -- 读到一半退出（关 KOReader / 切书 / 掉电 / 被杀）这段进度就丢了
        -- （README 承诺的「阅读中定期上传」以前并不存在）。
        -- 档位见 main.lua 的 PROGRESS_UPLOAD_PRESETS：0 / 1 / 3 / 5 / 10。
        upload_interval_minutes = 3,
    },
    cache = {
        download_book_images = true,
        -- 封面缓存有效期（天）：0 = 永不失效。超过这个天数的封面会被**重新下载**，
        -- 并交给「设置 → 封面缓存 → 立即清理」与「打开书架时每天一次的自动清理」删掉。
        -- 书城的书封面会随活动/版本换图，长期不失效的话本地会越积越多。
        -- 默认 3 天（与 `fanqie/cover_cache.lua` 的 DAYS_DEFAULT 同口径）：
        -- 档位 3 / 7 / 9 / 30 天 / 永久。
        cover_cache_days = 3,
        download_underlines_and_thoughts = false,
        show_annotations = true,
        max_size_mb = 1024,
        pre_download_chapters = 3,
        pre_download_groups = 2,
        -- 批量下载（预下载 / 整本下载）节流：相邻两章之间的基础间隔（秒）+
        -- 随机抖动上限（秒），每 request_batch_size 章再长休 request_batch_rest 秒。
        -- 取值对齐同一套 App 协议的生产实现（kindle-forge cache.py：1.0~1.8s + 每 20 章 6s）。
        -- 任意一项 <= 0 = 关闭该项（想一次性灌完可把 request_interval 设 0）。
        request_interval = 1.0,
        request_interval_jitter = 0.6,
        request_batch_size = 20,
        request_batch_rest = 6.0,
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
        -- 书架排序键 / 方向（参考 koobone 的 settings:shelf.sort_order + sort_asc）
        --   last_read  按最后阅读（服务端 read_timestamp，默认倒序＝最近读的在最前）
        --   title      按书名
        --   progress   按阅读进度
        --   shelf_order 按加入书架（接口原始顺序）
        sort_order = "last_read",
        sort_asc = false,
    },
    -- 视图显示方式（书架 / 书城各自独立，互不影响）
    --   list = 列表行（封面 + 书名 + 元信息）
    --   grid = 封面网格（每页 cols × rows 本，只有封面 + 单行书名）
    -- 网格**列数与行数都显式**（缺省 3×4）：行数不再由列宽反推 —— 反推的结果
    -- 随字号/DPI 漂移，用户没法预期也没法调。0 = 按屏高自动（老配置兜底）。
    ui = {
        shelf = "list",
        store = "list",
        grid_cols = 3,
        grid_rows = 4,
    },
    -- 段评开关（持久化到用户设置，重启后保持）
    para_review_enabled = false,
    download_dir = "",
    config_loaded = true,
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
    if not obj.store:has("config_loaded") then
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
    
    -- Cookie 优先级：扫码登录写入的 settings.cookies 优先，
    -- config.cookie_string / config.cookies 仅作保底 fallback。
    -- 已有扫码 cookie（任意非空值）时跳过，避免 config 覆盖扫码结果。
    local existing_cookies = self:get("cookies", {}) or {}
    local has_scanned_cookie = false
    for _, v in pairs(existing_cookies) do
        if v and v ~= "" then
            has_scanned_cookie = true
            break
        end
    end

    if not has_scanned_cookie then
        local cookies = {}
        if H.is_str(config.cookie_string) and config.cookie_string ~= "" then
            cookies = parse_cookie_string(config.cookie_string)
        elseif H.is_tbl(config.cookies) then
            cookies = config.cookies
        end
        -- 过滤空值：config 模板里 ttwid="" / sessionid="" 这类占位不算有效 cookie
        for k, v in pairs(cookies) do
            if not v or v == "" then
                cookies[k] = nil
            end
        end
        if next(cookies) ~= nil then
            self:set("cookies", cookies)
        end
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
        local user_set = self:get("cache_user_set")
        if type(user_set) ~= "table" then user_set = {} end
        -- 优先级：菜单显式设置 > config.lua > 内置默认。
        -- 旧实现只在 cache[key] == nil 时填充，于是「首次安装已写入 3」之后，
        -- 用户再改 config.lua 的 pre_download_chapters 永远不会生效
        -- —— 这正是「预下载章节数改了没用，一直默认三章」的根因之一。
        if override_existing then
            -- 显式「重新加载配置文件」：以 config.lua 为准，清掉菜单的显式设置标记
            for key, value in pairs(config.cache) do
                cache[key] = value
            end
            user_set = {}
            self:set("cache_user_set", user_set)
        else
            for key, value in pairs(config.cache) do
                if not user_set[key] then
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

-- ===== 缓存偏好写入（带「用户显式设置」标记）=====
-- 菜单改动 cache 项时走这里：除写值外记录 cache_user_set，
-- 使 apply_config 不再用 config.lua 的同名值覆盖它。
-- 想恢复「以 config.lua 为准」，用「设置 → 重新加载配置文件」。
function Settings:set_cache_pref(key, value)
    if type(key) ~= "string" or key == "" then return end
    local cache = self:get("cache")
    cache[key] = value
    self:set("cache", cache)
    local user_set = self:get("cache_user_set")
    if type(user_set) ~= "table" then user_set = {} end
    user_set[key] = true
    self:set("cache_user_set", user_set)
    self:flush()
end

-- ===== 书架排序持久化（参考 koobone）=====
-- 键不合法时回落 last_read，避免手改 settings 文件写坏排序导致书架顺序随机。
local SHELF_SORT_KEYS = {
    last_read = true, title = true, progress = true, shelf_order = true,
}

function Settings:get_shelf_sort()
    local shelf = self:get("shelf")
    local key = type(shelf) == "table" and shelf.sort_order or nil
    if not SHELF_SORT_KEYS[key] then
        -- 兼容旧值 time_desc（v2.5.0 之前的死字段）→ 按最后阅读
        return "last_read"
    end
    return key
end

-- 设置排序键时一并清掉方向：换键由调用方决定默认方向（与 koobone 一致）
function Settings:set_shelf_sort(key)
    if not SHELF_SORT_KEYS[key] then return end
    local shelf = self:get("shelf")
    if type(shelf) ~= "table" then shelf = {} end
    shelf.sort_order = key
    shelf.sort_asc = nil
    self:set("shelf", shelf)
end

-- 返回 nil 表示「未显式设置方向」→ 由调用方按各键默认方向决定
function Settings:get_shelf_sort_asc()
    local shelf = self:get("shelf")
    if type(shelf) ~= "table" then return nil end
    if type(shelf.sort_asc) == "boolean" then return shelf.sort_asc end
    return nil
end

function Settings:set_shelf_sort_asc(asc)
    local shelf = self:get("shelf")
    if type(shelf) ~= "table" then shelf = {} end
    shelf.sort_asc = asc == true
    self:set("shelf", shelf)
end

-- ===== 视图显示方式（列表 / 封面网格）=====
-- kind = "shelf" | "store"。两个视图各自记一份，改书城不会顺带把书架也变成网格。
-- 值不合法（手改 settings 写坏 / 旧版本没有这个键）一律回落 "list"，
-- 避免把一个认不出来的字符串一路带到 updateItems 里做出空页。
local UI_VIEW_KINDS = { shelf = true, store = true }
local UI_VIEW_MODES = { list = true, grid = true }
-- ⚠️ 这三组边界必须与 fanqie/cover_cell.lua 的 GRID_COLS_*/GRID_ROWS_* **同口径**：
-- 菜单档位、这里夹紧的边界、cover_cell.metrics 的兜底是**三处独立夹紧**，任何一处
-- 漂移都会出现「菜单里能选、布局里被悄悄改掉」这种最难查的静默错位。
local GRID_COLS_MIN, GRID_COLS_MAX, GRID_COLS_DEFAULT = 2, 8, 3
local GRID_ROWS_MIN, GRID_ROWS_MAX, GRID_ROWS_DEFAULT = 1, 8, 4

function Settings:get_ui_view(kind)
    if not UI_VIEW_KINDS[kind] then return "list" end
    local ui = self:get("ui")
    local mode = type(ui) == "table" and ui[kind] or nil
    if not UI_VIEW_MODES[mode] then return "list" end
    return mode
end

function Settings:set_ui_view(kind, mode)
    if not UI_VIEW_KINDS[kind] or not UI_VIEW_MODES[mode] then return end
    local ui = self:get("ui")
    if type(ui) ~= "table" then ui = {} end
    ui[kind] = mode
    self:set("ui", ui)
    self:flush()
end

function Settings:get_ui_grid_cols()
    local ui = self:get("ui")
    local n = type(ui) == "table" and tonumber(ui.grid_cols) or nil
    if not n then return GRID_COLS_DEFAULT end
    n = math.floor(n)
    if n < GRID_COLS_MIN then n = GRID_COLS_MIN end
    if n > GRID_COLS_MAX then n = GRID_COLS_MAX end
    return n
end

function Settings:set_ui_grid_cols(n)
    n = math.floor(tonumber(n) or GRID_COLS_DEFAULT)
    if n < GRID_COLS_MIN then n = GRID_COLS_MIN end
    if n > GRID_COLS_MAX then n = GRID_COLS_MAX end
    local ui = self:get("ui")
    if type(ui) ~= "table" then ui = {} end
    ui.grid_cols = n
    self:set("ui", ui)
    self:flush()
end

--- 网格行数。0 = 按屏高自动反推（老配置 / 没设置过时用默认档位）。
function Settings:get_ui_grid_rows()
    local ui = self:get("ui")
    local n = type(ui) == "table" and tonumber(ui.grid_rows) or nil
    if not n then return GRID_ROWS_DEFAULT end
    n = math.floor(n)
    if n <= 0 then return 0 end
    if n < GRID_ROWS_MIN then n = GRID_ROWS_MIN end
    if n > GRID_ROWS_MAX then n = GRID_ROWS_MAX end
    return n
end

function Settings:set_ui_grid_rows(n)
    n = math.floor(tonumber(n) or GRID_ROWS_DEFAULT)
    if n <= 0 then
        n = 0
    elseif n < GRID_ROWS_MIN then
        n = GRID_ROWS_MIN
    elseif n > GRID_ROWS_MAX then
        n = GRID_ROWS_MAX
    end
    local ui = self:get("ui")
    if type(ui) ~= "table" then ui = {} end
    ui.grid_rows = n
    self:set("ui", ui)
    self:flush()
end

-- ===== 封面缓存有效期（书城 store_covers/ 与书架 covers/ 共用这一个设置）=====
-- 0 = 永不失效；上限 10 年在语义上等于「永不失效」，但避免了把 0 当哨兵之外的怪值。
-- 🔴 默认值必须与 `fanqie/cover_cache.lua` 的 `DAYS_DEFAULT` 一致（改一处要改两处）。
local COVER_CACHE_DAYS_DEFAULT = 3
local COVER_CACHE_DAYS_MAX = 3650

function Settings:get_cover_cache_days()
    local cache = self:get("cache")
    local n = type(cache) == "table" and tonumber(cache.cover_cache_days) or nil
    if not n then return COVER_CACHE_DAYS_DEFAULT end
    n = math.floor(n)
    if n < 0 then n = 0 end
    if n > COVER_CACHE_DAYS_MAX then n = COVER_CACHE_DAYS_MAX end
    return n
end

function Settings:set_cover_cache_days(n)
    n = math.floor(tonumber(n) or COVER_CACHE_DAYS_DEFAULT)
    if n < 0 then n = 0 end
    if n > COVER_CACHE_DAYS_MAX then n = COVER_CACHE_DAYS_MAX end
    local cache = self:get("cache")
    if type(cache) ~= "table" then cache = {} end
    cache.cover_cache_days = n
    self:set("cache", cache)
    self:flush()
end

--- 上次自动清理封面缓存的时间戳（秒，0 = 从未清理过）。用来把自动清理限制成
--- 「一天最多一次」—— 每次开书架都扫一遍目录在小屏设备上是白白的 I/O。
function Settings:get_cover_cache_pruned_at()
    local cache = self:get("cache")
    local n = type(cache) == "table" and tonumber(cache.cover_cache_pruned_at) or nil
    if not n or n <= 0 then return 0 end
    return math.floor(n)
end

function Settings:set_cover_cache_pruned_at(ts)
    ts = math.floor(tonumber(ts) or 0)
    if ts < 0 then ts = 0 end
    local cache = self:get("cache")
    if type(cache) ~= "table" then cache = {} end
    cache.cover_cache_pruned_at = ts
    self:set("cache", cache)
    self:flush()
end

return Settings
