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
    active_menu = nil,
    detail_dialog = nil,
    is_downloading = false,
    last_page_number = nil,
    start_of_chapter_triggered = false,
    document_opened = false,
    -- 段评相关状态
    enable_review = false,           -- 段评开关
    current_para_reviews = {},      -- 当前章节的段评数据
    current_para_index = 0,         -- 当前选中的段评索引
    -- 内部引用：可选，用于持久化段评开关
    _settings_ref = nil,
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
end

-- 把 enable_review 持久化到 Settings（若 settings 可用）
local function persist_review_state(enabled)
    if not M._settings_ref then return end
    pcall(function() M._settings_ref:setParaReviewEnabled(enabled == true) end)
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

return M