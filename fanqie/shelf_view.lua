local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local function status_text(book)
    local progress = tonumber(book.progress or 0) or 0
    if progress >= 1 then return _("已读完") end
    local read_chapters = tonumber(book.read_chapters or 0) or 0
    local total_chapters = tonumber(book.total_chapters or 0) or 0
    if total_chapters > 0 and read_chapters > 0 then
        return string.format(_("%d/%d章"), read_chapters, total_chapters)
    elseif progress > 0 then
        return string.format(_("%.1f%%"), progress * 100)
    end
    return _("未开始")
end

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
    local side = math.max(Size.padding.small, Screen:scaleBySize(4))
    local show_cover = self.entry.show_cover ~= false
    local cover_h = math.max(Screen:scaleBySize(58), h - side * 2)
    local cover_w = show_cover and math.max(1, math.floor(cover_h * 0.69)) or 0
    local cover

    if show_cover and self.entry.cover_path then
        cover = ImageWidget:new{
            file = self.entry.cover_path,
            width = cover_w,
            height = cover_h,
            scale_factor = 0,
            file_do_cache = true,
        }
    elseif show_cover then
        cover = FrameContainer:new{
            width = cover_w,
            height = cover_h,
            bordersize = Size.border.thin,
            padding = 0,
            margin = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{w=cover_w, h=cover_h},
                TextWidget:new{text="", face=Font:getFace("smallinfofont", 12)},
            },
        }
    end

    local gap = show_cover and Size.padding.large or 0
    local text_w = math.max(Screen:scaleBySize(120), self.dimen.w - cover_w - gap - side * 2)
    local title = TextBoxWidget:new{
        text = tostring(self.entry.title or _("未命名")),
        face = Font:getFace("cfont", math.min(22, Screen:scaleBySize(18))),
        width = text_w,
        height = math.floor(h * .52),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        bold = true,
    }

    local details = tostring(self.entry.author or "")
    if details ~= "" and tostring(self.entry.status or "") ~= "" then details = details .. " · " end
    details = details .. tostring(self.entry.status or "")
    local info = TextBoxWidget:new{
        text = details,
        face = Font:getFace("smallinfofont", math.min(17, Screen:scaleBySize(14))),
        width = text_w,
        height = math.floor(h * .30),
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "left",
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local text_group = VerticalGroup:new{
        align = "left",
        title,
        VerticalSpan:new{height = math.max(1, Screen:scaleBySize(2))},
        info,
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

    self._underline = UnderlineContainer:new{
        dimen = self.dimen:copy(),
        linesize = Size.line.thin,
        color = Blitbuffer.COLOR_DARK_GRAY,
        padding = 0,
        vertical_align = "center",
        row,
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
    self._underline.color = Blitbuffer.COLOR_BLACK
    return true
end

function ShelfItem:onUnfocus()
    self._underline.color = Blitbuffer.COLOR_DARK_GRAY
    return true
end

local ShelfMenu = Menu:extend{
    on_page_changed = nil,
    on_close_callback = nil,
    _miu_closed = false,
    _suppress_page_callback = false,
}

-- 左上角按钮：弹出操作菜单（与目录界面一致，图标为 appbar.menu 三横杠）
function ShelfMenu:onLeftButtonTap()
    if not self._on_refresh then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local action_dialog
    action_dialog = ButtonDialog:new{
        title = _("书架操作"),
        title_align = "center",
        buttons = {
            {{
                text = _("刷新书架"),
                callback = function()
                    UIManager:close(action_dialog)
                    self._on_refresh()
                end,
            }},
            {{
                text = _("关闭"),
                callback = function()
                    UIManager:close(action_dialog)
                end,
            }},
        },
    }
    UIManager:show(action_dialog)
end

function ShelfMenu:onMenuSelect(entry, pos)
    return Menu.onMenuSelect(self, entry)
end

function ShelfMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    Menu._recalculateDimen(self, no_recalculate_dimen)
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
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback, self)
    end
    if Menu.onCloseWidget then return Menu.onCloseWidget(self) end
end

local ShelfView = {}

-- 构造 ShelfItem 的 items 列表（show 和 update 复用）
local function build_items(books, opts)
    local items = {}
    for _, book in ipairs(books or {}) do
        items[#items + 1] = {
            book_id = book.book_id or book.bookId,
            title = book.title,
            author = book.author,
            status = status_text(book),
            cover_path = book.cover_path,
            show_cover = opts.show_covers ~= false,
            callback = function() if opts.on_select then opts.on_select(book) end end,
            hold_callback = function() if opts.on_hold then opts.on_hold(book) end end,
        }
    end
    return items
end

function ShelfView.show(opts)
    opts = opts or {}
    local items = build_items(opts.books or {}, opts)
    local page_callback
    if opts.on_page_changed then
        page_callback = function(page, first, last, current)
            if last >= first then
                opts.on_page_changed(page, first, last, current)
            end
        end
    end
    local menu = ShelfMenu:new{
        title = opts.title or _("书架"),
        item_table = items,
        items_per_page = 7,
        is_borderless = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        on_close_callback = opts.on_close,
        on_page_changed = page_callback,
    }
    menu._on_refresh = opts.on_refresh
    UIManager:show(menu)
    return menu
end

-- 动态更新书架菜单内容（不关闭重开，避免闪烁）
-- 刷新数据回来后直接 switchItemTable 更新，保持当前页
function ShelfView.update(menu, books, opts)
    if not menu then return end
    opts = opts or {}
    local items = build_items(books or {}, opts)
    -- 保持当前页：switchItemTable 第二参数是 item_number（全局索引），不是 page
    local current_page = menu.page or 1
    local perpage = menu.perpage or 7
    local item_number = (current_page - 1) * perpage + 1
    if item_number > #items then item_number = 1 end
    menu:switchItemTable(items, item_number, true)
end

return ShelfView