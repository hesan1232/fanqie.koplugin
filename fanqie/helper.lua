local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local DataStorage = require("datastorage")

local M = {}

M.is_str = function(s)
    return type(s) == "string"
end

M.is_num = function(n)
    return type(n) == "number"
end

M.is_tbl = function(t)
    return type(t) == "table"
end

M.is_func = function(f)
    return type(f) == "function"
end

M.is_boolean = function(b)
    return type(b) == "boolean"
end

M.if_nil = function(a, b)
    if a == nil then
        return b
    end
    return a
end

M.trim = function(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

M.join_path = function(...)
    local args = {...}
    local path = ""
    for _, p in ipairs(args) do
        if p then
            path = path .. "/" .. p
        end
    end
    return path:gsub("/+", "/")
end

M.get_cache_path = function(book_id)
    local base_dir = DataStorage:getFullDataDir() .. "/fanqie"
    return M.join_path(base_dir, book_id)
end

M.make_dir = function(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    util.makePath(path)
    return lfs.attributes(path, "mode") == "directory"
end

M.file_exists = function(path)
    if not M.is_str(path) then return false end
    return lfs.attributes(path, "mode") == "file"
end

M.dir_exists = function(path)
    if not M.is_str(path) then return false end
    return lfs.attributes(path, "mode") == "directory"
end

M.delete_file = function(path)
    if M.file_exists(path) then
        return os.remove(path)
    end
    return true
end

M.write_file = function(path, data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        M.make_dir(dir)
    end
    local file, err = io.open(path, "wb")
    if not file then
        error(err)
    end
    file:write(data)
    file:close()
end

M.delete_dir = function(path)
    if not M.dir_exists(path) then return true end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = M.join_path(path, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                M.delete_dir(full_path)
            else
                os.remove(full_path)
            end
        end
    end
    return lfs.rmdir(path)
end

M.table_size = function(t)
    if not M.is_tbl(t) then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

M.split = function(str, sep)
    local result = {}
    local pattern = string.format("([^%s]+)", sep)
    for part in string.gmatch(str, pattern) do
        table.insert(result, part)
    end
    return result
end

M.url_encode = function(str)
    if not str then return "" end
    str = tostring(str)
    return str:gsub("[^a-zA-Z0-9%-_.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

-- ===========================================================================
-- JSON：更新器与通用场景共用的小封装
-- ===========================================================================
-- json 后端只探测一次（模块级缓存）。原做法是每次调用都 pcall(require, "json")，
-- 而更新器在清单解析/状态读写上会反复调用，pcall + package.loaded 查表的开销没必要重复付。
local _json_backend  -- nil = 未探测；false = 探测失败；否则为模块表
local function json_backend()
    if _json_backend == nil then
        local ok, mod = pcall(require, "json")
        if not ok then
            ok, mod = pcall(require, "rapidjson")
        end
        _json_backend = ok and mod or false
    end
    return _json_backend or nil
end

--- 解析 JSON 字符串。失败返回 nil（不抛错），调用方自行兜底。
M.json_decode = function(text)
    if not text or text == "" then return nil end
    local json = json_backend()
    if not json then return nil end
    local ok, result = pcall(json.decode, text)
    if ok and result ~= nil then
        return result
    end
    return nil
end

--- 序列化 table 为 JSON 字符串。失败返回 nil。
M.json_encode = function(obj)
    if obj == nil then return nil end
    local json = json_backend()
    if not json then return nil end
    local ok, result = pcall(json.encode, obj)
    if ok and type(result) == "string" then
        return result
    end
    return nil
end

-- ===========================================================================
-- 文件 / 路径（更新器需要）
-- ===========================================================================

M.file_size = function(path)
    local size = lfs.attributes(path, "size")
    return size or 0
end

--- 插件数据根目录（与 Settings:new 里的目录保持一致，避免两处各写一份）。
M.get_data_dir = function()
    return DataStorage:getFullDataDir() .. "/fanqie"
end

--- 解压 zip 到 dest_dir（纯 Lua，走 KOReader 自带的 ffi/archiver）。
--
-- 【为什么不用系统 unzip】Kindle 的 busybox 没有 unzip，依赖外部命令的实现在设备上直接不可用。
--
-- 【路径穿越防护】zip 条目名是攻击面（`../../x` 这类）。这里做两层检查：一是条目名里不允许
-- 出现 `..`，二是拼接后的绝对路径必须仍落在 dest_dir 之内。
--
-- @param zip_path string
-- @param dest_dir string
-- @return true | false, string 原因
M.unzip_file = function(zip_path, dest_dir)
    local ok_arch, Archiver = pcall(require, "ffi/archiver")
    if not ok_arch or not Archiver then
        return false, "无法加载 archiver 库"
    end

    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        return false, "无法打开 zip 文件"
    end

    local norm_dest = tostring(dest_dir):gsub("[/\\]+$", "")
    M.make_dir(dest_dir)

    for entry in arc:iterate() do
        local raw_entry = entry.path
        if raw_entry:find("%.%.") then
            -- 跳过疑似路径穿越的条目
        else
            -- 直接拼绝对路径（不走 M.join_path：那个实现会给相对路径补前导 "/"）
            local entry_path = dest_dir:gsub("[/\\]+$", "") .. "/" .. raw_entry
            if entry_path:sub(1, #norm_dest) ~= norm_dest then
                -- 跳过逃逸目标目录的条目
            elseif entry.mode == "directory" then
                M.make_dir(entry_path)
            elseif entry.mode == "file" then
                local parent_dir = entry_path:match("^(.*)[/\\]")
                if parent_dir then
                    M.make_dir(parent_dir)
                end
                local content = arc:extractToMemory(entry.path)
                if content then
                    local file = io.open(entry_path, "wb")
                    if file then
                        -- ⚠️ write / close 的返回值都要查：Lua stdio 带缓冲，磁盘写满时
                        -- write 往往不报错，错误要到 close 才暴露。只看 open 成功会留下
                        -- 一个「打开成功、内容截断」的文件，后面被当成完整文件使用。
                        local write_ok, write_err = file:write(content)
                        local close_ok, close_err = file:close()
                        if not write_ok or close_ok == nil then
                            os.remove(entry_path)
                        end
                    end
                end
            end
        end
    end

    arc:close()
    return true
end

-- ===========================================================================
-- 缓存偏好读取（唯一口径）
-- ===========================================================================
-- 🔴 必须用 settings:get("cache")（**不带第二个参数**）读取 cache 表。
-- 传 `{}` 当默认值会绕过 Settings 的 defaults 表（readSetting 只在 default 为
-- nil 时回落 defaults[key]），于是全新安装时 cache.pre_download_chapters 恒为
-- nil，各处只能各自写死 `or 3` —— 这正是「改了预下载章节数没用」的温床。
M.cache_table = function(settings)
    if not settings or type(settings.get) ~= "function" then return nil end
    local ok, cache = pcall(function() return settings:get("cache") end)
    if not ok or type(cache) ~= "table" then return nil end
    return cache
end

local function number_or(cache, key, default)
    local v = cache and tonumber(cache[key])
    if v == nil then return default end
    return v
end

-- 预下载章节数。0 = 关闭预下载；非法值回落默认；负数归一 0。
M.prefetch_count = function(settings)
    local v = number_or(M.cache_table(settings), "pre_download_chapters", 3)
    if v < 0 then return 0 end
    return math.floor(v)
end

-- ===========================================================================
-- 批量下载节流参数
-- ===========================================================================
-- 番茄服务端对「短时间高频抓取」有风控特征，逐章连打会放大该特征；这里在父进程的
-- 批次调度点上插入间隔，顺序预下载 / 整本下载统一生效（无需跨子进程状态）。
--
-- 「章间隔 + 随机抖动 + 批量长休」这一组取值对齐同一套 App 协议的生产实现
-- （kindle-forge backend/routes/cache.py::_pf_run_fanqie）：
--     章间隔 1.0 ~ 1.8s（抖动）          每 20 章长休 6s
-- 旧版这里是 0.6s 固定间隔且无长休，约比生产值激进 2~3 倍。
--
-- 全部读 settings.cache.*，未配置 / 非法值回落默认；<= 0 表示关闭该项。
local DEFAULT_INTERVAL = 1.0
local DEFAULT_JITTER = 0.6
local DEFAULT_BATCH_SIZE = 20
local DEFAULT_BATCH_REST = 6.0

-- 相邻两章之间的基础间隔（秒）。0 = 关闭节流。
M.request_gap = function(settings, default_seconds)
    local fallback = tonumber(default_seconds) or DEFAULT_INTERVAL
    local v = number_or(M.cache_table(settings), "request_interval", fallback)
    if v < 0 then return 0 end
    return v
end

-- 抖动上限（秒）。固定节奏本身就是风控特征，加随机量打散。
local seeded = false
M.request_jitter = function(settings)
    local max_jitter = number_or(M.cache_table(settings), "request_interval_jitter", DEFAULT_JITTER)
    if max_jitter <= 0 then return 0 end
    if not seeded then
        math.randomseed(os.time() + (math.floor((os.clock() or 0) * 1000) % 1000))
        seeded = true
    end
    return math.random() * max_jitter
end

-- 批量休息：每 batch_size 章之后额外休息 rest 秒（0 = 关闭）。
M.batch_rest = function(settings)
    local cache = M.cache_table(settings)
    local size = number_or(cache, "request_batch_size", DEFAULT_BATCH_SIZE)
    local rest = number_or(cache, "request_batch_rest", DEFAULT_BATCH_REST)
    if size <= 0 or rest <= 0 then return nil end
    return { size = math.floor(size), rest = rest }
end

-- 调度点统一入口：返回「下一章之前应等待的秒数」。
-- processed = 本次批量中**已发过请求**的章节数（跳过缓存的章节不计）。
M.next_request_delay = function(settings, processed)
    local gap = M.request_gap(settings)
    if gap <= 0 then return 0 end
    local delay = gap + M.request_jitter(settings)
    local br = M.batch_rest(settings)
    if br and processed and processed > 0 and processed % br.size == 0 then
        delay = delay + br.rest
    end
    return delay
end

-- ===========================================================================
-- UIManager 对话框生命周期（重复 close 会凭空刷屏）
-- ===========================================================================
-- 🔴 UIManager:close(w) 对「已经不在窗口栈上」的 w **依然会无条件派发一次**
--    CloseWidget 事件：koreader/frontend/ui/uimanager.lua 的 close() 一开头就是
--    `widget:handleEvent(Event:new("CloseWidget"))`，而扫描 _window_stack 做移除
--    的循环在它**后面**；只有移除真的发生了 dirty 才为 true 才会补刷新。
--    也就是说：移除这一步是 no-op，但 CloseWidget 事件的副作用照跑 ——
--      · ButtonDialog:onCloseWidget() → setDirty(nil, "flashui", 对话框区域)
--      · InfoMessage:onCloseWidget()  → setDirty(nil, "ui", 消息区域)
--    这两个 setDirty 的 refresh 回调会被塞进 _refresh_func_stack，等**下一次**
--    _repaint() 才消费：于是「重复关闭一个早就关掉的弹窗」表现为
--      (a) 屏幕上那块矩形凭空闪一下（flashui 是黑→白全刷，白底阅读页上像弹窗闪了一下）；
--      (b) 刷新请求会一直挂着，直到下一次 forceRePaint()（翻页 / 切章都会触发）才爆出来。
--    ⇒ 「切章时弹窗闪一下然后消失」就是这个。
--
--    所以凡是要「稍后再关一次」的地方（onClose 收尾、菜单关闭回调、幂等 busy），
--    都必须先问：它还在栈上吗？close_widget() = 这个问句 + 关闭的合并体。

local UI_MANAGER = nil
local function get_uimanager()
    if UI_MANAGER ~= nil then return UI_MANAGER end
    local ok, mod = pcall(require, "ui/uimanager")
    UI_MANAGER = (ok and mod) or false
    return UI_MANAGER
end

-- 该 widget 是否仍在 UIManager 的窗口栈上。
-- 兼容两种栈结构：新版 `{ {widget = w, ...}, ... }`、旧版 `{ w, ... }`。
-- 拿不到 UIManager / 结构不认识时**保守返回 true**（宁可多关一次，也不能漏关而留死界面）。
M.widget_shown = function(widget)
    if not widget then return false end
    local UIManager = get_uimanager()
    if not UIManager then return true end
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return true end
    for i = #stack, 1, -1 do
        local entry = stack[i]
        if entry == widget then return true end
        if type(entry) == "table" and entry.widget == widget then return true end
    end
    return false
end

-- 关闭对话框：只在它确实还在栈上时才关（避免上面那类「空关一次 → 凭空闪屏」）。
-- 返回 true 表示这次真的关了一次。
M.close_widget = function(widget)
    if not widget then return false end
    if not M.widget_shown(widget) then return false end
    local UIManager = get_uimanager()
    if not UIManager or not UIManager.close then return false end
    pcall(function() UIManager:close(widget) end)
    return true
end

return M