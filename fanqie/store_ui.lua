--[[--
书城编排层（main.lua 的 mixin）：分类浏览 / 排行榜 / 搜索 / 书籍详情。

职责边界：
  * **本模块**负责网络（一律走 Async 子进程）、菜单生命周期、封面缓存、翻页追加；
  * 渲染交给 `fanqie/store_view.lua`；
  * 数据与字段归一交给 `fanqie/store.lua`。

被 main.lua 以**白名单 mixin** 方式挂到 FanQiePlugin 上（见 main.lua 的 STORE_MIXIN）。
⚠️ 模块里新增公共方法必须同时登记进白名单，否则不会被拷贝（也不会被静态检查覆盖）；
   只在模块内部用的辅助函数一律写成 `local function f(plugin, …)`，不要用 `self:`，
   免得漏登记 —— 白名单式 mixin 的合法集只包含白名单成员。

关键设计：
  * 菜单一开就是「占位条目 + 后台加载」，加载完 `switchItemTable` 原地换表（不闪屏）；
  * 分页两条路：**滚到列表尾部自动追加**（到倒数第二页就预取下一页，见 should_prefetch）
    + 操作框里显式的「加载更多（已 N / 共 M）」；追加到零本时自动置 has_more=false 刹车；
  * 每次加载带 `menu._store_req` 序号，迟到的子进程结果直接丢弃（防止快速切分类/排序时错位）；
  * 封面下载串行 + `menu._store_gen` 代际号，翻页即作废；文件名按 book_id（书库接口书名是
    PUA 解码来的，可能含 `/`、`:` 等非法字符，不能拿来当文件名）。
--]]

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
-- T 必须是 util.template（%1/%2 占位符）。定义成 _ 的话占位符**原样显示**
-- （书城标题出现「共 %1 本」、错误提示出现「%1」——实测踩中）。
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

local H = require("fanqie.helper")
local Log = require("fanqie.logger")
local CoverCache = require("fanqie.cover_cache")
local Store = require("fanqie.store")
local StoreView = require("fanqie.store_view")
local State = require("fanqie.state")
local ok_Async, Async = pcall(require, "fanqie.async")

local UIManager = require("ui/uimanager")

local StoreUI = {}

local PAGE_SIZE = 18        -- 书库接口实测 page_count=30 也能用，取 18 与网页一致
local RANK_PAGE = 20
local COVER_SUBDIR = "store_covers"
local ASYNC_TAG = "store"

local LOADING_BOOK_ID = "__store_loading__"

-- App 榜单的缓存与熔断（v2.16.0）。
-- 🔴 为什么缓存必须落在**主进程**：`fetch_page` 跑在 Async 子进程里（只读 upvalue、
--    结果整体回传），拿不到 plugin 上的任何状态。
local RANK_CACHE_TTL = 600       -- 榜单结果缓存 10 分钟（榜单本来就按天/按小时更新）
local RANK_BLOCK_SECONDS = 300   -- 空榜单后 5 分钟内不再打这个榜

-- ------------------------------------------------------------------ 小工具

local function err_text(err)
    return Store.describe_error(err)
end

local function cover_dir(plugin)
    local dir = plugin.settings:get_download_dir() .. "/" .. COVER_SUBDIR
    if H and H.make_dir then pcall(H.make_dir, dir) end
    return dir
end

local function close_store_menu(plugin)
    -- 先摘引用再关：关闭过程会回调 on_close，那里会看 plugin._store_menu 判断
    -- 是不是「自己人」，先把引用摘掉语义更干净。
    local menu = plugin._store_menu
    plugin._store_menu = nil
    if menu then H.close_widget(menu) end
    if ok_Async and Async.cancel_tag then pcall(Async.cancel_tag, ASYNC_TAG) end
end

local function invalidate_shelf(plugin)
    -- 加入/移出书架之后，书架的三层缓存必须失效，否则回到书架看不到变化
    if plugin.clearShelfCache then
        pcall(function() plugin:clearShelfCache() end)
    end
end

local function loading_books()
    -- show_cover = false：占位行不画空封面框（空框在整页白底上非常扎眼，
    -- 且那行字会被挤成半宽）。
    return { { book_id = LOADING_BOOK_ID, title = _("正在加载…"), show_cover = false } }
end

-- ------------------------------------------------------------------ 数据抓取

--- 在**子进程**里跑。只读 upvalue，结果整体回传（Async 只回传第一个返回值）。
local function fetch_page(client, state, page_index)
    local out = { ok = false }
    if state.kind == "library" then
        local r, e = Store.library(client, {
            page_index = page_index,
            page_count = PAGE_SIZE,
            gender = state.gender,
            category_id = state.category_id,
            creation_status = state.creation_status,
            word_count = -1,
            book_type = -1,
            sort = state.sort,
        })
        if r then
            out.ok, out.books, out.has_more, out.total = true, r.books, r.has_more, r.total
        else
            out.err = e
        end
    elseif state.kind == "search" then
        local r, e = Store.search(client, state.keyword, { page_index = page_index, page_count = 10 })
        if r then
            out.ok, out.books, out.total = true, r.books, r.total
            -- 搜索接口没有 has_more；拿满一页就当还有
            out.has_more = #r.books >= 10
        else
            out.err = e
        end
    elseif state.kind == "rank_recent" then
        local r, e = Store.rank_recent(client, { offset = page_index * RANK_PAGE, limit = RANK_PAGE })
        if r then
            out.ok, out.books, out.total = true, r.books, r.total
            out.has_more = #r.books >= RANK_PAGE
        else
            out.err = e
        end
    elseif state.kind == "rank_recommend" then
        local r, e = Store.rank_recommend(client, { offset = page_index * RANK_PAGE, limit = RANK_PAGE })
        if r then
            out.ok, out.books, out.total = true, r.books, r.total
            out.has_more = #r.books >= RANK_PAGE
        else
            out.err = e
        end
    elseif state.kind == "rank_top" then
        -- 巅峰榜：**恒回固定 30 本**（offset 被服务端无视），不做翻页
        local r, e = Store.rank_top(client, { offset = 0, limit = 50 })
        if r then
            out.ok, out.books, out.total = true, r.books, r.total
            out.has_more = false
        else
            out.err = e
        end
    elseif state.kind == "rank_app" then
        -- App 榜单（cell/change/v1）：**单页 30 本、不做翻页**（服务端 offset 无效，
        -- 详见 store.lua Store.rank_cell）。所以 has_more 恒 false。
        local r, e = Store.rank_cell(client, {
            rank_key = state.rank_key,
            offset = 0,
            limit = 30,
        })
        if r then
            out.ok, out.books, out.total = true, r.books, r.total
            out.has_more = false
            out.cell_alias = r.cell_alias
        else
            out.err = e
        end
    elseif state.kind == "rank_praise" then
        -- 礼物榜（ugc/praise/rank/v1）：同样只取首页 30 条
        local r, e = Store.rank_praise(client, {
            rank_key = state.rank_key,
            offset = 0,
            limit = 30,
        })
        if r then
            out.ok, out.books, out.total = true, r.books, r.total
            out.has_more = false
        else
            out.err = e
        end
    elseif state.kind == "rank_category" then
        local r, e = Store.rank_category(client, {
            gender = state.gender,
            rank_mold = state.rank_mold,
            category_id = state.category_id,
            -- 首页为空串（服务端会解析当前榜单版本并回填），之后带上一页回传的版本，
            -- 免得翻页途中榜单换版导致名次/书目错位。
            rank_version = state.rank_version,
            offset = page_index * RANK_PAGE,
            limit = RANK_PAGE,
        })
        if r then
            out.ok, out.books, out.total = true, r.books, r.total
            out.has_more = r.has_more
            out.version = r.version
        else
            out.err = e
        end
    else
        out.err = { kind = "arg", message = _("未知的书城数据源") }
    end
    return out
end

-- ------------------------------------------------------------------ 封面链

--- 封面回填后的重绘调度：**防抖合并**。
--- 🔴 封面是串行下的（0.1s/张），一页 18 张。改造前是「标脏 + 0.3s 一次性窗口」
---    ⇒ 每 3 张就整树重建一次，一页下来 6 次全屏 `setDirty` —— 墨水屏上就是连闪 6 下，
---    切榜时更明显（新榜 18 张全是新封面，重建连着来，看着就是「卡一下」）。
---    改成防抖：每回来一张就把重绘时点往后推，**静默 0.6s** 才真正重建；
---    同时设硬上限（首张起 2.4s 必重建一次），避免封面持续下载时界面一直不更新。
--- ⚠️ 重建必须带 `no_recalculate_dimen = true`（只换封面、尺寸没变）—— 这也正是
---    `StoreMenu:updateItems` 不能写回 available_height 的原因（见那里的长注释）。
local COVER_REDRAW_TICK = 0.15
local COVER_REDRAW_IDLE = 0.6
local COVER_REDRAW_MAX = 2.4

local function schedule_cover_redraw(menu)
    if not menu then return end
    menu._store_cover_dirty = true
    menu._store_cover_seq = (menu._store_cover_seq or 0) + 1
    if menu._store_cover_render_scheduled then return end
    menu._store_cover_render_scheduled = true
    local seen = menu._store_cover_seq
    local quiet, elapsed = 0, 0
    local function tick()
        if not menu or menu._miu_closed then
            if menu then menu._store_cover_render_scheduled = nil end
            return
        end
        elapsed = elapsed + COVER_REDRAW_TICK
        if menu._store_cover_seq ~= seen then
            -- 期间又回来了新封面：重新计时（静默期从头算）
            seen = menu._store_cover_seq
            quiet = 0
        else
            quiet = quiet + COVER_REDRAW_TICK
        end
        if quiet < COVER_REDRAW_IDLE and elapsed < COVER_REDRAW_MAX then
            UIManager:scheduleIn(COVER_REDRAW_TICK, tick)
            return
        end
        menu._store_cover_render_scheduled = nil
        if not menu._store_cover_dirty then return end
        menu._store_cover_dirty = nil
        menu._suppress_page_callback = true
        pcall(menu.updateItems, menu, nil, true)
        menu._suppress_page_callback = false
    end
    UIManager:scheduleIn(COVER_REDRAW_TICK, tick)
end

--- 串行给 [first, last] 区间的条目下封面。generation 变了（翻页/换分类）立即停手。
local function cache_covers_step(plugin, menu, generation, index, last)
    if not menu or menu._miu_closed or menu._store_gen ~= generation then return end
    if index > last then return end

    local entry = menu.item_table and menu.item_table[index]
    local book = entry and entry.book
    local function next_step()
        UIManager:scheduleIn(0.1, function()
            cache_covers_step(plugin, menu, generation, index + 1, last)
        end)
    end

    if not book or book.book_id == LOADING_BOOK_ID or not book.cover or book.cover == "" then
        next_step()
        return
    end
    if book.cover_path then
        next_step()
        return
    end

    local path = StoreView.cover_path(cover_dir(plugin), book)
    if not path then
        next_step()
        return
    end

    -- 缓存命中与下载完成共用同一段回填逻辑
    local function apply_cover(p)
        book.cover_path = p
        local changed = false
        for _i, e in ipairs(menu.item_table or {}) do
            if tostring(e.book_id) == tostring(book.book_id) then
                if e.cover_path ~= p then
                    e.cover_path = p
                    changed = true
                end
                break
            end
        end
        if changed then
            -- 别每张封面各刷一次全树（一页 18 张 ⇒ 连闪 6 次）。防抖合并见函数注释。
            schedule_cover_redraw(menu)
        end
    end

    -- 「存在」还不够：过期封面当没有 ⇒ 下面重下并覆盖同名文件
    local cache_days = plugin.settings.get_cover_cache_days
        and plugin.settings:get_cover_cache_days()
    if H and H.file_exists(path) and CoverCache.is_fresh(path, cache_days) then
        apply_cover(path)
        next_step()
        return
    end

    if not (ok_Async and Async.run) then
        next_step()
        return
    end

    local url = book.cover
    local client = plugin.client
    Async.run(function()
        local data = client:get_binary(url)
        if not data then return nil end
        local file = io.open(path, "wb")
        if file then
            file:write(data)
            file:close()
            return path
        end
        return nil
    end, function(ok, result)
        if not menu or menu._miu_closed or menu._store_gen ~= generation then return end
        if ok and result then
            apply_cover(result)
        elseif Log then
            Log.debug("[FanQie][store] 封面下载失败:", tostring(book.book_id), tostring(result))
        end
        next_step()
    end, { poll_interval = 0.125, timeout = 30 })
end

-- ------------------------------------------------------------------ 加载

--- 标题 = 「书城 · <副标题> · 共 N 本」。Menu 会改写 self.title，所以必须
--- 自己合成后写回 menu._store_title（StoreView.update 用它调 switchItemTable）。
--- ⚠️ 必须声明在 load_page 之前：Lua 的 local 作用域从声明语句之后才开始，
---    放在后面的话 load_page 里的引用会解析成**全局 nil** → 点开书城即硬崩。
local function compose_title(menu)
    local base = menu._store_base_title or _("书城")
    local parts = {}
    local sub = menu._store_subtitle
    if type(sub) == "string" and sub ~= "" then parts[#parts + 1] = sub end
    local state = menu._store_state
    local total = state and tonumber(state.total) or 0
    if total > 0 then
        parts[#parts + 1] = T(_("共 %1 本"), tostring(total))
    end
    if #parts == 0 then return base end
    return base .. " · " .. table.concat(parts, " · ")
end

--- 详情增强：后台拉 multidetail（连载/完结/断更 + 总章数），静默合入后重绘。
--- ⚠️ 子进程里的内存修改**不会回传**（fork 内存隔离），所以子进程只拉数据、
---    合入必须在这个 on_done（父进程）里做；req 变了（切分类/翻页）直接丢弃。
local function enhance_details(plugin, menu, req)
    if not menu or menu._miu_closed then return end
    local books = menu._store_books
    if type(books) ~= "table" or #books == 0 then return end
    local client = plugin.client
    local ids = {}
    for _i, b in ipairs(books) do
        if type(b) == "table" and b.book_id ~= nil and b.book_id ~= "" then
            ids[#ids + 1] = tostring(b.book_id)
        end
    end
    if #ids == 0 then return end
    Async.run(function()
        local map, err = Store.book_details(client, ids)
        return { map = map, err = err }
    end, function(ok, res)
        if not menu or menu._miu_closed or menu._store_req ~= req then return end
        if not ok or type(res) ~= "table" or type(res.map) ~= "table" then
            -- 没登录 / 接口异常都静默降级：列表仍有书库接口自带的 creation_status
            if Log and res and res.err then
                Log.debug("[FanQie][store] multidetail 降级:", Store and Store.describe_error and Store.describe_error(res.err) or "")
            end
            return
        end
        local n = 0
        for _i, b in ipairs(books) do
            local d = b and b.book_id and res.map[tostring(b.book_id)] or nil
            if d then
                Store.apply_detail(b, d)
                n = n + 1
            end
        end
        if n > 0 then
            StoreView.update(menu, menu._store_books, menu._store_opts)
        end
    end, { poll_interval = 0.5, timeout = 30, tag = ASYNC_TAG })
end

--- 列表现在是不是「还在占位」（一条加载占位、或干脆没有数据）。
--- 🔴 首载失败的关菜单判据必须用它：失败时 `_store_books` 里是**加载占位条目**
--- （1 条），按旧的「#books == 0」判永远不关 —— 空响应后菜单就一直挂在
--- 「正在加载…」上（旧断言被选择器的关闭记录喂绿，掩盖了这个 bug）。
--- 换分类/刷新失败**不**关：用户还看着旧列表，错要报但不掀桌。
--- ⚠️ 必须声明在 load_page 之前（load_page 的失败分支要调它，Lua local 作用域
--- 从声明语句之后才开始 —— 放后面引用会解析成全局 nil）。
local function is_placeholder_books(menu)
    local b = menu and menu._store_books
    if type(b) ~= "table" then return true end
    local n = #b
    if n == 0 then return true end
    return n == 1 and type(b[1]) == "table" and b[1].book_id == LOADING_BOOK_ID
end

--- App 榜单（cell/礼物榜）的缓存键；非 App 榜单返回 nil（不参与缓存与熔断）。
local function app_rank_key(state)
    if not state then return nil end
    if state.kind == "rank_app" or state.kind == "rank_praise" then
        return state.kind .. ":" .. tostring(state.rank_key)
    end
    return nil
end

local function app_rank_cache_get(plugin, state)
    local key = app_rank_key(state)
    if not key then return nil end
    local cache = plugin._store_rank_cache
    local e = cache and cache[key]
    if type(e) ~= "table" or type(e.books) ~= "table" then return nil end
    if (os.time() - (tonumber(e.t) or 0)) > RANK_CACHE_TTL then return nil end
    return e.books
end

local function app_rank_cache_put(plugin, state, books)
    local key = app_rank_key(state)
    if not key or type(books) ~= "table" or #books == 0 then return end
    plugin._store_rank_cache = plugin._store_rank_cache or {}
    plugin._store_rank_cache[key] = { t = os.time(), books = books }
end

--- 该榜单是否在熔断冷却中；是则返回剩余秒数。
local function app_rank_block_left(plugin, state)
    local key = app_rank_key(state)
    if not key then return nil end
    local until_ts = plugin._store_rank_blocked and plugin._store_rank_blocked[key]
    if not until_ts then return nil end
    local left = tonumber(until_ts) - os.time()
    if left <= 0 then
        plugin._store_rank_blocked[key] = nil
        return nil
    end
    return left
end

local function app_rank_block(plugin, state)
    local key = app_rank_key(state)
    if not key then return end
    plugin._store_rank_blocked = plugin._store_rank_blocked or {}
    plugin._store_rank_blocked[key] = os.time() + RANK_BLOCK_SECONDS
end

--- 用一次抓取结果刷新菜单（异步回调与**榜单缓存命中**两条路共用）。
--- 🔴 抽出来的理由：缓存命中时不发请求，但后面「替换条目表 / 重画 / 起封面链 /
---    后台增强」这一整段必须与网络路径**完全一致**，复制一份必然走偏。
local function apply_fetch_result(plugin, menu, req, page_index, append, res)
    if not menu or menu._miu_closed or menu._store_req ~= req then return end
    local state = menu._store_state
    if not state then return end

    if not res.ok then
        local err = res.err
        -- 榜单专属错误（服务端明确说没数据 / 榜名对不上）：给友好提示，
        -- 「暂无数据」再挂 5 分钟熔断 —— 免得用户连点几次把同一个空榜反复打。
        if err and (err.kind == "rank_empty" or err.kind == "rank_mismatch") then
            if err.kind == "rank_empty" then app_rank_block(plugin, state) end
            plugin:showInfo(err_text(err))
        else
            plugin:showError(T(_("书城加载失败：%1"), err_text(err)))
        end
        if not append and is_placeholder_books(menu) then
            close_store_menu(plugin)
        end
        return
    end

    local books
    local added = 0
    if append then
        books = menu._store_books or {}
        for _i, b in ipairs(res.books or {}) do
            books[#books + 1] = b
            added = added + 1
        end
    else
        books = res.books or {}
    end
    state.page_index = page_index
    state.has_more = res.has_more == true
    state.total = tonumber(res.total) or state.total or 0
    -- 原创榜：把服务端解析出的榜单版本记下来，下一页带回去（见 state.rank_version）
    if res.version ~= nil and res.version ~= "" then state.rank_version = res.version end
    -- App 榜单：把服务端给的「排行依据」（如「根据番茄评分排行」）挂到副标题
    if res.cell_alias ~= nil and res.cell_alias ~= "" then
        state.rank_alias = res.cell_alias
        menu._store_subtitle = state.rank_label and (state.rank_label .. " · " .. res.cell_alias)
            or res.cell_alias
    end
    -- 🔴 追加却**一本没多**（服务端 has_more 是乐观值 / 该分类已翻到底）：
    --    立刻刹车。不刹车的话每次翻到末页都会重复拉同一页 —— 白费流量、
    --    封面链反复重跑，用户看到的是「一直在转圈但什么都没多」。
    if append and added == 0 then state.has_more = false end

    if not append and #books == 0 then
        plugin:showInfo(_("没有找到书籍"))
        close_store_menu(plugin)
        return
    end

    -- App 榜单：把成功结果写进缓存（下次进同一榜直接出，不再打接口）
    if not append then app_rank_cache_put(plugin, state, books) end

    menu._store_books = books
    local opts = menu._store_opts or {}
    opts.books = books
    menu._store_opts = opts
    menu._store_title = compose_title(menu)
    StoreView.update(menu, books, opts)

    if not append then
        -- StoreView.update 内部抑制了 on_page_changed，首屏封面要自己起
        menu._store_gen = (menu._store_gen or 0) + 1
        local last = math.min(#books, PAGE_SIZE)
        if last >= 1 then
            cache_covers_step(plugin, menu, menu._store_gen, 1, last)
        end
    end

    -- 后台增强：连载/完结/断更 + 总章数（multidetail，静默降级）
    enhance_details(plugin, menu, req)
end

local function load_page(plugin, menu, page_index, append)
    if not menu or menu._miu_closed then return end
    local state = menu._store_state
    if not state then return end
    if append and state.loading then return end

    -- 请求序号：切分类/切排序时旧结果必须丢弃，否则会把旧数据追加到新列表
    menu._store_req = (menu._store_req or 0) + 1
    local req = menu._store_req
    state.loading = true

    local client = plugin.client
    local snapshot = state      -- 只读；子进程里的修改不会回传

    if not append then
        -- ① 熔断中：不打接口，直接告知（榜单缓存与熔断都只对 App 榜单生效）
        local left = app_rank_block_left(plugin, state)
        if left then
            state.loading = false
            plugin:showInfo(T(_("该榜单暂时不可用，请 %1 分钟后再试"), tostring(math.ceil(left / 60))))
            if is_placeholder_books(menu) then close_store_menu(plugin) end
            return
        end
        -- ② 缓存命中：直接出数据（不走网络、不显示占位转圈）
        local cached = app_rank_cache_get(plugin, state)
        if cached then
            state.loading = false
            apply_fetch_result(plugin, menu, req, page_index, false, {
                ok = true,
                books = cached,
                total = #cached,
                has_more = false,
            })
            return
        end
    end

    Async.run(function()
        return fetch_page(client, snapshot, page_index)
    end, function(ok, res, err)
        if not menu or menu._miu_closed or menu._store_req ~= req then return end
        state.loading = false

        if not ok or type(res) ~= "table" then
            plugin:showError(T(_("书城加载失败：%1"), err_text(err or res)))
            if not append and is_placeholder_books(menu) then
                close_store_menu(plugin)
            end
            return
        end
        apply_fetch_result(plugin, menu, req, page_index, append, res)
    end, { poll_interval = 0.3, timeout = 40, tag = ASYNC_TAG })
end

--- 现在该不该预取下一页。
--- 🔴 判据是「**到倒数第二页就预取**」，不是「滚到最后一页才预取」：
---    书库一页 18 条、菜单一屏 7 条 ⇒ 一屏一屏翻，真等到最后一页等于让用户白翻两次；
---    而最后一页常常只剩两三条 —— 用户很可能根本不翻到那儿（以为已经到底了）。
---    提前一页预取，翻页手感才是连续的。
---    两个判据取「或」：`page_num` 在 `onGotoPage`（带 no_recalculate_dimen=true）时
---    不会刷新，可能偏小；`last >= total - perpage` 只依赖 item_table 长度，用来兜底。
local function should_prefetch(menu, page, last)
    local total = #(menu.item_table or {})
    if total == 0 then return false end
    local perpage = tonumber(menu.perpage) or 1
    if perpage < 1 then perpage = 1 end
    local page_num = math.max(1, math.ceil(total / perpage))
    if page >= page_num - 1 then return true end
    return last >= total - perpage
end

local function on_store_page(plugin, menu, page, first, last)
    if not menu then return end
    local state = menu._store_state
    menu._store_gen = (menu._store_gen or 0) + 1
    local generation = menu._store_gen
    -- 快到列表尾部且服务端说还有 → 后台追加下一页
    if state and state.has_more and not state.loading
        and should_prefetch(menu, page, last) then
        load_page(plugin, menu, (tonumber(state.page_index) or 0) + 1, true)
    end
    cache_covers_step(plugin, menu, generation, first, last)
end

-- ------------------------------------------------------------------ 菜单构造

local function make_menu(plugin, opts)
    -- 封面缓存每天最多清一次（见 cover_cache.maybe_auto_prune）。放在**建菜单之前**：
    -- 菜单建起来后这一屏的封面控件已经持有路径，那时删文件会画出空白格。
    if CoverCache and plugin._coverCacheDirs then
        pcall(CoverCache.maybe_auto_prune, plugin.settings, plugin:_coverCacheDirs())
    end

    -- 防叠加：上一个书城菜单（分类浏览 / 榜单 / 搜索）先收掉。
    -- 否则「操作框 → 换分类 → 选分类」这类路径会叠出第二个菜单：新的盖住旧的，
    -- 但旧的仍在 UIManager 栈上 —— 用户关掉新菜单后又会看到它。
    close_store_menu(plugin)

    local menu_ref
    local dir = cover_dir(plugin)
    opts.plugin = plugin   -- StoreMenu:onCloseWidget 靠它收掉书籍详情浮层
    opts.cover_dir = dir
    opts.file_exists = H and H.file_exists or nil
    -- ⚠️ 光给 file_exists 不够：build_items 会把过期的封面也摆上去（永远不重下）。
    --    这里再传一个「新鲜度」判据，两条件都过才算命中。
    opts.cover_fresh = function(p)
        local days = plugin.settings.get_cover_cache_days
            and plugin.settings:get_cover_cache_days()
        return CoverCache.is_fresh(p, days)
    end
    opts.on_page_changed = function(page, first, last, menu)
        on_store_page(plugin, menu, page, first, last)
    end
    opts.on_close = function()
        -- ⚠️ 本回调是经 scheduleIn(0) 延迟执行的（见 StoreMenu:onCloseWidget）。
        --    若这期间已经建了新菜单（上面的防叠加路径会关旧建新），必须整体跳过：
        --    Async 的 tag 是全局的，cancel_tag 会把新菜单刚发出的请求一起干掉。
        if plugin._store_menu and plugin._store_menu ~= menu_ref then
            return
        end
        if plugin._store_menu == menu_ref then
            plugin._store_menu = nil
        end
        -- 浮在菜单之上的搜索输入框也要一起收掉，否则它留在屏幕上点不动
        local search_dialog = plugin._store_search_dialog
        if search_dialog then
            plugin._store_search_dialog = nil
            H.close_widget(search_dialog)
        end
        if ok_Async and Async.cancel_tag then pcall(Async.cancel_tag, ASYNC_TAG) end
    end
    opts.on_select = function(book)
        if book and book.book_id ~= LOADING_BOOK_ID then
            plugin:showStoreBookDetail(book)
        end
    end
    opts.books = opts.books or loading_books()

    local menu = StoreView.show(opts)
    menu_ref = menu
    plugin._store_menu = menu
    menu._store_gen = 0
    menu._store_req = 0
    return menu
end

local function reload_from_head(plugin, menu)
    local state = menu._store_state
    if not state then return end
    state.has_more = true
    load_page(plugin, menu, 0, false)
end

--- 「加载更多」动作（分类浏览 / 榜单 / 搜索共用）。
--- 🔴 为什么要有这个显式入口：分页原本只有「滚到列表尾部自动追加」一条**看不见**的隐性路径，
---    用户不知道还能往下拉，看到 18 本就以为到底了 —— 反馈原话是
---    「这个书城是带分页的啊，你这岂不是只请求一次，后面的没法分页了」。
---    把它摆进操作框，顺带显示「已加载 N / 共 M」，分页就是可见可点的。
--- ⚠️ `text` 是**函数**（每次打开操作框时求值，见 StoreMenu:onLeftButtonTap），
---    所以里面的数字是活的，不能写成字符串。
local function load_more_action(plugin, menu)
    return {
        text = function()
            local st = menu._store_state or {}
            local n = #(menu._store_books or {})
            local total = tonumber(st.total) or 0
            if total > 0 then
                return T(_("加载更多（已 %1 / 共 %2）"), tostring(n), tostring(total))
            end
            return T(_("加载更多（已 %1）"), tostring(n))
        end,
        callback = function()
            local st = menu._store_state
            if not st then return end
            if st.loading then
                plugin:showInfo(_("正在加载中…"))
                return
            end
            if not st.has_more then
                plugin:showInfo(_("已经到底了"))
                return
            end
            load_page(plugin, menu, (tonumber(st.page_index) or 0) + 1, true)
        end,
    }
end

--- 🔴 前向声明（v2.16.0 tab 栏）：switch/show 两个函数体定义在下面，
--- 但 library_actions 的「换分类」会引用 show_ —— Lua 的 local 作用域从
--- 声明语句之后才开始，不先声明的话点「换分类」解析成全局 nil 硬崩。
local switch_library_gender
local show_library_categories

--- 🔴 前向声明（v2.16.0 控件行统一分派）：tab 行 / 筛选行 / 操作框三者的内容都
--- **按 `state.kind` 分派**（实现见文件后部的 menu_tabs / menu_filters / menu_actions）。
--- 这样「原地换榜单 / 换频道」时三个区域自动跟着 state 走，不会出现
--- 「tab 换了、筛选行还是上一屏的按钮」这种半新半旧的状态。
--- 定义在文件后部（要等各 kind 的 tabs/filters/actions 都定义完），此处先声明。
local menu_tabs, menu_filters, menu_actions

--- 原地换了 kind / 频道 / 榜别之后，重建操作框条目。
--- ⚠️ tab 行与筛选行**不用**手动刷新：它们是 `_store_tabs_fn` / `_store_filters_fn`，
---    每次 `updateItems` 重新求值，天然跟随 state；而操作框条目是构造时定下的数组。
local function refresh_menu_actions(plugin, menu)
    if not menu then return end
    -- menu_actions 此刻可能还是前向声明里的 nil（文件尚未执行到定义处）：
    -- pcall 兜住，此时保留原条目即可。
    local ok_a, acts = pcall(menu_actions, plugin, menu)
    if ok_a and type(acts) == "table" then menu._store_actions = acts end
end

--- 「显示方式」动作：列表 / 封面网格（3~5 列）。
--- 四个操作框（书城 / 榜单 / 榜单分类 / 搜索）共用同一个入口 —— 模式与列数
--- 持久化在 settings.ui.store，且**只影响书城**，不会顺带把书架也改成网格。
--- ⚠️ text 写成**函数**：标签里的列数要跟着当前设置实时变（同「加载更多」的理由）。
local function view_action(_plugin, menu)
    return {
        text = function()
            return T(_("显示方式：%1"), StoreView.view_label(menu))
        end,
        callback = function()
            StoreView.show_view_dialog(menu)
        end,
    }
end

--- 改了筛选条件后：先把**筛选行**的当前值刷出来，再从头拉数据。
--- ⚠️ 刷筛选行必须走完整的 `updateItems`（**不带** no_recalculate_dimen）：筛选行是
---    `_store_filters_fn` 在每次重绘时重新求值的，只有重绘才会更新按钮上的值。
---    不刷的话点完要等一整轮网络回来才看到值变了 —— 用户会以为没点上。
local function patch_filters_and_reload(plugin, menu, patch)
    local state = menu and menu._store_state
    if not state then return end
    for k, v in pairs(patch) do state[k] = v end
    if menu.updateItems then
        menu._suppress_page_callback = true
        pcall(menu.updateItems, menu)
        menu._suppress_page_callback = false
    end
    reload_from_head(plugin, menu)
end

--- 书库筛选行（v2.16.0）：排序 / 状态 / 分类 三个「下拉」。
--- 改造前这三个藏在左上角操作框里 —— tab 栏管「去哪」（男频/女频/榜单/搜索），
--- 筛选却要「先想起来点左上角、再在 7 行按钮里找」，两套交互割裂
--- （用户原话「有的是界面上 tabs，有的是菜单选项里的筛选」）。
--- 现在筛选全部摆在 tab 栏**下面一排**，点开即选、按钮上直接显示当前值。
--- ⚠️ 每个 chip 的 `text` 是**当次求值的字符串**：`build_filter_row` 每次重绘都会
---    调本函数，所以值天然是活的（不需要写成函数 —— 那是操作框 `text` 的语义）。
local function library_filters(plugin, menu)
    local state = menu._store_state
    if not state then return nil end
    return {
        {
            text = T(_("排序：%1"), Store.sort_label(state.sort)) .. " ▾",
            active = state.sort ~= Store.SORT.hot,
            on_tap = function()
                StoreView.show_chooser{
                    title = _("排序方式"),
                    entries = {
                        { text = _("最热"), callback = function()
                            patch_filters_and_reload(plugin, menu, { sort = Store.SORT.hot }) end },
                        { text = _("最新"), callback = function()
                            patch_filters_and_reload(plugin, menu, { sort = Store.SORT.new }) end },
                        { text = _("字数"), callback = function()
                            patch_filters_and_reload(plugin, menu, { sort = Store.SORT.words }) end },
                    },
                }
            end,
        },
        {
            text = T(_("状态：%1"), Store.creation_status_label(state.creation_status)) .. " ▾",
            active = state.creation_status ~= Store.CREATION_STATUS.any,
            on_tap = function()
                StoreView.show_chooser{
                    title = _("连载状态"),
                    entries = {
                        { text = _("不限"), callback = function()
                            patch_filters_and_reload(plugin, menu,
                                { creation_status = Store.CREATION_STATUS.any }) end },
                        { text = _("连载中"), callback = function()
                            patch_filters_and_reload(plugin, menu,
                                { creation_status = Store.CREATION_STATUS.ongoing }) end },
                        { text = _("已完结"), callback = function()
                            patch_filters_and_reload(plugin, menu,
                                { creation_status = Store.CREATION_STATUS.finished }) end },
                    },
                }
            end,
        },
        {
            text = T(_("分类：%1"), state.category_name or _("全部")) .. " ▾",
            active = (tonumber(state.category_id) or -1) ~= -1,
            -- 分类压平后 150+ 条，走带分隔头的选择器（见 open_categories 的压平说明）
            on_tap = function() show_library_categories(plugin, menu) end,
        },
    }
end

local function library_actions(plugin, menu)
    -- v2.16.0：排序 / 状态 / 分类 三项**已搬到筛选行**（tab 栏下面一排），
    -- 操作框只留「动作」（不是筛选条件的东西）：加载更多 / 显示方式 / 重新加载。
    return {
        load_more_action(plugin, menu),
        view_action(plugin, menu),
        { text = _("重新加载"), callback = function() reload_from_head(plugin, menu) end },
    }
end

--- 分类树取一次缓存一次（男频/女频各一棵，见 open_categories 的缓存注释）。
--- cb(list) 在树就绪时调用 —— 有缓存就**同步**调，没缓存才走子进程。
local function ensure_categories(plugin, gender, cb)
    local cached = plugin._store_categories
    if cached and plugin._store_categories_gender == gender then
        cb(cached)
        return
    end
    local client = plugin.client
    Async.run(function()
        local list, err = Store.categories(client, gender)
        return { list = list, err = err }
    end, function(ok, res, err)
        if not ok or type(res) ~= "table" or not res.list then
            local e2 = (type(res) == "table" and res.err) or err
            plugin:showError(T(_("获取分类失败：%1"), err_text(e2)))
            return
        end
        plugin._store_categories = res.list
        -- ⚠️ 缓存必须记住是**哪个性别**的树：男频 19 个主分类、女频 21 个，
        -- 混用会列错分类（列表内容对不上号）
        plugin._store_categories_gender = gender
        cb(res.list)
    end, { poll_interval = 0.3, timeout = 30, tag = ASYNC_TAG })
end

--- 分类浏览的 tab 栏：男频 | 女频（原地换频道）+ 分类…（原地换分类）+
--- 榜单 / 搜索（还是老的选择器入口）。active 由当前 state 现算。
--- （函数体在这里赋值，前向声明见 view_action 上方。）
switch_library_gender = function(plugin, menu, gender)
    local st = menu._store_state
    if not st then return end
    if st.gender == gender then return end
    plugin._store_gender = gender
    st.gender = gender
    -- 🔴 换频道必须把分类回落「全部」：男频/女频的分类树是两棵，带着男频的
    -- category_id 去查女频接口，查到的要么是错的分类要么是空列表。
    st.category_id = -1
    st.category_name = _("全部")
    menu._store_subtitle = Store.gender_label(gender) .. "·" .. st.category_name
    reload_from_head(plugin, menu)
end

--- tab 的「分类…」：在**当前菜单**上原地换分类（不再一层层弹选择器 → 重开菜单）。
--- 列表压平成一层：每个分类带分组前缀，不再「分组 → 分类」两层。
show_library_categories = function(plugin, menu)
    local st = menu._store_state
    if not st then return end
    ensure_categories(plugin, st.gender, function(list)
        local entries = {
            { text = _("全部"), callback = function()
                st.category_id = -1
                st.category_name = _("全部")
                menu._store_subtitle = Store.gender_label(st.gender) .. "·" .. st.category_name
                reload_from_head(plugin, menu)
            end },
        }
        local groups = Store.group_categories(list)
        for _i, g in ipairs(groups) do
            -- 组间分隔头（不可点）：压平后 150+ 条全靠前缀区分，没有分组头就是
            -- 十几页无结构的长串。条目量实测：男频 154（主 19/主题 33/角色 22/情节 80）、
            -- 女频 182（主 21/主题 25/角色 41/情节 95）。
            entries[#entries + 1] = {
                separator = true,
                text = T(_("── %1（%2）──"), g.label, tostring(#(g.items or {}))),
            }
            for _j, c in ipairs(g.items or {}) do
                local label = c.name
                if g.label ~= "主分类" then
                    label = g.label .. "·" .. c.name
                end
                entries[#entries + 1] = {
                    text = label,
                    callback = function()
                        st.category_id = c and tonumber(c.category_id) or -1
                        st.category_name = c and c.name or _("全部")
                        menu._store_subtitle = Store.gender_label(st.gender) .. "·" .. st.category_name
                        reload_from_head(plugin, menu)
                    end,
                }
            end
        end
        StoreView.show_chooser{
            title = T(_("分类 · %1"), Store.gender_label(st.gender)),
            entries = entries,
        }
    end)
end

--- 分类浏览列表的 tab 栏描述（active 由当前 state 现算，见 build_tab_row）。
local function library_tabs(plugin, menu)
    local st = menu._store_state or {}
    return {
        { text = _("男频"), active = st.gender == Store.GENDER.male,
          on_tap = function() switch_library_gender(plugin, menu, Store.GENDER.male) end },
        { text = _("女频"), active = st.gender == Store.GENDER.female,
          on_tap = function() switch_library_gender(plugin, menu, Store.GENDER.female) end },
        -- 「分类…」**不进 tab**：分类是**筛选条件**不是目的地，压平后 150+ 条弹在 tab 上太重
        -- —— 它在 tab 正下方的**筛选行**里（「分类：全部 ▾」），选完列表原地刷新。
        -- ⚠️ 本行的「榜单」是**导航**：不传 menu ⇒ 开一个新菜单，返回键能回到书库；
        --    榜单菜单筛选行里的「榜单 ▾」才是**原地换榜**（传 menu，同一栈位）。
        --    这两条语义是分开的，别合并。
        { text = _("榜单"), on_tap = function() plugin:showStoreRanks() end },
        { text = _("搜索"), on_tap = function() plugin:showStoreSearch() end },
    }
end

local function open_library(plugin, gender, category, group_label)
    local state = {
        kind = "library",
        gender = gender,
        category_id = category and category.category_id or -1,
        category_name = category and category.name or _("全部"),
        creation_status = Store.CREATION_STATUS.any,
        sort = Store.SORT.hot,
        page_index = 0,
        has_more = true,
        loading = false,
        total = 0,
    }
    local subtitle = Store.gender_label(gender) .. "·" .. state.category_name
    if group_label and group_label ~= "" then subtitle = group_label .. "·" .. subtitle end
    local menu = make_menu(plugin, {
        title = _("书城"),
        subtitle = subtitle,
        store_actions_title = _("书城操作"),
        -- v2.16.0：tabs / 筛选行 / 操作框三者都走**按 state.kind 分派**的统一入口
        -- （见 menu_tabs / menu_filters / menu_actions）—— 原地换频道、换榜单后
        -- 三块内容自动跟着 state 走，不会半新半旧。
        tabs_fn = function(m) return menu_tabs(plugin, m) end,
        filters_fn = function(m) return menu_filters(plugin, m) end,
    })
    menu._store_state = state
    menu._store_actions = library_actions(plugin, menu)
    load_page(plugin, menu, 0, false)
end

-- ⚠️ 前向声明：原创榜的两个辅助函数互相引用（榜单菜单的「换分类」要调分类选择器，
--    分类选中后又要回到榜单菜单）。Lua 的 local 作用域从声明语句**之后**才开始，
--    不先声明的话前向那处会解析成**全局 nil** → 点一下「换分类」就硬崩。
local open_rank_category
local open_rank_categories

--- 榜单 tab：原地换 kind（最近更新 ⇄ 推荐榜，两个 kind 走不同接口但同一个菜单）。
local function switch_rank_kind(plugin, menu, kind, label)
    local st = menu._store_state
    if not st then return end
    if st.kind == kind then return end
    st.kind = kind
    menu._store_subtitle = label
    -- 从 App 榜原地切回网页榜：清掉 App 榜专属字段，否则筛选行的「榜单：xx」会留在旧榜名
    st.rank_key = nil
    st.rank_label = nil
    -- kind 变了 ⇒ 操作框条目要重算（tab/筛选行自己会跟随，见 refresh_menu_actions）
    refresh_menu_actions(plugin, menu)
    reload_from_head(plugin, menu)
end

local function rank_list_tabs(plugin, menu)
    local st = menu._store_state or {}
    return {
        { text = _("最近更新"), active = st.kind == "rank_recent",
          on_tap = function() switch_rank_kind(plugin, menu, "rank_recent", _("最近更新")) end },
        { text = _("推荐榜"), active = st.kind == "rank_recommend",
          on_tap = function() switch_rank_kind(plugin, menu, "rank_recommend", _("推荐榜")) end },
        { text = _("巅峰榜"), active = st.kind == "rank_top",
          on_tap = function() switch_rank_kind(plugin, menu, "rank_top", _("巅峰榜")) end },
    }
end

--- 原创榜 tab：原地换榜别（阅读榜 ⇄ 新书榜，性别与分类保持不变）。
local function switch_rank_mold(plugin, menu, mold)
    local st = menu._store_state
    if not st then return end
    if st.rank_mold == mold then return end
    st.rank_mold = mold
    local label = Store.gender_label(st.gender) .. Store.rank_mold_label(mold)
    if st.category_name ~= "" then label = label .. " · " .. st.category_name end
    menu._store_subtitle = label
    reload_from_head(plugin, menu)
end

local function rank_category_tabs(plugin, menu)
    local st = menu._store_state or {}
    return {
        { text = _("阅读榜"), active = st.rank_mold == Store.RANK_MOLD.read,
          on_tap = function() switch_rank_mold(plugin, menu, Store.RANK_MOLD.read) end },
        { text = _("新书榜"), active = st.rank_mold == Store.RANK_MOLD.new,
          on_tap = function() switch_rank_mold(plugin, menu, Store.RANK_MOLD.new) end },
    }
end

--- 在**已有菜单**上原地应用一个原创榜状态（tab 换榜别 / 筛选行换性别·分类共用）。
local function apply_rank_category(plugin, menu, gender, mold, category)
    local st = menu._store_state
    if not st then return end
    -- 从别的榜（App 榜 / 网页榜）原地切进来时 kind 会变，必须一起改
    local from_other_kind = st.kind ~= "rank_category"
    st.kind = "rank_category"
    st.gender = gender
    st.rank_mold = mold
    st.rank_key = nil
    st.rank_label = nil
    -- 只是同榜内换分类/换榜别时**保留**已解析出的榜单版本（换榜才需要重新解析）
    if from_other_kind then st.rank_version = "" end
    st.category_id = category and tonumber(category.category_id) or nil
    st.category_name = category and category.name or ""
    local label = Store.gender_label(gender) .. Store.rank_mold_label(mold)
    if st.category_name ~= "" then label = label .. " · " .. st.category_name end
    menu._store_subtitle = label
    -- 从「其它榜」原地切进原创榜时 kind 会变 ⇒ 操作框条目要重算
    refresh_menu_actions(plugin, menu)
    reload_from_head(plugin, menu)
end

--- 榜单筛选行（网页榜 / App 榜共用）：一个「榜单：xx ▾」。
--- 点开就是分组榜单列表（网页榜单 / 男频榜单 / 出版物 / 礼物榜），选中**原地**换榜。
--- 改造前这个入口是操作框里的「换榜单」动作 —— 但它属于「这一屏显示哪个榜」的
--- **筛选语义**，与 tab 行并列在界面上更顺手，也不再有「藏在对话框里」的割裂。
--- ⚠️ 传 menu 给 showStoreRanks ⇒ 原地切换（不重开菜单、不闪一下）。
local function rank_filters(plugin, menu)
    local st = menu._store_state or {}
    -- ⚠️ 优先用 **subtitle**（原地换榜时它一定是最新的）；rank_label 只在 App 榜菜单
    --    构造时写过一次，原地换到别的榜后会留在旧值。
    local label = menu._store_subtitle
    if type(label) ~= "string" or label == "" then label = st.rank_label end
    if type(label) ~= "string" or label == "" then label = _("榜单") end
    return {
        {
            text = T(_("榜单：%1"), label) .. " ▾",
            on_tap = function() plugin:showStoreRanks(menu) end,
        },
    }
end

--- 原创榜筛选行：性别 / 分类（榜别在 tab 行，再给一个「榜单」跳去别的榜）。
local function rank_category_filters(plugin, menu)
    local st = menu._store_state or {}
    local cname = st.category_name
    if type(cname) ~= "string" or cname == "" then cname = _("全部") end
    return {
        {
            text = T(_("性别：%1"), Store.gender_label(st.gender)) .. " ▾",
            on_tap = function()
                StoreView.show_chooser{
                    title = _("频道"),
                    entries = {
                        { text = Store.gender_label(Store.GENDER.male), callback = function()
                            -- 换性别后分类未必存在 ⇒ 回落「全部」
                            apply_rank_category(plugin, menu, Store.GENDER.male, st.rank_mold, nil) end },
                        { text = Store.gender_label(Store.GENDER.female), callback = function()
                            apply_rank_category(plugin, menu, Store.GENDER.female, st.rank_mold, nil) end },
                    },
                }
            end,
        },
        {
            text = T(_("分类：%1"), cname) .. " ▾",
            active = (st.category_id ~= nil and st.category_id ~= ""),
            -- 传 menu ⇒ 原地换分类（不重开菜单）
            on_tap = function() open_rank_categories(plugin, st.gender, st.rank_mold, menu) end,
        },
        {
            text = T(_("榜单：%1"), Store.rank_mold_label(st.rank_mold)) .. " ▾",
            on_tap = function() plugin:showStoreRanks(menu) end,
        },
    }
end

-- ------------------------------------------------------------------ 操作框条目（按 kind 分派）

--- v2.16.0：操作框只留**动作**（不是筛选条件的东西）。排序/状态/分类已搬到筛选行，
--- 换榜单/换分类也搬了（都在筛选行），所以这里明显短了 —— 打开就是几个动作，不用滚。
--- ⚠️ 原地换 kind 时由 `refresh_menu_actions` 重建这份表。
local function rank_actions(plugin, menu)
    return {
        load_more_action(plugin, menu),
        view_action(plugin, menu),
        { text = _("重新加载"), callback = function() reload_from_head(plugin, menu) end },
        { text = _("搜索"), callback = function() plugin:showStoreSearch() end },
    }
end

--- App 榜（cell 榜 / 礼物榜）：**没有「加载更多」** —— 服务端分页无效（offset 被无视，
--- 回同一批 30 本），挂上去只会让用户以为能翻、点了却拿到重复书目。
local function app_rank_actions(plugin, menu)
    return {
        view_action(plugin, menu),
        { text = _("重新加载"), callback = function()
            -- 手动重载要**绕过缓存**：否则「刷新了还是旧数据」（缓存 TTL 10 分钟）
            local st = menu._store_state
            if st and plugin._store_rank_cache then
                plugin._store_rank_cache[app_rank_key(st)] = nil
            end
            reload_from_head(plugin, menu)
        end },
        { text = _("搜索"), callback = function() plugin:showStoreSearch() end },
    }
end

local function rank_category_actions(plugin, menu)
    return {
        load_more_action(plugin, menu),
        view_action(plugin, menu),
        { text = _("重新加载"), callback = function() reload_from_head(plugin, menu) end },
        { text = _("搜索"), callback = function() plugin:showStoreSearch() end },
    }
end

local function search_actions(plugin, menu)
    return {
        load_more_action(plugin, menu),
        view_action(plugin, menu),
        { text = _("重新搜索"), callback = function() plugin:showStoreSearch() end },
        { text = _("重新加载"), callback = function() reload_from_head(plugin, menu) end },
    }
end

--- 网页榜单菜单壳（最近更新 / 推荐榜 / 巅峰榜 —— 三个 kind 同一个菜单）。
--- `menu` 非 nil ⇒ **原地换 kind**（筛选行的「榜单 ▾」用它，不重开菜单、不闪）。
local function open_rank(plugin, kind, label, menu)
    if menu then
        switch_rank_kind(plugin, menu, kind, label)
        return menu
    end
    local state = {
        kind = kind,
        page_index = 0,
        has_more = true,
        loading = false,
        total = 0,
    }
    local m = make_menu(plugin, {
        title = _("书城"),
        subtitle = label,
        store_actions_title = _("榜单操作"),
        tabs_fn = function(x) return menu_tabs(plugin, x) end,
        filters_fn = function(x) return menu_filters(plugin, x) end,
    })
    m._store_state = state
    m._store_actions = rank_actions(plugin, m)
    load_page(plugin, m, 0, false)
    return m
end

--- App 榜单（v2.16.0）：cell/change（男频 11 榜 + 出版物 6 榜）与礼物榜共用。
--- 🔴 不挂「加载更多」也不挂 tab：服务端分页无效（offset 被无视，回同一批 30 本），
---    挂上去只会让用户以为能翻、点了却拿到重复书目。
---@param kind string "rank_app"（cell 榜）| "rank_praise"（礼物榜）
---@param rank_key string Store.APP_RANKS / Store.APP_PRAISE 里的 key
--- `menu` 非 nil ⇒ **原地换榜**（筛选行的「榜单 ▾」用它）。
---@param kind string "rank_app"（cell 榜）| "rank_praise"（礼物榜）
---@param rank_key string Store.APP_RANKS / Store.APP_PRAISE 里的 key
local function open_rank_app(plugin, kind, rank_key, label, menu)
    if menu and menu._store_state then
        -- 原地换榜：改写 state 后重拉，不重开菜单 ⇒ 不闪、不丢浏览位置；
        -- 缓存命中时几乎瞬时出结果（TTL 10 分钟，见 fetch_page 的榜单缓存分支）。
        local st = menu._store_state
        st.kind = kind
        st.rank_key = rank_key
        st.rank_label = label
        st.page_index = 0
        st.has_more = false
        st.total = 0
        -- 从网页榜 / 原创榜原地切进来时，清掉它们的专属字段（榜单版本 / 性别等）
        st.rank_version = nil
        menu._store_subtitle = label
        refresh_menu_actions(plugin, menu)
        reload_from_head(plugin, menu)
        return menu
    end
    local state = {
        kind = kind,
        rank_key = rank_key,
        rank_label = label,
        page_index = 0,
        has_more = false,
        loading = false,
        total = 0,
    }
    local m = make_menu(plugin, {
        title = _("书城"),
        subtitle = label,
        store_actions_title = _("榜单操作"),
        -- App 榜**没有 tab 行**（25 个榜放不下）：筛选行的「榜单：xx ▾」就是它的切换入口，
        -- 所以「换榜单」不再挂在操作框里。
        filters_fn = function(x) return menu_filters(plugin, x) end,
    })
    m._store_state = state
    m._store_actions = app_rank_actions(plugin, m)
    load_page(plugin, m, 0, false)
    return m
end

--- 原创榜（男频/女频 × 阅读榜/新书榜 × 分类）。
--- 接口 /api/rank/category/list 详见 store.lua 顶部清单：性别与榜别都是
--- 站点自己的枚举（1=男频/0=女频、1=新书榜/2=阅读榜）。
--- `menu` 非 nil ⇒ **原地切换**（筛选行的「榜单 ▾」从别的榜切进原创榜时用它）。
open_rank_category = function(plugin, gender, mold, category, menu)
    if menu then
        apply_rank_category(plugin, menu, gender, mold, category)
        return menu
    end
    local state = {
        kind = "rank_category",
        gender = gender,
        rank_mold = mold,
        category_id = category and tonumber(category.category_id) or nil,
        category_name = category and category.name or "",
        -- 空串交给服务端解析当前榜单版本；load_page 收到响应后写回真实版本
        rank_version = "",
        page_index = 0,
        has_more = true,
        loading = false,
        total = 0,
    }
    local label = Store.gender_label(gender) .. Store.rank_mold_label(mold)
    if state.category_name ~= "" then label = label .. " · " .. state.category_name end
    local m = make_menu(plugin, {
        title = _("书城"),
        subtitle = label,
        store_actions_title = _("榜单操作"),
        tabs_fn = function(x) return menu_tabs(plugin, x) end,
        filters_fn = function(x) return menu_filters(plugin, x) end,
    })
    m._store_state = state
    m._store_actions = rank_category_actions(plugin, m)
    load_page(plugin, m, 0, false)
    return m
end

--- 原创榜的分类入口列表：只取「主分类」，与榜单页列出的 19/18 项集合完全一致
--- （实测两边 category_id 集合逐一相同：男频 19 个、女频 18 个）。
--- 传了 menu 就**原地应用**（不重开菜单）；没传（榜单入口链上来的）才开新菜单。
local function rank_category_entries(plugin, gender, mold, list, menu)
    local entries = {}
    local function on_pick(c)
        if menu then
            apply_rank_category(plugin, menu, gender, mold, c)
        else
            open_rank_category(plugin, gender, mold, c)
        end
    end
    for _i, c in ipairs(list or {}) do
        if c.label == "主分类" then
            entries[#entries + 1] = {
                text = c.name,
                callback = function() on_pick(c) end,
            }
        end
    end
    if #entries == 0 then
        -- 分类树拿不到「主分类」（接口异常/字段变了）时，别给用户一个空菜单
        for _i, c in ipairs(list or {}) do
            entries[#entries + 1] = {
                text = c.name,
                callback = function() on_pick(c) end,
            }
        end
    end
    return entries
end

--- 选分类（只列「主分类」，与榜单页列出的 19/18 项完全一致）。
--- 分类树复用书城那份 `category_list`，不再单独请求榜单接口。
--- menu 参数：榜单菜单的「换分类」传自己进来 → 选中后原地换，不重开菜单。
open_rank_categories = function(plugin, gender, mold, menu)
    local rank_label = Store.gender_label(gender) .. Store.rank_mold_label(mold)
    ensure_categories(plugin, gender, function(list)
        StoreView.show_chooser{
            title = T(_("%1 · 选择分类"), rank_label),
            entries = rank_category_entries(plugin, gender, mold, list, menu),
        }
    end)
end

local function open_search(plugin, keyword)
    local state = {
        kind = "search",
        keyword = keyword,
        page_index = 0,
        has_more = true,
        loading = false,
        total = 0,
    }
    local menu = make_menu(plugin, {
        title = _("书城搜索"),
        subtitle = keyword,
        store_actions_title = _("搜索操作"),
        -- 搜索菜单**没有** tab 行与筛选行（分派器按 kind="search" 返回 nil）——
        -- 省下来的高度全给列表。
        tabs_fn = function(m) return menu_tabs(plugin, m) end,
        filters_fn = function(m) return menu_filters(plugin, m) end,
    })
    menu._store_state = state
    menu._store_actions = search_actions(plugin, menu)
    load_page(plugin, menu, 0, false)
end

local function open_categories(plugin, gender)
    -- v2.16.0 压平：分组与分类合成**一层**选择器（分组做文字前缀），
    -- 不再「分组 → 分类」两层弹窗。树复用 ensure_categories 的缓存。
    ensure_categories(plugin, gender, function(list)
        local entries = {}
        local groups = Store.group_categories(list)
        for _i, g in ipairs(groups) do
            -- 组间分隔头（不可点），同 show_library_categories —— 压平列表没有分组头没法扫
            entries[#entries + 1] = {
                separator = true,
                text = T(_("── %1（%2）──"), g.label, tostring(#(g.items or {}))),
            }
            for _j, c in ipairs(g.items or {}) do
                local label = c.name
                if g.label ~= "主分类" then
                    label = g.label .. "·" .. c.name
                end
                entries[#entries + 1] = {
                    text = label,
                    callback = function() open_library(plugin, gender, c) end,
                }
            end
        end
        if #entries == 0 then
            entries[1] = { text = _("（没有分类）") }
        end
        entries[#entries + 1] = { text = _("全部"), callback = function()
            open_library(plugin, gender, nil, nil)
        end }
        StoreView.show_chooser{
            title = T(_("分类 · %1"), Store.gender_label(gender)),
            entries = entries,
        }
    end)
end

-- ------------------------------------------------------------------ 控件行分派
--
-- v2.16.0：书城所有列表菜单共用同一套「三块区域」模型 ——
--
--   ┌ tab 行 ────── 一级导航：去哪（男频/女频/榜单/搜索 · 阅读榜/新书榜 · …）
--   ├ 筛选行 ────── 这一屏显示什么：排序/状态/分类 · 性别/分类 · 榜单
--   ├ 列表
--   └ 操作框 ────── 动作：显示方式 / 加载更多 / 重新加载 / 搜索
--
-- 三块内容**全部按 `state.kind` 现算**（tab 与筛选行每次重绘求值，操作框在 kind
-- 变化时由 refresh_menu_actions 重建）。好处：原地换榜单/换频道时三块自动跟着 state
-- 走，不会出现「tab 换了、筛选行还是上一屏的按钮」这种半新半旧的状态。
-- 改造前的形态是「导航在 tab、筛选藏在操作框」两套交互 —— 用户反馈「有点割裂」。

menu_tabs = function(plugin, menu)
    local st = menu._store_state or {}
    if st.kind == "library" then return library_tabs(plugin, menu) end
    if st.kind == "rank_category" then return rank_category_tabs(plugin, menu) end
    if st.kind == "rank_recent" or st.kind == "rank_recommend" or st.kind == "rank_top" then
        return rank_list_tabs(plugin, menu)
    end
    -- search / rank_app / rank_praise：没有 tab 行
    return nil
end

menu_filters = function(plugin, menu)
    local st = menu._store_state or {}
    if st.kind == "library" then return library_filters(plugin, menu) end
    if st.kind == "rank_category" then return rank_category_filters(plugin, menu) end
    if st.kind == "rank_recent" or st.kind == "rank_recommend" or st.kind == "rank_top"
        or st.kind == "rank_app" or st.kind == "rank_praise" then
        return rank_filters(plugin, menu)
    end
    -- search：没有筛选行
    return nil
end

menu_actions = function(plugin, menu)
    local st = menu._store_state or {}
    if st.kind == "library" then return library_actions(plugin, menu) end
    if st.kind == "search" then return search_actions(plugin, menu) end
    if st.kind == "rank_app" or st.kind == "rank_praise" then
        return app_rank_actions(plugin, menu)
    end
    if st.kind == "rank_category" then return rank_category_actions(plugin, menu) end
    return rank_actions(plugin, menu)
end

-- ------------------------------------------------------------------ 对外入口

--- 书城入口（挂在「番茄小说」主菜单下）。
--- v2.16.0：**直达书库列表**（男频 · 全部分类），不再先弹「分类浏览 / 排行榜 / 搜索」
--- 选择器 —— 频道切换 / 换分类用列表顶部的 **tab 栏**原地完成，榜单与搜索也摆在
--- tab 栏里（点一下就到，省掉两层弹窗）。上次浏览的频道会被记住。
function StoreUI.showStore(self)
    local plugin = self
    local gender = plugin._store_gender or Store.GENDER.male
    plugin._store_gender = gender
    open_library(plugin, gender, nil, nil)
end

--- 分类浏览：先选男频/女频，再选分类分组与具体分类。
function StoreUI.showStoreBrowser(self)
    local plugin = self
    local last = plugin._store_gender
    local entries = {
        { text = _("男频"), callback = function()
            plugin._store_gender = Store.GENDER.male
            open_categories(plugin, Store.GENDER.male)
        end },
        { text = _("女频"), callback = function()
            plugin._store_gender = Store.GENDER.female
            open_categories(plugin, Store.GENDER.female)
        end },
    }
    if last ~= nil then
        table.insert(entries, 1, {
            text = T(_("继续上次（%1）"), Store.gender_label(last)),
            callback = function() open_categories(plugin, last) end,
        })
    end
    StoreView.show_chooser{ title = _("分类浏览"), entries = entries }
end

--- 排行榜（v2.16.0：接入 App 端榜单——男频 11 榜 / 出版物 6 榜 / 礼物榜 4 榜）。
--- 分组用**分隔头**（不可点条目，见 StoreView.show_chooser 的 separator 分支），
--- 29 个条目压平后没有分组头就是一串没结构的长列表。
--- 排行榜入口：分组列出全部榜单（网页 5 + 男频 11 + 出版物 6 + 礼物 4）。
--- `menu` 非 nil ⇒ 选中后**原地换榜**（榜单菜单的筛选行「榜单 ▾」走这条路）；
--- 不传 ⇒ 开新菜单（书库 tab 栏的「榜单」是**导航**，返回时应回到书库，不能原地顶掉它）。
function StoreUI.showStoreRanks(self, menu)
    local plugin = self
    local entries = {
        { separator = true, text = _("── 网页榜单 ──") },
        { text = _("最近更新"), callback = function() open_rank(plugin, "rank_recent", _("最近更新"), menu) end },
        { text = _("推荐榜"), callback = function() open_rank(plugin, "rank_recommend", _("推荐榜"), menu) end },
        -- 巅峰榜（首页同款）：固定 30 本全站总榜，明文书名 + 封面（v2.16.0）
        { text = _("巅峰榜"), callback = function() open_rank(plugin, "rank_top", _("巅峰榜"), menu) end },
        -- 原创榜（番茄原创作品榜）：男频/女频 × 阅读榜/新书榜，各自再选分类。
        -- 点击进入后先选榜别，再选分类 —— 省掉一层「性别」是因为榜名自带了性别。
        { text = Store.gender_label(Store.GENDER.male) .. _("原创榜"), callback = function()
            StoreView.show_chooser{
                title = T(_("%1 · 原创榜"), Store.gender_label(Store.GENDER.male)),
                entries = {
                    { text = _("阅读榜"), callback = function()
                        open_rank_categories(plugin, Store.GENDER.male, Store.RANK_MOLD.read, menu) end },
                    { text = _("新书榜"), callback = function()
                        open_rank_categories(plugin, Store.GENDER.male, Store.RANK_MOLD.new, menu) end },
                },
            }
        end },
        { text = Store.gender_label(Store.GENDER.female) .. _("原创榜"), callback = function()
            StoreView.show_chooser{
                title = T(_("%1 · 原创榜"), Store.gender_label(Store.GENDER.female)),
                entries = {
                    { text = _("阅读榜"), callback = function()
                        open_rank_categories(plugin, Store.GENDER.female, Store.RANK_MOLD.read, menu) end },
                    { text = _("新书榜"), callback = function()
                        open_rank_categories(plugin, Store.GENDER.female, Store.RANK_MOLD.new, menu) end },
                },
            }
        end },
    }

    -- App 榜单：直接由目录生成（新增榜只要往 Store.APP_RANKS 里加一行）
    local groups = {
        { id = "male", header = _("── 男频榜单 ──") },
        { id = "pub", header = _("── 出版物榜单 ──") },
    }
    for _i, g in ipairs(groups) do
        entries[#entries + 1] = { separator = true, text = g.header }
        for _j, r in ipairs(Store.APP_RANKS) do
            if r.group == g.id then
                local label = _(r.label)
                entries[#entries + 1] = {
                    text = label,
                    callback = function() open_rank_app(plugin, "rank_app", r.key, label, menu) end,
                }
            end
        end
    end

    entries[#entries + 1] = { separator = true, text = _("── 礼物榜 ──") }
    for _i, r in ipairs(Store.APP_PRAISE) do
        local label = _(r.label)
        entries[#entries + 1] = {
            text = label,
            callback = function() open_rank_app(plugin, "rank_praise", r.key, label, menu) end,
        }
    end

    StoreView.show_chooser{ title = _("排行榜"), entries = entries }
end

--- 搜索（输入框 → 结果列表）。
function StoreUI.showStoreSearch(self)
    local plugin = self
    local InputDialog = require("ui/widget/inputdialog")

    -- 防叠加：上一个搜索输入框还开着就先收掉（连点两次「搜索」会叠两层）
    local prev = plugin._store_search_dialog
    if prev then
        plugin._store_search_dialog = nil
        H.close_widget(prev)
    end

    local dialog
    local function dismiss()
        plugin._store_search_dialog = nil
        if dialog then H.close_widget(dialog) end
        dialog = nil
    end

    dialog = InputDialog:new{
        title = _("搜索书城"),
        input = plugin._store_last_keyword or "",
        buttons = { {
            {
                text = _("取消"),
                callback = dismiss,
            },
            {
                text = _("搜索"),
                is_enter_default = true,
                callback = function()
                    local keyword = dialog:getInputText()
                    if not keyword or keyword == "" then
                        -- 静默 return 会让用户以为「点了没反应」；对齐 main.lua「跳转到第 N 章」的做法
                        plugin:showInfo(_("请输入搜索关键字"))
                        return
                    end
                    plugin._store_last_keyword = keyword
                    dismiss()
                    open_search(plugin, keyword)
                end,
            },
        } },
    }
    plugin._store_search_dialog = dialog
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 加入 / 移出书架（异步）。
---@param add boolean true=加入，false=移出
---@param on_done function|nil function(ok:boolean, added:boolean) 完成后回调（可选）
function StoreUI.toggleStoreShelf(self, book, add, on_done)
    local plugin = self
    if not book or not book.book_id then return end
    if not plugin:checkNetwork() then return end

    plugin:showBusy(add and _("正在加入书架…") or _("正在移出书架…"))
    local client = plugin.client
    local book_id = tostring(book.book_id)
    local want_add = add == true

    Async.run(function()
        if want_add then
            local r, e = Store.shelf_add(client, book_id)
            return { ok = (r ~= nil), err = e }
        end
        local r, e = Store.shelf_remove(client, book_id)
        return { ok = (r ~= nil), err = e }
    end, function(ok, res, err)
        plugin:closeBusy()
        if not ok or type(res) ~= "table" or not res.ok then
            local e2 = (type(res) == "table" and res.err) or err
            plugin:showError(T(_("操作失败：%1"), err_text(e2)))
            if on_done then on_done(false, want_add) end
            return
        end
        invalidate_shelf(plugin)
        -- 把这次操作的结果写进「书架状态快照」——清缓存只会把**完整快照**作废
        -- （State.clearShelfAll），但这本书是刚刚亲手操作过的，结论确定无疑。
        -- 阅读端菜单文案（「加入书架」/「移出书架」）与「退出时是否提示加入书架」
        -- 都读这份快照，靠的就是这里（见 state.lua 的同名小节）。
        if State and State.markShelf then State.markShelf(book_id, want_add) end
        plugin:showInfo(want_add and _("已加入书架") or _("已移出书架"))
        if on_done then on_done(true, want_add) end
    end, {
        poll_interval = 0.3,
        timeout = 30,
        tag = ASYNC_TAG,
        -- ⚠️ 取消后 on_done 不会再执行，loading 必须在这里自己关，否则界面永久卡在 loading
        on_cancel = function() pcall(function() plugin:closeBusy() end) end,
    })
end

--- 书城书籍详情（**先判书架状态，再决定那颗书架按钮的方向**）。
--
-- 🔴 v2.12.0 收敛：以前这里把「加入书架」「移出书架」**两颗一起摆**，而
--    `bookshelf/delete` 是**幂等**的（不在书架也回 `{"code":0,"message":"SUCCESS"}`）
--    ⇒ 对一本**根本不在书架**的书点「移出书架」，插件会一本正经地提示
--    「已移出书架」——一句谎话。现在用 `shelf_check`（39 字节，判据
--    `code==0 and data==1`）先问一次，只给**一个方向**。
-- 判不出来（离线 / 未登录 / 接口异常）时**干脆不给书架按钮**，
-- 只留「简介 / 开始阅读 / 章节目录 / 下载」——宁可不给，也不给一个方向未知的按钮。
function StoreUI.showStoreBookDetail(self, book)
    local plugin = self
    if type(book) ~= "table" or not book.book_id then return end
    if not plugin:checkNetwork() then return end

    local client = plugin.client
    local book_id = tostring(book.book_id)

    plugin:showBusy(_("正在获取书籍信息…"))
    Async.run(function()
        local on_shelf, err = Store.shelf_check(client, book_id)
        return { on_shelf = on_shelf, err = err }
    end, function(ok, res)
        plugin:closeBusy()
        local on_shelf = nil
        if ok and type(res) == "table" and type(res.on_shelf) == "boolean" then
            on_shelf = res.on_shelf
        end
        plugin:buildBookDetailDialog(book, {
            on_shelf = on_shelf,
            -- 书城列表项没有本地缓存概念
            cache_ok = false,
            -- 「开始阅读 / 章节目录」前把书城菜单收掉，否则读完回来还压着一层
            on_leave = function() close_store_menu(plugin) end,
        })
    end, {
        poll_interval = 0.3,
        timeout = 30,
        tag = ASYNC_TAG,
        on_cancel = function() pcall(function() plugin:closeBusy() end) end,
    })
end

return StoreUI
