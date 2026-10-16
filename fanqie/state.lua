local CACHE_EXPIRY_SECONDS = 86400

local M = {
    current_book = nil,
    current_chapters = nil,
    current_chapter_index = nil,
    current_document_path = nil,
    cached_directory = nil,
    pending_progress = {},
    last_progress_report = {},
    -- 阅读中定期上传的定时器开关 / 代际 token。
    -- 切章会重建 ReaderUI（连带插件实例），定时器链必须靠 token 认出「我已被换掉」，
    -- 否则新旧两条链并存 ⇒ 上传频率翻倍（见 main.lua 的 _ensureProgressTimer）。
    progress_timer_on = false,
    progress_timer_token = 0,
    cached_chapter_index = {},
    toc_menu_open = false,
    pre_download_triggered = false,
    -- 预下载独立标志：不阻塞用户阅读（与 is_downloading 区分）
    -- is_downloading 仅用于用户主动下载（手动下载/跳章下载），会阻塞 navigateToChapter
    -- pre_downloading 用于后台预下载，不阻塞阅读，但会被 is_downloading 中断
    pre_downloading = false,
    active_menu = nil,
    detail_dialog = nil,
    is_downloading = false,
    last_page_number = nil,
    start_of_chapter_triggered = false,
    document_opened = false,
    -- onEndOfBook 异步跳章重入保护：异步下载下一章期间为 true，抑制末页重复触发
    end_of_book_jumping = false,
    -- 章节切换中标志：navigateToChapter 期间为 true，防止段评异步回调在切章后弹窗闪现
    chapter_navigating = false,
    -- 段评相关状态
    enable_review = false,           -- 段评开关
    current_para_reviews = {},      -- 当前章节的段评数据
    current_para_index = 0,         -- 当前选中的段评索引
    -- 内部引用：可选，用于持久化段评开关
    _settings_ref = nil,
    -- 下载管理状态
    download_task = nil,  -- 当前下载任务 { book_id, book_title, current, total, status, start_time }
    download_history = {}, -- 最近完成的下载任务
    -- 书架状态快照（见下方 setShelfAll / markShelf / shelfState）。
    --   shelf_all   ：完整书架集合（由书架列表的载入/保存处重建）；nil = 还不知道
    --   shelf_known ：单本覆盖（刚加入/移出成功、或一次 shelf_check 的结果）
    shelf_all = nil,
    shelf_known = {},
    -- 「退出阅读时已问过是否加入书架」的书号集合（进程内节流，见 main.lua）
    shelf_prompted = {},
    -- 「到达文档末尾时的操作」原值备份（见 main.lua 的 _mute/_restoreEndDocumentAction）。
    -- 🔴 三态必须分清：
    --   nil   = 还没覆盖过（不需要还原）
    --   false = 覆盖前该项**没设过**（KOReader 的默认就是「弹窗询问」）
    --   其它  = 覆盖前的实际值（字符串）
    --    把 false 和 nil 混用 ⇒ 「原本没设过」会被当成「没覆盖过」，
    --    离开番茄书时就不还原，全局设置被永久改成 nothing。
    end_document_action_backup = nil,
}

-- 将段评开关从 Settings 加载到全局内存状态（启动时调用一次）
-- settings: Settings 实例（fanqie.settings:new() 返回值）
function M.loadReviewState(settings)
    if not settings then return end
    M._settings_ref = settings
    local ok, val = pcall(function() return settings:getParaReviewEnabled() end)
    if ok and val == true then
        M.enable_review = true
    else
        M.enable_review = false
    end
    -- 加载持久化的下载历史和任务状态
    M.loadDownloadState()
    -- 加载上一次退出时没传完的进度（见下方 persistPendingProgress 的说明）
    M.loadPendingProgress()
end

-- 把 enable_review 持久化到 Settings（若 settings 可用）
local function persist_review_state(enabled)
    if not M._settings_ref then return end
    pcall(function() M._settings_ref:setParaReviewEnabled(enabled == true) end)
end

-- ===== 下载状态持久化 =====
-- 持久化下载历史到文件（避免 KOReader 退出后丢失）
local function persist_download_history()
    if not M._settings_ref then return end
    pcall(function()
        M._settings_ref:set("download_history", M.download_history)
        M._settings_ref:flush()
    end)
end

-- 持久化当前下载任务到文件
local function persist_download_task()
    if not M._settings_ref then return end
    pcall(function()
        M._settings_ref:set("download_task", M.download_task)
        M._settings_ref:flush()
    end)
end

-- 从文件加载下载历史和任务状态（启动时调用）
-- 如果发现"正在下载"的任务（说明上次退出时下载未完成），标记为"中断"并归入历史
M.loadDownloadState = function()
    if not M._settings_ref then return end
    -- 加载历史记录
    local ok_h, history = pcall(function() return M._settings_ref:get("download_history") end)
    if ok_h and type(history) == "table" then
        M.download_history = history
    end
    -- 加载未完成的下载任务
    local ok_t, task = pcall(function() return M._settings_ref:get("download_task") end)
    print("[FanQie][state] loadDownloadState: history_count=" .. tostring(#M.download_history)
        .. " persisted_task=" .. tostring(task and task.book_title or "nil")
        .. " task_status=" .. tostring(task and task.status or "nil"))
    if ok_t and task and task.status == "downloading" then
        -- 上次退出时下载未完成，标记为"中断"
        task.status = "interrupted"
        task.end_time = os.time()
        table.insert(M.download_history, 1, task)
        while #M.download_history > 10 do
            table.remove(M.download_history)
        end
        M.download_task = nil
        M.is_downloading = false
        persist_download_history()
        persist_download_task()
        print("[FanQie][state] loadDownloadState: found interrupted task, moved to history")
    elseif ok_t and task then
        M.download_task = task
        M.is_downloading = task.status == "downloading"
    end
end

M.isCurrentDocFanqie = function(file_path)
    local path = file_path or M.current_document_path
    if not path then return false end
    return path:lower():find('/fanqie/', 1, true) or false
end

--- 从章节文档路径反推番茄书号（纯函数）。
--
-- 路径形状（见 fanqie/content.lua 的 book_cache_dir / save_chapter_html）：
--     <cache_dir>/<book_id>/chapter_<item_id>.html
--
-- 🔴 为什么需要它：`current_book` **不持久化**（只有 openBook / openChapter /
--    showChapterListing 三处赋值）。重启 KOReader 后从「最近阅读 / 文件管理器」
--    直接打开章节续读时它是 nil，而文档路径里其实带着书号 —— 阅读界面的
--    「加入/移出书架」就靠这个函数把书号捞回来。
--    调用方（main.lua 的 getCurrentBook）还会拿缓存目录反查校验一次，
--    避免把用户自己放在别处的同名 `chapter_*.html` 误认成番茄章节。
--
-- @param path string|nil
-- @return string|nil book_id
M.book_id_from_path = function(path)
    if type(path) ~= "string" then return nil end
    local id = path:match("/([^/]+)/chapter_[^/]+%.html$")
    if id == nil or id == "" then return nil end
    return id
end

--- 从章节文档路径反查**章节 item_id**。
--
-- 🔴 为什么需要它（「上传进度有时候有问题」的根因）：
--    切章 = 关掉旧 ReaderUI 再开新的（main.lua 的 showReaderUI 走
--    `ReaderUI:showReader`，其 `doShowReader` 会 `ReaderUI.instance:onClose()`），
--    KOReader 在 onClose 里派发 `CloseDocument` —— 也就是**每次切章都会走一遍**
--    本插件的 `onCloseDocument`。而 `navigateToChapter` 远在那之前就把
--    `current_chapter_index` 改成了**新章**。
--    ⇒ 「关文档时补发进度」只能按**这份文档属于哪一章**取号，
--      真值来源是文档路径（`<cache>/<book_id>/chapter_<item_id>.html`），
--      不是 `current_chapter_index`。否则会把旧章的页进度写成新章的进度
--      （末页翻章时 progress≈1.0 ⇒ 新章被标记成「已读完」）。
--
-- @param path string|nil
-- @return string|nil item_id
M.item_id_from_path = function(path)
    if type(path) ~= "string" then return nil end
    local id = path:match("/chapter_([^/]+)%.html$")
    if id == nil or id == "" then return nil end
    return id
end

-- ------------------------------------------------------------------ 书架状态快照
--
-- 🔴 为什么需要这层快照，而不是当场查：
--    有两处必须在 **UI 线程同步** 决定「这本书在不在书架」——
--      ① 阅读端菜单项的文案（「加入书架」还是「移出书架」）：由
--         `Menu.getMenuText`（koreader frontend/ui/widget/menu.lua）在每次
--         `updateItems` 时同步求值；
--      ② 退出阅读时「是否加入书架」的提示。
--    而现成的两个来源都同步不了：`Store.shelf_check()` 是网络往返；
--    `Bookshelf:get_shelf()` 未命中 client 的 5 分钟短缓存时同样是阻塞式发包。
--    ⇒ 这里维护一份内存快照，由书架数据的既有读写点同步维护，查询是 O(1)。
--
-- 两级快照，语义严格区分（混用会直接导致文案反着来）：
--   · `shelf_all`：**完整**书架集合。nil = 还没读过书架列表 ⇒ 对任何书都只能说
--     「未知」；非 nil 时「不在表里」才等于确定不在架。
--   · `shelf_known`：单本**覆盖**。优先级高于 `shelf_all` —— 否则「刚加入的书」
--     会被一份过期书架表判成不在架（加入书架后缓存会被整体清掉，见 store_ui）。

--- 用一份**完整**书架列表重建快照（bookshelf.lua 的 save / load 处调用）。
-- @param books table|nil 书架书籍数组；nil = 列表不可用（≠ 空书架），退回未知。
function M.setShelfAll(books)
    if type(books) ~= "table" then
        M.shelf_all = nil
        return
    end
    local set = {}
    for _, b in ipairs(books) do
        local id = type(b) == "table" and b.book_id
        if id ~= nil then
            set[tostring(id)] = true
        end
    end
    M.shelf_all = set
end

--- 书架列表失效（加入/移出书架后清缓存）⇒ 完整快照不再可信。
-- ⚠️ **只清 shelf_all，不动 shelf_known**：后者是「刚操作过」的确定事实，
--    而 shelf_all 已经过期 —— 一起清会把「刚加入的书」重新变成「未知」。
function M.clearShelfAll()
    M.shelf_all = nil
end

--- 是否已经有一份**完整**书架快照（false = 还没读过书架列表，一切皆「未知」）。
-- 外部只该通过它 + shelfState 观察快照，别直接读 M.shelf_all：
-- 那个字段的 nil 有语义（「未知」），字段本身对外是内部实现。
function M.hasShelfAll()
    return M.shelf_all ~= nil
end

--- 记录**单本**书的确定状态（加入/移出成功、或一次 shelf_check 的结果）。
-- @param book_id string|number
-- @param on_shelf boolean
function M.markShelf(book_id, on_shelf)
    if book_id == nil or type(on_shelf) ~= "boolean" then return end
    M.shelf_known[tostring(book_id)] = on_shelf
end

--- 「这本书在不在书架」的同步查询。
-- @return true=在架 / false=不在架 / nil=**未知**（还没有任何可信来源）
-- 🔴 调用方必须区分 false 与 nil：只有 false 才敢断言「不在书架」。
--    把 nil 当 false 会让「还没读过书架列表」的冷启动场景到处误报方向。
function M.shelfState(book_id)
    if book_id == nil then return nil end
    local id = tostring(book_id)
    local known = M.shelf_known[id]
    if type(known) == "boolean" then return known end
    if M.shelf_all ~= nil then return M.shelf_all[id] == true end
    return nil
end

-- 待上传进度的磁盘持久化。
--
-- 🔴 为什么必须落盘：`pending_progress` 以前只在内存里、而且**只在失败回调**里登记。
--    可是失败回调本身依赖 UI 循环继续跑（Async 的 poll 由 UIManager:scheduleIn 驱动），
--    用户在「上传在途」时退出 KOReader / 切书 / 被系统杀掉 ⇒ on_done 永不执行
--    ⇒ 既没上传成功、也没留下任何记录 = **静默丢进度**。
--    所以现在的口径是：**发起的那一刻就登记**（内存），失败与退出时落盘，
--    下次启动/进书时由 retryPendingProgress 重试。
M.persistPendingProgress = function()
    if not M._settings_ref then return end
    pcall(function()
        M._settings_ref:set("pending_progress", M.pending_progress)
        M._settings_ref:flush()
    end)
end

-- 待传进度的保留策略：超过 TTL 的丢掉（章节可能已下架，重试也不会成功），
-- 条数超过上限时丢最旧的 —— 否则「每次进书都重试一遍 pending」会变成无休止打接口。
local PENDING_TTL_SECONDS = 7 * 24 * 3600
local PENDING_MAX_ITEMS = 100

-- 读回时做一次清理（TTL + 条数上限），返回被丢掉的条数（便于日志/测试观察）。
M.loadPendingProgress = function()
    if not M._settings_ref then return nil end
    local ok, val = pcall(function() return M._settings_ref:get("pending_progress") end)
    if not ok or type(val) ~= "table" then return nil end

    local now = os.time()
    local kept, dropped = {}, 0
    for key, item in pairs(val) do
        local ts = (type(item) == "table") and tonumber(item.timestamp) or nil
        if type(item) == "table" and (ts == nil or (now - ts) <= PENDING_TTL_SECONDS) then
            kept[key] = item
        else
            dropped = dropped + 1
        end
    end

    local keys = {}
    for k in pairs(kept) do keys[#keys + 1] = k end
    if #keys > PENDING_MAX_ITEMS then
        table.sort(keys, function(a, b)
            return (tonumber(kept[a].timestamp) or 0) < (tonumber(kept[b].timestamp) or 0)
        end)
        for i = 1, #keys - PENDING_MAX_ITEMS do
            kept[keys[i]] = nil
            dropped = dropped + 1
        end
    end

    M.pending_progress = kept
    return dropped
end

M.addPendingProgress = function(book_id, item_id, chapter_idx, progress)
    local key = book_id .. "_" .. item_id
    M.pending_progress[key] = {
        book_id = book_id,
        item_id = item_id,
        chapter_idx = chapter_idx,
        progress = progress,
        timestamp = os.time()
    }
end

M.getPendingProgress = function()
    return M.pending_progress
end

M.removePendingProgress = function(book_id, item_id)
    local key = book_id .. "_" .. item_id
    M.pending_progress[key] = nil
end

M.clearAllPendingProgress = function()
    M.pending_progress = {}
end

M.setLastProgressReport = function(item_id, progress)
    M.last_progress_report[item_id] = {
        progress = progress,
        timestamp = os.time()
    }
end

M.getLastProgressReport = function(item_id)
    return M.last_progress_report[item_id]
end

M.setChapterIndexCache = function(book_id, index)
    M.cached_chapter_index[book_id] = {
        data = index,
        timestamp = os.time()
    }
end

M.getChapterIndexCache = function(book_id)
    local cached = M.cached_chapter_index[book_id]
    if cached then
        local now = os.time()
        if cached.timestamp and (now - cached.timestamp) < CACHE_EXPIRY_SECONDS then
            return cached.data
        else
            M.cached_chapter_index[book_id] = nil
        end
    end
    return nil
end

M.invalidateChapterIndexCache = function(book_id)
    M.cached_chapter_index[book_id] = nil
end

M.invalidateDirectoryCache = function(book_id)
    if M.cached_directory then
        M.cached_directory[book_id] = nil
    end
end

-- ===== 目录内存缓存：内存主源 + 文件后备 =====
-- 结构：cached_directory[book_id] = { chapters = {...}, timestamp = os.time() }
-- 与 chapter_index 一致，采用 CACHE_EXPIRY_SECONDS (24h) TTL，避免进程长时间驻留后
-- 内存数据与文件/服务器严重脱节。
--
-- 注意：Async.run 的 work_func 在子进程执行，子进程内存不回传父进程。
--       因此 setDirectoryCache 只能在父进程（Async 回调 / 主线程）调用，
--       子进程内调用无效。当前所有写入点都在父进程，符合此约束。
M.setDirectoryCache = function(book_id, chapters)
    if not book_id or not chapters then return end
    M.cached_directory = M.cached_directory or {}
    M.cached_directory[book_id] = {
        chapters = chapters,
        timestamp = os.time(),
    }
end

M.getDirectoryCache = function(book_id)
    if not M.cached_directory then return nil end
    local cached = M.cached_directory[book_id]
    if not cached then return nil end
    local now = os.time()
    if cached.timestamp and (now - cached.timestamp) < CACHE_EXPIRY_SECONDS then
        return cached.chapters
    end
    -- 过期：清理单条，避免累计陈旧数据
    M.cached_directory[book_id] = nil
    return nil
end

M.invalidateAllCache = function()
    M.cached_chapter_index = {}
    M.cached_directory = {}
end

M.setTocMenuOpen = function(is_open)
    M.toc_menu_open = is_open
end

M.isTocMenuOpen = function()
    return M.toc_menu_open == true
end

-- 段评开关
M.setReviewEnabled = function(enabled)
    M.enable_review = enabled == true
    persist_review_state(M.enable_review)
end

M.isReviewEnabled = function()
    return M.enable_review == true
end

-- 段评数据管理
M.setCurrentParaReviews = function(para_reviews)
    M.current_para_reviews = para_reviews or {}
    M.current_para_index = 0
end

M.getCurrentParaReviews = function()
    return M.current_para_reviews or {}
end

M.setCurrentParaIndex = function(index)
    M.current_para_index = index or 0
end

M.getCurrentParaIndex = function()
    return M.current_para_index or 0
end

M.clearParaReviews = function()
    M.current_para_reviews = {}
    M.current_para_index = 0
end

-- 章节切换标志：navigateToChapter 期间为 true，防止段评异步回调在切章后弹窗闪现
M.setChapterNavigating = function(v)
    M.chapter_navigating = v == true
end

M.isChapterNavigating = function()
    return M.chapter_navigating == true
end

-- 下载管理
M.setDownloadTask = function(task)
    M.download_task = task
    M.is_downloading = task and true or false
    persist_download_task()
    print("[FanQie][state] setDownloadTask: " .. (task and task.book_title or "nil")
        .. " status=" .. (task and task.status or "nil"))
end

M.getDownloadTask = function()
    return M.download_task
end

M.updateDownloadProgress = function(current, total, chapter)
    if M.download_task then
        M.download_task.current = current
        M.download_task.total = total
        M.download_task.chapter = chapter
    end
end

M.clearDownloadTask = function()
    print("[FanQie][state] clearDownloadTask: was=" .. tostring(M.download_task and M.download_task.book_title or "nil"))
    M.download_task = nil
    M.is_downloading = false
    persist_download_task()
end

-- 「从下载管理取消」的立即生效入口。
--
-- 🔴 为什么需要它（而不是只看 M.download_task 还在不在）：
--    download.lua 只在**每一章开始之前**检查 `not _state.download_task`，
--    而单章下载跑在 Async 子进程里 —— 图集/漫画一整章几十页大图，实测 1~5 分钟。
--    于是「点取消」的真实表现是「进度条继续往前爬几分钟」，用户以为取消没生效。
--    下载流程开始时会注册一个 handler，这里回调它：立刻掐掉当前章的子进程并收尾
--    （close 进度框、写历史、清状态），做到「一点就停」。
M._download_cancel_handler = nil

M.setDownloadCancelHandler = function(fn)
    M._download_cancel_handler = type(fn) == "function" and fn or nil
end

M.requestDownloadCancel = function()
    M.download_cancel_requested = true
    if type(M._download_cancel_handler) == "function" then
        local ok, err = pcall(M._download_cancel_handler)
        if not ok then
            print("[FanQie][state] requestDownloadCancel handler error: " .. tostring(err))
        end
    end
end

M.addDownloadHistory = function(task)
    if not task then return end
    task.end_time = os.time()
    table.insert(M.download_history, 1, task)
    -- 只保留最近 10 条
    while #M.download_history > 10 do
        table.remove(M.download_history)
    end
    persist_download_history()
    print("[FanQie][state] addDownloadHistory: " .. tostring(task.book_title)
        .. " status=" .. tostring(task.status)
        .. " history_count=" .. tostring(#M.download_history))
end

M.getDownloadHistory = function()
    return M.download_history or {}
end

M.clearDownloadHistory = function()
    M.download_history = {}
    persist_download_history()
end

return M