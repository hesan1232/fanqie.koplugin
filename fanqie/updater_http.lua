-- 更新器专用的极简 HTTP 客户端：只做「取 JSON 清单」与「下文件到本地」两件事。
--
-- 【为什么不复用业务层的 client / http_downloader】
--   · fanqie.client 绑定了番茄的 base_url、Cookie、设备身份与四神签名头；
--   · fanqie.download 是「子进程 + 管道 IPC + 断点续传」的重型下载器。
-- 而更新请求要打到 github.com 和第三方镜像站（ghfast.top 等）上，**必须一个凭证都不带**
-- ——把用户的 Cookie / 设备身份发给镜像站是不可接受的。更新包也只有几百 KB，用不上
-- 子进程那套。所以这里单写一个最小实现，代价是几十行重复代码，换来的是清晰的安全边界。
--
-- 【超时必须中心收口】LuaSocket 的 `http.TIMEOUT` 是**模块级全局**，改完不恢复会污染
-- 业务层的下载（表现为「下载书永远超时」或「卡住不超时」）。这里统一在
-- `with_timeout()` 里设置 + 恢复，调用方不直接碰 TIMEOUT。
--
-- 【重定向必须自己跟随】ssl.https（LuaSec）**不支持自动重定向** —— request 表里只要
-- `redirect` 是真值，它就返回 `nil,"redirect not supported"` 而**根本不发请求**。
-- 而 GitHub 与国内镜像站都会 302，所以这里统一传 `redirect=false`，由 `request_follow()`
-- 自己跟进，并沿用 KOReader OPDS 的做法拒绝 HTTPS→HTTP 降级。
--
-- 与 koobone.koplugin 的 updater_http.lua 同源（去掉业务侧的目录探测）。

local ok_http, http = pcall(require, "socket.http")
local ok_https, https = pcall(require, "ssl.https")

local H = require("fanqie.helper")
local Log = require("fanqie.logger")

local M = {}

M.UA = "KOReader-FanQie-Updater/1.0"
M.DEFAULT_TIMEOUT = 60        -- 秒；同时作用于连接与读取
M.JSON_MAX_BYTES = 64 * 1024  -- 清单正文上限，防呆（正常只有几百字节）
M.MAX_REDIRECTS = 5           -- 手动跟随的重定向上限（与 LuaSocket 默认值一致）

--- 传输层是否可用（socket.http 加载失败时整个更新功能禁用）
function M.available()
    return ok_http and http ~= nil
end

local function pick_transport(url)
    if tostring(url or ""):find("^https://") then
        if not ok_https then return nil, "ssl.https 不可用" end
        return https
    end
    if not ok_http then return nil, "socket.http 不可用" end
    return http
end

--- 在给定超时内执行 fn，结束后**无条件**恢复原来的 TIMEOUT。
-- 返回 pcall 风格：ok, r1..r4（LuaSocket 的 request 最多返回 4 个值）。
local function with_timeout(seconds, fn)
    local old_http = http and http.TIMEOUT
    local old_https = (ok_https and https) and https.TIMEOUT

    if http then http.TIMEOUT = seconds end
    if ok_https and https then https.TIMEOUT = seconds end

    local ok, r1, r2, r3, r4 = pcall(fn)

    if http then http.TIMEOUT = old_http end
    if ok_https and https then https.TIMEOUT = old_https end

    return ok, r1, r2, r3, r4
end

local function build_headers(extra)
    local headers = {
        ["User-Agent"] = M.UA,
        ["Accept"] = "*/*",
        -- 显式拒绝压缩：LuaSocket 不会自动解压，服务器若回 gzip 就会得到二进制垃圾，
        -- 表现是「JSON 解析失败」这种指向错误位置的报错。
        ["Accept-Encoding"] = "identity",
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            headers[k] = v
        end
    end
    return headers
end

--- 把 `Location` 头解析成绝对 URL。只处理绝对地址、`//host/path` 与相对路径。
-- @return string|nil
local function resolve_location(base_url, location)
    location = tostring(location or ""):gsub("%s", "")
    if location == "" then return nil end
    if location:match("^https?://") then return location end

    local scheme, host = base_url:match("^(https?)://([^/]+)")
    if not scheme then return nil end
    if location:sub(1, 2) == "//" then
        return scheme .. ":" .. location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    -- 相对路径：拼到当前地址的目录部分
    local dir = base_url:match("^(https?://.*)/")
    if dir then return dir .. "/" .. location end
    return scheme .. "://" .. host .. "/" .. location
end

--- 禁止 HTTPS → HTTP 降级重定向（与 KOReader 官方 OPDS 的同款护栏）。
-- @return boolean
local function is_https_downgrade(from_url, to_url)
    return from_url:match("^https://") ~= nil and to_url:match("^http://") ~= nil
end

--- 发起 GET 并**手动**跟随 3xx，返回最终响应。
--
-- 【为什么 sink 要工厂】上一次尝试的响应体可能已经写进 sink 了；沿用同一个 sink
-- 会把两次响应拼成一个非法正文，报错还会指向「解析失败」而不是「重定向」。
-- 所以每跳都重建 sink —— 这是重试类代码最容易踩的坑。
--
-- @param url string 起始地址
-- @param opts table 可含 timeout / headers / max_redirects
-- @param make_sink fun():function,table 返回 (sink, state)；sink 为 nil 视为致命错误
-- @return boolean ok, number|string code_or_err, table|nil headers
local function request_follow(url, opts, make_sink)
    local current = url
    local max_redirects = tonumber(opts.max_redirects) or M.MAX_REDIRECTS

    for _ = 0, max_redirects do
        local transport, terr = pick_transport(current)
        if not transport then return false, tostring(terr), nil end

        local sink, state = make_sink()
        if not sink then
            return false, tostring(state and state.open_error or "无法创建 sink"), nil
        end

        local ok_call, r1, r2, r3 = with_timeout(tonumber(opts.timeout) or M.DEFAULT_TIMEOUT,
            function()
                return transport.request{
                    url = current,
                    method = "GET",
                    headers = build_headers(opts.headers),
                    sink = sink,
                    redirect = false,
                }
            end)

        if not ok_call then
            return false, "请求异常：" .. tostring(r1), nil
        end
        if not r1 then
            return false, tostring(r2 or "网络错误"), nil
        end

        local code = tonumber(r2) or 0
        local headers = type(r3) == "table" and r3 or nil
        if code < 300 or code > 399 then
            return true, code, headers
        end

        local next_url = resolve_location(current, headers and headers.location)
        if not next_url then
            return false, string.format("HTTP %s 缺少 Location", tostring(r2)), nil
        end
        if is_https_downgrade(current, next_url) then
            return false, "拒绝 HTTPS→HTTP 降级重定向", nil
        end
        current = next_url
    end

    return false, "重定向次数过多", nil
end

--- GET 一个 JSON 清单。
-- @return table 解析后的对象 | nil, string 原因
function M.get_json(url, opts)
    opts = opts or {}
    local max_bytes = tonumber(opts.max_bytes) or M.JSON_MAX_BYTES

    local st = { chunks = {}, total = 0, overflow = false }
    local function make_sink()
        -- 每跳都要清空累积器（见 request_follow 的注释）
        st.chunks, st.total, st.overflow = {}, 0, false
        local sink = function(chunk, err)
            if err then return nil, err end
            if chunk then
                st.total = st.total + #chunk
                if st.total > max_bytes then
                    st.overflow = true
                    return nil, "响应超过 " .. tostring(max_bytes) .. " 字节"
                end
                st.chunks[#st.chunks + 1] = chunk
            end
            return 1
        end
        return sink, st
    end

    local ok, code = request_follow(url, opts, make_sink)
    if not ok then return nil, tostring(code) end
    if code ~= 200 then
        return nil, string.format("HTTP %s", tostring(code))
    end
    if st.overflow then
        return nil, "清单响应过大"
    end

    local body = table.concat(st.chunks)
    if body == "" then
        return nil, "清单内容为空"
    end

    local decoded = H.json_decode(body)
    if type(decoded) ~= "table" then
        return nil, "清单不是合法 JSON"
    end
    return decoded
end

--- 下载文件到 path。
-- 先写 `path + ".part"`，全部校验通过后才 rename —— 中途失败不会留下一个
-- 「看起来完整」的半截文件（大小校验对它无效，因为名字就已经暴露了状态）。
-- @return true, number 字节数 | nil, string 原因
function M.download(url, path, opts)
    opts = opts or {}
    local tmp = path .. ".part"
    os.remove(tmp)

    -- ⚠️ write / close 的返回值都要查：Lua stdio 是带缓冲的，磁盘写满时 write 往往
    -- 不报错，错误要到 close 才暴露（有时甚至只在 flush 时）。只看「open 成功」
    -- 会留下一个内容截断的文件，后面当完整包用。
    local st = { f = nil, closed = false, write_error = nil, open_error = nil }

    -- 每跳都重新以 "wb" 打开（会截断）：重定向时上一跳的正文可能已经写进去了。
    local function make_sink()
        local f, oerr = io.open(tmp, "wb")
        if not f then
            st.open_error = oerr or "打开失败"
            return nil, st
        end
        st.f, st.closed, st.write_error = f, false, nil
        local sink = function(chunk, err)
            if err then return nil, err end
            if not chunk then
                local ok_close, cerr = f:close()
                st.closed = true
                if not ok_close then
                    st.write_error = cerr or "close 失败"
                    return nil, st.write_error
                end
                return 1
            end
            local ok_write, werr = f:write(chunk)
            if not ok_write then
                st.write_error = werr or "write 失败"
                return nil, st.write_error
            end
            return 1
        end
        return sink, st
    end

    local ok, code = request_follow(url, opts, make_sink)

    -- 失败路径上 sink 的 close 分支可能压根没被调用，这里兜一次底防句柄泄漏。
    if st.f and not st.closed then
        pcall(function() st.f:close() end)
        st.closed = true
    end

    if st.open_error then
        os.remove(tmp)
        return nil, "无法创建临时文件：" .. tostring(st.open_error)
    end
    if not ok then
        os.remove(tmp)
        return nil, tostring(code)
    end
    if code ~= 200 then
        os.remove(tmp)
        return nil, string.format("HTTP %s", tostring(code))
    end
    if st.write_error then
        os.remove(tmp)
        return nil, "写入失败：" .. tostring(st.write_error)
    end

    local size = H.file_size(tmp)
    if not size or size == 0 then
        os.remove(tmp)
        return nil, "下载内容为空"
    end

    os.remove(path)  -- rename 在 vfat / Windows 上不能覆盖已存在的文件
    local renamed, rerr = os.rename(tmp, path)
    if not renamed then
        os.remove(tmp)
        return nil, "重命名失败：" .. tostring(rerr)
    end

    Log.debug(string.format("[Updater] downloaded %s -> %s (%d bytes)", url, path, size))
    return true, size
end

return M
