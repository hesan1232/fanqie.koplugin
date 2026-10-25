--[[--
书城显示层：分类浏览 / 排行榜 / 搜索结果。

职责边界（与书架一致）：
  * 本模块**只渲染**，不发起任何网络请求，不读写 settings；
  * 网络与菜单生命周期在 `fanqie/store_ui.lua`（main.lua 的 mixin）里编排。

对外接口：
  StoreView.show(opts)              → 书籍列表菜单（列表行 / 封面网格两种模式）
  StoreView.update(menu, books, opts) → 原地换表（翻页追加 / 刷新 / 换显示方式）
  StoreView.show_chooser(opts)      → 通用纯文本选择器（分类/排序/完本状态）
                                      · 短列表（≤8 项）→ 弹窗；长列表/带分组头 → 全屏菜单
  StoreView.resolve_view(opts)      → 当前生效的显示方式与网格列数
  StoreView.view_label(menu)        → 操作框里显示的那个短标签
  StoreView.show_view_dialog(menu)  → 「显示方式」对话框（列表 / 网格 3×3…4×4 / 自定义列×行）
  StoreView.meta_text(book)         → 一行元信息文案
  StoreView.cover_path(dir, book)   → 封面缓存路径（store_ui 下载时复用同一口径）

显示模式与书架同一套（见 fanqie/shelf_view.lua 顶部说明）：模式/列数存在
`settings.ui.store` / `settings.ui.grid_cols`，**与书架各自独立** —— 把书城切成
网格不该顺带把书架也改了。

🔴 v2.12.0 起**不再有** `StoreView.show_book_detail`：书籍详情对话框与书架共用
   main.lua 的 `buildBookDetailDialog`（字段合并见 fanqie/book_detail.lua）。
   原来的那份把内容塞进 `ButtonDialog.info_text` —— 而 `ButtonDialog` **没有这个字段**
   （见 MEMORY-koreader-core「上游组件事实」），那一屏书目信息其实一行都没显示过。
   随之删除的还有 `StoreView.close_detail`；「浮层不随菜单关闭」的守卫改为
   在 `StoreMenu:onCloseWidget` 里回调插件的收尾方法（见那里的注释）。
--]]

local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Button = require("ui/widget/button")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = Device.screen

local CoverCell = require("fanqie.cover_cell")
local S = require("fanqie.ui_style")

local Store = require("fanqie.store")
-- H.close_widget：只关「确实还在 UIManager 栈上」的对话框（避免重复 close
-- 凭空触发一次 flashui 全刷，见 fanqie/helper.lua 里的说明）。
local H = require("fanqie.helper")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
-- T 必须是 util.template（%1/%2 占位符）；写成 _ 的话占位符会**原样显示**。
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

local StoreView = {}

-- ------------------------------------------------------------------ 文案

--- 字数：数值型（搜索接口）与展示串（书库接口，已是「7935字」）两种口径。
local function word_text(v)
    if type(v) == "number" then
        if v >= 10000 then return string.format(_("%.1f万字"), v / 10000) end
        return string.format(_("%d字"), v)
    end
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

--- 阅读数：同上，书库接口返回的是「未满1000人在读」这种展示串。
local function read_text(v)
    if type(v) == "number" then
        if v >= 10000 then return string.format(_("%.1f万人在读"), v / 10000) end
        return string.format(_("%d人在读"), v)
    end
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

local function time_text(ts)
    local n = tonumber(ts)
    if not n or n <= 0 then return nil end
    return os.date("%Y-%m-%d", n)
end

--- 一行元信息：「作者 · 分类 · 4.5万字 · 1157人在读 · 连载中」
function StoreView.meta_text(book)
    if type(book) ~= "table" then return "" end
    local parts = {}
    local function push(v)
        if type(v) == "string" and v ~= "" then parts[#parts + 1] = v end
    end
    push(book.author)
    push(book.category)
    push(word_text(book.word_count))
    push(read_text(book.read_count))
    -- 状态优先用 multidetail 增强出来的 status_text（连载/完结/断更口径），
    -- 没拉到（未登录/失败）再退回书库接口自带的 creation_status 数字。
    -- creation_status 为 nil 时 creation_status_label 会返回「不限」，别把它当状态显示
    if type(book.status_text) == "string" and book.status_text ~= "" then
        push(book.status_text)
    elseif book.creation_status ~= nil then
        push(Store.creation_status_label(book.creation_status))
    end
    return table.concat(parts, " · ")
end

--- 状态短标签（网格徽章用）。判不出返回 nil（不画徽章，而不是画一个「不限」）。
function StoreView.status_tag(book)
    if type(book) ~= "table" then return nil end
    if type(book.status_text) == "string" and book.status_text ~= "" then
        return book.status_text
    end
    if book.creation_status ~= nil then
        local label = Store.creation_status_label(book.creation_status)
        -- creation_status_label(nil/未知) 会回「不限」，那不是状态，别当徽章显示
        if label and label ~= "" and label ~= _("不限") then return label end
    end
    return nil
end

--- 第二行（列表里显示在元信息下方）：「最近更新 2026-10-13 · 最新章节 第300章 …」
function StoreView.sub_text(book)
    if type(book) ~= "table" then return "" end
    local parts = {}
    -- 原创榜的「较上期变化」：正=上升、负=下降、0=持平
    if type(book.rank_diff) == "number" then
        if book.rank_diff > 0 then
            parts[#parts + 1] = string.format(_("较上期 ↑%d"), book.rank_diff)
        elseif book.rank_diff < 0 then
            parts[#parts + 1] = string.format(_("较上期 ↓%d"), -book.rank_diff)
        else
            parts[#parts + 1] = _("较上期 —")
        end
    end
    local t = time_text(book.update_time)
    if t then parts[#parts + 1] = string.format(_("更新于 %s"), t) end
    -- multidetail 增强的总章数（serial_count）
    if type(book.total_chapters) == "number" and book.total_chapters > 0 then
        parts[#parts + 1] = string.format(_("共 %d 章"), book.total_chapters)
    end
    if type(book.latest_chapter) == "string" and book.latest_chapter ~= "" then
        parts[#parts + 1] = book.latest_chapter
    end
    if type(book.last_chapter_title) == "string" and book.last_chapter_title ~= "" then
        parts[#parts + 1] = book.last_chapter_title
    end
    return table.concat(parts, " · ")
end

--- 封面缓存路径：**按 book_id 命名**（书库接口的书名是 PUA 解码得来的，
--- 且可能带 `/`、`:` 等非法字符；用 book_id 才稳定且不会互相覆盖）。
function StoreView.cover_path(dir, book)
    if type(book) ~= "table" or not book.book_id then return nil end
    local id = tostring(book.book_id):gsub("[^%w%-_]", "")
    if id == "" then return nil end
    return dir .. "/" .. id .. ".jpg"
end

-- ------------------------------------------------------------------ 控件行工具

--- 量一个控件行的高度（拿不到就 0 —— 高度只用来扣减列表可用区）。
local function row_height(row)
    if not row then return 0 end
    local ok_s, size = pcall(row.getSize, row)
    return (ok_s and type(size) == "table" and tonumber(size.h)) or 0
end

--- 屏幕逻辑宽度。⚠️ 桩环境（回归 harness）可能没实现 `getWidth` ⇒ 必须 pcall 兜底，
--- 否则「书城一打开就崩」——这类桩缺方法导致的崩溃在真机上不可复现、排查成本极高。
local function screen_width()
    local ok_w, w = pcall(function() return Screen:getWidth() end)
    if ok_w and type(w) == "number" and w > 0 then return w end
    return S.sz(600)
end

-- ------------------------------------------------------------------ 条目

local StoreItem = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
}

function StoreItem:init()
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
        cover = select(1, S.cover(self.entry.cover_path, cover_w, cover_h))
    end

    local gap = show_cover and S.sz(12) or 0
    local text_w = math.max(S.sz(120), self.dimen.w - cover_w - gap - side * 2)

    -- 标题行右侧的徽章（榜单名次 / 连载状态）。网格一直有（CoverCell 的 entry.tag），
    -- 列表此前漏了 —— 同一条数据两个视图一个有「连载中」一个没有，观感上就是「书城糙」。
    -- 先把徽章建出来量总宽，再让标题让位（max_width 省略号），两边不挤。
    local badges = {}
    if type(self.entry.rank) == "string" and self.entry.rank ~= "" then
        badges[#badges + 1] = S.badge(T(_("#%1"), self.entry.rank), 11)
    end
    if type(self.entry.tag) == "string" and self.entry.tag ~= "" then
        badges[#badges + 1] = S.badge(self.entry.tag, 11)
    end
    local badges_w, badges_h = 0, 0
    if #badges > 0 then
        for _i, b in ipairs(badges) do
            local s = b:getSize()
            badges_w = badges_w + s.w
            if s.h > badges_h then badges_h = s.h end
        end
        badges_w = badges_w + S.sz(4) * (#badges - 1)
    end

    -- 书名：单行 `TextWidget`（max_width 超宽省略号，与网格同一截断口径）。
    -- 此前用 TextBoxWidget 预留 .38 行高：单行时白占一截、窄屏折两行时又和
    -- info 挤在一起；定高单行 + 省略号在 7 行/屏的行高里更稳。
    local title_w = text_w
    if badges_w > 0 then title_w = math.max(S.sz(80), text_w - badges_w - S.sz(8)) end
    local title = TextWidget:new{
        text = tostring(self.entry.title or _("未命名")),
        face = S.face("cfont", 18),
        bold = true,
        max_width = title_w,
        fgcolor = S.ink,
    }
    local title_row_h = math.max(title:getSize().h, badges_h)
    local title_row
    if badges_w > 0 then
        local badge_group = HorizontalGroup:new{ align = "center" }
        for _i, b in ipairs(badges) do
            table.insert(badge_group, b)
        end
        -- OverlapGroup + 左/右容器：书名靠左、徽章靠右，同一行互不抢位
        title_row = OverlapGroup:new{
            dimen = Geom:new{ w = text_w, h = title_row_h },
            LeftContainer:new{ dimen = Geom:new{ w = text_w, h = title_row_h }, title },
            RightContainer:new{ dimen = Geom:new{ w = text_w, h = title_row_h }, badge_group },
        }
    else
        title_row = title
    end

    local info = TextBoxWidget:new{
        text = tostring(self.entry.info or ""),
        face = S.face("smallinfofont", 14),
        width = text_w,
        height = math.floor(h * .26),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = S.muted,
    }

    local sub = TextBoxWidget:new{
        text = tostring(self.entry.sub or ""),
        face = S.face("smallinfofont", 13),
        width = text_w,
        height = math.floor(h * .24),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = S.hint,
    }

    -- ⚠️ VerticalSpan 的高度字段叫 **width**（`return {w=0, h=self.width}`），
    --    写成 `height = ...` 不报错但那个间隔恒为 0。
    local text_group = VerticalGroup:new{
        align = "left",
        title_row,
        VerticalSpan:new{width = S.sz(3)},
        info,
        VerticalSpan:new{width = S.sz(1)},
        sub,
    }
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

    -- 选中态：整行浅底（尺寸常驻，不随选中变化）
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
        color = S.rule,
        padding = 0,
        vertical_align = "center",
        self._row,
    }
    -- 🔴 必须挂到 self[1]：InputContainer:paintTo 第一行就是
    --    `if self[1] == nil then return end` —— 不挂的话每个条目都**占位不绘制**，
    --    菜单算得出页数（item_table 有 18 条 ⇒ 3 页）但整页纯白。
    --    这正是「书城选完分类进去有三页但全是空白」的根因（书架 ShelfItem 有这行，
    --    StoreItem 当初漏了）。onTapSelect 里的 self[1].dimen 也靠它。
    self[1] = self._underline
end

function StoreItem:onTapSelect(arg, ges)
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

function StoreItem:onHoldSelect()
    if self.entry and self.entry.hold_callback then self.entry.hold_callback() end
    return true
end

function StoreItem:onFocus()
    if self._row then self._row.background = S.surface end
    if self._underline then self._underline.color = S.ink end
    return true
end

function StoreItem:onUnfocus()
    if self._row then self._row.background = nil end
    if self._underline then self._underline.color = S.rule end
    return true
end

-- ------------------------------------------------------------------ 菜单

local StoreMenu = Menu:extend{
    on_page_changed = nil,
    on_close_callback = nil,
    _miu_closed = false,
    _suppress_page_callback = false,
}

-- 左上角按钮：默认弹「操作」对话框（分类 / 排序 / 完本 / 搜索 / 刷新 / 显示方式）
function StoreMenu:onLeftButtonTap()
    if self._on_left_button then
        pcall(self._on_left_button, self)
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")

    -- 🔴 引用挂到 menu 上（理由同 shelf_view）：局部变量在菜单被关掉后
    --    就没人能收掉这个对话框，它会永远留在屏幕上（「弹窗不消失」）。
    local function drop_action_dialog()
        local old = self._action_dialog
        self._action_dialog = nil
        if old then H.close_widget(old) end
    end
    drop_action_dialog()

    local buttons = {}
    local half_row = nil
    local function flush_half()
        if half_row then
            buttons[#buttons + 1] = half_row
            half_row = nil
        end
    end
    for _i, act in ipairs(self._store_actions or {}) do
        -- act.text 允许是**函数**：操作框每次打开时重新求值，用来显示活数字
        -- （如「加载更多（已 18 / 共 10000）」）。写成字符串的话数字会定格在首次构造时。
        local text = act.text
        if type(text) == "function" then
            local ok_t, t = pcall(text)
            text = (ok_t and type(t) == "string") and t or _("操作")
        end
        local btn = {
            text = text,
            callback = function()
                drop_action_dialog()
                pcall(act.callback)
            end,
        }
        -- act.half = true：短标签动作**两个一行**（ButtonDialog 原生支持一行多按钮），
        -- 压低操作框整体高度 —— 全部独占一行时 6~7 个动作在小屏上要滚动。
        -- 连续的 half 打包同行，遇到非 half（长文案如「加载更多（已 x / 共 y）」）先断行，
        -- 避免长文案被压进半宽按钮里截断。
        if act.half then
            half_row = half_row or {}
            half_row[#half_row + 1] = btn
            if #half_row == 2 then flush_half() end
        else
            flush_half()
            buttons[#buttons + 1] = { btn }
        end
    end
    flush_half()
    buttons[#buttons + 1] = { { text = _("关闭"), callback = drop_action_dialog } }
    local dialog = ButtonDialog:new{
        title = self._store_actions_title or _("书城操作"),
        title_align = "center",
        buttons = buttons,
    }
    self._action_dialog = dialog
    UIManager:show(dialog)
end

function StoreMenu:onMenuSelect(entry, pos)
    return Menu.onMenuSelect(self, entry)
end

-- ------------------------------------------------------------------ 顶部 tab 栏

--- 顶部 tab 栏（v2.16.0）：title 栏与列表之间的一排切换按钮 —— 把「分类浏览 →
--- 男频/女频 → 分组 → 分类」这种一层套一层的弹窗路径压成**原地切换**。
--- `menu._store_tabs_fn(menu)` 返回 `{{ text=, active=, on_tap= }}`（每次 updateItems
--- 重新求值，所以 active 高亮跟着当前状态走）。没有 tabs_fn 就完全不画（搜索菜单等）。
---
--- 🔴 视觉与命中：**当前** tab 用黑字 + 下划线；非当前用灰字但仍可点
--- （`enabled=false` 只是变灰，`allow_tap_when_disabled=true` 保留点击 ——
--- 见 button.lua `onTapSelectButton`）。tab 回调一律 `UIManager:nextTick` 挪出
--- 按钮手势分发（同评论区翻页的教训：回调里重建控件树不能发生在手势分发内）。
function StoreView.build_tab_row(menu)
    local fn = menu._store_tabs_fn
    if type(fn) ~= "function" then return nil end
    local ok_t, tabs = pcall(fn, menu)
    if not ok_t or type(tabs) ~= "table" or #tabs == 0 then return nil end
    local row = HorizontalGroup:new{ align = "top" }
    for i, tab in ipairs(tabs) do
        if i > 1 then
            row[#row + 1] = HorizontalSpan:new{ width = S.sz(6) }
        end
        local btn = Button:new{
            text = tostring(tab.text or ""),
            text_font_face = "smallinfofont",
            text_font_size = S.fontSize(14),
            text_font_bold = tab.active and true or false,
            bordersize = 0,
            padding_h = S.sz(6),
            padding_v = S.sz(4),
            enabled = tab.active and true or false,
            allow_tap_when_disabled = not tab.active,
            show_parent = menu,
            callback = tab.on_tap and function()
                UIManager:nextTick(tab.on_tap)
            end or nil,
        }
        if tab.active then
            row[#row + 1] = UnderlineContainer:new{
                linesize = S.sz(2),
                color = S.ink,
                padding = 0,
                vertical_align = "bottom",
                btn,
            }
        else
            row[#row + 1] = btn
        end
    end
    return row
end

--- 筛选行（v2.16.0）：tab 栏**下面**那一排「下拉」按钮 —— 排序 / 状态 / 分类 / 榜单…
--- 点一下弹选择器，选完列表原地刷新，按钮上的值跟着变。
---
--- 🔴 为什么要它：tab 栏管「去哪（男频/女频/榜单/搜索）」，筛选管「这一屏显示什么」。
---    改造前筛选全塞在左上角操作框里（要「先想起来点左上角 → 再在 7 行按钮里找」），
---    与 tab 栏并列的导航形成两套交互 —— 用户原话「有点割裂，有的是界面上 tabs，
---    有的是菜单选项里的筛选」。现在统一为：**导航在 tab 行、筛选在筛选行、
---    动作（显示方式/加载更多/重载）留在操作框**。
---
--- `menu._store_filters_fn(menu)` 返回 `{{ text=, on_tap=, active?= }}`，
--- 每次 updateItems 重新求值 ⇒ 按钮上的当前值永远是活的。
--- 视觉上刻意与 tab 区分：tab 是「黑字 + 下划线」（当前项），筛选是**等宽描边胶囊
--- + ▾**（明确「点了会弹东西」，不是目的地）。
function StoreView.build_filter_row(menu)
    local fn = menu._store_filters_fn
    if type(fn) ~= "function" then return nil end
    local ok_f, chips = pcall(fn, menu)
    if not ok_f or type(chips) ~= "table" or #chips == 0 then return nil end

    local n = #chips
    local pad = S.sz(8)
    local gap = S.sz(6)
    -- 等宽分配：小屏上按内容自适应会溢出屏幕（分类名可能很长），等宽 + 省略号最稳。
    -- ⚠️ 例外：只剩 1 个 chip 时等宽 = 整条通栏大按钮，观感很笨（v2.16.29 起筛选行
    --    普遍只剩「分类 ▾ / 榜单 ▾」一个入口）⇒ 改按内容量宽，量不到再退回等宽。
    local chip_w
    if n == 1 then
        local probe = Button:new{
            text = tostring(chips[1].text or ""),
            text_font_face = "smallinfofont",
            text_font_size = S.fontSize(12),
            bordersize = S.sz(1),
            padding_h = S.sz(3),
            padding_v = S.sz(3),
        }
        local ok_s, size = pcall(probe.getSize, probe)
        if probe.free then pcall(probe.free, probe) end
        chip_w = (ok_s and type(size) == "table" and tonumber(size.w)) or S.sz(200)
        chip_w = math.min(math.max(S.sz(48), math.floor(chip_w) + S.sz(2)),
            screen_width() - pad * 2)
    else
        chip_w = math.floor((screen_width() - pad * 2 - gap * (n - 1)) / n)
        chip_w = math.max(S.sz(48), chip_w)
    end

    local row = HorizontalGroup:new{ align = "center" }
    row[#row + 1] = HorizontalSpan:new{ width = pad }
    for i, chip in ipairs(chips) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = Button:new{
            text = tostring(chip.text or ""),
            width = chip_w,
            text_font_face = "smallinfofont",
            text_font_size = S.fontSize(12),
            text_font_bold = chip.active and true or false,
            bordersize = S.sz(1),
            radius = S.radius(),
            padding_h = S.sz(3),
            padding_v = S.sz(3),
            show_parent = menu,
            callback = chip.on_tap and function()
                -- 同 tab：重建控件树的回调不能发生在手势分发内
                UIManager:nextTick(chip.on_tap)
            end or nil,
        }
    end
    row[#row + 1] = HorizontalSpan:new{ width = pad }
    return row
end

--- 内容胶囊行（v2.16.29）：与筛选行的区别——筛选行是「点开弹选择器」的下拉入口，
--- 胶囊行是**一组可选值常显在界面上**，点一下原地切换、不进任何弹窗。
--- 参照 book.koplugin 书城浏览页的 browse chips：常显胶囊 + 「更多 ▾」折叠。
---
--- `menu._store_chips_fn(menu)` 返回：
---   { chips = { { text=, active=, on_tap= }, … },
---     overflow = { text=, on_tap= }   ← 放不下时行尾的「更多 ▾」（缺省不画） }
--- 每次 updateItems 重新求值 ⇒ active 高亮跟随当前 state。
---
--- 🔴 贪心装箱：先逐个构造 Button 量宽（不给 width 时 `getSize` 走内容实测），
---    按屏幕宽度装到装不下为止，剩余的收进 overflow —— **绝不让一行胶囊溢出屏幕**。
---    桩环境量不到宽度时按保守值兜底，行为仍然确定（回归断言可依赖）。
function StoreView.build_chip_row(menu)
    local fn = menu._store_chips_fn
    if type(fn) ~= "function" then return nil end
    local ok_c, spec = pcall(fn, menu)
    if not ok_c or type(spec) ~= "table" then return nil end
    local chips = spec.chips
    if type(chips) ~= "table" or #chips == 0 then return nil end

    local pad = S.sz(8)
    local gap = S.sz(6)
    local max_w = screen_width() - pad * 2

    local function make_btn(chip)
        return Button:new{
            text = tostring(chip.text or ""),
            text_font_face = "smallinfofont",
            text_font_size = S.fontSize(12),
            text_font_bold = chip.active and true or false,
            bordersize = S.sz(1),
            radius = S.radius(),
            padding_h = S.sz(5),
            padding_v = S.sz(3),
            show_parent = menu,
            callback = chip.on_tap and function()
                -- 同 tab / 筛选：重建控件树的回调不能发生在手势分发内
                UIManager:nextTick(chip.on_tap)
            end or nil,
        }
    end

    local btns = {}
    for i, chip in ipairs(chips) do
        btns[i] = make_btn(chip)
    end
    local widths = {}
    for i, b in ipairs(btns) do
        local ok_s, size = pcall(b.getSize, b)
        widths[i] = (ok_s and type(size) == "table" and tonumber(size.w)) or S.sz(64)
    end

    -- overflow 按钮只在「整行装不下」时才参与排版
    local overflow_btn = nil
    local overflow_w = 0
    if type(spec.overflow) == "table" then
        overflow_btn = make_btn{
            text = spec.overflow.text or _("更多") .. " ▾",
            on_tap = spec.overflow.on_tap,
        }
        local ok_s, size = pcall(overflow_btn.getSize, overflow_btn)
        overflow_w = (ok_s and type(size) == "table" and tonumber(size.w)) or S.sz(72)
    end

    local all_w = 0
    for i, w in ipairs(widths) do
        all_w = all_w + w + (i > 1 and gap or 0)
    end
    local show_overflow = overflow_btn ~= nil
        and (all_w + gap + overflow_w > max_w or #chips > #widths)
    local used = 0
    local count = 0
    for i = 1, #widths do
        local w = widths[i] + (count > 0 and gap or 0)
        local reserve = show_overflow and (gap + overflow_w) or 0
        if used + w + reserve <= max_w then
            used = used + w
            count = i
        else
            break
        end
    end
    if count == 0 and #widths > 0 then
        -- 连一颗都装不下（超窄屏）：至少亮出第一颗，别给用户一行空白
        count = 1
    end

    -- 装不下的按钮当场释放：Button 里有文字控件，白留着就是漏显存
    for i = count + 1, #btns do
        if btns[i] and btns[i].free then pcall(btns[i].free, btns[i]) end
    end
    if overflow_btn and not show_overflow then
        if overflow_btn.free then pcall(overflow_btn.free, overflow_btn) end
        overflow_btn = nil
    end

    local row = HorizontalGroup:new{ align = "center" }
    row[#row + 1] = HorizontalSpan:new{ width = pad }
    for i = 1, count do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = btns[i]
    end
    if overflow_btn then
        row[#row + 1] = HorizontalSpan:new{ width = gap }
        row[#row + 1] = overflow_btn
    end
    row[#row + 1] = HorizontalSpan:new{ width = pad }
    return row
end

--- 摘掉某个已挂的控件行并释放。
--- ⚠️ `updateItems` 重建**不发任何事件**（同 item_group）⇒ 释放要自己做，
---    否则每次重绘都漏一排 Button（墨水屏上跑几十次就是几十 MB 显存）。
local function detach_control_row(menu, key)
    local old = menu[key]
    if not old then return end
    local group = menu.item_group
    for i = #group, 1, -1 do
        if group[i] == old then
            table.remove(group, i)
        end
    end
    -- HorizontalGroup 是 WidgetContainer：free() 会递归释放里面的 Button/TextWidget
    if old.free then pcall(old.free, old) end
    menu[key] = nil
    if group.resetLayout then group:resetLayout() end
end

--- 控件行（tab 栏 / 筛选行）挂在 **`item_group` 里**，不挂 `content_group`。
---
--- 🔴 v2.16.24 改：以前插进 `content_group`（[1]=title 栏、[2]=tab、[3]=筛选、
---    [4]=item_group）。理论上 `VerticalGroup` 会把 item_group 排在控件行**下面**，
---    但实测书城网格模式下**第一行封面会压住排序/状态那排胶囊** —— 说明这条
---    「靠 content_group 的 offsets 把控件行让出来」的链子在真机上并不可靠
---    （`VerticalGroup` 的 `_size`/`_offsets` 是带缓存的，`table.insert` 不会让它
---    失效；网格行又是由 `item_group` 自己铺的，两套偏移一错位就整排上移）。
---    现在控件行与网格行是**同一个 VerticalGroup 的兄弟节点**：要么一起往下排，
---    要么一起不排，结构上不可能再互相压住。
---    代价只是 `item_group:clear()` 会连控件行一起 free ⇒ `updateItems` 里必须
---    先把 `_store_tab_row` / `_store_filter_row` 的引用丢掉，免得二次 free。
function StoreView.attach_tab_row(menu, row)
    detach_control_row(menu, "_store_tab_row")
    if not row then return 0 end
    table.insert(menu.item_group, 1, row)
    menu._store_tab_row = row
    if menu.item_group.resetLayout then menu.item_group:resetLayout() end
    return row_height(row)
end

--- 把筛选行插在 tab 行**之后**（没有 tab 行就是 1 号位）。
--- 必须后于 `attach_tab_row` 调用（顺序 = tab 在上、筛选在下）。
function StoreView.attach_filter_row(menu, row)
    detach_control_row(menu, "_store_filter_row")
    if not row then return 0 end
    local at = menu._store_tab_row and 2 or 1
    table.insert(menu.item_group, at, row)
    menu._store_filter_row = row
    if menu.item_group.resetLayout then menu.item_group:resetLayout() end
    return row_height(row)
end

--- 把胶囊行插在筛选行**之后**（依次补齐缺的行位）。
--- 必须最后调用（顺序 = tab → 筛选 → 胶囊）。
function StoreView.attach_chip_row(menu, row)
    detach_control_row(menu, "_store_chip_row")
    if not row then return 0 end
    local at = 1
    if menu._store_tab_row then at = at + 1 end
    if menu._store_filter_row then at = at + 1 end
    table.insert(menu.item_group, at, row)
    menu._store_chip_row = row
    if menu.item_group.resetLayout then menu.item_group:resetLayout() end
    return row_height(row)
end

--- 网格模式：按封面度量铺满一页（详见 shelf_view 里同名方法的注释）。
function StoreMenu:buildGridItems(select_number, cols, rows)
    local pad = CoverCell.sidePad()
    -- 有「字数 · 在读」短行（entry.meta）的条目，格高要**多预留一行**：
    -- 不预留的话 CoverCell 把 meta 行画进 title_extra 的空间，封面被顶掉一截。
    -- 与书架 chapters 的处理同机制（见 cover_cell.metaExtra 的注释）。
    local needs_meta = false
    for _i, e in ipairs(self.item_table or {}) do
        if type(e.meta) == "string" and e.meta ~= "" then needs_meta = true break end
    end
    -- 控件行（tab 栏 / 筛选行）占的高度已在 updateItems 里从可用区扣掉 —— 这里必须用
    -- 扣过的那份，否则网格会铺满整屏、末行压进页脚。兜底顺序见 updateItems 的注释。
    local avail = tonumber(self._store_eff_ah) or tonumber(self.available_height) or 0
    local m = CoverCell.metrics(self.inner_dimen.w - pad * 2,
                                math.max(S.sz(40), avail - S.sz(10)), cols,
                                { rows = rows,
                                  title_extra = CoverCell.titleExtra()
                                      + (needs_meta and CoverCell.metaExtra() or 0) })
    self._grid_metrics = m
    self.perpage = m.perpage
    self.page_num = self:getPageNumber(#self.item_table)
    if self.page > self.page_num then self.page = self.page_num end
    if self.page < 1 then self.page = 1 end

    local offset = (self.page - 1) * self.perpage
    for r = 1, m.rows do
        local row_group = HorizontalGroup:new{align = "top"}
        local cells = {}
        -- 两端留白（`Menu.item_group` 是左对齐的 VerticalGroup，见 shelf_view 同处注释）
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
        table.insert(self.layout, cells)
    end
    return select_number
end

function StoreMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    -- 🔴 控件行现在挂在 item_group 里（见 attach_tab_row 的说明）⇒ clear() 会连
    --    它们一起 free。先把引用丢掉：否则后面的 attach_* 会对一个**已释放**的
    --    Button 再来一次 free（double free，墨水屏上直接花屏/闪退）。
    self._store_tab_row = nil
    self._store_filter_row = nil
    self._store_chip_row = nil
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    Menu._recalculateDimen(self, no_recalculate_dimen)

    -- ── 控件行（tab 栏 + 筛选行）────────────────────────────────────────
    -- 🔴 控件行占的高度必须**从 available_height 派生**，绝不能原地扣减它：
    --    `Menu:_recalculateDimen` 在 no_recalculate_dimen=true 时**第 655 行直接
    --    return、不重置 available_height**（见 koreader/ui/widget/menu.lua），
    --    而封面回填 / 翻页重绘走的正是 `updateItems(nil, true)`（见 store_ui 的封面链）
    --    ⇒ 原地扣减会**逐次累加**：每回填一张封面就再扣一次控件行高，
    --    item_dimen.h 越压越小、文本区跟着缩水 ⇒ 用户看到的就是
    --    「书城一页一页地闪、字越来越小」。available_height 只读不写，
    --    控件行高度在算 item 尺寸时扣一次（每次都是全量重算，天然幂等）。
    -- ⚠️ 桩菜单可能没有 available_height（没算过 dimen）⇒ 拿不到就只挂栏、不调尺寸。
    local ah = tonumber(self.available_height) or 0
    local tab_row = StoreView.build_tab_row(self)
    local tab_h = StoreView.attach_tab_row(self, tab_row)
    local filter_row = StoreView.build_filter_row(self)
    local filter_h = StoreView.attach_filter_row(self, filter_row)
    -- 内容胶囊行（v2.16.29）：筛选行下面、列表上面。没有 chips_fn 的菜单（搜索等）不画。
    local chip_row = StoreView.build_chip_row(self)
    local chip_h = StoreView.attach_chip_row(self, chip_row)

    -- 控件行挂在 item_group 头部 ⇒ 它们**实际占掉**垂直流里的一段高度，算每页条目数时
    -- 必须把这部分扣掉（否则最后一行会被挤出屏幕）。
    -- ⚠️ 只落到 `_store_eff_ah`，绝不能写回 `self.available_height`（v2.16.0 的累加
    --    bug 就是那样来的：封面回填每重绘一次再扣一次，条目越压越扁）。
    local eff_ah = ah
    local control_h = tab_h + filter_h + chip_h
    if control_h > 0 and ah > control_h then eff_ah = ah - control_h end
    self._store_eff_ah = eff_ah > 0 and eff_ah or nil
    if eff_ah > 0 and self.item_dimen then
        local pp = tonumber(self.perpage) or 1
        if pp >= 1 then self.item_dimen.h = math.floor(eff_ah / pp) end
    end

    local opts = self._store_opts or {}
    local mode, cols, rows = StoreView.resolve_view(opts)
    self._view_mode = mode
    self._view_cols = cols
    self._view_rows = rows

    if mode == "grid" then
        select_number = self:buildGridItems(select_number, cols, rows)
    else
        self._grid_metrics = nil
        local offset = (self.page - 1) * self.perpage
        for index_on_page = 1, self.perpage do
            local index = offset + index_on_page
            local entry = self.item_table[index]
            if not entry then break end
            entry.idx = index
            if index == self.itemnumber then select_number = index_on_page end
            local item = StoreItem:new{
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
        UIManager:scheduleIn(0, function()
            if not self._miu_closed and self.on_page_changed then
                -- 🔴 `last` 必须在**回调执行时**按当时的 item_table 算，不能在调度时算：
                --    调度时若还停在首帧（item_table 只有 1 条「正在加载…」占位），算出来的
                --    last 就是 1；这个**过期值**被闭包带进回调，会把整页封面回填截断成
                --    1 本（并且顺带把 generation 顶掉，作废已经在跑的那条链）。
                --    真实设备上这个回调通常先于数据到达，所以只在「数据先到」时才踩到。
                local n = #(self.item_table or {})
                local perpage = tonumber(self.perpage) or 0
                local last = math.min(n, first + perpage - 1)
                pcall(self.on_page_changed, page, first, last, self)
            end
        end)
    end
end

function StoreMenu:onCloseWidget()
    self._miu_closed = true
    -- ⚠️ 浮在菜单之上的对话框（左上角操作框 / 显示方式 / 书籍详情）**不会**随菜单一起关：
    --    UIManager:close(menu) 只摘掉 menu 自己。不显式收掉的话它们会留在屏幕上，
    --    而且再没有任何入口能操作它们（「弹窗不消失」）。
    local old = self._action_dialog
    self._action_dialog = nil
    if old then H.close_widget(old) end
    local vd = self._view_dialog
    self._view_dialog = nil
    if vd then H.close_widget(vd) end
    -- 书籍详情（对话框 + 可滚动的「简介」整页）由**插件**持有
    -- （main.lua 的 _state.detail_dialog / _book_detail_page），
    -- 所以这里回调插件去收，而不是 StoreView 自己留一份句柄。
    -- 用 pcall 包住：菜单关不掉永远比多留一个浮层严重。
    local plugin = self._store_plugin
    if plugin then
        if type(plugin.closeBookDetailPage) == "function" then
            pcall(plugin.closeBookDetailPage, plugin)
        end
        if type(plugin._closeDetailDialog) == "function" then
            pcall(plugin._closeDetailDialog, plugin)
        end
    end

    if self.on_close_callback then
        local callback = self.on_close_callback
        UIManager:scheduleIn(0, function() pcall(callback) end)
    end
    return Menu.onCloseWidget(self)
end

-- ------------------------------------------------------------------ 显示方式

--- 解析当前生效的显示方式（settings 优先，opts 覆盖其次）。
---@return string mode "list" | "grid"
---@return number cols 网格列数（2~8；0 = 按屏宽自适应）
---@return number rows 网格行数（1~8；0 = 按屏高自动反推）
function StoreView.resolve_view(opts)
    opts = opts or {}
    local settings = opts.plugin and opts.plugin.settings
    local mode = opts.view_mode
    if not mode and settings and settings.get_ui_view then
        mode = settings:get_ui_view("store")
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
    return mode, CoverCell.normalize_layout(cols, rows)
end

--- 左上角菜单里显示的那个短标签（「列表」/「封面网格 3×4」）。
function StoreView.view_label(menu)
    local opts = (menu and menu._store_opts) or {}
    local mode, cols, rows = StoreView.resolve_view(opts)
    if mode == "grid" then
        return T(_("封面网格 %1"), CoverCell.layout_label(cols, rows))
    end
    return _("列表")
end

--- 「显示方式」对话框（按钮与「自定义列×行」都在 cover_cell 里，与书架共用）。
--- 这里只负责往**书城那一份**设置写（`ui.store` / `ui.grid_*`），改完原地重刷。
function StoreView.show_view_dialog(menu)
    local opts = (menu and menu._store_opts) or {}
    local settings = opts.plugin and opts.plugin.settings
    local mode, cols, rows = StoreView.resolve_view(opts)

    CoverCell.show_view_dialog{
        owner = menu, field = "_view_dialog",
        current_mode = mode, current_cols = cols, current_rows = rows,
        on_apply = function(new_mode, new_cols, new_rows)
            opts.view_mode = new_mode
            if new_cols then opts.grid_cols = new_cols end
            if new_rows then opts.grid_rows = new_rows end
            if settings then
                if settings.set_ui_view then settings:set_ui_view("store", new_mode) end
                if new_cols and settings.set_ui_grid_cols then settings:set_ui_grid_cols(new_cols) end
                if new_rows and settings.set_ui_grid_rows then settings:set_ui_grid_rows(new_rows) end
            end
            StoreView.update(menu, menu and menu._store_books, opts)
        end,
    }
end

-- ------------------------------------------------------------------ 构造条目

local function build_items(books, opts)
    opts = opts or {}
    local items = {}
    for _i, book in ipairs(books or {}) do
        local cover_path = book.cover_path
        if not cover_path and opts.cover_dir and opts.file_exists then
            local p = StoreView.cover_path(opts.cover_dir, book)
            -- `cover_fresh` = 有效期判据（store_ui 传进来）。只判存在的话，过期封面会被
            -- 当成命中直接摆上去 —— 书城换图后永远是旧图。
            if p and opts.file_exists(p) and (not opts.cover_fresh or opts.cover_fresh(p)) then
                cover_path = p
            end
        end
        -- 榜单条目带名次（原创榜自带 currentPos，其余榜单由 store_ui 按返回顺序编号）：
        -- 渲染层画成「#N」小徽章（列表在标题右侧、v2.16.29 起网格叠封面左上角），
        -- 不往书名文本里塞「#N 」前缀 —— 徽章有边框有留白，榜单「一眼看得出来是榜」，
        -- 书名也不会被砍掉一截宽度。
        local title = tostring(book.title or "")
        -- 网格的书名下那行弱化短行：字数 · 在读（列表的 info 行有完整版；
        -- 网格此前只有书名 + 状态徽章，光溜溜的）。拿不到就不给 —— 不留「 · 」悬挂分隔。
        local meta_parts = {}
        local w_txt = word_text(book.word_count)
        if w_txt then meta_parts[#meta_parts + 1] = w_txt end
        local r_txt = read_text(book.read_count)
        if r_txt then meta_parts[#meta_parts + 1] = r_txt end
        local on_select = function() if opts.on_select then opts.on_select(book) end end
        local on_hold = function() if opts.on_hold then opts.on_hold(book) end end
        items[#items + 1] = {
            book_id = book.book_id,
            title = title,
            info = StoreView.meta_text(book),
            sub = StoreView.sub_text(book),
            tag = StoreView.status_tag(book),
            rank = type(book.rank_pos) == "number"
                and tostring(book.rank_pos) or nil,
            meta = #meta_parts > 0 and table.concat(meta_parts, " · ") or nil,
            cover_path = cover_path,
            -- book.show_cover == false = 这行本来就不要封面（加载占位）；
            -- ⚠️ 别写成只看 opts.show_covers，占位行会画出一个空封面框，很扎眼。
            show_cover = opts.show_covers ~= false and book.show_cover ~= false,
            -- 回指原始 book 对象：翻页追加/排序后 item 下标与 books 下标会错位，
            -- 封面链必须按条目取书而不是按 books[index]。
            book = book,
            callback = on_select,
            hold_callback = on_hold,
            -- 网格单元用这两个（CoverCell.build 只认 on_tap / on_hold）
            on_tap = on_select,
            on_hold = on_hold,
        }
    end
    return items
end

-- ------------------------------------------------------------------ 对外

--- 书籍列表菜单。
---@param opts table { title, subtitle, books, cover_dir, plugin, view_mode?, grid_cols?,
---                    on_select, on_hold, on_close, on_refresh, on_page_changed,
---                    on_left_button, store_actions, store_actions_title, show_covers,
---                    tabs_fn }
---        ⚠️ store_actions[i].text 可以是 string，也可以是 **function**（打开操作框时求值）。
function StoreView.show(opts)
    opts = opts or {}
    local mode = StoreView.resolve_view(opts)
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
    local title = opts.title or _("书城")
    if opts.subtitle and opts.subtitle ~= "" then
        title = title .. " · " .. opts.subtitle
    end
    -- 🔴 这几个字段必须**走构造表**：`Menu:init` 里立刻会调一次 `updateItems`，
    --    那时若 `self._store_opts` 还是 nil，`resolve_view` 读不到 settings ⇒
    --    首帧永远按列表画（与 shelf_view.show 同一个坑，见那里的长注释）。
    local menu = StoreMenu:new{
        title = title,
        item_table = items,
        items_per_page = 7,
        is_borderless = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        on_close_callback = opts.on_close,
        on_page_changed = page_callback,
        _store_opts = opts,
        _store_books = opts.books or {},
        -- ⚠️ 插件引用：StoreMenu:onCloseWidget 要用它收掉「书籍详情」浮层
        -- （详情对话框/整页由插件持有，不再是 StoreView 的句柄）。
        _store_plugin = opts.plugin,
        -- ⚠️ Menu 会在 init 里改写 self.title（拼 title_bar），所以自己留一份原文案，
        -- switchItemTable 时用它，否则标题会越拼越长。
        _store_title = title,
        _store_base_title = opts.title or _("书城"),
        _store_subtitle = opts.subtitle,
        _store_actions = opts.store_actions,
        _store_actions_title = opts.store_actions_title,
        -- 顶部 tab 栏（v2.16.0）：function(menu) → { { text, active, on_tap } }；
        -- nil = 不画 tab 栏。走构造表的理由同上（init 里第一次 updateItems 就要用）。
        _store_tabs_fn = opts.tabs_fn,
        -- tab 栏下面那排「下拉」筛选按钮（v2.16.0）：function(menu) → { { text, on_tap } }。
        -- nil = 不画（搜索菜单等）。每次 updateItems 重新求值 ⇒ 按钮上的当前值永远是活的。
        _store_filters_fn = opts.filters_fn,
        -- 筛选行下面那排「内容胶囊」（v2.16.29）：function(menu) → { chips=, overflow= }。
        -- nil = 不画。与筛选行的分工：筛选行点了会弹选择器，胶囊行点一下直接切换。
        _store_chips_fn = opts.chips_fn,
        _on_left_button = opts.on_left_button,
        _on_refresh = opts.on_refresh,
    }
    UIManager:show(menu)
    return menu
end

--- 原地换表：book 数组变了（翻页追加 / 刷新 / 换显示方式）但不关菜单。
--- keep_first = 保持当前页首条（追加场景）
function StoreView.update(menu, books, opts)
    if not menu then return end
    opts = opts or menu._store_opts or {}
    opts.books = books or {}
    menu._store_books = opts.books
    menu._store_opts = opts
    local items = build_items(opts.books, opts)
    if #items == 0 then return end
    local current_page = tonumber(menu.page) or 1
    local perpage = menu.perpage or 7
    local first = (current_page - 1) * perpage + 1
    if first > #items then first = math.max(1, #items - perpage + 1) end
    menu._suppress_page_callback = true
    pcall(function() menu:switchItemTable(menu._store_title or menu.title, items, first) end)
    menu._suppress_page_callback = false
end

-- 条目数 ≤ 此值，且**没有分组分隔头** ⇒ 用弹窗；否则开全屏选择菜单。
--
-- 🔴 为什么不一律弹窗：KOReader **没有「下拉浮层」这种原生控件**，能弹出来的只有两类：
--    * `ButtonDialog`（本阈值走这条）：居中、原生支持点外部 / 按返回关闭，但内容只是
--      「一整条长滚动」—— 没有分页、没有分组分隔头、没有页脚，150+ 条就是十几屏无结构长串；
--    * `Menu`：分页 + `items_per_page` + `select_enabled=false` 的分隔头全都有，
--      但 `Menu:init` 把 `dimen` 写死成 `x=0, y=0, w = self.width or 屏宽`（`menu.lua:692`）
--      ⇒ 不传 width/height 就是**全屏**。
--    分类选择器（男频 154 / 女频 182）与排行榜入口（30 条）非分页+分组不可，只能走 `Menu`；
--    而排序(3) / 状态(3) / 性别(2) / 分类浏览(2~3) / 换榜别(3~5) 只有几项，
--    开一整屏菜单纯属浪费。两边各取所长。
local CHOOSER_POPUP_MAX = 8

--- 短列表：弹窗（居中、点外部 / 按返回关闭，与原「操作框」同款）。
--- 选中后**先关掉弹窗**再执行回调，避免选择器叠在新界面后面。
local function show_chooser_popup(opts, entries)
    local ButtonDialog = require("ui/widget/buttondialog")
    local buttons = {}
    for _i, e in ipairs(entries) do
        buttons[#buttons + 1] = { {
            text = e.text,
            callback = function()
                local cb = e.callback
                StoreView.close_chooser()
                if cb then cb() end
            end,
        } }
    end
    -- 显式「取消」：墨水屏上「点外部关闭」不是人人都知道，留着与原操作框的「关闭」一致
    buttons[#buttons + 1] = { { text = _("取消"), callback = function() StoreView.close_chooser() end } }

    local dialog
    dialog = ButtonDialog:new{
        title = opts.title or _("请选择"),
        title_align = "center",
        buttons = buttons,
        -- 点外部 / 按返回关掉时也要摘引用（否则 close_chooser 会对已关的弹窗空关一次）
        tap_close_callback = function()
            if StoreView._chooser == dialog then StoreView._chooser = nil end
        end,
    }
    StoreView._chooser = dialog
    UIManager:show(dialog)
    return dialog
end

--- 长列表：全屏选择菜单（可翻页 + 分组分隔头）。
local function show_chooser_menu(opts, entries)
    local menu
    local items = {}
    for _i, e in ipairs(entries) do
        if e.separator then
            -- 分组分隔头：**不可点**（真 Menu 的 select_enabled=false 语义 ——
            -- onMenuSelect 见 false 直接跳过，不会关窗也不会触发回调）。
            -- 长列表（分类选择器 150+ 条）没有它就是十几页平铺长串，没法扫。
            items[#items + 1] = { text = e.text, select_enabled = false }
        else
            items[#items + 1] = {
                text = e.text,
                callback = function()
                    local cb = e.callback
                    StoreView.close_chooser()
                    if cb then cb() end
                end,
            }
        end
    end
    if #items == 0 then
        items[1] = { text = _("（没有可用条目）") }
    end
    menu = Menu:new{
        title = opts.title or _("请选择"),
        item_table = items,
        -- 17/页：分类选择器压平后有 150+ 条，12/页要翻 13~16 页；17/页省 1/3 页数。
        -- 短列表（排行榜/换榜别几个条目）不受影响 —— 不超一页就没有页脚。
        items_per_page = opts.per_page or 17,
        is_borderless = true,
        title_bar_fm_style = true,
        on_close_callback = function()
            -- 用户点外部 / 按返回关掉时也要摘引用，否则 close_chooser 会对着
            -- 已经关掉的菜单空关一次（多余的 flashui 刷新）
            if StoreView._chooser == menu then StoreView._chooser = nil end
            if opts.on_close then pcall(opts.on_close) end
        end,
    }
    StoreView._chooser = menu
    UIManager:show(menu)
    -- 🔴 锚点定位（v2.16.32）：树状分类折叠行「点开 = 关掉重开选择器」，重开后
    --    Menu 从第 1 页显示 —— 用户刚点的那组跑到看不见的地方，得重新往下翻
    --    （用户报「展开直接页码重置为开始了」）。翻到锚点条目所在页即可。
    --    在 show() 之后调 onGotoPage：它只 updateItems，不影响首次绘制。
    local anchor = tonumber(opts.anchor_index) or 0
    if anchor > 0 and menu.onGotoPage and menu.getPageNumber then
        pcall(function()
            local page = menu:getPageNumber(anchor)
            if page and page > 1 then menu:onGotoPage(page) end
        end)
    end
    return menu
end

--- 通用纯文本选择器（男/女频、分类 label、分类项、排序、完本状态都用它）。
--- 按「条目数 + 有没有分组分隔头」自动分派到弹窗 / 全屏菜单（见 `CHOOSER_POPUP_MAX`）。
--- 选中后**先关掉选择器**再执行回调，避免它叠在新界面后面。
---@param opts table { title, entries = { { text=, callback=, separator?= } }, on_close, per_page }
---  ⚠️ `on_close` / `per_page` 只对**全屏菜单**分支生效（都是长列表才关心的东西；目前也没有调用方传）。
function StoreView.show_chooser(opts)
    opts = opts or {}
    -- 防叠加：上一个选择器还开着就先收掉（连点两次「排序」会叠两层，
    -- 而且底层那个还关不掉）。
    StoreView.close_chooser()

    local entries = opts.entries or {}

    -- 条目自带 anchor 标记（树状分类的折叠组头）⇒ 换算成行号传下去（见
    -- show_chooser_menu 的锚点定位注释）。
    if not opts.anchor_index then
        for i, e in ipairs(entries) do
            if e.anchor then opts.anchor_index = i break end
        end
    end

    -- 分组分隔头是**长列表**的结构标记（没有它 150+ 条就是一串扫不动的东西）
    -- ⇒ 带分隔头的一律走全屏菜单，不吃条目数阈值。
    local has_separator = false
    for _i, e in ipairs(entries) do
        if e.separator then has_separator = true break end
    end

    if #entries > 0 and #entries <= CHOOSER_POPUP_MAX and not has_separator then
        return show_chooser_popup(opts, entries)
    end
    return show_chooser_menu(opts, entries)
end

--- 关闭当前的选择器（弹窗或菜单，若还开着）。
function StoreView.close_chooser()
    local menu = StoreView._chooser
    StoreView._chooser = nil
    if menu then H.close_widget(menu) end
end

return StoreView
