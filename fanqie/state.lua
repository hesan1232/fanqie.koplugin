local CACHE_EXPIRY_SECONDS = 86400

local M = {
    current_book = nil,
    current_chapters = nil,
    current_chapter_index = nil,
    current_document_path = nil,
    cached_directory = nil,
    pending_progress = {},
    last_progress_report = {},
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