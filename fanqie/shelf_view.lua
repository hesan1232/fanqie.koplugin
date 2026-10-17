--[[--
书架显示层：列表 / 封面网格两种模式 + 排序 / 搜索。

职责边界：本模块**只渲染**，不发起网络请求；数据由 main.lua 准备好后传进来。

两种显示模式（v2.13.0 起）：
  * `list` 列表行 —— 封面 + 加粗书名 + 「作者 · 连载状态 · 122/256 章」，一页 7 行；
  * `grid` 封面网格 —— 密铺封面 + 封面下单行书名 + 章节进度 + 连载状态徽章，档位由用户直接选
    「列×行」（3×3 / 3×4 / 4×3 / 4×4，或自定义填 列x行；列 2~8、行 1~8），
    每页条数 = 列数 × 行数。行数是**显式**的（v2.15.0 改，此前是按封面高反推，
    见 `fanqie/cover_cell` 文件头）。
模式与布局存在 `settings.ui.shelf` / `settings.ui.grid_cols` / `settings.ui.grid_rows`，
两个视图各自一份。

⚠️ 复用 `Menu` 而不是自造全屏控件：`Menu` 已经替我们处理好了
  标题栏（含左上角按钮回调）、底部分页条、左右滑动翻页、`onGotoPage`、
  以及**焦点管理的 mosaic 模式**（`updatePageInfo` 看到 `self.layout[1]` 有多个
  元素就按网格算焦点坐标）。自造一套要重写这些，还得处理 Kindle 的按键导航。

@module fanqie.shelf_view
--]]

local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local UIManager = require("ui/uimanager")

local CoverCell = require("fanqie.cover_cell")
-- S：设计令牌（尺寸 / 配色 / 圆角封面 / 进度条）。书架与书城共用同一套，
-- 避免「书架行距和书城不一样」这种改一处忘一处的问题。
local S = require("fanqie.ui_style")
-- H.close_widget：只关「确实还在 UIManager 栈上」的对话框。
-- 菜单关闭 / 重复打开对话框时用来收掉浮在菜单之上的子对话框，
-- 并避免对已经关掉的对象再 close 一次（那样会凭空触发一次 flashui 全刷）。
local H = require("fanqie.helper")

-- 🔴 ShelfView 必须在 ShelfMenu 之前声明：
-- ShelfMenu:onLeftButtonTap 闭包内引用 ShelfView（排序/搜索对话框），
-- 若声明在后，闭包创建时该局部变量还不存在 → 解析成全局 nil → 点击即崩。
local ShelfView = {}

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
-- T 必须是 util.template（%1/%2 占位符）；写成 _ 的话占位符会**原样显示**。
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

--- 书籍**连载状态**标签 —— 书架条目上要显示的那一个词。
---
--- 口径与书城（store_view 的状态徽章）保持一致，也就是 kindle-forge
--- `FanqieShelf.vue:formatStatus` 的判定顺序：
---   1. `creation_status == 0` → 已完结
---   2. `update_stop == 1`      → 已断更（只有 "1" 算断更，"2" 不是）
---   3. 作者最后更新时间 **晚于** 上次阅读时间 → 更新（有未读新章）
---   4. 否则 → 连载中
--- 字段来源见 bookshelf.lua 的 book 构造表（creation_status / update_stop /
--- last_chapter_update_time / read_timestamp 全在）。
---
--- ⚠️ 以前这里显示的是**阅读进度**（「12/100章」「35.0%」「已读完」），那是「读到哪了」，
---    不是「书是什么状态」。两者别混：进度已经由书架排序（按阅读进度）承担，
---    条目上要留给「更新/完结/断更/连载」这类**作品**信息。
local function book_status_tag(book)
    if type(book) ~= "table" then return nil end
    if tonumber(book.creation_status) == 0 then return _("已完结") end
    if tonumber(book.update_stop) == 1 then return _("已断更") end
    local last_update = tonumber(book.last_chapter_update_time) or 0
    local read_ts = tonumber(book.read_timestamp) or 0
    if last_update > 0 and read_ts > 0 and last_update > read_ts then
        return _("更新")
    end
    return _("连载中")
end

--- 书籍**章节进度**文案 —— 「我读到哪了 / 还有多少没读」。
---
--- 两种形态：
---   * 从没读过（`read_chapters <= 0`）→ `未读 256 章`（直接给「多少未读」）；
---   * 读过 → `122/256 章`（已读 / 总章）。
--- 总章数拿不到时返回 nil ⇒ 条目上就不显示这一行（服务端偶尔不给 `serial_count`）。
---
--- ⚠️ 与 `book_status_tag` 是**两件事**，别合并：
---    状态说的是**作品**（更新 / 完结 / 断更 / 连载），这里说的是**我读到哪了**。
---    书城的书**没有** `read_chapters`（那是书架专有的服务端进度字段）⇒
---    书城条目自然拿不到这一段，也不该有。
local function book_chapter_text(book)
    if type(book) ~= "table" then return nil end
    local total = tonumber(book.total_chapters) or 0
    if total <= 0 then return nil end
    local read = tonumber(book.read_chapters) or 0
    if read < 0 then read = 0 end
    if read > total then read = total end
    if read <= 0 then return T(_("未读 %1 章"), tostring(total)) end
    return T(_("%1/%2 章"), tostring(read), tostring(total))
end

-- ---------------------------------------------------------------------------
-- 列表行的条目控件
-- ---------------------------------------------------------------------------

local ShelfItem = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
}

function ShelfItem:init()
    self.ges_events = {
        TapSelect = {GestureRange:new{ges="tap", range=self.dimen}},
        HoldSelect = {GestureRange:new{ges="hold", range=self.dimen}},
    }

    local h = self.dimen.h
    local side = S.sz(4)
    local show_cover = self.entry.show_cover ~= false
    local cover_h = math.max(S.sz(54), h - side * 2)
    local cover_w = show_cover and math.max(1, math.floor(cover_h * 0.69)) or 0
    local cover
    if show_cover then
        -- 圆角 + 1px 细描边（外框尺寸即 cover_w × cover_h）
        cover = select(1, S.cover(self.entry.cover_path, cover_w, cover_h))
    end

    local gap = show_cover and S.sz(12) or 0
    local text_w = math.max(S.sz(120), self.dimen.w - cover_w - gap - side * 2)
    local title = TextBoxWidget:new{
        text = tostring(self.entry.title or _("未命名")),
        face = S.face("cfont", 18),
        width = text_w,
        height = math.floor(h * .46),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        bold = true,
    }

    local details = tostring(self.entry.author or "")
    if details ~= "" and tostring(self.entry.status or "") ~= "" then details = details .. " · " end
    details = details .. tostring(self.entry.status or "")
    -- 「读到哪了」接在状态后面（`作者 · 连载中 · 122/256 章`）。
    -- 窄屏一行排不下时 TextBoxWidget 会**折行**（下面 height 给到 h*.32 就是为这个），
    -- 折不下才省略号 —— 所以它必须排在状态之后，被截掉的永远是章节数而不是「完结/断更」。
    if tostring(self.entry.chapters or "") ~= "" then
        if details ~= "" then details = details .. " · " end
        details = details .. tostring(self.entry.chapters)
    end
    local info = TextBoxWidget:new{
        text = details,
        face = S.face("smallinfofont", 14),
        width = text_w,
        -- h*.26 只够一行；加章节进度后窄屏会折成两行，给到 .32 才不会把第二行截掉
        height = math.floor(h * .32),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = S.muted,
    }

    -- ⚠️ VerticalSpan 的高度字段叫 **width**（见 koreader verticalspan.lua：`return {w=0, h=self.width}`）。
    --    写成 `height = ...` 不会报错，只是那个间隔**恒为 0**。
    local text_group = VerticalGroup:new{
        align = "left",
        title,
        VerticalSpan:new{width = S.sz(2)},
        info,
    }
    -- 🔴 这里以前挂的是一条「读到哪了」的**细进度条**（S.progressBar）。已按要求去掉：
    --    书架条目只保留两行文字 —— 条目高度是固定的（一页 7 行），
    --    那条进度条既挤掉书名/作者的行高，也和状态标签抢同一眼注意力。
    --    现在「读到哪了」改由**文字**承担（上面的 `entry.chapters`：`122/256 章` /
    --    `未读 256 章`）—— 比一条没有刻度的细条信息量大，也不占额外行高。

    local row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{width = side},
    }
    if cover then
        table.insert(row, cover)
        table.insert(row, HorizontalSpan:new{width = gap})
    end
    table.insert(row, LeftContainer:new{dimen=Geom:new{w=text_w, h=h}, text_group})
    table.insert(row, HorizontalSpan:new{width = side})

    -- 选中态用的浅底：常驻一个 FrameContainer（默认无背景 = 不画），
    -- 尺寸不随选中变化 ⇒ 不会引起重排/抖动（墨水屏最怕整页重绘）。
    self._row = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = nil,
        width = self.dimen.w,
        height = h,
        row,
    }

    self._underline = UnderlineContainer:new{
        dimen = self.dimen:copy(),
        linesize = S.sz(1),
        -- 发丝线：0xDD 而非旧版的深灰，一屏 7 行时不再像「表格框」
        color = S.rule,
        padding = 0,
        vertical_align = "center",
        self._row,
    }
    self[1] = self._underline
end

function ShelfItem:onTapSelect(arg, ges)
    local pos
    local dimen = self[1] and self[1].dimen
    if dimen and ges and ges.pos then
        pos = {
            x=(ges.pos.x - dimen.x) / math.max(1, dimen.w),
            y=(ges.pos.y - dimen.y) / math.max(1, dimen.h),
        }
    end
    self.menu:onMenuSelect(self.entry, pos)
    return true
end

function ShelfItem:onHoldSelect()
    if self.entry and self.entry.hold_callback then self.entry.hold_callback() end
    return true
end

function ShelfItem:onFocus()
    if self._row then self._row.background = S.surface end
    if self._underline then self._underline.color = S.ink end
    return true
end

function ShelfItem:onUnfocus()
    if self._row then self._row.background = nil end
    if self._underline then self._underline.color = S.rule end
    return true
end

-- ---------------------------------------------------------------------------
-- 菜单
-- ---------------------------------------------------------------------------

local ShelfMenu = Menu:extend{
    on_page_changed = nil,
    on_close_callback = nil,
    _miu_closed = false,
    _suppress_page_callback = false,
}

-- 左上角按钮：弹出操作菜单（参考 koobone 系列视图：刷新 / 排序 / 搜索）
function ShelfMenu:onLeftButtonTap()
    local opts = self._shelf_opts
    local ButtonDialog = require("ui/widget/buttondialog")

    -- 🔴 对话框引用必须挂在 menu 上，不能是局部变量。局部变量只有本次调用看得见：
    --   ① 菜单自己被关掉时（后台刷新完成会 close 旧菜单重建、返回键关菜单），
    --      没人能顺带收掉它 → **弹窗永远留在屏幕上**（UIManager:close(menu) 只移除
    --      menu 自己，不会动它上面的 widget）；
    --   ② 连点两次左上角按钮会叠出第二个对话框，第一个再也关不掉。
    --   这就是「书架弹窗有时候不会消失」。
    local function drop_action_dialog()
        local old = self._action_dialog
        self._action_dialog = nil
        if old then H.close_widget(old) end
    end
    drop_action_dialog()

    local filter = opts and opts.filter_text
    local search_label = (filter and filter ~= "")
        and (_("搜索") .. ": " .. filter) or _("搜索")

    local dialog = ButtonDialog:new{
        title = _("书架操作"),
        title_align = "center",
        buttons = {
            {{
                text = _("刷新书架"),
                callback = function()
                    drop_action_dialog()
                    if self._on_refresh then self._on_refresh() end
                end,
            }},
            {{
                text = _("显示方式") .. "（" .. ShelfView.view_label(self) .. "）",
                callback = function()
                    drop_action_dialog()
                    ShelfView.show_view_dialog(self)
                end,
            }},
            {{
                text = _("排序方式") .. (opts and opts.sort_label and ("（" .. opts.sort_label .. "）") or ""),
                callback = function()
                    drop_action_dialog()
                    ShelfView.show_sort_dialog(self)
                end,
            }},
            {{
                text = search_label,
                callback = function()
                    drop_action_dialog()
                    ShelfView.show_search_dialog(self)
                end,
            }},
            {{ text = _("关闭"), callback = drop_action_dialog }},
        },
    }
    self._action_dialog = dialog
    UIManager:show(dialog)
end

function ShelfMenu:onMenuSelect(entry, pos)
    return Menu.onMenuSelect(self, entry)
end

--- 网格模式：按封面度量铺满一页。
--- perpage 必须在这里**重算**（列数×行数），不能沿用 `_recalculateDimen` 按
--- `items_per_page` 均分出来的值 —— 行数是「列宽 → 封面高 → 格高」反推的。
function ShelfMenu:buildGridItems(select_number, cols, rows)
    local pad = CoverCell.sidePad()
    -- title_extra 显式加上「章节进度行」与「细进度条」的高度：网格格高是按 rows
    -- 均分出来的，少算哪一行封面都会顶到文字上（`cell_h` 只夹到 `title_extra + 24`）。
    -- ⚠️ 进度条那 7px 以前漏了 ⇒ 内容恒比 cell_h 高，居中后上下各溢出一截（v2.16.17 补）。
    local m = CoverCell.metrics(self.inner_dimen.w - pad * 2,
                                self.available_height - S.sz(10), cols, {
                                    rows = rows,
                                    title_extra = CoverCell.titleExtra()
                                        + CoverCell.metaExtra()
                                        + CoverCell.progressExtra(),
                                })
    self._grid_metrics = m
    self.perpage = m.perpage
    self.page_num = self:getPageNumber(#self.item_table)
    if self.page > self.page_num then self.page = self.page_num end
    if self.page < 1 then self.page = 1 end

    local offset = (self.page - 1) * self.perpage
    for r = 1, m.rows do
        local row_group = HorizontalGroup:new{align = "top"}
        local cells = {}
        -- ⚠️ 两端各垫一个 sidePad：`Menu.item_group` 是 `VerticalGroup{align="left"}`，
        --    行不自己垫的话会**贴死左边**（右边却空出 2×pad），看上去像整体跑偏了。
        table.insert(row_group, HorizontalSpan:new{width = pad})
        for c = 1, m.cols do
            if c > 1 then
                table.insert(row_group, HorizontalSpan:new{width = m.gap})
            end
            local index = offset + (r - 1) * m.cols + c
            local entry = self.item_table[index]
            if entry then
                entry.idx = index
                if index == self.itemnumber then
                    select_number = (r - 1) * m.cols + c
                end
                local cell = CoverCell.build(entry, m)
                table.insert(row_group, cell)
                cells[#cells + 1] = cell
            else
                -- 末行缺位补一个等宽等高占位：否则 HorizontalGroup 会把最后几格居中，
                -- 看上去像「这一行的封面整体缩进了」。
                table.insert(row_group, Widget:new{
                    dimen = Geom:new{w = m.slot_w, h = m.cell_h},
                })
            end
        end
        table.insert(row_group, HorizontalSpan:new{width = pad})
        table.insert(self.item_group, row_group)
        if r < m.rows then
            table.insert(self.item_group, VerticalSpan:new{width = m.row_gap})
        end
        -- 焦点管理（DPad 设备）：mosaic 模式要求 layout 每行是一个数组
        table.insert(self.layout, cells)
    end
    return select_number
end

function ShelfMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    Menu._recalculateDimen(self, no_recalculate_dimen)

    local opts = self._shelf_opts or {}
    local mode, cols, rows = ShelfView.resolve_view(opts)
    self._view_mode = mode
    self._view_cols = cols
    self._view_rows = rows

    if mode == "grid" then
        select_number = self:buildGridItems(select_number, cols, rows)
    else
        -- 列表模式：perpage 由 items_per_page（7）决定，_recalculateDimen 已算好
        self._grid_metrics = nil
        local offset = (self.page - 1) * self.perpage
        for index_on_page = 1, self.perpage do
            local index = offset + index_on_page
            local entry = self.item_table[index]
            if not entry then break end
            entry.idx = index
            if index == self.itemnumber then select_number = index_on_page end
            local item = ShelfItem:new{
                entry = entry,
                menu = self,
                dimen = self.item_dimen:copy(),
            }
            table.insert(self.item_group, item)
            table.insert(self.layout, {item})
        end
    end

    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()
    UIManager:setDirty(self.show_parent, function()
        return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen
    end)
    if not self._suppress_page_callback and not self._miu_closed and self.on_page_changed then
        local page = tonumber(self.page) or 1
        local first = (page - 1) * self.perpage + 1
        local last = math.min(#self.item_table, first + self.perpage - 1)
        UIManager:scheduleIn(0, function()
            if not self._miu_closed and self.on_page_changed then
                pcall(self.on_page_changed, page, first, last, self)
            end
        end)
    end
end

function ShelfMenu:onCloseWidget()
    self._miu_closed = true
    -- ⚠️ 菜单自己关掉时，浮在它上面的子对话框**不会**跟着关：UIManager:close(menu)
    --    只从窗口栈里摘掉 menu 自己，menu 之上的操作/排序/搜索框原样留在屏幕上，
    --    而且没有任何入口能再操作它们（表现为「弹窗不消失，点也没反应」）。
    --    这里统一收掉。
    local function drop(field)
        local w = self[field]
        self[field] = nil
        if w then H.close_widget(w) end
    end
    drop("_action_dialog")
    drop("_sort_dialog")
    drop("_search_dialog")
    drop("_view_dialog")

    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback, self)
    end
    if Menu.onCloseWidget then return Menu.onCloseWidget(self) end
end

-- ===========================================================================
-- 显示方式（列表 / 封面网格）
-- ===========================================================================
-- 模式与列数各自持久化到 settings（`ui.shelf` / `ui.grid_cols`），改书城不影响书架。

--- 解析当前生效的显示方式。
--- settings 优先，其次 opts 覆盖（测试与「只改这一次」用得上）。
---@return string mode "list" | "grid"
---@return number cols 网格列数（2~8）
---@return number rows 网格行数（1~8；0 = 按屏高自动反推）
function ShelfView.resolve_view(opts)
    opts = opts or {}
    local settings = opts.plugin and opts.plugin.settings
    local mode = opts.view_mode
    if not mode and settings and settings.get_ui_view then
        mode = settings:get_ui_view("shelf")
    end
    if mode ~= "grid" then mode = "list" end
    local cols = opts.grid_cols
    if not cols and settings and settings.get_ui_grid_cols then
        cols = settings:get_ui_grid_cols()
    end
    local rows = opts.grid_rows
    if rows == nil and settings and settings.get_ui_grid_rows then
        rows = settings:get_ui_grid_rows()
    end
    -- 夹紧与「认不出来就回落默认档」统一交给 cover_cell（与菜单档位、metrics 同口径）
    return mode, CoverCell.normalize_layout(cols, rows)
end

--- 左上角菜单里显示的那个短标签（「列表」/「封面网格 3×4」）。
function ShelfView.view_label(menu)
    local opts = (menu and menu._shelf_opts) or {}
    local mode, cols, rows = ShelfView.resolve_view(opts)
    if mode == "grid" then
        return T(_("封面网格 %1"), CoverCell.layout_label(cols, rows))
    end
    return _("列表")
end

--- 「显示方式」对话框。按钮与「自定义列×行」输入框都在 cover_cell 里（书架/书城共用），
--- 这里只负责**往哪个 settings 键写**（书架的 `ui.shelf` / `ui.grid_*`）。
function ShelfView.show_view_dialog(menu)
    local opts = (menu and menu._shelf_opts) or {}
    local settings = opts.plugin and opts.plugin.settings
    local mode, cols, rows = ShelfView.resolve_view(opts)

    CoverCell.show_view_dialog{
        owner = menu, field = "_view_dialog",
        current_mode = mode, current_cols = cols, current_rows = rows,
        on_apply = function(new_mode, new_cols, new_rows)
            opts.view_mode = new_mode
            if new_cols then opts.grid_cols = new_cols end
            if new_rows then opts.grid_rows = new_rows end
            if settings then
                if settings.set_ui_view then settings:set_ui_view("shelf", new_mode) end
                if new_cols and settings.set_ui_grid_cols then settings:set_ui_grid_cols(new_cols) end
                if new_rows and settings.set_ui_grid_rows then settings:set_ui_grid_rows(new_rows) end
            end
            ShelfView.refresh(menu)
        end,
    }
end

-- ===========================================================================
-- 排序 / 搜索
-- ===========================================================================
-- 交互参考 koobone 的 shelf_view：同一个排序键再点一次翻正/倒序，当前键标 ✓，
-- 未生效的键显示它自己的默认方向，搜索关键字写进标题栏（[关键字]）。
-- 排序 / 过滤都是**显示层**行为：只对传入数组做浅拷贝后重排，
-- 绝不原地改动缓存数组（缓存里保持接口原始顺序）。
--
-- 各键默认方向：书名、加入书架用正序，其余倒序（最近阅读 / 进度高的排前面）。
-- 加入书架走正序是为了配合 sort_value 的缺失值哨兵：缺 shelf_index 时返回 math.huge，
-- 只有正序才把「没有顺序信息」的书排到末尾（last_read/progress 则用 0 + 倒序排末尾）。
local function default_asc(key) return key == "title" or key == "shelf_order" end

local SORT_LABELS = {
    last_read = _("按最后阅读"),
    title = _("按书名"),
    progress = _("按阅读进度"),
    shelf_order = _("按加入书架"),
}

local SORT_ORDER = { "last_read", "title", "progress", "shelf_order" }

local function sort_value(book, key)
    if key == "last_read" then
        -- 服务端 read_timestamp（unix 秒）；缺失按 0（排在最后）
        return tonumber(book.read_timestamp) or 0
    elseif key == "progress" then
        return tonumber(book.progress) or 0
    elseif key == "shelf_order" then
        -- 接口原始顺序（加入书架顺序）；缺失按极大值
        return tonumber(book.shelf_index) or math.huge
    end
    return 0
end

-- 取当前生效的排序（插件 settings 优先，其次 opts 覆盖）
local function resolve_sort(opts)
    opts = opts or {}
    local settings = opts.plugin and opts.plugin.settings
    local key, asc
    if settings and settings.get_shelf_sort then
        key = settings:get_shelf_sort()
        if settings.get_shelf_sort_asc then
            asc = settings:get_shelf_sort_asc()
        end
    end
    key = opts.sort_key or key or "last_read"
    if asc == nil then asc = opts.sort_asc end
    if asc == nil then asc = default_asc(key) end
    return key, asc == true
end

-- 浅拷贝 + 排序；返回新数组，缓存数组顺序不受影响
local function sort_books(books, key, asc)
    local list = {}
    for i, b in ipairs(books or {}) do list[i] = b end
    if not key then return list end
    -- 🔴 不能写成 `asc and (va < vb) or (va > vb)`：and/or 惯用法只在中间值**恒为真**
    -- 时才等价于三元表达式。这里中间值是 (va < vb)，本身可以是 false —— 那样会掉到
    -- `or (va > vb)` 分支，比较器对 (a,b) 与 (b,a) 同时返回 true、自相矛盾，导致方向
    -- 被整体反转（实测 asc=true 得到的就是倒序）。koobone 用的就是下面这种显式写法
    -- （bookshelf.lua:_sort_vols_catalog）。
    table.sort(list, function(a, b)
        local ta, tb = tostring(a.title or ""), tostring(b.title or "")
        if key == "title" then
            if ta ~= tb then
                if asc then return ta < tb end
                return ta > tb
            end
        else
            local va, vb = sort_value(a, key), sort_value(b, key)
            if va ~= vb then
                if asc then return va < vb end
                return va > vb
            end
            -- 主键相同：按书名兜底（方向跟随主排序），保证顺序稳定
            if ta ~= tb then
                if asc then return ta < tb end
                return ta > tb
            end
        end
        -- 最后按加入书架顺序兜底，绝不让 table.sort 产生不稳定结果
        return (tonumber(a.shelf_index) or 0) < (tonumber(b.shelf_index) or 0)
    end)
    return list
end

-- 关键字过滤：大小写不敏感的字面子串匹配（string.find 第 4 参 true = plain，
-- 关键字里的 . ( ) 等按字面处理而非 pattern）。匹配书名 + 作者。
local function make_matcher(filter)
    if not filter or filter == "" then return nil end
    local needle = string.lower(filter)
    return function(book)
        local fields = { book.title, book.author }
        -- 循环变量别叫 `_`：会遮蔽模块级 gettext（见文件头 local _ = ...）
        for _field_idx, f in ipairs(fields) do
            if f and f ~= "" and string.find(string.lower(tostring(f)), needle, 1, true) then
                return true
            end
        end
        return false
    end
end

local function compute_title(opts)
    local base = (opts and opts.title) or _("番茄书架")
    local f = opts and opts.filter_text
    if f and f ~= "" then base = base .. " [" .. f .. "]" end
    return base
end

-- 构造 ShelfItem / CoverCell 的 items 列表（show / update / refresh 复用）
local function build_items(books, opts)
    opts = opts or {}
    local matcher = make_matcher(opts.filter_text)
    local filtered = {}
    for _, book in ipairs(books or {}) do
        if not matcher or matcher(book) then filtered[#filtered + 1] = book end
    end
    local key, asc = resolve_sort(opts)
    local sorted = sort_books(filtered, key, asc)

    local items = {}
    for _, book in ipairs(sorted) do
        -- 连载状态标签：列表行挂在 `status`（作者行的第二段），网格挂在 `tag`
        -- （cover_cell 会渲染成一个小徽章）。两处同一个值，别只改一处。
        local tag = book_status_tag(book)
        local chapters = book_chapter_text(book)
        items[#items + 1] = {
            book_id = book.book_id or book.bookId,
            title = book.title,
            author = book.author,
            status = tag,
            tag = tag,
            -- 「读到哪了」：`122/256 章`（没读过 → `未读 256 章`）。列表行接在状态后、
            -- 网格里单独一行（见 cover_cell 的 entry.chapters 分支）。
            chapters = chapters,
            cover_path = book.cover_path,
            show_cover = opts.show_covers ~= false,
            -- 回指原始 book 对象：排序/搜索后 item 下标与 books 下标会错位，
            -- 封面链（main.lua `_cacheShelfPageCovers`）必须按 item 取书而不是按 books[index]。
            book = book,
            callback = function() if opts.on_select then opts.on_select(book) end end,
            hold_callback = function() if opts.on_hold then opts.on_hold(book) end end,
            -- 网格单元用这两个（CoverCell.build 只认 on_tap / on_hold）
            on_tap = function() if opts.on_select then opts.on_select(book) end end,
            on_hold = function() if opts.on_hold then opts.on_hold(book) end end,
        }
    end
    return items
end

-- opts 里补上排序键的中文标签，供左上角菜单显示「排序方式（按最后阅读）」
local function decorate_opts(opts)
    opts = opts or {}
    local key, asc = resolve_sort(opts)
    local label = SORT_LABELS[key] or key
    opts.sort_label = label .. "·" .. (asc and _("正序") or _("倒序"))
    opts._sort_key = key
    opts._sort_asc = asc
    return opts
end

-- 当前菜单原地重刷 items（不关闭菜单、保持页码）——排序/搜索/换显示方式后调用
function ShelfView.refresh(menu, books, opts)
    if not menu then return end
    opts = opts or menu._shelf_opts or {}
    if books then opts.books = books end
    local list = opts.books or menu._shelf_books or {}
    decorate_opts(opts)
    local items = build_items(list, opts)
    if #items == 0 and (opts.filter_text and opts.filter_text ~= "") then
        -- 过滤后为空：提示并保留原列表，否则菜单会因无条目而消失，用户再也没法清筛选
        opts.filter_text = nil
        decorate_opts(opts)
        items = build_items(list, opts)
        if UIManager and UIManager.show then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("没有匹配的结果，已清空筛选"),
                timeout = 3,
            })
        end
    end
    if #items == 0 then return end
    local current_page = tonumber(menu.page) or 1
    local perpage = menu.perpage or 7
    local first = (current_page - 1) * perpage + 1
    if first > #items then first = math.max(1, #items - perpage + 1) end
    menu._shelf_books = list
    -- switchItemTable 第二参数是 item_number（全局索引）；传新标题让标题栏真正更新
    pcall(function() menu:switchItemTable(compute_title(opts), items, first) end)
end

-- 排序对话框（ButtonDialog；同一个键再点一次翻方向）
function ShelfView.show_sort_dialog(menu)
    local opts = (menu and menu._shelf_opts) or {}
    local settings = opts.plugin and opts.plugin.settings
    local ButtonDialog = require("ui/widget/buttondialog")
    local key, asc = resolve_sort(opts)

    -- 关掉已有的排序框（引用挂在 menu 上，菜单关闭时 onCloseWidget 也会兜底清理）。
    -- 直接对已关闭的对象再 close 一次会凭空触发一次 flashui 全刷，所以走 close_widget。
    local function close_sort_dialog()
        if not menu then return end
        local old = menu._sort_dialog
        menu._sort_dialog = nil
        if old then H.close_widget(old) end
    end
    close_sort_dialog()

    local function toggle(key_clicked)
        if settings and settings.set_shelf_sort then
            if key == key_clicked then
                settings:set_shelf_sort_asc(not asc)
            else
                settings:set_shelf_sort(key_clicked)   -- 换键：清方向，由默认方向决定
            end
            if settings.flush then settings:flush() end
        else
            -- 无 settings（理论上不会发生）：退化为仅本次生效
            opts.sort_key = key_clicked
            if key == key_clicked then
                opts.sort_asc = not asc
            else
                opts.sort_asc = default_asc(key_clicked)
            end
        end
        ShelfView.refresh(menu)
    end

    local buttons = {}
    -- 🔴 循环变量**不能**叫 `_`：本模块的 gettext 就是局部名 `_`（见文件头），
    -- `for _, k in ...` 会在循环体内把它遮蔽成「数字下标」，循环里任何 `_("...")`
    -- 都变成调用一个 number → 一打开排序对话框就抛错（实测踩中）。
    for _sort_idx, k in ipairs(SORT_ORDER) do
        -- 未生效的键显示它自己的默认方向（与 koobone 一致）
        local shown_asc
        if k == key then shown_asc = asc else shown_asc = default_asc(k) end
        table.insert(buttons, {{
            text = (SORT_LABELS[k] or k) .. "（" .. (shown_asc and _("正序") or _("倒序")) .. "）"
                .. (k == key and "  ✓" or ""),
            callback = function()
                close_sort_dialog()
                toggle(k)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("取消"),
        callback = close_sort_dialog,
    }})

    menu._sort_dialog = ButtonDialog:new{
        title = _("排序方式"),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(menu._sort_dialog)
end

-- 搜索对话框（InputDialog；留空 = 清除筛选）
function ShelfView.show_search_dialog(menu)
    local opts = (menu and menu._shelf_opts) or {}
    local InputDialog = require("ui/widget/inputdialog")

    -- 同上：引用挂 menu（菜单关闭时兜底清理）+ 开新的之前先关旧的
    local function close_search_dialog()
        if not menu then return end
        local old = menu._search_dialog
        menu._search_dialog = nil
        if old then H.close_widget(old) end
    end
    close_search_dialog()

    local dialog
    local function dismiss()
        if menu then menu._search_dialog = nil end
        if dialog then H.close_widget(dialog) end
        dialog = nil
    end

    dialog = InputDialog:new{
        title = _("搜索书架"),
        input = opts.filter_text or "",
        input_hint = _("书名 / 作者关键字，留空清除"),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = dismiss,
                },
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText() or ""
                        text = text:match("^%s*(.-)%s*$") or ""
                        dismiss()
                        opts.filter_text = (text ~= "") and text or nil
                        if menu._shelf_opts and menu._shelf_opts ~= opts then
                            menu._shelf_opts.filter_text = opts.filter_text
                        end
                        ShelfView.refresh(menu)
                    end,
                },
            },
        },
    }
    if menu then menu._search_dialog = dialog end
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 启动书架。
---@param opts table { title, books, show_covers, filter_text, plugin, view_mode?,
---                    grid_cols?, grid_rows?, on_select, on_hold, on_close,
---                    on_refresh, on_page_changed }
---        view_mode / grid_cols / grid_rows 缺省时读 plugin.settings
---        （"list"|"grid" / 2..8 / 1..8，0 = 行数自动）。
function ShelfView.show(opts)
    opts = opts or {}
    decorate_opts(opts)
    local mode = ShelfView.resolve_view(opts)
    opts.view_mode = mode
    local items = build_items(opts.books or {}, opts)
    local page_callback
    if opts.on_page_changed then
        page_callback = function(page, first, last, current)
            if last >= first then
                opts.on_page_changed(page, first, last, current)
            end
        end
    end
    -- 🔴 `_shelf_opts` 必须**走构造表**传进去，不能 new 完再赋值：
    --    `Menu:init` 里就会调一次 `updateItems`，那时 `self._shelf_opts` 若还是 nil，
    --    `resolve_view` 读不到 plugin/settings ⇒ 首帧**永远按列表画**。而首帧之后
    --    只有「封面路径真的变了」才会再 updateItems，所以已缓存封面时这个列表会一直
    --    留在屏幕上 —— 用户看到的正是「设置里明明是网格，进来却是列表」。
    local menu = ShelfMenu:new{
        title = compute_title(opts),
        item_table = items,
        items_per_page = 7,
        is_borderless = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        on_close_callback = opts.on_close,
        on_page_changed = page_callback,
        -- 菜单绑定同一张 opts（排序/搜索/显示方式对话框据此原地重刷）
        _shelf_opts = opts,
        _shelf_books = opts.books or {},
    }
    menu._on_refresh = opts.on_refresh
    UIManager:show(menu)
    return menu
end

-- 动态更新书架菜单内容（不关闭重开，避免闪烁）
-- 刷新数据回来后直接 switchItemTable 更新，保持当前页
function ShelfView.update(menu, books, opts)
    if not menu then return end
    opts = opts or menu._shelf_opts or {}
    menu._shelf_books = books or {}
    opts.books = menu._shelf_books
    ShelfView.refresh(menu, menu._shelf_books, opts)
end

return ShelfView
