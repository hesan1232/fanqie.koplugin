local ltn12 = require("ltn12")
local Cookie = require("fanqie.cookie")
local FanQie = require("fanqie.fanqie")
local H = require("fanqie.helper")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")

-- High-resolution wall-clock timer for perf logging (millisecond precision).
-- Falls back to os.clock() (CPU time) if socket is unavailable.
local ok_socket_perf, socket_perf = pcall(require, "socket")
local function now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.clock() * 1000
end

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
local SHELF_CACHE_TTL = 5 * 60 -- 5 minutes for shelf cache
local unpack_args = unpack or table.unpack

-- 官方 App reading 协议（设备身份 + 四神签名 + AES 解密），插件唯一书源。
-- 需要 LuaJIT（bit/ffi/ffi-sha2）；加载失败时章节获取直接报错。
local ok_reading, Reading = pcall(require, "fanqie.reading")

local Client = {}
Client.__index = Client

-- SHELF_CACHE：fetch_shelf_detail 内部短缓存，按 cookie_hash 做 key，5 分钟 TTL。
-- 仅用于避免短时间内重复网络请求，不是显示层数据源。
-- 显示层数据源由 bookshelf.lua 的 SHELF_MEM_CACHE（内存主源 + 文件后备）承担。
local SHELF_CACHE = {}

local function header_value(headers, name)
    if not headers then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == target then
            return value
        end
    end
    return nil
end

local AUTH_ERROR_CODES = {
    [-2012] = true,
    [-2041] = true,
}

-- Set-Cookie 合并持久化：仅当 cookie 实际变化时才写盘。
-- LuaSettings:flush() 会把整个 settings 文件序列化写 flash（还触发 backup），
-- 每个带 Set-Cookie 的响应都写会在批量下载时放大 flash 磨损与耗时。
-- 注意 Cookie.merge_set_cookie 原地修改并返回同一张表，变更检测需先做快照。
local function persist_cookies(client, resp_headers)
    local set_cookie = header_value(resp_headers, "set-cookie")
    if not set_cookie then
        return
    end
    local cookies = client.settings:get("cookies", {})
    local before, n_before = {}, 0
    for k, v in pairs(cookies) do
        before[k] = v
        n_before = n_before + 1
    end
    local merged = Cookie.merge_set_cookie(cookies, set_cookie)
    local changed, n_after = false, 0
    for k, v in pairs(merged) do
        n_after = n_after + 1
        if before[k] ~= v then
            changed = true
            break
        end
    end
    if not changed and n_after ~= n_before then
        changed = true
    end
    if changed then
        client.settings:set("cookies", merged)
        client.settings:flush()
    end
end

local function is_auth_error(client, code, text, headers)
    if code == 401 or code == 403 then
        return true
    end
    text = tostring(text or "")
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            if AUTH_ERROR_CODES[err_code] then
                return true
            end
            local err_message = data.errMsg or data.errmsg or data.message or data.msg or ""
            -- 中英文登录态失效文案都判定为 auth 错误
            if tostring(err_message):find("登录", 1, true)
                or tostring(err_message):lower():find("login", 1, true) then
                return true
            end
        end
    end
    return false
end

local function http_error(client, code, text, headers)
    text = tostring(text or "")
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. content_type,
        "body_bytes=" .. tostring(#text),
    }
    if is_auth_error(client, code, text, headers) then
        table.insert(parts, "auth_expired=true")
    end
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then
                table.insert(parts, "error_code=" .. tostring(err_code))
            end
            if err_message ~= nil then
                local message = tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
                table.insert(parts, "error_message=" .. message)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function transport_request(transport, request, timeout)
    timeout = timeout or DEFAULT_TIMEOUT_SECONDS
    local previous_timeout = transport.TIMEOUT
    transport.TIMEOUT = timeout
    local t0 = now_ms()
    local ok, result1, result2, result3, result4 = pcall(transport.request, request)
    local elapsed = now_ms() - t0
    transport.TIMEOUT = previous_timeout

    -- Perf log: how long the raw HTTP request took (network + TLS + server).
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    if ok_logger and logger_mod then
        local method = (request and request.method) or "GET"
        local url = (request and request.url) or "?"
        -- socket.http returns 1 on success (not the body); the body is
        -- collected by the ltn12 sink, so we can't get its length here.
        -- Only strings/tables support the # operator — numbers don't.
        local body_len = 0
        if type(result1) == "string" or type(result1) == "table" then
            body_len = #result1
        end
        logger_mod.debug("[FanQie][perf] transport_request:",
            "method=" .. method,
            "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
            "code=" .. tostring(result2),
            "result_type=" .. type(result1),
            "url=" .. url)
    end

    if not ok then
        error("transport_request抛异常: " .. tostring(result1))
    end
    -- LuaSocket returns: body, code, headers, status 或 nil, error_message
    -- 检查是否为nil错误（连接失败、超时等）
    if result1 == nil and type(result2) == "string" then
        error("transport_request连接失败: " .. result2)
    end
    return result1, result2, result3, result4
end

function Client:new(settings)
    local obj = setmetatable({
        settings = settings,
    }, self)
    -- 章节获取走官方 App 协议（唯一书源）。
    obj._source_fetchers = {
        official = function(bid, iid, opts) return obj:official_get_content(bid, iid, opts) end,
    }
    return obj
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:request(opts)
    local body = opts.body
    local response = {}
    local headers = opts.headers or {}
    headers["User-Agent"] = headers["User-Agent"] or FanQie.USER_AGENT
    headers["Accept"] = headers["Accept"] or "application/json, text/plain, */*"
    headers["Accept-Encoding"] = "identity"
    headers["Connection"] = "keep-alive"

    if body then
        headers["Content-Length"] = tostring(#body)
    end

    local transport = opts.url:match("^https:") and https or http
    if opts.url:match("^https:") and not ok_https then
        error("ssl.https is not available")
    elseif not transport and not ok_http then
        error("socket.http is not available")
    end

    local request_tbl = {
        url = opts.url,
        method = opts.method or (body and "POST" or "GET"),
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response),
    }
    -- 透传 redirect 选项（socket.http 默认 true 自动跟随，设 false 可手动处理重定向以保留中间 Set-Cookie）
    if opts.redirect ~= nil then
        request_tbl.redirect = opts.redirect
    end

    local _, code, resp_headers, status = transport_request(transport, request_tbl, opts.timeout)

    return table.concat(response), tonumber(code), resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    max_redirects = max_redirects or 5
    local url = opts.url
    for redirect_index = 1, max_redirects + 1 do
        opts.url = url
        local text, code, resp_headers, status = self:request(opts)
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local location = header_value(resp_headers, "location")
            if not location then
                return text, code, resp_headers, status
            end
            if location:match("^https?://") then
                url = location
            else
                local scheme, host = url:match("^(https?)://([^/]+)")
                if scheme then
                    if location:sub(1, 1) == "/" then
                        url = scheme .. "://" .. host .. location
                    else
                        local prefix = url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
                        url = prefix .. location
                    end
                else
                    url = location
                end
            end
            opts.method = "GET"
            opts.body = nil
            opts.headers = opts.headers or {}
            opts.headers["Content-Length"] = nil
        else
            return text, code, resp_headers, status
        end
    end
    error("Too many redirects")
end

-- Binary-safe download with redirect following (for images, etc.)
function Client:download_binary(url)
    local headers = {
        ["User-Agent"] = FanQie.USER_AGENT,
        ["Accept"] = "*/*",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
    }
    local text, code = self:request_follow({
        url = url,
        method = "GET",
        headers = headers,
    })
    if code and code >= 200 and code < 300 then
        return text, code
    end
    return nil, code
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Content-Type"] = "application/json;charset=UTF-8",
        ["Origin"] = FanQie.BASE_URL,
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "POST",
        headers = headers,
        body = self:json_encode(data),
    })
    persist_cookies(self, resp_headers)
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    local err_detail = http_error(self, code, text, resp_headers)
    local err_msg = string.format("POST %s => %s", url, err_detail)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:get_json(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    persist_cookies(self, resp_headers)
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    local err_detail = http_error(self, code, text, resp_headers)
    local err_msg = string.format("GET %s => %s", url, err_detail)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:get_text(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
        ["Cookie"] = Cookie.to_header(cookies),
    }
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    persist_cookies(self, resp_headers)
    if code and code >= 200 and code < 300 then
        return text
    end
    local err_msg = http_error(self, code, text, resp_headers)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "*/*",
        ["Cookie"] = Cookie.to_header(cookies),
    }
    -- Referer: explicit string → use it; false → send none; nil → default base URL.
    -- Some CDNs (e.g. fqnovelpic.com) reject any Referer as anti-leech.
    if opts.referer == false then
        -- intentionally no Referer header
    elseif opts.referer then
        headers["Referer"] = opts.referer
    else
        headers["Referer"] = FanQie.BASE_URL .. "/"
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end
    local text, code, resp_headers = self:request_follow({
        url = url,
        method = "GET",
        headers = headers,
    })
    persist_cookies(self, resp_headers)
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    local err_msg = http_error(self, code, text, resp_headers)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

-- ===========================================================================
-- 书城（fanqienovel.com 网页接口）通用请求
-- ===========================================================================
-- 与上面的 get_json/post_json 的差别：**不抛异常**，把三种失败分开返回，
-- 因为书城接口的失败语义很不一样：
--   * HTTP 200 + **0 字节** → 被风控限流 / 路径失效（实测 /page/{id} 长这样）。
--     这跟「真没数据」长得一模一样，必须单独识别，
--     否则用户会看到「空书城」而不是「被限流」。
--     ⚠️ 但**别拿一次 0 字节就给接口判死刑**：/api/author/library/book_list/v0/
--     曾被这样误判为「已下线」，2026-10-14 复核其实是好的（见 fanqie.lua 顶部）。
--   * HTTP 200 + 非 JSON → 风控挑战页。
--   * 其它非 2xx → 常规 HTTP 错误。
-- 返回 (data, err)：成功 err=nil；失败 data=nil，err 是**表**
--   { kind = "empty"|"not_json"|"http"|"auth", message = "...", code = n }
-- 表形式的 err 让上层能按 kind 给不同提示，而不用去 match 字符串。
--
-- 🔴 `had_cookie`（v2.16.2）：本次请求**是否带上了 Cookie 头**。
--    「HTTP 200 + 0 字节」有**两个完全不同的成因**，而两者的处置相反：
--      ① 请求没带 Cookie ⇒ 该接口要登录（引导用户登录）
--      ② 带了 Cookie 仍是 0 字节 ⇒ 被限流（让用户重试，**别让他去重新登录**）
--    光看「0 字节」无法区分，所以把「有没有带 Cookie」这个事实带出来，交给上层决策。
--    实测（2026-10-16）：搜索接口**只要请求里带 Cookie 头就给数据**，
--    连值都换成假 sessionid 也照样返回 —— 它根本不校验登录态，只看有没有这个头。
--    另：限流形态也确实是「HTTP 200 + 0 字节」（不是 429），所以二者同形。

local function web_finish(client, text, code, resp_headers, method, url, had_cookie)
    persist_cookies(client, resp_headers)
    if not code or code < 200 or code >= 300 then
        local err = {
            kind = is_auth_error(client, code, text, resp_headers) and "auth" or "http",
            message = http_error(client, code, text, resp_headers),
            code = code,
            had_cookie = had_cookie and true or false,
        }
        return nil, err
    end
    if text == nil or #text == 0 then
        -- 🔴 「HTTP 200 + 0 字节」有**三个**成因（v2.16.3 补第三条），处置各不相同：
        --   ① 没带 Cookie                → 引导登录
        --   ② 带了 Cookie 但缺 s_v_web_id → 补风控标识（config 兜底 / 重新登录）
        --   ③ 带了 Cookie 且有 s_v_web_id → 多为频率限流，重试即可
        -- 🔬 实测（2026-10-16，`_probe_search_cookie_minimal.py` 二分）：
        --    书城**搜索**接口只认风控标识 `s_v_web_id` —— 只带 `sessionid`（登录态）
        --    或只带 `ttwid` 都是 0 字节，**只带 `s_v_web_id` 一个键**就回 11 KB / 10 条；
        --    伪造值无效（连格式仿真的假 `verify_…` 也是 0 字节）。
        --    ⇒ 用户会出现「书架正常、搜索却恒失败」：书架只要登录态，搜索要风控标识。
        --    而插件的扫码链路拿不到 `s_v_web_id`（登录页 / get_qrcode / 首页 / 搜索页
        --    / 书库 **都不下发**）⇒ 必须让用户能拿浏览器 Cookie 兜底，且提示要说清是哪一条。
        --    ⚠️ 只判「有没有 Cookie」是不够的：那样缺 s_v_web_id 的用户会被引导去**重复登录**，
        --    而重新登录并不能解决（登录链路本来就拿不到它）。
        local ck = nil
        if client and client.settings and client.settings.get then
            local ok_ck, v = pcall(client.settings.get, client.settings, "cookies", {})
            if ok_ck and type(v) == "table" then ck = v end
        end
        local sv = ck and ck["s_v_web_id"] or nil
        local has_sv = (type(sv) == "string" and sv ~= "") and true or false
        local why
        if not had_cookie then
            why = "本次未带 Cookie，该接口可能需要登录"
        elseif not has_sv then
            why = "已带 Cookie，但缺风控标识 s_v_web_id"
        else
            why = "已带 Cookie 与 s_v_web_id，多为频率限流"
        end
        local msg = string.format("%s %s => HTTP 200 但响应 0 字节（%s）", method, url, why)
        -- 🔴 记一条日志：这三种成因**处置相反**（该登录 / 该补标识 / 该重试），
        --    而界面上只显示一句提示、事后分不出来。用户报障时靠这条日志定性
        --    —— 排查曾卡住就是因为它（只能反复猜「到底是限流还是没登录」）。
        local ok_log, logger_mod = pcall(require, "fanqie.logger")
        if ok_log and logger_mod and logger_mod.warn then
            logger_mod.warn("[FanQie][client] " .. msg)
        end
        return nil, {
            kind = "empty",
            had_cookie = had_cookie and true or false,
            -- 事实字段，供上层决策（store.lua 的搜索分支据此区分「该登录 / 该补标识 / 该重试」）
            has_sv_web_id = has_sv,
            message = msg,
            code = code,
        }
    end
    local ok, data = pcall(client.json_decode, client, text)
    if not ok or type(data) ~= "table" then
        return nil, {
            kind = "not_json",
            message = string.format("%s %s => HTTP 200 但响应不是 JSON（%d 字节，前 60 字节：%s）",
                method, url, #text, tostring(text):gsub("[%c]+", " "):sub(1, 60)),
            code = code,
        }
    end
    return data, nil
end

--- 书城 GET（不抛异常）。opts: { referer = "…", headers = {…} }
---@return table|nil, table|nil
function Client:web_get_json(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end
    local ok, text, code, resp_headers = pcall(self.request, self, {
        url = url,
        method = "GET",
        headers = headers,
    })
    if not ok then
        return nil, { kind = "transport", message = tostring(text), code = 0 }
    end
    return web_finish(self, text, code, resp_headers, "GET", url, cookie_header ~= "")
end

--- App（api*.fqnovel.com）GET（不抛异常）。
--- 🔴 为什么不能复用 web_get_json：网页域要 desktop UA + fanqienovel Referer + cookie，
---    而 App 接口（榜单/礼物榜）要 `com.dragon.read/…` UA、**不带**网页 Referer，
---    也不需要 cookie（实测带不带都返回同一批数据，带了反而可能与网页登录态混用）。
---opts: { headers = {…} }
---@return table|nil, table|nil
function Client:app_get_json(url, opts)
    opts = opts or {}
    local headers = {
        ["User-Agent"] = FanQie.APP_UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = FanQie.APP_BASE_URL .. "/",
    }
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end
    local ok, text, code, resp_headers = pcall(self.request, self, {
        url = url,
        method = "GET",
        headers = headers,
    })
    if not ok then
        return nil, { kind = "transport", message = tostring(text), code = 0 }
    end
    -- App 域请求**不带** Cookie（见本函数上方的说明）⇒ had_cookie = false。
    return web_finish(self, text, code, resp_headers, "GET", url, false)
end

--- 书城 POST（不抛异常）。opts: { referer = "…", headers = {…}, raw_body = string }
---@return table|nil, table|nil
function Client:web_post_json(url, data, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Content-Type"] = "application/json;charset=UTF-8",
        ["Origin"] = FanQie.BASE_URL,
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end
    local ok, text, code, resp_headers = pcall(self.request, self, {
        url = url,
        method = "POST",
        headers = headers,
        body = opts.raw_body or self:json_encode(data),
    })
    if not ok then
        return nil, { kind = "transport", message = tostring(text), code = 0 }
    end
    return web_finish(self, text, code, resp_headers, "POST", url, cookie_header ~= "")
end

function Client:fetch_shelf_info()
    local params = FanQie.make_shelf_params()
    local url = FanQie.shelf_url() .. "?"
    local parts = {}
    for key, value in pairs(params) do
        table.insert(parts, key .. "=" .. H.url_encode(value))
    end
    return self:get_json(url .. table.concat(parts, "&"))
end

function Client:clear_shelf_cache()
    SHELF_CACHE = {}
end

local function get_cookie_hash(cookies)
    local parts = {}
    for k, v in pairs(cookies) do
        table.insert(parts, k .. "=" .. v)
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

function Client:fetch_shelf_detail(force_refresh)
    local now = os.time()
    local cookies = self.settings:get("cookies", {})
    local cache_key = next(cookies) and get_cookie_hash(cookies) or "default"
    local cached = SHELF_CACHE[cache_key]
    if not force_refresh and cached and (now - cached.timestamp) < SHELF_CACHE_TTL then
        return cached.data
    end
    
    -- 书架直接使用官方 API
    local shelf_info = self:fetch_shelf_info()
    if type(shelf_info) ~= "table" or type(shelf_info.data) ~= "table" then
        return { code = 0, data = { detail_list = {} } }
    end
    
    local book_shelf_info = shelf_info.data.book_shelf_info or shelf_info.data.bookShelfInfo or shelf_info.data
    if type(book_shelf_info) ~= "table" or #book_shelf_info == 0 then
        return { code = 0, data = { detail_list = {} } }
    end
    
    local shelf_book_ids = {}
    -- shelf_index：book_shelf_info 的原始顺序 = 「加入书架」顺序，供书架按加入时间排序
    local shelf_index = {}
    -- shelf_meta：book_shelf_info 的**书架侧**元数据（加入时间 / 上次操作时间 / 星标）。
    -- 这些字段 multidetail 里**没有**（它只给书目信息），而 bookshelf/info 里**有**
    -- —— 两边按 book_id 合并才是完整的一条书架记录（v2.12.0 详情页要用）。
    local shelf_meta = {}
    for idx, item in ipairs(book_shelf_info) do
        if item.book_id then
            table.insert(shelf_book_ids, item.book_id)
            shelf_index[tostring(item.book_id)] = idx
            shelf_meta[tostring(item.book_id)] = item
        end
    end
    
    local progress_result = self:fetch_read_progress()
    local progress_map = {}
    if progress_result and progress_result.data then
        for _, item in ipairs(progress_result.data) do
            progress_map[tostring(item.book_id)] = {
                read_progress = item.read_progress,
                index = item.index,
                item_id = item.item_id,
                -- read_timestamp 是服务端给的最后阅读时间（unix 秒），
                -- 书架「按最后阅读」排序即用它（与 kindle-forge 前端同款）。
                read_timestamp = tonumber(item.read_timestamp) or 0,
            }
        end
    end
    
    local books = {}
    for _, book_id in ipairs(shelf_book_ids) do
        local progress = progress_map[tostring(book_id)]
        table.insert(books, {
            book_id = book_id,
            item_id = progress and progress.item_id or "0",
        })
    end
    
    local detail_result = self:post_json(FanQie.bookshelf_multidetail_url(), { books = books })
    if detail_result and detail_result.data and detail_result.data.detail_list then
        for _, book in ipairs(detail_result.data.detail_list) do
            local key = tostring(book.book_id)
            local progress = progress_map[key]
            if progress then
                book.read_progress = progress.read_progress
                book.index = progress.index
                book.latest_read_item_id = progress.item_id
            end
            book.read_timestamp = progress and progress.read_timestamp or 0
            book.shelf_index = shelf_index[key]
            -- 书架侧元数据（bookshelf/info 才有的那三个字段）
            local meta = shelf_meta[key]
            if meta then
                book.add_shelf_time = tonumber(meta.add_shelf_time) or 0
                book.last_operate_time = tonumber(meta.last_operate_time) or 0
                book.asterisked = meta.asterisked == true
                book.add_type = tonumber(meta.add_type)
            end
        end
    end
    
    SHELF_CACHE[cache_key] = {
        timestamp = now,
        data = detail_result,
    }
    
    return detail_result
end

function Client:fetch_read_progress()
    return self:get_json(FanQie.progress_url())
end

function Client:update_read_progress(book_id, item_id, index, progress)
    return self:post_json(FanQie.update_progress_url(), {
        book_id = book_id,
        item_id = item_id,
        read_progress = progress or 0,
        index = index,
        read_timestamp = tostring(math.floor(os.time())),
        genre_type = 0,
    })
end

function Client:fetch_chapter_directory(book_id)
    -- 目录直接使用官方 API
    local ok, result = pcall(function()
        return self:get_json(FanQie.directory_url(book_id))
    end)
    
    if ok and result and result.code == 0 and result.data then
        return result
    end
    
    local err_msg = "官方 API 获取目录失败"
    if result then
        err_msg = err_msg .. ": code=" .. tostring(result.code) .. " message=" .. tostring(result.message or "")
    end
    error(err_msg)
end

-- 段评气泡标签注入：把 <comment ident="fqapp://book/item/para" count="N" />
-- 追加到对应段落 </p> 前。App 协议正文段落结构：
--   <p idx="N" p_idx="40000"><blk p_idx="N" ...>正文</blk></p>
-- 其中 blk 的 p_idx 即段评统计（idea/list）返回的段落序号（与 kindle-forge
-- 的 inject_comment_bubbles 对齐）。返回 (注入后的正文, para_reviews)。
local function inject_comment_tags(content, book_id, item_id, stats)
    local para_reviews = {}
    if type(content) ~= "string" or type(stats) ~= "table" then
        return content, para_reviews
    end
    local out = content:gsub("(<p%s[^>]*>[%s%S]-</p>)", function(seg)
        -- 取 blk 标签的 p_idx（<p> 自身也带 p_idx，但那是 40000 之类的偏移值）
        local pid = tonumber(seg:match('<blk[^>]*p_idx="(%d+)"'))
        local info = pid and stats[pid]
        local n = info and (tonumber(info.count) or 0) or 0
        if n > 0 and not seg:find("<comment", 1, true) then
            local ident = string.format("fqapp://%s/%s/%d", book_id, item_id, pid)
            table.insert(para_reviews, { ident = ident, count = n })
            local tag = string.format('<comment ident="%s" count="%d" />', ident, n)
            return seg:sub(1, -5) .. tag .. "</p>"
        end
        return seg
    end)
    return out, para_reviews
end

-- Fetch chapter content via the official FanQie App "reading" protocol.
-- 链路：设备身份注册 → registerkey 换内容密钥 → batch_full 拉密文 → AES 解密。
-- 说明：旧的网页接口 /api/reader/chapter/content 已被风控（HTTP 515），
-- 故改用 App 端 reading 协议（移植自 book.koplugin）。
-- opts.review = true 时同时拉段评统计（commentapi idea/list），把
-- <comment ident="..." count="N" /> 注入对应段落末尾，复用 content.lua 的
-- 气泡清洗管线；para_reviews 按 <comment> 出现顺序返回（与气泡序号一致）。
-- Returns {content, title, author, para_reviews} on success; errors on failure.
function Client:official_get_content(book_id, item_id, opts)
    if not ok_reading or type(Reading) ~= "table" then
        error("官方书源不可用：reading 模块加载失败（需 LuaJIT 环境）")
    end
    opts = opts or {}
    local result, err = Reading.fetch(self, self.settings, book_id, item_id)
    if not result then
        error("官方API获取正文失败: " .. tostring(err))
    end
    local para_reviews = {}
    if opts.review then
        local ok_logger, logger_mod = pcall(require, "fanqie.logger")
        -- Comments.stats 失败时返回 (nil, err)：err 必须落到日志，
        -- 否则「正文没气泡」会被误判成「本章本来就没段评」。
        local stats, stats_err
        local ok_stats, ret1, ret2 = pcall(function()
            local Comments = require("fanqie.reading.comments")
            return Comments.stats(self, self.settings, item_id)
        end)
        if ok_stats then
            stats, stats_err = ret1, ret2
        else
            stats_err = ret1
        end
        if stats then
            local ok_inject, content2, reviews = pcall(
                inject_comment_tags, result.content or "",
                tostring(book_id), tostring(item_id), stats)
            if ok_inject then
                result.content = content2
                para_reviews = reviews or {}
            end
            if ok_logger and logger_mod then
                logger_mod.info("[FanQie] 段评统计注入:",
                    "itemId=" .. tostring(item_id),
                    "paras=" .. tostring(type(stats) == "table" and (function()
                        local n = 0 for _ in pairs(stats) do n = n + 1 end return n end)() or 0),
                    "bubbles=" .. tostring(#para_reviews))
            end
        else
            -- 段评统计失败不阻塞正文：只记日志，正文不带气泡
            if ok_logger and logger_mod then
                logger_mod.warn("[FanQie] 段评统计获取失败（正文不带气泡）:",
                    tostring(stats_err or stats))
            end
        end
    end
    return {
        content = result.content or "",
        title = result.title or "",
        author = result.author or "",
        source = result.source or "official_reading",
        para_reviews = para_reviews,
    }
end

-- ============================================================================
-- 章节获取（官方 App 协议，唯一书源）+ 段评
-- ============================================================================

-- 段评列表（官方 App commentapi）。ident 格式 fqapp://book_id/item_id/para_index。
-- opts: { count = number|nil 单页条数（≤50，默认 10）,
--         cursor = string|nil 翻页游标（首屏 ""）,
--         sort = number|nil 0|3=热门 1=最新,
--         item_version = string|nil 章节 version（缺省 "0"） }
--
-- 返回结构对齐 kindle-forge `api.get_para_comments`：
--   { comments = {扁平条目…}, cursor = string, has_more = bool, total = number }
-- 失败时返回 (nil, err)——**绝不返回空页**，否则上层会显示成「共 0 条评论」。
function Client:official_get_para_review(ident, opts)
    opts = opts or {}
    local book_id, item_id, para_index = tostring(ident):match("^fqapp://(%d+)/(%d+)/(%d+)$")
    if not book_id then
        return nil, "段评标识无效（仅支持官方 App 协议）: " .. tostring(ident)
    end
    local Comments = require("fanqie.reading.comments")
    local data_list, info, err = Comments.list(self, self.settings, item_id, book_id,
        tonumber(para_index), {
            count = tonumber(opts.count) or 10,
            cursor = tostring(opts.cursor or ""),
            sort = tonumber(opts.sort) or 0,
            item_version = opts.item_version,
        })
    if not data_list then
        return nil, err or "段评列表获取失败"
    end
    local comments = {}
    for i, item in ipairs(data_list) do
        comments[i] = Comments.flatten_comment(item)
    end
    return {
        comments = comments,
        cursor = tostring((info and info.cursor) or ""),
        has_more = (info and info.has_more) == true,
        total = tonumber(info and info.total) or 0,
    }
end

-- 段评回复（官方 App commentapi reply/list）。返回**一页**回复的扁平列表。
-- 决定「回复哪条」的只有 comment_id（走 URL），comment_source 必须为 5。
-- 失败时返回 (nil, err)：与 official_get_para_review 同样的语义 ——
-- commentapi 签名不合规回的是 200 空响应，绝不能降级成「这条没有回复」。
-- 返回结构：{ replies = {扁平条目…}, cursor = string, has_more = bool, total = number }
function Client:official_get_para_replies(comment_id, opts)
    opts = opts or {}
    local Comments = require("fanqie.reading.comments")
    local reply_list, info, err = Comments.replies(self, self.settings,
        tostring(comment_id), {
            count = tonumber(opts.count) or Comments.REPLY_MAX_COUNT,
            cursor = tostring(opts.cursor or ""),
        })
    if not reply_list then
        return nil, err or "段评回复获取失败"
    end
    local replies = {}
    for i, item in ipairs(reply_list) do
        replies[i] = Comments.flatten_reply(item)
    end
    return {
        replies = replies,
        cursor = tostring((info and info.cursor) or ""),
        has_more = (info and info.has_more) == true,
        total = tonumber(info and info.total) or 0,
    }
end

-- Fetch chapter content (official App protocol only).
-- opts: { review = bool }  -- 是否启用段评模式
-- 返回 result（单值）。多书源下线后不再有 source_id，也没有需要跨子进程合并的
-- 限流时间戳，故不再返回占位值。
function Client:get_chapter_content_with_fallback(book_id, item_id, opts)
    opts = opts or {}
    local t_start = now_ms()
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    local function log_info(...) if ok_logger and logger_mod then logger_mod.info(...) end end
    local function log_debug(...) if ok_logger and logger_mod then logger_mod.debug(...) end end
    local function log_error(...) if ok_logger and logger_mod then logger_mod.error(...) end end

    log_info("[FanQie] 获取正文:", "source=official", "itemId=" .. tostring(item_id))
    local t_src = now_ms()
    local ok, result = pcall(self._source_fetchers.official, book_id, item_id, opts)
    local elapsed = now_ms() - t_src
    if ok and result and result.content then
        log_debug("[FanQie][perf] 获取成功:",
            "source=official",
            "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
            "itemId=" .. tostring(item_id),
            "长度=" .. tostring(#result.content))
        return result
    end

    local err_msg = "未知错误"
    if type(result) == "string" then
        err_msg = result
    elseif type(result) == "table" and result.message then
        err_msg = result.message
    end
    err_msg = err_msg:gsub("[%c]+", " ")
    local total_elapsed = now_ms() - t_start
    log_error("[FanQie] 章节获取失败:",
        "itemId=" .. tostring(item_id),
        "total=" .. string.format("%.0f", total_elapsed) .. "ms",
        "err=" .. err_msg)
    error("章节获取失败: " .. err_msg)
end

return Client