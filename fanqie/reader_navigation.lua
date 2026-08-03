local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T = _

local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_InfoMessage, InfoMessage = pcall(require, "ui/widget/infomessage")

local ok_H, H = pcall(require, "fanqie.helper")
local ok_Log, Log = pcall(require, "fanqie.logger")
local ok_Content, Content = pcall(require, "fanqie.content")
local ok_state, _state = pcall(require, "fanqie.state")
local ok_Async, Async = pcall(require, "fanqie.async")
local ok_SM, SM = pcall(require, "fanqie.sources")

local ReaderNavigation = {}

function ReaderNavigation:navigateToChapter(book, chapters, chapter_index, opts)
    opts = opts or {}
    local chapter = chapters[chapter_index]
    if not chapter then
        self:showInfo(_("章节不存在"))
        return false
    end

    -- 中断预下载（后台预下载不应阻塞用户阅读）
    -- 预下载的 on_done 会检查 pre_download_triggered，若为 false 则停止调度
    if _state.pre_download_triggered then
        _state.pre_download_triggered = false
        if Log then Log.info("navigateToChapter: aborting pre-download for user navigation") end
    end

    if _state.is_downloading then
        -- 用户主动下载进行中：给用户明确提示
        self:showInfo(_("正在下载中，请稍候再试"))
        return false
    end

    _state.current_book = book
    _state.current_chapters = chapters

    -- 从全局状态获取段评开关
    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = { skip_cache_index = true }
    if review_enabled then fetch_opts.review = true end

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

    -- 如果段评开启且有缓存，检查是否需要重新下载（如果没有段评数据）
    if existing_path and review_enabled then
        local existing_reviews = Content and Content.load_para_reviews_index(self.settings, book.book_id, item_id) or {}
        if #existing_reviews == 0 then
            existing_path = nil  -- 没有段评数据，需要重新获取
        end
    end

    -- If not found in cache index, try to find file directly from filesystem
    if not existing_path or not (H and H.file_exists(existing_path)) then
        local found_path = Content and Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found_path then
            -- Update cache index with found file
            book.cached_chapters = book.cached_chapters or {}
            book.cached_chapters[item_id] = found_path
            Content.save_cache_index(self.settings, book.book_id, book.cached_chapters)
            existing_path = found_path
            if Log then Log.info("found cached chapter in filesystem:", item_id) end
        end
    end

    if existing_path and H and H.file_exists(existing_path) then
        _state.current_chapter_index = chapter_index
        _state.pre_download_triggered = false
        -- 加载段评数据
        if review_enabled then
            local reviews = Content and Content.load_para_reviews_index(self.settings, book.book_id, item_id) or {}
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

    local self_ref = self
    local b = { book_id = book.book_id, title = book.title, author = book.author }
    local client = self.client
    local settings = self.settings

    local work_fn = function()
        local path, ch, para_reviews, rate_info = Content and Content.fetch_chapter_html(
            client, settings, b, chapter, fetch_opts
        )
        return { path = path, para_reviews = para_reviews, rate_info = rate_info }
    end

    local function on_done(ok, result, err)
        self_ref:closeBusy()

        if not ok or type(result) ~= "table" or not result.path then
            if Log then Log.error("navigateToChapter download failed:", tostring(err or result)) end
            _state.is_downloading = false
            self_ref:showError(T(_(opts.error_message or "下载章节失败:\n%1"),
                self_ref:displayError(err or result)))
            return
        end

        -- 合并子进程限流时间戳（子进程会随退出丢失）
        if result.rate_info and ok_SM and SM and SM.merge_rate_limit_timestamps then
            SM.merge_rate_limit_timestamps(result.rate_info)
        end

        local path = result.path
        local para_reviews = result.para_reviews

        book.cached_chapters = book.cached_chapters or {}
        book.cached_chapters[item_id] = path

        -- 持久化 cache_index
        if Content and Content.save_cache_index then
            local cc = Content.load_cache_index(settings, book.book_id) or {}
            cc[item_id] = path
            Content.save_cache_index(settings, book.book_id, cc)
        end

        -- 存储段评数据到全局状态
        if review_enabled and para_reviews then
            _state.setCurrentParaReviews(para_reviews)
        end

        _state.current_chapter_index = chapter_index
        _state.pre_download_triggered = false
        _state.is_downloading = false
        self_ref:showReaderUI(path, chapter)

        if opts.after_navigate then
            UIManager:scheduleIn(1.0, opts.after_navigate)
        end
    end

    if ok_Async and Async and Async.run then
        Async.run(work_fn, on_done, { poll_interval = 0.125, timeout = 120 })
    else
        -- 降级：同步执行
        local ok_sync, res = pcall(work_fn)
        on_done(ok_sync, res, ok_sync and nil or res)
    end

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
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(path, true)  -- seamless=true 隐藏"打开文件"提示
    else
        ReaderUI:showReader(path, nil, true)  -- seamless=true 隐藏"打开文件"提示
    end
end

function ReaderNavigation:preDownloadChapters(book, chapters, current_index)
    if _state.pre_download_triggered then return end
    _state.pre_download_triggered = true

    local cache = self.settings:get("cache", {})
    local pre_download_count = cache.pre_download_chapters or 3
    local start_idx = current_index + 1
    local end_idx = math.min(current_index + pre_download_count, #chapters)

    if start_idx > end_idx then
        _state.pre_download_triggered = false
        return
    end

    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = review_enabled and { review = true, skip_cache_index = true } or { skip_cache_index = true }
    local self_ref = self
    local client = self.client
    local settings = self.settings
    local b = { book_id = book.book_id, title = book.title, author = book.author }

    -- 递归异步下载：每次下载一章 -> 检查取消/限流 -> 下载下一章
    local function download_one(idx)
        if idx > end_idx then
            _state.pre_download_triggered = false
            _state.pre_downloading = false
            return
        end

        -- 如果被用户操作中断（navigateToChapter 设置 pre_download_triggered=false），停止
        if not _state.pre_download_triggered then
            _state.pre_downloading = false
            if Log then Log.info("pre-download: aborted by user navigation") end
            return
        end

        -- 如果用户主动下载（手动下载/跳章下载），中断预下载，让用户操作优先
        if _state.is_downloading then
            _state.pre_download_triggered = false
            _state.pre_downloading = false
            if Log then Log.info("pre-download: aborted, user download in progress") end
            return
        end

        local chapter = chapters[idx]
        local item_id = tostring(chapter.itemId)

        -- 检查是否已缓存
        local cached_chapters = book.cached_chapters or Content.load_cache_index(settings, book.book_id) or {}
        local existing_path = cached_chapters[item_id]

        -- 如果段评开启，还需检查是否有段评数据
        if existing_path and review_enabled then
            local existing_reviews = Content and Content.load_para_reviews_index(settings, book.book_id, item_id) or {}
            if #existing_reviews == 0 then
                existing_path = nil  -- 没有段评数据，需要重新获取
            end
        end

        if existing_path and H and H.file_exists(existing_path) then
            -- 已缓存，跳过
            if Log then Log.info("pre-download: skipping cached chapter", idx) end
            UIManager:scheduleIn(0, function() download_one(idx + 1) end)
            return
        end

        -- 限流预检：检查所有活跃源是否可用
        if ok_SM and SM then
            local sources = SM.get_active_sources(settings)
            if #sources > 0 then
                local any_ok = false
                local max_wait = 0
                for _, src in ipairs(sources) do
                    local rl = src.config.rate_limit or {}
                    local rl_ok, wait = SM.rate_limit_peek(src.id, rl.max_requests, rl.window_seconds)
                    if rl_ok then any_ok = true; break end
                    if wait and wait > max_wait then max_wait = wait end
                end
                if not any_ok and max_wait > 0 then
                    -- 所有源都被限流，等待后重试
                    if Log then Log.info("pre-download: rate limited, waiting", max_wait, "s") end
                    UIManager:scheduleIn(max_wait, function() download_one(idx) end)
                    return
                end
            end
        end

        -- 设置预下载标志（独立于 is_downloading，不阻塞用户阅读）
        _state.pre_downloading = true

        if Log then Log.info("pre-download: downloading chapter", idx) end

        -- 异步下载（子进程执行 HTTP + IO）
        local work_fn = function()
            local path, ch, para_reviews, rate_info = Content.fetch_chapter_html(
                client, settings, b, chapter, fetch_opts
            )
            return { path = path, item_id = item_id, rate_info = rate_info }
        end

        local function on_done(ok, result, err)
            _state.pre_downloading = false

            -- 如果已被中断，不继续调度
            if not _state.pre_download_triggered then
                if Log then Log.info("pre-download: interrupted, stop scheduling") end
                return
            end

            if not ok or type(result) ~= "table" or not result.path then
                if Log then Log.warn("pre-download: failed chapter", idx, tostring(err or result)) end
            else
                -- 更新缓存索引
                cached_chapters[result.item_id] = result.path
                book.cached_chapters = cached_chapters
                if Content and Content.save_cache_index then
                    Content.save_cache_index(settings, book.book_id, cached_chapters)
                end

                -- 合并子进程限流时间戳
                if result.rate_info and ok_SM and SM and SM.merge_rate_limit_timestamps then
                    SM.merge_rate_limit_timestamps(result.rate_info)
                end

                if Log then Log.info("pre-download: completed chapter", idx) end
            end

            -- 继续下一章
            UIManager:scheduleIn(0.5, function() download_one(idx + 1) end)
        end

        if ok_Async and Async and Async.run then
            Async.run(work_fn, on_done, { poll_interval = 0.125, timeout = 90 })
        else
            -- 降级：同步执行
            local ok_sync, res = pcall(work_fn)
            on_done(ok_sync, res, ok_sync and nil or res)
        end
    end

    -- 延迟启动，给UI线程让出时间
    UIManager:scheduleIn(1.0, function() download_one(start_idx) end)
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
