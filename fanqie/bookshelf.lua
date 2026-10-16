local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
-- T 必须是 util.template（%1/%2 占位符）。定义成 _ 的话占位符**原样显示**
-- （书城标题出现「共 %1 本」、错误提示出现「%1」——实测踩中）。
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

local H = require("fanqie.helper")
local Log = require("fanqie.logger")
local FanQie = require("fanqie.fanqie")
local ok_Async, Async = pcall(require, "fanqie.async")
local State = require("fanqie.state")
-- 注：排序（settings.shelf.sort_order）已移到显示层 shelf_view.lua，本模块不读排序。
-- 注：v2.16.0 起本模块**又**需要 fanqie.state 了 —— 只用它的「书架状态快照」
--     （setShelfAll / clearShelfAll）。阅读端菜单文案（「加入书架」/「移出书架」）
--     与「退出阅读时是否提示加入书架」都必须在 UI 线程**同步**判断，而这个判断
--     既不能打 shelf_check（网络），也不能走 get_shelf（未命中短缓存时阻塞发包）
--     ⇒ 快照必须在书架数据的读写点维护（见 state.lua 的同名小节）。
-- 注：本模块已不再直接弹 Menu / InfoMessage / InputDialog，也不再读 content 缓存，
-- 相关 require 随死代码一并移除（那些 UI 由 main.lua 的同名方法负责）。

-- ===== 书架内存缓存：内存主源 + 文件后备 =====
-- 存精简后的 books 数组（与 shelf_cache.lua 同构）。
-- 与 client.lua 的 SHELF_CACHE 职责区分：
--   - SHELF_MEM_CACHE（本变量）：显示层数据源，进程生命周期内有效，无 TTL
--   - SHELF_CACHE（client.lua）：fetch_shelf_detail 内部短缓存，按 cookie_hash 做 key，
--     10 分钟 TTL，避免短时间内重复网络请求
local SHELF_MEM_CACHE = nil

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    if type(err) == "table" and err.auth_expired == true then
        return _("Cookie 已过期，请重新配置")
    end
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

-- 书架持久化缓存：存为 Lua table 文件，离线时直接读
local function get_shelf_cache_path(settings)
    local cache_dir = settings and settings.get_download_dir and settings:get_download_dir() or ""
    if cache_dir == "" then cache_dir = "./fanqie_cache" end
    H.make_dir(cache_dir)
    return cache_dir .. "/shelf_cache.lua"
end

-- 浅拷贝 books 数组（仅数组层）：避免显示层 build_items/sort_books 的原地排序
-- 污染内存缓存的原始顺序。内部 book 对象仍共享引用，封面下载（main.lua 的
-- _preloadAllCovers / _cacheShelfPageCovers）写入的 cover_path 会影响缓存中的
-- book 对象，但该污染无害（有益——跳过重复下载）。
local function shallow_copy_books(books)
    local copy = {}
    for i, b in ipairs(books) do
        copy[i] = b
    end
    return copy
end

local function save_shelf_cache(settings, books)
    if not settings or not books or type(books) ~= "table" then return end
    -- 写内存缓存（浅拷贝：调用方后续的 do_sort/showBookList 会原地修改 books，
    -- 存浅拷贝保持内存缓存的原始顺序不被污染）
    SHELF_MEM_CACHE = shallow_copy_books(books)
    -- 同步重建「书架状态快照」（阅读端菜单文案 / 退出提示要同步查，见 state.lua）。
    -- ⚠️ 这一句是**快照的唯一权威写入口**：书架列表拿到了 ⇒ 「不在表里」才等于不在架。
    State.setShelfAll(books)
    -- 写文件缓存（持久化后备）
    local path = get_shelf_cache_path(settings)
    local lines = { "return {" }
    for i, b in ipairs(books) do
        local parts = {}
        for k, v in pairs(b) do
            if type(v) == "string" then
                -- 完整转义：\ " \n \r \t，避免书名含特殊字符导致缓存文件语法错误
                local escaped = v:gsub("\\", "\\\\")
                    :gsub('"', '\\"')
                    :gsub("\n", "\\n")
                    :gsub("\r", "\\r")
                    :gsub("\t", "\\t")
                table.insert(parts, string.format('%s="%s"', k, escaped))
            elseif type(v) == "number" then
                table.insert(parts, string.format('%s=%s', k, tostring(v)))
            elseif type(v) == "boolean" then
                table.insert(parts, string.format('%s=%s', k, tostring(v)))
            end
        end
        table.insert(lines, "  {" .. table.concat(parts, ",") .. "},")
    end
    table.insert(lines, "}")
    local f = io.open(path, "w")
    if f then
        f:write(table.concat(lines, "\n"))
        f:close()
        Log.info("shelf cache saved: " .. tostring(#books) .. " books to " .. path)
    else
        Log.warn("shelf cache save failed: cannot open " .. path)
    end
end

-- 书架缓存读取：内存主源 + 文件后备 + 回填
-- 优先查内存缓存，命中直接返回，避免文件 IO；
-- 未命中时读文件缓存，并回填内存，后续读取全部走内存。
-- 返回浅拷贝：避免调用方 do_sort/showBookList 的 table.sort 原地排序污染内存缓存。
local function load_shelf_cache(settings)
    -- 1. 先查内存缓存
    if SHELF_MEM_CACHE and #SHELF_MEM_CACHE > 0 then
        return shallow_copy_books(SHELF_MEM_CACHE)
    end
    -- 2. 未命中：读文件缓存
    local path = get_shelf_cache_path(settings)
    if not H.file_exists(path) then
        Log.info("shelf cache: file not found at " .. path)
        return nil
    end
    local ok, data = pcall(function()
        local chunk, err = loadfile(path)
        if not chunk then
            Log.warn("shelf cache loadfile failed: " .. tostring(err))
            return nil
        end
        return chunk()
    end)
    if ok and type(data) == "table" and #data > 0 then
        Log.info("shelf cache loaded: " .. tostring(#data) .. " books")
        -- 3. 回填内存缓存（存原始引用，调用方拿到的是浅拷贝不会污染 data）
        SHELF_MEM_CACHE = data
        -- 文件后备同样是一份**完整**书架列表 ⇒ 同步重建快照（冷启动离线也能判方向）
        State.setShelfAll(data)
        return shallow_copy_books(data)
    end
    if not ok then
        Log.warn("shelf cache pcall failed: " .. tostring(data))
    end
    return nil
end

local Bookshelf = {}

-- 清除书架缓存：三层同步清理
--   1. SHELF_MEM_CACHE（显示层内存缓存）
--   2. client.SHELF_CACHE（API 短缓存）
--   3. shelf_cache.lua（文件缓存）
function Bookshelf:clearShelfCache()
    -- 1. 清显示层内存缓存
    SHELF_MEM_CACHE = nil
    -- 2. 清 client 的 API 短缓存
    if self.client and self.client.clear_shelf_cache then
        self.client:clear_shelf_cache()
    end
    -- 3. 删文件缓存
    local path = get_shelf_cache_path(self.settings)
    if H.file_exists(path) then
        os.remove(path)
        Log.info("shelf cache file deleted: " .. path)
    end
    -- 4. 完整快照跟着失效（「书架列表」这份证据已经没了）。
    --    ⚠️ 只清 shelf_all：刚加入/移出那本书的确定结论在 shelf_known 里，
    --       那是本次操作的直接结果，比过期的书架表更可信。
    if State and State.clearShelfAll then State.clearShelfAll() end
end

--- 把书架状态快照补到可用（**纯同步**：内存 → 本地文件缓存，绝不联网）。
--
-- 🔴 为什么需要它：冷启动续读时用户可能从没打开过书架列表，此时快照是「未知」，
--    而「未知」不能拿来决定按钮文案的方向、更不能拿来弹「加入书架」的提示。
--    本方法把「曾经缓存过的书架列表」读回来（一次本地文件读），让绝大多数场景
--    在**不发网络请求**的前提下就能得到确定答案。
-- ⚠️ 幂等：已经有完整快照就直接返回。也**不能**退化成 get_shelf —— 那是网络路径，
--    放在这里会把「同步判断」变成「同步阻塞发包」。
function Bookshelf:ensureShelfSnapshot()
    if State.hasShelfAll() then return end
    if not self.settings then return end
    local ok, books = pcall(load_shelf_cache, self.settings)
    if ok and type(books) == "table" then
        State.setShelfAll(books)
    end
end

--- 从**本地**书架缓存里找一本书的完整记录（零网络）。
--
-- 用途：阅读界面的「书籍信息」在「重启后从最近阅读/文件管理器直接打开章节续读」
-- 时拿不到 `_state.current_book`（它不持久化），只有从文档路径反推出来的书号。
-- 这时用本地书架缓存把书名/作者/简介/进度补齐 —— 和 ensureShelfSnapshot 一样
-- **绝不联网**：网络往返会让菜单卡住，而本地文件（或内存缓存）命中是零成本的。
-- @return table|nil 命中返回原始记录（调用方只读，不要就地改）
function Bookshelf:findCachedBook(book_id)
    if not book_id or not self.settings then return nil end
    local want = tostring(book_id)
    local ok, books = pcall(load_shelf_cache, self.settings)
    if not ok or type(books) ~= "table" then return nil end
    for _i, b in ipairs(books) do
        if type(b) == "table" and tostring(b.book_id) == want then
            return b
        end
    end
    return nil
end

function Bookshelf:showBookshelf(opts)
    opts = opts or {}
    local force_refresh = opts.force_refresh == true

    if not self.patches_ok then
        local Patches = require("patches.core")
        Patches.install()
        self.patches_ok = true
    end

    -- 排序已移到显示层（fanqie/shelf_view.lua 的 build_items → sort_books）：
    -- 排序键/方向持久化在 settings.shelf，缓存里始终保持接口原始顺序，
    -- 切换排序只需原地重刷列表、且不会污染缓存。
    -- （旧实现在这里读 _state.shelf_sort_type，而该字段全仓从未被赋值，
    --   且比较用的 added_time / last_read_time 也从未写入 → 排序恒不生效。已删。）

    -- 回退到文件缓存（force_refresh 获取失败时使用）
    local function fallback_to_cache()
        local cached = load_shelf_cache(self.settings)
        if cached and #cached > 0 then
            self:showBookList(cached)
            return true
        end
        return false
    end

    -- 非强制刷新：优先显示本地缓存，有网后台刷新
    if not force_refresh then
        local cached_shelf = load_shelf_cache(self.settings)
        if cached_shelf and #cached_shelf > 0 then
            self:showBookList(cached_shelf)
            -- 后台异步刷新
            if self:checkNetwork() then
                self:showBusy(_("正在刷新书架..."))
                local plugin = self
                if ok_Async and Async then
                    Async.run(function()
                        return plugin:get_shelf()
                    end, function(ok, result, err)
                        plugin:closeBusy()
                        if ok and type(result) == "table" and #result > 0 then
                            save_shelf_cache(plugin.settings, result)
                            plugin:showBookList(result)
                        end
                    end, {
                        poll_interval = 0.3, timeout = 60,
                        tag = "shelf",
                        -- 取消（退出 KOReader）后 on_done 不再执行，
                        -- busy 对话框必须在这里关掉，否则墨水屏上永久卡在 loading。
                        on_cancel = function() plugin:closeBusy() end,
                    })
                end
            end
            return
        end
    end

    -- force_refresh 或无缓存：直接从网络获取
    -- 获取成功后 save_shelf_cache 覆盖旧缓存；失败时回退到旧缓存
    if not self:checkNetwork() then
        if force_refresh and fallback_to_cache() then
            self:showInfo(_("无网络，显示缓存数据"))
            return
        end
        self:showError(_("无网络且无书架缓存，请先联网获取书架"))
        return
    end

    self:showBusy(force_refresh and _("正在刷新书架...") or _("正在获取书架..."))
    local plugin = self
    if ok_Async and Async then
        Async.run(function()
            -- force_refresh=true 跳过 client 内存缓存，从网络获取
            return plugin:get_shelf(force_refresh)
        end, function(ok, result, err)
            plugin:closeBusy()
            if not ok or type(result) ~= "table" then
                Log.error("fetch shelf failed:", log_error(err or result))
                -- 获取失败：回退到旧缓存，不删除任何数据
                if force_refresh and fallback_to_cache() then
                    plugin:showInfo(_("刷新失败，显示缓存数据"))
                    return
                end
                plugin:showError(T(_("获取书架失败:\n%1"), display_error(err or result)))
                return
            end
            Log.debug("shelf fetched:", #result, "books")
            if not result or #result == 0 then
                -- 空结果可能是 cookie 过期，回退到旧缓存
                if force_refresh and fallback_to_cache() then
                    plugin:showInfo(_("获取数据为空，显示缓存数据"))
                    return
                end
                plugin:showInfo(_("书架为空，请先在番茄小说App中添加书籍"))
                return
            end

            -- 获取成功：覆盖旧缓存
            save_shelf_cache(plugin.settings, result)
            plugin:showBookList(result)
        end, {
            poll_interval = 0.3, timeout = 60,
            tag = "shelf",
            on_cancel = function() plugin:closeBusy() end,
        })
    else
        -- Async 模块不可用时降级为同步
        local ok, result = pcall(function()
            return self:get_shelf()
        end)
        self:closeBusy()
        if not ok then
            Log.error("fetch shelf failed:", log_error(result))
            self:showError(T(_("获取书架失败:\n%1"), display_error(result)))
            return
        end
        Log.debug("shelf fetched:", #result, "books")
        if not result or #result == 0 then
            self:showInfo(_("书架为空，请先在番茄小说App中添加书籍"))
            return
        end

        save_shelf_cache(self.settings, result)
        self:showBookList(result)
    end
end

function Bookshelf:get_shelf(force_refresh)
    Log.debug("fetching shelf from API" .. (force_refresh and " (force refresh)" or ""))
    local result = self.client:fetch_shelf_detail(force_refresh)
    
    local books = {}
    local shelf = nil
    if result and type(result.data) == "table" then
        shelf = result.data.detail_list or result.data.book_shelf_info or result.data.bookShelfInfo
        if not shelf then
            local count = 0
            for _ in pairs(result.data) do count = count + 1 end
            if count > 0 and result.data[1] then
                shelf = result.data
            end
        end
    end
    if type(shelf) == "table" then
        for _, item in ipairs(shelf) do
            local total_chapters = tonumber(item.serial_count or item.total_chapters or 0)
            local read_chapters = tonumber(item.real_chapter_order or item.index or 0)
            local progress = 0
            if total_chapters and total_chapters > 0 then
                progress = read_chapters / total_chapters
            elseif item.read_progress then
                progress = tonumber(item.read_progress) / 10000
            end
            -- 封面：接口给的是**签名** URL（x-expires 只到次日，过期回源 403），
            -- 经 FanQie.mobile_cover 收敛成无签名 CDN 地址（幂等）。
            -- 注意 Lua 里 "" 是 truthy，不能只靠 `or` 兜底 —— 空串会把后面的候选
            -- 字段整个吃掉，所以逐个挑「非空字符串」。
            local raw_cover = item.thumb_url
            if type(raw_cover) ~= "string" or raw_cover == "" then raw_cover = item.thumb_uri end
            if type(raw_cover) ~= "string" or raw_cover == "" then raw_cover = item.coverUrl end
            if type(raw_cover) ~= "string" or raw_cover == "" then raw_cover = item.cover end
            if type(raw_cover) ~= "string" or raw_cover == "" then raw_cover = item.cover_url end
            local book = {
                book_id = item.book_id or item.bookId or item.id,
                title = item.book_name or item.title or item.name or "未知",
                author = item.author_name or item.author or "",
                cover = FanQie.mobile_cover(raw_cover),
                desc = item.description or item.desc or item.abstract or "",
                progress = progress,
                item_id = item.item_id or item.itemId,
                total_chapters = total_chapters,
                read_chapters = read_chapters,
                -- 书架排序用（见 shelf_view.sort_books）：
                --   read_timestamp 服务端给的最后阅读时间（unix 秒，来自 /api/reader/book/progress）
                --   shelf_index    book_shelf_info 原始顺序 = 加入书架顺序
                read_timestamp = tonumber(item.read_timestamp) or 0,
                shelf_index = tonumber(item.shelf_index),
                -- ↓ 以下字段供「书籍详情页」用（v2.12.0）。全部来自
                --   POST /api/bookshelf/multidetail 的 detail_list 与
                --   GET  /reading/bookapi/bookshelf/info 的 book_shelf_info
                --   （两条在 client:fetch_shelf_detail 里已按 book_id 合并）。
                --   不在这里归一，详情页就还得再打一次网络 —— 书架列表本来就
                --   已经把 multidetail 拉回来了，白扔掉才是浪费。
                abstract = item.abstract or "",
                serial_count = total_chapters,
                real_chapter_order = tonumber(item.real_chapter_order) or 0,
                creation_status = tonumber(item.creation_status),
                update_status = tonumber(item.update_status),
                update_stop = tonumber(item.update_stop),
                last_chapter_update_time = tonumber(item.last_chapter_update_time) or 0,
                last_chapter_item_id = item.last_chapter_item_id,
                latest_read_item_id = item.latest_read_item_id,
                item_show_title = item.item_show_title,
                item_abstract = item.item_abstract,
                add_shelf_time = tonumber(item.add_shelf_time) or 0,
                last_operate_time = tonumber(item.last_operate_time) or 0,
                asterisked = item.asterisked == true,
                -- =1 表示图集/漫画（正文章节是整页大图序列）。阅读时用它把
                -- 「整章几十页大图、要等一会儿」讲清楚（见 main.lua:openChapter）。
                book_type = tonumber(item.book_type),
            }
            if book.book_id then
                table.insert(books, book)
            end
        end
    end
    return books
end

-- ⚠️ 本模块只保留 main.lua **未定义**的公共方法（由 main.lua 的白名单 mixin 拷入
-- FanQiePlugin）。此前这里还有 showBookList / showBookDetail / showChapterListing /
-- showJumpToChapter / _displayChapterListing / download_covers / downloadBook 七份实现，
-- 但它们全被 main.lua 的同名方法覆盖 → 永不执行（其中 download_covers 与
-- _displayChapterListing 还是同步阻塞版，是个随时会被误启用的地雷），已整体移除。
-- 新增公共方法请同步登记到 main.lua 的 BOOKSHELF_MIXIN 白名单。
return Bookshelf
