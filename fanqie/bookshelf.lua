local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T = _

local ok_device, device = pcall(require, "device")
local Screen = ok_device and device.screen or nil
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_Menu, Menu = pcall(require, "ui/widget/menu")
local ok_InfoMessage, InfoMessage = pcall(require, "ui/widget/infomessage")
local ok_ConfirmBox, ConfirmBox = pcall(require, "ui/widget/confirmbox")
local ok_InputDialog, InputDialog = pcall(require, "ui/widget/inputdialog")

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_util, util = pcall(require, "util")
local ok_H, H = pcall(require, "fanqie.helper")
local ok_Log, Log = pcall(require, "fanqie.logger")
local ok_Content, Content = pcall(require, "fanqie.content")
local ok_state, _state = pcall(require, "fanqie.state")

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

local Bookshelf = {}

function Bookshelf:showBookshelf()
    if not self:checkNetwork() then return end
    if not self.patches_ok then
        local Patches = require("patches.core")
        Patches.install()
        self.patches_ok = true
    end
    self:showBusy(_("正在获取书架..."))
    local ok, result = pcall(function()
        return self:get_shelf()
    end)
    self:closeBusy()
    if not ok then
        if Log then Log.error("fetch shelf failed:", log_error(result)) end
        self:showError(T(_("获取书架失败:\n%1"), display_error(result)))
        return
    end
    if Log then Log.debug("shelf fetched:", #result, "books") end
    if not result or #result == 0 then
        self:showInfo(_("书架为空，请先在番茄小说App中添加书籍"))
        return
    end
    self:showBookList(result)
end

function Bookshelf:get_shelf(force_refresh)
    if Log then Log.debug("fetching shelf from API" .. (force_refresh and " (force refresh)" or "")) end
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
            local book = {
                book_id = item.book_id or item.bookId or item.id,
                title = item.book_name or item.title or item.name or "未知",
                author = item.author_name or item.author or "",
                cover = item.thumb_url or item.coverUrl or item.cover or item.cover_url,
                desc = item.description or item.desc or item.abstract or "",
                progress = progress,
                item_id = item.item_id or item.itemId,
                total_chapters = total_chapters,
                read_chapters = read_chapters,
            }
            if book.book_id then
                table.insert(books, book)
            end
        end
    end
    return books
end

function Bookshelf:download_covers(books)
    local cover_cache_dir = self.settings:get("cache_dir") .. "/covers"
    H.make_dir(cover_cache_dir)
    for _, book in ipairs(books) do
        if book.cover and not book.cover_path then
            local cover_filename = string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
            local cover_path = cover_cache_dir .. "/" .. cover_filename
            local ok, _ = pcall(function()
                local data = self.client:get_binary(book.cover)
                local file = io.open(cover_path, "wb")
                if file then
                    file:write(data)
                    file:close()
                    book.cover_path = cover_path
                end
            end)
            if not ok and Log then Log.warn("failed to download cover for:", book.title) end
        end
    end
end

function Bookshelf:showBookList(books)
    table.sort(books, function(a, b)
        return (a.progress or 0) < (b.progress or 0)
    end)

    self:download_covers(books)

    local ShelfView = require("fanqie.shelf_view")
    self.book_list_menu = ShelfView.show{
        title = _("我的书架"),
        books = books,
        show_covers = true,
        on_select = function(book)
            self:showBookDetail(book)
        end,
        on_close = function()
            self.book_list_menu = nil
        end,
    }
end

function Bookshelf:showBookDetail(book)
    local ok, chapters = pcall(function()
        return self:get_chapters(book.book_id)
    end)
    if not ok then
        if Log then Log.error("fetch chapters failed:", log_error(chapters)) end
        self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
        return
    end

    local progress_text = ""
    if book.progress then
        progress_text = string.format(_("已读 %.1f%%"), book.progress * 100)
    end
    local chapter_text = ""
    if book.read_chapters and book.total_chapters then
        chapter_text = string.format(_("%d/%d章"), book.read_chapters, book.total_chapters)
    end

    local items = {
        {
            text = _("开始阅读"),
            callback = function()
                UIManager:close(self.book_detail_menu)
                self:openBook(book)
            end,
        },
        {
            text = _("目录"),
            callback = function()
                UIManager:close(self.book_detail_menu)
                self:showChapterListing(book)
            end,
        },
        {
            text = _("下载"),
            callback = function()
                UIManager:close(self.book_detail_menu)
                self:downloadBook(book)
            end,
        },
        {
            text = _("刷新进度"),
            callback = function()
                UIManager:close(self.book_detail_menu)
                local ok, books = pcall(function()
                    return self:get_shelf(true)
                end)
                if ok and #books > 0 then
                    for _, b in ipairs(books) do
                        if b.book_id == book.book_id then
                            self:showBookDetail(b)
                            break
                        end
                    end
                else
                    self:showError(T(_("刷新失败:\n%1"), display_error(books)))
                end
            end,
        },
    }

    self.book_detail_menu = Menu:new{
        title = book.title,
        subtitle = progress_text .. (chapter_text ~= "" and (" " .. chapter_text) or ""),
        items = items,
        is_borderless = true,
        width = Screen:getWidth() - 40,
        height = Screen:getHeight() - 100,
        close_callback = function()
            self.book_detail_menu = nil
        end,
    }
    UIManager:show(self.book_detail_menu)
end

function Bookshelf:showChapterListing(book)
    local ok, chapters = pcall(function()
        return self:get_chapters(book.book_id)
    end)
    if not ok then
        if Log then Log.error("fetch chapters failed:", log_error(chapters)) end
        self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
        return
    end

    local cached = self.settings:get("cached_chapter_index." .. book.book_id, {})

    local items = {}
    for i, chapter in ipairs(chapters) do
        local is_cached = cached[tostring(chapter.itemId)] and true or false
        local text = string.format("%d. %s", i, chapter.title or "")
        table.insert(items, {
            text = text,
            mandatory = is_cached and "✓" or "",
            chapter_index = i,
            callback = function()
                UIManager:close(self.chapter_list_menu)
                self:openChapter(book, chapters, i)
            end,
        })
    end

    self.chapter_list_menu = Menu:new{
        title = book.title,
        items = items,
        is_borderless = true,
        width = Screen:getWidth() - 40,
        height = Screen:getHeight() - 100,
        close_callback = function()
            self.chapter_list_menu = nil
        end,
        on_top = function()
            if self.chapter_list_menu then
                self.chapter_list_menu.page = 1
                UIManager:setDirty(self.chapter_list_menu)
            end
        end,
        on_bottom = function()
            if self.chapter_list_menu then
                local total_pages = math.ceil(#items / (self.chapter_list_menu.per_page or 10))
                self.chapter_list_menu.page = total_pages
                UIManager:setDirty(self.chapter_list_menu)
            end
        end,
    }
    UIManager:show(self.chapter_list_menu)
end

function Bookshelf:showJumpToChapter(book, chapters)
    local dialog = InputDialog:new{
        title = _("跳转到章节"),
        input = tostring(_state.current_chapter_index or 1),
        input_type = "number",
        buttons = {
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("确定"),
                callback = function()
                    local idx = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    if idx and idx >= 1 and idx <= #chapters then
                        self:openChapter(book, chapters, idx)
                    else
                        self:showError(_("章节号无效"))
                    end
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function Bookshelf:downloadBook(book)
    local ok, chapters = pcall(function()
        return self:get_chapters(book.book_id)
    end)
    if not ok then
        if Log then Log.error("fetch chapters failed:", log_error(chapters)) end
        self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
        return
    end
    self:showDownloadRangeDialog(book, chapters)
end

function Bookshelf:showDownloadRangeDialog(book, chapters)
    local cached = self.settings:get("cached_chapter_index." .. book.book_id, {})
    local cached_count = 0
    for _ in pairs(cached) do cached_count = cached_count + 1 end

    local dialog = InputDialog:new{
        title = string.format(_("下载 %s"), book.title),
        input_hint = string.format(_("章节范围 (如: 1-%d, 当前已下载 %d章)"), #chapters, cached_count),
        input = "1-" .. tostring(#chapters),
        buttons = {
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("下载"),
                callback = function()
                    local input = dialog:getInputText()
                    UIManager:close(dialog)
                    local start_str, end_str = input:match("^(%d+)%s*-?%s*(%d*)$")
                    local start_idx = tonumber(start_str)
                    local end_idx = tonumber(end_str) or #chapters
                    if start_idx and start_idx >= 1 and end_idx >= start_idx and end_idx <= #chapters then
                        self:doDownloadBook(book, chapters, start_idx, end_idx)
                    else
                        self:showError(_("无效的章节范围"))
                    end
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function Bookshelf:doDownloadBook(book, chapters, start_idx, end_idx)
    local DownloadProgress = require("fanqie.download_progress")
    local dialog = DownloadProgress:new{
        title = string.format(_("下载 %s"), book.title),
    }
    dialog:show()

    local downloaded = 0
    local failed = 0
    local total = end_idx - start_idx + 1
    dialog:setState{stage = "prepare", current = 0, total = total}

    for i = start_idx, end_idx do
        if dialog:isCanceled() then
            break
        end
        local chapter = chapters[i]
        local chapter_title = chapter.title or string.format(_("第%d章"), i)
        dialog:setState{
            stage = "content",
            current = downloaded,
            total = total,
            chapter = chapter_title,
        }
        local ok, path = pcall(function()
            local b = { book_id = book.book_id, title = book.title, author = book.author }
            return require("fanqie.content").fetch_chapter_html(self.client, self.settings, b, chapter)
        end)
        if ok then
            downloaded = downloaded + 1
        else
            failed = failed + 1
            if Log then Log.warn("chapter download failed:", chapter_title, path) end
        end
        dialog:setState{
            stage = "content",
            current = downloaded,
            total = total,
            chapter = chapter_title,
        }
        if i < end_idx then
            util.sleep(0.5)
        end
    end
    dialog:close()
    local msg = string.format(_("下载完成: %d/%d"), downloaded, total)
    if failed > 0 then
        msg = msg .. string.format(_(" (失败 %d 章)"), failed)
    end
    self:showInfo(msg)
end

return Bookshelf
