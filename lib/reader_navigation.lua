local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_InfoMessage, InfoMessage = pcall(require, "ui/widget/infomessage")

local ok_H, H = pcall(require, "lib.helper")
local ok_Log, Log = pcall(require, "lib.logger")
local ok_Content, Content = pcall(require, "lib.content")
local ok_state, _state = pcall(require, "lib.state")

local ReaderNavigation = {}

function ReaderNavigation:navigateToChapter(book, chapters, chapter_index, opts)
    opts = opts or {}
    local chapter = chapters[chapter_index]
    if not chapter then return false end

    if _state.is_downloading then
        return false
    end

    _state.current_book = book
    _state.current_chapters = chapters

    local item_id = tostring(chapter.itemId)
    local existing_path = nil
    
    if book.cached_chapters then
        existing_path = book.cached_chapters[item_id]
    else
        local cached = _state.getChapterIndexCache(book.book_id)
        if cached then
            existing_path = cached[item_id]
        else
            book.cached_chapters = Content and Content.load_cache_index(self.settings, book.book_id) or {}
            existing_path = book.cached_chapters[item_id]
        end
    end

    if existing_path and H and H.file_exists(existing_path) then
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
            return Content and Content.fetch_chapter_html(self.client, self.settings, b, chapter)
        end)
        self:closeBusy()

        if not ok then
            if Log then Log.error("navigateToChapter download failed:", tostring(path)) end
            _state.is_downloading = false
            self:showError(T(_(opts.error_message or "下载章节失败:\n%1"), self:displayError(path)))
            return
        end

        book.cached_chapters = book.cached_chapters or {}
        book.cached_chapters[item_id] = path

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

function ReaderNavigation:openChapter(book, chapters, chapter_index)
    return self:navigateToChapter(book, chapters, chapter_index, {
        error_message = "下载章节失败:\n%1",
    })
end

function ReaderNavigation:showReaderUI(path, chapter)
    _state.current_document_path = path
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

function ReaderNavigation:preDownloadChapters(book, chapters, current_index)
    if _state.pre_download_triggered then return end
    _state.pre_download_triggered = true

    local pre_download_count = self.settings:get("pre_download_count", 5)
    local start_idx = current_index + 1
    local end_idx = math.min(current_index + pre_download_count, #chapters)

    if start_idx > end_idx then
        return
    end

    UIManager:scheduleIn(2.0, function()
        for i = start_idx, end_idx do
            if _state.is_downloading then
                break
            end
            local chapter = chapters[i]
            local item_id = tostring(chapter.itemId)
            local existing_path = nil
            if book.cached_chapters then
                existing_path = book.cached_chapters[item_id]
            else
                local cached = _state.getChapterIndexCache(book.book_id)
                existing_path = cached and cached[item_id]
            end
            if not existing_path or not H.file_exists(existing_path) then
                local ok, path = pcall(function()
                    local b = { book_id = book.book_id, title = book.title, author = book.author }
                    return Content.fetch_chapter_html(self.client, self.settings, b, chapter)
                end)
                if ok then
                    book.cached_chapters = book.cached_chapters or {}
                    book.cached_chapters[item_id] = path
                end
            end
        end
    end)
end

function ReaderNavigation:getCurrentPageProgress()
    if not self.ui or not self.ui.document then return 0 end
    local doc = self.ui.document
    local current_page = self.ui.view.state.page
    local total_pages = doc:getPageCount()
    if total_pages <= 0 then return 0 end
    return current_page / total_pages
end

function ReaderNavigation:syncCurrentProgress()
    if not _state.current_book or not _state.current_chapters then return end
    local book = _state.current_book
    local chapters = _state.current_chapters
    local current_idx = _state.current_chapter_index or 0

    if current_idx <= 0 or current_idx > #chapters then return end

    local chapter = chapters[current_idx]
    if not chapter or not chapter.itemId then return end

    local page_progress = self:getCurrentPageProgress()
    local chapter_progress = (current_idx - 1 + page_progress) / #chapters

    local last_report = _state.getLastProgressReport(chapter.itemId)
    if last_report and last_report.progress >= page_progress then
        return
    end

    local book_id = book.book_id
    local item_id = chapter.itemId
    local idx = current_idx

    UIManager:scheduleIn(1.0, function()
        local ok, err = pcall(function()
            self.client:update_read_progress(book_id, item_id, idx - 1, page_progress)
        end)
        if ok then
            _state.setLastProgressReport(item_id, page_progress)
            _state.removePendingProgress(book_id, item_id)
        else
            _state.addPendingProgress(book_id, item_id, idx - 1, page_progress)
        end
    end)
end

function ReaderNavigation:retryPendingProgress()
    local pending = _state.getPendingProgressList()
    if not pending or #pending == 0 then return end

    for _, item in ipairs(pending) do
        local ok, err = pcall(function()
            self.client:update_read_progress(item.book_id, item.item_id, item.chapter_index, item.progress)
        end)
        if ok then
            _state.setLastProgressReport(item.item_id, item.progress)
            _state.removePendingProgress(item.book_id, item.item_id)
        end
    end
end

function ReaderNavigation:onPageUpdate(pageno)
    if not self:isCurrentDocFanqie() then return end
    if pageno % 10 == 0 then
        self:syncCurrentProgress()
    end
end

function ReaderNavigation:onStartOfBook()
    if Log then Log.info("fanqie onStartOfBook called") end
    
    if not _state.current_book or not _state.current_chapters then
        if Log then Log.info("fanqie onStartOfBook: current_book or current_chapters is nil") end
        return false
    end
    
    local is_fanqie = self:isCurrentDocFanqie()
    if Log then Log.info("fanqie onStartOfBook: is_fanqie=", is_fanqie) end
    
    if not is_fanqie then
        return false
    end

    local current_idx = _state.current_chapter_index or 0
    local chapters = _state.current_chapters
    local book = _state.current_book

    if Log then Log.info("fanqie onStartOfBook: current_idx=", current_idx, "total_chapters=", #chapters) end

    if current_idx <= 1 then
        UIManager:show(InfoMessage:new{
            text = _("已经是第一章了"),
            timeout = 3,
        })
        return true
    end

    local prev_idx = current_idx - 1
    local prev_chapter = chapters[prev_idx]
    if not prev_chapter then
        return true
    end

    self:navigateToChapter(book, chapters, prev_idx, {
        error_message = "加载上一章失败:\n%1",
        after_navigate = function()
            self:syncCurrentProgress()
            self:preDownloadChapters(book, chapters, prev_idx)
            self:retryPendingProgress()
        end,
    })

    return true
end

function ReaderNavigation:onEndOfBook()
    if Log then Log.info("fanqie onEndOfBook called") end
    
    if not _state.current_book or not _state.current_chapters then
        if Log then Log.info("fanqie onEndOfBook: current_book or current_chapters is nil") end
        return false
    end
    
    local is_fanqie = self:isCurrentDocFanqie()
    if Log then Log.info("fanqie onEndOfBook: is_fanqie=", is_fanqie) end
    
    if not is_fanqie then
        return false
    end

    local current_idx = _state.current_chapter_index or 0
    local chapters = _state.current_chapters
    local book = _state.current_book
    if Log then Log.info("fanqie onEndOfBook triggered: current_idx=", current_idx, "total_chapters=", #chapters) end

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

function ReaderNavigation:onCloseDocument()
    if not self:isCurrentDocFanqie() then return end
    if Log then Log.info("fanqie onCloseDocument called") end
    self:syncCurrentProgress()
end

function ReaderNavigation:onClose()
    if Log then Log.info("fanqie onClose called") end
    if self:isCurrentDocFanqie() then
        self:syncCurrentProgress()
    end
end

function ReaderNavigation:onCloseWidget()
    if Log then Log.info("fanqie onCloseWidget called") end
    if self:isCurrentDocFanqie() then
        self:syncCurrentProgress()
    end
end

function ReaderNavigation:onShowFanQieToc()
    if not _state.current_book then return end
    self:showChapterListing(_state.current_book)
end

function ReaderNavigation:onShowFanQieBookshelf()
    self:showBookshelf()
end

function ReaderNavigation:openBook(book)
    local ok, chapters = pcall(function()
        return self:get_chapters(book.book_id)
    end)
    if not ok then
        if Log then Log.error("fetch chapters failed:", tostring(chapters)) end
        self:showError(T(_("获取目录失败:\n%1"), self:displayError(chapters)))
        return
    end

    local start_idx = 1
    if book.read_chapters and book.read_chapters > 0 then
        start_idx = math.min(book.read_chapters + 1, #chapters)
    end

    self:openChapter(book, chapters, start_idx)
end

return ReaderNavigation
