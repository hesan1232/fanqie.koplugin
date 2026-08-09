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

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_Log, Log = pcall(require, "fanqie.logger")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local Async = {}

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
--- @param opts       table|nil  { delay=0, poll_interval=0.125, timeout=60 }
--- @return handle|nil  返回句柄 { cancel=fn, pid=... }；降级同步时返回 nil
function Async.run(work_func, on_done, opts)
    opts = opts or {}
    local poll_interval = opts.poll_interval or 0.125
    local timeout = opts.timeout or 60
    local delay = opts.delay or 0

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
            Log.debug("[async] child payload len=" .. tostring(#payload) .. " 前120=" .. payload:sub(1, 120))
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

    -- 终止并清理子进程（避免僵尸），fd 也一并关闭。
    local function cleanup(pid_ref, fd_ref)
        if fd_ref then
            pcall(ffiutil.readAllFromFD, fd_ref)
        end
        if pid_ref and not ffiutil.isSubProcessDone(pid_ref) then
            pcall(ffiutil.terminateSubProcess, pid_ref)
        end
    end

    handle.cancel = function()
        handle._cancelled = true
        cleanup(handle.pid, handle.fd)
        handle.fd = nil
    end

    -- 轮询函数：每次由 UIManager:scheduleIn 在 UI 线程唤醒。
    local function poll()
        if handle._cancelled then return end

        -- 超时检测
        if os.difftime(os.time(), start_clock) > timeout then
            if ok_Log then Log.warn("[async] 子进程超时", timeout, "s，终止") end
            cleanup(handle.pid, handle.fd)
            handle.fd = nil
            if on_done then on_done(false, nil, "async timeout") end
            return
        end

        local subprocess_done = ffiutil.isSubProcessDone(pid)
        local stuff_to_read = parent_read_fd
            and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0

        if subprocess_done or stuff_to_read then
            local result_ok, result_val, result_err
            if stuff_to_read then
                local ret_str = ffiutil.readAllFromFD(parent_read_fd)
                handle.fd = nil
                if ok_Log then
                    Log.debug("[async] parent ret_str len=" .. tostring(ret_str and #ret_str or -1) .. " 前120=" .. tostring(ret_str):sub(1, 120))
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
                -- 子进程退出但无任何输出（崩溃 / os.exit）
                if parent_read_fd then
                    pcall(ffiutil.readAllFromFD, parent_read_fd)
                    handle.fd = nil
                end
                result_ok, result_err = false, "subprocess exited without output"
            end

            -- 若读取时子进程尚未退出（数据先于退出到达），安排稍后回收
            if not subprocess_done then
                local collect_pid = pid
                local collect
                collect = function()
                    if ffiutil.isSubProcessDone(collect_pid) then
                        -- 已回收
                    else
                        UIManager:scheduleIn(1, collect)
                    end
                end
                UIManager:scheduleIn(1, collect)
            end

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

return Async
