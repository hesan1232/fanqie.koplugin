-- fanqie/async.lua
-- 异步子进程执行模块：把阻塞的网络/IO 操作放到子进程，UI 线程通过
-- UIManager:scheduleIn 轮询管道，保持 KOReader 界面响应。
--
-- 设计参考 koreader frontend/ui/trapper.lua 的 runInSubProcess + pipe 模式
-- （见 trapper.lua dismissableRunInSubprocess），以及 assistant.koplugin
-- 的 backgroundRequest 用法。区别于 trapper 的是：本模块不依赖 TrapWidget，
-- 采用纯回调驱动（on_done），适合“后台静默执行”的进度上传 / 预下载场景。
--
-- 协议：子进程执行 work_func，把结果以 JSON 写入管道后关闭 fd：
--   成功: {"ok":true,"result":<可序列化值>}
--   失败: {"ok":false,"err":"<错误信息>"}
-- 父进程在 UI 线程轮询 getNonBlockingReadSize / isSubProcessDone，
-- 一次性 readAllFromFD 读取并解析，最后回调 on_done(ok, result, err)。
--
-- 不支持子进程时（Windows 测试环境 / 旧版无 fork）自动降级为
-- “延后同步执行”，保证功能可用，只是仍会短暂阻塞。
--
-- ⚠️ 与 koobone/async.lua 的**有意分歧**（勿“对齐”）：
--    子进程正常退出但零字节输出时，本模块判**失败**（"subprocess exited without output"），
--    koobone 判**成功**（result=nil）。本插件的 work_func 一律显式 return，正常路径落不到
--    这条分支；只有子进程被信号杀死 / 崩溃才会命中，此时判失败才符合调用方语义。

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_Log, Log = pcall(require, "fanqie.logger")
local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local Async = {}

-- ============================================================
-- 活动句柄登记表 —— 让 handle.cancel 真正有人调用
-- ============================================================
-- 背景：Async.run 一直返回 handle（含 .cancel），但此前全仓库零个调用点接收它
-- （`grep -n "= Async.run("` 零命中）→ handle.cancel 是死代码。
-- 后果：凡是「打开界面 → 异步拉取 → 回填」的流程，用户中途关界面或退出 KOReader 后，
-- 子进程仍会一路跑到自己的 timeout（最长 300s），然后回填到一个已经死掉的 widget 上。
--
-- 这里把句柄集中登记，调用方不需要自己保存 handle：
--   opts.tag       可选，句柄归组名（默认 "default"），供 Async.cancel_tag 批量取消
--   opts.on_cancel 可选，被取消时回调。⚠️ **取消后 on_done 不会再执行**，
--                  所以「本流程弹出的 loading 对话框（plugin:showBusy）」必须在这里关掉，
--                  否则墨水屏上界面会永久卡在 loading（等于假死）。
local _active = {}      -- id -> handle
local _next_id = 0

--- 当前运行环境是否支持子进程（POSIX fork）。
function Async.is_available()
    return ok_ffiutil
        and ffiutil
        and type(ffiutil.runInSubProcess) == "function"
        and type(ffiutil.writeToFD) == "function"
        and type(ffiutil.readAllFromFD) == "function"
        and type(ffiutil.getNonBlockingReadSize) == "function"
        and type(ffiutil.isSubProcessDone) == "function"
end

-- Lua 原生序列化：把子进程结果序列化为可 loadstring 的 Lua 表达式。
-- 之前用 JSON，但 rapidjson/dkjson 对纯字符串 key 的 hash table 编码时会
-- 丢成空 {}，导致 result.jar 跨子进程后变空（登录成功但 cookie 全丢）。
-- Lua 序列化能完整保留 table 结构，且 string.format("%q") 正确转义所有特殊字符。
local function lua_serialize(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "nil"
    elseif t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            local ks
            if type(k) == "string" then
                ks = string.format("[%q]", k)
            elseif type(k) == "number" then
                ks = "[" .. tostring(k) .. "]"
            else
                ks = nil  -- 跳过非 string/number key（function/userdata 等不支持）
            end
            if ks then
                table.insert(parts, ks .. "=" .. lua_serialize(val))
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    else
        return "nil"
    end
end

local function lua_deserialize(s)
    if not s or s == "" then return nil end
    local load_func = loadstring or load
    if not load_func then return nil end
    local fn = load_func("return " .. s)
    if not fn then return nil end
    local ok, v = pcall(fn)
    if not ok then return nil end
    return v
end

-- 把任意错误信息清理成单行字符串，避免 JSON/协议被换行污染。
local function sanitize_err(err)
    local s = tostring(err or "unknown error")
    s = s:gsub("[%c]", " ")
    if #s > 1000 then s = s:sub(1, 1000) .. "..." end
    return s
end

--- 延后同步执行（降级路径）：在 UI 线程跑 work_func，立即回调。
local function run_sync(work_func, on_done, delay)
    if not ok_UIManager or not UIManager then
        -- 连 UIManager 都没有，直接同步执行
        local ok, result = pcall(work_func)
        if on_done then
            if ok then on_done(true, result, nil)
            else on_done(false, nil, sanitize_err(result)) end
        end
        return nil
    end
    UIManager:scheduleIn(delay or 0, function()
        local ok, result = pcall(work_func)
        if on_done then
            if ok then on_done(true, result, nil)
            else on_done(false, nil, sanitize_err(result)) end
        end
    end)
    return nil
end

--- 在子进程中执行 work_func（无参闭包，返回可 JSON 序列化值或抛错），
--- 完成后在 UI 线程回调 on_done(ok, result, err)。
---
--- @param work_func function  子进程内执行的工作函数（闭包捕获的状态在 fork 时被继承）
--- @param on_done    function|nil  回调 function(ok, result, err)，在 UI 线程运行
--- @param opts       table|nil  { delay=0, poll_interval=0.125, timeout=60, tag="default",
---                                on_cancel=fn, heartbeat=path, on_heartbeat=fn }
--- @return handle|nil  返回句柄 { cancel=fn, pid=... }；降级同步时返回 nil
---
--- 🔴 `timeout` 是**「多久没有任何进展」**的截止时间，不是「总时长」上限 ——
---    前提是任务提供了 `heartbeat`。没有心跳的任务，两者等价。
---
---    为什么需要心跳：漫画/图集章节的正文就是几十张整页大图（实测《未知生物大百科》
---    单章 22~49 页、每页 1440×2559 约 400 KB），整章下载动辄 1~5 分钟；
---    而超时到点会 `abort_subprocess()` **杀掉子进程**，已经下好的几十页全部丢掉
---    （用户看到的就是「下载超时」，然后什么都没留下）。可是真卡死（网络挂起 /
---    服务端不响应）又必须能掐掉 —— 两者的唯一区别就是「还有没有东西在落盘」。
---
---    `heartbeat` = 一个**文件路径**：子进程每完成一小步就往里写点东西（内容随意，
---    一般是「已完成/总数」），父进程每次轮询 stat 一次 mtime，**变了就重置超时时钟**；
---    内容变了还会回调 `on_heartbeat(text)`（UI 可以拿来显示进度）。
---    ⚠️ 该文件由 Async 负责收尾删除（它是本模块的临时件，调用方不用管）。
function Async.run(work_func, on_done, opts)
    opts = opts or {}
    local poll_interval = opts.poll_interval or 0.125
    local timeout = opts.timeout or 60
    local delay = opts.delay or 0
    local heartbeat_path = opts.heartbeat
    local on_heartbeat = opts.on_heartbeat
    if heartbeat_path and not (ok_lfs and lfs and type(lfs.attributes) == "function") then
        -- 拿不到 stat 就用不了心跳：退化成「总时长超时」，但要出声（否则是静默降级）。
        if ok_Log then Log.warn("[async] lfs 不可用，heartbeat 被忽略") end
        heartbeat_path = nil
    end

    if not Async.is_available() then
        if ok_Log then Log.debug("[async] 子进程不可用，降级同步执行") end
        return run_sync(work_func, on_done, delay)
    end

    -- 子进程入口：执行 work_func，把结果以 JSON 写回管道并关闭 fd。
    local function child_entry(pid, child_write_fd)
        local ok, result = pcall(work_func)
        local payload
        if ok then
            local enc = lua_serialize({ ok = true, result = result })
            -- 序列化失败时退化为纯成功标记
            payload = enc or '{ok=true,result=nil}'
        else
            local enc = lua_serialize({ ok = false, err = sanitize_err(result) })
            payload = enc or '{ok=false,err="encode failed"}'
        end
        if ok_Log then
            -- ⚠️ 只记长度、不记内容：payload 可能含 cookie / token（登录、进度上传）。
            Log.debug("[async] child payload len=" .. tostring(#payload))
        end
        -- writeToFD 第三参 true 表示写完关闭 fd，父进程 readAllFromFD 据此收到 EOF
        pcall(ffiutil.writeToFD, child_write_fd, payload, true)
    end

    local pid, parent_read_fd = ffiutil.runInSubProcess(child_entry, true) -- with_pipe = true
    if not pid then
        if ok_Log then Log.warn("[async] runInSubProcess 启动失败，降级同步") end
        return run_sync(work_func, on_done, delay)
    end

    local handle = { pid = pid, fd = parent_read_fd, _cancelled = false }
    local start_clock = os.time()

    -- 心跳状态（见 Async.run 的 opts.heartbeat 说明）。
    --   mtime 变了  ⇒ 子进程还在落盘/推进 ⇒ **重置超时时钟**（timeout 变成「停滞上限」）
    --   内容变了    ⇒ 回调 on_heartbeat(text)，UI 可以显示「第 N/M 页」
    local hb_mtime, hb_text = nil, nil
    local function heartbeat_tick()
        if not heartbeat_path then return end
        local m = lfs.attributes(heartbeat_path, "modification")
        if type(m) ~= "number" then return end
        if hb_mtime and m > hb_mtime then
            start_clock = os.time()
        end
        hb_mtime = m
        if not on_heartbeat then return end
        local f = io.open(heartbeat_path, "rb")
        if not f then return end
        local body = f:read("*a")
        f:close()
        if type(body) == "string" and body ~= "" and body ~= hb_text then
            hb_text = body
            pcall(on_heartbeat, body)
        end
    end

    -- 登记到活动表，并把 tag 冒泡到 handle 上（供 cancel_tag / cancel_all 使用）。
    _next_id = _next_id + 1
    local handle_id = _next_id
    handle.id = handle_id
    handle.tag = opts.tag or "default"
    _active[handle_id] = handle

    -- 注销：句柄已终结（正常完成 / 取消 / 超时）。必须每条终结路径都调用，
    -- 否则活动表会无限增长（每次 Async.run 泄漏一个表项 + 一个已死句柄）。
    -- 顺带收掉心跳文件（它归 Async 管，调用方不用操心）。
    local function untrack()
        if _active[handle_id] == handle then
            _active[handle_id] = nil
        end
        if heartbeat_path then
            pcall(os.remove, heartbeat_path)
            heartbeat_path = nil   -- 保证只删一次
        end
    end

    -- 终止并清理子进程（避免僵尸），fd 也一并关闭。
    -- 收尸间隔（秒）/ 次数上限 / 读取宽限期（秒）
    local REAP_INTERVAL = 5
    local REAP_MAX_ATTEMPTS = 12
    local READ_GRACE = 2
    local data_seen_at = nil

    -- 异步收尸：关闭管道 fd 并让内核 reap 掉子进程，避免 fd 泄漏与僵尸进程。
    --
    -- ⚠️ 原实现是「先 readAllFromFD 排空管道 → 再 terminateSubProcess」，顺序是反的：
    -- readAllFromFD 是**阻塞读到 EOF**，子进程还在下载时它一秒都不返回 ——
    -- 也就是说「点取消」这个动作本身就会把 UI 冻到任务自然结束，取消按钮等于没有。
    -- 上游 koreader frontend/ui/trapper.lua:dismissableRunInSubprocess 的做法是
    -- 「先 terminateSubProcess，再交给 scheduleIn 异步收」，从不同步读。
    local function reap(pid_ref, fd_ref, attempt)
        attempt = attempt or 0
        if pid_ref and not ffiutil.isSubProcessDone(pid_ref) then
            if attempt >= REAP_MAX_ATTEMPTS then
                if ok_Log then
                    Log.warn("[async] 收尸重试超过 " .. REAP_MAX_ATTEMPTS
                        .. " 次仍未结束，放弃轮询；fd 交由进程退出时回收")
                end
                return
            end
            UIManager:scheduleIn(REAP_INTERVAL, function()
                reap(pid_ref, fd_ref, attempt + 1)
            end)
            return
        end
        -- 子进程已结束：此刻读管道会立即 EOF，顺带关闭自己这一端的 fd
        if fd_ref then
            pcall(ffiutil.readAllFromFD, fd_ref)
        end
    end

    -- 非阻塞地终止子进程，并把收尾交给异步收尸。「取消」与「超时」共用。
    local function abort_subprocess()
        local pid_ref, fd_ref = handle.pid, handle.fd
        handle.fd = nil   -- 句柄交给收尸函数，poll 不再碰它

        if pid_ref and not ffiutil.isSubProcessDone(pid_ref) then
            if type(ffiutil.terminateSubProcess) == "function" then
                pcall(ffiutil.terminateSubProcess, pid_ref)
            elseif ok_Log then
                Log.warn("[async] terminateSubProcess 不可用，改为等待子进程自然结束")
            end
        end

        reap(pid_ref, fd_ref)
    end

    handle.cancel = function()
        if handle._cancelled then return end   -- 幂等：连点两次取消不会重复收尸
        handle._cancelled = true
        untrack()
        abort_subprocess()
        -- ⚠️ 取消后 on_done 不会再执行（见 poll 末尾的 `not handle._cancelled` 守卫）。
        -- 因此「本流程自己弹出的 loading 对话框 / busy 提示」必须在 on_cancel 里关掉，
        -- 否则取消 = 界面永久卡在 loading。没有 loading 的流程可以不传。
        if type(opts.on_cancel) == "function" then
            pcall(opts.on_cancel)
        end
    end

    -- 轮询函数：每次由 UIManager:scheduleIn 在 UI 线程唤醒。
    local function poll()
        if handle._cancelled then return end

        -- 先看心跳：只要子进程还在推进（文件 mtime 变了），就把超时时钟往后推。
        -- ⚠️ 必须放在超时判断**之前**：否则「刚好在到点那一刻又推进了一页」
        --    会被判超时，白丢几十页。
        heartbeat_tick()

        -- 超时检测
        if os.difftime(os.time(), start_clock) > timeout then
            if ok_Log then Log.warn("[async] 子进程超时", timeout, "s（无进展），终止") end
            untrack()
            abort_subprocess()
            if on_done then on_done(false, nil, "async timeout") end
            return
        end

        local subprocess_done = ffiutil.isSubProcessDone(pid)
        local has_data = parent_read_fd
            and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0

        if has_data and not data_seen_at then
            data_seen_at = os.time()
        end

        -- readAllFromFD 是阻塞读到 EOF，只有两种情况才允许调用：
        --   ① 子进程已结束 —— 写端已关闭，read 会立即 EOF；
        --   ② 管道有数据、但子进程迟迟不结束且超过宽限期 —— payload 撑爆了管道容量，
        --      子进程正卡在 write 上，必须由父进程读走才能解开。
        -- 其余情况（子进程还在跑、还没写出东西）一律不读，否则界面会被冻住 ——
        -- 这正是「点取消却卡住」那个 bug 的同源问题。
        local should_read = has_data
            and (subprocess_done
                or os.difftime(os.time(), data_seen_at) >= READ_GRACE)

        if should_read or subprocess_done then
            local result_ok, result_val, result_err
            if should_read then
                local ret_str = ffiutil.readAllFromFD(parent_read_fd)
                handle.fd = nil
                if ok_Log then
                    -- ⚠️ 同 child 侧：只记长度、不记内容（可能含 cookie / token）。
                    Log.debug("[async] parent ret_str len=" .. tostring(ret_str and #ret_str or -1))
                end
                local decoded = ret_str and lua_deserialize(ret_str)
                if type(decoded) == "table" then
                    if decoded.ok then
                        result_ok, result_val = true, decoded.result
                    else
                        result_ok, result_err = false, decoded.err or "unknown error"
                    end
                else
                    -- Lua 反序列化失败：若子进程已正常退出，视作成功无返回值
                    if subprocess_done then
                        result_ok, result_val = true, nil
                    else
                        result_ok, result_err = false, "malformed subprocess output"
                    end
                end
            else
                -- 子进程退出但无任何输出（崩溃 / os.exit / 被信号杀死）。
                -- 【有意分歧，勿抄 koobone】koobone 把这条判为成功（result=nil），
                -- 本插件判为失败 —— 见文件头说明。
                if parent_read_fd then
                    pcall(ffiutil.readAllFromFD, parent_read_fd)
                    handle.fd = nil
                end
                result_ok, result_err = false, "subprocess exited without output"
            end

            -- 若读取时子进程尚未退出（数据先于退出到达），安排稍后回收
            -- 若此刻子进程尚未结束（走的是宽限期兜底路径），交给异步收尸，绝不阻塞等待。
            -- subprocess_done 为真时 reap 会立即返回，不产生额外开销。
            reap(pid, nil, 0)

            untrack()

            if on_done and not handle._cancelled then
                if result_ok then
                    on_done(true, result_val, nil)
                else
                    on_done(false, nil, result_err)
                end
            end
        else
            -- 未完成，继续轮询
            UIManager:scheduleIn(poll_interval, poll)
        end
    end

    UIManager:scheduleIn(delay, poll)
    return handle
end

-- ============================================================
-- 取消接口（配套上面的活动句柄登记表）
-- ============================================================

--- 取消全部活动子进程。用于插件 teardown（onExit）。
-- 注意：被取消的流程 on_done 不会执行，只有它们的 opts.on_cancel 会执行。
-- @return number 实际取消的句柄数
function Async.cancel_all()
    local n = 0
    local snapshot = {}
    for id, handle in pairs(_active) do
        snapshot[#snapshot + 1] = handle
        _active[id] = nil
    end
    for _i, handle in ipairs(snapshot) do
        if type(handle.cancel) == "function" then
            pcall(handle.cancel)
            n = n + 1
        end
    end
    return n
end

--- 按 tag 取消。用于「界面已关闭，本流程的异步结果不再需要」。
--
-- 【预留公共接口，勿当死代码清理】当前主路径由 onExit 的 cancel_all 覆盖；
-- 本接口供「单个流程结束就收摊」的场景使用（例如关闭阅读器时只掐 progress）。
-- 已有的 tag：shelf / updater / progress / covers / book_detail / download。
-- @param tag string|nil  nil 等价于 "default"
-- @return number 实际取消的句柄数
function Async.cancel_tag(tag)
    tag = tag or "default"
    local n = 0
    local snapshot = {}
    for id, handle in pairs(_active) do
        if handle.tag == tag then
            snapshot[#snapshot + 1] = handle
            _active[id] = nil
        end
    end
    for _i, handle in ipairs(snapshot) do
        if type(handle.cancel) == "function" then
            pcall(handle.cancel)
            n = n + 1
        end
    end
    return n
end

--- 当前活动子进程数（诊断 / 自检用，勿当死代码清理：排查「子进程泄漏 / 僵死」的唯一入口）。
-- 自检示例：`Async.run(...,{}) UIManager:scheduleIn(1, function() print(Async.active_count()) end)`
function Async.active_count()
    local n = 0
    for _ in pairs(_active) do n = n + 1 end
    return n
end

return Async
