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

-- 段评图片查看器（KOReader 自带，支持缩放/拖动；纯文本 TextViewer 画不了图）
local ImageViewer = safe_require("ui/widget/imageviewer")

-- 段评视图（可滚动 + 图片内嵌 + 回复一键展开，见 fanqie/comment_view.lua）。
-- 加载失败时 _renderParaReviewView 会退回纯文本 TextViewer 渲染。
local CommentView = safe_require("fanqie.comment_view")

-- 书籍详情（书架/详情/进度三接口合并 + 纯函数格式化，见 fanqie/book_detail.lua）
local BookDetail = safe_require("fanqie.book_detail")

-- 封面缓存的有效期 / 占用 / 清理（见 fanqie/cover_cache.lua）
local CoverCache = safe_require("fanqie.cover_cache")

local PathChooser = safe_require("ui/widget/pathchooser")

local Event = safe_require("ui/event")

local GestureRange = safe_require("ui/gesturerange")

local logger = safe_require("logger")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or nil

local util = safe_require("util")

-- Screen 实例：KOReader **不提供** Screen 全局，必须自己从 device 取。
-- 此前 main.lua 里两处 `Screen:xxx()` 是裸全局引用（Screen 从未定义），
-- 一旦走到那些分支就会 "attempt to index global 'Screen' (a nil value)"。
local Device = safe_require("device")
local Screen = Device and Device.screen

-- Local libs
local Settings = safe_require("fanqie.settings")

local Client = safe_require("fanqie.client")

local H = safe_require("fanqie.helper")

local Content = safe_require("fanqie.content")

local DownloadProgress = safe_require("fanqie.download_progress")

local FanQie = safe_require("fanqie.fanqie")

local Log = safe_require("fanqie.logger")

-- 日志模块加载失败时用 no-op 兜底表，调用点无需逐个 `if Log` 保护。
-- 历史上有 22 处直接 `Log.xxx(...)`（未加 guard），logger 缺失时会二次崩溃拖垮整个插件。
if not Log then
    local function _noop() end
    Log = {
        init = _noop,
        debug = _noop,
        info = _noop,
        warn = _noop,
        error = _noop,
        clear_log = _noop,
        is_debug_enabled = function() return false end,
        get_log_file_path = function() return nil end,
    }
end

local Patches = safe_require("patches.core")

local Bookshelf = safe_require("fanqie.bookshelf")

-- 书城（fanqienovel.com 网页接口）：编排层，以白名单 mixin 方式挂到本类上
local StoreUI = safe_require("fanqie.store_ui")

-- 书城数据层：阅读界面的「加入/移出书架」要直接用 Store.shelf_check / shelf_add /
-- shelf_remove（这三个是书城与阅读界面共用的书架口径，别各写一份）。
local Store = safe_require("fanqie.store")

-- 插件元信息（版本号、关于文案）：集中管理，避免多处维护不同步
local Info = safe_require("fanqie.info")

-- 异步子进程模块：把进度上传 / 预下载等阻塞网络操作移出 UI 线程，消除卡顿。
local Async = safe_require("fanqie.async")

-- 在线更新（自更新）：启动自检 + 静默自动检查 + 菜单入口
local UpdaterUI = safe_require("fanqie.updater_ui")

local unpack_args = unpack or table.unpack

-- 墙钟计时（秒）：os.clock() 返回的是 CPU 时间，父进程空转等子进程时几乎不累加，
-- 用它算「耗时」会严重偏低并误导排查。与 download.lua 的 now_ms() 同源（socket.gettime）。
local ok_socket, socket = pcall(require, "socket")
local function now_seconds()
    if ok_socket and socket and socket.gettime then
        return socket.gettime()
    end
    return os.clock()
end

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

--- 章内进度回调工厂（给 Async.run 的 `on_heartbeat`）。
--- 图集/漫画一章就是几十页整页大图、整章几分钟，而 showBusy 只写一句静态文案
--- 且**没有任何进度**：用户分不清「在下」还是「卡死」。这里按心跳把页码显示出来。
--- text 格式见 fanqie/content.lua 的 heartbeat："尝试/总数[/失败数]"。
--- 节流：每次更新都要重建 InfoMessage（close + show + forceRePaint，墨水屏会闪），
--- 所以只在跨过约 1/5 的页数台阶时更新。
--- @param plugin table   FanQiePlugin 实例（用它的 showBusy）
--- @param chapter table  当前章节（取标题）
--- @param is_comic boolean  仅图集/漫画才值得显示（文字章没有几十页图片）
--- @return function|nil
local function make_page_heartbeat(plugin, chapter, is_comic)
    if not is_comic or not plugin then return nil end
    local title = (chapter and chapter.title) or ""
    local last_shown = 0
    return function(text)
        local done_s, total_s, failed_s = tostring(text):match("^(%d+)/(%d+)/?(%d*)$")
        local done, total = tonumber(done_s), tonumber(total_s)
        if not (done and total and total > 0) then return end
        local failed = tonumber(failed_s) or 0
        local step = math.max(1, math.floor(total / 5))
        if done < total and done - last_shown < step then return end
        last_shown = done
        local msg = T(_("正在下载图集: %1\n（第 %2/%3 页）"), title, done, total)
        if failed > 0 then
            msg = msg .. T(_("（失败 %1 页）"), failed)
        end
        plugin:showBusy(msg)
    end
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
    _state.chapter_navigating = false
    function _state.setChapterNavigating(v) _state.chapter_navigating = v == true end
    function _state.isChapterNavigating() return _state.chapter_navigating == true end
    -- 书架状态快照：真模块里由 bookshelf / store_ui 维护。回退态下没有数据源，
    -- 一律回「未知」（nil）—— 调用方本来就必须处理 nil（文案走乐观兜底、
    -- 退出提示静默跳过），所以这里的降级是安全的。
    _state.shelf_all = nil
    _state.shelf_known = {}
    _state.shelf_prompted = {}
    function _state.setShelfAll() _state.shelf_all = nil end
    function _state.clearShelfAll() _state.shelf_all = nil end
    function _state.markShelf() end
    function _state.shelfState() return nil end
    -- 「到达文档末尾时的操作」原值备份：回退态下同样只是普通字段，不需要额外接口。
    _state.end_document_action_backup = nil
end

local function getCurrentChapterIndex()
    return _state.current_chapter_index or 0
end

-- 形参故意不叫 self：本文件里只要出现 `local function f(self)`，
-- 静态检查（lua_self_method_check）就会判定「self 被重绑定」而静默跳过**整个 main.lua**，
-- 等于把 self:方法 的存在性检查关掉。改用 plugin 之后检查恢复生效。
local function getCachedChapters(plugin, book)
    if not book then
        return {}
    end
    if not book.cached_chapters then
        book.cached_chapters = Content.load_cache_index(plugin.settings, book.book_id) or {}
    end
    return book.cached_chapters
end

local FanQiePlugin = WidgetContainer:extend{
    name = "fanqie",
    is_doc_only = false,
    fullname = "FanQie",
    version = Info and Info.version or "2.16.6",
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

--- KOReader 的全局阅读设置对象（不存在时返回 nil）。
--
-- `G_reader_settings` 是 KOReader 的全局变量，正常情况下一定存在；但
-- **回归 harness 里没有它**（也拿不到真对象）。所有用到它的地方都必须
-- 走这个取用口，缺了就静默降级 —— 否则一个可选能力会把阅读界面拖崩。
function FanQiePlugin:_readerSettings()
    local ok, rs = pcall(function() return G_reader_settings end)
    if ok and rs and type(rs.readSetting) == "function" then
        return rs
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- 「到达文档末尾时的操作」：读番茄章节时改成「什么都不做」（v2.17.0）
-- ---------------------------------------------------------------------------
-- 背景：番茄小说**一章就是一个 html 文件**（`content.lua` 的
-- `chapter_<item_id>.html`），在 KOReader 眼里「读完一章」就等于
-- 「读完一本书」。于是读到最后一页**再往后翻**时（判据在
-- `readerrolling.lua:914/928`：`diff > 0 and old_page == self.current_page`），
-- 会派发 `EndOfBook`，而 `ReaderStatus:onEndOfBook` 按**全局设置**
-- `end_document_action`（默认 `"pop-up"`）弹一个「已到文档末尾」的按钮框。
-- 那个框和本插件自己的「自动下一章」是两套东西，一起出现就是打扰。
--
-- 🔴 为什么是「改设置」而不是「插件抢事件」：
--    `WidgetContainer:propagateEvent` 是**正序**遍历
--    （`widgetcontainer.lua:82` `for _, widget in ipairs(self)`，第一个返回 true 的
--    就把事件截住），而 `ReaderStatus` 在 `readerui.lua:416` 就注册了，插件远在其后
--    ⇒ KOReader 的那个对话框**永远先于**插件的 `onEndOfBook` 执行。想让它不发生，
--    只能让 `ReaderStatus` 自己「什么都不做」。
--
-- ✅ 为什么选 `"nothing"` 这个值最合适：
--    `ReaderStatus:onEndOfBook` 的 if/elseif 链里**没有 `"nothing"` 分支**
--    （`readerstatus.lua:126-166` 只有 pop-up / book_status / next_file /
--    goto_beginning / file_browser / mark_read / …），所以它什么也不做，
--    并且**不返回值**（nil）⇒ 事件继续传播 ⇒ 插件的 `onEndOfBook`
--    （进度置 1.0 + 自动下一章）一切照旧，只是不再有那个框。
--
-- 生效范围：**只覆盖打开番茄章节的这段时间**，离开时还原（见各函数的注释）。
function FanQiePlugin:_muteEndDocumentAction()
    if not self:isCurrentDocFanqie() then return end
    local rs = self:_readerSettings()
    if not rs then return end
    local cur = rs:readSetting("end_document_action")
    if _state.end_document_action_backup == nil then
        -- 只在**第一次**覆盖时记原值：切章会走一遍「还原 → 再覆盖」，
        -- 若每次都记，第二次记下的就是我们自己写的 "nothing"，原值就丢了。
        -- ⚠️ 用 `false` 表示「原本没设过」（KOReader 的默认即「弹窗询问」）——
        --    不能和 nil（= 还没覆盖过）混用，否则永远不会还原。
        -- 🔴 别写成 `(cur == nil) and false or cur`：Lua 的 `and/or` 在中间值为
        --    **false** 时会落到最后一个操作数 ⇒ 表达式退化成 `cur`（= nil），
        --    「原本没设过」又变回「还没覆盖过」，L1b/L5 就是这么红的。
        if cur == nil then
            _state.end_document_action_backup = false
        else
            _state.end_document_action_backup = cur
        end
    end
    if cur ~= "nothing" then
        rs:saveSetting("end_document_action", "nothing")
    end
end

--- 还原「到达文档末尾时的操作」。没覆盖过时是空转。
function FanQiePlugin:_restoreEndDocumentAction()
    local backup = _state.end_document_action_backup
    if backup == nil then return end
    _state.end_document_action_backup = nil
    local rs = self:_readerSettings()
    if not rs then return end
    -- ⚠️ 只还原「仍然是我们写的那个值」的情况：用户在阅读番茄小说的过程中
    --    自己去设置里改过（比如就是想要那个框），那就尊重用户的选择。
    if rs:readSetting("end_document_action") ~= "nothing" then return end
    -- 🔴 同样别写成 `backup == false and nil or backup`：中间值是 nil 时整个
    --    表达式落到最后一项 ⇒ 会把 `false` 写回去（LuaSettings 里就成了一个
    --    真值为 false 的键，而不是「没设过」）。L5 就是这条。
    if backup == false then
        rs:saveSetting("end_document_action", nil)  -- 删键 = 回到 KOReader 默认
    else
        rs:saveSetting("end_document_action", backup)
    end
end

--- KOReader 每次打开文档都会广播 `ReaderReady`（`readerui.lua:517`），
--- 这是「文档已就绪」的统一挂载点：插件自己打开章节（showReaderUI）和
--- 用户从「最近阅读 / 文件管理器」直接打开章节 html 都会经过这里。
--- ⚠️ 返回 nil（不消费事件）：别把 ReaderReady 从别的模块手里截走。
function FanQiePlugin:onReaderReady()
    local ok, err = pcall(function() self:_muteEndDocumentAction() end)
    if not ok and Log and Log.error then
        Log.error("mute end_document_action failed:", tostring(err))
    end
end

--- 当前正在读的番茄书。
--
-- 优先内存里的 `_state.current_book`；没有时（重启后从「最近阅读 / 文件管理器」
-- 直接打开章节续读）从文档路径反推书号，返回一条**最小记录** `{ book_id = ... }`。
--
-- 🔴 `_state.current_book` 不持久化，只有 openBook / openChapter /
--    showChapterListing 会赋值 ⇒ 这条回退是阅读界面「加入/移出书架」在
--    重启续读场景下唯一的书号来源。返回值只保证有 book_id（toggleStoreShelf
--    也只用 book_id），所以标题缺失时确认框文案会退化成「未知」，这是可接受的。
function FanQiePlugin:getCurrentBook()
    local cached = _state.current_book
    if type(cached) == "table" and cached.book_id then
        return cached
    end
    if not (self.ui and self.ui.document) then return nil end
    local path = self.ui.document.file or self.ui.document.path
    if not path or type(_state.book_id_from_path) ~= "function" then return nil end
    local book_id = _state.book_id_from_path(path)
    if not book_id then return nil end
    -- 反查校验：路径前缀必须正是这本书的缓存目录
    if Content and Content.book_cache_dir then
        local dir = Content.book_cache_dir(self.settings, book_id)
        if not dir or path:sub(1, #dir) ~= dir then return nil end
    end
    return { book_id = book_id }
end

--- 当前这本书「在不在书架」的**同步**判断。
-- @return true=在架 / false=不在架 / nil=未知
-- 🔴 为什么必须同步：菜单项文案由 `Menu.getMenuText` 在每次重绘时同步求值，
--    不可能等一次网络往返。所以判据只能是 `_state` 的书架快照（见 state.lua）。
--    快照缺数据（冷启动、从没读过书架列表）时**不要**退化成联网去查 ——
--    那会把菜单打开拖成一个网络等待。返回 nil，由调用方决定兜底文案。
function FanQiePlugin:isCurrentBookOnShelf()
    if not (_state and type(_state.shelfState) == "function") then return nil end
    local book = self:getCurrentBook()
    if type(book) ~= "table" or not book.book_id then return nil end
    return _state.shelfState(book.book_id)
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
    -- 自更新链路永远不能让插件本体变哑：任何抛错都只吞进日志。
    -- UI.startup 内部有进程级去重（KOReader 会为 FileManager / 每个 ReaderUI 各建实例）。
    if UpdaterUI and UpdaterUI.startup then
        pcall(function() UpdaterUI.startup(self) end)
    end
end

function FanQiePlugin:displayError(err)
    return display_error(err)
end

-- mixin 只做「白名单显式拷贝」：main.lua 未定义的模块方法才需要搬进来。
-- 以前用 pairs() 全量拷贝，而 main.lua 在下方又重定义了同名方法 → 模块侧那些实现
-- 永不执行（其中还夹着同步阻塞版），是「改了模块却不生效」的维护陷阱。
-- ⚠️ 模块里新增公共方法，必须在此登记，否则不会被拷贝（reader_navigation.lua 已整体移除）。
local BOOKSHELF_MIXIN = {
    "clearShelfCache", -- 三层清缓存（显示层内存 / client API 短缓存 / 文件）
    "showBookshelf",   -- 书架入口（异步拉取 + 缓存回退 + 后台刷新）
    "get_shelf",       -- 拉取书架列表并归一化（子进程内执行）
    "ensureShelfSnapshot", -- 同步补齐「书架状态快照」（纯本地文件，绝不联网）
    "findCachedBook",  -- 从本地书架缓存按书号取完整记录（阅读端「书籍信息」补全用）
}
if Bookshelf then
    for _, name in ipairs(BOOKSHELF_MIXIN) do
        FanQiePlugin[name] = Bookshelf[name]
    end
end

-- 书城入口的名字一律登记在这里；模块内部辅助函数是 local，不需要登记。
local STORE_MIXIN = {
    "showStore",             -- 书城根菜单（分类浏览 / 排行榜 / 搜索）
    "showStoreBrowser",      -- 分类浏览（男频/女频 → 分类分组 → 分类 → 书籍列表）
    "showStoreRanks",        -- 排行榜（最近更新 / 推荐榜）
    "showStoreSearch",       -- 搜索（输入框 → 结果列表）
    "showStoreBookDetail",   -- 书城书籍详情（加入/移出书架、阅读、目录、下载）
    "toggleStoreShelf",      -- 加入 / 移出书架（异步）
}
if StoreUI then
    for _, name in ipairs(STORE_MIXIN) do
        FanQiePlugin[name] = StoreUI[name]
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
    -- 🔴 这里**不能**再卡 `_state.current_book`：它不持久化，重启后从
    --    「最近阅读 / 文件管理器」直接打开章节续读时是 nil，而
    --    `isCurrentDocFanqie()`（看路径里有没有 /fanqie/）仍然为真 ——
    --    多卡一个条件会让整个阅读端菜单（含「加入/移出书架」）凭空消失。
    if self.ui.document and self:isCurrentDocFanqie() then
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
                        text = _("书城"),
                        callback = self:safeCallback(_("书城"), function()
                            self:showStore()
                        end),
                    },
                    {
                        -- 阅读界面里「我在读的是什么」的入口（v2.17.0）。
                        -- 判据与「加入/移出书架」「目录」同源：优先内存里的
                        -- _state.current_book，没有就从文档路径反推 + 本地书架缓存补全
                        -- （重启续读场景），全程零网络。详见 showCurrentBookInfo。
                        text = _("书籍信息"),
                        callback = self:safeCallback(_("书籍信息"), function()
                            self:showCurrentBookInfo()
                        end),
                    },
                    {
                        text = _("目录"),
                        callback = self:safeCallback(_("目录"), function()
                            -- onShowFanQieToc 需要 current_book + 章节表（都在内存里）；
                            -- 重启续读时两者皆无，事件发出去没人接 ⇒ 显式提示比静默好。
                            if not (_state.current_book and _state.current_chapters) then
                                self:showInfo(_("请先从书架或书城打开这本书"))
                                return
                            end
                            self.ui:handleEvent(Event:new("ShowFanQieToc"))
                        end),
                    },
                    {
                        text = _("下载"),
                        callback = self:safeCallback(_("下载"), function()
                            local book = _state.current_book
                            if not book then self:showInfo(_("无书籍信息")); return end
                            local chapters = _state.current_chapters
                            if not chapters or #chapters == 0 then
                                -- 子进程获取目录，UI 线程保持响应
                                self:showBusy(_("正在获取目录..."))
                                local client = self.client
                                local book_id = book.book_id
                                Async.run(function()
                                    local b = { book_id = book_id }
                                    return Content.fetch_catalog(client, b)
                                end, function(ok_cat, result, err)
                                    self:closeBusy()
                                    if not ok_cat or type(result) ~= "table" or #result == 0 then
                                        self:showInfo(_("获取目录失败"))
                                        return
                                    end
                                    _state.current_chapters = result
                                    local Download = require("fanqie.download")
                                    Download.showOptionsDialog(self, book, result,
                                        { current_index = _state.current_chapter_index })
                                end, { poll_interval = 0.3, timeout = 60 })
                                return
                            end
                            local Download = require("fanqie.download")
                            Download.showOptionsDialog(self, book, chapters,
                                { current_index = _state.current_chapter_index })
                        end),
                    },
                    {
                        -- 阅读界面直接管理当前这本书的书架状态（v2.12.0）。
                        -- 🔴 文案按**实际书架状态**给（v2.16.0）。以前一律写
                        --    「加入/移出书架」，等于把两个方向摆在一起让用户自己猜 ——
                        --    在架的书该显示「移出书架」、不在架的该显示「加入书架」。
                        --    判据是 `_state` 的书架快照（纯内存 O(1)，见 state.lua），
                        --    在 `text_func` 里**同步**求值：koreader 的
                        --    `Menu.getMenuText` 每次 `updateItems` 都会调用它
                        --    ⇒ 菜单一打开，方向就是对的。
                        -- 未知（冷启动且本地没有书架缓存）时乐观显示「加入书架」：
                        --    加入是可逆的，而「移出书架」是破坏性动作 —— 宁可猜前者。
                        --    （点击后 `toggleCurrentBookShelf` 仍会先 shelf_check 复核，
                        --      所以即便猜错也不会做错事，只是文案多一次翻转。）
                        text_func = function()
                            if self:isCurrentBookOnShelf() == true then
                                return _("移出书架")
                            end
                            return _("加入书架")
                        end,
                        callback = self:safeCallback(_("加入/移出书架"), function()
                            self:toggleCurrentBookShelf()
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
                        text = _("在线更新"),
                        sub_item_table_func = function()
                            return self:getUpdateMenuItems()
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
                            self:showInfo(T(Info and Info.about_template or _("番茄小说插件 v%1"), self.version, self.settings:get_download_dir()))
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
-- 段评
-- ===========================================================================
-- 段评开关已移至「设置」页面（getSettingsMenuItems 中的"段评显示"），
-- 阅读时点击「重新获取本章节」会根据开关状态决定是否带段评获取正文。

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

-- 显示单段段评详情（从API获取评论数据，每页 PARA_REVIEW_PAGE_SIZE 条 + cursor 分页）
-- 段评统一走官方 App commentapi 协议（ident 格式 fqapp://book_id/item_id/para_index，
-- 由 client.lua official_get_content 注入气泡时生成）。
-- opts.page：段评列表页码（缺省 1）。
-- 翻页说明：commentapi 的 cursor 只能前向翻页，已取回的页缓存在
-- self._para_pages[ident]（父进程），回翻零请求；缺页时在子进程内用
-- cursor 链顺序补拉（每页一次请求），取回后在父进程回调里合并缓存。
-- ⚠️ 缓存合并必须在父进程回调里做：子进程内的 table 改动不会传回。
local PARA_REVIEW_PAGE_SIZE = 10

function FanQiePlugin:showParaReviewDetail(index, opts)
    opts = opts or {}
    local page = math.max(1, math.floor(tonumber(opts.page) or 1))
    local reviews = _state.getCurrentParaReviews()
    local pr = reviews[index]
    if not pr or not pr.ident then
        self:showInfo(_("段评数据无效"))
        return
    end

    local self_ref = self
    local ident = pr.ident
    local review_index = index
    local total_reviews = #reviews
    -- 气泡上显示的服务端统计条数：列表请求失败/为空时用它兜底提示，
    -- 避免把「请求失败」显示成「共 0 条评论」（对齐 kindle-forge 前端的
    -- `if (!total) total = list.length || count` 回退）。
    local bubble_count = tonumber(pr.count) or 0

    -- 每个 ident 一份页缓存：pages[q]=该页评论列表、infos[q]=分页信息、cursors[q]=进第 q 页用的 cursor
    self._para_pages = self._para_pages or {}
    local cache = self._para_pages[ident]
    if not cache then
        cache = { pages = {}, infos = {}, cursors = { [1] = "" } }
        self._para_pages[ident] = cache
    end

    -- 翻页链已断（服务端末页）时收缩目标页到最近可达页
    local p = page - 1
    while p >= 1 and not cache.pages[p] do
        p = p - 1
    end
    if p >= 1 and cache.cursors[p + 1] == nil then
        page = p
    end

    -- 已取回的页直接渲染（回翻零网络请求）
    if cache.pages[page] then
        self_ref:_displayParaReviewDetail(review_index, total_reviews, true, {
            comments = cache.pages[page],
            info = cache.infos[page] or {},
            __page = page,
            __bubble_count = bubble_count,
            __ident = ident,
        }, nil)
        return
    end

    -- 子进程从最近的已缓存页 (p+1) 顺序补拉到目标页
    local start_page = p + 1
    local cursors_snapshot = {}
    for k, v in pairs(cache.cursors) do
        cursors_snapshot[k] = v
    end

    local function walk_pages(c)
        local fetched = {}
        local q = start_page
        while q <= page do
            -- official_get_para_review 失败时返回 nil+err（对齐 kindle-forge：
            -- 「签名不合规 → 200 空响应」「code≠0」都算失败，绝不能降级成空页）
            local pg, ferr = c:official_get_para_review(ident, {
                count = PARA_REVIEW_PAGE_SIZE,
                cursor = cursors_snapshot[q] or "",
            })
            if not pg then
                return nil, ferr or "段评列表获取失败"
            end
            fetched[q] = pg
            if pg.has_more and tostring(pg.cursor or "") ~= "" then
                cursors_snapshot[q + 1] = pg.cursor
            else
                break -- 服务端末页，停止补拉
            end
            q = q + 1
        end
        return fetched
    end

    -- 将段评获取（阻塞 HTTP）移到子进程，UI 线程仅轮询，不阻塞用户操作。
    self:showBusy(_("正在获取段评..."))
    if Async and Async.run then
        Async.run(function()
            local c = Client:new(self_ref.settings)
            if Log then
                Log.info("[段评] showParaReviewDetail(异步): idx=" .. tostring(review_index)
                    .. " page=" .. tostring(page) .. "/" .. tostring(start_page)
                    .. " ident=" .. tostring(ident):sub(1, 80))
            end
            local ok, fetched, ferr = pcall(walk_pages, c)
            if not ok then error(fetched or "段评获取失败", 0) end
            if not fetched then error(ferr or "段评获取失败", 0) end
            return fetched
        end, function(ok, fetched, err)
            if not ok then
                self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil, err)
                return
            end
            -- 合并子进程取回的页到父进程缓存。
            -- ⚠️ 只缓存请求成功的页：早期版本失败时把空表也写进缓存，
            -- 于是第一次失败之后每次点击都命中空缓存、永远显示「共 0 条」。
            for q, pg in pairs(fetched) do
                cache.pages[q] = pg.comments or {}
                cache.infos[q] = {
                    cursor = pg.cursor,
                    has_more = pg.has_more,
                    total = pg.total,
                }
                if pg.has_more and tostring(pg.cursor or "") ~= "" then
                    cache.cursors[q + 1] = pg.cursor
                end
            end
            -- 实际显示页：目标页取到则显示，否则回退到取到的最深页
            local display_page = page
            while display_page > 1 and not cache.pages[display_page] do
                display_page = display_page - 1
            end
            if not cache.pages[display_page] then
                self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil,
                    "段评列表返回为空")
                return
            end
            self_ref:_displayParaReviewDetail(review_index, total_reviews, true, {
                comments = cache.pages[display_page],
                info = cache.infos[display_page] or {},
                __page = display_page,
                __bubble_count = bubble_count,
                __ident = ident,
            }, nil)
        end, { poll_interval = 0.125, timeout = 60 })
    else
        -- 降级：Async 模块未加载（极端情况），同步执行
        local c = self_ref.client or Client:new(self_ref.settings)
        local ok, fetched, ferr = pcall(walk_pages, c)
        if not ok then
            self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil, fetched)
            return
        end
        if not fetched then
            self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil, ferr)
            return
        end
        for q, pg in pairs(fetched) do
            cache.pages[q] = pg.comments or {}
            cache.infos[q] = {
                cursor = pg.cursor,
                has_more = pg.has_more,
                total = pg.total,
            }
            if pg.has_more and tostring(pg.cursor or "") ~= "" then
                cache.cursors[q + 1] = pg.cursor
            end
        end
        local display_page = page
        while display_page > 1 and not cache.pages[display_page] do
            display_page = display_page - 1
        end
        if not cache.pages[display_page] then
            self_ref:_displayParaReviewDetail(review_index, total_reviews, false, nil,
                "段评列表返回为空")
            return
        end
        self_ref:_displayParaReviewDetail(review_index, total_reviews, true, {
            comments = cache.pages[display_page],
            info = cache.infos[display_page] or {},
            __page = display_page,
            __bubble_count = bubble_count,
            __ident = ident,
        }, nil)
    end
end

-- ===========================================================================
-- 段评树状渲染（顶层段评 + 其回复串）
-- ===========================================================================
-- 层次结构：段评（comment/list）→ 回复（reply/list，reply_to_reply_id 指向父回复）。
-- TextViewer 只能画纯文本、且**不支持行内可点区域**，所以这里的「树」分两层落地：
--   * 层级用**缩进**表达（每层 1 个全角空格，深度封顶，避免深链挤成竖排）；
--   * 展开/收起靠底部按钮，状态存在 self._para_pages[ident]（跨弹窗生命周期）；
--     状态变化后调用 TextViewer:reinit() **原地重排**（reinit 内部按可见高度比例
--     还原滚动位置），而不是关窗重开 —— 否则展开列表深处的一条回复会把视图弹回顶部。
local REPLY_INDENT      = "\u{3000}"  -- 全角空格
local REPLY_INDENT_MAX  = 4           -- 最大缩进层级
local PARA_REPLY_PAGE_SIZE = 20       -- 每次拉取的回复条数（服务端上限 50）
local PARA_REPLY_MAX_PAGES = 5        -- 单次展开最多连拉几页（防「回复上千条」时失控）
local REPLY_BUTTONS_PER_ROW = 4       -- 每行放几个回复开关按钮

-- UIManager:isWidgetShown 是较新版本才有的 API；老版本退化为「句柄在即视为已显示」
-- （close_callback 已负责清句柄，所以这个兜底不会误用已关闭的 widget）
local function viewer_is_shown(widget)
    if not widget then return false end
    if UIManager and type(UIManager.isWidgetShown) == "function" then
        local ok, shown = pcall(UIManager.isWidgetShown, UIManager, widget)
        return ok and shown or false
    end
    return true
end

local function fmt_comment_time(raw)
    if type(raw) == "number" then
        return os.date("%Y-%m-%d %H:%M", raw)
    end
    if raw then
        return tostring(raw)
    end
    return ""
end

-- 头衔展示串：「［作家］［次元破壁神］［故事合伙人］」；没有头衔时返回 ""。
-- 数据由 Comments.titles_of 归一（`fanqie/reading/comments.lua`），这里只管
-- 组装与 i18n：`is_author` 单独补一个「作者」标记（接口的 is_author 与
-- user_title_info 里的「作家」是两回事，实测有 is_author=true 但头衔为空的）。
-- ⚠️ 放在「评论头行」之前，4 处头行（顶层/回复 × 主路径/回退路径）共用它，
--    别只改一处 —— 改动会被 _mutate_paretap.py 的变异抓住。
local function comment_titles_text(comment)
    if type(comment) ~= "table" then return "" end
    local parts = {}
    if comment.is_author == true then parts[#parts + 1] = _("作者") end
    local titles = comment.titles
    if type(titles) == "table" then
        for _i, t in ipairs(titles) do
            if type(t) == "string" then
                -- 🔴 必须**去空白后再判空**：只写 `t ~= ""` 时，纯空白头衔
                --    （" " / "  "）会渲染成「［  ］」这种空括号。
                --    Comments.titles_of 那边本来就会 trim，这里再兜一次是为了
                --    「渲染层不依赖上游一定干净」（回归 D10/D11 压的就是这一条）。
                local name = t:match("^%s*(.-)%s*$")
                if name ~= "" then parts[#parts + 1] = name end
            end
        end
    end
    if #parts == 0 then return "" end
    for i = 1, #parts do parts[i] = "［" .. parts[i] .. "］" end
    return " " .. table.concat(parts)
end

-- 递归把回复树摊成文本行（缩进 + ↳ 前缀 + 「回复某人」）
-- ⚠️ 循环变量**不能**叫 `_`：本函数体内要调用 gettext 的全局 `_()`，
--    而 `for _, node in ...` 的 `_` 是局部变量，会把 `_()` 遮蔽成数字索引
--    （实测报 "attempt to call local '_' (a number value)"）。
local function append_reply_lines(nodes, out)
    for _i, node in ipairs(nodes or {}) do
        local depth = math.min(tonumber(node.depth) or 0, REPLY_INDENT_MAX)
        local indent = string.rep(REPLY_INDENT, depth + 1)
        local to = ""
        if node.reply_to_user_name and node.reply_to_user_name ~= node.user_name then
            to = T(_(" 回复 %1"), tostring(node.reply_to_user_name))
        end
        local head = T(_("%1↳ %2%3%4 (赞%5)"), indent,
            tostring(node.user_name or _("匿名")), comment_titles_text(node), to,
            tonumber(node.digg_count) or 0)
        local ts = fmt_comment_time(node.create_time)
        if ts ~= "" then
            head = head .. "  " .. ts
        end
        out[#out + 1] = head
        local body = tostring(node.text or "")
        if body ~= "" then
            out[#out + 1] = indent .. "  " .. body
        end
        if node.children and #node.children > 0 then
            append_reply_lines(node.children, out)
        end
    end
end

-- 段评图片归一（薄封装，便于渲染与按钮两处共用同一份判定）。
local function comment_images(comment)
    local ok, Comments = pcall(require, "fanqie.reading.comments")
    if not ok or type(Comments) ~= "table" or type(Comments.normalize_images) ~= "function" then
        return {}
    end
    local ok2, list = pcall(Comments.normalize_images, comment and comment.images)
    return (ok2 and type(list) == "table") and list or {}
end

-- 图片提示行：TextViewer 画不了图，只能把「有几张、哪几张能看」写进文本。
-- 不可显示的必须显式说明 —— 否则用户点开是空白，会以为插件坏了。
-- （HEIC 现在会先试着转码成 WebP，转不了才落到这里）
local function comment_image_note(list)
    local n_ok, n_bad, bad_fmt = 0, 0, {}
    for _i, im in ipairs(list) do
        if im.displayable then
            n_ok = n_ok + 1
        else
            n_bad = n_bad + 1
            bad_fmt[string.upper(tostring(im.format or "HEIC"))] = true
        end
    end
    if n_ok == 0 and n_bad == 0 then return nil end
    local parts = {}
    if n_ok > 0 then
        parts[#parts + 1] = T(_("%1 张可看"), tostring(n_ok))
    end
    if n_bad > 0 then
        local names = {}
        for f in pairs(bad_fmt) do names[#names + 1] = f end
        table.sort(names)
        parts[#parts + 1] = T(_("%1 张为 %2，本设备无法显示"),
            tostring(n_bad), table.concat(names, "/"))
    end
    return T(_("【图片】%1"), table.concat(parts, "，"))
end

-- 一条顶层段评 → 文本行（含已展开的回复树）。
-- expanded 为 nil 表示收起；否则为 { roots = 树, has_more = bool, total = n }。
local function append_comment_lines(number, comment, expanded)
    local user = tostring(comment.user_name or comment.username or _("匿名"))
    local likes = tonumber(comment.digg_count or comment.like_count) or 0
    local replies = tonumber(comment.reply_count) or 0
    local head = T(_("%1. %2%3 (赞%4 回复%5)"), number,
        user, comment_titles_text(comment), likes, replies)
    local ts = fmt_comment_time(comment.create_time)
    if ts ~= "" then
        head = head .. "  " .. ts
    end
    -- 折叠标记写进标题：TextViewer **没有行内可点区域**（这是它与 CommentView 的
    -- 唯一交互差别 —— 操作全靠下面那些按钮），用户靠这一行判断
    -- 「这条有没有回复、现在是展开还是收起」。文案与 CommentView 主路径保持一致。
    if expanded then
        head = head .. _("   ［收起］")
    elseif replies > 0 then
        head = head .. T(_("   ［展开 %1 条回复］"), tostring(replies))
    end
    local out = { head }
    local body = tostring(comment.text or "")
    if body ~= "" then
        out[#out + 1] = body
    end
    local note = comment_image_note(comment_images(comment))
    if note then
        out[#out + 1] = note
    end
    if expanded then
        if expanded.roots and #expanded.roots > 0 then
            append_reply_lines(expanded.roots, out)
        end
        if expanded.has_more then
            out[#out + 1] = REPLY_INDENT .. _("… 还有更多回复，点下方「⋯」继续加载")
        end
    end
    return out
end

-- 显示段评详情弹窗（纯 UI 渲染，不做网络请求）
function FanQiePlugin:_displayParaReviewDetail(index, total_reviews, ok, result, err)
    -- 章节切换中：异步段评获取完成时可能已进入新章节，丢弃过期的段评弹窗
    if _state.isChapterNavigating() then
        if Log then Log.debug("[段评] _displayParaReviewDetail: 章节切换中，丢弃段评弹窗") end
        self:closeBusy()
        return
    end
    if not ok then
        if Log then Log.error("[段评] 获取失败:", tostring(err or result)) end
        self:closeBusy()
        self:showInfo(_("段评获取失败: ") .. tostring(err or result))
        return
    end

    -- 评论条目已在子进程由 Comments.flatten_comment 归一（对齐 kindle-forge
    -- api.get_para_comments 的 {'comments':[扁平]}），这里不再解析嵌套结构。
    local comments = (type(result) == "table" and type(result.comments) == "table")
        and result.comments or {}
    local info = (type(result) == "table" and type(result.info) == "table")
        and result.info or {}

    if Log then
        local t = tonumber(info.total) or 0
        Log.info("[段评] 本页返回: comments=" .. #comments .. " total=" .. tostring(t))
    end

    local total = tonumber(info.total) or 0
    if total <= 0 then total = #comments end
    -- 服务端 total 缺失时用气泡上的统计条数兜底
    if total <= 0 then total = tonumber(result and result.__bubble_count) or 0 end

    self:closeBusy()

    if #comments == 0 then
        -- 请求成功但服务端没给条目：把气泡上的统计条数一起显示，
        -- 便于区分「本段确实没评论」与「服务端返回为空」。
        local bubble_count = tonumber(result and result.__bubble_count) or 0
        if bubble_count > 0 then
            self:showInfo(T(_("本条段评共 %1 条，服务端未返回内容，请稍后重试"),
                tostring(bubble_count)))
        else
            self:showInfo(_("本段暂无可显示的段评"))
        end
        return
    end

    -- 渲染所需状态存下来：回复展开/收起按钮只改这里，再原地重排
    self._para_view_state = {
        index = index,
        total_reviews = total_reviews,
        ident = result and result.__ident or nil,
        comments = comments,
        info = info,
        page = tonumber(result and result.__page) or 1,
        total = total,
    }
    self:_renderParaReviewView(false)
end

-- 重新渲染当前段评弹窗。
-- in_place=true 走 TextViewer:reinit()（保留滚动位置）；false 时新建窗口
-- （翻页/换段后应当从头看起）。
-- ---------------------------------------------------------------- 新段评视图

-- 段评图片本地缓存路径（与 showCommentImage 同一套命名，缓存互通）。
-- ⚠️ 图片 URL 带签名、不可改写（实测改后缀/去 query/换 host 全 403），只能原样下载。
-- 🔴 后缀必须落在 `DocumentRegistry.image_ext` 白名单里（jpg/jpeg/png/gif/webp/tif/svg）：
--    `ImageWidget:_loadfile()` 第一句是 `DocumentRegistry:isImageFile(self.file)`，而它
--    是**按后缀**判的（`image_ext[getSuffix(file)]`），不在白名单里就直接
--    `error("Image file type not supported.")` ⇒ 图**根本画不出来**，整条评论只剩文字。
--    番茄段评图 URL 常以 `~tplv-xxx:800:0:0` 这类**无后缀**形式结尾
--    （`Comments.image_ext` 返回 nil），以前 `im.format or "img"` 就落成 `.img` ⇒
--    所有这类图都被默默吞掉。
--    注：真实内容类型由 `RenderImage:renderImageData` 按**文件头**嗅探
--    （RIFF→libwebp、0xFFD8→jpeg、其余交 MuPDF），所以后缀只是「过闸门」用的，
--    猜成 jpg 也不会把 webp 内容解错。
local IMAGE_EXT_OK = {
    jpg = true, jpeg = true, png = true, gif = true, webp = true, tif = true, tiff = true,
}

--- 缓存文件名后缀：认识的原样用，不认识的一律落到 `jpg`（理由见上面白名单注释）。
local function safe_image_ext(im)
    local fmt = type(im) == "table" and tostring(im.format or "") or ""
    fmt = fmt:lower()
    if IMAGE_EXT_OK[fmt] then return fmt end
    return "jpg"
end

local function para_image_path(plugin, owner, owner_no, img_no, im)
    local dir = plugin:_comment_image_dir()
    local cid = (owner.comment_id and tostring(owner.comment_id)) or tostring(owner_no)
    return H.join_path(dir, "c_" .. cid .. "_" .. tostring(img_no)
        .. "." .. safe_image_ext(im))
end

--- 这张图之前下载失败过吗。失败记录挂在当前段评状态上（换段/重开自动失效）。
local function para_image_failed(plugin, path)
    local st = plugin and plugin._para_view_state
    local fails = st and st._image_failures
    return (type(fails) == "table" and fails[path] == true) or false
end

-- 渲染块的图片条目：已下载→内嵌；未下载→「加载中」占位；不可显示→显式说明。
-- 同时返回缺失清单（供后台串行下载），项 { owner=, img_no=, im=, path= }。
-- 图片条目（视图用）。`allow_tap` 为真时给**可显示的图**挂上点击载荷 ——
-- 点图开全屏（落点是 showCommentImage）。
--
-- ⚠️ 只有**顶层评论**能开图：showCommentImage 用 `state.comments[comment_no]`
--    取原始记录，而回复节点（build_reply_blocks）的 owner_no 是 comment_id 字符串，
--    落不到同一张表上。所以回复里的图**不给 tap**（与回退路径只给顶层图按钮一致）。
--    `tap` 载荷 = { no = 顶层评论序号, img = 图片在 comment_images() 里的下标 }。
local function view_image_entries(plugin, owner, owner_no, allow_tap)
    local entries, missing = {}, {}
    local list = comment_images(owner)
    for k, im in ipairs(list) do
        if not im.displayable then
            entries[#entries + 1] = { note = T(_("（%1 图片，本设备无法显示）"),
                string.upper(tostring(im.format or "HEIC"))) }
        else
            local tap = allow_tap and { no = owner_no, img = k } or nil
            local path = para_image_path(plugin, owner, owner_no, k, im)
            if H.file_exists(path) then
                entries[#entries + 1] = { path = path, w = im.width, h = im.height,
                                          img_no = k, tap = tap }
            else
                -- 「正在后台加载…」这一行也可点：点它当场下载并打开
                -- （不必等预取；预取完成后会被上面的 path 分支替换掉）
                -- 失败过的那张明说「加载失败」：永远停在「正在加载」既不告诉用户出了
                -- 什么事、也没法判断还能不能好，是这类异步 UI 最常见的坑。
                local note
                if para_image_failed(plugin, path) then
                    note = T(_("（图%1：加载失败，点这行重试）"), tostring(k))
                else
                    note = T(_("（图%1：正在后台加载…）"), tostring(k))
                end
                entries[#entries + 1] = { note = note, img_no = k, tap = tap }
                missing[#missing + 1] = { owner = owner, img_no = k, im = im, path = path }
            end
        end
    end
    return entries, missing
end

-- 回复树 → 视图块（头行文案与 append_reply_lines 口径一致）。
-- 返回 blocks, missing（缺失图片清单，供后台下载）。
local function build_reply_blocks(plugin, roots)
    local out, missing_all = {}, {}
    local function walk(list)
        for _i, node in ipairs(list or {}) do
            local to = ""
            if node.reply_to_user_name and node.reply_to_user_name ~= node.user_name then
                to = T(_(" 回复 %1"), tostring(node.reply_to_user_name))
            end
            local head = T(_("↳ %1%2%3 · 赞%4"), tostring(node.user_name or _("匿名")),
                comment_titles_text(node), to,
                tonumber(node.digg_count) or 0)
            local ts = fmt_comment_time(node.create_time)
            if ts ~= "" then head = head .. "  " .. ts end
            local imgs, missing = view_image_entries(plugin, node, node.comment_id)
            for _k, m in ipairs(missing) do missing_all[#missing_all + 1] = m end
            out[#out + 1] = {
                head = head,
                text = tostring(node.text or ""),
                images = imgs,
            }
            if node.children and #node.children > 0 then
                walk(node.children)
            end
        end
    end
    walk(roots)
    return out, missing_all
end

-- 拉取某条评论的回复并合入缓存（**不渲染**）。on_done(ok) 在父进程回调。
-- 与 showParaReviewReplies 共用同一套游标/上限逻辑；签名不合规时服务端回
-- 200 空响应，client 层转成 (nil, err)，这里必须报错而不是退化成「没回复」。
function FanQiePlugin:_fetchParaReplies(index, comment_no, on_done)
    local state = self._para_view_state
    if not state or state.index ~= index then
        self:showInfo(_("段评数据已失效，请重新打开"))
        if on_done then on_done(false) end
        return
    end
    local comment = state.comments[comment_no]
    local cid = comment and comment.comment_id and tostring(comment.comment_id) or nil
    if not cid then
        self:showInfo(_("段评数据无效"))
        if on_done then on_done(false) end
        return
    end
    local cache = state.ident and self._para_pages and self._para_pages[state.ident] or nil
    if not cache then
        self:showInfo(_("段评数据已失效，请重新打开"))
        if on_done then on_done(false) end
        return
    end
    cache.expanded = cache.expanded or {}
    cache.replies = cache.replies or {}
    local rs = cache.replies[cid]
    if not rs then
        rs = { flat = {}, pages = 0, cursor = "", has_more = true, total = 0 }
        cache.replies[cid] = rs
    end
    local remain = PARA_REPLY_MAX_PAGES - (rs.pages or 0)
    if remain <= 0 then
        self:showInfo(_("已达到单次加载上限"))
        if on_done then on_done(false) end
        return
    end
    local cursor = (rs.pages or 0) > 0 and rs.cursor or ""
    local self_ref = self
    if Log then
        Log.info("[段评] 获取回复: idx=" .. tostring(index) .. " comment=" .. cid
            .. " cursor=" .. tostring(cursor) .. " 可拉页数=" .. tostring(remain))
    end
    self:showBusy(_("正在获取回复..."))
    if not (Async and Async.run) then
        self:closeBusy()
        self:showInfo(_("异步模块不可用，无法获取回复"))
        if on_done then on_done(false) end
        return
    end
    Async.run(function()
        local c = Client:new(self_ref.settings)
        local flat, cur, has_more, total, pages = {}, cursor, true, 0, 0
        while pages < remain do
            local pg, ferr = c:official_get_para_replies(cid, {
                count = PARA_REPLY_PAGE_SIZE,
                cursor = cur,
            })
            -- 子进程里只有 error() 能把失败原因带回父进程
            if not pg then
                error(ferr or "段评回复获取失败", 0)
            end
            for _i, r in ipairs(pg.replies or {}) do
                flat[#flat + 1] = r
            end
            total = tonumber(pg.total) or total
            pages = pages + 1
            local nxt = tostring(pg.cursor or "")
            if pg.has_more and nxt ~= "" and nxt ~= cur then
                cur = nxt
            else
                has_more = false
                break
            end
        end
        return {
            flat = flat,
            cursor = cur,
            has_more = has_more,
            total = total,
            pages = pages,
        }
    end, function(ok, res, ferr)
        self_ref:closeBusy()
        if not ok or type(res) ~= "table" then
            if Log then Log.error("[段评] 回复获取失败:", tostring(ferr or res)) end
            self_ref:showInfo(T(_("回复获取失败: %1"), tostring(ferr or res)))
            if on_done then on_done(false) end
            return
        end
        -- ⚠️ 合并必须在父进程做：子进程里的 table 改动不会回传
        local flat_before = #rs.flat
        for _i, r in ipairs(res.flat or {}) do
            rs.flat[#rs.flat + 1] = r
        end
        rs.pages = (rs.pages or 0) + (tonumber(res.pages) or 0)
        rs.cursor = tostring(res.cursor or "")
        rs.has_more = res.has_more == true
        rs.total = tonumber(res.total) or rs.total
        -- ⚠️ 「空成功」闸门（2026-10-17，排查「展开回复后空白」）：client 层已挡
        --    total>0 的空列表，这里再挡 total 一并被抹成 0 的那一种 —— 评论自己
        --    明明挂着 reply_count>0，首页却 0 条。放行的后果不只是这一次空白：
        --    pages 记成 1 后，「纯展开零请求」分支（rs.pages>0 直接复用缓存）会把
        --    空结果**粘死**，收起再展开永远不再发请求 ⇒ 必须整体回滚（含裁掉本次
        --    并进的空段、清零 pages/cursor/total），让下一次点开真的重新拉第一页。
        local want = tonumber(comment.reply_count) or 0
        if #rs.flat == 0 and want > 0 then
            for _i = #rs.flat, flat_before + 1, -1 do
                rs.flat[_i] = nil
            end
            rs.pages = 0
            rs.cursor = ""
            rs.has_more = true
            rs.total = 0
            if Log then
                Log.warn("[段评] 回复列表为空但评论挂着回复数: cid=" .. tostring(cid)
                    .. " reply_count=" .. tostring(want)
                    .. " resp_pages=" .. tostring(res.pages)
                    .. " resp_total=" .. tostring(res.total))
            end
            self_ref:showInfo(_("回复列表返回为空（可能被风控），请稍后重试"))
            if on_done then on_done(false) end
            return
        end
        if Log then
            Log.info("[段评] 回复合并: cid=" .. tostring(cid)
                .. " flat=" .. tostring(#rs.flat)
                .. " total=" .. tostring(rs.total)
                .. " pages=" .. tostring(rs.pages))
        end
        if on_done then on_done(true) end
    end, { poll_interval = 0.125, timeout = 60 })
end

-- 「回复」按钮（cycling）：有收起的→全部展开；都展开但有更多→续拉；
-- 全部加载完→全部收起。整条链路只占**一个**固定按钮。
function FanQiePlugin:toggleAllParaReplies()
    local state = self._para_view_state
    if not state then
        self:showInfo(_("段评数据已失效，请重新打开"))
        return
    end
    local cache = state.ident and self._para_pages and self._para_pages[state.ident] or nil
    if not cache then
        self:showInfo(_("段评数据已失效，请重新打开"))
        return
    end
    cache.expanded = cache.expanded or {}
    cache.replies = cache.replies or {}

    local to_expand, to_more, any_expanded = {}, {}, false
    for i, comment in ipairs(state.comments) do
        local cid = comment.comment_id and tostring(comment.comment_id) or nil
        local n = tonumber(comment.reply_count) or 0
        if cid and n > 0 then
            if not cache.expanded[cid] then
                to_expand[#to_expand + 1] = i
            else
                any_expanded = true
                local rs = cache.replies[cid]
                if rs and rs.has_more then to_more[#to_more + 1] = i end
            end
        end
    end

    local chain
    chain = function(list, pos)
        if not list or pos > #list then
            self:_renderParaReviewView(true)
            return
        end
        self:_fetchParaReplies(state.index, list[pos], function(ok)
            if not ok then
                -- 失败（含上限）也继续渲染已拉到的部分
                self:_renderParaReviewView(true)
                return
            end
            chain(list, pos + 1)
        end)
    end

    if #to_expand > 0 then
        chain(to_expand, 1)
    elseif #to_more > 0 then
        chain(to_more, 1)
    elseif any_expanded then
        for cid in pairs(cache.expanded) do
            cache.expanded[cid] = nil
        end
        self:_renderParaReviewView(true)
    else
        self:showInfo(_("这一页的评论都没有回复"))
    end
end

-- 后台串行下载本页缺失的段评图片；每张完成即 refresh（逐张浮现）。
function FanQiePlugin:_prefetchParaImages(index)
    local state = self._para_view_state
    if not state or state.index ~= index then return end
    if state._images_prefetching then return end
    local missing = {}
    local fails = type(state._image_failures) == "table" and state._image_failures or {}
    for _i, vc in ipairs(state._view_images_missing or {}) do
        -- ⚠️ 已经失败过的不再自动重试：否则会变成
        --    「下载失败 → 重渲染 → 又进预取 → 再失败」的**死循环**（一直打服务器 + 一直刷屏）。
        --    用户点那一行（showCommentImage）才是重试入口。
        if not fails[vc.path] then
            missing[#missing + 1] = vc
        end
    end
    if #missing == 0 then return end
    state._images_prefetching = true
    local self_ref = self
    local client = self.client
    local pos = 0

    -- 图片回填的**合并节流**。
    --
    -- 🔴 为什么要合并：CommentView:refresh() 是「整树重建」，而图片是逐张下完的 ——
    --    每张都立刻重建一次 ⇒ ① 屏幕上一直闪（重建后要整块重绘）；
    --    ② 一页 N 张图会留下 N 棵内容树的 blitbuffer 等 GC（小内存设备上
    --    反复开关评论区就是「闪退」）。把 250ms 内的多次完成合并成一次重建，
    --    观感上仍是「分批浮现」，但只重绘一次、只产生一棵待回收的树。
    local render_scheduled = false
    local function schedule_render()
        if render_scheduled then return end
        render_scheduled = true
        UIManager:scheduleIn(0.25, function()
            render_scheduled = false
            local st = self_ref._para_view_state
            if not st or st.index ~= index then return end
            -- 🔴 视图已经不在屏幕上（用户翻了页/点了关闭）时**不要**重新弹出来：
            --    `in_place=true` 的语义是「刷新正显示着的这一份」；没人看就渲染的话，
            --    `viewer_is_shown` 为假 ⇒ 走新建分支 ⇒ 已关掉的旧页以「幽灵窗」还魂，
            --    压在翻页 loading 上面（本条曾与「点下一页」竞态实踩）。
            if not viewer_is_shown(self_ref._para_viewer) then return end
            self_ref:_renderParaReviewView(true)
        end)
    end

    local function next_one()
        if not self_ref._para_view_state or self_ref._para_view_state.index ~= index then
            return -- 视图已切走
        end
        pos = pos + 1
        local job = missing[pos]
        if not job then
            self_ref._para_view_state._images_prefetching = false
            return
        end
        if H.file_exists(job.path) then
            next_one()
            return
        end
        Async.run(function()
            -- referer=false：fqnovelpic 系 CDN 实测对 Referer 做防盗链
            -- fetch_url：HEIC 已换成无签名 host + 公共模板（服务端转码成 WebP）
            local data = client:get_binary(job.im.fetch_url or job.im.url, { referer = false })
            if not data or #data == 0 then
                error("图片下载失败（响应为空）", 0)
            end
            H.write_file(job.path, data)
            return { path = job.path }
        end, function(ok, res)
            local st = self_ref._para_view_state
            if st and type(st._image_failures) == "table" then
                -- 成功要把失败标记清掉：否则这张图会一直显示「加载失败」
                st._image_failures[job.path] = nil
            end
            if ok and type(res) == "table" and res.path then
                -- 回填：把占位换成真图，原地刷新
                for _i, vc in ipairs((self_ref._para_view_state or {})._view_images_missing or {}) do
                    if vc.path == res.path then
                        vc.done = true
                        break
                    end
                end
                schedule_render()
            elseif st then
                -- 失败：记下来（视图会显示「加载失败，点这行重试」）并立刻重渲染
                if type(st._image_failures) ~= "table" then st._image_failures = {} end
                st._image_failures[job.path] = true
                if logger then logger.warn("段评图片下载失败:", tostring(job.path), tostring(res)) end
                schedule_render()
            end
            next_one()
        end, { poll_interval = 0.25, timeout = 45, tag = "comment_image" })
    end
    next_one()
end

-- 当前**阅读字号**（逻辑值，未 DPI 缩放）—— 段评 / 评论区的字号按它折算，
-- 这样「正文调大了，评论区跟着大」（用户反馈「评论区字还是太小」）。
-- 取法优先级：当前文档 `font_size`（crengine，用户真正在调的那个）→ 全局 `cre_font_size`
-- → 全局 `font_size` → nil（交给 comment_view 用默认基准兜底）。
-- ⚠️ mupdf 的 `font_size` 是 1.0 量级的倍数、crengine 是 12~64 的 pt 级数
--    （KOReader 自己就用 `<5` / `>5` 区分这两种语义）⇒ 区间外的值一律当读不到，
--    否则 mupdf 用户的评论区会被算成 1pt。
function FanQiePlugin:_readerFontSize()
    local function sane(v)
        v = tonumber(v)
        if v and v >= 12 and v <= 64 then return v end
        return nil
    end
    local size
    if self.ui and self.ui.doc_settings and self.ui.doc_settings.readSetting then
        size = sane(self.ui.doc_settings:readSetting("font_size"))
    end
    if not size then
        local ok, rs = pcall(function() return G_reader_settings end)
        if ok and rs and rs.readSetting then
            size = sane(rs:readSetting("cre_font_size")) or sane(rs:readSetting("font_size"))
        end
    end
    return size
end

-- 渲染段评视图（优先 CommentView；不可用时退回纯文本 TextViewer）。
function FanQiePlugin:_renderParaReviewView(in_place)
    if not CommentView then
        return self:_renderParaReviewText(in_place)
    end
    local state = self._para_view_state
    if not state then return end
    local comments = state.comments
    local Comments = require("fanqie.reading.comments")

    local cache = state.ident and self._para_pages and self._para_pages[state.ident] or nil
    local cache_expanded = (cache and cache.expanded) or {}
    local cache_replies = (cache and cache.replies) or {}

    local view_comments = {}
    local all_missing = {}
    for i, comment in ipairs(comments) do
        local cid = comment.comment_id and tostring(comment.comment_id) or nil
        local expanded = nil
        if cid and cache_expanded[cid] then
            local rs = cache_replies[cid]
            expanded = {
                roots = Comments.build_reply_tree((rs and rs.flat) or {}),
                has_more = (rs and rs.has_more) == true,
                total = tonumber(rs and rs.total) or 0,
            }
        end
        local user = tostring(comment.user_name or comment.username or _("匿名"))
        local likes = tonumber(comment.digg_count or comment.like_count) or 0
        local replies = tonumber(comment.reply_count) or 0
        local head = T(_("%1. %2%3 · 赞%4 · 回复%5"), tostring(i),
            user, comment_titles_text(comment), likes, replies)
        local ts = fmt_comment_time(comment.create_time)
        if ts ~= "" then head = head .. "  " .. ts end
        -- 折叠标记写进头行 —— **这一行本身就是可点行**（v2.12.0 起，见 comment_view 的 TapRow）。
        -- 文案要**自解释**：直接写「展开 N 条回复」，不要只放一个 ▼/▶
        -- （用户既看不出 N 是多少，也看不出它可点）。已展开时写「收起」：
        -- 条数此刻就列在下面，再写一遍是噪音。
        if expanded then
            head = head .. _("   ［收起］")
        elseif replies > 0 then
            head = head .. T(_("   ［展开 %1 条回复］"), tostring(replies))
        end

        local imgs, missing = view_image_entries(self, comment, i, true)
        for _k, m in ipairs(missing) do all_missing[#all_missing + 1] = m end

        local rc, more, reply_missing
        if expanded then
            rc, reply_missing = build_reply_blocks(self, expanded.roots)
            for _k, m in ipairs(reply_missing or {}) do all_missing[#all_missing + 1] = m end
            if expanded.has_more then
                more = math.max(1, (expanded.total or 0) - #(expanded.roots or {}))
            end
        end

        -- 可点载荷（**不透明**，语义在这里；comment_view 只负责原样回传）：
        --   tap      = 点「头行 + 正文」→ 该条展开/收起（只有回复数 >0 或已展开才可点）
        --   more_tap = 点「… 还有 N 条回复」→ 该条继续加载
        -- 0 回复且未展开的评论**不给 tap**：否则点一下会白发一次 commentapi 请求，
        -- 而那种评论本来就不显示折叠标记（与上面 head 的判据保持一致）。
        local tap, more_tap
        if (replies > 0) or expanded then
            tap = { no = i, collapse = (expanded ~= nil) }
        end
        if more then
            more_tap = { no = i, more = true }
        end

        view_comments[#view_comments + 1] = {
            no = i,
            head = head,
            text = tostring(comment.text or ""),
            images = imgs,
            replies = rc,
            more_replies = more,
            tap = tap,
            more_tap = more_tap,
        }
    end
    state._view_images_missing = all_missing

    -- 单条点击的落点：comment_view 只回传 payload，这里负责翻成一次请求/渲染。
    -- 复用 showParaReviewReplies（它自己做了「收起=零请求」「已缓存=零请求」
    -- 「more 且没更多=提示」三种快速分支，以及失效状态守卫）。
    local index_ref = state.index
    local on_block_tap = function(t)
        if type(t) ~= "table" then return end
        if t.more then
            self:showParaReviewReplies(index_ref, t.no, { more = true })
        else
            self:showParaReviewReplies(index_ref, t.no, { collapse = t.collapse })
        end
    end
    -- 点段评图 → 全屏预览（与回退路径的「图N·k」按钮同一个落点）。
    -- 未缓存的图由 showCommentImage 自己下载，所以不必等预取完成。
    local on_image_tap = function(t)
        if type(t) ~= "table" then return end
        self:showCommentImage(index_ref, t.no, t.img)
    end

    -- 底部按钮（固定数量，不随评论条数增长）
    -- ⚠️ 这一行是**批量**开关（单条点击见上面的 tap）——所以文案必须带「全部」，
    --    否则和「点评论展开这一条」混淆。
    local buttons_table = {}
    local reply_label = _("展开全部回复")
    local any_collapsed = false
    for _i, comment in ipairs(comments) do
        local cid = comment.comment_id and tostring(comment.comment_id) or nil
        local n = tonumber(comment.reply_count) or 0
        if cid and n > 0 and not cache_expanded[cid] then
            any_collapsed = true
            break
        end
    end
    if not any_collapsed then
        local any_more = false
        for _i, comment in ipairs(comments) do
            local cid = comment.comment_id and tostring(comment.comment_id) or nil
            local rs = cid and cache_replies[cid] or nil
            if cid and cache_expanded[cid] and rs and rs.has_more then
                any_more = true
                break
            end
        end
        reply_label = any_more and _("加载更多回复") or _("收起全部回复")
    end
    buttons_table[#buttons_table + 1] = { {
        text = reply_label,
        callback = function() self:toggleAllParaReplies() end,
    } }

    local page = state.page or 1
    local has_more = state.info.has_more == true
    local total = state.total or 0
    local total_pages = nil
    if total > PARA_REVIEW_PAGE_SIZE then
        total_pages = math.ceil(total / PARA_REVIEW_PAGE_SIZE)
    end

    local page_row = {}
    -- 🔴 翻页/关闭按钮**绝不**在回调里直接 `UIManager:close` 再开新窗（v2.16.0 实测真机
    --    「点下一页秒闪退」的根因）。两个独立的坑：
    --    ① 回调此刻还在**按钮自己的手势分发**里，而且 flash_ui 开着时 Button 的回调
    --       前后还要穿插高亮/取消高亮的即时重绘（见 ui/widget/button.lua
    --       onTatSelectButton 的长注释：官方明确写了「回调可能关掉自己」并为此绕路）——
    --       在这个当口把整棵控件树（包括那个正在执行回调的 Button 自己）free 掉，
    --       是真机 segfault 的经典姿势；
    --    ② 「先关窗、再异步取数」会和图片预取的 schedule_render 竞态：定时器先到的话，
    --       `_renderParaReviewView(true)` 看不到已显示的视图，会把**旧页**当新窗重新弹出来。
    --    修法：nextTick 把动作挪出手势分发；旧窗保留到新数据就绪，由
    --    `_renderParaReviewView(false)` 的 else 分支统一「关旧开新」——
    --    墨水屏上还少一次闪空白。
    if page > 1 then
        page_row[#page_row + 1] = {
            text = _("上一页"),
            callback = function()
                UIManager:nextTick(function()
                    self:showParaReviewDetail(state.index, { page = page - 1 })
                end)
            end,
        }
    end
    if has_more or (total_pages and page < total_pages) then
        page_row[#page_row + 1] = {
            text = _("下一页"),
            callback = function()
                UIManager:nextTick(function()
                    self:showParaReviewDetail(state.index, { page = page + 1 })
                end)
            end,
        }
    end
    page_row[#page_row + 1] = {
        text = _("关闭"),
        callback = function()
            UIManager:nextTick(function()
                local v = self._para_viewer
                -- 🔴 走 `CommentView:onClose` 而不是裸 `UIManager:close`：
                --    它是「用户主动关闭」的唯一语义入口，会在关窗后按需补一次**全刷**
                --    （视图里有内嵌图片时不刷会留残影），并且会连带触发 `on_close`
                --    清掉 `_para_viewer` 句柄。裸 close 两件事都漏。
                if v and v.onClose then
                    pcall(v.onClose, v)
                elseif v then
                    pcall(function() UIManager:close(v) end)
                end
                self._para_viewer = nil
            end)
        end,
    }
    buttons_table[#buttons_table + 1] = page_row

    local viewer_title = T(_("段评 %1/%2 (共%3条)"), tostring(state.index),
        tostring(state.total_reviews), tostring(total))
    if total_pages then
        viewer_title = viewer_title .. T(_(" 第%1/%2页"), tostring(page), tostring(total_pages))
    end

    local need_prefetch = #all_missing > 0
    if in_place and viewer_is_shown(self._para_viewer) and self._para_viewer.refresh then
        -- 原地重建（CommentView:refresh 保持滚动比例；图片逐张回填时页面不跳）
        -- ⚠️ on_block_tap / on_image_tap 都必须一起换：闭包捕获的是**本次渲染**的
        --    index_ref，复用旧闭包会在换段后打到旧段落上
        --    （refresh 只重建内容，不重建实例）。
        local viewer = self._para_viewer
        viewer.title = viewer_title
        viewer.comments = view_comments
        viewer.buttons_table = buttons_table
        viewer.on_block_tap = on_block_tap
        viewer.on_image_tap = on_image_tap
        -- 阅读字号可能在读书过程中被调过 ⇒ 一起刷新（清掉缓存，refresh 会重算并重建内容树）
        viewer.reader_font_size = self:_readerFontSize()
        viewer._font_head = nil
        viewer:refresh()
    else
        if self._para_viewer and self._para_viewer.onClose then
            pcall(function() UIManager:close(self._para_viewer) end)
        end
        self._para_viewer = CommentView:new{
            title = viewer_title,
            comments = view_comments,
            buttons_table = buttons_table,
            on_block_tap = on_block_tap,
            on_image_tap = on_image_tap,
            -- 字号跟正文走（读不到就给 nil，comment_view 用默认基准）
            reader_font_size = self:_readerFontSize(),
            on_close = function()
                -- 关窗后清掉句柄，避免下次对已关闭的 widget 调 refresh
                self._para_viewer = nil
            end,
        }
        UIManager:show(self._para_viewer)
    end
    if need_prefetch then
        UIManager:scheduleIn(0.2, function()
            self:_prefetchParaImages(state.index)
        end)
    end
end

-- [兜底渲染器] TextViewer 纯文本版：CommentView（fanqie/comment_view.lua）加载
-- 失败时使用。文案口径与新视图一致，但没有内嵌图片（只有【图片】提示行）。
function FanQiePlugin:_renderParaReviewText(in_place)
    local state = self._para_view_state
    if not state then return end
    local comments = state.comments

    local cache = state.ident and self._para_pages and self._para_pages[state.ident] or nil
    local cache_expanded = (cache and cache.expanded) or {}
    local cache_replies = (cache and cache.replies) or {}
    local Comments = require("fanqie.reading.comments")

    local text_parts = {}
    local reply_buttons = {}
    for i, comment in ipairs(comments) do
        local cid = comment.comment_id and tostring(comment.comment_id) or nil
        local expanded = nil
        if cid and cache_expanded[cid] then
            local rs = cache_replies[cid]
            expanded = {
                roots = Comments.build_reply_tree((rs and rs.flat) or {}),
                has_more = (rs and rs.has_more) == true,
                total = tonumber(rs and rs.total) or 0,
            }
        end
        text_parts[#text_parts + 1] = table.concat(append_comment_lines(i, comment, expanded), "\n")

        if cid then
            local n = tonumber(comment.reply_count) or 0
            local is_open = cache_expanded[cid] == true
            if n > 0 or is_open then
                local index_ref = state.index
                local no = i
                reply_buttons[#reply_buttons + 1] = {
                    text = is_open and T(_("%1 收起"), tostring(i))
                        or T(_("%1 展开%2条回复"), tostring(i), tostring(n)),
                    callback = function()
                        self:showParaReviewReplies(index_ref, no, { collapse = is_open })
                    end,
                }
                local rs = cache_replies[cid]
                if is_open and rs and rs.has_more then
                    reply_buttons[#reply_buttons + 1] = {
                        text = T(_("%1 ⋯"), tostring(i)),
                        callback = function()
                            self:showParaReviewReplies(index_ref, no, { more = true })
                        end,
                    }
                end
            end
        end

        -- 段评图片：每张「可显示」的图一个按钮。
        -- 不可显示的（HEIC）**不给按钮**，理由已写进正文的图片提示行，
        -- 免得按钮点下去只能弹一句"打不开"。
        for _k, im in ipairs(comment_images(comment)) do
            if im.displayable then
                local index_ref2 = state.index
                local no2, kn2 = i, _k
                reply_buttons[#reply_buttons + 1] = {
                    text = T(_("图%1·%2"), tostring(i), tostring(_k)),
                    callback = function()
                        self:showCommentImage(index_ref2, no2, kn2)
                    end,
                }
            end
        end
    end

    local buttons_table = {}
    for i = 1, #reply_buttons, REPLY_BUTTONS_PER_ROW do
        local row = {}
        for j = i, math.min(i + REPLY_BUTTONS_PER_ROW - 1, #reply_buttons) do
            row[#row + 1] = reply_buttons[j]
        end
        buttons_table[#buttons_table + 1] = row
    end

    -- 分页状态（__page 由 showParaReviewDetail 标记）
    local page = state.page or 1
    local has_more = state.info.has_more == true
    local total = state.total or 0
    local total_pages = nil
    if total > PARA_REVIEW_PAGE_SIZE then
        total_pages = math.ceil(total / PARA_REVIEW_PAGE_SIZE)
    end

    local page_row = {}
    -- 🔴 与 CommentView 版同理（见那边长注释）：不要在按钮手势分发里直接关窗，
    --    一律 nextTick 挪出去，旧窗留给 `_renderParaReviewView` 统一关。
    if page > 1 then
        page_row[#page_row + 1] = {
            text = _("上一页"),
            callback = function()
                UIManager:nextTick(function()
                    self:showParaReviewDetail(state.index, { page = page - 1 })
                end)
            end,
        }
    end
    if has_more or (total_pages and page < total_pages) then
        page_row[#page_row + 1] = {
            text = _("下一页"),
            callback = function()
                UIManager:nextTick(function()
                    self:showParaReviewDetail(state.index, { page = page + 1 })
                end)
            end,
        }
    end
    if #page_row > 0 then
        buttons_table[#buttons_table + 1] = page_row
    end

    buttons_table[#buttons_table + 1] = {
        {
            text = _("关闭"),
            callback = function()
                UIManager:nextTick(function()
                    local v = self._para_viewer
                    -- 与 CommentView 版同理：走官方 `TextViewer:onClose`（内部会调
                    -- `close_callback` 清句柄），而不是裸 `UIManager:close`。
                    -- 本回退路径没有内嵌图片，所以不需要补全刷。
                    if v and v.onClose then
                        pcall(v.onClose, v)
                    elseif v then
                        pcall(function() UIManager:close(v) end)
                    end
                    self._para_viewer = nil
                end)
            end,
        },
    }

    local viewer_title = T(_("段评 %1/%2 (共%3条)"), tostring(state.index),
        tostring(state.total_reviews), tostring(total))
    if total_pages then
        viewer_title = viewer_title .. T(_(" 第%1/%2页"), tostring(page), tostring(total_pages))
    end

    local text = table.concat(text_parts, "\n\n")
    if in_place and viewer_is_shown(self._para_viewer) then
        -- 原地重排：TextViewer:reinit() 会按可见高度比例还原滚动位置
        local viewer = self._para_viewer
        viewer.text = text
        viewer.title = viewer_title
        viewer.buttons_table = buttons_table
        viewer:reinit()
    else
        self._para_viewer = TextViewer:new{
            title = viewer_title,
            text = text,
            text_type = "book_info",
            justified = false,
            buttons_table = buttons_table,
            close_callback = function()
                -- 关窗后清掉句柄，避免下次对已关闭的 widget 调 reinit
                self._para_viewer = nil
            end,
        }
        UIManager:show(self._para_viewer)
    end
end

-- 展开 / 收起 / 继续加载某条段评的回复（reply/list，异步）。
-- comment_no 是本页评论序号（1-based）；opts = { collapse=true | more=true }。
-- ⚠️ 回复请求与段评列表同属 commentapi：签名不合规时服务端回 **200 空响应**，
--    client 层把它转成 (nil, err)，这里必须显示成错误，
--    不能退化成「这条没有回复」——两者症状一样但含义完全相反。
function FanQiePlugin:showParaReviewReplies(index, comment_no, opts)
    opts = opts or {}
    local state = self._para_view_state
    if not state or state.index ~= index then
        self:showInfo(_("段评数据已失效，请重新打开"))
        return
    end
    local comment = state.comments[comment_no]
    local cid = comment and comment.comment_id and tostring(comment.comment_id) or nil
    if not cid then
        self:showInfo(_("段评数据无效"))
        return
    end
    local cache = state.ident and self._para_pages and self._para_pages[state.ident] or nil
    if not cache then
        self:showInfo(_("段评数据已失效，请重新打开"))
        return
    end
    cache.expanded = cache.expanded or {}
    cache.replies = cache.replies or {}
    local rs = cache.replies[cid]
    if not rs then
        rs = { flat = {}, pages = 0, cursor = "", has_more = true, total = 0 }
        cache.replies[cid] = rs
    end

    -- 收起
    if opts.collapse then
        cache.expanded[cid] = nil
        self:_renderParaReviewView(true)
        return
    end
    -- 已有数据且不是「继续加载」→ 纯展开，零请求
    if not opts.more and (rs.pages or 0) > 0 then
        cache.expanded[cid] = true
        self:_renderParaReviewView(true)
        return
    end
    if opts.more and not rs.has_more then
        self:showInfo(_("没有更多回复了"))
        return
    end

    -- 实际拉取复用 _fetchParaReplies（游标/上限/busy/子进程/合并都在那边），
    -- 这里只负责快速分支与「成功后展开 + 重渲染」。
    local self_ref = self
    self:_fetchParaReplies(index, comment_no, function(ok)
        if ok then
            cache.expanded[cid] = true
            self_ref:_renderParaReviewView(true)
        end
    end)
end

-- 段评图片的本地缓存目录（与章节缓存同根，便于「缓存管理」一起统计/清理）。
function FanQiePlugin:_comment_image_dir()
    local base
    if self.settings and self.settings.get_download_dir then
        base = self.settings:get_download_dir()
    end
    if not base or base == "" then
        base = H.get_data_dir()
    end
    return H.join_path(base, "comment_images")
end

-- 查看段评里的一张图片。
-- 缓存命中直接开；未命中在子进程下载（UI 线程零阻塞）后开。
--
-- ⚠️ 图片 URL 是**带签名的**（x-expires 约 1 个月）。实测三件事：
--    · 改扩展名（.heic→.jpeg）、去掉 query、换无签名 host —— 全部 403；
--    · 换 Accept 头（image/webp / image/jpeg / */*）—— 服务端不做内容协商，
--      返回的内容类型恒定；
--    → 只能**原样**下载再本地缓存，任何"看起来更友好"的 URL 改写都会失败。
function FanQiePlugin:showCommentImage(index, comment_no, img_no)
    local state = self._para_view_state
    if not state or state.index ~= index then
        self:showInfo(_("段评数据已失效，请重新打开"))
        return
    end
    local comment = state.comments[comment_no]
    local list = comment_images(comment)
    local im = list[img_no]
    if not im or im.url == "" then
        self:showInfo(_("图片不存在"))
        return
    end
    if not im.displayable then
        self:showInfo(T(_("该图片为 %1 格式，本设备无法显示"),
            string.upper(tostring(im.format or "HEIC"))))
        return
    end

    -- 与内嵌渲染共用同一个路径函数（后缀白名单见 para_image_path 的注释）——
    -- 两边各写一份的话，改了一处就会出现「内嵌能显示、点开却说文件不存在」。
    local path = para_image_path(self, comment, comment_no, img_no, im)

    local title = T(_("段评图片 %1/%2"), tostring(img_no), tostring(#list))
    local self_ref = self
    local function open_file(p)
        if not ImageViewer then
            self_ref:showInfo(_("图片查看器不可用"))
            return
        end
        UIManager:show(ImageViewer:new{
            file = p,
            with_title_bar = true,
            title_text = title,
        })
    end

    if H.file_exists(path) then
        open_file(path)
        return
    end

    self:showBusy(_("正在下载图片..."))
    if not (Async and Async.run) then
        self:closeBusy()
        self:showInfo(_("异步模块不可用，无法下载图片"))
        return
    end
    local client = self.client
    Async.run(function()
        -- referer=false：fqnovelpic 系 CDN 实测对 Referer 做防盗链
        -- fetch_url：HEIC 已换成无签名 host + 公共模板（服务端转码成 WebP）
        local data = client:get_binary(im.fetch_url or im.url, { referer = false })
        if not data or #data == 0 then
            error("图片下载失败（响应为空）", 0)
        end
        H.write_file(path, data)
        return { path = path }
    end, function(ok, res, err)
        self_ref:closeBusy()
        if not ok or type(res) ~= "table" or not res.path then
            if Log then Log.error("[段评] 图片下载失败:", tostring(err or res)) end
            self_ref:showInfo(T(_("图片下载失败: %1"), tostring(err or res)))
            return
        end
        -- 手动重试成功：清掉失败标记并重渲染，那张「加载失败」占位行会就地变成真图
        local st = self_ref._para_view_state
        if st and type(st._image_failures) == "table" and st._image_failures[path] then
            st._image_failures[path] = nil
            self_ref:_renderParaReviewView(true)
        end
        open_file(res.path)
    end, { poll_interval = 0.125, timeout = 45, tag = "comment_image" })
end

-- 段评异步获取已迁移至 showParaReviewDetail / _displayParaReviewDetail


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
    -- 章节切换中（onEndOfBook→navigateToChapter）：忽略段评请求，防止弹窗闪现
    if _state.isChapterNavigating() then
        if Log then Log.debug("[段评] onFanQieParaReview: 章节切换中，跳过 idx=" .. tostring(idx)) end
        return true
    end
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
            text = _("书城"),
            callback = self:safeCallback(_("书城"), function()
                self:showStore()
            end),
        },
        {
            text = _("下载管理"),
            callback = self:safeCallback(_("下载管理"), function()
                self:showDownloadManager()
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
            text = _("在线更新"),
            sub_item_table_func = function()
                return self:getUpdateMenuItems()
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
                text = T(Info and Info.about_template or _("番茄小说插件 v%1"), self.version, self.settings:get_download_dir()),
            })
        end),
    })
    
    return items
end

-- 在线更新菜单（实现见 fanqie/updater_ui.lua）
function FanQiePlugin:getUpdateMenuItems()
    if not (UpdaterUI and UpdaterUI.menu_items) then
        return {
            { text = _("当前环境不支持在线更新（网络组件不可用）"), enabled = false },
        }
    end
    return UpdaterUI.menu_items(self)
end

-- ===========================================================================
-- Settings menu
-- ===========================================================================

--- 「阅读中定期上传进度」档位（分钟）。0 = 关闭。
-- 默认见 `fanqie/settings.lua` 的 `sync.upload_interval_minutes`。
FanQiePlugin.PROGRESS_UPLOAD_PRESETS = { 0, 1, 3, 5, 10 }

--- 设置 → 阅读中定期上传进度：单选档位。
--
-- 存在的理由：以前进度只在「末页翻章 / 关文档 / 开目录」三个时刻上传，
-- 读到一半退出（关 KOReader、切书、掉电、被杀）这段进度就没了 ——
-- README 里承诺的「阅读中定期上传」在那之前其实并不存在。
function FanQiePlugin:getProgressUploadIntervalItems()
    local function current_minutes()
        local ok, sync = pcall(function() return self.settings:get("sync", {}) end)
        if not ok or type(sync) ~= "table" then return 0 end
        return tonumber(sync.upload_interval_minutes) or 0
    end

    local items = {}
    for _i, minutes in ipairs(FanQiePlugin.PROGRESS_UPLOAD_PRESETS) do
        local value = minutes
        items[#items + 1] = {
            text = value <= 0 and _("关闭") or T(_("每 %1 分钟"), tostring(value)),
            radio = true,
            checked_func = function() return current_minutes() == value end,
            keep_menu_open = true,
            callback = function()
                local sync = self.settings:get("sync", {}) or {}
                sync.upload_interval_minutes = value
                self.settings:set("sync", sync)
                self.settings:flush()
                -- 立刻生效：先停掉旧链，需要的话再挂新的
                self:_stopProgressTimer()
                if value > 0 then
                    self:_ensureProgressTimer()
                end
            end,
        }
    end
    return items
end

--- 设置 → 封面缓存：有效期 + 占用 + 清理。
function FanQiePlugin:getCoverCacheMenuItems()
    local dirs = self:_coverCacheDirs()

    -- 「共 N 张 · X MB」：两个目录合起来算（书架的 covers/ 与书城的 store_covers/）
    local function total_stats()
        local files, bytes = 0, 0
        if CoverCache then
            for _i, d in ipairs(dirs) do
                local st = CoverCache.stats(d)
                files = files + (st.files or 0)
                bytes = bytes + (st.bytes or 0)
            end
        end
        return files, bytes
    end

    local function run(action)
        local removed, freed = 0, 0
        if CoverCache then
            for _i, d in ipairs(dirs) do
                local r = action(d)
                removed = removed + (r.removed or 0)
                freed = freed + (r.bytes or 0)
            end
        end
        return removed, freed
    end

    local items = {}
    items[#items + 1] = {
        text = _("缓存有效期"),
        keep_menu_open = true,
        sub_item_table_func = function()
            local out = {}
            for _i, days in ipairs(CoverCache and CoverCache.DAYS_PRESETS or { 3, 7, 9, 30, 0 }) do
                out[#out + 1] = {
                    text = CoverCache and CoverCache.days_label(days) or tostring(days),
                    checked_func = function()
                        return self.settings:get_cover_cache_days() == days
                    end,
                    keep_menu_open = true,
                    callback = function()
                        self.settings:set_cover_cache_days(days)
                        self:showInfo(T(_("封面缓存有效期已设为 %1"), tostring(days > 0 and (days .. " 天") or _("永久"))))
                    end,
                }
            end
            return out
        end,
    }
    items[#items + 1] = {
        text_func = function()
            local files, bytes = total_stats()
            return T(_("清理过期封面（共 %1 张 · %2）"), tostring(files),
                CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local removed, freed = run(function(d)
                return CoverCache and CoverCache.prune(d, self.settings:get_cover_cache_days())
                    or { removed = 0, bytes = 0 }
            end)
            self:showInfo(T(_("已清理 %1 张，释放 %2"), tostring(removed),
                CoverCache and CoverCache.human_bytes(freed) or tostring(freed)))
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }
    items[#items + 1] = {
        text_func = function()
            local files, bytes = total_stats()
            return T(_("清空封面缓存（%1 张 · %2）"), tostring(files),
                CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local files, bytes = total_stats()
            if files == 0 then
                self:showInfo(_("封面缓存是空的"))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("删除全部封面缓存？共 %1 张（%2）。\n下次打开书架/书城时会重新下载。"),
                    tostring(files), CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes)),
                ok_text = _("删除"),
                ok_callback = function()
                    local removed, freed = run(function(d)
                        return CoverCache and CoverCache.clear(d) or { removed = 0, bytes = 0 }
                    end)
                    self:showInfo(T(_("已清空 %1 张，释放 %2"), tostring(removed),
                        CoverCache and CoverCache.human_bytes(freed) or tostring(freed)))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
    return items
end

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
                -- 统一走 H.prefetch_count（唯一读取口径），不再各处写死 `or 3`
                local count = H.prefetch_count(self.settings)
                if count <= 0 then
                    return _("预下载: 已关闭")
                end
                return T(_("预下载章节数: %1"), tostring(count))
            end,
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getPreDownloadMenuItems()
            end,
        },
        
        {
            text = _("下载图片"),
            checked_func = function()
                local cache = self.settings:get("cache")
                return cache.download_book_images ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local cache = self.settings:get("cache")
                local value = not (cache.download_book_images ~= false)
                -- 走 set_cache_pref：标记「用户显式设置」，config.lua 不覆盖
                if self.settings.set_cache_pref then
                    self.settings:set_cache_pref("download_book_images", value)
                else
                    cache.download_book_images = value
                    self.settings:set("cache", cache)
                    self.settings:flush()
                end
            end,
        },
        {
            text = _("封面缓存"),
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getCoverCacheMenuItems()
            end,
        },
        {
            text = _("段评显示"),
            checked_func = function()
                return _state.isReviewEnabled()
            end,
            keep_menu_open = true,
            callback = function()
                _state.setReviewEnabled(not _state.isReviewEnabled())
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
            text = _("Upload progress on close"),
            help_text = _("离开阅读界面时把最后一次进度补传上去"),
            checked_func = function()
                return self:_uploadOnCloseEnabled()
            end,
            keep_menu_open = true,
            callback = function()
                local sync = self.settings:get("sync", {}) or {}
                sync.upload_on_close = not (sync.upload_on_close ~= false)
                self.settings:set("sync", sync)
                self.settings:flush()
            end,
        },
        {
            text = _("阅读中定期上传进度"),
            help_text = _("读到一半退出 / 掉电也不会丢进度（读到哪传到哪）"),
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getProgressUploadIntervalItems()
            end,
        },
        {
            text = _("重新加载配置文件"),
            keep_menu_open = true,
            callback = function()
                self:loadConfigFile(false, true, true)
            end,
        },
        {
            text = _("扫码登录"),
            keep_menu_open = false,
            callback = function()
                local QRLogin = require("fanqie.qrlogin")
                local qr = QRLogin:new(self.client, self.settings, self)
                qr:start()
            end,
        },
        {
            text = _("退出登录"),
            -- 🔴 字段名必须是 Menu 认的那个：KOReader `Menu:onMenuSelect` 只检查
            --    `item.select_enabled == false` 和 `item.select_enabled_func`，
            --    写 `enabled_func` 等于**没写**（条目照旧可点）。
            select_enabled_func = function()
                return self.settings:is_cookie_configured()
            end,
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("确定退出登录？将清除已保存的 Cookie。"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        self.settings:set("cookies", {})
                        self.settings:flush()
                        self:showInfo(_("已退出登录"))
                    end,
                })
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
                -- 直接用文本查看器打开。
                -- 此前这里先构造了一个 `local fm = FileManager:new{...}`，但 fm 之后再无
                -- 任何引用（下面注释自己都写了 "Simpler approach: show in text viewer"），
                -- 且 dimen 用了一个并不存在的 API（Screen:getDeviceScreenSize），
                -- 属死代码 + 崩溃地雷，故整块移除，只保留真正生效的分支。
                local TextViewer = safe_require("ui/widget/textviewer")
                if TextViewer then
                    UIManager:show(TextViewer:new{
                        title = _("FanQie 插件日志"),
                        text = content,
                    })
                else
                    -- ⚠️ 必须是 T（util.template）而不是 _：`_(fmt, arg)` 里
                    --    gettext 会把第二个参数整个丢掉，用户看到的是字面 `%1`。
                    self:showInfo(T(_("日志已复制到: %1"), tmp_path))
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

-- 预下载章节数选项（0 = 关闭预下载）。
-- 集中在此维护，避免像旧实现那样在 4 个 checked_func + 读取点各写一份 `or 3`：
-- 那种重复一旦某处不同步，用户就会看到「改了没用，一直默认 3」。
function FanQiePlugin:getPreDownloadMenuItems()
    local choices = {
        { value = 0,  text = _("关闭") },
        { value = 1,  text = "1" },
        { value = 3,  text = "3" },
        { value = 5,  text = "5" },
        { value = 10, text = "10" },
        { value = 20, text = "20" },
    }
    local items = {}
    for _, c in ipairs(choices) do
        local value = c.value
        table.insert(items, {
            text = c.text,
            keep_menu_open = true,
            callback = function() self:setPreDownloadCount(value) end,
            checked_func = function()
                local count = H.prefetch_count(self.settings)
                return count == value
            end,
        })
    end
    return items
end

function FanQiePlugin:setPreDownloadCount(n)
    n = math.floor(tonumber(n) or 3)
    if n < 0 then n = 0 end
    -- 走 set_cache_pref：写值 + 标记「用户显式设置」，
    -- 使 config.lua 的同名值不再覆盖菜单里的选择（优先级：菜单 > config > 默认）。
    if self.settings.set_cache_pref then
        self.settings:set_cache_pref("pre_download_chapters", n)
    else
        local cache = self.settings:get("cache")
        cache.pre_download_chapters = n
        self.settings:set("cache", cache)
        self.settings:flush()
    end
    if Log then Log.info("[FanQie] pre_download_chapters =", n) end
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

function FanQiePlugin:loadConfigFile(silent, force, override)
    local plugin_path = self:getPluginPath()
    local config_path = plugin_path .. "/config.lua"
    
    local file = io.open(config_path, "r")
    if not file then return end
    file:close()
    
    local ok, config = pcall(dofile, config_path)
    if not ok or type(config) ~= "table" then return end
    
    pcall(function()
        -- override：显式重载时以 config.lua 为准（含清掉菜单的显式设置标记）。
        -- 启动时的静默加载 override=false，绝不冲掉用户在菜单里的选择。
        self.settings:apply_config(config, {
            apply_preferences = true,
            force = force,
            override_existing = override or false,
        })
    end)
    
    if not silent then
        -- 补入缺失 cookie 时如实报出来：书城搜索只认风控标识 s_v_web_id，而扫码登录
        -- 拿不到它（实测不下发）⇒「把浏览器 Cookie 填进 config.lua」是**唯一**能让
        -- 搜索恢复的路径，用户必须看得见它到底生效了没有。
        local sup = self.settings.cookie_supplemented
        local text = _("config.lua loaded.")
        if type(sup) == "table" and #sup > 0 then
            text = T(_("config.lua loaded.\n已补入本地缺失的 Cookie: %1"),
                table.concat(sup, ", "))
        end
        UIManager:show(InfoMessage:new{
            text = text, timeout = 2,
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



--- 两处封面缓存目录（书架按书名、书城按 book_id）。清理由此统一入口。
function FanQiePlugin:_coverCacheDirs()
    local base = self.settings:get_download_dir()
    return { base .. "/covers", base .. "/store_covers" }
end

--- 「清空书架缓存」的占用统计：shelf_cache.lua（书单文件）+ covers/（书架封面）。
-- 榜单/章节缓存在别处算，这里只算「书架身份」的两块。
function FanQiePlugin:_shelfCacheBytes()
    local bytes = 0
    local base = self.settings:get_download_dir()
    local shelf_file = base .. "/shelf_cache.lua"
    if lfs and H.file_exists(shelf_file) then
        bytes = bytes + (tonumber(lfs.attributes(shelf_file, "size")) or 0)
    end
    if CoverCache then
        local st = CoverCache.stats(base .. "/covers")
        bytes = bytes + (tonumber(st and st.bytes) or 0)
    end
    return bytes
end

--- 「清空书城缓存」的占用统计：store_covers/（书城封面）。
-- 榜单短缓存在内存里（`_store_rank_cache`），不计字节，但清空时一并删。
function FanQiePlugin:_storeCacheBytes()
    if not CoverCache then return 0 end
    local st = CoverCache.stats(self.settings:get_download_dir() .. "/store_covers")
    return tonumber(st and st.bytes) or 0
end

--- 这张封面缓存还能用吗：**存在**且**没过有效期**。
--- ⚠️ 只判 `file_exists` 的话封面一旦落盘就永不失效（书城活动换图后一直显示旧图，
---    而且只增不减）。有效期见 settings 的 `cache.cover_cache_days`（0 = 永久）。
function FanQiePlugin:_coverCacheUsable(path)
    if not (H and H.file_exists(path)) then return false end
    if not CoverCache then return true end
    local days = self.settings.get_cover_cache_days and self.settings:get_cover_cache_days()
    return CoverCache.is_fresh(path, days)
end

function FanQiePlugin:showBookList(books)
    -- 封面缓存每天最多清一次（见 cover_cache.maybe_auto_prune）。放在**建菜单之前**：
    -- 菜单一旦建起来，这一屏的 ImageWidget 就持有具体的封面路径了，那时删文件会画出空白格。
    if CoverCache then
        pcall(CoverCache.maybe_auto_prune, self.settings, self:_coverCacheDirs())
    end
    -- 先关闭旧的书架菜单，避免后台刷新后两个书架 UI 叠在一起
    if self.book_list_menu then
        self:_cancelCoverLoading()
        UIManager:close(self.book_list_menu)
        self.book_list_menu = nil
    end

    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end

    for _, book in ipairs(books) do
        if book.cover then
            local cover_filename = string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
            local cover_path = cover_cache_dir .. "/" .. cover_filename
            -- 过期封面**当没有**处理：下面 _preloadAllCovers 会重下并覆盖同名文件
            if self:_coverCacheUsable(cover_path) then
                book.cover_path = cover_path
            end
        end
    end

    local ShelfView = require("fanqie.shelf_view")
    self._shelf_books = books
    self.book_list_menu = ShelfView.show{
        title = _("番茄书架"),
        books = books,
        show_covers = true,
        -- 刷新后保留搜索关键字；plugin 供排序/搜索对话框读写 settings
        filter_text = self._shelf_opts and self._shelf_opts.filter_text or nil,
        plugin = self,
        on_select = function(book)
            self:_cancelCoverLoading()  -- 进入书籍时停止封面预下载，释放带宽给章节预下载
            self:showBookDetail(book)
        end,
        -- 长按条目：单本书快捷菜单（开始阅读 / 章节目录 / 清空本书缓存），
        -- 不打断「点按 = 打开详情」。README「书架操作」早就承诺了这个菜单。
        on_hold = function(book)
            self:showShelfHoldMenu(book)
        end,
        on_close = function()
            self:_cancelCoverLoading()
            self.book_list_menu = nil
            _state.active_menu = nil
        end,
        on_refresh = function()
            self:showBookshelf({ force_refresh = true })
        end,
        on_page_changed = function(page, first, last, current)
            self:_onShelfPage(current, page, first, last)
        end,
    }
    -- 把菜单上的 opts 也交给插件保存：排序/搜索原地重刷后，关键字要能被下次刷新继承
    if self.book_list_menu and self.book_list_menu._shelf_opts then
        self._shelf_opts = self.book_list_menu._shelf_opts
    end
    _state.active_menu = self.book_list_menu

    -- 后台批量预下载所有未缓存的封面（串行，避免阻塞 UI）
    self:_preloadAllCovers(books)
end

function FanQiePlugin:_cancelCoverLoading()
    self._cover_generation = (tonumber(self._cover_generation) or 0) + 1
    self._cover_preload_generation = (tonumber(self._cover_preload_generation) or 0) + 1
end

-- ⚠️ 页面封面缓存按**当前显示条目**取书（view.item_table[index]），
-- 不能再用 books[index]：书架支持排序与搜索后，显示顺序与 books 下标会错位，
-- 那样会把封面下到别的书上（甚至越界）。
function FanQiePlugin:_onShelfPage(view, page, first, last)
    -- 只取消翻页级的封面下载，不影响 _preloadAllCovers 的全量预下载
    self._cover_generation = (tonumber(self._cover_generation) or 0) + 1
    local generation = self._cover_generation
    self:_cacheShelfPageCovers(view, page, first, last, generation, first)
end

function FanQiePlugin:_cacheShelfPageCovers(view, page, first, last, generation, index)
    index = index or first
    if generation ~= self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1) ~= tonumber(page) then
        return
    end
    if index > last then return end

    local entry = view.item_table and view.item_table[index]
    -- 排序/搜索原地重刷后 item_table 会换新表，优先用条目回指的 book
    local book = (entry and entry.book) or (self._shelf_books and self._shelf_books[index])
    local function next_index()
        UIManager:scheduleIn(0.1, function()
            self:_cacheShelfPageCovers(view, page, first, last, generation, index + 1)
        end)
    end

    if not book or not book.cover or book.cover == "" then
        next_index()
        return
    end

    if book.cover_path then
        next_index()
        return
    end

    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end
    local cover_filename = string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
    local cover_path = cover_cache_dir .. "/" .. cover_filename

    -- 把封面路径回填到当前页 UI（缓存命中与子进程下载完成共用同一段逻辑）
    local function apply_cover(path)
        book.cover_path = path
        local changed = false
        for _, entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id) == tostring(book.book_id or book.bookId) then
                if entry.cover_path ~= path then
                    entry.cover_path = path
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

    if self:_coverCacheUsable(cover_path) then
        apply_cover(cover_path)
        next_index()
        return
    end

    -- 子进程下载封面并写盘，UI 线程零阻塞。
    -- 此前这里是同步的 self.client:get_binary()，翻页时每本书一次阻塞 HTTP + 写盘 → 明显卡顿。
    -- tag 与 _preloadAllCovers 共用 "covers"：页级缓存与全量预下载同属封面链，一并取消。
    local url = book.cover
    local client = self.client
    if not (Async and Async.run) then
        next_index()
        return
    end
    Async.run(function()
        local data = client:get_binary(url)
        local file = io.open(cover_path, "wb")
        if file then
            file:write(data)
            file:close()
            return cover_path
        end
        return nil
    end, function(ok, result, err)
        if generation ~= self._cover_generation or not view or view._miu_closed then return end
        if ok and result then
            apply_cover(result)
        elseif Log then
            Log.debug("page cover download failed:", tostring(book.book_id or book.bookId), tostring(err or result))
        end
        next_index()
    end, { poll_interval = 0.125, timeout = 30, tag = "covers" })
end

-- 后台批量预下载所有未缓存的封面（子进程执行，不阻塞 UI）
-- 使用独立的 _cover_preload_generation，不受翻页取消影响
function FanQiePlugin:_preloadAllCovers(books)
    self._cover_preload_generation = (tonumber(self._cover_preload_generation) or 0) + 1
    local generation = self._cover_preload_generation
    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end
    local view = self.book_list_menu
    local client = self.client

    -- 更新 UI 中指定 book_id 的封面路径
    local function update_ui_cover(book_id, cover_path)
        if not view or view._miu_closed then return end
        local changed = false
        for _, entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id) == tostring(book_id) then
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

    local function preload_one(idx)
        if generation ~= self._cover_preload_generation then return end
        if not view or view._miu_closed then return end
        if idx > #books then return end

        local book = books[idx]
        if not book or not book.cover or book.cover == "" then
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
            return
        end

        -- 已有缓存路径，跳过
        if book.cover_path then
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
            return
        end

        local cover_filename = string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
        local cover_path = cover_cache_dir .. "/" .. cover_filename
        local book_id = book.book_id or book.bookId

        -- 文件已存在且未过期，设置路径并更新 UI（过期就往下走重下）
        if self:_coverCacheUsable(cover_path) then
            book.cover_path = cover_path
            update_ui_cover(book_id, cover_path)
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
            return
        end

        -- 子进程下载封面并写入文件，UI 线程零阻塞
        local url = book.cover
        Async.run(function()
            -- fork 继承 client/settings，子进程内同步下载并写文件
            local data = client:get_binary(url)
            local file = io.open(cover_path, "wb")
            if file then
                file:write(data)
                file:close()
                return { path = cover_path, book_id = tostring(book_id) }
            end
            return nil
        end, function(ok, result, err)
            if generation ~= self._cover_preload_generation then return end
            if ok and result and result.path then
                book.cover_path = result.path
                update_ui_cover(result.book_id, result.path)
            end
            -- 继续下一本（子进程已退出，无残留资源）
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
        end, { poll_interval = 0.125, timeout = 30, tag = "covers" })
    end

    -- 延迟启动，给书架 UI 渲染让出时间
    UIManager:scheduleIn(0.5, function() preload_one(1) end)
end

-- ===========================================================================
-- 书籍详情（书架 / 书城共用）
-- ===========================================================================
-- 🔴 ButtonDialog **没有 `info_text` 字段**（KOREADER 上游事实，见
--    MEMORY-koreader-core「上游组件事实」）：`init()` 只渲染 `self.title`
--    与 `self._added_widgets`，传进去的 `info_text` 被**静默丢弃**
--    ⇒ 以前的书架/书城详情框里其实**一行书目信息都没显示**，用户只看到按钮。
--    所以：短摘要写进 `title`，长内容（简介全文）走「简介」按钮打开的可滚动页面。
--
-- 字段来源（v2.12.0）：书架接口（add_shelf_time/last_operate_time/asterisked）
--   + 详情接口 multidetail（书名/简介/总章数/更新状态/章节摘要）
--   + 阅读进度接口（item_id/index/read_timestamp）
-- 合并与格式化全在 fanqie/book_detail.lua（纯函数），本文件只负责摆按钮。

--- 阅读界面「书籍信息」：显示**当前正在读的这本番茄书**的详情（v2.17.0）。
--
-- 数据的取用按可靠性依次退让，**全程零网络**：
--   1. `_state.current_book` —— 从书架 / 书城打开时是完整记录；
--   2. `getCurrentBook()` —— 文档路径反推的书号（重启后从「最近阅读 /
--      文件管理器」直接打开章节续读时，这是唯一的书号来源）；
--   3. `findCachedBook()` —— 用**本地**书架缓存（内存缓存或 shelf_cache.lua）
--      把书名 / 作者 / 简介 / 进度补齐，和 ensureShelfSnapshot 同源，不发包。
--
-- 🔴 为什么不在第 3 步之后再去联网查一次详情：这个入口在阅读界面的菜单里，
--    菜单项的 callback 一旦阻塞在网络往返上，用户看到的就是「点了没反应」。
--    本地能补多少补多少，补不到就明说。
function FanQiePlugin:showCurrentBookInfo()
    local book = _state.current_book
    if type(book) ~= "table" or not book.book_id then
        local minimal = self:getCurrentBook()
        book = minimal
        if type(minimal) == "table" and minimal.book_id
            and type(self.findCachedBook) == "function" then
            local ok, found = pcall(self.findCachedBook, self, minimal.book_id)
            if ok and type(found) == "table" then
                book = found
            end
        end
    end
    if type(book) ~= "table" or not book.book_id then
        self:showInfo(_("无法确定当前书籍"))
        return
    end
    if not (book.title or book.book_name) then
        -- 本地也补不到（首次打开、书架缓存还没落盘）：把书号说出来，
        -- 好过弹一句干巴巴的「暂无书籍信息」。
        self:showInfo(T(_("暂无书籍信息（书号 %1）"), tostring(book.book_id)))
        return
    end
    self:showBookDetailPage(book, {})
end

--- 关闭「书籍详情」整页（唯一入口，避免连点叠两页）。
function FanQiePlugin:closeBookDetailPage()
    local page = self._book_detail_page
    self._book_detail_page = nil
    if page then H.close_widget(page) end
end

--- 打开「书籍详情」整页：简介全文 + 合并出来的全部字段（可滚动）。
---@param book table
---@param opts table|nil { on_read = function|nil }
function FanQiePlugin:showBookDetailPage(book, opts)
    opts = opts or {}
    if type(book) ~= "table" then return end
    if not BookDetail then
        self:showInfo(_("书籍详情组件不可用"))
        return
    end
    self:closeBookDetailPage()
    local cached = Content.load_cache_index(self.settings, book.book_id)
    local cache_count = 0
    for _ in pairs(cached) do cache_count = cache_count + 1 end
    local lines = BookDetail.lines(book, { cache_count = cache_count })
    if #lines == 0 then lines = { _("暂无书籍信息") } end
    local text = table.concat(lines, "\n")

    if not TextViewer then
        self:showInfo(text)
        return
    end
    local buttons = {}
    if opts.on_read then
        buttons[#buttons + 1] = { {
            text = _("开始阅读"),
            callback = function()
                self:closeBookDetailPage()
                opts.on_read()
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("关闭"),
        callback = function() self:closeBookDetailPage() end,
    } }
    local page = TextViewer:new{
        title = tostring(book.title or book.book_name or _("书籍详情")),
        text = text,
        text_type = "book_info",
        justified = false,
        buttons_table = buttons,
        close_callback = function() self._book_detail_page = nil end,
    }
    self._book_detail_page = page
    UIManager:show(page)
end

--- 组装「书籍详情」按钮框（书架 / 书城共用）。
-- ⚠️ 一律走 `title` 显示摘要：`info_text` 是死键（见本节开头）。
--@param book table
--@param opts table {
--         on_shelf  = boolean|nil,  -- true=在书架（给「移出书架」）/ false=不在（给「加入书架」）/ nil=未知（不给书架按钮）
--         on_leave  = function|nil,  -- 「开始阅读 / 章节目录」之前的收尾（书城要顺手关掉书城菜单）
--         cache_ok  = boolean,       -- 是否给「清空本书缓存」（书架记录才有本地缓存概念）
--         now       = number|nil,    -- 注入的「当前时间」（测试用）
--       }
function FanQiePlugin:buildBookDetailDialog(book, opts)
    opts = opts or {}
    if type(book) ~= "table" then return nil end
    self:_closeDetailDialog()

    local cached = Content.load_cache_index(self.settings, book.book_id)
    local cache_count = 0
    for _ in pairs(cached) do cache_count = cache_count + 1 end

    local function leave()
        if opts.on_leave then pcall(opts.on_leave) end
    end

    local rows = {}

    -- 第 1 行：简介（整页）/ 开始阅读
    local row1 = {
        {
            text = _("简介"),
            callback = function()
                self:showBookDetailPage(book, { on_read = function()
                    self:_closeDetailDialog()
                    leave()
                    self:openBook(book)
                end })
            end,
        },
        {
            text = _("开始阅读"),
            callback = function()
                self:closeBookDetailPage()
                self:_closeDetailDialog()
                if _state.active_menu then
                    local menu = _state.active_menu
                    _state.active_menu = nil
                    H.close_widget(menu)
                end
                leave()
                self:openBook(book)
            end,
        },
    }
    rows[#rows + 1] = row1

    -- 第 2 行：章节目录 / 下载
    rows[#rows + 1] = {
        {
            text = _("章节目录"),
            callback = function()
                self:closeBookDetailPage()
                self:_closeDetailDialog()
                if _state.active_menu then
                    local menu = _state.active_menu
                    _state.active_menu = nil
                    H.close_widget(menu)
                end
                leave()
                self:showChapterListing(book)
            end,
        },
        {
            text = _("下载"),
            callback = function()
                self:closeBookDetailPage()
                self:_closeDetailDialog()
                -- 保留 active_menu（书架），后台运行关闭下载进度对话框后可回到书架
                -- 避免 UIManager 无 widget 导致 KOReader 退出
                self:_startBookDownload(book)
            end,
        },
    }

    -- 第 3 行：书架动作（**单颗**：由 shelf_check 判定后只给一个方向）。
    -- delete 是幂等的（不在书架也回成功）⇒ 两颗按钮一起给必然出现
    -- 「点「移出书架」→ 提示已移出书架」这种谎报，见 store_ui 的收敛说明。
    if opts.on_shelf ~= nil and type(self.toggleStoreShelf) == "function" then
        local want_add = (opts.on_shelf ~= true)
        rows[#rows + 1] = { {
            text = want_add and _("加入书架") or _("移出书架"),
            callback = function()
                self:closeBookDetailPage()
                self:_closeDetailDialog()
                self:toggleStoreShelf(book, want_add, opts.on_shelf_changed)
            end,
        } }
    end

    -- 第 4 行：清空缓存（仅书架记录）
    if opts.cache_ok ~= false and cache_count > 0 then
        rows[#rows + 1] = { {
            text = _("清空本书缓存"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("确定清空《%1》的缓存?\n%2 章节将被删除。"),
                        book.title or book.book_name or _("未知"), cache_count),
                    ok_text = _("清空"),
                    cancel_text = _("取消"),
                    ok_callback = function()
                        self.settings:clear_book_cache(book.book_id)
                        self:_closeDetailDialog()
                        UIManager:show(InfoMessage:new{ text = _("缓存已清空") })
                    end,
                })
            end,
        } }
    end

    rows[#rows + 1] = { {
        text = _("关闭"),
        callback = function()
            self:closeBookDetailPage()
            self:_closeDetailDialog()
        end,
    } }

    local ButtonDialog = require("ui/widget/buttondialog")
    local title = BookDetail and BookDetail.summary_title(book, { now = opts.now })
        or tostring(book.title or book.book_name or _("书籍详情"))
    if cache_count > 0 then
        title = title .. T(_(" · 缓存 %1 章"), tostring(cache_count))
    end
    _state.detail_dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(_state.detail_dialog)
    return _state.detail_dialog
end

--- 阅读界面：「加入 / 移出书架」当前这本书。
-- 🔴 必须先 `shelf_check` 再决定方向：`bookshelf/delete` 是**幂等**的
--    （不在书架也回 `{"code":0,"message":"SUCCESS"}`），不问就删会谎报
--    「已移出书架」；不问就加则可能重复加。判据只有一句：
--    `code == 0 and data == 1` = 在书架（39 字节，见 fanqie/fanqie.lua 的
--    shelf_check_url 注释与 .workbuddy/tools/_probe_shelf_check*.py）。
-- 移出是破坏性动作 ⇒ 给一次确认；加入直接做（可逆、无副作用）。
function FanQiePlugin:toggleCurrentBookShelf()
    -- 走 getCurrentBook()：内存里没有就从文档路径反推（重启续读场景）。
    local book = self:getCurrentBook()
    if type(book) ~= "table" or not book.book_id then
        self:showInfo(_("无书籍信息"))
        return
    end
    if not (Store and Store.shelf_check) then
        self:showInfo(_("书城组件不可用"))
        return
    end
    if not self:checkNetwork() then return end
    local book_id = tostring(book.book_id)
    local client = self.client

    self:showBusy(_("正在查询书架状态…"))
    Async.run(function()
        -- 括号：Async 只回传第一个返回值，显式丢弃 err（失败时首值是 nil）
        return { on_shelf = (Store.shelf_check(client, book_id)) }
    end, function(ok, res)
        self:closeBusy()
        -- 🔴 不能写 `(ok and type(res) == "table") and res.on_shelf or nil`：
        --    Lua 的 `and/or` 链在**左值求值为 false** 时会掉进 `or nil`
        --    ⇒「不在书架」（on_shelf = false）被读成 nil ⇒ 误报「查询失败」，
        --      于是「加入书架」这条路径**永远走不到**（回归 G4 抓到）。
        --    必须显式判类型，别用 `or` 兜底布尔。store_ui.lua 的同名判断就是这个写法。
        local on_shelf
        if ok and type(res) == "table" and type(res.on_shelf) == "boolean" then
            on_shelf = res.on_shelf
        end
        if type(on_shelf) ~= "boolean" then
            self:showError(_("查询书架状态失败，请检查网络与 Cookie"))
            return
        end
        -- 这次查询就是一份确定结论 ⇒ 写进书架快照：菜单文案下一次打开即正确，
        -- 而且「退出阅读时是否提示加入书架」也就不用再查一遍（见 state.lua）。
        if _state and _state.markShelf then _state.markShelf(book_id, on_shelf) end
        if not on_shelf then
            if type(self.toggleStoreShelf) == "function" then
                self:toggleStoreShelf(book, true)
            else
                self:showInfo(_("书城组件不可用"))
            end
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("《%1》已在书架中，确定要移出吗？"),
                tostring(book.title or book.book_name or _("未知"))),
            ok_text = _("移出"),
            cancel_text = _("取消"),
            ok_callback = function()
                if type(self.toggleStoreShelf) == "function" then
                    self:toggleStoreShelf(book, false)
                end
            end,
        })
    end, {
        poll_interval = 0.3,
        timeout = 30,
        tag = "shelf_state",
        -- 取消后回调不执行：loading 必须在这里自己关
        on_cancel = function() pcall(function() self:closeBusy() end) end,
    })
end

--- 离开这本书时：若它**不在书架**，问一次「是否加入书架」。
--
-- 🔴 三个必须守住的边界（每一条都对应一个会真的踩到的场景）：
--
--    ① **切章也会走到这里**。调用点 `onCloseDocument` 在切章时同样触发
--       （`ReaderUI:doShowReader` 会先 `ReaderUI.instance:onClose()`）。
--       判据是「延后一拍看 `ReaderUI.instance` 是否还在」——
--       切章/换书路径在**同一个同步块**里就把新实例 `UIManager:show` 出去了
--       （中间不 yield），所以 nextTick 回调跑时 instance 已存在；而真退出
--       （onHome / 关闭阅读）走到 `ReaderUI.onCloseWidget`，那里把 instance 置 nil。
--       ⇒ 只有 instance 为 nil 才认为「用户真的离开了这本书」。
--
--    ② **不能每次退出都问**。同一本书读过 5 次被问 5 次谁受得了 ——
--       按书号记「已问过」（`_state.shelf_prompted`）。这是**进程内**节流，
--       刻意不落盘：重启后重问一次的代价，远小于为此多维护一份持久化状态。
--
--    ③ **「未知」不等于「不在架」**。冷启动续读时快照可能还是未知（用户从没读过
--       书架列表）。此时**不能**凭猜测弹「加入书架」—— 在架的书会被问错方向。
--       所以：先同步补一次本地书架缓存（`ensureShelfSnapshot`，零网络），
--       还未知才发一次 `shelf_check`（39 B）；连查都查不到（离线）就静默放弃。
--       **不能确定方向，就不要打扰用户**。
function FanQiePlugin:_promptAddShelfOnLeave()
    local book = self:getCurrentBook()
    if type(book) ~= "table" or not book.book_id then return end
    if not (_state and type(_state.shelfState) == "function") then return end
    local book_id = tostring(book.book_id)
    _state.shelf_prompted = _state.shelf_prompted or {}
    if _state.shelf_prompted[book_id] then return end

    local self_ref = self

    local function ask(on_shelf)
        if on_shelf ~= false then return end   -- 在架 / 仍未知 ⇒ 不打扰
        -- 不论用户怎么选都记「问过」：点「不用了」就不该再被问第二次。
        _state.shelf_prompted[book_id] = true
        local title = tostring(book.title or book.book_name or book_id)
        UIManager:show(ConfirmBox:new{
            text = T(_("《%1》还没加入书架，要加入吗？"), title),
            ok_text = _("加入书架"),
            cancel_text = _("不用了"),
            ok_callback = function()
                if type(self_ref.toggleStoreShelf) == "function" then
                    -- 复用书城那条路径：它会 showBusy / 写快照 / 失效书架缓存
                    self_ref:toggleStoreShelf({ book_id = book_id, title = title }, true)
                end
            end,
        })
    end

    -- 「真的离开了阅读」：切章 / 换书时 instance 还在（见边界 ①）。
    local function left_reading()
        local ok_rui, RUI = pcall(require, "apps/reader/readerui")
        if ok_rui and RUI and RUI.instance then return false end
        return true
    end

    -- 未知 ⇒ 先同步补本地缓存（内存 → 文件，绝不联网），能补上就省一次请求。
    if _state.shelfState(book_id) == nil and type(self.ensureShelfSnapshot) == "function" then
        pcall(function() self:ensureShelfSnapshot() end)
    end
    local known = _state.shelfState(book_id)

    if known ~= nil then
        -- 已有确定结论：只等一拍确认「真的离开了阅读」。
        UIManager:nextTick(function()
            if left_reading() then ask(known) end
        end)
        return
    end

    -- 还是未知：等一拍确认离开阅读后，查一次（39 B），查到才问。
    UIManager:nextTick(function()
        if not left_reading() then return end
        if not (Store and Store.shelf_check) then return end
        if not self_ref:checkNetwork() then return end
        local client = self_ref.client
        Async.run(function()
            -- 括号：Async 只回传第一个返回值，显式丢弃 err（失败时首值是 nil）
            return { on_shelf = (Store.shelf_check(client, book_id)) }
        end, function(ok, res)
            local on_shelf
            if ok and type(res) == "table" and type(res.on_shelf) == "boolean" then
                on_shelf = res.on_shelf
                -- 结论写进快照：下次（同一次运行内）就不用再查了
                if _state.markShelf then _state.markShelf(book_id, on_shelf) end
            end
            ask(on_shelf)
        end, {
            poll_interval = 0.3,
            timeout = 15,
            -- 独立 tag：别让切章/关菜单的 cancel_tag 把这次查询掐掉
            tag = "shelf_prompt",
        })
    end)
end

-- 书籍详情对话框的**唯一**关闭入口。
-- 顺序很重要：先把 _state.detail_dialog 置 nil，再关那个对象。
--   · 置 nil 让所有「稍后再收尾」的路径（onClose / onCloseWidget / 菜单关闭回调）
--     都不会再碰它；
--   · H.close_widget 只在它**确实还在 UIManager 栈上**时才真关。
-- 这两点缺一不可：直接 `UIManager:close(已经关过的 dialog)` 会照常派发
-- CloseWidget 事件 → ButtonDialog:onCloseWidget 给自己排一次 flashui 全刷 →
-- 墨水屏上表现成「弹窗凭空闪一下」（而且刷新请求会挂到下一次翻页/切章才爆出来）。
function FanQiePlugin:_closeDetailDialog()
    local dialog = _state.detail_dialog
    _state.detail_dialog = nil
    if dialog then H.close_widget(dialog) end
end

function FanQiePlugin:showBookDetail(book)
    if type(book) ~= "table" then return end
    -- 书架记录**本来就来自书架**（fetch_shelf_detail 拉回来的）⇒ 必定在架。
    -- 这里不再打 shelf_check（39 B）：它确实很快，但每点一本书都要闪一次
    -- loading；而唯一会「过期」的场景是「别的设备把它移出了书架」，此时
    -- 「移出书架」本身是幂等的，不会误伤任何东西。
    -- 书城那条路（StoreUI.showStoreBookDetail）才必须查 —— 见那里的收敛说明。
    self:buildBookDetailDialog(book, {
        on_shelf = true,
        cache_ok = true,
    })
end

--- 长按书架条目：单本书快捷菜单（开始阅读 / 章节目录 / 清空本书缓存）。
-- README「书架操作」从早期版本就承诺了「长按书籍：显示操作菜单（开始阅读、
-- 章节目录、清空缓存）」，但代码一直没接 `on_hold` —— 本方法补齐该承诺。
-- 「清空本书缓存」与「书籍详情 → 清空本书缓存」走同一条清理路径
-- （settings.clear_book_cache），区别在入口更快、且无缓存时给明确提示。
function FanQiePlugin:showShelfHoldMenu(book)
    if type(book) ~= "table" or not book.book_id then return end
    local title = tostring(book.title or book.book_name or _("未知"))
    local dialog -- 先声明后赋值：下面的闭包要捕获这个 upvalue

    -- 打开别的界面之前必须把本菜单 + 书架菜单都关掉，否则书架叠在阅读界面底下
    --（与「书籍详情 → 开始阅读」同一套收尾；book_list_menu 也要同步置 nil，
    --  否则 on_close 再触发一次会拿到已关闭的菜单）
    local function dismiss_self()
        H.close_widget(dialog)
        if _state.active_menu then
            local menu = _state.active_menu
            _state.active_menu = nil
            H.close_widget(menu)
            if self.book_list_menu == menu then self.book_list_menu = nil end
        end
    end

    local cached = Content.load_cache_index(self.settings, book.book_id)
    local cache_count = 0
    if type(cached) == "table" then
        for _ in pairs(cached) do cache_count = cache_count + 1 end
    end

    local rows = {}
    rows[#rows + 1] = { {
        text = _("开始阅读"),
        callback = function()
            dismiss_self()
            self:openBook(book)
        end,
    } }
    rows[#rows + 1] = { {
        text = _("章节目录"),
        callback = function()
            dismiss_self()
            self:showChapterListing(book)
        end,
    } }
    rows[#rows + 1] = { {
        text = cache_count > 0
            and T(_("清空本书缓存（%1 章）"), tostring(cache_count))
            or _("清空本书缓存"),
        callback = function()
            if cache_count <= 0 then
                self:showInfo(T(_("《%1》没有本地章节缓存"), title))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("确定清空《%1》的缓存?\n%2 章节将被删除。"), title, tostring(cache_count)),
                ok_text = _("清空"),
                cancel_text = _("取消"),
                ok_callback = function()
                    self.settings:clear_book_cache(book.book_id)
                    self:showInfo(T(_("已清空《%1》的 %2 章缓存"), title, tostring(cache_count)))
                end,
            })
        end,
    } }
    rows[#rows + 1] = { {
        text = _("关闭"),
        callback = function()
            H.close_widget(dialog)
        end,
    } }

    local ButtonDialog = require("ui/widget/buttondialog")
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(dialog)
end
-- 异步获取目录后打开下载对话框
function FanQiePlugin:_startBookDownload(book)
    local self_ref = self
    local book_id = book.book_id
    local Async_mod = Async

    self:showBusy(_("正在获取目录..."))

    local function fetch_and_show()
        if Async_mod and Async_mod.run then
            Async_mod.run(function()
                return self_ref:get_chapters(book_id)
            end, function(ok, chapters, err)
                self_ref:closeBusy()
                if not ok or type(chapters) ~= "table" then
                    if Log then Log.error("fetch chapters failed:", log_error(err or chapters)) end
                    self_ref:showError(T(_("获取目录失败:\n%1"), display_error(err or chapters)))
                    return
                end
                -- 检查已缓存章节数量
                local cached_map = Content.load_cache_index(self_ref.settings, book_id) or {}
                local cached_count = 0
                for _ in pairs(cached_map) do cached_count = cached_count + 1 end
                require("fanqie.download").showOptionsDialog(self_ref, book, chapters, {
                    cached_count = cached_count,
                })
            end, {
                poll_interval = 0.3, timeout = 60,
                tag = "book_detail",
                -- 取消后 on_done 不执行：busy 必须在这里关掉。
                on_cancel = function() self_ref:closeBusy() end,
            })
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
            local cached_map = Content.load_cache_index(self.settings, book_id) or {}
            local cached_count = 0
            for _ in pairs(cached_map) do cached_count = cached_count + 1 end
            require("fanqie.download").showOptionsDialog(self, book, chapters, {
                cached_count = cached_count,
            })
        end
    end

    -- 有缓存目录时先显示，后台刷新
    local cached_catalog = Content.load_catalog_cache(self.settings, book_id)
    if cached_catalog and #cached_catalog > 0 then
        fetch_and_show()
    else
        fetch_and_show()
    end
end

-- ===========================================================================
-- Chapter listing
-- ===========================================================================

function FanQiePlugin:showChapterListing(book, opts)
    opts = opts or {}
    local force_refresh = opts.force_refresh == true
    -- remember_page: keep the user on the same page after a refresh
    local remember_page = opts.remember_page

    -- 构建并显示目录菜单（缓存命中与异步获取共用）
    local function display_chapters(chapters)
        if not chapters or #chapters == 0 then
            self:showInfo(_("未获取到章节"))
            return
        end

        _state.current_book = book
        _state.current_chapters = chapters

        -- 刷新内存缓存：预下载可能已更新文件但内存缓存未同步，
        -- 强制重新从文件加载确保目录对号准确
        _state.invalidateChapterIndexCache(book.book_id)
        local cached = Content.load_cache_index(self.settings, book.book_id)
        local current_idx = getCurrentChapterIndex()

        -- current_chapter_index 已在切章时正确更新，优先使用。
        -- 仅当 current_chapter_index 无效（首次打开/未设置）时，
        -- 才用 book.item_id（书架记录的上次阅读章节）回退定位。
        if (not current_idx or current_idx <= 0) and book.item_id then
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
                    -- 先关闭目录菜单，避免切章时菜单闪现
                    if _state.active_menu then
                        UIManager:close(_state.active_menu)
                        _state.active_menu = nil
                    end
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
        -- 🔴 必须先单独声明再赋值。`local chapter_menu = Menu:new{...}` 是**单条语句**，
        -- 其 local 作用域从语句*之后*才开始，因此 close_callback 闭包里引用的
        -- chapter_menu 会解析到全局 nil：`_state.active_menu == chapter_menu`
        -- 恒不成立（等于拿菜单去和 nil 比），关闭目录后 active_menu 永不清空。
        local chapter_menu
        chapter_menu = Menu:new{
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

    -- 缓存命中：直接显示，不走网络
    if chapters and #chapters > 0 then
        display_chapters(chapters)
        return
    end

    -- 无缓存或强制刷新：子进程获取目录，UI 线程保持响应（不再卡顿）
    if not self:checkNetwork() then
        -- force_refresh 无网时回退到旧缓存
        if force_refresh then
            local cached = Content.load_catalog_cache(self.settings, book.book_id)
            if cached and #cached > 0 then
                display_chapters(cached)
                self:showInfo(_("无网络，显示缓存目录"))
                return
            end
        end
        return
    end
    self:showBusy(_("正在获取目录..."))
    local client = self.client
    local settings = self.settings
    local book_id = book.book_id
    Async.run(function()
        -- 子进程内执行 HTTP 目录获取
        local b = { book_id = book_id }
        return Content.fetch_catalog(client, b)
    end, function(ok, result, err)
        self:closeBusy()
        if not ok or type(result) ~= "table" then
            -- 获取失败：回退到旧缓存，不删除任何数据
            if force_refresh then
                local cached = Content.load_catalog_cache(settings, book.book_id)
                if cached and #cached > 0 then
                    display_chapters(cached)
                    self:showInfo(_("刷新失败，显示缓存目录"))
                    return
                end
            end
            self:showError(T(_("获取目录失败:\n%1"), display_error(err or result)))
            return
        end
        local fetched = result
        if #fetched == 0 then
            -- 空结果可能是 cookie 过期，回退到旧缓存
            if force_refresh then
                local cached = Content.load_catalog_cache(settings, book.book_id)
                if cached and #cached > 0 then
                    display_chapters(cached)
                    self:showInfo(_("获取数据为空，显示缓存目录"))
                    return
                end
            end
            self:showInfo(_("未获取到章节"))
            return
        end

        -- 获取成功：覆盖旧缓存
        Content.save_catalog_cache(settings, book_id, fetched)
        -- 同时更新内存缓存
        _state.setDirectoryCache(book_id, fetched)

        display_chapters(fetched)
    end, { poll_interval = 0.3, timeout = 60 })
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

--- 章节下载的**心跳文件**路径（每本书一个，Async 结束时自动删掉）。
---
--- 为什么需要：图集/漫画（`book_type == 1`）一章的正文就是几十张整页大图
--- （实测《未知生物大百科》：单章 22~49 页、每页 1440×2559 约 400 KB），
--- 整章下完要 1~5 分钟。而 `Async.run` 的 `timeout` 到点会
--- `terminateSubProcess` **杀掉子进程** ⇒ 用户看到「下载超时」，已下好的几十页全丢。
--- 子进程每下完一张就把「已下载/总数」写进这个文件，父进程据此续期
--- （fanqie/async.lua 的 `opts.heartbeat`）——「只要还在下载就不算超时」，
--- 而真正卡死（长时间一张都没落盘）仍然会被掐掉。
function FanQiePlugin:_downloadHeartbeatPath(book)
    local dir = Content.book_cache_dir(self.settings, book.book_id)
    H.make_dir(dir)   -- 心跳可能是本章**第一个**写盘的操作
    return H.join_path(dir, "._dlbeat")
end

function FanQiePlugin:navigateToChapter(book, chapters, chapter_index, opts)
    opts = opts or {}
    local chapter = chapters[chapter_index]
    if not chapter then
        self:showInfo(_("章节不存在"))
        return false
    end

    -- 标记章节切换中：防止段评异步回调在切章后弹窗闪现
    _state.setChapterNavigating(true)

    if _state.is_downloading then
        -- 正在下载其它章节：给用户明确提示，而不是静默失败
        _state.setChapterNavigating(false)
        self:showInfo(_("正在下载中，请稍候再试"))
        return false
    end

    _state.current_book = book
    _state.current_chapters = chapters

    -- 从全局状态获取段评开关，传递 review=true 给内容获取
    -- skip_cache_index=true：子进程不写共享索引，由父进程统一持久化
    local review_enabled = _state.isReviewEnabled()
    -- heartbeat_path：下载心跳（见 fanqie/async.lua 的 opts.heartbeat）。
    -- 图集/漫画一章几十页大图，整章下载要几分钟 —— 有心跳才不会因为「总时长」
    -- 被 Async 掐掉、白丢已经下好的几十页。
    local fetch_opts = {
        skip_cache_index = true,
        heartbeat_path = self:_downloadHeartbeatPath(book),
    }
    if review_enabled then fetch_opts.review = true end

    local item_id = tostring(chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]

    -- 已缓存正文直接使用：段评数据缺失不触发重下（有些章节本就无段评）。
    -- 想要段评的用户可通过「重新获取本章节」手动重下（按当前段评开关决定是否带段评）。

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
    -- 图集/漫画（book_type=1）一章就是几十张整页大图，光下载就得几分钟 ——
    -- 文案里先说一声，免得用户当成卡死。真卡死仍会被 Async 的停滞超时掐掉
    -- （只要还有图在落盘，心跳就会给超时续期，见 fanqie/async.lua）。
    -- 🔴 用 tonumber：书城/书架接口给的 book_type 是**字符串** "1"（实测）。
    local comic = tonumber(book.book_type) == 1
    if comic then
        self:showBusy(T(_("正在下载图集: %1\n（整章为多页大图，请稍候）"), chapter.title or ""))
    else
        self:showBusy(T(_("正在下载: %1"), chapter.title or ""))
    end

    local b = { book_id = book.book_id, title = book.title, author = book.author }
    local client = self.client
    local settings = self.settings
    -- 段评获取与章节正文下载一起在子进程执行，UI 线程仅轮询，不再卡顿
    Async.run(function()
        local path, _ch, para_reviews = Content.fetch_chapter_html(client, settings, b, chapter, fetch_opts)
        return { path = path, para_reviews = para_reviews }
    end, function(ok, result, err)
        self:closeBusy()

        if not ok or type(result) ~= "table" or not result.path then
            Log.error("navigateToChapter download failed:", tostring(err or result))
            _state.is_downloading = false
            _state.setChapterNavigating(false)
            self:showError(T(_(opts.error_message or "下载章节失败:\n%1"), display_error(err or result)))
            return
        end


        local path = result.path
        local para_reviews = result.para_reviews

        local cc = getCachedChapters(self, book)
        cc[item_id] = path
        -- 父进程统一持久化完整索引
        Content.save_cache_index(settings, book.book_id, cc)

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
    end, { delay = 0.1, poll_interval = 0.2,
           -- 停滞上限（有心跳时掐的不是总时长，见 fanqie/async.lua）：
           -- 图集单页 ~570KB，慢网下单次请求就可能逼近 socket 超时，给 180s 余量。
           timeout = comic and 180 or 60,
           heartbeat = fetch_opts.heartbeat_path,
           -- 「正在下载图集…（第 N/M 页）」：没有它用户分不清在下还是卡死
           on_heartbeat = make_page_heartbeat(self, chapter, comic) })

    return true
end

function FanQiePlugin:openChapter(book, chapters, chapter_index)
    return self:navigateToChapter(book, chapters, chapter_index, {
        error_message = "下载章节失败:\n%1",
    })
end

function FanQiePlugin:showReaderUI(path, chapter)
    local ReaderUI = require("apps/reader/readerui")

    -- 章节切换已完成（新文档即将加载），清除导航标志
    _state.setChapterNavigating(false)

    local ok, err = pcall(function()
        -- 不用 switchDocument（其内部先 onClose 再 showReader，中间 forceRePaint 会闪现书架）
        -- 直接用 showReader：doShowReader 在 nextTick 中关闭旧实例并打开新实例，无闪现
        if not ReaderUI.instance then
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
        end
        ReaderUI:showReader(path, nil, true)  -- seamless=true 隐藏"打开文件"提示
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
                -- 上次退出时没传完的进度（pending 落过盘）在这里补一发；
                -- 否则要等用户翻到章末 / 关文档才会重试。没有待传项时是空转。
                self:retryPendingProgress()
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
    -- 唯一读取口径（helper.prefetch_count）；0 = 关闭预下载
    local pre_download_count = H.prefetch_count(self.settings)
    local total = #chapters

    if current_index >= total then
        _state.pre_download_triggered = false
        return
    end
    if pre_download_count <= 0 then
        -- 关闭预下载：清标志，避免 onPageUpdate 里反复进入本函数
        _state.pre_download_triggered = false
        if Log then Log.info("[FanQie] pre-download disabled (pre_download_chapters=0)") end
        return
    end

    -- 段评模式：预下载也传递 review=true；skip_cache_index 由父进程统一持久化索引
    local review_enabled = _state.isReviewEnabled()
    -- heartbeat_path：见 _downloadHeartbeatPath 的注释（图集/漫画整章下载不能被
    -- 「总时长」超时掐掉，只要还有图在落盘就续期）。
    local fetch_opts = {
        skip_cache_index = true,
        heartbeat_path = self:_downloadHeartbeatPath(book),
    }
    if review_enabled then fetch_opts.review = true end

    local cached_chapters = getCachedChapters(self, book)
    local client = self.client
    local settings = self.settings
    -- 本次批量里「真正发过请求」的章节数：只有它参与批量休息计数
    -- （跳过缓存的章节不发请求，不该占用节流额度）。
    local processed = 0

    if Log then
        Log.info("[FanQie] pre-download start: count=" .. tostring(pre_download_count)
            .. " from=" .. tostring(current_index) .. "/" .. tostring(total)
            .. " review=" .. tostring(review_enabled))
    end

    -- 顺序下载：每章在子进程执行（HTTP + 图片下载 + 落盘均在子进程），
    -- 父进程 UI 线程只做轻量轮询，不再因预下载卡顿阅读。
    local function download_one(offset)
        if _state.is_downloading then
            -- 用户正在主动下载章节，稍后重试
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
        -- 已缓存正文直接跳过：段评数据缺失不触发重下

        if already_cached then
            Log.debug("pre-download: chapter", target_idx, "already cached")
            UIManager:scheduleIn(0, function() download_one(offset + 1) end)
            return
        end

        Log.info("pre-download: starting download for chapter", target_idx)
        local b = { book_id = book.book_id, title = book.title, author = book.author }
        -- 置 is_downloading：让 onEndOfBook/navigateToChapter 感知预下载进行中，
        -- 避免与它们重复下载同一章；on_done 中先清零再调度下一章。
        _state.is_downloading = true
        Async.run(function()
            -- 子进程内执行：抓取正文 + 段评 + 图片下载 + 保存 HTML
            -- skip_cache_index=true，不写共享 cache_index.lua（由父进程统一持久化）
            local path = Content.fetch_chapter_html(client, settings, b, chapter, fetch_opts)
            return { path = path }
        end, function(ok, result, err)
            -- 先清零，确保调度下一章时 download_one 不会被自己卡住
            _state.is_downloading = false
            local path = type(result) == "table" and result.path or nil
            if ok and path then
                cached_chapters[item_id] = path
                -- 父进程统一持久化完整索引，避免与子进程争写
                Content.save_cache_index(settings, book.book_id, cached_chapters)
                Log.info("pre-download: completed chapter", target_idx)
            else
                Log.warn("pre-download: failed chapter", target_idx, ":", err)
            end
            -- 继续下一章：间隔 = 基础间隔 + 随机抖动，每 N 章再长休一次
            -- （参数见 helper.next_request_delay / settings.cache.request_*）。
            -- 失败也算「发过请求」，一并计数。
            processed = processed + 1
            local delay = H.next_request_delay(settings, processed)
            UIManager:scheduleIn(delay, function() download_one(offset + 1) end)
        end, { poll_interval = 0.2, timeout = 60 })
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

-- 按 item_id 在目录里找它的 1-based 序号（找不到返回 nil）。
--
-- 🔴 为什么需要它：切章时 `_state.current_chapter_index` 是**新章**，
--    而「补发旧文档进度」要的是**旧章**的序号 —— 只能按 item_id 反查（见 onCloseDocument）。
function FanQiePlugin:_chapterIndexByItemId(chapters, item_id)
    if not chapters or item_id == nil then return nil end
    local want = tostring(item_id)
    for i, ch in ipairs(chapters) do
        if ch and ch.itemId ~= nil and tostring(ch.itemId) == want then
            return i
        end
    end
    return nil
end

-- 当前文档对应的章节 item_id（路径反查 `<cache>/<book_id>/chapter_<item_id>.html`）。
function FanQiePlugin:_currentDocChapterItemId()
    if not (self.ui and self.ui.document) then return nil end
    if type(_state.item_id_from_path) ~= "function" then return nil end
    return _state.item_id_from_path(self.ui.document.file or self.ui.document.path)
end

-- Sync reading progress to server（章节结束 / 关文档 / 定期上传都走这里）
-- 通过 Async 子进程上传，HTTP 请求在子进程执行，UI 线程仅做轻量轮询，
-- 不再阻塞界面（消除章节开始 / 每 10 页时的几秒卡顿）。
--
-- @param opts table|nil
--   opts.item_id   要上传**哪一章**（默认当前章）。
--                  🔴 切章时旧文档关闭的那一刻 `current_chapter_index` 已经是新章，
--                  所以 onCloseDocument 必须显式传「这份文档所属的章节」；
--                  不传就会把旧章的页进度写成新章的进度（末页翻章 ⇒ 新章被标记成已读完）。
--                  传了但目录里找不到该章 ⇒ 直接放弃（宁可不上传，也别写到错的章上）。
--   opts.progress  页进度（默认按当前文档的阅读位置算）
function FanQiePlugin:syncCurrentProgress(opts)
    opts = opts or {}
    if not _state.current_book or not _state.current_chapters then return end
    local chapters = _state.current_chapters
    local idx
    if opts.item_id ~= nil then
        idx = self:_chapterIndexByItemId(chapters, opts.item_id)
        if not idx then
            -- 目录里没有这一章（目录刚刷新过 / 章节已下架）⇒ 不猜，也不写到别的章上
            if Log then
                Log.warn("syncCurrentProgress: item_id 不在目录里，跳过", tostring(opts.item_id))
            end
            return
        end
    else
        idx = _state.current_chapter_index
    end
    if not idx or idx < 1 then return end
    local chapter = chapters[idx]
    if not chapter or not chapter.itemId or not _state.current_book.book_id then
        return
    end
    local progress = opts.progress or self:getCurrentPageProgress()
    local last_report = _state.getLastProgressReport(chapter.itemId)
    if last_report and last_report.progress >= progress then
        return
    end

    -- 提前拷贝，避免子进程闭包依赖可变的全局状态
    local book_id = _state.current_book.book_id
    local item_id = chapter.itemId
    local chapter_idx = idx - 1
    local client = self.client
    local start_time = now_seconds()

    -- 🔴 发起的那一刻就登记 pending：Async 的轮询由 UIManager 驱动，
    --    进程在「在途」时退出（关 KOReader / 掉电 / 被杀）⇒ on_done 永不执行
    --    ⇒ 只在失败回调里登记 = **静默丢进度**。成功后再 remove（见下方 on_done）。
    _state.addPendingProgress(book_id, item_id, chapter_idx, progress)

    Async.run(function()
        -- 在子进程中执行阻塞 HTTP POST
        client:update_read_progress(book_id, item_id, chapter_idx, progress)
        return true
    end, function(ok, _result, err)
        Log.info("syncCurrentProgress completed in",
            string.format("%.3f", now_seconds() - start_time), "seconds")
        if ok then
            _state.setLastProgressReport(item_id, progress)
            _state.removePendingProgress(book_id, item_id)
        else
            if Log then Log.warn("syncCurrentProgress failed:", err) end
            -- 重新登记（幂等）+ 落盘：重启后还能补上这一次
            _state.addPendingProgress(book_id, item_id, chapter_idx, progress)
            _state.persistPendingProgress()
        end
    end, { delay = 0.1, poll_interval = 0.2, timeout = 30, tag = "progress" })
end

-- Retry pending progress reports when network is available
-- 每条待上传进度在子进程执行，顺序处理，UI 线程不阻塞。
function FanQiePlugin:retryPendingProgress()
    local book_id = _state.current_book and _state.current_book.book_id
    if not book_id then return end

    local start_time = now_seconds()
    UIManager:scheduleIn(0.5, function()
        local pending = _state.getPendingProgress()
        -- 收集本书的待上传条目为顺序列表
        local queue = {}
        for key, item in pairs(pending) do
            if item.book_id == book_id then
                table.insert(queue, item)
            end
        end
        local total = #queue
        if total == 0 then return end

        local client = self.client
        local function process_next(i)
            if i > total then
                Log.info("retryPendingProgress completed", total,
                    "items in", string.format("%.3f", now_seconds() - start_time), "seconds")
                return
            end
            local item = queue[i]
            Async.run(function()
                client:update_read_progress(item.book_id, item.item_id, item.chapter_idx, item.progress)
                return true
            end, function(ok, _r, err)
                if ok then
                    _state.setLastProgressReport(item.item_id, item.progress)
                    _state.removePendingProgress(item.book_id, item.item_id)
                else
                    if Log then Log.warn("retryPendingProgress item failed:", item.item_id, err) end
                end
                -- 处理下一条
                UIManager:scheduleIn(0, function() process_next(i + 1) end)
            end, { poll_interval = 0.2, timeout = 30, tag = "progress" })
        end
        process_next(1)
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

    -- 阅读中定期上传（幂等）：只在用户真的在翻页时确认定时器活着。
    -- 关文档 / 切章会把它停掉，下一次翻页再重新挂上。
    self:_ensureProgressTimer()

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
    _state.setChapterNavigating(true)

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

    -- 段评模式：段评开关决定首次下载是否带段评；已缓存正文直接用，缺段评不重下
    local review_enabled = _state.isReviewEnabled()
    -- heartbeat_path：见 _downloadHeartbeatPath 的注释（图集/漫画整章下载不能被
    -- 「总时长」超时掐掉，只要还有图在落盘就续期）。
    local fetch_opts = {
        skip_cache_index = true,
        heartbeat_path = self:_downloadHeartbeatPath(book),
    }
    if review_enabled then fetch_opts.review = true end

    -- 下载完成后的跳章逻辑（缓存命中与异步下载共用）
    local function finish_prev(p)
        -- 加载段评数据
        if review_enabled then
            local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            _state.setCurrentParaReviews(reviews)
        end
        _state.current_chapter_index = prev_idx
        _state.pre_download_triggered = false
        _state.last_page_number = nil
        self:showReaderUI(p, prev_chapter)
        UIManager:scheduleIn(1.0, function()
            _state.start_of_chapter_triggered = false
            self:syncCurrentProgress()
            self:preDownloadChapters(book, chapters, prev_idx)
            self:retryPendingProgress()
        end)
    end

    if not existing_path or not H.file_exists(existing_path) then
        -- Try to find file directly from filesystem
        local found_path = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found_path then
            cached_chapters[item_id] = found_path
            Content.save_cache_index(self.settings, book.book_id, cached_chapters)
            path = found_path
        else
            self:showBusy(T(_("正在下载: %1"), prev_chapter.title or ""))
            local b = { book_id = book.book_id, title = book.title, author = book.author }
            local client = self.client
            local settings = self.settings
            Async.run(function()
                local path = Content.fetch_chapter_html(client, settings, b, prev_chapter, fetch_opts)
                return { path = path }
            end, function(ok, result, err)
                self:closeBusy()
                if not ok or type(result) ~= "table" or not result.path then
                    Log.error("onFanQiePrevChapter download failed:", tostring(err or result))
                    _state.start_of_chapter_triggered = false
                    _state.setChapterNavigating(false)
                    self:showError(T(_("加载上一章失败:\n%1"), display_error(err or result)))
                    return
                end
                local cc = getCachedChapters(self, book)
                cc[item_id] = result.path
                Content.save_cache_index(settings, book.book_id, cc)
                finish_prev(result.path)
            end, { delay = 0.1, poll_interval = 0.2, timeout = 60 })
            return true  -- 异步下载，完成后跳章
        end
    end

    finish_prev(path)
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

    -- 重入保护：异步跳章期间，忽略末页重复触发的事件，避免重复下载下一章
    if _state.end_of_book_jumping then
        return true
    end

    local current_idx = getCurrentChapterIndex()
    local chapters = _state.current_chapters
    local book = _state.current_book

    if book.book_id and current_idx > 0 then
        local chapter = chapters[current_idx]
        if chapter and chapter.itemId then
            -- 本章读完 ⇒ 进度 1.0。统一走 syncCurrentProgress：
            --   · **显式传 item_id**：末页这一刻 current_chapter_index 还是本章，
            --     但显式传号让「补发 / 定期上传 / 读完」三种来源的口径完全一致；
            --   · tag / last_report 守卫 / pending 登记都在那边统一处理。
            self:syncCurrentProgress({ item_id = chapter.itemId, progress = 1.0 })
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

    -- 下一章切换：段评获取与正文下载在子进程执行，UI 线程保持响应。
    -- busy 对话框期间界面不冻结；事件返回 true 使文档保持打开，
    -- 异步完成后由 finish_next 跳转下一章。
    _state.setChapterNavigating(true)
    local item_id = tostring(next_chapter.itemId)
    local review_enabled = _state.isReviewEnabled()
    -- heartbeat_path：见 _downloadHeartbeatPath 的注释（图集/漫画整章下载不能被
    -- 「总时长」超时掐掉，只要还有图在落盘就续期）。
    local fetch_opts = {
        skip_cache_index = true,
        heartbeat_path = self:_downloadHeartbeatPath(book),
    }
    if review_enabled then fetch_opts.review = true end

    -- 下载完成后的跳章逻辑（缓存命中与异步下载共用）
    local function finish_next(p)
        -- 加载段评数据
        if review_enabled then
            local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            _state.setCurrentParaReviews(reviews)
        end
        _state.current_chapter_index = next_idx
        _state.pre_download_triggered = false
        self:showReaderUI(p, next_chapter)
        UIManager:scheduleIn(1.0, function()
            self:preDownloadChapters(book, chapters, next_idx)
            self:retryPendingProgress()
        end)
    end

    -- 解析下一章缓存路径（已缓存正文直接用，缺段评不重下；文件系统回退查找）
    local function resolve_cached_path()
        local cached_chapters = getCachedChapters(self, book)
        local p = cached_chapters[item_id]
        if p and H.file_exists(p) then
            return p
        end
        local found = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found then
            local cc = getCachedChapters(self, book)
            cc[item_id] = found
            Content.save_cache_index(self.settings, book.book_id, cc)
            return found
        end
        return nil
    end

    -- 1) 快速路径：缓存命中直接跳章（同步完成，无需重入保护）
    local cached_path = resolve_cached_path()
    if cached_path then
        finish_next(cached_path)
        return true
    end

    -- 2) 异步下载路径：标记重入，避免末页重复触发下载同一章
    _state.end_of_book_jumping = true

    local b = { book_id = book.book_id, title = book.title, author = book.author }
    local client = self.client
    local settings = self.settings

    -- showBusy 幂等包装：等待路径可能已显示 busy，避免重复 show 泄漏对话框
    local function ensure_busy(text)
        if not self._busy_msg then
            self:showBusy(text)
        end
    end

    -- 启动下载：同时置 is_downloading，让预下载 download_one 检测后延后重试，
    -- 避免与预下载争用同一书源限流配额 / 争写缓存索引。
    local function start_download()
        _state.is_downloading = true
        ensure_busy(T(_("正在下载: %1"), next_chapter.title or ""))
        Async.run(function()
            local path = Content.fetch_chapter_html(client, settings, b, next_chapter, fetch_opts)
            return { path = path }
        end, function(ok, result, err)
            self:closeBusy()
            if not ok or type(result) ~= "table" or not result.path then
                Log.error("onEndOfBook download failed:", tostring(err or result))
                _state.is_downloading = false
                _state.end_of_book_jumping = false
                _state.setChapterNavigating(false)
                self:showError(T(_("加载下一章失败:\n%1"), display_error(err or result)))
                return
            end
            local cc = getCachedChapters(self, book)
            cc[item_id] = result.path
            Content.save_cache_index(settings, book.book_id, cc)
            _state.is_downloading = false
            _state.end_of_book_jumping = false
            finish_next(result.path)
        end, { delay = 0.1, poll_interval = 0.2, timeout = 60 })
    end

    -- 若预下载正在进行（is_downloading=true），先等待其完成再决定是否需要自己下载：
    -- 预下载可能正在下载本章，完成后即可走缓存命中路径，避免重复下载。
    -- 每轮先查缓存，命中即跳；未命中且仍有下载在进行则继续等（最多 ~60s）。
    if _state.is_downloading then
        ensure_busy(T(_("正在准备: %1"), next_chapter.title or ""))
        local waits = 0
        local function wait_then_download()
            -- 优先查缓存：预下载可能已缓存本章
            local p = resolve_cached_path()
            if p then
                self:closeBusy()
                _state.end_of_book_jumping = false
                finish_next(p)
                return
            end
            if _state.is_downloading then
                waits = waits + 1
                if waits > 120 then
                    -- 等待超时（is_downloading 异常卡死），强制自己下载
                    Log.warn("onEndOfBook: wait for is_downloading timeout, force download")
                    start_download()
                    return
                end
                UIManager:scheduleIn(0.5, wait_then_download)
                return
            end
            -- 无下载在进行且未缓存，自己下载
            start_download()
        end
        UIManager:scheduleIn(0.5, wait_then_download)
    else
        start_download()
    end
    return true  -- 事件已处理，文档保持打开，异步完成后跳章
end

-- 进度会话收尾：只掐「进度上传」这一条异步链（tag="progress"），
-- 跳章 / 预下载 / 书架刷新 / 封面不受影响（那是 onExit 的 cancel_all 才管的范围）。
-- 场景：切章与关文档都会瞬间发起多次上传，旧的在途请求会带着旧进度迟到回填，
-- 覆盖掉刚写的收尾值。先取消、再补发，保证最后落地的是当前状态。
function FanQiePlugin:_finalizeProgressSession()
    if Async and Async.cancel_tag then
        pcall(function() Async.cancel_tag("progress") end)
    end
end

-- 「关闭时上传进度」开关（settings.sync.upload_on_close，默认 true）。
-- 这个配置项以前是**死的**（全仓库只有默认值定义、没有任何消费点，设置页也看不到），
-- 于是用户以为关掉了其实一直在传。
function FanQiePlugin:_uploadOnCloseEnabled()
    if not (self.settings and self.settings.get) then return true end
    local ok, sync = pcall(function() return self.settings:get("sync", {}) end)
    if not ok or type(sync) ~= "table" then return true end
    return sync.upload_on_close ~= false
end

-- 阅读中定期上传的间隔（秒）。0 / 非法值 = 关闭。
function FanQiePlugin:_progressUploadInterval()
    if not (self.settings and self.settings.get) then return 0 end
    local ok, sync = pcall(function() return self.settings:get("sync", {}) end)
    if not ok or type(sync) ~= "table" then return 0 end
    local minutes = tonumber(sync.upload_interval_minutes) or 0
    if minutes <= 0 then return 0 end
    return math.max(60, math.floor(minutes * 60))
end

-- 当前活跃的插件实例。
--
-- 🔴 为什么不能直接用闭包里的 self：切章会重建 ReaderUI（连带重建插件实例），
--    旧实例的 `self.ui` 指向已销毁的 ReaderUI ⇒ `getCurrentPageProgress()` 返回 0
--    ⇒ 拿它上传等于**把进度刷成 0**。所以定时器每次 tick 都从 ReaderUI.instance
--    现取活跃实例（ReaderUI:registerModule 会把它挂成 `instance.fanqie`）。
local function active_plugin_instance()
    local ok, RUI = pcall(require, "apps/reader/readerui")
    if ok and type(RUI) == "table" and RUI.instance then
        return RUI.instance.fanqie
    end
    return nil
end

-- 阅读中定期上传（settings.sync.upload_interval_minutes，0 = 关闭）。
-- 幂等：翻页时反复调用只会挂一个定时器链；关文档时由 _stopProgressTimer 撤掉。
--
-- 🔴 这也是「进度有时候丢」的主因之一：以前只在「末页 / 关文档 / 开目录」
--    三个时刻上传，读到一半退出 KOReader（或切到别的书、被系统杀掉）这段进度
--    就没了 —— README 里承诺的「阅读中定期上传」在这之前其实并不存在。
function FanQiePlugin:_ensureProgressTimer()
    local seconds = self:_progressUploadInterval()
    if seconds <= 0 then
        self:_stopProgressTimer()
        return
    end
    if _state.progress_timer_on then return end
    _state.progress_timer_on = true
    -- 🔴 代际 token：切章会先 stop 再 start，旧 tick 闭包必须能认出「我已经被换掉」，
    --    否则新旧两条定时器链会并存（上传频率翻倍）。
    _state.progress_timer_token = (_state.progress_timer_token or 0) + 1
    local my_token = _state.progress_timer_token
    if Log then Log.info("progress upload timer started, every", seconds, "s") end

    local function tick()
        if _state.progress_timer_token ~= my_token then return end
        local plugin = active_plugin_instance()
        if plugin and plugin.syncCurrentProgress and plugin:isCurrentDocFanqie() then
            plugin:syncCurrentProgress()
        end
        UIManager:scheduleIn(seconds, tick)
    end
    UIManager:scheduleIn(seconds, tick)
end

function FanQiePlugin:_stopProgressTimer()
    _state.progress_timer_on = false
    _state.progress_timer_token = (_state.progress_timer_token or 0) + 1
end

function FanQiePlugin:onCloseDocument()
    -- 🔴 必须放在最前面：这不依赖「当前文档是不是番茄的」——
    --    只要覆盖过（`_state.end_document_action_backup ~= nil`）就要还回去，
    --    否则「到达文档末尾时的操作」会被永久改成 nothing（影响用户读别的书）。
    --    下面那个 `isCurrentDocFanqie` 守卫在文档已经不在时可能为假，
    --    所以还原不能写在守卫后面。
    --    本钩子切章时也会走 —— 那次还原之后，新文档的 ReaderReady 会立刻重新覆盖
    --    （showReader 的 doShowReader 在同一同步块里 onClose + new + show），
    --    中间窗口内不会有翻页发生，所以不会漏挡。
    local ok_restore, err_restore = pcall(function() self:_restoreEndDocumentAction() end)
    if not ok_restore and Log and Log.error then
        Log.error("restore end_document_action failed:", tostring(err_restore))
    end
    if not self:isCurrentDocFanqie() then
        return
    end
    -- 🔴 这个钩子**切章时也会走**：showReaderUI 用的是 `ReaderUI:showReader`
    --    （不是 switchDocument），它的 doShowReader 里会
    --    `ReaderUI.instance:onClose()` ⇒ 派发 CloseDocument ⇒ 走到这里。
    --    而 navigateToChapter 早在这之前就把 `_state.current_chapter_index`
    --    改成了**新章**。所以补发必须按「**这份文档**属于哪一章」取号
    --    （从文档路径反查），否则会把旧章的页进度上传成新章的进度：
    --    末页翻章时 progress≈1.0，等于把新章标记成「已读完」——
    --    这就是「上传进度有时候不对」的来源。
    local doc_item_id = self:_currentDocChapterItemId()
    -- 对齐 koobone 的 end_session：先取消在途上传，再强制补发最后一次进度。
    -- （cancel 会让在途那条的 on_done 不再执行、last_report 不更新，
    --   因此下面这行 syncCurrentProgress 必然真的发包。）
    self:_finalizeProgressSession()
    self:_stopProgressTimer()
    if self:_uploadOnCloseEnabled() then
        self:syncCurrentProgress({ item_id = doc_item_id })
    end
    -- 还没传成功的进度落盘，下次启动能补
    _state.persistPendingProgress()
    -- 离开这本书时，若它不在书架，问一次「是否加入书架」。
    -- ⚠️ 必须在清状态**之前**调用：它要用 getCurrentBook() 取书号与书名。
    -- ⚠️ 本钩子切章时也会走到，切章不算「离开」—— 过滤逻辑在函数内部
    --    （延后一拍看 ReaderUI.instance 是否还在），见那里的注释。
    -- ⚠️ 包 pcall：这是关文档路径，弹窗/查询出任何错都不能连累进度收尾。
    local ok_prompt, err_prompt = pcall(function() self:_promptAddShelfOnLeave() end)
    if not ok_prompt and Log and Log.error then
        Log.error("add-shelf prompt failed:", tostring(err_prompt))
    end
    _state.current_document_path = nil
    _state.setTocMenuOpen(false)
    _state.pre_download_triggered = false
    _state.last_page_number = nil
    _state.document_opened = false
    _state.setChapterNavigating(false)
end

-- 收尾界面层：把本插件自己 show 出来的顶层对话框收干净。
--
-- 🔴 每一步都是「先摘引用、再关对象」，且一律走 H.close_widget（只关还在
--    UIManager 栈上的）。直接 UIManager:close(已关过的 dialog) 会照常派发
--    CloseWidget 事件，副作用是给那块区域排一次 flashui 全刷 ——
--    这正是「弹窗偶尔会凭空闪一下、尤其在切章时才冒出来」的来源：
--    刷新回调会一直挂在 UIManager._refresh_func_stack 里，
--    直到下一次 forceRePaint（翻页 / 切章 / showBusy）才被消费。
function FanQiePlugin:onClose()
    if _state.active_menu then
        local menu = _state.active_menu
        _state.active_menu = nil
        H.close_widget(menu)
    end
    self:_closeDetailDialog()
    if _state.toc_menu then
        local toc = _state.toc_menu
        _state.toc_menu = nil
        H.close_widget(toc)
    end
    _state.setTocMenuOpen(false)
end

function FanQiePlugin:onCloseWidget()
    self:onClose()
end

-- 退出应用（KOReader 退出 / 插件卸载）：先取消所有在途的异步子进程
-- （书架刷新 / 取目录 / 跳章 / 封面预下载 / 进度上传 / 检查更新 / 下载安装），再收尾界面。
--
-- ⚠️ 这一步**不能**放进 onCloseWidget：那个钩子在「从文件管理器打开一本书」时也会触发，
--    一刀切会掐掉刚发起的（如自动拉取进度）子进程。只有真正退出 KOReader 才该全清。
-- ⚠️ 顺序：先掐在途异步，**再**收尾。这里刻意**不**调 onCloseDocument ——
--    它会补发一次「最后一次进度上传」的新子进程，而那时 cancel_all 已经跑过，
--    这个新子进程反而没人管了。收尾只做界面层的事。
function FanQiePlugin:onExit()
    if Async and Async.cancel_all then
        pcall(function() Async.cancel_all() end)
    end
    self:_stopProgressTimer()
    -- 🔴 还停在 pending 里的进度（含「在途但没跑完 on_done」的那些）必须落盘：
    --    进程一退，Async 的 poll 就不再跑，on_done 永不执行 ⇒ 不落盘就是静默丢。
    if _state.persistPendingProgress then
        _state.persistPendingProgress()
    end
    self:onCloseWidget()
    if self.settings and self.settings.flush then
        pcall(function() self.settings:flush() end)
    end
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
-- Cache management
-- ===========================================================================

function FanQiePlugin:getCacheMenuItems()
    local items = {}
    local stats = self.settings:get_cache_stats()
    local size_mb = stats.total_size / (1024 * 1024)

    table.insert(items, {
        text = string.format(_("缓存统计: %d 本书, %d 章节, %.1f MB"), stats.book_count, stats.chapter_count, size_mb),
        -- 纯展示行（见下方 Menu 的字段名说明）：Menu 只认 select_enabled/select_enabled_func
        select_enabled = false,
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
                    self:clearShelfCache()
                    UIManager:show(InfoMessage:new{
                        text = _("章节缓存已刷新"),
                    })
                end,
            })
        end,
    })
    -- 书架缓存 = 书单缓存（shelf_cache.lua 三层 + 快照）+ 书架封面（covers/）。
    -- 书城缓存 = 榜单短缓存（内存）+ 书城封面（store_covers/）。
    -- 两者拆开是因为目录本来就分开（covers/ vs store_covers/），用户经常只想清一边。
    table.insert(items, {
        text_func = function()
            local bytes = self:_shelfCacheBytes()
            return T(_("清空书架缓存（书单 + 封面 · %1）"),
                CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local bytes = self:_shelfCacheBytes()
            if bytes <= 0 then
                self:showInfo(_("书架缓存是空的"))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("删除书架缓存（书单缓存 + 书架封面，共 %1）？\n书架列表下次打开会重新联网获取，封面会重新下载。"),
                    CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes)),
                ok_text = _("清空"),
                cancel_text = _("取消"),
                ok_callback = function()
                    -- 书单三层（显示层内存 / client API 短缓存 / shelf_cache.lua）+ 快照
                    self:clearShelfCache()
                    local removed = 0
                    if CoverCache then
                        local r = CoverCache.clear(self.settings:get_download_dir() .. "/covers")
                        removed = r.removed or 0
                    end
                    self:showInfo(T(_("书架缓存已清空（含封面 %1 张）"), tostring(removed)))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    })
    table.insert(items, {
        text_func = function()
            local bytes = self:_storeCacheBytes()
            return T(_("清空书城缓存（榜单 + 封面 · %1）"),
                CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local bytes = self:_storeCacheBytes()
            local has_rank = type(self._store_rank_cache) == "table" and next(self._store_rank_cache) ~= nil
            if bytes <= 0 and not has_rank then
                self:showInfo(_("书城缓存是空的"))
                return
            end
            UIManager:show(ConfirmBox:new{
                text = T(_("删除书城缓存（榜单缓存 + 书城封面，共 %1）？\n榜单下次打开会重新联网获取，封面会重新下载。"),
                    CoverCache and CoverCache.human_bytes(bytes) or tostring(bytes)),
                ok_text = _("清空"),
                cancel_text = _("取消"),
                ok_callback = function()
                    self._store_rank_cache = nil
                    local removed = 0
                    if CoverCache then
                        local r = CoverCache.clear(self.settings:get_download_dir() .. "/store_covers")
                        removed = r.removed or 0
                    end
                    self:showInfo(T(_("书城缓存已清空（含封面 %1 张）"), tostring(removed)))
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    })
    table.insert(items, {
        text = _("清除全部缓存"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = string.format(_("确定清除所有番茄小说缓存?\n%d 本书, %d 章节将被删除。"), stats.book_count, stats.chapter_count),
                ok_text = _("清除"),
                cancel_text = _("取消"),
                ok_callback = function()
                    self.settings:clear_all_cache()
                    self:clearShelfCache()
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

-- ===========================================================================
-- Download management
-- ===========================================================================

function FanQiePlugin:showDownloadManager()
    local self_ref = self
    local dialog
    -- 定时刷新控制标志（Menu 关闭后停止刷新）
    local refresh_active = true

    -- 调试日志
    local task = _state.getDownloadTask()
    local history = _state.getDownloadHistory()
    if Log and Log.info then
        Log.info("[DownloadMgr] open: task=" .. tostring(task and task.book_title or "nil")
            .. " task_status=" .. tostring(task and task.status or "nil")
            .. " history_count=" .. tostring(#history))
    end

    -- 构建进度条文本（墨水屏友好的纯文本进度条）
    local function buildProgressText(current, total)
        if not total or total <= 0 then return "0%" end
        local pct = math.floor((current or 0) / total * 100)
        -- 10 格进度条，每格代表 10%
        local filled = math.floor(pct / 10)
        local bar = string.rep("█", filled) .. string.rep("░", 10 - filled)
        return string.format("%s %d%% (%d/%d)", bar, pct, current or 0, total)
    end

    -- 构建 Menu items
    local function buildItems()
        local items = {}
        local task = _state.getDownloadTask()
        if Log and Log.info then
            Log.info("[DownloadMgr] buildItems: task=" .. tostring(task and task.book_title or "nil")
                .. " status=" .. tostring(task and task.status or "nil"))
        end

        -- 当前下载任务
        -- 🔴 这一整屏的「纯展示行」必须用 `select_enabled = false`（**不是**
        --    `enabled_func`）。KOReader 的 `Menu:onMenuSelect` 只认
        --    `item.select_enabled == false` / `item.select_enabled_func`；
        --    写错字段名的后果不是「多点了没反应」这么轻 —— 点中之后仍然走
        --    `onMenuChoice`，紧接着 menu.lua 会调用 `self.close_callback()`，
        --    而这里的 close_callback 会把 refresh_active 置 false ⇒
        --    **用户在下载管理里随便点一行，进度就再也不自动刷新了**。
        if task and task.status == "downloading" then
            table.insert(items, {
                text = T(_("正在下载: 《%1》"), task.book_title or task.book_id or "未知"),
                select_enabled = false,
            })
            table.insert(items, {
                text = buildProgressText(task.current, task.total),
                select_enabled = false,
            })
            if task.chapter and task.chapter ~= "" then
                table.insert(items, {
                    text = T(_("当前: %1"), task.chapter),
                    select_enabled = false,
                    separator = true,
                })
            else
                table.insert(items, { text = "", separator = true })
            end
            table.insert(items, {
                text = _("取消下载"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("确定取消《%1》的下载?"), task.book_title or "未知"),
                        ok_text = _("确定"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            -- 走 state 的取消入口（而不是直接 clearDownloadTask）：
                            -- 下载流程注册的 handler 会**立刻掐掉当前章的子进程**并收尾。
                            -- 只清状态的话，正在跑的那一章要等它自己跑完
                            -- （图集/漫画单章 1~5 分钟）才停，看起来就像「取消没生效」。
                            if _state.requestDownloadCancel then
                                _state.requestDownloadCancel()
                            else
                                _state.clearDownloadTask()
                            end
                            self_ref:showInfo(_("已取消下载"))
                            -- 刷新列表
                            if dialog and dialog.updateItems then
                                dialog.item_table = buildItems()
                                dialog:updateItems()
                            end
                        end,
                    })
                end,
            })
            table.insert(items, { text = "", separator = true })
        else
            table.insert(items, {
                text = _("当前无下载任务"),
                select_enabled = false,
            })
            table.insert(items, { text = "", separator = true })
        end

        -- 历史下载记录
        local history = _state.getDownloadHistory()
        if #history > 0 then
            table.insert(items, {
                text = _("最近下载记录:"),
                select_enabled = false,
            })
            for i, h in ipairs(history) do
                local status_text = h.status == "completed" and _("完成")
                    or (h.status == "interrupted" and _("中断") or _("取消"))
                local time_str = h.end_time and os.date("%m-%d %H:%M", h.end_time) or ""
                table.insert(items, {
                    text = T(_("《%1》 - %2 %3"), h.book_title or h.book_id or "未知", status_text, time_str),
                    select_enabled = false,
                })
            end
            table.insert(items, { text = "", separator = true })
            table.insert(items, {
                text = _("清空历史记录"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("确定清空所有下载历史记录?"),
                        ok_text = _("确定"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            _state.clearDownloadHistory()
                            self_ref:showInfo(_("已清空历史记录"))
                            if dialog and dialog.updateItems then
                                dialog.item_table = buildItems()
                                dialog:updateItems()
                            end
                        end,
                    })
                end,
            })
        end

        if Log and Log.info then
            Log.info("[DownloadMgr] buildItems: items_count=" .. tostring(#items))
        end
        return items
    end

    -- 打开本菜单会**临时**顶掉 _state.active_menu（它同时被书架的关闭逻辑使用）。
    -- 关窗时必须把这个引用还回去，否则「从书架进下载管理再返回」会让
    -- _state.active_menu 变 nil —— 书架还在屏幕上，而依赖它的清理逻辑全部失效。
    local prev_active_menu = _state.active_menu

    dialog = Menu:new{
        title = _("下载管理"),
        item_table = buildItems(),
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            -- ⚠️ `close_callback` **不只在「菜单真的关掉」时**触发：koreader
            --    menu.lua 的 `Menu:onMenuSelect` 每选中一个条目也会调它。
            --    以前无条件 `refresh_active = false` ⇒ 用户在下载管理里点任何一行
            --    （哪怕只是点书名那条展示行），**进度从此不再自动刷新**，
            --    而且 active_menu 被顺手清空。这里用「菜单是否还在屏幕上」区分。
            if UIManager and type(UIManager.isWidgetShown) == "function" then
                local ok, shown = pcall(UIManager.isWidgetShown, UIManager, dialog)
                if ok and shown then return end
            end
            refresh_active = false
            if _state.active_menu == dialog then
                _state.active_menu = prev_active_menu
            end
        end,
    }
    _state.active_menu = dialog
    UIManager:show(dialog)

    -- 定时刷新当前下载进度（2秒间隔，墨水屏友好）
    local function refreshProgress()
        if not refresh_active then return end
        if not dialog then return end

        local task = _state.getDownloadTask()
        if task and task.status == "downloading" then
            -- 有下载任务，刷新列表
            dialog.item_table = buildItems()
            if dialog.updateItems then
                dialog:updateItems()
            end
            -- 继续定时刷新
            UIManager:scheduleIn(2, refreshProgress)
        else
            -- 下载完成或取消，最后刷新一次
            dialog.item_table = buildItems()
            if dialog.updateItems then
                dialog:updateItems()
            end
        end
    end

    -- 如果有下载任务，启动定时刷新
    local task = _state.getDownloadTask()
    if task and task.status == "downloading" then
        UIManager:scheduleIn(2, refreshProgress)
    end
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
        width = Screen and (Screen:getWidth() - 100) or nil,
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

-- 用缓存目录进入阅读（离线模式或网络获取失败时的回退路径）
function FanQiePlugin:_openBookWithCache(book, cached_chapters)
    if not cached_chapters or #cached_chapters == 0 then return end
    UIManager:scheduleIn(0.1, function()
        getCachedChapters(self, book)
    end)
    -- 从 book.item_id（书架中的上次阅读章节）找起始索引
    local start_index = 1
    if book.item_id then
        local target_item_id = tostring(book.item_id)
        for idx, ch in ipairs(cached_chapters) do
            if tostring(ch.itemId or ch.item_id) == target_item_id then
                start_index = idx
                break
            end
        end
    end
    -- 如果上次阅读的章节没有缓存，向后找第一个有缓存的章节
    local chapter_cache = Content.load_cache_index(self.settings, book.book_id)
    if chapter_cache then
        local start_item_id = tostring(cached_chapters[start_index].itemId or cached_chapters[start_index].item_id or "")
        if not chapter_cache[start_item_id] then
            if Log then Log.info("openBook: last read chapter not cached, finding next cached") end
            for idx = start_index, #cached_chapters do
                local item_id = tostring(cached_chapters[idx].itemId or cached_chapters[idx].item_id or "")
                if chapter_cache[item_id] then
                    start_index = idx
                    break
                end
            end
        end
    end
    if Log then Log.info("openBookWithCache: start_index=" .. start_index) end
    self:openChapter(book, cached_chapters, start_index)
end

function FanQiePlugin:openBook(book)
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = true
    end
    _state.current_book = book

    -- 先尝试目录缓存（本地 IO，不阻塞）
    local cached_chapters = Content.load_catalog_cache(self.settings, book.book_id)
    local has_cache = cached_chapters and #cached_chapters > 0

    -- 无缓存 + 无网络：提示用户联网
    if not has_cache and not self:checkNetwork() then
        return
    end

    -- 有缓存 + 无网络：离线模式，直接用缓存打开，跳过云端进度同步
    if has_cache and not self:checkNetwork() then
        if Log then Log.info("openBook: offline mode, using cached chapters") end
        self:_openBookWithCache(book, cached_chapters)
        return
    end

    -- 有网络（无论是否有缓存）：子进程获取目录（缓存未命中时）+ 阅读进度
    self:showBusy(_("正在获取目录..."))
    local client = self.client
    local settings = self.settings
    local book_id = book.book_id
    local pull_progress = settings:get("sync", {}).pull_on_open ~= false

    Async.run(function()
        -- 子进程：始终拉取最新目录（有缓存也刷新，获取新章节）；按设置拉取阅读进度
        local b = { book_id = book_id }
        local fetched = Content.fetch_catalog(client, b)
        local progress = nil
        if pull_progress then
            local ok_p, p = pcall(function() return client:fetch_read_progress() end)
            if ok_p then progress = p end
        end
        -- 多值打包成 table（Async.run work_func 只能返回单值）
        return { chapters = fetched, progress = progress }
    end, function(ok, result, err)
        self:closeBusy()
        if not ok or type(result) ~= "table" then
            -- 获取失败：有缓存则回退到缓存进入阅读
            if has_cache then
                if Log then Log.warn("openBook: fetch failed, fallback to cached chapters") end
                self:_openBookWithCache(book, cached_chapters)
                return
            end
            self:showError(T(_("获取目录失败:\n%1"), display_error(err or result)))
            return
        end

        -- 优先用子进程新拉取的目录，回退到缓存
        local chapters = result.chapters or (has_cache and cached_chapters or nil)
        if not chapters or #chapters == 0 then
            -- 新目录为空（可能 cookie 过期）：有缓存则回退
            if has_cache then
                if Log then Log.warn("openBook: fetched empty chapters, fallback to cache") end
                self:_openBookWithCache(book, cached_chapters)
                return
            end
            self:showInfo(_("未获取到章节"))
            return
        end

        -- 持久化新拉取的目录（缓存命中时不重复写）
        if result.chapters and #result.chapters > 0 then
            Content.save_catalog_cache(settings, book_id, result.chapters)
            _state.setDirectoryCache(book_id, result.chapters)
        end

        UIManager:scheduleIn(0.1, function()
            getCachedChapters(self, book)
        end)

        -- 从云端进度中找到起始章节
        local start_index = 1
        if result.progress and result.progress.data then
            for _, item in ipairs(result.progress.data) do
                if tostring(item.book_id or item.bookId) == tostring(book_id) then
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

        -- 云端进度未命中当前书籍时，回退到 book.item_id（书架中的上次阅读章节）
        if start_index == 1 and book.item_id then
            local target_item_id = tostring(book.item_id)
            for idx, ch in ipairs(chapters) do
                if tostring(ch.itemId or ch.item_id) == target_item_id then
                    start_index = idx
                    break
                end
            end
            if start_index > 1 and Log then
                Log.info("openBook: cloud progress miss, fallback to book.item_id, start_index=" .. start_index)
            end
        end

        if start_index > #chapters then
            start_index = 1
        end

        self:openChapter(book, chapters, start_index)
    end, { poll_interval = 0.3, timeout = 60 })
end

-- ===========================================================================
-- UI helpers
-- ===========================================================================

-- 忙碌提示（半透明遮罩 + 白框，无 timeout，必须显式 closeBusy）。
--
-- 🔴 必须幂等：直接 `self._busy_msg = InfoMessage:new{...}` 覆盖引用，
--    上一个 InfoMessage 就**再也没有任何引用能关掉它**——它会永久留在
--    UIManager 栈上（点一下就关得掉，但不点就一直在）。
--    实测症状就是「点了书架，那个『正在刷新书架…』弹窗有时候不消失」：
--    例如缓存先显示 → showBusy#1 → 用户点书 → 详情里的下载又 showBusy#2 →
--    #1 的引用被 #2 覆盖，等 #2 关掉时 #1 早就漏了。
--    所以这里先摘引用、再关旧的。
--
-- 注：旧代码写的 `norefresh = true` 是**无效字段**（InfoMessage 没有这个字段，
--     与之相近的是 no_refresh_on_close）。这里不补上它：busy 关掉时必须重绘，
--     否则白框会留在墨水屏上。
function FanQiePlugin:showBusy(text)
    if self._busy_msg then
        local old = self._busy_msg
        self._busy_msg = nil
        H.close_widget(old)
    end
    self._busy_msg = InfoMessage:new{ text = text }
    UIManager:show(self._busy_msg)
    UIManager:forceRePaint()
end

function FanQiePlugin:closeBusy()
    local msg = self._busy_msg
    self._busy_msg = nil
    if msg then H.close_widget(msg) end
end

function FanQiePlugin:showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function FanQiePlugin:showError(text)
    -- 同样：`norefresh = false` 是无效字段（InfoMessage 无此字段），去掉。
    UIManager:show(InfoMessage:new{ text = text })
end

return FanQiePlugin
