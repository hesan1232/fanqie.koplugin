-- 书籍元数据（作者）解析与缓存。
-- 背景：书架 / 目录接口都不带作者，唯一稳定来源是公开详情页
--   https://fanqienovel.com/page/<book_id> 里的 <span class="author-name-text">。
--   页面 0.2~1.7MB，所以按书抓一次 → 落盘缓存 → 回填统计库，绝不在翻页路径上同步抓。
-- 缓存：<cache_dir>/<book_id>/book_meta.lua = { author, at, tried }
-- ⭐ 只有「页面正常但没有作者」(empty) 才写 tried；传输层 / 5xx / 反爬 515 一律不落盘，
--   否则一次网络抖动就永久放弃（抓取内部另带 3 次重试，间隔 1s / 2s）。

local M = {}

local ok_H, H = pcall(require, "fanqie.helper")
if not ok_H then H = nil end

local ok_Content, Content = pcall(require, "fanqie.content")
if not ok_Content then Content = nil end

local function is_str(s)
    return H and H.is_str and H.is_str(s) or type(s) == "string"
end

local function log_debug(...)
    local ok, L = pcall(require, "fanqie.logger")
    if ok and type(L) == "table" and L.debug then pcall(L.debug, ...) end
end

-- 重试策略：总尝试 3 次，失败后分别等待 1s / 2s。
-- 番茄详情页有反爬（偶发 HTTP 515），单次失败不该给这本书判死刑。
local RETRY_MAX = 3
local RETRY_DELAYS = { 1, 2 }

-- 把任意错误值（string / {auth_expired=..., message=...}）转成可读字符串。
local function err_text(e)
    if type(e) == "table" then
        return tostring(e.message or e.err or "table error")
    end
    return tostring(e)
end

-- 判断一次失败是否值得重试。
-- 传输层失败（连接被拒 / 超时）没有状态码，同样值得重试。
local function is_retryable(err)
    local s = err_text(err)
    local code = tonumber(s:match("HTTP%s+(%d+)"))
    if not code then return true end
    if code == 429 then return true end
    if code >= 500 then return true end -- 含 515 反爬、502/503
    return false                        -- 4xx 是确定性错误，重试无意义
end

-- 子进程内休眠。降级同步路径（无 fork，跑在 UI 线程）绝不休眠，否则卡界面。
local function sleep_seconds(sec)
    if not sec or sec <= 0 then return end
    local ok_a, Async = pcall(require, "fanqie.async")
    if ok_a and type(Async) == "table" and Async.is_available
        and not Async.is_available() then
        return
    end
    local ok_s, socket = pcall(require, "socket")
    if ok_s and type(socket) == "table" and type(socket.sleep) == "function" then
        pcall(socket.sleep, sec)
    end
end

-- <cache_dir>/<book_id>/book_meta.lua（拿不到目录时返回 nil）
function M.meta_path(settings, book_id)
    if not settings or not is_str(book_id) or book_id == "" then return nil end
    if Content and Content.book_cache_dir then
        local ok, dir = pcall(Content.book_cache_dir, settings, book_id)
        if ok and is_str(dir) then return H.join_path(dir, "book_meta.lua") end
    end
    return nil
end

-- 读缓存：返回 (author, tried)。author 为空串表示"缓存里就是没作者"。
function M.read(settings, book_id)
    local path = M.meta_path(settings, book_id)
    if not path or not H or not H.file_exists(path) then return nil, false end
    local ok, meta = pcall(dofile, path)
    if not ok or type(meta) ~= "table" then return nil, false end
    local author = is_str(meta.author) and meta.author or ""
    return author, meta.tried == true
end

function M.get_author(settings, book_id)
    local author = M.read(settings, book_id)
    if author and author ~= "" then return author end
    return nil
end

-- 是否已经抓过（成功或有 tried 标记）—— 用于决定要不要再发网络请求
function M.is_cached(settings, book_id)
    local author, tried = M.read(settings, book_id)
    if author and author ~= "" then return true end
    return tried
end

function M.save(settings, book_id, author, tried)
    local path = M.meta_path(settings, book_id)
    if not path or not H or not H.write_file then return false end
    local body = string.format("return { author = %q, at = %d, tried = %s }\n",
        is_str(author) and author or "", os.time(), tried and "true" or "false")
    local ok = pcall(H.write_file, path, body)
    return ok and true or false
end

-- 从书籍详情页 HTML 里解析作者。多路兜底，任一命中即返回。
function M.parse_author(html)
    if not is_str(html) or html == "" then return nil end
    local author = html:match('<span class="author%-name%-text">%s*(.-)%s*</span>')
    if not author or author == "" then
        author = html:match('<meta%s+name="author"%s+content="(.-)"')
    end
    if not author or author == "" then
        author = html:match('"authorName"%s*:%s*"(.-)"')
    end
    if not author or author == "" then
        author = html:match('"author_name"%s*:%s*"(.-)"')
    end
    if author and author ~= "" then
        -- HTML 实体兜底（作者名里偶见 &amp; 等）
        author = author:gsub("&amp;", "&"):gsub("&#39;", "'"):gsub("&quot;", '"')
        if H and H.trim then author = H.trim(author) end
        if author ~= "" then return author end
    end
    return nil
end

-- 直接抓一次书籍详情页并解析作者（在子进程里跑）。
-- 返回 (author, status, err)：
--   "ok"    author = 作者名
--   "empty" author = nil，页面正常返回但确实没有作者（确定性 → 可记 tried）
--   "error" author = nil，传输层 / 服务端故障（非确定性 → 不落盘，下次再试）
function M.fetch_author(settings, book_id)
    if not settings or not is_str(book_id) or book_id == "" then
        return nil, "error", "invalid book_id"
    end
    local ok_client, Client = pcall(require, "fanqie.client")
    if not ok_client or type(Client) ~= "table" or not Client.new then
        return nil, "error", "client unavailable"
    end
    local ok_new, client = pcall(function() return Client:new(settings) end)
    if not ok_new or not client then
        return nil, "error", "client init failed"
    end

    local url = "https://fanqienovel.com/page/" .. tostring(book_id)
    local last_err
    for attempt = 1, RETRY_MAX do
        -- 本仓 Client:get_text 自己带 Cookie 头（settings.cookies），无需外部拼装
        local ok_get, html = pcall(function()
            return client:get_text(url, { referer = "https://fanqienovel.com/" })
        end)
        if ok_get and is_str(html) and html ~= "" then
            local author = M.parse_author(html)
            if author then return author, "ok" end
            -- 页面拿到了、只是没有作者字段：确定性结果，不重试
            return nil, "empty"
        end

        last_err = ok_get and "empty body" or html
        log_debug("[book_meta] 作者页抓取失败(第" .. tostring(attempt) .. "/"
            .. tostring(RETRY_MAX) .. "次):", tostring(book_id), err_text(last_err))

        if attempt < RETRY_MAX then
            if not is_retryable(last_err) then break end
            sleep_seconds(RETRY_DELAYS[attempt] or 2)
        end
    end
    return nil, "error", err_text(last_err)
end

-- 回填 KOReader 统计库：把 book.authors 从 N/A 改成真实作者。
-- 统计库里本插件的书靠 md5 = "fanqie-<book_id>" 标识（见 stats.lua）。
-- 不存在该行时静默返回（下次打开书时 resolve 会带上缓存作者重新落库）。
function M.backfill_stats_db(book_id, author)
    if not is_str(book_id) or not is_str(author) or author == "" then return false end
    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then return false end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or type(DataStorage) ~= "table" then return false end
    local ok_path, dir = pcall(DataStorage.getSettingsDir, DataStorage)
    if not ok_path or not is_str(dir) then return false end
    local ok_db, db = pcall(SQ3.open, dir .. "/statistics.sqlite3")
    if not ok_db or not db then return false end
    local md5 = "fanqie-" .. tostring(book_id)
    local esc = author:gsub("'", "''")
    local ok = pcall(function()
        db:exec(string.format("UPDATE book SET authors = '%s' WHERE md5 = '%s';", esc, md5))
    end)
    pcall(db.close, db)
    return ok and true or false
end

-- 确保某本书的作者已解析：
--   有缓存 → 直接回填统计库并回调；
--   无缓存 → 后台异步抓取，成功后落盘 + 回填 + 回调。
-- 绝不同步阻塞阅读路径。
function M.ensure(settings, book_id, on_done)
    if not settings or not is_str(book_id) or book_id == "" then return nil end

    local cached = M.get_author(settings, book_id)
    if cached then
        M.backfill_stats_db(book_id, cached)
        if on_done then pcall(on_done, cached) end
        return cached
    end
    if M.is_cached(settings, book_id) then
        -- 之前抓过但确实没有作者：不再重复请求
        return nil
    end

    local ok_Async, Async = pcall(require, "fanqie.async")
    if not ok_Async or type(Async) ~= "table" or not Async.run then
        return nil
    end

    Async.run(function()
        local author, status, err = M.fetch_author(settings, book_id)
        -- 单个返回值（Async.run 只透传一个返回值）
        return { author = author, status = status, err = err }
    end, function(ok, result)
        if not ok or type(result) ~= "table" then
            -- 子进程异常 / 超时：属于非确定性失败，不落盘，下次打开还会重试
            log_debug("[book_meta] 作者抓取子进程异常，未缓存:", tostring(book_id))
            return
        end
        local status = result.status
        if status == "ok" and is_str(result.author) and result.author ~= "" then
            M.save(settings, book_id, result.author, true)
            M.backfill_stats_db(book_id, result.author)
            log_debug("[book_meta] 作者已解析:", tostring(book_id), result.author)
            if on_done then pcall(on_done, result.author) end
        elseif status == "empty" then
            -- 页面正常返回但确实没有作者：记 tried，避免每次打开都请求
            M.save(settings, book_id, "", true)
        else
            -- "error" 或未知状态：不写缓存，留给下次打开重试
            log_debug("[book_meta] 作者抓取失败，未缓存，下次重试:",
                tostring(book_id), tostring(result.err))
        end
    end, { poll_interval = 0.3, timeout = 90, tag = "book_meta" })
    return nil
end

return M
