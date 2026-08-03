-- fanqie/download.lua
-- 公共下载模块：书架 + 阅读界面共用同一套下载选项与执行逻辑。
-- 特性：
--   * 下载选项对话框（全部/前10章/当前阅读后N章/剩余全部/自定义范围）
--   * 严格按书源 rate_limit 配置主动等待（通过 rate_limit_peek 预检）
--   * 进度条显示预估剩余时间（实测滚动平均耗时）
--   * 跳过已缓存章节、取消、失败统计

local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_ButtonDialog, ButtonDialog = pcall(require, "ui/widget/buttondialog")
local ok_InputDialog, InputDialog = pcall(require, "ui/widget/inputdialog")
local ok_util, util = pcall(require, "util")
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local ok_H, H = pcall(require, "fanqie.helper")
local ok_Content, Content = pcall(require, "fanqie.content")
local ok_SM, SM = pcall(require, "fanqie.sources")
local ok_state, _state = pcall(require, "fanqie.state")
local ok_DLProgress, DownloadProgress = pcall(require, "fanqie.download_progress")
local ok_Log, Log = pcall(require, "fanqie.logger")
local ok_Async, Async = pcall(require, "fanqie.async")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

-- 高精度计时（ms），与 content.lua 一致
local ok_socket, socket = pcall(require, "socket")
local function now_ms()
    if ok_socket and socket and socket.gettime then
        return socket.gettime() * 1000
    end
    return os.clock() * 1000
end

local Download = {}

-- 将秒数格式化为 "Xs" / "X分Y秒" / "X时Y分"
local function formatEta(sec)
    sec = math.max(0, math.floor(tonumber(sec) or 0))
    if sec < 60 then return string.format("%ds", sec) end
    local m = math.floor(sec / 60)
    local s = sec % 60
    if m < 60 then return string.format("%d分%d秒", m, s) end
    local h = math.floor(m / 60)
    m = m % 60
    return string.format("%d时%d分", h, m)
end

-- 获取书的已缓存章节索引（item_id -> path），与 main.lua getCachedChapters 等价
local function getCachedChapters(settings, book)
    if not book then return {} end
    if not book.cached_chapters then
        book.cached_chapters = Content.load_cache_index(settings, book.book_id) or {}
    end
    return book.cached_chapters
end

-- 频次预检：若所有活跃源都被限流，主动等待窗口恢复。
-- 返回 true 表示至少一个源可用；false 表示用户取消。
local function waitForRateLimit(settings, dialog, current, total)
    if not ok_SM then return true end
    while true do
        local sources = SM.get_active_sources(settings)
        if #sources == 0 then return true end  -- 无源配置，交给 fetch 报错
        local max_wait = 0
        local any_ok = false
        for _, src in ipairs(sources) do
            local rl = src.config.rate_limit or {}
            local ok, wait = SM.rate_limit_peek(src.id, rl.max_requests, rl.window_seconds)
            if ok then any_ok = true; break end
            if wait and wait > max_wait then max_wait = wait end
        end
        if any_ok then return true end
        if dialog:isCanceled() then return false end
        local wait_int = math.max(1, math.ceil(max_wait))
        dialog:setState{
            stage = "rate_limit",
            current = current, total = total,
            message = string.format("剩余 %ds", wait_int),
        }
        -- 分段睡，每秒检查取消并更新剩余等待
        for i = 1, wait_int do
            if dialog:isCanceled() then return false end
            if ok_util then util.sleep(1) else os.execute("sleep 1") end
            dialog:setState{
                stage = "rate_limit",
                current = current, total = total,
                message = string.format("剩余 %ds", wait_int - i),
            }
        end
    end
end

-- 执行下载（异步递归实现，UI 线程仅做进度刷新与调度，不阻塞）
-- 每一章的 HTTP 请求通过 Async.run 放到子进程，父进程拿到结果后递归调度下一章。
function Download.execute(parent, book, chapters, start_idx, end_idx)
    local settings = parent.settings
    local client = parent.client
    local total = end_idx - start_idx + 1
    local b = { book_id = book.book_id, title = book.title, author = book.author }
    local self_ref = parent

    -- 设置全局下载任务状态
    if ok_state and _state then
        _state.setDownloadTask({
            book_id = book.book_id,
            book_title = book.title or book.book_id,
            current = 0,
            total = total,
            chapter = "",
            status = "downloading",
            start_time = os.time(),
        })
    end
    if ok_Log and Log then
        Log.info("[Download] execute: book=" .. tostring(book.title or book.book_id)
            .. " range=" .. tostring(start_idx) .. "-" .. tostring(end_idx)
            .. " total=" .. tostring(total))
    end

    local dialog = DownloadProgress:new{
        title = T(_("下载 %s"), book.title or book.book_id),
    }
    -- 设置后台运行回调（对话框关闭但下载继续）
    -- 关键：关闭后必须确保有 widget 显示，否则 UIManager 会退出，内存状态丢失
    dialog.on_background = function()
        dialog._backgrounded = true
        dialog:close()
        -- 延迟检查，等 dialog:close() 完成
        UIManager:scheduleIn(0, function()
            -- 检查是否有 FileManager/ReaderUI 实例
            local has_ui = false
            local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
            if ok_rui and ReaderUI and ReaderUI.instance then has_ui = true end
            if not has_ui then
                local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
                if ok_fm and FileManager and FileManager.instance then has_ui = true end
            end
            -- 没有 FileManager/ReaderUI 且书架已关闭时，重新显示书架避免 UIManager 退出
            -- 如果书架还在（parent.book_list_menu 存在），不需要重新显示
            if not has_ui and parent and parent.showBookshelf and not parent.book_list_menu then
                if Log then Log.info("[FanQie] background: no FM/ReaderUI, show bookshelf to prevent exit") end
                parent:showBookshelf()
            end
        end)
    end
    dialog:show()
    dialog:setState{ stage = "prepare", current = 0, total = total }

    -- 下载会话状态（闭包内共享）
    local state = {
        downloaded = 0,
        failed = 0,
        skipped = 0,
        cached_chapters = {},
        book = book,
        chapters = chapters,
        start_idx = start_idx,
        end_idx = end_idx,
        total = total,
        review_enabled = false,
    }

    -- 预先计算段评开关（只读，跨子进程保持一致）
    if ok_state and _state and _state.isReviewEnabled then
        state.review_enabled = _state.isReviewEnabled()
    end

    -- 快照当前缓存（item_id -> path），用于跳过已缓存章节
    if ok_Content and Content then
        state.cached_chapters = Content.load_cache_index(settings, book.book_id) or {}
    end

    local function updateProgress(stage, chapter_title)
        dialog:setState{
            stage = stage,
            current = state.downloaded,
            total = state.total,
            chapter = chapter_title,
        }
        -- 更新全局状态
        if ok_state and _state then
            _state.updateDownloadProgress(state.downloaded, state.total, chapter_title or "")
        end
    end

    local function finish()
        if not dialog._backgrounded then
            dialog:close()
        end
        local cancelled = dialog:isCanceled()
        if ok_Log and Log then
            Log.info("[Download] finish: downloaded=" .. tostring(state.downloaded)
                .. " failed=" .. tostring(state.failed)
                .. " skipped=" .. tostring(state.skipped)
                .. " cancelled=" .. tostring(cancelled)
                .. " backgrounded=" .. tostring(dialog._backgrounded))
        end
        -- 清除全局下载任务
        if ok_state and _state then
            local task = _state.getDownloadTask()
            if task then
                task.status = cancelled and "cancelled" or "completed"
                task.current = state.downloaded
                task.failed = state.failed
                task.skipped = state.skipped
                _state.addDownloadHistory(task)
                if ok_Log and Log then
                    Log.info("[Download] addDownloadHistory: book=" .. tostring(task.book_title)
                        .. " status=" .. tostring(task.status))
                end
            else
                if ok_Log and Log then
                    Log.warn("[Download] finish: download_task is nil, cannot add history")
                end
            end
            _state.clearDownloadTask()
        end

        if cancelled and state.downloaded < state.total then
            self_ref:showInfo(T(_("已取消下载\n已保存 %1/%2 章"), state.downloaded, state.total))
        else
            local msg = T(_("下载完成!\n《%s》共 %1/%2 章"), book.title or book.book_id, state.downloaded, state.total)
            if state.skipped > 0 then msg = msg .. T(_(" (跳过已缓存 %d 章)"), state.skipped) end
            if state.failed > 0 then msg = msg .. T(_(" (失败 %d 章)"), state.failed) end
            self_ref:showInfo(msg)
        end
    end

    -- 轮询式调度：每次下载一章 -> 子进程回调 -> UIManager:scheduleIn 触发下一章
    -- 避免单次子进程生命周期过长、UI 无感。
    local function schedule_next(idx)
        if idx > state.end_idx then
            finish()
            return
        end

        -- 检查是否取消（对话框取消 或 从下载管理取消）
        if dialog:isCanceled() then
            finish()
            return
        end
        if ok_state and _state and not _state.download_task then
            -- 从下载管理取消
            dialog.cancelled = true
            finish()
            return
        end

        local chapter = state.chapters[idx]
        local item_id = tostring(chapter.itemId)
        local chapter_title = chapter.title or string.format(_("第%d章"), idx)

        -- 已缓存跳过（检查快照 + book 最新缓存，避免与预下载重复）
        local cached_path = state.cached_chapters[item_id]
        -- 如果快照中没有，检查 book.cached_chapters（预下载可能已更新）
        if not cached_path and state.book and state.book.cached_chapters then
            cached_path = state.book.cached_chapters[item_id]
            if cached_path then
                state.cached_chapters[item_id] = cached_path  -- 同步到快照
            end
        end
        if cached_path and ok_H and H and H.file_exists(cached_path) then
            state.skipped = state.skipped + 1
            state.downloaded = state.downloaded + 1
            updateProgress("content", chapter_title)
            UIManager:scheduleIn(0, function() schedule_next(idx + 1) end)
            return
        end

        -- 频次预检 + 等待（UI 线程本地判断，非 IO）
        if ok_SM and SM then
            local sources = SM.get_active_sources(settings)
            if #sources == 0 then
                -- 无源配置，继续让子进程尝试，由子进程报错
            else
                local any_ok = false
                local max_wait = 0
                for _, src in ipairs(sources) do
                    local rl = src.config.rate_limit or {}
                    local rl_ok, wait = SM.rate_limit_peek(src.id, rl.max_requests, rl.window_seconds)
                    if rl_ok then any_ok = true; break end
                    if wait and wait > max_wait then max_wait = wait end
                end
                if not any_ok and max_wait > 0 then
                    local wait_int = math.max(1, math.ceil(max_wait))
                    dialog:setState{
                        stage = "rate_limit",
                        current = state.downloaded, total = state.total,
                        message = string.format("剩余 %ds", wait_int),
                    }
                    UIManager:scheduleIn(wait_int, function() schedule_next(idx) end)
                    return
                end
            end
        end

        updateProgress("content", chapter_title)

        -- 子进程内下载章节（HTTP + 文件 IO），UI 线程不阻塞
        local fetch_opts = state.review_enabled and { review = true, skip_cache_index = true }
            or { skip_cache_index = true }
        local work_fn = function()
            local path, ch, para_reviews, rate_info = Content.fetch_chapter_html(
                client, settings, b, chapter, fetch_opts
            )
            return {
                path = path,
                item_id = item_id,
                rate_info = rate_info,
            }
        end

        local function on_done(ok, result, err)
            if not ok or type(result) ~= "table" or not result.path then
                state.failed = state.failed + 1
                if ok_Log and Log then
                    Log.warn("[FanQie] chapter download failed:", chapter_title, tostring(err or result))
                end
            else
                state.cached_chapters[result.item_id] = result.path
                state.downloaded = state.downloaded + 1
                -- 合并子进程限流时间戳（子进程会随退出丢失）
                if result.rate_info and ok_SM and SM and SM.merge_rate_limit_timestamps then
                    SM.merge_rate_limit_timestamps(result.rate_info)
                end
                -- 父进程持久化 cache_index
                if ok_Content and Content and Content.save_cache_index then
                    Content.save_cache_index(settings, book.book_id, state.cached_chapters)
                end
            end

            updateProgress("content", chapter_title)

            if dialog:isCanceled() then
                finish()
                return
            end
            -- 继续下一章（scheduleIn 而非直接递归，让出 UI 事件循环）
            UIManager:scheduleIn(0, function() schedule_next(idx + 1) end)
        end

        if ok_Async and Async and Async.run then
            Async.run(work_fn, on_done, { poll_interval = 0.125, timeout = 90 })
        else
            -- 降级：同步执行（极少触发，仅当 Async 模块未加载）
            local ok_sync, res = pcall(work_fn)
            on_done(ok_sync, res, ok_sync and nil or res)
        end
    end

    schedule_next(start_idx)
end

-- 自定义范围输入对话框
local function showCustomRangeDialog(parent, book, chapters, current_index)
    local dialog
    local default_text = current_index
        and string.format("%d-%d", math.min(current_index + 1, #chapters), #chapters)
        or ("1-" .. tostring(#chapters))
    dialog = InputDialog:new{
        title = _("下载范围"),
        input = default_text,
        input_hint = _("格式: 起始-结束 (如 1-50)"),
        description = T(_("共 %1 章，输入下载范围"), #chapters),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("下载"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        local s_str, e_str = text:match("^(%d+)%s*-%s*(%d+)$")
                        if not (s_str and e_str) then
                            parent:showInfo(_("格式错误，请使用 起始-结束 格式"))
                            return
                        end
                        local s = tonumber(s_str)
                        local e = tonumber(e_str)
                        if s < 1 then s = 1 end
                        if e > #chapters then e = #chapters end
                        if s > e then s, e = e, s end
                        UIManager:close(dialog)
                        Download.execute(parent, book, chapters, s, e)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- "当前阅读后N章"输入对话框
local function showAfterNDialog(parent, book, chapters, current_index)
    local dialog
    dialog = InputDialog:new{
        title = _("下载当前阅读后N章"),
        input = "10",
        input_hint = T(_("当前阅读第%1章，输入要下载的后续章节数"), current_index),
        description = T(_("从第 %1 章开始下载"), current_index + 1),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("下载"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText()
                        local n = tonumber(text)
                        if not n or n < 1 then
                            parent:showInfo(_("请输入有效数字"))
                            return
                        end
                        local s = current_index + 1
                        local e = math.min(current_index + n, #chapters)
                        if s > e then
                            parent:showInfo(_("已是最后一章"))
                            return
                        end
                        UIManager:close(dialog)
                        Download.execute(parent, book, chapters, s, e)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- 下载选项对话框（主入口）
-- opts.current_index: 当前阅读章节序号（阅读界面传入，书架不传）
-- opts.cached_count: 已缓存章节数（可选，显示在提示文字中）
function Download.showOptionsDialog(parent, book, chapters, opts)
    opts = opts or {}
    local current_index = opts.current_index
    local cached_count = opts.cached_count or 0
    local total = #chapters
    local has_current = current_index and current_index >= 1 and current_index < total

    -- 检查是否正在下载（避免重复下载请求）
    if ok_state and _state and _state.is_downloading then
        parent:showInfo(_("正在下载中，请稍候再试"))
        return
    end

    local info_text = T(_("共 %1 章"), total)
    if cached_count > 0 then
        info_text = info_text .. T(_("，已缓存 %1 章（下载时将自动跳过）"), cached_count)
    end
    info_text = info_text .. _("，请选择下载范围")

    local dialog
    local buttons = {
        {
            { text = _("全部下载"), callback = function()
                UIManager:close(dialog)
                Download.execute(parent, book, chapters, 1, total)
            end },
            { text = _("前10章"), callback = function()
                UIManager:close(dialog)
                Download.execute(parent, book, chapters, 1, math.min(10, total))
            end },
        },
    }

    if has_current then
        -- 阅读界面：含"当前阅读后N章"与"下载剩余全部"
        buttons[#buttons + 1] = {
            { text = _("当前阅读后N章"), callback = function()
                UIManager:close(dialog)
                showAfterNDialog(parent, book, chapters, current_index)
            end },
            { text = _("下载剩余全部"), callback = function()
                UIManager:close(dialog)
                Download.execute(parent, book, chapters, current_index + 1, total)
            end },
        }
        buttons[#buttons + 1] = {
            { text = _("自定义范围"), callback = function()
                UIManager:close(dialog)
                showCustomRangeDialog(parent, book, chapters, current_index)
            end },
            { text = _("取消"), callback = function()
                UIManager:close(dialog)
            end },
        }
    else
        -- 书架：仅基础三项
        buttons[#buttons + 1] = {
            { text = _("自定义范围"), callback = function()
                UIManager:close(dialog)
                showCustomRangeDialog(parent, book, chapters, nil)
            end },
            { text = _("取消"), callback = function()
                UIManager:close(dialog)
            end },
        }
    end

    dialog = ButtonDialog:new{
        title = _("下载范围"),
        title_align = "center",
        info_text = info_text,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return Download
