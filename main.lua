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

local MultiInputDialog = safe_require("ui/widget/multiinputdialog")

local DataStorage = safe_require("datastorage")

local Menu = safe_require("ui/widget/menu")

local TextViewer = safe_require("ui/widget/textviewer")

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

-- Shared state across FileManager and ReaderUI instances
-- (KOReader creates separate WidgetContainer instances for each)
local ok_state, _state = pcall(require, "fanqie.state")
-- fallback_settings_ref 用于在 fallback _state 中也能持久化段评开关
local fallback_settings_ref = nil
if not ok_state then
    _state = {
        current_book = nil,
        current_chapters = nil,
        current_chapter_index = nil,
        current_document_path = nil,
        cached_directory = nil,
        enable_review = false,
        current_para_reviews = {},
        current_para_index = 0,
    }
    function _state.isReviewEnabled() return _state.enable_review == true end
    function _state.setReviewEnabled(v)
        _state.enable_review = v == true
        if fallback_settings_ref then
            pcall(function() fallback_settings_ref:setParaReviewEnabled(_state.enable_review) end)
        end
    end
    function _state.loadReviewState(settings)
        if not settings then return end
        fallback_settings_ref = settings
        local ok_val, val = pcall(function() return settings:getParaReviewEnabled() end)
        if ok_val and val == true then _state.enable_review = true end
    end
    function _state.getCurrentParaReviews() return _state.current_para_reviews or {} end
    function _state.setCurrentParaReviews(r) _state.current_para_reviews = r or {} end
    function _state.setCurrentParaIndex(i) _state.current_para_index = i or 0 end
    function _state.getCurrentParaIndex() return _state.current_para_index or 0 end
    function _state.clearParaReviews() _state.current_para_reviews = {}; _state.current_para_index = 0 end
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
    version = "2.0.0",
}

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
    -- 尽早安装补丁（含 ReaderLink 段评链接拦截），确保已打开的书也能立即生效
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = Patches.verifyPatched()
    end
    -- 加载持久化的段评开关（必须在加载 config 之前，让 config 不覆盖用户选择）
    if _state.loadReviewState then
        _state.loadReviewState(self.settings)
    end
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
                        text = _("段评"),
                        separator = true,
                        sub_item_table_func = function()
                            return self:getReviewMenuItems()
                        end,
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
                        text = _("重新获取本章节"),
                        callback = self:safeCallback(_("重新获取本章节"), function()
                            self:reloadCurrentChapter()
                        end),
                    },
                    {
                        text = _("关于"),
                        callback = self:safeCallback(_("关于"), function()
                            self:showInfo(T(_("番茄小说插件 v%1\n\n在 KOReader 中阅读番茄小说，支持章节缓存、预下载和阅读进度同步。\n\n下载格式: HTML\n下载目录: %2"), self.version, self.settings:get_download_dir()))
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

-- ===========================================================================
-- 段评菜单
-- ===========================================================================

function FanQiePlugin:getReviewMenuItems()
    local items = {}

    -- 段评开关
    table.insert(items, {
        text_func = function()
            if _state.isReviewEnabled() then
                return _("段评: 开 (点击关闭)")
            else
                return _("段评: 关 (点击开启)")
            end
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local new_state = not _state.isReviewEnabled()
            _state.setReviewEnabled(new_state)

            if new_state then
                -- 开启段评：重新获取当前章节（带 review=1）
                self:showInfo(_("段评已开启，正在重新获取章节..."))
                self:reloadCurrentChapter()
            else
                -- 关闭段评：清除段评数据
                _state.clearParaReviews()
                self:showInfo(_("段评已关闭"))
            end

            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })

    -- 刷新段评
    table.insert(items, {
        text = _("刷新段评数据"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showInfo(_("正在刷新段评数据..."))
            self:reloadCurrentChapter()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })

    return items
end

-- 显示段评列表对话框
function FanQiePlugin:showParaReviewList()
    local reviews = _state.getCurrentParaReviews()
    if #reviews == 0 then
        self:showInfo(_("当前章节暂无段评数据"))
        return
    end
    
    -- 构建段评列表项
    local items = {}
    for i, pr in ipairs(reviews) do
        table.insert(items, {
            text = string.format("%d. %d条评论", i, pr.count or 0),
            callback = function()
                self:showParaReviewDetail(i)
            end,
        })
    end
    
    local menu = Menu:new{
        title = _("段评列表"),
        item_table = items,
        items_per_page = 20,
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            _state.active_menu = nil
        end,
    }
    _state.active_menu = menu
    UIManager:show(menu)
end

-- 显示单段段评详情（从API获取评论数据）
function FanQiePlugin:showParaReviewDetail(index)
    local reviews = _state.getCurrentParaReviews()
    local pr = reviews[index]
    if not pr or not pr.ident then
        self:showInfo(_("段评数据无效"))
        return
    end
    
    self:showBusy(_("正在获取段评..."))

    UIManager:scheduleIn(0.1, function()
        local ok, result = pcall(function()
            -- 复用已登录的 client，避免重新登录
            local c = self.client or Client:new(self.settings)
            -- 根据 ident URL 域名判断书源，优先调用对应源避免不必要的失败请求
            -- 注意: find 第 4 参数 true 为纯文本模式，不能带 % 转义
            local ident_str = tostring(pr.ident)
            local is_dahuilang = ident_str:find("czyl.cf", 1, true)
            local is_qingtian = ident_str:find("gyks.cf", 1, true)

            if Log then
                Log.info("[段评] showParaReviewDetail: idx=" .. tostring(index)
                    .. " is_dahuilang=" .. tostring(is_dahuilang)
                    .. " is_qingtian=" .. tostring(is_qingtian)
                    .. " ident=" .. ident_str:sub(1, 80))
            end

            if is_dahuilang and not is_qingtian then
                -- 大灰狼源：直接调用大灰狼
                return c:dahuilang_get_para_review(pr.ident)
            elseif is_qingtian and not is_dahuilang then
                -- 晴天源：直接调用晴天
                return c:qingtian_get_para_review(pr.ident)
            else
                -- 未知源：先试晴天，再试大灰狼
                local ok_qt, err_qt = pcall(function()
                    return c:qingtian_get_para_review(pr.ident)
                end)
                if ok_qt and err_qt then
                    return err_qt
                end
                -- 晴天失败则尝试大灰狼
                local ok_dl, err_dl = pcall(function()
                    return c:dahuilang_get_para_review(pr.ident)
                end)
                if ok_dl and err_dl then
                    return err_dl
                end
                error("所有书源均获取段评失败")
            end
        end)
        
        self:closeBusy()

        if not ok then
            if Log then Log.error("[段评] 获取失败:", tostring(result)) end
            self:showInfo(_("段评获取失败: ") .. tostring(result))
            return
        end

        -- 日志：记录 API 返回的原始结构，便于诊断
        if Log then
            local result_type = type(result)
            local comments_count = 0
            local total_val = 0
            if result_type == "table" then
                local c = result.comments
                if not c and type(result.data) == "table" then
                    c = result.data.comments or result.data
                end
                if type(c) == "table" then comments_count = #c end
                total_val = result.total
                    or (result.data and result.data.total) or 0
            end
            Log.info("[段评] API返回: type=" .. result_type
                .. " comments=" .. comments_count
                .. " total=" .. tostring(total_val))
        end

        -- 解析并显示评论
        -- API 可能返回多种结构：
        --   1. { comments: [...] }              — 顶层
        --   2. { data: { comments: [...] } }    — data 嵌套（大灰狼实际格式）
        --   3. { data: [...] }                  — data 直接是数组
        local comments = nil
        if type(result) == "table" then
            comments = result.comments
            if not comments and type(result.data) == "table" then
                comments = result.data.comments or result.data
            end
        end
        if type(comments) ~= "table" then comments = {} end

        local total = 0
        if type(result) == "table" then
            total = result.total or (result.data and result.data.total) or #comments or 0
        end

        if #comments > 0 then
            -- 使用 TextViewer 展示段评，可滚动浏览
            local text_parts = {}
            for i, comment in ipairs(comments) do
                local username = tostring(comment.username or comment.user_name
                    or (comment.user and comment.user.user_name)
                    or (comment.user and comment.user.nick_name)
                    or comment.nick_name or comment.nickname or "匿名")
                local content_text = tostring(comment.content or comment.text or "")
                local like_count = tonumber(comment.like_count or comment.likeCount) or 0
                local reply_count = tonumber(comment.reply_count or comment.replyCount) or 0
                local raw_time = comment.create_time or comment.create_at or comment.time
                local time_str = ""
                if type(raw_time) == "number" then
                    -- Unix 时间戳 → 可读格式
                    time_str = os.date("%Y-%m-%d %H:%M", raw_time)
                elseif raw_time then
                    time_str = tostring(raw_time)
                end

                -- 格式: 序号. 用户名 (赞N 回复N) 时间
                --        评论内容
                local header = string.format("%d. %s (赞%d 回复%d)", i, username, like_count, reply_count)
                if time_str ~= "" then
                    header = header .. "  " .. time_str
                end
                table.insert(text_parts, header .. "\n" .. content_text)
            end

            local total_reviews = #reviews
            local review_text = table.concat(text_parts, "\n\n")

            -- 构建底部按钮：上一段 / 下一段 / 关闭
            local buttons_table = {}
            local nav_row = {}
            if index > 1 then
                table.insert(nav_row, {
                    text = _("上一段"),
                    callback = function()
                        UIManager:close(self._para_viewer)
                        self:showParaReviewDetail(index - 1)
                    end,
                })
            end
            if index < total_reviews then
                table.insert(nav_row, {
                    text = _("下一段"),
                    callback = function()
                        UIManager:close(self._para_viewer)
                        self:showParaReviewDetail(index + 1)
                    end,
                })
            end
            if #nav_row > 0 then
                table.insert(buttons_table, nav_row)
            end
            table.insert(buttons_table, {
                {
                    text = _("关闭"),
                    callback = function()
                        UIManager:close(self._para_viewer)
                    end,
                },
            })

            self._para_viewer = TextViewer:new{
                title = T(_("段评 %1/%2 (共%3条)"), tostring(index),
                    tostring(total_reviews), tostring(#comments)),
                text = review_text,
                text_type = "book_info",
                justified = false,
                buttons_table = buttons_table,
            }
            UIManager:show(self._para_viewer)
        else
            self:showInfo(T(_("本条段评共 %1 条评论，暂无显示数据"), tostring(total)))
        end
    end)
end

-- ============================================================================
-- 段评链接拦截
-- ============================================================================
-- KOReader 的 ReaderLink:showLinkBox() 在检测到 <a> 链接点击时，直接调用
-- self:onGotoLink()（方法调用，非事件广播），因此插件自身的 onGotoLink 永远
-- 收不到。ReaderLink:onGotoLink 不认识 fanqie-para: 协议，会报"无效或外部链接"。
--
-- 解决方案：通过 patches/core.lua 猴补丁 ReaderLink.onGotoLink，在原函数之前
-- 检查 fanqie-para: 前缀，匹配则派发 FanQieParaReview 事件给本插件。
function FanQiePlugin:onFanQieParaReview(idx)
    if not self:isCurrentDocFanqie() then return end
    if not idx then return end
    if Log then Log.info("[段评] onFanQieParaReview: idx=" .. tostring(idx)) end
    self:showParaReviewDetail(idx)
    return true
end

function FanQiePlugin:getMainMenuItems()
    local items = {
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
    }
    
    -- Add "Reload current chapter" option only when reading a fanqie chapter
    if self:isCurrentDocFanqie() and _state.current_chapter_index and _state.current_chapter_index > 0 then
        table.insert(items, {
            text = _("重新获取本章节"),
            separator = true,
            callback = self:safeCallback(_("重新获取本章节"), function()
                self:reloadCurrentChapter()
            end),
        })
    end
    
    table.insert(items, {
        text = _("关于"),
        callback = self:safeCallback(_("关于"), function()
            UIManager:show(InfoMessage:new{
                text = T(_("番茄小说插件 v%1\n\n在 KOReader 中阅读番茄小说，支持章节缓存、预下载和阅读进度同步。\n\n下载格式: HTML\n下载目录: %2"), self.version, self.settings:get_download_dir()),
            })
        end),
    })
    
    return items
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
                { text = "1",  keep_menu_open = true, callback = function() self:setPreDownloadCount(1) end,
                    checked_func = function() local c = self.settings:get("cache", {}); return (c and c.pre_download_chapters or 3) == 1 end },
                { text = "3",  keep_menu_open = true, callback = function() self:setPreDownloadCount(3) end,
                    checked_func = function() local c = self.settings:get("cache", {}); return (c and c.pre_download_chapters or 3) == 3 end },
                { text = "5",  keep_menu_open = true, callback = function() self:setPreDownloadCount(5) end,
                    checked_func = function() local c = self.settings:get("cache", {}); return (c and c.pre_download_chapters or 3) == 5 end },
                { text = "10", keep_menu_open = true, callback = function() self:setPreDownloadCount(10) end,
                    checked_func = function() local c = self.settings:get("cache", {}); return (c and c.pre_download_chapters or 3) == 10 end },
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
                self:loadConfigFile(false, true)
            end,
        },
        {
            text = _("书源管理"),
            sub_item_table_func = function()
                return self:getSourceMenuItems()
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

-- ===========================================================================
-- Book source management
-- ===========================================================================

function FanQiePlugin:getSourceMenuItems()
    local SourceManager = require("fanqie.sources")
    local ordered = SourceManager.get_all_sources(self.settings)
    local items = {}
    for _i, src in ipairs(ordered) do
        local cfg = src.config
        local meta = src.meta
        local is_dev = meta.in_development == true
        local is_enabled = cfg.enabled ~= false
        local is_configured = SourceManager.is_configured(src.id, cfg, self.settings)
        local name = meta.name
        if is_dev then name = name .. _(" (开发中)") end
        if not is_configured and not is_dev then name = name .. _(" (未配置)") end
        local display_name = name
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source(src.id)
                local prefix = (c.enabled ~= false) and "●" or "○"
                return string.format("%s %s", prefix, display_name)
            end,
            enabled_func = function() return not is_dev end,
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getSourceDetailMenuItems(src.id)
            end,
        })
    end
    return items
end

function FanQiePlugin:getSourceDetailMenuItems(source_id)
    local SourceManager = require("fanqie.sources")
    local meta = SourceManager.REGISTRY[source_id]
    local items = {}

    -- Enable / disable toggle (dev sources lock this)
    if not meta.in_development then
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source(source_id)
                return c.enabled ~= false and _("禁用此源") or _("启用此源")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local c = self.settings:get_source(source_id)
                self.settings:set_source_field(source_id, "enabled", c.enabled == false)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        })
    end

    -- Qingtian-specific: server / account / password + auto-login + login status
    if source_id == "qingtian" then
        table.insert(items, {
            text = _("服务器/账号设置"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showQingtianConfigDialog(touchmenu_instance)
            end,
        })
        table.insert(items, {
            text = _("检测可用线路"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showServerDetectionDialog("qingtian", touchmenu_instance)
            end,
        })
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source(source_id)
                return c.auto_login ~= false and _("自动登录: 开") or _("自动登录: 关")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local c = self.settings:get_source(source_id)
                self.settings:set_source_field(source_id, "auto_login", c.auto_login == false)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        })
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source(source_id)
                local token = c.token or ""
                if token ~= "" then
                    return _("已登录 (点击退出)")
                else
                    return _("未登录")
                end
            end,
            enabled_func = function()
                local c = self.settings:get_source(source_id)
                return (c.token or "") ~= ""
            end,
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("确定退出晴天登录？\n将清除已保存的 token 和设备ID。"),
                    ok_text = _("退出登录"),
                    cancel_text = _("取消"),
                    ok_callback = function()
                        self.settings:clear_qingtian_token()
                        local SM = require("fanqie.sources")
                        SM.rate_limit_reset("qingtian")
                        UIManager:show(InfoMessage:new{
                            text = _("已退出晴天登录"), timeout = 2,
                        })
                    end,
                })
            end,
        })
    end

    -- DahuiLang-specific: config + login + logout
    if source_id == "dahuilang" then
        table.insert(items, {
            text = _("服务器/账号设置"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showDahuilangConfigDialog(touchmenu_instance)
            end,
        })
        table.insert(items, {
            text = _("检测可用线路"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showServerDetectionDialog("dahuilang", touchmenu_instance)
            end,
        })
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source(source_id)
                local token = c.token or ""
                if token ~= "" then
                    return _("已登录 (点击退出)")
                else
                    return _("未登录 (点击立即登录)")
                end
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local c = self.settings:get_source(source_id)
                local token = c.token or ""
                if token ~= "" then
                    -- 退出登录
                    UIManager:show(ConfirmBox:new{
                        text = _("确定退出大灰狼登录？\n将清除已保存的 token 和设备ID。"),
                        ok_text = _("退出登录"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            self.settings:clear_dahuilang_token()
                            local SM = require("fanqie.sources")
                            SM.rate_limit_reset("dahuilang")
                            UIManager:show(InfoMessage:new{
                                text = _("已退出大灰狼登录"), timeout = 2,
                            })
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                else
                    -- 立即登录
                    if Client then
                        UIManager:show(InfoMessage:new{
                            text = _("正在登录..."), timeout = 1,
                        })
                        UIManager:scheduleIn(0.5, function()
                            local ok_login, err = pcall(function()
                                local c = Client:new(self.settings)
                                c:dahuilang_login()
                            end)
                            if ok_login then
                                UIManager:show(InfoMessage:new{
                                    text = _("大灰狼登录成功！"), timeout = 2,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("登录失败: ") .. tostring(err), timeout = 3,
                                })
                            end
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                    end
                end
            end,
        })
    end

    -- Rate limit setting (all sources)
    table.insert(items, {
        text_func = function()
            local c = self.settings:get_source(source_id)
            local rl = c.rate_limit or {}
            local mr = rl.max_requests or 0
            local ws = (rl.window_seconds or 0) > 0 and rl.window_seconds or 30
            if mr == 0 then
                return _("限流: 无限制")
            end
            return string.format(_("限流: %d次 / %ds"), mr, ws)
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showSourceRateLimitDialog(source_id, touchmenu_instance)
        end,
    })

    -- Move up / down (order is reflected when user returns to the source list,
    -- because getSourceMenuItems is re-invoked via sub_item_table_func)
    table.insert(items, {
        text = _("上移"),
        separator = true,
        keep_menu_open = true,
        callback = function()
            self.settings:move_source(source_id, -1)
            UIManager:show(InfoMessage:new{
                text = _("已上移，请返回查看顺序"), timeout = 2,
            })
        end,
    })
    table.insert(items, {
        text = _("下移"),
        keep_menu_open = true,
        callback = function()
            self.settings:move_source(source_id, 1)
            UIManager:show(InfoMessage:new{
                text = _("已下移，请返回查看顺序"), timeout = 2,
            })
        end,
    })

    return items
end

function FanQiePlugin:showQingtianConfigDialog(touchmenu_instance)
    if not MultiInputDialog then
        self:showInfo(_("系统不支持多输入对话框"))
        return
    end
    local cfg = self.settings:get_source("qingtian")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("晴天聚合设置"),
        fields = {
            {
                description = _("服务器地址"),
                text = cfg.server_url or "",
                hint = "https://v1.gyks.cf/",
            },
            {
                description = _("账号（邮箱）"),
                text = cfg.username or "",
                hint = _("邮箱"),
            },
            {
                description = _("密码"),
                text = cfg.password or "",
                hint = _("密码"),
            },
        },
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        local server = H.trim(fields[1] or "")
                        local user = H.trim(fields[2] or "")
                        local pass = (fields[3] or "")
                        if server == "" then
                            self:showInfo(_("服务器地址不能为空"))
                            return
                        end
                        local new_cfg = self.settings:get_source("qingtian")
                        new_cfg.server_url = server
                        new_cfg.username = user
                        new_cfg.password = pass
                        -- 清除服务器检测缓存
                        new_cfg._detected_url = nil
                        new_cfg._detected_at = nil
                        -- Server/account changed -> clear token to force re-login
                        if new_cfg.token and new_cfg.token ~= "" then
                            new_cfg.token = ""
                            new_cfg.device_id = ""
                            local SM = require("fanqie.sources")
                            SM.rate_limit_reset("qingtian")
                        end
                        self.settings:set_source("qingtian", new_cfg)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("已保存，下次获取时自动登录"), timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanQiePlugin:showDahuilangConfigDialog(touchmenu_instance)
    if not MultiInputDialog then
        self:showInfo(_("系统不支持多输入对话框"))
        return
    end
    local cfg = self.settings:get_source("dahuilang")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("大灰狼聚合设置"),
        fields = {
            {
                description = _("服务器地址"),
                text = cfg.server_url or "",
                hint = "https://legado.gyks.cf/",
            },
            {
                description = _("邮箱"),
                text = cfg.username or "",
                hint = _("账号密码登录（与密钥二选一）"),
            },
            {
                description = _("密码"),
                text = cfg.password or "",
                hint = _("密码"),
            },
            {
                description = _("密钥 (可选)"),
                text = cfg.key or "",
                hint = _("密钥登录（优先于账号密码）"),
            },
            {
                description = _("原始书源"),
                text = cfg.source or "番茄",
                hint = _("番茄/七猫/塔读等"),
            },
        },
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存并登录"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        local server = H.trim(fields[1] or "")
                        local user = H.trim(fields[2] or "")
                        local pass = H.trim(fields[3] or "")
                        local key = H.trim(fields[4] or "")
                        local source = H.trim(fields[5] or "")

                        if server == "" then
                            self:showInfo(_("服务器地址不能为空"))
                            return
                        end

                        local new_cfg = self.settings:get_source("dahuilang")
                        local need_relogin = false

                        new_cfg.server_url = server
                        new_cfg.username = user
                        new_cfg.password = pass
                        new_cfg.key = key
                        new_cfg.source = source ~= "" and source or "番茄"
                        -- 清除服务器检测缓存
                        new_cfg._detected_url = nil
                        new_cfg._detected_at = nil

                        -- If login credentials changed, force re-login
                        if new_cfg.token and new_cfg.token ~= "" then
                            local old_token = new_cfg.token
                            -- Check if credentials changed
                            if user ~= (cfg.username or "") or pass ~= (cfg.password or "") or key ~= (cfg.key or "") or server ~= (cfg.server_url or "") then
                                new_cfg.token = ""
                                new_cfg.device_id = ""
                                need_relogin = true
                            end
                        end

                        self.settings:set_source("dahuilang", new_cfg)
                        local SM = require("fanqie.sources")
                        SM.rate_limit_reset("dahuilang")
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end

                        if need_relogin or new_cfg.token == "" then
                            -- Try to login immediately
                            if Client then
                                local ok_login, err = pcall(function()
                                    local c = Client:new(self.settings)
                                    c:dahuilang_login()
                                end)
                                if ok_login then
                                    UIManager:show(InfoMessage:new{
                                        text = _("大灰狼登录成功！"), timeout = 2,
                                    })
                                else
                                    UIManager:show(InfoMessage:new{
                                        text = _("登录失败: ") .. tostring(err), timeout = 3,
                                    })
                                end
                            end
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("大灰狼配置已保存"), timeout = 2,
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

function FanQiePlugin:showSourceRateLimitDialog(source_id, touchmenu_instance)
    if not InputDialog then
        self:showInfo(_("系统不支持输入对话框"))
        return
    end
    local cfg = self.settings:get_source(source_id)
    local rl = cfg.rate_limit or { max_requests = 0, window_seconds = 0 }
    local dialog
    dialog = InputDialog:new{
        title = _("限流设置"),
        input = tostring(rl.max_requests or 0),
        input_type = "number",
        description = _("格式: 最大请求数 / 时间窗口(秒)，0=无限制\n示例: 5/30 表示 30秒内最多5次"),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local input = dialog:getInputText() or ""
                        UIManager:close(dialog)
                        local mr_str, win_str = input:match("^(%d+)%s*/%s*(%d+)$")
                        if not mr_str then
                            mr_str = input:match("^(%d+)$")
                            win_str = tostring(rl.window_seconds or 30)
                        end
                        if not mr_str then
                            self:showInfo(_("格式错误"))
                            return
                        end
                        local mr = tonumber(mr_str) or 0
                        local win = (tonumber(win_str) or 30)
                        if win <= 0 then win = 30 end
                        if mr < 0 then
                            self:showInfo(_("数值不能为负"))
                            return
                        end
                        local new_cfg = self.settings:get_source(source_id)
                        new_cfg.rate_limit = { max_requests = mr, window_seconds = win }
                        self.settings:set_source(source_id, new_cfg)
                        -- Reset this source's rate-limit state so the new config
                        -- takes effect immediately (old timestamps cleared).
                        local SM = require("fanqie.sources")
                        SM.rate_limit_reset(source_id)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("限流设置已保存"), timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanQiePlugin:showServerDetectionDialog(source_id, touchmenu_instance)
    local cfg = self.settings:get_source(source_id)
    local servers = cfg.servers or {}
    local source_name = source_id == "dahuilang" and _("大灰狼") or _("晴天")
    
    if #servers == 0 then
        self:showInfo(source_name .. _("服务器列表为空，请先在配置中添加服务器地址"))
        return
    end
    
    -- Show loading message
    UIManager:show(InfoMessage:new{
        text = source_name .. _("正在检测服务器..."),
        timeout = 1,
    })
    
    -- Run detection asynchronously
    UIManager:scheduleIn(0.3, function()
        local client = Client and Client:new(self.settings)
        if not client then
            self:showInfo(_("客户端初始化失败"))
            return
        end
        
        local results = {}
        local available_count = 0
        
        for _, url in ipairs(servers) do
            local ok, available, code = pcall(function()
                return client:check_single_server(url)
            end)
            if ok and available then
                table.insert(results, { url = url, available = true, code = code })
                available_count = available_count + 1
            else
                table.insert(results, { url = url, available = false, code = code or 0 })
            end
        end
        
        -- Build result text
        local result_lines = {}
        table.insert(result_lines, string.format(_("检测完成: %d/%d 可用"), available_count, #servers))
        table.insert(result_lines, "")
        
        for i, r in ipairs(results) do
            local status = r.available and "✓" or "✗"
            local short_url = r.url:gsub("^https?://", "")
            table.insert(result_lines, string.format("%s %s [%s]", status, short_url, r.available and _("可用") or _("不可用")))
        end
        
        local result_text = table.concat(result_lines, "\n")
        
        -- Show results with selection
        local MultiInputDialog = require("ui/widget/multiinputdialog")
        if not MultiInputDialog then
            -- Simple info dialog
            self:showInfo(result_text)
            return
        end
        
        local dialog
        dialog = MultiInputDialog:new{
            title = source_name .. _("线路检测结果"),
            fields = {
                {
                    description = _("检测结果"),
                    text = result_text,
                    readonly = true,
                    text_type = "multi-line",
                },
                {
                    description = _("选择可用服务器 (输入序号)"),
                    text = available_count > 0 and "1" or "",
                    hint = _("填入要使用的服务器序号 (1, 2, 3...)"),
                },
            },
            buttons = {
                {
                    {
                        text = _("关闭"),
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text = _("使用选中线路"),
                        is_enter_default = true,
                        enabled_func = function() return available_count > 0 end,
                        callback = function()
                            local fields = dialog:getFields()
                            UIManager:close(dialog)
                            local idx = tonumber(H.trim(fields[2] or ""))
                            if idx and idx >= 1 and idx <= #results and results[idx].available then
                                local new_cfg = self.settings:get_source(source_id)
                                new_cfg.server_url = results[idx].url
                                -- Clear token since server changed
                                new_cfg.token = ""
                                new_cfg.device_id = ""
                                -- Clear cached detection
                                new_cfg._detected_url = nil
                                new_cfg._detected_at = nil
                                self.settings:set_source(source_id, new_cfg)
                                self.settings:flush()
                                local SM = require("fanqie.sources")
                                SM.rate_limit_reset(source_id)
                                if touchmenu_instance then
                                    touchmenu_instance:updateItems()
                                end
                                local short = results[idx].url:gsub("^https?://", "")
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("已切换到: %s"), short),
                                    timeout = 2,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("无效的序号或该线路不可用"),
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
    end)
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
                -- Copy log to a temp location for safe viewing
                local tmp_dir = DataStorage:getDataDir() .. "/tmp"
                H.make_dir(tmp_dir)
                local tmp_path = tmp_dir .. "/fanqie_log_viewer.txt"
                local src = io.open(log_path, "r")
                if not src then
                    self:showInfo(_("无法读取日志文件"))
                    return
                end
                local content = src:read("*a")
                src:close()
                if #content > 20000 then
                    content = content:sub(-20000)
                end
                local dst = io.open(tmp_path, "w")
                if not dst then
                    self:showInfo(_("无法写入临时文件"))
                    return
                end
                dst:write(content)
                dst:close()
                -- Open with file manager / text viewer
                local FileManager = safe_require("ui/filemanager")
                if FileManager then
                    local fm = FileManager:new{
                        dimen = Screen:getDeviceScreenSize(),
                        covers_fullscreen = true,
                    }
                    -- Navigate to temp dir and open the file
                    -- Simpler approach: show in text viewer
                    local TextViewer = safe_require("ui/widget/textviewer")
                    if TextViewer then
                        UIManager:show(TextViewer:new{
                            title = _("FanQie 插件日志"),
                            text = content,
                        })
                    else
                        self:showInfo(_("日志已复制到: %1", tmp_path))
                    end
                else
                    self:showInfo(_("日志已复制到: %1", tmp_path))
                end
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

function FanQiePlugin:loadConfigFile(silent, force)
    local plugin_path = self:getPluginPath()
    local config_path = plugin_path .. "/config.lua"
    
    local file = io.open(config_path, "r")
    if not file then return end
    file:close()
    
    local ok, config = pcall(dofile, config_path)
    if not ok or type(config) ~= "table" then return end
    
    pcall(function()
        self.settings:apply_config(config, { apply_preferences = true, force = force })
    end)
    
    if not silent then
        UIManager:show(InfoMessage:new{
            text = _("config.lua loaded."), timeout = 2,
        })
    end
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

function FanQiePlugin:showChapterListing(book, opts)
    opts = opts or {}
    local force_refresh = opts.force_refresh == true
    -- remember_page: keep the user on the same page after a refresh
    local remember_page = opts.remember_page

    -- Try persistent catalog cache first (so we don't hit the network every time)
    local chapters = nil
    if not force_refresh then
        chapters = Content.load_catalog_cache(self.settings, book.book_id)
        if chapters and #chapters > 0 then
            Log.debug("showChapterListing: using cached catalog, count =", #chapters)
        else
            chapters = nil
        end
    end

    -- No cache (or forced refresh): fetch from server
    if not chapters or force_refresh then
        if not self:checkNetwork() then return end
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

        -- Persist to disk so we don't re-fetch next time
        Content.save_catalog_cache(self.settings, book.book_id, chapters)
        -- Also update in-memory cache
        _state.cached_directory = _state.cached_directory or {}
        _state.cached_directory[book.book_id] = {
            chapters = chapters,
            timestamp = os.time(),
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

    if book.item_id then
        for i, chapter in ipairs(chapters) do
            if tostring(chapter.itemId) == tostring(book.item_id) then
                current_idx = i
                break
            end
        end
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

    local items_per_page = 12
    local initial_page = remember_page or 1

    if not remember_page and current_idx > 0 then
        items.current = current_idx
        initial_page = math.ceil(current_idx / items_per_page)
    end

    local plugin = self
    local chapter_menu = Menu:new{
        title = string.format("%s - 目录", book.title or book.book_id),
        item_table = items,
        items_per_page = items_per_page,
        is_borderless = true,
        is_popout = false,
        title_bar_left_icon = "appbar.menu",
        close_callback = function()
            if _state.active_menu == chapter_menu then
                _state.active_menu = nil
            end
        end,
    }

    -- Wire up the title-bar left icon to open a small action menu.
    -- This icon is visible on every page of the chapter list, so the user
    -- can refresh from wherever they currently are.
    chapter_menu.onLeftButtonTap = function()
        local current_page = chapter_menu.page or 1
        local ButtonDialog = require("ui/widget/buttondialog")
        local action_dialog
        action_dialog = ButtonDialog:new{
            title = _("目录操作"),
            title_align = "center",
            buttons = {
                {{
                    text = _("刷新目录"),
                    callback = function()
                        UIManager:close(action_dialog)
                        UIManager:close(chapter_menu)
                        _state.active_menu = nil
                        -- Re-open and stay on the same page after refresh
                        plugin:showChapterListing(book, {
                            force_refresh = true,
                            remember_page = current_page,
                        })
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

    if initial_page > 1 then
        chapter_menu:onGotoPage(initial_page)
    end

    _state.active_menu = chapter_menu
    UIManager:show(chapter_menu)

    if force_refresh and not opts.silent then
        self:showInfo(_("目录已刷新"))
    end
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

    -- 从全局状态获取段评开关，传递 review=true 给内容获取
    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = review_enabled and { review = true } or nil

    local item_id = tostring(chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]

    -- 段评开启时，如果缓存的章节没有段评数据，需要重新获取
    if existing_path and review_enabled then
        local existing_reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
        if #existing_reviews == 0 then
            existing_path = nil  -- 没有段评数据，需要重新获取
        end
    end

    -- If not found in cache index, try to find file directly from filesystem
    if not existing_path or not H.file_exists(existing_path) then
        local found_path = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found_path then
            -- Update cache index with found file
            cached_chapters[item_id] = found_path
            Content.save_cache_index(self.settings, book.book_id, cached_chapters)
            existing_path = found_path
            if Log then Log.info("found cached chapter in filesystem:", item_id) end
        end
    end

    if existing_path and H.file_exists(existing_path) then
        _state.current_chapter_index = chapter_index
        _state.pre_download_triggered = false
        -- 加载段评数据到全局状态
        if review_enabled then
            local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            _state.setCurrentParaReviews(reviews)
        end
        self:showReaderUI(existing_path, chapter)
        if opts.after_navigate then
            UIManager:scheduleIn(1.0, opts.after_navigate)
        end
        return true
    end

    _state.is_downloading = true
    self:showBusy(T(_("正在下载: %s"), chapter.title or ""))

    UIManager:scheduleIn(0.1, function()
        local ok, result = pcall(function()
            local b = { book_id = book.book_id, title = book.title, author = book.author }
            -- 传递 fetch_opts（含 review=true）以启用段评模式
            local path, ch, para_reviews = Content.fetch_chapter_html(self.client, self.settings, b, chapter, fetch_opts)
            return { path = path, para_reviews = para_reviews }
        end)
        self:closeBusy()

        if not ok then
            Log.error("navigateToChapter download failed:", tostring(result))
            _state.is_downloading = false
            self:showError(T(_(opts.error_message or "下载章节失败:\n%1"), display_error(result)))
            return
        end

        local path = result.path
        local para_reviews = result.para_reviews

        local cached_chapters = getCachedChapters(self, book)
        cached_chapters[item_id] = path

        -- 存储段评数据到全局状态
        if review_enabled and para_reviews then
            _state.setCurrentParaReviews(para_reviews)
        end

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
    _state.document_opened = true
    
    if _state.current_book then
        UIManager:scheduleIn(1.0, function()
            if _state.current_book then
                getCachedChapters(self, _state.current_book)
            end
        end)
    end
end

-- Reload current chapter: delete cached file and re-download
function FanQiePlugin:reloadCurrentChapter()
    local book = _state.current_book
    local chapters = _state.current_chapters
    local current_idx = _state.current_chapter_index
    
    if not book or not chapters or not current_idx then
        self:showInfo(_("没有可重新获取的章节"))
        return
    end
    
    local chapter = chapters[current_idx]
    if not chapter then return end
    
    local item_id = tostring(chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]
    
    -- Delete cached file if exists
    if existing_path and H.file_exists(existing_path) then
        os.remove(existing_path)
        if Log then Log.info("deleted cached chapter:", item_id) end
    end
    
    -- Also try to delete from expected location
    local expected_path = Content.book_cache_dir(self.settings, book.book_id) .. "/chapter_" .. item_id .. ".html"
    if H.file_exists(expected_path) then
        os.remove(expected_path)
        if Log then Log.info("deleted expected chapter file:", item_id) end
    end

    -- 删除段评数据索引文件，确保重新获取
    local para_reviews_path = Content.book_cache_dir(self.settings, book.book_id) .. "/para_reviews_" .. item_id .. ".lua"
    if H.file_exists(para_reviews_path) then
        os.remove(para_reviews_path)
        if Log then Log.info("deleted para_reviews index:", item_id) end
    end
    _state.clearParaReviews()

    -- Clear cache index entry
    cached_chapters[item_id] = nil
    Content.save_cache_index(self.settings, book.book_id, cached_chapters)
    
    -- Re-download
    self:navigateToChapter(book, chapters, current_idx, {
        error_message = "重新获取章节失败:\n%1",
    })
end

function FanQiePlugin:preDownloadChapters(book, chapters, current_index)
    local cache = self.settings:get("cache", {})
    local pre_download_count = cache.pre_download_chapters or 3
    local total = #chapters

    if current_index >= total then return end

    -- 段评模式：预下载也传递 review=true
    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = review_enabled and { review = true } or nil

    local cached_chapters = getCachedChapters(self, book)

    -- Recursive download: download one chapter, then yield to UI via scheduleIn(0)
    -- This prevents blocking the UI thread during multi-chapter pre-download
    local function download_one(offset)
        if _state.is_downloading then
            -- User is actively downloading a chapter; retry later
            UIManager:scheduleIn(1.0, function()
                download_one(offset)
            end)
            return
        end

        if offset > pre_download_count or current_index + offset > total then
            _state.pre_download_triggered = false
            Log.debug("pre-download: batch completed")
            return
        end

        local target_idx = current_index + offset
        local chapter = chapters[target_idx]
        local item_id = tostring(chapter.itemId)

        local already_cached = cached_chapters[item_id] and H.file_exists(cached_chapters[item_id])
        -- 段评开启时，还需检查是否有段评数据
        if already_cached and review_enabled then
            local existing_reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            if #existing_reviews == 0 then
                already_cached = false  -- 没有段评数据，需要重新获取
            end
        end

        if already_cached then
            Log.debug("pre-download: chapter", target_idx, "already cached")
        else
            Log.info("pre-download: starting download for chapter", target_idx)
            local ok, path = pcall(function()
                local b = { book_id = book.book_id, title = book.title, author = book.author }
                return Content.fetch_chapter_html(self.client, self.settings, b, chapter, fetch_opts)
            end)
            if ok then
                cached_chapters[item_id] = path
                Log.info("pre-download: completed chapter", target_idx)
            else
                Log.warn("pre-download: failed chapter", target_idx, ":", path)
            end
        end

        -- Yield to UI thread, then continue with next chapter
        UIManager:scheduleIn(0, function()
            download_one(offset + 1)
        end)
    end

    -- Delay start so user sees the current chapter first
    UIManager:scheduleIn(2.0, function()
        download_one(1)
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

    _state.last_page_number = pageno

    -- Only trigger pre-download after user has read past 50% of the chapter
    -- This avoids triggering immediately on chapter open for short chapters
    local progress = pageno / total_pages
    if progress > 0.5 and not _state.pre_download_triggered then
        _state.pre_download_triggered = true
        UIManager:scheduleIn(1.0, function()
            self:preDownloadChapters(_state.current_book, _state.current_chapters, _state.current_chapter_index)
        end)
    end

    if pageno % 10 == 0 then
        self:syncCurrentProgress()
    end
end

-- Handle "previous chapter" signal from patched ReaderPaging.
-- Triggered only when user presses "previous page" while on page 1.
function FanQiePlugin:onFanQiePrevChapter()
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

    _state.start_of_chapter_triggered = true

    local prev_idx = current_idx - 1
    local chapters = _state.current_chapters
    local book = _state.current_book
    local prev_chapter = chapters[prev_idx]
    if not prev_chapter then
        _state.start_of_chapter_triggered = false
        return true
    end

    local item_id = tostring(prev_chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]
    local path = existing_path

    -- 段评模式：检查缓存是否需要重新获取（无段评数据时）
    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = review_enabled and { review = true } or nil
    if existing_path and review_enabled then
        local existing_reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
        if #existing_reviews == 0 then
            existing_path = nil
            path = nil
        end
    end

    if not existing_path or not H.file_exists(existing_path) then
        -- Try to find file directly from filesystem
        local found_path = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found_path then
            cached_chapters[item_id] = found_path
            Content.save_cache_index(self.settings, book.book_id, cached_chapters)
            path = found_path
        else
            self:showBusy(T(_("正在下载: %s"), prev_chapter.title or ""))
            local ok, result = pcall(function()
                local b = { book_id = book.book_id, title = book.title, author = book.author }
                return Content.fetch_chapter_html(self.client, self.settings, b, prev_chapter, fetch_opts)
            end)
            self:closeBusy()

            if not ok then
                Log.error("onFanQiePrevChapter download failed:", tostring(result))
                _state.start_of_chapter_triggered = false
                self:showError(T(_("加载上一章失败:\n%1"), display_error(result)))
                return true
            end

            path = result
            cached_chapters[item_id] = path
        end
    end

    -- 加载段评数据
    if review_enabled then
        local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
        _state.setCurrentParaReviews(reviews)
    end

    _state.current_chapter_index = prev_idx
    _state.pre_download_triggered = false
    _state.last_page_number = nil
    self:showReaderUI(path, prev_chapter)

    UIManager:scheduleIn(1.0, function()
        _state.start_of_chapter_triggered = false
        self:syncCurrentProgress()
        self:preDownloadChapters(book, chapters, prev_idx)
        self:retryPendingProgress()
    end)
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

    -- 同步处理下一章切换，避免返回后 KOReader 关闭文档
    local item_id = tostring(next_chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]
    local path = existing_path

    -- 段评模式：检查缓存是否需要重新获取（无段评数据时）
    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = review_enabled and { review = true } or nil
    if existing_path and review_enabled then
        local existing_reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
        if #existing_reviews == 0 then
            existing_path = nil
            path = nil
        end
    end

    if not existing_path or not H.file_exists(existing_path) then
        self:showBusy(T(_("正在下载: %s"), next_chapter.title or ""))
        local ok, result = pcall(function()
            local b = { book_id = book.book_id, title = book.title, author = book.author }
            return Content.fetch_chapter_html(self.client, self.settings, b, next_chapter, fetch_opts)
        end)
        self:closeBusy()

        if not ok then
            Log.error("onEndOfBook download failed:", tostring(result))
            self:showError(T(_("加载下一章失败:\n%1"), display_error(result)))
            return true
        end

        path = result
        cached_chapters[item_id] = path
    end

    -- 加载段评数据
    if review_enabled then
        local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
        _state.setCurrentParaReviews(reviews)
    end

    _state.current_chapter_index = next_idx
    _state.pre_download_triggered = false
    self:showReaderUI(path, next_chapter)

    UIManager:scheduleIn(1.0, function()
        self:preDownloadChapters(book, chapters, next_idx)
        self:retryPendingProgress()
    end)

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
    _state.last_page_number = nil
    _state.document_opened = false
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
    -- Reuse showChapterListing so the reader-side TOC also gets the
    -- persistent catalog cache and the refresh button.
    self:showChapterListing(_state.current_book)
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
            -- 段评模式：批量下载也传递 review=true
            local review_enabled = _state.isReviewEnabled()
            local fetch_opts = review_enabled and { review = true } or nil
            return Content.fetch_chapter_html(self.client, self.settings, b, chapter, fetch_opts)
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
