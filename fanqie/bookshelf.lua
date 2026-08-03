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
local ok_Async, Async = pcall(require, "fanqie.async")

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

local function save_shelf_cache(settings, books)
    if not settings or not books or type(books) ~= "table" then return end
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
        if Log then Log.info("shelf cache saved: " .. tostring(#books) .. " books to " .. path) end
    else
        if Log then Log.warn("shelf cache save failed: cannot open " .. path) end
    end
end

local function load_shelf_cache(settings)
    local path = get_shelf_cache_path(settings)
    if not H or not H.file_exists or not H.file_exists(path) then
        if Log then Log.info("shelf cache: file not found at " .. path) end
        return nil
    end
    local ok, data = pcall(function()
        local chunk, err = loadfile(path)
        if not chunk then
            if Log then Log.warn("shelf cache loadfile failed: " .. tostring(err)) end
            return nil
        end
        return chunk()
    end)
    if ok and type(data) == "table" and #data > 0 then
        if Log then Log.info("shelf cache loaded: " .. tostring(#data) .. " books") end
        return data
    end
    if not ok then
        if Log then Log.warn("shelf cache pcall failed: " .. tostring(data)) end
    end
    return nil
end

local Bookshelf = {}

function Bookshelf:showBookshelf()
    if not self.patches_ok then
        local Patches = require("patches.core")
        Patches.install()
        self.patches_ok = true
    end

    local sort_type = _state.shelf_sort_type or "default"
    local function do_sort(books)
        if sort_type ~= "default" then
            table.sort(books, function(a, b)
                if sort_type == "progress" then
                    return (a.progress or 0) < (b.progress or 0)
                elseif sort_type == "added" then
                    return (a.added_time or 0) > (b.added_time or 0)
                elseif sort_type == "read" then
                    return (a.last_read_time or 0) > (b.last_read_time or 0)
                elseif sort_type == "title" then
                    return (a.title or "") < (b.title or "")
                else
                    return true
                end
            end)
        end
    end

    -- 优先显示本地缓存，有网后台刷新
    local cached_shelf = load_shelf_cache(self.settings)
    if cached_shelf and #cached_shelf > 0 then
        do_sort(cached_shelf)
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
                        do_sort(result)
                        plugin:showBookList(result)
                    end
                end, { poll_interval = 0.3, timeout = 60 })
            end
        end
        return
    end

    -- 无缓存 + 有网：正常获取
    if not self:checkNetwork() then
        self:showError(_("无网络且无书架缓存，请先联网获取书架"))
        return
    end

    self:showBusy(_("正在获取书架..."))
    local plugin = self
    if ok_Async and Async then
        Async.run(function()
            return plugin:get_shelf()
        end, function(ok, result, err)
            plugin:closeBusy()
            if not ok or type(result) ~= "table" then
                if Log then Log.error("fetch shelf failed:", log_error(err or result)) end
                plugin:showError(T(_("获取书架失败:\n%1"), display_error(err or result)))
                return
            end
            if Log then Log.debug("shelf fetched:", #result, "books") end
            if not result or #result == 0 then
                plugin:showInfo(_("书架为空，请先在番茄小说App中添加书籍"))
                return
            end

            save_shelf_cache(plugin.settings, result)
            do_sort(result)
            plugin:showBookList(result)
        end, { poll_interval = 0.3, timeout = 60 })
    else
        -- Async 模块不可用时降级为同步
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

        save_shelf_cache(self.settings, result)
        do_sort(result)
        self:showBookList(result)
    end
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
    local progress_text = ""
    if book.progress then
        progress_text = string.format(_("已读 %.1f%%"), book.progress * 100)
    end
    local chapter_text = ""
    if book.read_chapters and book.total_chapters then
        chapter_text = string.format(_("%d/%d章"), book.read_chapters, book.total_chapters)
    end

    -- 异步获取目录，UI 保持响应
    local self_ref = self
    local book_id = book.book_id
    local client = self.client
    local settings = self.settings
    local Async_mod = Async

    local function fetch_chapters_async(callback)
        if ok_Async and Async_mod then
            Async_mod.run(function()
                return self_ref:get_chapters(book_id)
            end, function(ok, result, err)
                if not ok or type(result) ~= "table" then
                    if Log then Log.error("fetch chapters failed:", log_error(err or result)) end
                    self_ref:showError(T(_("获取目录失败:\n%1"), display_error(err or result)))
                    return
                end
                callback(result)
            end, { poll_interval = 0.3, timeout = 60 })
        else
            local ok, result = pcall(function()
                return self_ref:get_chapters(book_id)
            end)
            if not ok or type(result) ~= "table" then
                if Log then Log.error("fetch chapters failed:", log_error(result)) end
                self_ref:showError(T(_("获取目录失败:\n%1"), display_error(result)))
                return
            end
            callback(result)
        end
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
                self:showBusy(_("正在获取目录..."))
                fetch_chapters_async(function(chapters)
                    self_ref:closeBusy()
                    require("fanqie.download").showOptionsDialog(self_ref, book, chapters)
                end)
            end,
        },
        {
            text = _("刷新进度"),
            callback = function()
                UIManager:close(self.book_detail_menu)
                self:showBusy(_("正在刷新进度..."))
                fetch_chapters_async(function()
                    -- 复用 get_shelf 异步
                    if ok_Async and Async_mod then
                        Async_mod.run(function()
                            return self_ref:get_shelf(true)
                        end, function(ok, books, err)
                            self_ref:closeBusy()
                            if ok and type(books) == "table" and #books > 0 then
                                for _, b in ipairs(books) do
                                    if b.book_id == book_id then
                                        self_ref:showBookDetail(b)
                                        break
                                    end
                                end
                            else
                                self_ref:showError(T(_("刷新失败:\n%1"), display_error(err or books)))
                            end
                        end, { poll_interval = 0.3, timeout = 60 })
                    else
                        local ok, books = pcall(function()
                            return self_ref:get_shelf(true)
                        end)
                        self_ref:closeBusy()
                        if ok and type(books) == "table" and #books > 0 then
                            for _, b in ipairs(books) do
                                if b.book_id == book_id then
                                    self_ref:showBookDetail(b)
                                    break
                                end
                            end
                        else
                            self_ref:showError(T(_("刷新失败:\n%1"), display_error(books)))
                        end
                    end
                end)
            end,
        },
    }

    self.book_detail_menu = Menu:new{
        title = book.title,
        subtitle = progress_text .. (chapter_text ~= "" and (" " .. chapter_text) or ""),
        item_table = items,
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
    local self_ref = self
    local book_id = book.book_id
    local Async_mod = Async

    local function fetch_and_display()
        self:showBusy(_("正在获取目录..."))
        if ok_Async and Async_mod then
            Async_mod.run(function()
                return self_ref:get_chapters(book_id)
            end, function(ok, chapters, err)
                self_ref:closeBusy()
                if not ok or type(chapters) ~= "table" then
                    if Log then Log.error("fetch chapters failed:", log_error(err or chapters)) end
                    self_ref:showError(T(_("获取目录失败:\n%1"), display_error(err or chapters)))
                    return
                end
                self_ref:_displayChapterListing(book, chapters)
            end, { poll_interval = 0.3, timeout = 60 })
        else
            local ok, chapters = pcall(function()
                return self_ref:get_chapters(book_id)
            end)
            self:closeBusy()
            if not ok or type(chapters) ~= "table" then
                if Log then Log.error("fetch chapters failed:", log_error(chapters)) end
                self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
                return
            end
            self:_displayChapterListing(book, chapters)
        end
    end

    -- 检查是否有缓存目录
    local cached = Content.load_catalog_cache and Content.load_catalog_cache(self.settings, book_id) or nil
    if cached and #cached > 0 then
        self:_displayChapterListing(book, cached)
        -- 后台刷新
        fetch_and_display()
    else
        fetch_and_display()
    end
end

function Bookshelf:_displayChapterListing(book, chapters)
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
        item_table = items,
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
    -- 书架下载：不传 current_index（无"当前阅读后N章"/"剩余全部"选项）
    require("fanqie.download").showOptionsDialog(self, book, chapters)
end

return Bookshelf
