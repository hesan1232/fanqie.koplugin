--[[--
书籍详情：把「书架接口 + 详情接口 + 阅读进度接口」按 book_id 合并成一份展示数据。

为什么单独一层：三个接口各给一部分字段，谁都不知道全貌；
  * GET  /reading/bookapi/bookshelf/info   → 书架侧（add_shelf_time /
    last_operate_time / asterisked / book_type）——**只有已在书架的书才有**
  * POST /api/bookshelf/multidetail        → 书目侧（book_name / abstract /
    thumb_url / serial_count / creation_status / update_status / update_stop /
    last_chapter_update_time / last_chapter_item_id / item_show_title /
    item_abstract / real_chapter_order）
  * GET  /api/reader/book/progress         → 进度侧（item_id / index /
    read_timestamp / read_progress）
本模块只做「合并 + 纯函数格式化」，不发任何请求（IO 在 client/bookshelf 里）。

🔴 **multidetail 的 `item_show_title` / `item_abstract` 跟着请求里的 `item_id` 走**
（2026-10-14 实测：同一本书分别传 item_id="0" / 第1章 / 第2章 / 第51章的 id，
返回的 title/abstract 逐一对应）。所以：
  * 想看「最近阅读章节」→ 请求时必须传**进度里的 item_id**（bookshelf.lua 就是这么做的）；
  * 传 "0" 时它给的是**第 1 章**，把它当「最近阅读」是错的
    （用户最初的困惑就出在这儿 —— 不是接口只能给第 1 章，是参数没给对）。
  * 章节正文（item_abstract）会随章节变长，只截前 N 字展示。

🔴 **multidetail 只返回「已在书架」的书**（实测：请求 3 本、其中 2 本在架
→ 只回 2 条；单独请求 1 本不在架的书 → `detail_list` 为空数组，code 仍是 0）。
未登录 → `{"code":-1,"message":"请先登录"}`。
所以书城（未加书架）的书拿不到这批字段 —— 详情页要如实降级，不能编。

@module fanqie.book_detail
--]]

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
-- T 必须是 util.template（%1/%2 占位符）；定义成 _ 会让占位符原样显示。
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

local BookDetail = {}

-- 连载中但超过这个天数没更新 → 文案降级为「疑似断更」（用户给定口径）
BookDetail.STALE_DAYS = 60

-- 服务端枚举（原始值都是**字符串**，比较时一律 tonumber）
BookDetail.CREATION_STATUS = { finished = 0, ongoing = 1 }   -- 0 完结 / 1 连载
BookDetail.UPDATE_STATUS   = { stopped = 0, normal = 1 }     -- 0 停更 / 1 正常
BookDetail.UPDATE_STOP     = { normal = 0, stopped = 1, finished = 2 } -- 0 正常 / 1 断更 / 2 完结

local function num(v)
    if v == nil then return nil end
    local n = tonumber(v)
    return n
end

--- 更新状态组合判断（**组合**，不能只看一个字段）。
-- 口径（用户给定，2026-10-14）：
--   creation_status == 0            → 已完结
--   update_stop     == 2            → 已完结/停止更新
--   update_stop     == 1 或 update_status == 0 → 断更/停更
--   creation_status == 1 且 update_status == 1 且 update_stop == 0
--         → 距今 > STALE_DAYS 天没更新则「疑似断更」，否则「连载中」
--   其余 → 未知
-- ⚠️ `now` 可注入（测试用）；缺省取 os.time()。
-- ⚠️ last_chapter_update_time 缺失/为 0 时**不**判「疑似断更」
--    （没有时间就不该猜），直接算「连载中」。
-- @param d table 含 creation_status / update_status / update_stop / last_chapter_update_time
-- @return string 展示文案
function BookDetail.update_status_label(d, now)
    d = type(d) == "table" and d or {}
    local cs  = num(d.creation_status)
    local us  = num(d.update_status)
    local ust = num(d.update_stop)

    if cs == BookDetail.CREATION_STATUS.finished then
        return _("已完结")
    end
    if ust == BookDetail.UPDATE_STOP.finished then
        return _("已完结（停止更新）")
    end
    if ust == BookDetail.UPDATE_STOP.stopped
        or us == BookDetail.UPDATE_STATUS.stopped then
        return _("断更")
    end
    if cs == BookDetail.CREATION_STATUS.ongoing
        and us == BookDetail.UPDATE_STATUS.normal
        and ust == BookDetail.UPDATE_STOP.normal then
        local last = num(d.last_chapter_update_time)
        now = tonumber(now) or os.time()
        if last and last > 0 and now - last > BookDetail.STALE_DAYS * 86400 then
            return _("疑似断更")
        end
        return _("连载中")
    end
    return _("未知")
end

--- 剩余未读章数 = 总章数 − 已读章数（没读过就整本未读）。
-- 已读章数优先 `real_chapter_order`（multidetail 直接给的「读到第几章」）；
-- 拿不到时用 read_progress（服务端算的万分比整书进度）× 总章数**估算**。
-- 🔴 进度接口的 index 不能当已读章数（2026-10-26 实测：89 条里 74 条恒 0，
--    同一本书 item_id 不变 index 也会从 51 漂到 0）—— 旧版拿它兜底，
--    有阅读进度的书会显示「整本未读」。
-- @return number, boolean 剩余未读, 是否有已读记录
function BookDetail.unread_count(serial_count, real_chapter_order, read_progress)
    local total = num(serial_count) or 0
    local read = num(real_chapter_order)
    if not read or read <= 0 then
        local rp = num(read_progress)
        if rp and rp > 0 and total > 0 then
            read = math.floor(rp / 10000 * total + 0.5)
            if read < 1 then read = 1 end
            if read > total then read = total end
        end
    end
    local has_read = (read ~= nil and read > 0)
    if total <= 0 then return 0, has_read end
    local left = total - (read or 0)
    if left < 0 then left = 0 end
    return left, has_read
end

--- /reading/reader/recommend/book/ 的单条 ApiBookInfo → 详情框可用的书记录。
-- 🔴 字段名是 snake_case（实测 2026-10-26，.workbuddy/tools/_probe_related_book.py）：
--    book_id / book_name / book_abstract_v2 / word_number / creation_status…
--    thumb_url 是签名 HEIC（墨水屏不渲染封面，不取）。
-- @param item table ApiBookInfo（可为 nil）
-- @return table|nil { book_id, title, book_name, author, abstract, serial_status, meta }
function BookDetail.related_item(item)
    if type(item) ~= "table" then return nil end
    local book_id = tostring(item.book_id or "")
    if book_id == "" then return nil end
    local title = item.book_name or item.book_short_name
    if type(title) ~= "string" or title == "" then return nil end

    -- 状态：creationStatus 0=完结 1=连载（报告 §7.1）
    local cs = tonumber(item.creation_status)
    local status = (cs == 1 and _("连载中")) or (cs == 0 and _("已完结")) or nil

    -- meta 短行：作者 · 分类 · 字数 · 评分 · 状态（空的跳过）
    local meta = {}
    local function push(v) 
        if type(v) == "string" and v ~= "" then meta[#meta + 1] = v end
    end
    push(item.author)
    push(item.category)
    local wn = tonumber(item.word_number) or 0
    if wn >= 10000 then
        meta[#meta + 1] = string.format("%.1f%s", wn / 10000, _("万字"))
    elseif wn > 0 then
        meta[#meta + 1] = string.format("%d%s", wn, _("字"))
    end
    if type(item.score) == "string" and item.score ~= "" then
        meta[#meta + 1] = T(_("评分 %1"), item.score)
    end
    push(status)
    -- 排除自身（调用方再按 book_id 兜一道，这里只管单条归一）

    return {
        book_id = book_id,
        title = title,
        book_name = title,
        author = item.author,
        abstract = item.book_abstract_v2 or item.abstract or item.book_abstract,
        serial_status = status,
        meta = table.concat(meta, " · "),
    }
end

--- 推荐列表 → Menu 条目数组（排除基准书自己；全被排除 → 空数组）。
-- @param list table ApiBookInfo 数组
-- @param exclude_book_id string|nil 基准书 ID（推荐里常含同书）
-- @return table { { book=记录, text=书名, mandatory=meta } … }
function BookDetail.related_rows(list, exclude_book_id)
    local out = {}
    if type(list) ~= "table" then return out end
    local want = exclude_book_id and tostring(exclude_book_id) or nil
    for _i, item in ipairs(list) do
        local rec = BookDetail.related_item(item)
        if rec and rec.book_id ~= want then
            out[#out + 1] = {
                book = rec,
                text = rec.title,
                mandatory = rec.meta,
            }
        end
    end
    return out
end

--- unix 秒 → "YYYY-MM-DD HH:MM"；<=0 / nil / 非法 → nil（调用方据此跳过该行）
function BookDetail.fmt_datetime(ts)
    local n = num(ts)
    if not n or n <= 0 then return nil end
    local ok, s = pcall(os.date, "%Y-%m-%d %H:%M", n)
    if not ok or not s then return nil end
    return s
end

--- unix 秒 → "YYYY-MM-DD"
function BookDetail.fmt_date(ts)
    local n = num(ts)
    if not n or n <= 0 then return nil end
    local ok, s = pcall(os.date, "%Y-%m-%d", n)
    if not ok or not s then return nil end
    return s
end

--- 从 multidetail 响应里取某本书的明细（纯函数，便于回归）。
-- @return table|nil
function BookDetail.pick_detail(resp, book_id)
    local list = type(resp) == "table"
        and type(resp.data) == "table"
        and type(resp.data.detail_list) == "table"
        and resp.data.detail_list or nil
    if not list then return nil end
    local want = tostring(book_id)
    for _i, d in ipairs(list) do
        if type(d) == "table" and tostring(d.book_id) == want then
            return d
        end
    end
    return nil
end

--- 从 bookshelf/info 响应里取某本书的书架侧元数据（纯函数）。
-- @return table|nil
function BookDetail.pick_shelf_meta(resp, book_id)
    local list = type(resp) == "table"
        and type(resp.data) == "table"
        and (resp.data.book_shelf_info or resp.data.bookShelfInfo) or nil
    if type(list) ~= "table" then return nil end
    local want = tostring(book_id)
    for _i, it in ipairs(list) do
        if type(it) == "table" and tostring(it.book_id) == want then
            return it
        end
    end
    return nil
end

--- 从 /api/reader/book/progress 响应里取某本书的进度（纯函数）。
-- @return table|nil
function BookDetail.pick_progress(resp, book_id)
    local list = type(resp) == "table" and type(resp.data) == "table" and resp.data or nil
    if type(list) ~= "table" then return nil end
    local want = tostring(book_id)
    for _i, it in ipairs(list) do
        if type(it) == "table" and tostring(it.book_id) == want then
            return it
        end
    end
    return nil
end

-- 简介/章节摘要的展示上限（字符）。TextViewer 能滚动，但一屏塞 3000 字
-- 意义不大；这里只防「整页只有一段简介」。
BookDetail.ABSTRACT_MAX = 1200
BookDetail.ITEM_ABSTRACT_MAX = 300

local function clip(s, max)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    if #s > max then
        -- 🔴 Lua 的 `#s` / `sub` 都是**按字节**的 ⇒ 直接 `s:sub(1, max)` 会把
        --    多字节字符（中文 3 字节）拦腰砍断，TextViewer 里显示成乱码方块。
        --    这里把切点回退到 UTF-8 字符边界（0x80~0xBF 是续接字节）。
        local cut = max
        while cut > 0 do
            local b = s:byte(cut + 1)
            if b and b >= 0x80 and b < 0xC0 then cut = cut - 1 else break end
        end
        return s:sub(1, cut) .. "…"
    end
    return s
end

--- 组装「书籍详情页」的正文行（纯函数，无 IO）。
--
-- `book` 出一条**统一形状**的记录即可 —— 书架记录（bookshelf.lua）与
-- 书城列表项（store.lua normalize）都能喂进来，靠下面的别名兜底：
--   title / book_name            书名
--   author / author_name         作者
--   abstract / desc              简介全文
--   serial_count / total_chapters 总章数
--   real_chapter_order / read_chapters  已读章数
--   item_show_title              最近阅读章节标题（= 请求时传了进度 item_id 的结果）
--   item_abstract                最近阅读章节正文摘要
--   latest_read_item_id          "0" / nil = 无阅读记录
--   last_chapter_update_time / update_time 最后更新时间
--   add_shelf_time / last_operate_time     书架侧时间
--   read_timestamp               上次阅读时间（进度接口）
--   cover / thumb_url            封面（不渲染，仅用于存在性判断）
--
-- @param book table
-- @param opts table|nil { now=number, cache_count=number, max_abstract=number }
-- @return table 行数组（string），已剔除空行
function BookDetail.lines(book, opts)
    opts = opts or {}
    if type(book) ~= "table" then return {} end
    local out = {}
    local function push(label, value)
        if value == nil then return end
        if type(value) == "string" and value == "" then return end
        out[#out + 1] = label .. tostring(value)
    end

    local title = book.title or book.book_name
    push(_("书名："), title)
    push(_("作者："), book.author or book.author_name)
    local cat = book.category
    push(_("分类："), cat)
    if book.word_count then
        local wc = tonumber(book.word_count)
        if wc and wc > 0 then
            push(_("字数："), T(_("%1 万字"), string.format("%.1f", wc / 10000)))
        elseif type(book.word_count) == "string" then
            -- 书库接口的字数是**PUA 解码后的展示串**（「7935字」），原样用
            push(_("字数："), book.word_count)
        end
    end
    if book.read_count ~= nil then
        local rc = tonumber(book.read_count)
        if rc and rc > 0 then
            push(_("阅读："), T(_("%1 人在读"), tostring(rc)))
        elseif type(book.read_count) == "string" and book.read_count ~= "" then
            push(_("阅读："), book.read_count)
        end
    end

    push(_("状态："), BookDetail.update_status_label(book, opts.now))

    local serial = tonumber(book.serial_count) or tonumber(book.total_chapters)
    if serial and serial > 0 then
        push(_("总章数："), T(_("%1 章"), tostring(serial)))
    end

    local last_up = book.last_chapter_update_time
    if last_up == nil or tonumber(last_up) == 0 then last_up = book.update_time end
    local up_text = BookDetail.fmt_datetime(last_up)
    if up_text then push(_("最新更新："), up_text) end

    push(_("最新章节："), book.latest_chapter or book.last_chapter_title)

    -- 最近阅读：只有「有阅读记录」时才显示章节标题。
    -- ⚠️ item_show_title 在没传进度 item_id 时是**第 1 章**，不能当最近阅读。
    local read_order = tonumber(book.real_chapter_order) or tonumber(book.read_chapters)
    local progress_item = book.latest_read_item_id
    local has_read = (read_order and read_order > 0)
        or (progress_item ~= nil and tostring(progress_item) ~= ""
            and tostring(progress_item) ~= "0")
        or (tonumber(book.read_timestamp) or 0) > 0
    if has_read then
        push(_("最近阅读："), book.item_show_title)
        push(_("本章摘要："), clip(book.item_abstract, tonumber(opts.max_item_abstract)
            or BookDetail.ITEM_ABSTRACT_MAX))
    else
        push(_("最近阅读："), _("暂无阅读记录"))
    end

    local left = BookDetail.unread_count(
        serial, book.real_chapter_order or book.read_chapters, book.read_progress)
    if serial and serial > 0 then
        push(_("剩余未读："), T(_("%1 章"), tostring(left)))
    end

    local add_t = BookDetail.fmt_date(book.add_shelf_time)
    if add_t then push(_("加入书架："), add_t) end
    local read_t = BookDetail.fmt_datetime(book.read_timestamp)
    if read_t then push(_("上次阅读："), read_t) end
    local op_t = BookDetail.fmt_datetime(book.last_operate_time)
    if op_t then push(_("上次操作："), op_t) end
    if book.asterisked == true then push(_("星标："), _("已加星")) end

    local cache = tonumber(opts.cache_count)
    if cache and cache > 0 then
        push(_("本地缓存："), T(_("%1 章"), tostring(cache)))
    end

    local abstract = clip(book.abstract or book.desc,
        tonumber(opts.max_abstract) or BookDetail.ABSTRACT_MAX)
    if abstract then
        out[#out + 1] = ""
        out[#out + 1] = _("【简介】")
        out[#out + 1] = abstract
    end
    return out
end

--- 详情框「标题」用的一行摘要（ButtonDialog 只画 title，没有 info_text 字段）。
function BookDetail.summary_title(book, opts)
    opts = opts or {}
    if type(book) ~= "table" then return _("书籍详情") end
    local parts = {}
    parts[#parts + 1] = tostring(book.title or book.book_name or _("未知"))
    local author = book.author or book.author_name
    if author and author ~= "" then
        parts[#parts + 1] = _("作者：") .. tostring(author)
    end
    local serial = tonumber(book.serial_count) or tonumber(book.total_chapters)
    local status = BookDetail.update_status_label(book, opts.now)
    local line2 = { status }
    if serial and serial > 0 then
        line2[#line2 + 1] = T(_("%1 章"), tostring(serial))
    end
    local read_order = tonumber(book.real_chapter_order) or tonumber(book.read_chapters)
    if read_order and read_order > 0 then
        line2[#line2 + 1] = T(_("读到第 %1 章"), tostring(read_order))
    end
    return table.concat(parts, " · ") .. "\n" .. table.concat(line2, " · ")
end

return BookDetail
