-- 阅读统计合并：一本书的所有章节在 statistics 里算一条记录，页数用统一刻度跨章累加。
--   1) 猴补 initData()，临时换成本书固定身份读写，结束后还原 doc_props（界面仍显示章节名）；
--   2) 页号 = (N-1)*CHAPTER_SPAN+P，避免各章的"第 3 页"互相覆盖。
-- ⚠️ book.pages 必须 = 总章数 × CHAPTER_SPAN = 该书所有行的 total_pages，否则要么
--    进度分母与页号量纲不一致（990 章算成 769%），要么 page_stat 视图按比例缩放页号。
-- ⚠️ 映射只做在落库层，内存页码保持真实值，否则翻页判定失效、时长全丢。

local M = {
    _mark = "_fanqie_stats_patch_v3",
}

-- 每章预留的虚拟页槽位（足够大，防止大字号把一章撑进下一章的页号段）
local CHAPTER_SPAN = 100

local ok_H, H = pcall(require, "fanqie.helper")
if not ok_H then H = nil end

local function is_str(s)
    return H and H.is_str and H.is_str(s) or type(s) == "string"
end

-- 判据与 patches/core.lua / state.lua 同源：按**结构**认番茄章节
-- （<cache_dir>/<book_id>/chapter_<item_id>.html），不依赖目录名里有没有 fanqie。
-- 🔴 上游用 `find('/fanqie/')`：用户把下载目录改到任何不含 fanqie 的路径后恒假，
--    统计合并会整条静默失效。
local function is_fanqie_path(file_path)
    if not is_str(file_path) or file_path == "" then return false end
    local normalized = file_path:gsub("\\", "/")
    if not normalized:match("/chapter_[^/]+%.html$") then return false end
    local parent = normalized:match("/([^/]+)/chapter_[^/]+%.html$")
    return parent ~= nil and #parent >= 6
        and parent:match("^[%w%._-]+$") ~= nil and parent:match("%d") ~= nil
end

-- 章节文件路径：<cache_dir>/<book_id>/chapter_<item_id>.html
local function book_id_from_path(file_path)
    if not is_str(file_path) then return nil end
    local normalized = file_path:gsub("\\", "/")
    local book_id = normalized:match("/([^/]+)/chapter_[^/]+%.html$")
    if not book_id or book_id == "" then return nil end
    return book_id
end

-- chapter_<item_id>.html → item_id
local function item_id_from_path(file_path)
    if not is_str(file_path) then return nil end
    local item_id = file_path:gsub("\\", "/"):match("/chapter_([^/]+)%.html$")
    if not item_id or item_id == "" then return nil end
    return item_id
end

-- 诊断日志：只在异常时记一次，避免翻页刷屏（WARN 级确保落盘）
local _diag_seen = {}
local function diag(key, msg)
    if _diag_seen[key] then return end
    _diag_seen[key] = true
    local ok, L = pcall(require, "fanqie.logger")
    if ok and type(L) == "table" and L.warn then
        pcall(L.warn, "[stats] " .. tostring(msg))
    end
end

-- 目录信息进程内缓存：目录文件可能几十 KB，别每次翻页都读
local _cat_cache = {}

-- 直接读目录文件（权威且完整）。刻意绕开 Content.load_catalog_cache 的
-- _state 内存缓存：那个缓存有 24h TTL，且可能是"部分目录"，会让章序号解析
-- 失败，统计随之退化成"只统计一章页数"。
local function read_catalog_file(settings, book_id)
    local ok_content, Content = pcall(require, "fanqie.content")
    if not ok_content or type(Content) ~= "table" or not Content.book_cache_dir then
        return nil
    end
    if not (H and H.join_path and H.file_exists) then return nil end
    local ok_dir, dir = pcall(Content.book_cache_dir, settings, book_id)
    if not ok_dir or not is_str(dir) then return nil end
    local path = H.join_path(dir, "catalog_cache.lua")
    if not H.file_exists(path) then return nil end
    local ok, catalog = pcall(dofile, path)
    if not ok or type(catalog) ~= "table" or #catalog == 0 then return nil end
    return catalog
end

local function build_catalog_info(catalog)
    local idx, by_title = {}, {}
    for i, ch in ipairs(catalog) do
        if type(ch) == "table" then
            local iid = tostring(ch.itemId or ch.item_id or "")
            if iid ~= "" and idx[iid] == nil then idx[iid] = i end
            local t = ch.title
            if is_str(t) and t ~= "" and by_title[t] == nil then by_title[t] = i end
        end
    end
    return { idx = idx, by_title = by_title, total = #catalog }
end

-- 返回 { idx = { [item_id] = 章序号 }, by_title, total }；拿不到返回 nil。
-- 传入 item_id 时若缓存里查不到，会强制重读目录文件（目录可能已被刷新）。
local function catalog_info(settings, book_id, item_id)
    if not book_id then return nil end
    book_id = tostring(book_id)
    local hit = _cat_cache[book_id]
    if hit and (not item_id or hit.idx[item_id]) then return hit end

    local catalog = read_catalog_file(settings, book_id)
    if not catalog then
        -- 文件读不到时退回 Content 的缓存（内存 / 文件）
        local ok_content, Content = pcall(require, "fanqie.content")
        if ok_content and type(Content) == "table" and Content.load_catalog_cache then
            local ok, c2 = pcall(Content.load_catalog_cache, settings, book_id)
            if ok and type(c2) == "table" and #c2 > 0 then catalog = c2 end
        end
    end
    if not catalog then return hit end

    local info = build_catalog_info(catalog)
    _cat_cache[book_id] = info
    return info
end

-- 章节文件标题缓存：chapter_<item_id>.html 头部有 <title>第N章 …</title>
local _title_cache = {}

local function read_html_title(file_path)
    if not is_str(file_path) then return nil end
    local cached = _title_cache[file_path]
    if cached ~= nil then return cached or nil end
    local title = nil
    local f = io and io.open and io.open(file_path, "r") or nil
    if f then
        local head = f:read(2048) or ""
        f:close()
        title = head:match("<title>%s*(.-)%s*</title>")
    end
    _title_cache[file_path] = title or false
    return title
end

-- 目录里匹配不到 item_id 时的兜底（目录刷新换了 ID / 章节已下架）：
-- 优先用章节标题在目录里按 title 反查章序号，再退化为解析"第N章"的 N。
function M.chapter_index_fallback(file_path, cat)
    local title = read_html_title(file_path)
    if not title or title == "" then return nil end
    if cat and cat.by_title and cat.by_title[title] then
        return cat.by_title[title]
    end
    local n = tonumber(title:match("第%s*(%d+)%s*[章回节]"))
    if n and n >= 1 then return n end
    return nil
end

-- 当前会话正在读的书（最可靠，含未落缓存的书）
local function current_session_book(book_id)
    local ok_state, _state = pcall(require, "fanqie.state")
    if not ok_state or type(_state) ~= "table" then return nil end
    local b = _state.current_book
    if type(b) ~= "table" then return nil end
    if tostring(b.book_id or b.bookId or "") ~= book_id then return nil end
    local title = b.title or b.book_name or b.name
    if not title or title == "" then return nil end
    return { title = title, author = b.author or b.author_name or "" }
end

-- 书架缓存里的书（冷启动直接打开章节文件时靠它）
local function shelf_book(book_id, settings)
    local ok_bs, Bookshelf = pcall(require, "fanqie.bookshelf")
    if not ok_bs or type(Bookshelf) ~= "table" or not Bookshelf.find_book_meta then return nil end
    local ok, meta = pcall(Bookshelf.find_book_meta, book_id, settings)
    if not ok or type(meta) ~= "table" then return nil end
    if not meta.title or meta.title == "" then return nil end
    return { title = meta.title, author = meta.author or "" }
end

-- 返回 { title, authors, md5, chapter_index, total_chapters }；
-- 确认不了书名时返回 nil（保持 KOReader 原行为）。
-- chapter_index / total_chapters 拿不到时为 nil，此时只合并身份、不动页数。
function M.resolve(file_path, settings)
    if not is_fanqie_path(file_path) then return nil end
    local book_id = book_id_from_path(file_path)
    if not book_id then
        diag("nbid", "无法从路径解析 book_id: " .. tostring(file_path))
        return nil
    end
    local book = current_session_book(book_id) or shelf_book(book_id, settings)
    if not book then
        diag("nbook:" .. book_id, "找不到书名元数据，统计不合并: " .. book_id)
        return nil
    end

    -- 作者兜底：书架 / 目录接口都不带作者，唯一可靠来源是书籍详情页
    -- （fanqie/book_meta.lua 抓取并缓存）。有缓存就直接用，没有先留 N/A，
    -- 由 main.lua 在文档就绪后异步抓取并回填统计库。
    local author = book.author
    if not author or author == "" then
        local ok_bm, BookMeta = pcall(require, "fanqie.book_meta")
        if ok_bm and type(BookMeta) == "table" and BookMeta.get_author then
            local ok_a, cached = pcall(BookMeta.get_author, settings, book_id)
            if ok_a and is_str(cached) and cached ~= "" then
                author = cached
            end
        end
    end

    local identity = {
        book_id = book_id,
        title = book.title,
        authors = (author and author ~= "") and author or "N/A",
        md5 = "fanqie-" .. book_id,
    }

    local item_id = item_id_from_path(file_path)
    local cat = catalog_info(settings, book_id, item_id)
    if cat then
        identity.total_chapters = cat.total
        identity.chapter_index = item_id and cat.idx[item_id] or nil
        if not identity.chapter_index then
            -- 目录里没有该 item_id：用章节标题兜底解析章序号，
            -- 避免退化成"不介入"而把 book.pages 写成本章页数。
            identity.chapter_index = M.chapter_index_fallback(file_path, cat)
            if not identity.chapter_index then
                diag("nidx:" .. book_id .. ":" .. tostring(item_id),
                    string.format("章序号未解析（目录 %d 条，item=%s）",
                        cat.total, tostring(item_id)))
            end
        end
    else
        diag("ncat:" .. book_id, "目录缓存不可用，页数统计不介入: " .. book_id)
    end
    return identity
end

-- statistics 实例：正常按插件名取；名字对不上时按特征在模块列表里兜底找
local function find_statistics(ui)
    local st = ui.statistics
    if type(st) == "table" and type(st.initData) == "function" then return st end
    for _, mod in ipairs(ui) do
        if type(mod) == "table" and type(mod.initData) == "function"
            and type(mod.getIdBookDB) == "function" then
            return mod
        end
    end
    return nil
end

-- 虚拟页号

-- 第 N 章第 P 页 → 全局唯一页号
function M.virtual_page(chapter_index, local_page)
    local n = math.floor(tonumber(chapter_index) or 1)
    local p = math.floor(tonumber(local_page) or 1)
    if n < 1 then n = 1 end
    if p < 1 then p = 1 end
    if p > CHAPTER_SPAN then p = CHAPTER_SPAN end -- 溢出保护：截断到本章段尾
    return (n - 1) * CHAPTER_SPAN + p
end

-- 把本会话的「章内页 → 时长列表」重映射到「虚拟页 → 时长列表」。
-- 时长原样保留，只是换页号，因此各章之间不再互相覆盖。
-- 返回 nil 表示没有可落库的数据。
function M.remap_page_stat(page_stat, chapter_index)
    if type(page_stat) ~= "table" or not chapter_index then return nil end
    local out, moved = {}, 0
    for local_page, data_list in pairs(page_stat) do
        if type(data_list) == "table" then
            local vp = M.virtual_page(chapter_index, local_page)
            local dst = out[vp]
            if not dst then dst = {}; out[vp] = dst end
            for _, tuple in ipairs(data_list) do
                if type(tuple) == "table" then
                    dst[#dst + 1] = tuple
                    moved = moved + 1
                end
            end
        end
    end
    if moved == 0 then return nil end
    return out
end

-- 全书虚拟总页数的落库读写：结果必须与 page_stat_data.total_pages 相等（见文件头 ⚠️）

local function with_db(fn)
    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then return nil end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or type(DataStorage) ~= "table" then return nil end
    local ok_path, path = pcall(DataStorage.getSettingsDir, DataStorage)
    if not ok_path or not is_str(path) then return nil end
    local ok, db = pcall(SQ3.open, path .. "/statistics.sqlite3")
    if not ok or not db then return nil end
    local r1, r2 = pcall(fn, db)
    pcall(db.close, db)
    if r1 then return r2 end
    return nil
end

-- 库里已落库的最大页号（目录缩水时用来兜底，避免进度 >100%）
local function max_page_in_db(id_book)
    if not id_book then return nil end
    return with_db(function(db)
        local ok, row = pcall(function()
            return db:rowexec(string.format(
                "SELECT max(page) FROM page_stat_data WHERE id_book = %d;", tonumber(id_book)))
        end)
        if not ok or type(row) ~= "table" then return nil end
        local v = tonumber(row[1])
        if v and v > 0 then return v end
        return nil
    end)
end

-- 让全书的历史记录与当前 book.pages 对齐，保证 page_stat 视图恒等映射
local function align_total_pages(id_book, v)
    if not id_book or not v then return end
    with_db(function(db)
        pcall(function()
            db:exec(string.format(
                "UPDATE page_stat_data SET total_pages = %d WHERE id_book = %d AND total_pages <> %d;",
                tonumber(v), tonumber(id_book), tonumber(v)))
        end)
    end)
end

-- 读取库里当前记录的全书页数（降级时保底用，绝不让它被本章页数覆盖）
function M.current_book_pages(id_book)
    if not id_book then return nil end
    return with_db(function(db)
        local ok, row = pcall(function()
            return db:rowexec(string.format(
                "SELECT pages FROM book WHERE id = %d;", tonumber(id_book)))
        end)
        if not ok or type(row) ~= "table" then return nil end
        local v = tonumber(row[1])
        if v and v > 0 then return v end
        return nil
    end)
end

-- 全书页数 = 总章数 × CHAPTER_SPAN，与 M.virtual_page 同一把尺子。
-- 只影响进度分母，不影响已读页数与时长。
function M.estimate_total_pages(id_book, total_chapters)
    local n = tonumber(total_chapters)
    if not n or n <= 0 then return nil end
    local v = n * CHAPTER_SPAN
    -- 目录条数变少（章节被删 / 目录只拉到一部分）时，历史页号可能已越过 v，
    -- 进度会 >100%，按库里最大页号向上取整补足。
    local maxp = max_page_in_db(id_book)
    if maxp and maxp > v then
        v = math.ceil(maxp / CHAPTER_SPAN) * CHAPTER_SPAN
    end
    return v
end

-- 安装补丁

-- 给当前文档（一个 ReaderUI 实例）的 statistics 实例安装身份 / 页数补丁。
-- 返回解析出的身份（table）表示"本文档是番茄章节且已知书名"；否则返回 nil。
function M.sync(ui, settings)
    if type(ui) ~= "table" then return nil end
    local file = ui.document and (ui.document.file or ui.document.path)
    local identity = M.resolve(file, settings)
    if not identity then return nil end

    -- statistics 插件可能未启用 / 不存在：此时不动，只返回身份供日志用
    local st = find_statistics(ui)
    if type(st) ~= "table" then return identity end
    if st[M._mark] then return identity end

    -- 计算并把身份 / 页数应用到一个 statistics 实例上（initData 与 insertDB 共用）
    local function apply(s, idn)
        -- 页数只依赖"全书章数"：章数可得就能恢复全书页数，
        -- 不再要求 chapter_index（它只用于页号 remap）。
        if not idn or not idn.total_chapters then return nil end
        local v = M.estimate_total_pages(s.id_curr_book, idn.total_chapters)
        if not v then return nil end
        if type(s.data) == "table" then s.data.pages = v end
        if s.id_curr_book then align_total_pages(s.id_curr_book, v) end
        return v
    end

    local orig_initData = st.initData
    st.initData = function(s)
        local props = type(s) == "table" and s.ui and s.ui.doc_props or nil
        local idn = nil
        if type(props) == "table" then
            local f = s.ui and s.ui.document and (s.ui.document.file or s.ui.document.path)
            idn = M.resolve(f, settings)
        end
        if not idn then return orig_initData(s) end
        -- 临时顶替：initData 内部从 doc_props 取书名 / 作者，从 self.doc_md5 取标识
        local saved_title, saved_authors = props.display_title, props.authors
        props.display_title = idn.title
        props.authors = idn.authors
        s.doc_md5 = idn.md5
        local ok, err = pcall(orig_initData, s)
        -- 还原：界面上的标题 / 作者仍是章节文件自己的
        props.display_title = saved_title
        props.authors = saved_authors
        if not ok then error(tostring(err), 0) end
        -- orig 内部把 pages 写成了本章页数，这里改成全书页数（id_curr_book 已有值）
        apply(s, idn)
    end

    -- 落库时把章内页号重映射成跨章唯一的虚拟页号。
    -- 必须在这一层做：内存里若把页码改掉，onPageUpdate 的翻页判定会失效，
    -- 阅读时长将全部丢失。
    local orig_insertDB = st.insertDB
    if type(orig_insertDB) == "function" then
        st.insertDB = function(s, updated_pagecount)
            local f = s.ui and s.ui.document and (s.ui.document.file or s.ui.document.path)
            local idn = M.resolve(f, settings)
            if not idn or not idn.chapter_index then
                -- 拿不到章序号时不能直接交给原生逻辑：它会把 book.pages 覆盖成
                -- "本章页数"，与历史 total_pages 不一致，page_stat 视图会按
                -- pages/total_pages 缩放页号，已读页数被压成一章的量。
                -- 这里保留库里已有的全书页数。
                local keep = M.current_book_pages(s.id_curr_book)
                if keep then
                    if type(s.data) == "table" then s.data.pages = keep end
                    align_total_pages(s.id_curr_book, keep)
                    return orig_insertDB(s, keep)
                end
                return orig_insertDB(s, updated_pagecount)
            end

            local v = apply(s, idn)
            local real_curr = s.curr_page
            local remapped = M.remap_page_stat(s.page_stat, idn.chapter_index)
            if remapped then
                s.page_stat = remapped
                s.curr_page = M.virtual_page(idn.chapter_index, real_curr)
            end
            -- 把全书页数作为 updated_pagecount 传进去，避免上游把
            -- book.pages 覆盖回"本章页数"（那样会破坏视图的恒等映射）
            local ok, err = pcall(orig_insertDB, s, v or updated_pagecount)

            -- 注意：orig 内部末尾会 resetVolatileStats() 清空 page_stat，
            -- 这里绝不能把落库前的旧 page_stat 还原回去（会重复入库）。
            -- 只把当前页重新播种（真实页码），保证后续翻页计时连续。
            s.curr_page = real_curr
            s.page_stat = {}
            if real_curr ~= nil then
                s.page_stat[real_curr] = { { os.time(), 0 } }
            end
            if not ok then error(tostring(err), 0) end
        end
    end

    st[M._mark] = true

    -- 插件注册顺序不保证：若 statistics 的 onReaderReady 已经先跑过，
    -- 用新身份重跑一次 initData，让 id_curr_book 指向合并后的那条记录。
    if st.id_curr_book ~= nil then
        pcall(function() st:initData() end)
    end
    return identity
end

return M
