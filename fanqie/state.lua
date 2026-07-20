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
}

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

return M