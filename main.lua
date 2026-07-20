local LOG_MODULE = "[FanQie]"

local function safe_require(module_name, required)
    local ok, result = pcall(require, module_name)
    if not ok then
        if required then
            print(LOG_MODULE, "fatal: failed to load required module:", module_name, "-", result)
            return nil, false
        else
            print(LOG_MODULE, "warning: failed to load optional module:", module_name, "-", result)
            return nil, true
        end
    end
    return result, true
end

local WidgetContainer, ok = safe_require("ui/widget/container/widgetcontainer", true)
if not ok then return end

local lfs = safe_require("libs/libkoreader-lfs")

local Dispatcher = safe_require("dispatcher")

local UIManager = safe_require("ui/uimanager")

local InfoMessage = safe_require("ui/widget/infomessage")

local ConfirmBox = safe_require("ui/widget/confirmbox")

local InputDialog = safe_require("ui/widget/inputdialog")

local Menu = safe_require("ui/widget/menu")

local PathChooser = safe_require("ui/widget/pathchooser")

local Event = safe_require("ui/event")

local GestureRange = safe_require("ui/gesturerange")

local logger = safe_require("logger")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or nil

local util = safe_require("util")

-- Local libs
local Settings = safe_require("fanqie.settings")

local Client = safe_require("fanqie.client")

local H = safe_require("fanqie.helper")

local Content = safe_require("fanqie.content")

local DownloadProgress = safe_require("fanqie.download_progress")

local FanQie = safe_require("fanqie.fanqie")

local Log = safe_require("fanqie.logger")

local Patches = safe_require("patches.core")

local Bookshelf = safe_require("fanqie.bookshelf")
local ReaderNavigation = safe_require("fanqie.reader_navigation")

local unpack_args = unpack or table.unpack

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function is_auth_error(err)
    return type(err) == "table" and err.auth_expired == true
end

local function display_error(err)
    if is_auth_error(err) then
        return _("登录已过期，请更新 Cookie\n\n请编辑 config.lua 文件，填入最新的 Cookie 值后重新启动插件。")
    end
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

local function getCurrentChapterIndex()
    return _state.current_chapter_index or 0
end

local function getCachedChapters(self, book)
    if not book then
        return {}
    end
    if not book.cached_chapters then
        book.cached_chapters = Content.load_cache_index(self.settings, book.book_id) or {}
    end
    return book.cached_chapters
end

local FanQiePlugin = WidgetContainer:extend{
    name = "fanqie",
    is_doc_only = false,
    fullname = "FanQie",
    version = "1.2.2",
}

-- Shared state across FileManager and ReaderUI instances
-- (KOReader creates separate WidgetContainer instances for each)
local ok_state, _state = pcall(require, "fanqie.state")
if not ok_state then
    _state = {
        current_book = nil,
        current_chapters = nil,
        current_chapter_index = nil,
        current_document_path = nil,
        cached_directory = nil,
    }
end

-- Check if the active ReaderUI document is the fanqie chapter we opened.
-- Prevents event handlers (onEndOfBook, onCloseDocument, etc.) from
-- firing on unrelated documents the user may open afterwards.
function FanQiePlugin:isCurrentDocFanqie()
    if not (self.ui and self.ui.document) then return false end
    local doc_path = self.ui.document.file or self.ui.document.path
    if not doc_path then return false end
    return doc_path:lower():find('/fanqie/', 1, true) ~= nil
end

function FanQiePlugin:init()
    self.settings = Settings:new()
    Log.init(self.settings)
    self.client = Client:new(self.settings)
    self.patches_ok = Patches.verifyPatched()
    self:onDispatcherRegisterActions()
    self:loadConfigFile(true)
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    Log.info("plugin initialized:", "version=", self.version)
end

function FanQiePlugin:displayError(err)
    return display_error(err)
end

if Bookshelf then
    for k, v in pairs(Bookshelf) do
        FanQiePlugin[k] = v
    end
end

if ReaderNavigation then
    for k, v in pairs(ReaderNavigation) do
        FanQiePlugin[k] = v
    end
end

function FanQiePlugin:logInitError(step, err)
    local err_msg = log_error(err)
    if logger and logger.err then
        logger.err(LOG_MODULE, step .. ":", err_msg)
    end
    if Log and Log.error then
        Log.error(step .. ":", err_msg)
    end
    local file = io.open("/mnt/us/koreader/fanqie_init_error.log", "a")
    if file then
        file:write("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. step .. ": " .. err_msg .. "\n")
        file:close()
    end
end

function FanQiePlugin:ensurePatchesInstalled()
    local Patches = require("patches.core")
    if not Patches.verifyPatched("ReaderToc") then
        Patches.install()
    end
end



function FanQiePlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_fanqie_bookshelf", {
        category = "none",
        event = "ShowFanQieBookshelf",
        title = _("番茄书架"),
        filemanager = true,
    })
    Dispatcher:registerAction("return_fanqie_toc", {
        category = "none",
        event = "ShowFanQieToc",
        title = _("返回番茄目录"),
        reader = true,
    })
end

function FanQiePlugin:safeCallback(label, callback)
    local self_ref = self
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, debug.traceback)
        if not ok then
            self_ref:closeBusy()
            if logger and logger.err then logger.err(LOG_MODULE, "action failed:", label, log_error(err)) end
            self_ref:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end
end

function FanQiePlugin:addToMainMenu(menu_items)
    if self.ui.document and _state.current_book and self:isCurrentDocFanqie() then
        menu_items.fanqie = {
            text = _("番茄小说"),
            sorting_hint = "tools",
            sub_item_table_func = function()
                return {
                    {
                        text = _("书架"),
                        callback = self:safeCallback(_("书架"), function()
                            self:showBookshelf()
                        end),
                    },
                    {
                        text = _("目录"),
                        callback = self:safeCallback(_("目录"), function()
                            self.ui:handleEvent(Event:new("ShowFanQieToc"))
                        end),
                    },
                    {
                        text = _("设置"),
                        sub_item_table_func = function()
                            return self:getSettingsMenuItems()
                        end,
                    },
                    {
                        text = _("缓存管理"),
                        sub_item_table_func = function()
                            return self:getCacheMenuItems()
                        end,
                    },
                    {
                        text = _("关于"),
                        callback = self:safeCallback(_("关于"), function()
                            self:showAbout()
                        end),
                    },
                }
            end,
        }
    else
        menu_items.fanqie = {
            text = _("番茄小说"),
            sorting_hint = "tools",
            sub_item_table_func = function()
                return self:getMainMenuItems()
            end,
        }
    end
end

function FanQiePlugin:getMainMenuItems()
    return {
        {
            text = _("书架"),
            callback = self:safeCallback(_("书架"), function()
                self:showBookshelf()
            end),
        },
        {
            text = _("设置"),
            sub_item_table_func = function()
                return self:getSettingsMenuItems()
            end,
        },
        {
            text = _("缓存管理"),
            sub_item_table_func = function()
                return self:getCacheMenuItems()
            end,
        },
        {
            text = _("关于"),
            callback = self:safeCallback(_("关于"), function()
                UIManager:show(InfoMessage:new{
                    text = T(_("番茄小说插件 v%1\n\n在 KOReader 中阅读番茄小说，支持章节缓存、预下载和阅读进度同步。\n\n下载格式: HTML\n下载目录: %2"), self.version, self.settings:get_download_dir()),
                })
            end),
        },
    }
end

-- ===========================================================================
-- Settings menu
-- ===========================================================================

function FanQiePlugin:getSettingsMenuItems()
    return {
        {
            text = _("缓存目录"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showDownloadDirPicker(touchmenu_instance)
            end,
        },
        {
            text_func = function()
                local cache = self.settings:get("cache", {})
                local count = cache.pre_download_chapters or 3
                return T(_("预下载章节数: %1"), tostring(count))
            end,
            keep_menu_open = true,
            sub_item_table = {
                { text = "1",  keep_menu_open = true, callback = function() self:setPreDownloadCount(1) end },
                { text = "3",  keep_menu_open = true, callback = function() self:setPreDownloadCount(3) end },
                { text = "5",  keep_menu_open = true, callback = function() self:setPreDownloadCount(5) end },
                { text = "10", keep_menu_open = true, callback = function() self:setPreDownloadCount(10) end },
            },
        },
        
        {
            text = _("下载图片"),
            checked_func = function()
                local cache = self.settings:get("cache", {})
                return cache.download_book_images ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local cache = self.settings:get("cache", {})
                cache.download_book_images = not (cache.download_book_images ~= false)
                self.settings:set("cache", cache)
                self.settings:flush()
            end,
        },
        {
            text = _("读取进度同步"),
            checked_func = function()
                local sync = self.settings:get("sync", {})
                return sync.pull_on_open ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local sync = self.settings:get("sync", {})
                sync.pull_on_open = not (sync.pull_on_open ~= false)
                self.settings:set("sync", sync)
                self.settings:flush()
            end,
        },
        {
            text = _("重新加载配置文件"),
            keep_menu_open = true,
            callback = function()
                self.settings:reset_config_loaded()
                self:loadConfigFile()
            end,
        },
        {
            text = _("调试日志"),
            sub_item_table_func = function()
                return self:getLogMenuItems()
            end,
        },
    }
end

function FanQiePlugin:getLogMenuItems()
    return {
        {
            text_func = function()
                local advanced = self.settings:get("advanced", {})
                return advanced.developer_logs and _("调试日志: 开") or _("调试日志: 关")
            end,
            checked_func = function()
                local advanced = self.settings:get("advanced", {})
                return advanced.developer_logs == true
            end,
            keep_menu_open = true,
            callback = function()
                local advanced = self.settings:get("advanced", {})
                advanced.developer_logs = not (advanced.developer_logs == true)
                self.settings:set("advanced", advanced)
                self.settings:flush()
                if advanced.developer_logs then
                    Log.info("debug logging enabled")
                end
            end,
        },
        {
            text = _("查看日志文件"),
            keep_menu_open = true,
            callback = function()
                local log_path = Log.get_log_file_path()
                if not log_path then
                    self:showInfo(_("日志文件路径未初始化"))
                    return
                end
                if not lfs or not lfs.attributes(log_path, "mode") then
                    self:showInfo(_("日志文件不存在，开启调试日志后操作插件即可生成"))
                    return
                end
                local file = io.open(log_path, "r")
                if not file then
                    self:showInfo(_("无法打开日志文件"))
                    return
                end
                local content = file:read("*a")
                file:close()
                -- Show last 5000 chars to avoid memory issues
                if #content > 5000 then
                    content = "...(仅显示最后5000字符)\n" .. content:sub(-5000)
                end
                UIManager:show(InfoMessage:new{
                    text = content,
                    timeout = 0,
                })
            end,
        },
        {
            text = _("清除日志"),
            keep_menu_open = true,
            callback = function()
                Log.clear_log()
                self:showInfo(_("日志已清除"))
            end,
        },
        {
            text = _("在文件管理器中查看"),
            keep_menu_open = true,
            callback = function()
                local log_path = Log.get_log_file_path()
                if not log_path then return end
                local dir = log_path:match("^(.*)/[^/]+$") or self.settings:get_download_dir()
                local FileManager = require("apps/filemanager/filemanager")
                local RUI = require("apps/reader/readerui")
                if RUI and RUI.instance then
                    RUI.instance:onClose()
                    UIManager:scheduleIn(0.1, function()
                        FileManager:showFiles(dir)
                    end)
                else
                    FileManager:showFiles(dir)
                end
            end,
        },
    }
end

function FanQiePlugin:setPreDownloadCount(n)
    local cache = self.settings:get("cache", {})
    cache.pre_download_chapters = n
    self.settings:set("cache", cache)
    self.settings:flush()
end

function FanQiePlugin:showDownloadDirPicker(touchmenu_instance)
    local path_chooser = PathChooser:new{
        select_file = false,
        path = self.settings:get_download_dir(),
        onConfirm = function(path)
            self.settings:set_download_dir(path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            UIManager:show(InfoMessage:new{
                text = T(_("缓存目录已设置为:\n%1"), path),
                timeout = 2,
            })
        end,
    }
    UIManager:show(path_chooser)
end

-- ===========================================================================
-- Config file loading
-- ===========================================================================

function FanQiePlugin:loadConfigFile(silent)
    local plugin_path = self:getPluginPath()
    local config_path = plugin_path .. "/config.lua"
    
    local file = io.open(config_path, "r")
    if not file then return end
    file:close()
    
    local ok, config = pcall(dofile, config_path)
    if not ok or type(config) ~= "table" then return end
    
    pcall(function()
        self.settings:apply_config(config, { apply_preferences = true })
    end)
end

function FanQiePlugin:getPluginPath()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:match("^@(.+)$") or source
    return path:match("^(.*)/[^/]+$") or "."
end

-- ===========================================================================
-- Network check
-- ===========================================================================

function FanQiePlugin:checkNetwork()
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        self:showInfo(_("未连接网络，请先开启 WiFi"))
        return false
    end
    return true
end



function FanQiePlugin:showBookList(books)
    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end

    for _, book in ipairs(books) do
        if book.cover then
            local cover_filename = string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
            local cover_path = cover_cache_dir .. "/" .. cover_filename
            if H.file_exists(cover_path) then
                book.cover_path = cover_path
            end
        end
    end

    local ShelfView = require("fanqie.shelf_view")
    self.book_list_menu = ShelfView.show{
        title = _("番茄书架"),
        books = books,
        show_covers = true,
        on_select = function(book)
            self:showBookDetail(book)
        end,
        on_close = function()
            self:_cancelCoverLoading()
            self.book_list_menu = nil
            _state.active_menu = nil
        end,
        on_refresh = function()
            self.client:clear_shelf_cache()
            self:showBookshelf()
        end,
        on_page_changed = function(page, first, last, current)
            self:_onShelfPage(books, current, page, first, last)
        end,
    }
    _state.active_menu = self.book_list_menu
end

function FanQiePlugin:_cancelCoverLoading()
    self._cover_generation = (tonumber(self._cover_generation) or 0) + 1
end

function FanQiePlugin:_onShelfPage(books, view, page, first, last)
    self:_cancelCoverLoading()
    local generation = self._cover_generation
    self:_cacheShelfPageCovers(books, view, page, first, last, generation, first)
end

function FanQiePlugin:_cacheShelfPageCovers(books, view, page, first, last, generation, index)
    index = index or first
    if generation ~= self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1) ~= tonumber(page) then
        return
    end
    if index > last then return end

    local book = books[index]
    if not book or not book.cover or book.cover == "" then
        UIManager:scheduleIn(0.1, function()
            self:_cacheShelfPageCovers(books, view, page, first, last, generation, index + 1)
        end)
        return
    end

    if book.cover_path then
        UIManager:scheduleIn(0.1, function()
            self:_cacheShelfPageCovers(books, view, page, first, last, generation, index + 1)
        end)
        return
    end

    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end
    local cover_filename = string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
    local cover_path = cover_cache_dir .. "/" .. cover_filename

    if H.file_exists(cover_path) then
        book.cover_path = cover_path
        local changed = false
        for _, entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id) == tostring(book.book_id or book.bookId) then
                if entry.cover_path ~= cover_path then
                    entry.cover_path = cover_path
                    changed = true
                end
                break
            end
        end
        if changed then
            view._suppress_page_callback = true
            pcall(view.updateItems, view, nil, true)
            view._suppress_page_callback = false
        end
        UIManager:scheduleIn(0.1, function()
            self:_cacheShelfPageCovers(books, view, page, first, last, generation, index + 1)
        end)
        return
    end

    local ok, _ = pcall(function()
        local data = self.client:get_binary(book.cover)
        local file = io.open(cover_path, "wb")
        if file then
            file:write(data)
            file:close()
            book.cover_path = cover_path
            local changed = false
            for _, entry in ipairs(view.item_table or {}) do
                if tostring(entry.book_id) == tostring(book.book_id or book.bookId) then
                    if entry.cover_path ~= cover_path then
                        entry.cover_path = cover_path
                        changed = true
                    end
                    break
                end
            end
            if changed then
                view._suppress_page_callback = true
                pcall(view.updateItems, view, nil, true)
                view._suppress_page_callback = false
            end
        end
    end)

    UIManager:scheduleIn(0.1, function()
        self:_cacheShelfPageCovers(books, view, page, first, last, generation, index + 1)
    end)
end

function FanQiePlugin:showSortMenu()
    local sort_types = {
        { text = _("默认顺序"), value = "default" },
        { text = _("阅读进度"), value = "progress" },
        { text = _("最后阅读时间"), value = "read" },
        { text = _("加入时间"), value = "added" },
        { text = _("书名排序"), value = "title" },
    }

    local current_sort = _state.shelf_sort_type or "default"

    local Menu = require("ui/widget/menu")
    local sort_menu = Menu:new{
        title = _("排序方式"),
        item_table = sort_types,
        is_borderless = true,
        on_close = function()
            sort_menu = nil
        end,
    }

    for i, item in ipairs(sort_menu.item_table) do
        if item.value == current_sort then
            sort_menu:selectItem(i)
            break
        end
    end

    UIManager:show(sort_menu)

    local plugin = self
    sort_menu.onMenuSelect = function(_, item)
        _state.shelf_sort_type = item.value
        UIManager:close(sort_menu)
        plugin.client:clear_shelf_cache()
        plugin:showBookshelf()
    end
end

function FanQiePlugin:showBookDetail(book)
    local cached = Content.load_cache_index(self.settings, book.book_id)
    local cache_count = 0
    for _ in pairs(cached) do cache_count = cache_count + 1 end

    local buttons = {
        {
            {
                text = _("开始阅读"),
                callback = function()
                    UIManager:close(_state.detail_dialog)
                    if _state.active_menu then
                        UIManager:close(_state.active_menu)
                        _state.active_menu = nil
                    end
                    self:openBook(book)
                end,
            },
            {
                text = _("章节目录"),
                callback = function()
                    UIManager:close(_state.detail_dialog)
                    if _state.active_menu then
                        UIManager:close(_state.active_menu)
                        _state.active_menu = nil
                    end
                    self:showChapterListing(book)
                end,
            },
        },
        {
            {
                text = _("下载全书"),
                callback = function()
                    UIManager:close(_state.detail_dialog)
                    self:downloadBook(book)
                end,
            },
        },
        {
            {
                text = _("清空本书缓存"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("确定清空《%s》的缓存?\n%d 章节将被删除。"), book.title or "未知", cache_count),
                        ok_text = _("清空"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            self.settings:clear_book_cache(book.book_id)
                            UIManager:close(_state.detail_dialog)
                            UIManager:show(InfoMessage:new{
                                text = _("缓存已清空"),
                            })
                        end,
                    })
                end,
            },
        },
        {
            {
                text = _("关闭"),
                callback = function()
                    UIManager:close(_state.detail_dialog)
                end,
            },
        },
    }

    local ButtonDialog = require("ui/widget/buttondialog")
    local info_text = string.format("%s\n进度: %d/%d", book.title or "未知", book.read_chapters or 0, book.total_chapters or 0)
    if cache_count > 0 then
        info_text = info_text .. string.format(" [缓存%d章]", cache_count)
    end
    if book.desc and #book.desc > 0 then
        local short_desc = book.desc:sub(1, 200)
        if #book.desc > 200 then short_desc = short_desc .. "..." end
        info_text = info_text .. "\n\n" .. short_desc
    end

    _state.detail_dialog = ButtonDialog:new{
        title = _("书籍详情"),
        title_align = "center",
        info_text = info_text,
        buttons = buttons,
    }
    UIManager:show(_state.detail_dialog)
end

-- ===========================================================================
-- Chapter listing
-- ===========================================================================

function FanQiePlugin:showChapterListing(book)
    if not self:checkNetwork() then return end

    local now = os.time()
    local use_cache = false
    local cached_chapters = nil

    if _state.cached_directory and _state.cached_directory[book.book_id] then
        local cache = _state.cached_directory[book.book_id]
        if (now - cache.timestamp) < 300 then
            use_cache = true
            cached_chapters = cache.chapters
        end
    end

    local chapters
    if use_cache then
        chapters = cached_chapters
    else
        self:showBusy(_("正在获取目录..."))
        local ok
        ok, chapters = pcall(function()
            return self:get_chapters(book.book_id)
        end)
        self:closeBusy()
        if not ok then
            self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
            return
        end

        _state.cached_directory = _state.cached_directory or {}
        _state.cached_directory[book.book_id] = {
            chapters = chapters,
            timestamp = now,
        }
    end

    if not chapters or #chapters == 0 then
        self:showInfo(_("未获取到章节"))
        return
    end

    _state.current_book = book
    _state.current_chapters = chapters

    local cached = Content.load_cache_index(self.settings, book.book_id)
    local current_idx = getCurrentChapterIndex()

    local items = {}
    local cached_map = {}
    if cached then
        for item_id, _ in pairs(cached) do
            cached_map[item_id] = true
        end
    end

    for i, chapter in ipairs(chapters) do
        local title = chapter.title or ("Chapter " .. tostring(i))
        local prefix = ""
        if i == current_idx then
            prefix = "▶ "
        elseif cached_map[tostring(chapter.itemId)] then
            prefix = "✓ "
        end
        table.insert(items, {
            text = prefix .. title,
            callback = function()
                self:openChapter(book, chapters, i)
            end,
        })
    end

    local items_per_page = 12
    local initial_page = 1
    
    if current_idx > 0 then
        items.current = current_idx
        initial_page = math.ceil(current_idx / items_per_page)
    end
    
    local chapter_menu = Menu:new{
        title = string.format("%s - 目录", book.title or book.book_id),
        item_table = items,
        items_per_page = items_per_page,
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            if _state.active_menu == chapter_menu then
                _state.active_menu = nil
            end
        end,
    }
    
    if initial_page > 1 then
        chapter_menu:onGotoPage(initial_page)
    end
    
    _state.active_menu = chapter_menu
    UIManager:show(chapter_menu)
end

function FanQiePlugin:showJumpToChapter(book, chapters)
    local InputDialog = require("ui/widget/inputdialog")
    local total = #chapters

    local dialog
    dialog = InputDialog:new{
        title = _("跳转到章节"),
        input = tostring(getCurrentChapterIndex() > 0 and getCurrentChapterIndex() or 1),
        input_hint = string.format("(1-%d)", total),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("跳转"),
                    is_enter_default = true,
                    callback = function()
                        local input = dialog:getInputText()
                        local idx = tonumber(input)
                        if idx and idx >= 1 and idx <= total then
                            UIManager:close(dialog)
                            self:openChapter(book, chapters, math.floor(idx))
                        else
                            UIManager:show(InfoMessage:new{
                                text = T(_("请输入 1 到 %1 之间的数字"), total),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanQiePlugin:get_chapters(book_id)
    local book = { book_id = book_id }
    return Content.fetch_catalog(self.client, book)
end

-- ===========================================================================
-- Chapter reading & auto-jump next chapter
-- ===========================================================================

function FanQiePlugin:navigateToChapter(book, chapters, chapter_index, opts)
    opts = opts or {}
    local chapter = chapters[chapter_index]
    if not chapter then return false end

    if _state.is_downloading then
        return false
    end

    _state.current_book = book
    _state.current_chapters = chapters

    local item_id = tostring(chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]

    if existing_path and H.file_exists(existing_path) then
        _state.current_chapter_index = chapter_index
        _state.pre_download_triggered = false
        self:showReaderUI(existing_path, chapter)
        if opts.after_navigate then
            UIManager:scheduleIn(1.0, opts.after_navigate)
        end
        return true
    end

    _state.is_downloading = true
    self:showBusy(T(_("正在下载: %s"), chapter.title or ""))

    UIManager:scheduleIn(0.1, function()
        local ok, path = pcall(function()
            local b = { book_id = book.book_id, title = book.title, author = book.author }
            return Content.fetch_chapter_html(self.client, self.settings, b, chapter)
        end)
        self:closeBusy()

        if not ok then
            Log.error("navigateToChapter download failed:", tostring(path))
            _state.is_downloading = false
            self:showError(T(_(opts.error_message or "下载章节失败:\n%1"), display_error(path)))
            return
        end

        local cached_chapters = getCachedChapters(self, book)
        cached_chapters[item_id] = path

        _state.current_chapter_index = chapter_index
        _state.pre_download_triggered = false
        _state.is_downloading = false
        self:showReaderUI(path, chapter)

        if opts.after_navigate then
            UIManager:scheduleIn(1.0, opts.after_navigate)
        end
    end)

    return true
end

function FanQiePlugin:openChapter(book, chapters, chapter_index)
    return self:navigateToChapter(book, chapters, chapter_index, {
        error_message = "下载章节失败:\n%1",
    })
end

function FanQiePlugin:showReaderUI(path, chapter)
    local ReaderUI = require("apps/reader/readerui")

    local ok, err = pcall(function()
        if ReaderUI.instance then
            ReaderUI.instance:switchDocument(path, false)
        else
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
            ReaderUI:showReader(path, nil, false)
        end
    end)
    if not ok then
        Log.error("showReaderUI failed:", log_error(err))
        self:showError(T(_("打开文档失败:\n%1"), display_error(err)))
        return
    end
    _state.current_document_path = path
    
    if _state.current_book then
        UIManager:scheduleIn(1.0, function()
            if _state.current_book then
                getCachedChapters(self, _state.current_book)
            end
        end)
    end
end

function FanQiePlugin:preDownloadChapters(book, chapters, current_index)
    local cache = self.settings:get("cache", {})
    local pre_download_count = cache.pre_download_chapters or 3
    local total = #chapters

    if current_index >= total then return end

    local cached_chapters = getCachedChapters(self, book)

    UIManager:scheduleIn(1.0, function()
        for offset = 1, pre_download_count do
            local target_idx = current_index + offset
            if target_idx > total then break end

            local chapter = chapters[target_idx]
            local item_id = tostring(chapter.itemId)

            if cached_chapters[item_id] and H.file_exists(cached_chapters[item_id]) then
                Log.debug("pre-download: chapter", target_idx, "already cached")
                goto continue
            end

            Log.info("pre-download: starting download for chapter", target_idx)
            local ok, path = pcall(function()
                local b = { book_id = book.book_id, title = book.title, author = book.author }
                return Content.fetch_chapter_html(self.client, self.settings, b, chapter)
            end)

            if ok then
                cached_chapters[item_id] = path
                Log.info("pre-download: completed chapter", target_idx)
            else
                Log.warn("pre-download: failed for chapter", target_idx, ":", path)
            end

            ::continue::
        end
    end)
end

-- Get current page progress within the chapter (0.0 - 1.0)
function FanQiePlugin:getCurrentPageProgress()
    if self.ui and self.ui.document then
        local doc = self.ui.document
        if doc.info and doc.info.number_of_pages and doc.info.number_of_pages > 0 then
            local current_page = self.ui.state and self.ui.state.page or 1
            return math.min(current_page / doc.info.number_of_pages, 1.0)
        end
    end
    return 0
end

-- Sync reading progress to server (called on chapter end and document close)
function FanQiePlugin:syncCurrentProgress()
    if not _state.current_book or not _state.current_chapters then return end
    local idx = _state.current_chapter_index
    if not idx or idx < 1 then return end
    local chapter = _state.current_chapters[idx]
    if not chapter or not chapter.itemId or not _state.current_book.book_id then
        return
    end
    local progress = self:getCurrentPageProgress()
    local last_report = _state.getLastProgressReport(chapter.itemId)
    if last_report and last_report.progress >= progress then
        return
    end

    local start_time = os.clock()
    UIManager:scheduleIn(0.1, function()
        local ok, err = pcall(function()
            self.client:update_read_progress(
                _state.current_book.book_id,
                chapter.itemId,
                idx - 1,
                progress
            )
        end)
        Log.info("syncCurrentProgress completed in", string.format("%.3f", os.clock() - start_time), "seconds")
        if ok then
            _state.setLastProgressReport(chapter.itemId, progress)
            _state.removePendingProgress(_state.current_book.book_id, chapter.itemId)
        else
            _state.addPendingProgress(_state.current_book.book_id, chapter.itemId, idx - 1, progress)
        end
    end)
end

-- Retry pending progress reports when network is available
function FanQiePlugin:retryPendingProgress()
    local book_id = _state.current_book and _state.current_book.book_id
    if not book_id then return end

    local start_time = os.clock()
    UIManager:scheduleIn(0.5, function()
        local pending = _state.getPendingProgress()
        local count = 0
        for key, item in pairs(pending) do
            if item.book_id == book_id then
                count = count + 1
                local ok, err = pcall(function()
                    self.client:update_read_progress(
                        item.book_id,
                        item.item_id,
                        item.chapter_idx,
                        item.progress
                    )
                end)
                if ok then
                    _state.setLastProgressReport(item.item_id, item.progress)
                    _state.removePendingProgress(item.book_id, item.item_id)
                end
            end
        end
        Log.info("retryPendingProgress completed", count, "items in", string.format("%.3f", os.clock() - start_time), "seconds")
    end)
end

function FanQiePlugin:onPageUpdate(pageno)
    if not _state.current_book or not _state.current_chapters then
        return
    end
    if not self:isCurrentDocFanqie() then
        return
    end

    if not self.ui or not self.ui.document then return end

    local doc = self.ui.document
    local total_pages = doc:getPageCount()
    if not total_pages or total_pages <= 0 then return end

    local progress = pageno / total_pages
    if progress > 0.5 and not _state.pre_download_triggered then
        _state.pre_download_triggered = true
        UIManager:scheduleIn(0.1, function()
            self:preDownloadChapters(_state.current_book, _state.current_chapters, _state.current_chapter_index)
        end)
    end

    if pageno % 10 == 0 then
        self:syncCurrentProgress()
    end
end

function FanQiePlugin:onStartOfBook()
    if not _state.current_book or not _state.current_chapters then
        return false
    end
    if not self:isCurrentDocFanqie() then
        return false
    end

    if _state.start_of_chapter_triggered then
        return false
    end

    local current_idx = getCurrentChapterIndex()
    if current_idx <= 1 then
        UIManager:show(InfoMessage:new{
            text = _("已经是第一章了"),
            timeout = 3,
        })
        return true
    end

    local prev_idx = current_idx - 1
    local chapters = _state.current_chapters
    local book = _state.current_book
    local prev_chapter = chapters[prev_idx]
    if not prev_chapter then
        return true
    end

    _state.start_of_chapter_triggered = true
    self:navigateToChapter(book, chapters, prev_idx, {
        error_message = "加载上一章失败:\n%1",
        after_navigate = function()
            _state.start_of_chapter_triggered = false
            self:syncCurrentProgress()
            self:preDownloadChapters(book, chapters, prev_idx)
            self:retryPendingProgress()
        end,
    })

    return true
end

function FanQiePlugin:onEndOfBook()
    if not _state.current_book or not _state.current_chapters then
        return false
    end
    
    local is_fanqie = self:isCurrentDocFanqie()
    if not is_fanqie then
        return false
    end

    local current_idx = getCurrentChapterIndex()
    local chapters = _state.current_chapters
    local book = _state.current_book

    if book.book_id and current_idx > 0 then
        local chapter = chapters[current_idx]
        if chapter and chapter.itemId then
            local last_report = _state.getLastProgressReport(chapter.itemId)
            if not last_report or last_report.progress < 1.0 then
                local book_id = book.book_id
                local item_id = chapter.itemId
                local idx = current_idx
                UIManager:scheduleIn(0.1, function()
                    local ok, err = pcall(function()
                        self.client:update_read_progress(book_id, item_id, idx - 1, 1.0)
                    end)
                    if ok then
                        _state.setLastProgressReport(item_id, 1.0)
                        _state.removePendingProgress(book_id, item_id)
                    else
                        _state.addPendingProgress(book_id, item_id, idx - 1, 1.0)
                    end
                end)
            end
        end
    end

    local next_idx = current_idx + 1

    if next_idx > #chapters then
        UIManager:show(InfoMessage:new{
            text = _("已经是最后一章了"),
            timeout = 3,
        })
        return true
    end

    local next_chapter = chapters[next_idx]
    if not next_chapter then
        return true
    end

    self:navigateToChapter(book, chapters, next_idx, {
        error_message = "加载下一章失败:\n%1",
        after_navigate = function()
            self:preDownloadChapters(book, chapters, next_idx)
            self:retryPendingProgress()
        end,
    })

    return true
end

function FanQiePlugin:onCloseDocument()
    if not self:isCurrentDocFanqie() then
        return
    end
    self:syncCurrentProgress()
    _state.current_document_path = nil
    _state.setTocMenuOpen(false)
    _state.pre_download_triggered = false
end

function FanQiePlugin:onClose()
    if _state.active_menu then
        UIManager:close(_state.active_menu)
        _state.active_menu = nil
    end
    if _state.detail_dialog then
        UIManager:close(_state.detail_dialog)
        _state.detail_dialog = nil
    end
    if _state.toc_menu then
        UIManager:close(_state.toc_menu)
        _state.toc_menu = nil
    end
    _state.setTocMenuOpen(false)
end

function FanQiePlugin:onCloseWidget()
    self:onClose()
end

function FanQiePlugin:onShowFanQieToc()
    if not (_state.current_book and _state.current_chapters) then
        return false
    end
    if not self:isCurrentDocFanqie() then
        return false
    end
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = true
    end

    self:syncCurrentProgress()

    local book = _state.current_book
    local chapters = _state.current_chapters
    local current_idx = getCurrentChapterIndex()
    local cached = _state.getChapterIndexCache(book.book_id)
    if not cached then
        cached = Content.load_cache_index(self.settings, book.book_id)
    end

    local items = {}
    local cached_map = {}
    if cached then
        for item_id, _ in pairs(cached) do
            cached_map[item_id] = true
        end
    end

    for i, chapter in ipairs(chapters) do
        local title = chapter.title or ("Chapter " .. tostring(i))
        local prefix = ""
        if i == current_idx then
            prefix = "▶ "
        elseif cached_map[tostring(chapter.itemId)] then
            prefix = "✓ "
        end
        table.insert(items, {
            text = prefix .. title,
            callback = function()
                self:openChapter(book, chapters, i)
            end,
        })
    end

    Log.info("fanqie onShowFanQieToc: current_idx=", current_idx, "total chapters=", #chapters)
    
    if current_idx > 0 then
        items.current = current_idx
        Log.info("fanqie onShowFanQieToc: setting items.current to=", current_idx)
    else
        Log.warn("fanqie onShowFanQieToc: current_idx is 0 or nil, cannot set items.current")
    end
    
    local toc_menu = Menu:new{
        title = string.format("%s - 目录", book.title or book.book_id),
        item_table = items,
        items_per_page = 12,
        close_callback = function()
            if _state.active_menu == toc_menu then
                _state.active_menu = nil
            end
        end,
    }
    
    _state.active_menu = toc_menu
    UIManager:show(toc_menu)
    return true
end

function FanQiePlugin:onShowFanQieBookshelf()
    if not (self.ui and self.ui.document) then
        self:showBookshelf()
    end
    return true
end

-- ===========================================================================
-- Book download (batch)
-- ===========================================================================

function FanQiePlugin:downloadBook(book)
    if not self:checkNetwork() then return end
    self:showBusy(_("正在获取目录..."))
    local ok, chapters = pcall(function()
        return self:get_chapters(book.book_id)
    end)
    self:closeBusy()
    if not ok then
        self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
        return
    end
    if not chapters or #chapters == 0 then
        self:showInfo(_("未获取到章节"))
        return
    end

    -- ask download range
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    dialog = ButtonDialog:new{
        title = _("下载范围"),
        title_align = "center",
        info_text = T(_("共 %1 章，请选择下载范围"), #chapters),
        buttons = {
            {
                { text = _("全部下载"), callback = function()
                    UIManager:close(dialog)
                    self:doDownloadBook(book, chapters, 1, #chapters)
                end },
                { text = _("前10章"), callback = function()
                    UIManager:close(dialog)
                    self:doDownloadBook(book, chapters, 1, math.min(10, #chapters))
                end },
            },
            {
                { text = _("自定义范围"), callback = function()
                    UIManager:close(dialog)
                    self:showDownloadRangeDialog(book, chapters)
                end },
                { text = _("取消"), callback = function()
                    UIManager:close(dialog)
                end },
            },
        },
    }
    UIManager:show(dialog)
end

function FanQiePlugin:showDownloadRangeDialog(book, chapters)
    local dialog
    dialog = InputDialog:new{
        title = _("下载范围"),
        input = "1-" .. tostring(#chapters),
        input_hint = _("格式: 起始-结束 (如 1-50)"),
        description = T(_("共 %1 章，输入下载范围"), #chapters),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("下载"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        UIManager:close(dialog)
                        local start_idx, end_idx = text:match("^(%d+)%s*-%s*(%d+)$")
                        if start_idx and end_idx then
                            start_idx = tonumber(start_idx)
                            end_idx = tonumber(end_idx)
                            if start_idx < 1 then start_idx = 1 end
                            if end_idx > #chapters then end_idx = #chapters end
                            if start_idx > end_idx then
                                start_idx, end_idx = end_idx, start_idx
                            end
                            self:doDownloadBook(book, chapters, start_idx, end_idx)
                        else
                            self:showInfo(_("格式错误，请使用 起始-结束 格式"))
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanQiePlugin:doDownloadBook(book, chapters, start_idx, end_idx)
    local selected = {}
    for i = start_idx, end_idx do
        table.insert(selected, chapters[i])
    end

    local dialog = DownloadProgress:new{
        title = T(_("下载 %s"), book.title or book.book_id),
    }
    dialog:show()

    local downloaded_count = 0
    local failed_count = 0
    local skipped_count = 0
    local total = #selected
    local b = { book_id = book.book_id, title = book.title, author = book.author }

    local cached_chapters = getCachedChapters(self, book)

    for i, chapter in ipairs(selected) do
        if dialog:isCanceled() then
            break
        end

        local item_id = tostring(chapter.itemId)
        
        if cached_chapters[item_id] and H.file_exists(cached_chapters[item_id]) then
            skipped_count = skipped_count + 1
            downloaded_count = downloaded_count + 1
            
            local chapter_title = chapter.title or string.format(_("第%d章"), i)
            dialog:setState{
                stage = "content",
                current = downloaded_count,
                total = total,
                chapter = chapter_title,
            }
            
            if i < total then
                util.sleep(0.1)
            end
            goto continue
        end

        local chapter_title = chapter.title or string.format(_("第%d章"), i)
        dialog:setState{
            stage = "content",
            current = downloaded_count,
            total = total,
            chapter = chapter_title,
        }

        local ok, path = pcall(function()
            return Content.fetch_chapter_html(self.client, self.settings, b, chapter)
        end)

        if ok then
            cached_chapters[item_id] = path
            downloaded_count = downloaded_count + 1
        else
            failed_count = failed_count + 1
            if Log then Log.warn("chapter download failed:", chapter_title, path) end
        end

        dialog:setState{
            stage = "content",
            current = downloaded_count,
            total = total,
            chapter = chapter_title,
        }

        if i < total then
            util.sleep(0.5)
        end
        
        ::continue::
    end

    dialog:close()

    if dialog:isCanceled() and downloaded_count < total then
        self:showInfo(T(_("已取消下载\n已保存 %1/%2 章"), downloaded_count, total))
    else
        local msg = T(_("下载完成!\n共 %1/%2 章"), downloaded_count, total)
        if skipped_count > 0 then
            msg = msg .. T(_(" (跳过已缓存 %d 章)"), skipped_count)
        end
        if failed_count > 0 then
            msg = msg .. T(_(" (失败 %d 章)"), failed_count)
        end
        self:showInfo(msg)
    end
end

-- ===========================================================================
-- Cache management
-- ===========================================================================

function FanQiePlugin:getCacheMenuItems()
    local items = {}
    local stats = self.settings:get_cache_stats()
    local size_mb = stats.total_size / (1024 * 1024)

    table.insert(items, {
        text = T(_("缓存统计: %d 本书, %d 章节, %.1f MB"), stats.book_count, stats.chapter_count, size_mb),
        enabled_func = function() return false end,
    })
    table.insert(items, {
        text = _("查看缓存目录"),
        keep_menu_open = true,
        callback = function()
            local dir = self.settings:get_download_dir()
            local FileManager = require("apps/filemanager/filemanager")
            local RUI = require("apps/reader/readerui")
            if RUI and RUI.instance then
                RUI.instance:onClose()
                UIManager:scheduleIn(0.1, function()
                    FileManager:showFiles(dir)
                end)
            else
                FileManager:showFiles(dir)
            end
        end,
    })
    table.insert(items, {
        text = _("刷新章节缓存"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("确定刷新章节缓存?\n下次打开书籍时将重新获取最新章节列表。"),
                ok_text = _("刷新"),
                cancel_text = _("取消"),
                ok_callback = function()
                    _state.invalidateAllCache()
                    self.client:clear_shelf_cache()
                    UIManager:show(InfoMessage:new{
                        text = _("章节缓存已刷新"),
                    })
                end,
            })
        end,
    })
    table.insert(items, {
        text = _("清除全部缓存"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = T(_("确定清除所有番茄小说缓存?\n%d 本书, %d 章节将被删除。"), stats.book_count, stats.chapter_count),
                ok_text = _("清除"),
                cancel_text = _("取消"),
                ok_callback = function()
                    self.settings:clear_all_cache()
                    self.client:clear_shelf_cache()
                    _state.invalidateAllCache()
                    UIManager:show(InfoMessage:new{
                        text = _("缓存已清除"),
                    })
                end,
            })
        end,
    })
    return items
end

function FanQiePlugin:getCacheSizeMB()
    local total = 0
    local dir = self.settings:get_download_dir()
    local ok = pcall(function()
        local function walk(path)
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    local full = path .. "/" .. entry
                    local attr = lfs.attributes(full)
                    if attr then
                        if attr.mode == "directory" then
                            walk(full)
                        else
                            total = total + attr.size
                        end
                    end
                end
            end
        end
        walk(dir)
    end)
    return total / (1024 * 1024)
end

function FanQiePlugin:clearAllCache()
    local dir = self.settings:get_download_dir()
    if not dir then
        self:showInfo(_("下载目录未设置"))
        return
    end

    local ProgressWidget = require("ui/widget/progresswidget")
    local progress = ProgressWidget:new{
        width = Screen:getWidth() - 100,
        height = 8,
    }
    local progress_dialog = InfoMessage:new{
        text = _("正在清除缓存..."),
        timeout = 0,
        dismissable = false,
        icon = "info",
        additional_widgets = { progress },
    }
    UIManager:show(progress_dialog)

    local total_files = 0
    local function count_files(path)
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local full = path .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "directory" then
                        count_files(full)
                    end
                    total_files = total_files + 1
                end
            end
        end
    end
    count_files(dir)

    local removed_count = 0
    local function remove_tree(path)
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local full = path .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "directory" then
                        remove_tree(full)
                        lfs.rmdir(full)
                    else
                        os.remove(full)
                    end
                    removed_count = removed_count + 1
                    if total_files > 0 then
                        progress:setProgress(removed_count / total_files)
                    end
                    UIManager:forceRePaint()
                end
            end
        end
    end

    pcall(remove_tree, dir)
    UIManager:close(progress_dialog)
    self:showInfo(string.format(_("缓存已清除\n共删除 %d 个文件"), removed_count))
end

-- ===========================================================================
-- Book opening (from bookshelf or direct)
-- ===========================================================================

function FanQiePlugin:openBook(book)
    if not self:checkNetwork() then return end
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = true
    end
    _state.current_book = book

    -- get chapters first
    self:showBusy(_("正在获取目录..."))
    local ok, chapters = pcall(function()
        return self:get_chapters(book.book_id)
    end)
    self:closeBusy()

    if not ok then
        self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
        return
    end

    if not chapters or #chapters == 0 then
        self:showInfo(_("未获取到章节"))
        return
    end

    UIManager:scheduleIn(0.1, function()
        getCachedChapters(self, book)
    end)

    -- try to get reading progress and find chapter by item_id
    local start_index = 1
    if self.settings:get("sync", {}).pull_on_open ~= false then
        pcall(function()
            local progress = self.client:fetch_read_progress()
            if progress and progress.data then
                for _, item in ipairs(progress.data) do
                    if tostring(item.book_id or item.bookId) == tostring(book.book_id) then
                        local target_item_id = tostring(item.item_id or item.itemId)
                        if target_item_id and target_item_id ~= "" then
                            for idx, ch in ipairs(chapters) do
                                if tostring(ch.itemId or ch.item_id) == target_item_id then
                                    start_index = idx
                                    break
                                end
                            end
                        end
                        break
                    end
                end
            end
        end)
    end

    if start_index > #chapters then
        start_index = 1
    end

    self:openChapter(book, chapters, start_index)
end

-- ===========================================================================
-- UI helpers
-- ===========================================================================

function FanQiePlugin:showBusy(text)
    self._busy_msg = InfoMessage:new{ text = text, norefresh = true }
    UIManager:show(self._busy_msg)
    UIManager:forceRePaint()
end

function FanQiePlugin:closeBusy()
    if self._busy_msg then
        UIManager:close(self._busy_msg)
        self._busy_msg = nil
    end
end

function FanQiePlugin:showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function FanQiePlugin:showError(text)
    UIManager:show(InfoMessage:new{ text = text, norefresh = false })
end

return FanQiePlugin
