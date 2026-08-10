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

-- Rate limiting is now handled per-source by fanqie.sources.SourceManager,
-- invoked from get_chapter_content_with_fallback (not inside each fetcher).

local Client = {}
Client.__index = Client

-- SHELF_CACHE：fetch_shelf_detail 内部短缓存，按 cookie_hash 做 key，10 分钟 TTL。
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
            if tostring(err_message):find("登录", 1, true) or tostring(err_message):find("登录", 1, true) then
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
    -- Source fetcher dispatch table: source_id -> function(book_id, item_id, opts).
    -- Note: qingtian_get_content takes (item_id, book_id), so we swap args.
    obj._source_fetchers = {
        qingtian = function(bid, iid, opts) return obj:qingtian_get_content(iid, bid, opts) end,
        dahuilang = function(bid, iid, opts) return obj:dahuilang_get_content(bid, iid, opts) end,
        official = function(bid, iid) return obj:official_get_content(bid, iid) end,
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

-- ============================================================================
-- Server detection (check-servers with short-circuit optimization)
-- ============================================================================

-- Check if a single server is available by sending GET to /login
-- Returns (available:bool, response_code:number)
function Client:check_single_server(server_url)
    local base = FanQie.normalize_base(server_url)
    local mobile_ua = FanQie.MOBILE_UA

    -- 服务器存活探测：超时 10 秒
    -- 注意：从日志看 v2.czyl.cf /login 实际响应需要 5-6s（国外/慢链路），
    -- v4.czyl.cf 需要 8s，这些都是"正常"完成时间。超时必须留足 10s，
    -- 否则会把所有正常服务器误判为超时，导致检测不到可用线路。
    -- 真正死的服务器（如已移除的 api.langge.cf）会在 10s 后超时失败，
    -- 短路逻辑保证找到第一个可用的就停止。
    local ok, text, code = pcall(function()
        return self:request({
            url = base .. "/login",
            method = "GET",
            headers = {
                ["User-Agent"] = mobile_ua,
                ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                ["Accept-Encoding"] = "identity",
                ["Connection"] = "close",
            },
            timeout = 10,
        })
    end)
    
    if not ok or not code then
        return false, 0
    end
    
    -- 仅 2xx / 3xx 视为真正可用
    if code >= 200 and code < 400 then
        return true, code
    end
    return false, code
end

-- Check multiple servers and return the first available one (short-circuit)
-- servers: array of server URLs
-- Returns { available = "url" or nil, found = bool }
function Client:check_servers(servers)
    if type(servers) ~= "table" or #servers == 0 then
        return { available = nil, found = false }
    end
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    local now_ms_local = now_ms
    for idx, url in ipairs(servers) do
        local t0 = now_ms_local()
        local available, code = self:check_single_server(url)
        local elapsed = now_ms_local() - t0
        if ok_logger and logger_mod then
            logger_mod.debug("[FanQie] 服务器探测:",
                "idx=" .. tostring(idx),
                "url=" .. tostring(url),
                "code=" .. tostring(code),
                "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
                "available=" .. tostring(available))
        end
        if available then
            return { available = url, found = true }
        end
    end
    return { available = nil, found = false }
end

-- ============================================================================
-- Server list resolution for sources
-- ============================================================================

function Client:get_qingtian_server_list()
    local qt = self.settings:get_source("qingtian")
    local server_urls = {}
    -- Primary server from config
    if qt.server_url and qt.server_url ~= "" then
        table.insert(server_urls, qt.server_url)
    end
    -- Default fallback servers (known working nodes)
    local defaults = {
        "https://v1.gyks.cf/",
        "https://v2.gyks.cf/",
        "https://v3.gyks.cf/",
        "https://v4.gyks.cf/",
        "https://v5.gyks.cf/",
        "https://v6.gyks.cf/",
        "https://v7.gyks.cf/",
    }
    for _, d in ipairs(defaults) do
        local found = false
        for _, u in ipairs(server_urls) do
            if u == d then found = true break end
        end
        if not found then
            table.insert(server_urls, d)
        end
    end
    return server_urls
end

function Client:get_dahuilang_server_list()
    local dl = self.settings:get_source("dahuilang")
    local server_urls = {}
    if dl.server_url and dl.server_url ~= "" then
        table.insert(server_urls, dl.server_url)
    end
    local defaults = {
        "https://v2.czyl.cf",
        "https://v4.czyl.cf",
        "https://v5.czyl.cf",
        "https://legado.gyks.cf",
    }
    for _, d in ipairs(defaults) do
        local found = false
        for _, u in ipairs(server_urls) do
            if u == d then found = true break end
        end
        if not found then
            table.insert(server_urls, d)
        end
    end
    return server_urls
end

-- ============================================================================
-- Token expiration handling
-- ============================================================================

-- Check if an error response indicates token expiration
-- Returns true if token is expired and needs re-login
local function is_token_expired_error(result)
    if type(result) ~= "table" then return false end
    local msg = tostring(result.message or result.msg or result.error or "")
    if msg:find("多次登录失败", 1, true) then return true end
    if msg:find("token", 1, true) and msg:find("过期", 1, true) then return true end
    if msg:find("登录失败", 1, true) then return true end
    local err_code = result.code or result.errCode or result.errcode
    if err_code and (err_code == -2012 or err_code == -2041) then return true end
    return false
end

-- ============================================================================
-- 晴天登录方法
-- ============================================================================

function Client:qingtian_login(override_server_url)
    local qingtian = self.settings:get_source("qingtian")
    local server_url = override_server_url or H.trim(qingtian.server_url or "")
    local username = H.trim(qingtian.username or "")
    local password = H.trim(qingtian.password or "")
    
    if server_url == "" or username == "" or password == "" then
        error("晴天配置不完整：需要服务器地址、账号和密码")
    end
    
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    local function log_info(...) if ok_logger and logger_mod then logger_mod.info(...) end end
    local function log_error(...) if ok_logger and logger_mod then logger_mod.error(...) end end
    
    log_info("[FanQie] 开始晴天登录:", "server=" .. server_url, "user=" .. username)
    
    -- 生成设备ID（如果没有）
    local device_id = qingtian.device_id
    if not device_id or device_id == "" then
        math.randomseed(os.time() + os.clock())
        local chars = "0123456789abcdef"
        device_id = ""
        for i = 1, 32 do
            local pos = math.random(1, #chars)
            device_id = device_id .. chars:sub(pos, pos)
        end
        self.settings:set_qingtian_token("", device_id)
        log_info("[FanQie] 生成新设备ID:", device_id)
    else
        log_info("[FanQie] 使用已有设备ID:", device_id)
    end
    
    -- 发送登录请求
    local login_url = FanQie.qt_login_url(server_url)
    local login_data = {
        register_email = username,
        password = password,
        device_id = device_id
    }
    
    log_info("[FanQie] 发送登录请求:", "url=" .. login_url)
    
    local headers = {
        ["User-Agent"] = FanQie.MOBILE_UA,
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json, text/plain, */*",
    }
    
    local text, code, resp_headers, status = self:request({
        url = login_url,
        method = "POST",
        headers = headers,
        body = self:json_encode(login_data),
    })
    
    log_info("[FanQie] 登录响应:", "code=" .. tostring(code), "status=" .. tostring(status or "nil"))
    
    if code and code >= 200 and code < 300 then
        local ok, result = pcall(function()
            return self:json_decode(text)
        end)
        
        if ok and result then
            if result.code == 0 and result.key then
                -- 登录成功，保存 token
                self.settings:set_qingtian_token(result.key, device_id)
                local token_preview = result.key:sub(1, 15) .. "..."
                log_info("[FanQie] 晴天登录成功:", "token=" .. token_preview, "deviceId=" .. device_id)
                return result.key, device_id
            else
                local err_msg = tostring(result.message or result.msg or "未知错误")
                log_error("[FanQie] 晴天登录失败:", "code=" .. tostring(result.code), "msg=" .. err_msg)
                error("晴天登录失败: " .. err_msg)
            end
        else
            log_error("[FanQie] 晴天登录响应解析失败:", "响应前100字节=" .. tostring(text or ""):sub(1, 100))
            error("晴天登录响应解析失败")
        end
    else
        log_error("[FanQie] 晴天登录HTTP失败:", "code=" .. tostring(code), "status=" .. tostring(status or "nil"))
        error("晴天登录请求失败: HTTP " .. tostring(code))
    end
end

-- 确保晴天已登录（自动登录）
function Client:_qingtian_ensure_login()
    local qingtian = self.settings:get_source("qingtian")
    local token = H.trim(qingtian.token or "")
    
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    local function log_info(...) if ok_logger and logger_mod then logger_mod.info(...) end end
    
    -- 服务器检测：缓存5分钟
    local server_url = H.trim(qingtian.server_url or "")
    local detected_url = nil
    local now = os.time()
    
    if qingtian._detected_url and qingtian._detected_at and (now - qingtian._detected_at) < 300 then
        if qingtian._detected_url ~= server_url then
            log_info("[FanQie] 晴天使用缓存服务器:", qingtian._detected_url)
            detected_url = qingtian._detected_url
            server_url = detected_url
        end
    else
        -- 优先使用：get_qingtian_server_list（server_url 放在第一个 + defaults 去重追加）
        -- 回退：qt.servers / qt.server_list
        local servers
        if self.get_qingtian_server_list then
            servers = self:get_qingtian_server_list()
        end
        if not servers or type(servers) ~= "table" or #servers == 0 then
            servers = qingtian.servers or qingtian.server_list
        end
        if servers and type(servers) == "table" and #servers > 1 then
            local detected = self:check_servers(servers)
            if detected.found and detected.available then
                local avail_url = H.trim(detected.available)
                if avail_url ~= server_url then
                    log_info("[FanQie] 晴天服务器自动选择 (本次):", "from=" .. server_url, "to=" .. avail_url)
                    detected_url = avail_url
                    server_url = avail_url
                end
                qingtian._detected_url = avail_url
                qingtian._detected_at = now
                self.settings:set_source("qingtian", qingtian)
                self.settings:flush()
            end
        end
    end
    
    if token ~= "" then
        log_info("[FanQie] 晴天Token已存在，跳过登录:", "token=" .. token:sub(1, 15) .. "...")
        return token, qingtian.device_id, detected_url
    end
    
    -- 没有 token，尝试自动登录
    local auto_login = qingtian.auto_login
    if auto_login == false then
        error("晴天未登录，且自动登录已禁用")
    end
    
    log_info("[FanQie] 晴天Token不存在，开始自动登录...")
    return self:qingtian_login(detected_url)
end

-- 通过晴天获取正文
-- opts: { review = bool }  -- 是否启用段评模式
function Client:qingtian_get_content(item_id, book_id, opts)
    opts = opts or {}
    local token, device_id, detected_url = self:_qingtian_ensure_login()
    local qingtian = self.settings:get_source("qingtian")
    local server_url = detected_url or H.trim(qingtian.server_url or "")
    
    local content_url = FanQie.qt_content_url(server_url)
    
    -- 段评模式：review=1 作为 URL 查询参数（不是 POST body）
    if opts.review then
        local review_sources = { ["番茄"] = true, ["七猫"] = true, ["塔读"] = true, ["QQ阅读"] = true, ["svip_QQ阅读"] = true }
        local src = H.trim(qingtian.source or "番茄")
        local tb = H.trim(qingtian.tab or "小说")
        if review_sources[src] and tb == "小说" then
            content_url = content_url .. "?review=1"
        end
    end
    
    -- 构建请求体（与后端保持一致）
    local content_body = {
        html = "",
        item_id = tostring(item_id),
        source = "番茄",
        tab = "小说",
        tone_id = "4",
        variable = "{}",
        version = "4.11.5.1",
    }
    if book_id and tostring(book_id) ~= "" then
        content_body.book_id = tostring(book_id)
    end
    
    -- 段评已通过 URL 查询参数传递，不再需要 POST body 中的 review 字段
    
    local body = self:json_encode(content_body)
    
    -- 构建 Cookie 认证
    local cookie_str = "qttoken=" .. token
    if device_id and device_id ~= "" then
        cookie_str = cookie_str .. ";deviceId=" .. device_id
    end
    
    local headers = {
        ["User-Agent"] = FanQie.MOBILE_UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Content-Type"] = "application/json",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
        ["Cookie"] = cookie_str,
    }
    
    local text, code, resp_headers, status = self:request({
        url = content_url,
        method = "POST",
        headers = headers,
        body = body,
    })
    
    if not code or code < 200 or code >= 300 then
        error(string.format("晴天HTTP请求失败: url=%s, itemId=%s, code=%s, status=%s",
            content_url, tostring(item_id), tostring(code or "nil"), tostring(status or "nil")))
    end
    
    local ok, result = pcall(function()
        return self:json_decode(text)
    end)
    
    if not ok or not result then
        error(string.format("晴天JSON解析失败: url=%s, itemId=%s, 响应前100字节=%s",
            content_url, tostring(item_id), tostring(text or ""):sub(1, 100)))
    end
    
    -- Token 过期检测与自动重登录
    if is_token_expired_error(result) and not opts._retried then
        local ok_logger, logger_mod = pcall(require, "fanqie.logger")
        local function log_info(...) if ok_logger and logger_mod then logger_mod.info(...) end end
        log_info("[FanQie] 晴天Token过期，尝试自动重新登录...")
        
        -- 清除旧 token 并重新登录
        self.settings:clear_qingtian_token()
        local new_token, new_device_id = self:qingtian_login()
        
        -- 用新 token 重试一次
        local retry_opts = { _retried = true, review = opts.review }
        return self:qingtian_get_content(item_id, book_id, retry_opts)
    end
    
    -- 检查内容
    local content = result.content or ""
    local title = result.title or ""
    local author = result.author or ""
    
    if not content or #content <= 50 then
        local err_msg = result.message or result.msg or result.error or "内容为空"
        error(string.format("晴天正文获取失败: itemId=%s, msg=%s, 长度=%s",
            tostring(item_id), tostring(err_msg), tostring(#content)))
    end
    
    -- 检查是否包含 VIP 广告等无效内容
    local has_ad = content:find("VIP", 1, true) and #content < 200
    if has_ad then
        error(string.format("晴天返回疑似广告内容: itemId=%s, 长度=%s",
            tostring(item_id), tostring(#content)))
    end
    
    -- 缓存 token 以便下次使用
    if token and token ~= "" then
        local qt_cfg = self.settings:get_source("qingtian")
        if qt_cfg.token ~= token then
            self.settings:set_qingtian_token(token, device_id)
        end
    end
    
    -- 提取段评数据：先从 content 中的 <comment> 标签提取，
    -- 再从响应的独立字段（para_comments/comments/reviews）补充
    -- 参考 kindle-forge 的 _inject_comment_ident_metadata：
    --   ident=" 前注入 base_url（相对路径→完整 URL）
    --   book_id= → book_id={book_id}&ssionid={qttoken}
    -- 同时把注入后的 ident 写回 content 中的 <comment> 标签，
    -- 这样 clean_chapter_content 生成的气泡 data-ident 就是完整可用的 URL
    local para_reviews = {}
    local base = server_url:gsub("/+$", "")  -- 去掉末尾斜杠
    local bid_str = tostring(book_id or "")

    -- ident 注入函数：相对路径→完整 URL，空 book_id→填入 book_id+ssionid
    local function inject_ident(ident)
        local full_ident = ident
        if full_ident ~= "" and not full_ident:match("^https?://") then
            full_ident = base .. full_ident
        end
        if full_ident:find("book_id=", 1, true) and bid_str ~= "" then
            full_ident = full_ident:gsub("book_id=", "book_id=" .. bid_str .. "&ssionid=" .. token)
        end
        return full_ident
    end

    -- 1. 从 content 中提取 <comment> 标签，用 gsub 同时注入 ident 并写回 content
    if opts.review and content:find("<comment", 1, true) then
        -- 带 count 的 <comment ident="..." count="..." />
        content = content:gsub('<comment%s+ident="([^"]*)"%s+count="([^"]*)"%s*/?>', function(ident, count)
            local full_ident = inject_ident(ident)
            table.insert(para_reviews, { ident = full_ident, count = tonumber(count) or 0 })
            return '<comment ident="' .. full_ident .. '" count="' .. count .. '" />'
        end)
        -- 不带 count 的 <comment ident="..." />
        content = content:gsub('<comment%s+ident="([^"]*)"%s*/?>', function(ident)
            local full_ident = inject_ident(ident)
            local found = false
            for _, pr in ipairs(para_reviews) do
                if pr.ident == full_ident then found = true; break end
            end
            if not found then
                table.insert(para_reviews, { ident = full_ident, count = 0 })
            end
            return '<comment ident="' .. full_ident .. '" />'
        end)
    end
    
    -- 2. 从响应的独立字段中提取段评数据
    if opts.review and result then
        local review_data = result.para_comments or result.paraReviews 
            or result.comments or result.reviews or result.para_reviews
        if type(review_data) == "table" and #review_data > 0 then
            for _, item in ipairs(review_data) do
                if type(item) == "table" and (item.ident or item.id) then
                    local ident = item.ident or item.id or ""
                    local count = item.count or item.comment_count or item.commentCount or 0
                    local found = false
                    for _, pr in ipairs(para_reviews) do
                        if pr.ident == ident then found = true; break end
                    end
                    if not found and ident ~= "" then
                        table.insert(para_reviews, { ident = ident, count = tonumber(count) or 0 })
                    end
                end
            end
        end
    end
    
    -- 记录段评提取结果
    if opts.review then
        local ok_logger, logger_mod = pcall(require, "fanqie.logger")
        if ok_logger and logger_mod then
            logger_mod.info("[FanQie] 段评提取:", "itemId=" .. tostring(item_id), "found=" .. tostring(#para_reviews))
        end
    end
    
    return {
        content = content,
        title = title,
        author = author,
        para_reviews = para_reviews,
        has_review = opts.review and #para_reviews > 0,
    }
end

-- 晴天段评 API
-- ident: 来自 <comment> 标签的 ident URL（已注入 base_url、book_id、ssionid 等）
-- 抓包验证：正确的 JSON 端点是 /api/fanqie/comment/paragraph/list（不是 /para_review）
--   参数: book_id(Base64), item_id, item_version, author_user_id, cursor, para_index
--   响应: data.data_list[].comment.{common,stat}, data.common_list_info.total
function Client:qingtian_get_para_review(ident)
    local token, device_id, detected_url = self:_qingtian_ensure_login()
    local qingtian = self.settings:get_source("qingtian")
    local server_url = detected_url or H.trim(qingtian.server_url or "")
    local base = server_url:gsub("/+$", "")

    -- 从 ident URL 中提取段评请求所需的参数
    -- ident 格式: {base}/get_para_review?book_id={b64}&ssionid=...&item_id=...&para=N&source=...&author_user_id=...&item_version=...
    local function extract_param(url, key)
        local val = url:match("[?&]" .. key .. "=([^&]*)")
        return val or ""
    end

    local p_book_id    = extract_param(ident, "book_id")
    local p_item_id    = extract_param(ident, "item_id")
    local p_para       = extract_param(ident, "para")
    local p_author_uid = extract_param(ident, "author_user_id")
    local p_item_ver   = extract_param(ident, "item_version")

    -- 构建正确的段评 API URL
    local review_url = string.format(
        "%s/api/fanqie/comment/paragraph/list?book_id=%s&item_id=%s&item_version=%s&author_user_id=%s&cursor=&para_index=%s",
        base, p_book_id, p_item_id, p_item_ver, p_author_uid, p_para
    )

    -- 段评 API 不需要 qttoken 认证（抓包验证），但保留 token Cookie 不影响
    local cookie_str = "qttoken=" .. token
    if device_id and device_id ~= "" then
        cookie_str = cookie_str .. ";deviceId=" .. device_id
    end
    -- 添加段评功能开关 Cookie（抓包中有 fqpara=on）
    cookie_str = cookie_str .. ";fqpara=on"

    local headers = {
        ["User-Agent"] = FanQie.MOBILE_UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Content-Type"] = "application/json",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
        ["Cookie"] = cookie_str,
        ["Referer"] = base .. "/get_para_review?book_id=" .. p_book_id .. "&item_id=" .. p_item_id,
    }
    
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    if ok_logger and logger_mod then
        logger_mod.info("[FanQie] 晴天段评请求:", "url=" .. review_url:sub(1, 120))
    end
    
    local ok, text, code = pcall(function()
        return self:request({
            url = review_url,
            method = "GET",
            headers = headers,
            timeout = 10,
        })
    end)
    
    if not ok or not code or code < 200 or code >= 300 then
        error("晴天段评请求失败: HTTP " .. tostring(code or "nil"))
    end

    -- 日志：记录原始响应前 300 字符，便于诊断空数据问题
    local ok_logger2, logger_mod2 = pcall(require, "fanqie.logger")
    if ok_logger2 and logger_mod2 then
        local preview = tostring(text or ""):sub(1, 300)
        logger_mod2.info("[FanQie] 晴天段评响应: code=" .. tostring(code)
            .. " len=" .. tostring(#(text or ""))
            .. " preview=" .. preview)
    end

    local ok_decode, result = pcall(function()
        return self:json_decode(text)
    end)

    if not ok_decode or not result then
        error("晴天段评响应解析失败: " .. tostring(text or ""):sub(1, 200))
    end
    
    -- Token 过期重试
    if is_token_expired_error(result) then
        self.settings:clear_qingtian_token()
        self:qingtian_login()
        return self:qingtian_get_para_review(ident)
    end
    
    return result
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
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
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
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
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
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
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
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
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
    for _, item in ipairs(book_shelf_info) do
        if item.book_id then
            table.insert(shelf_book_ids, item.book_id)
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
            local progress = progress_map[tostring(book.book_id)]
            if progress then
                book.read_progress = progress.read_progress
                book.index = progress.index
                book.latest_read_item_id = progress.item_id
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

-- Fetch chapter content via the official FanQie API (public, no login needed).
-- Returns {content, title, author} on success; errors on failure.
function Client:official_get_content(book_id, item_id)
    local url = FanQie.chapter_content_url(book_id, item_id)
    local result = self:get_json(url)
    if type(result) == "table" and result.data then
        local content = result.data.content or ""
        if content and #content > 50 then
            return {
                content = content,
                title = result.data.title or "",
                author = result.data.author or "",
            }
        end
        error(string.format("官方API返回内容过短: itemId=%s, 长度=%s",
            tostring(item_id), tostring(#content)))
    elseif type(result) == "table" then
        local keys = {}
        for k, _ in pairs(result) do table.insert(keys, tostring(k)) end
        error(string.format("官方API响应格式异常: itemId=%s, 缺少data字段, keys=%s",
            tostring(item_id), table.concat(keys, ",")))
    end
    error(string.format("官方API响应无效: itemId=%s, type=%s", tostring(item_id), type(result)))
end

-- ============================================================================
-- 大灰狼 (DaHuiLang) Source
-- Login API: POST {server}/login_api  body={register_email, password}  → {code, key}
-- Key-only:  POST {server}/user_api  with cookie: qttoken={key}
-- Content:   POST {server}/content  body={item_id, source, tab, ...}  cookie: qttoken+deviceId
-- ============================================================================

function Client:dahuilang_login(override_server_url)
    local dl = self.settings:get_source("dahuilang")
    local server_url = override_server_url or H.trim(dl.server_url or "")
    local username = H.trim(dl.username or "")
    local password = H.trim(dl.password or "")
    local key = H.trim(dl.key or "")

    if server_url == "" then
        error("大灰狼服务器地址未配置")
    end

    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    local function log_info(...) if ok_logger and logger_mod then logger_mod.info(...) end end
    local function log_error(...) if ok_logger and logger_mod then logger_mod.error(...) end end

    -- 生成 device_id
    local device_id = H.trim(dl.device_id or "")
    if device_id == "" then
        math.randomseed(os.time() + os.clock())
        local chars = "0123456789abcdef"
        device_id = ""
        for i = 1, 32 do
            local pos = math.random(1, #chars)
            device_id = device_id .. chars:sub(pos, pos)
        end
        self.settings:set_source_field("dahuilang", "device_id", device_id)
        log_info("[FanQie] 大灰狼生成新设备ID:", device_id)
    end

    -- 密钥登录（直接用密钥）
    if key ~= "" and (username == "" or password == "") then
        log_info("[FanQie] 大灰狼密钥登录:", "key=" .. key:sub(1, 15) .. "..., deviceId=" .. device_id)
        local cookie_str = "qttoken=" .. key .. ";deviceId=" .. device_id
        local text, code = self:request({
            url = server_url .. "/user_api",
            method = "POST",
            headers = {
                ["User-Agent"] = FanQie.MOBILE_UA,
                ["Content-Type"] = "application/json",
                ["Cookie"] = cookie_str,
            },
        })
        if code and code >= 200 and code < 300 then
            local ok_decode, result = pcall(function() return self:json_decode(text) end)
            if ok_decode and result and result.id then
                self.settings:set_dahuilang_token(key, device_id)
                log_info("[FanQie] 大灰狼密钥登录成功")
                return key, device_id
            end
        end
        error("大灰狼密钥登录失败：密钥无效或已过期")
    end

    -- 账号密码登录（两步走：先 GET /login 获取 session cookies，再 POST /login_api）
    if username == "" or password == "" then
        error("大灰狼配置不完整：需要邮箱和密码，或密钥")
    end

    log_info("[FanQie] 大灰狼账号登录:", "server=" .. server_url, "user=" .. username)

    local base = server_url
    if base:sub(-1) == "/" then base = base:sub(1, -2) end

    local mobile_ua = FanQie.MOBILE_UA

    -- Step 0 (optimization): 直接 POST /login_api，不带 session cookie 先试一次，
    -- 大多数后端不需要前置 cookie，成功则省去一次 5s+ 的 GET /login。
    do
        local login_url0 = base .. "/login_api"
        local headers0 = {
            ["User-Agent"] = mobile_ua,
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json, text/plain, */*",
        }
        local text0, code0 = self:request({
            url = login_url0,
            method = "POST",
            headers = headers0,
            body = self:json_encode(login_data),
            timeout = 8,
        })
        if code0 and code0 >= 200 and code0 < 300 and text0 and text0 ~= "" then
            local ok_decode0, result0 = pcall(function() return self:json_decode(text0) end)
            if ok_decode0 and result0 and result0.code == 0 and result0.key then
                self.settings:set_dahuilang_token(result0.key, device_id)
                log_info("[FanQie] 大灰狼登录成功 (快速模式, 无前置GET):",
                    "token=" .. result0.key:sub(1, 15) .. "..., deviceId=" .. device_id, "server=" .. base)
                return result0.key, device_id
            end
        end
    end

    -- Step 1: GET /login 获取 session cookies (仅在快速模式失败后回退)
    local login_page_text, login_page_code, login_page_headers = self:request({
        url = base .. "/login",
        method = "GET",
        headers = {
            ["User-Agent"] = mobile_ua,
            ["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
        timeout = 8,
    })

    if not login_page_code or login_page_code < 200 or login_page_code >= 400 then
        log_error("[FanQie] 大灰狼登录页面访问失败:", "code=" .. tostring(login_page_code))
        error("大灰狼登录页面访问失败: HTTP " .. tostring(login_page_code) .. "，服务器 " .. server_url .. " 不可用")
    end

    -- 提取 Set-Cookie 用于后续请求
    local cookies = {}
    local set_cookie = header_value(login_page_headers, "set-cookie")
    if set_cookie then
        for name, value in tostring(set_cookie):gmatch("([^=;%s]+)=([^;%s]*)") do
            if name and value then
                table.insert(cookies, name .. "=" .. value)
            end
        end
    end
    local cookie_str = table.concat(cookies, "; ")

    -- Step 2: POST /login_api 携带 session cookies
    local login_url = base .. "/login_api"

    local login_data = {
        register_email = username,
        password = password,
    }

    local headers = {
        ["User-Agent"] = mobile_ua,
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = base .. "/login",
        ["Origin"] = base,
    }
    if cookie_str ~= "" then
        headers["Cookie"] = cookie_str
    end

    local text, code, resp_headers = self:request({
        url = login_url,
        method = "POST",
        headers = headers,
        body = self:json_encode(login_data),
        timeout = 8,
    })

    if not code or code < 200 or code >= 300 then
        log_error("[FanQie] 大灰狼登录HTTP失败:", "code=" .. tostring(code))
        if code == 404 then
            error("大灰狼登录请求失败: HTTP 404 - 服务器 " .. server_url .. " 不正确或后端服务不可用。可尝试其他线路")
        end
        error("大灰狼登录请求失败: HTTP " .. tostring(code))
    end

    local ok_decode, result = pcall(function() return self:json_decode(text) end)
    if not ok_decode or not result then
        error("大灰狼登录响应解析失败: " .. tostring(text or ""):sub(1, 200))
    end

    if result.code == 0 and result.key then
        self.settings:set_dahuilang_token(result.key, device_id)
        log_info("[FanQie] 大灰狼登录成功:", "token=" .. result.key:sub(1, 15) .. "..., deviceId=" .. device_id, "server=" .. base)
        return result.key, device_id
    else
        local err_msg = tostring(result.msg or result.message or "未知错误")
        log_error("[FanQie] 大灰狼登录失败:", "code=" .. tostring(result.code), "msg=" .. err_msg)
        error("大灰狼登录失败: " .. err_msg)
    end
end

function Client:dahuilang_logout()
    self.settings:clear_dahuilang_token()
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    if ok_logger and logger_mod then
        logger_mod.info("[FanQie] 大灰狼已登出")
    end
end

function Client:_dahuilang_ensure_login()
    local dl = self.settings:get_source("dahuilang")
    local token = H.trim(dl.token or "")

    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    local function log_info(...) if ok_logger and logger_mod then logger_mod.info(...) end end
    
    -- 服务器检测：缓存5分钟，避免每次请求都检测
    local server_url = H.trim(dl.server_url or "")
    local detected_url = nil
    local now = os.time()
    
    -- 检查缓存
    if dl._detected_url and dl._detected_at and (now - dl._detected_at) < 300 then
        -- 缓存有效，使用缓存的 URL
        if dl._detected_url ~= server_url then
            log_info("[FanQie] 大灰狼使用缓存服务器:", dl._detected_url)
            detected_url = dl._detected_url
            server_url = detected_url
        end
    else
        -- 无缓存或缓存过期，执行检测
        -- 优先使用：get_dahuilang_server_list（把用户配置的 server_url 放在第一个 + defaults 去重追加）
        -- 回退：dl.servers/dl.server_list（config 中显式写的列表）
        local servers
        if self.get_dahuilang_server_list then
            servers = self:get_dahuilang_server_list()
        end
        if not servers or type(servers) ~= "table" or #servers == 0 then
            servers = dl.servers or dl.server_list
        end
        if servers and type(servers) == "table" and #servers > 1 then
            local detected = self:check_servers(servers)
            if detected.found and detected.available then
                local avail_url = H.trim(detected.available)
                if avail_url ~= server_url then
                    log_info("[FanQie] 大灰狼服务器自动选择 (本次):", "from=" .. server_url, "to=" .. avail_url)
                    detected_url = avail_url
                    server_url = avail_url
                end
                -- 缓存检测结果
                dl._detected_url = avail_url
                dl._detected_at = now
                self.settings:set_source("dahuilang", dl)
                self.settings:flush()
            end
        end
    end

    if token ~= "" then
        return token, dl.device_id, detected_url
    end

    -- 自动登录，传递检测到的服务器 URL
    log_info("[FanQie] 大灰狼Token不存在，开始自动登录...")
    return self:dahuilang_login(detected_url)
end

-- Fetch chapter content via the 大灰狼 aggregation API.
-- opts: { review = bool }  -- 是否启用段评模式
function Client:dahuilang_get_content(book_id, item_id, opts)
    opts = opts or {}
    local token, device_id, detected_url = self:_dahuilang_ensure_login()
    local dl = self.settings:get_source("dahuilang")
    local server_url = detected_url or H.trim(dl.server_url or "")

    if server_url == "" then
        error("大灰狼服务器地址未配置")
    end

    local content_url = server_url
    if content_url:sub(-1) ~= "/" then content_url = content_url .. "/" end
    content_url = content_url .. "content"
    
    -- 段评模式：review=1 作为 URL 查询参数（不是 POST body）
    if opts.review then
        local review_sources = { ["番茄"] = true, ["七猫"] = true, ["塔读"] = true, ["QQ阅读"] = true, ["svip_QQ阅读"] = true }
        local src = H.trim(dl.source or "番茄")
        local tb = H.trim(dl.tab or "小说")
        if review_sources[src] and tb == "小说" then
            content_url = content_url .. "?review=1"
        end
    end

    local source = H.trim(dl.source or "番茄")
    local tab = H.trim(dl.tab or "小说")
    local tone_id = H.trim(dl.tone_id or "4")

    local request_body = {
        html = "",
        item_id = tostring(item_id),
        source = source,
        tab = tab,
        tone_id = tone_id,
        variable = "{}",
        version = "4.11.5.1",
    }
    if book_id and tostring(book_id) ~= "" then
        request_body.book_id = tostring(book_id)
    end
    
    -- 段评已通过 URL 查询参数传递，不再需要 POST body 中的 review 字段

    local cookie_str = "qttoken=" .. token
    if device_id and device_id ~= "" then
        cookie_str = cookie_str .. ";deviceId=" .. device_id
    end

    local headers = {
        ["User-Agent"] = FanQie.MOBILE_UA,
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json, text/plain, */*",
        ["Cookie"] = cookie_str,
    }

    local text, code, resp_headers, status = self:request({
        url = content_url,
        method = "POST",
        headers = headers,
        body = self:json_encode(request_body),
    })

    if not code or code < 200 or code >= 300 then
        local err_msg = "大灰狼HTTP请求失败"
        if code then err_msg = err_msg .. ": code=" .. tostring(code) end
        if status then err_msg = err_msg .. ", status=" .. tostring(status) end
        error(err_msg)
    end

    local ok_decode, result = pcall(function() return self:json_decode(text) end)
    if not ok_decode or not result then
        error("大灰狼响应解析失败: " .. tostring(text or ""):sub(1, 200))
    end

    -- Token 过期检测与自动重登录
    if is_token_expired_error(result) and not opts._retried then
        local ok_logger, logger_mod = pcall(require, "fanqie.logger")
        local function log_info(...) if ok_logger and logger_mod then logger_mod.info(...) end end
        log_info("[FanQie] 大灰狼Token过期，尝试自动重新登录...")
        
        self.settings:clear_dahuilang_token()
        local new_token, new_device_id = self:dahuilang_login()
        
        local retry_opts = { _retried = true, review = opts.review }
        return self:dahuilang_get_content(book_id, item_id, retry_opts)
    end

    if result.msg and result.content == nil then
        error("大灰狼API返回错误: " .. tostring(result.msg))
    end

    local content = result.content or ""
    if type(content) == "string" and #content > 50 then
        if result.qttoken and result.qttoken ~= token then
            self.settings:set_dahuilang_token(result.qttoken, device_id)
        end
        
        -- 提取段评数据：先从 content 中的 <comment> 标签提取，
        -- 再从响应的独立字段（para_comments/comments/reviews）补充
        -- 参考 kindle-forge 的 _inject_comment_ident_metadata：
        --   ident=" 前注入 base_url（相对路径→完整 URL）
        --   book_id= → book_id={book_id}&ssionid={qttoken}
        -- 同时把注入后的 ident 写回 content 中的 <comment> 标签，
        -- 这样 clean_chapter_content 生成的气泡 data-ident 就是完整可用的 URL
        local para_reviews = {}
        local base = server_url:gsub("/+$", "")  -- 去掉末尾斜杠
        local bid_str = tostring(book_id or "")

        -- ident 注入函数：相对路径→完整 URL，空 book_id→填入 book_id+ssionid
        local function inject_ident(ident)
            local full_ident = ident
            if full_ident ~= "" and not full_ident:match("^https?://") then
                full_ident = base .. full_ident
            end
            if full_ident:find("book_id=", 1, true) and bid_str ~= "" then
                full_ident = full_ident:gsub("book_id=", "book_id=" .. bid_str .. "&ssionid=" .. token)
            end
            return full_ident
        end

        -- 1. 从 content 中提取 <comment> 标签，用 gsub 同时注入 ident 并写回 content
        if opts.review and content:find("<comment", 1, true) then
            -- 带 count 的 <comment ident="..." count="..." />
            content = content:gsub('<comment%s+ident="([^"]*)"%s+count="([^"]*)"%s*/?>', function(ident, count)
                local full_ident = inject_ident(ident)
                table.insert(para_reviews, { ident = full_ident, count = tonumber(count) or 0 })
                return '<comment ident="' .. full_ident .. '" count="' .. count .. '" />'
            end)
            -- 不带 count 的 <comment ident="..." />
            content = content:gsub('<comment%s+ident="([^"]*)"%s*/?>', function(ident)
                local full_ident = inject_ident(ident)
                local found = false
                for _, pr in ipairs(para_reviews) do
                    if pr.ident == full_ident then found = true; break end
                end
                if not found then
                    table.insert(para_reviews, { ident = full_ident, count = 0 })
                end
                return '<comment ident="' .. full_ident .. '" />'
            end)
        end
        
        -- 2. 从响应的独立字段中提取段评数据
        if opts.review and result then
            local review_data = result.para_comments or result.paraReviews 
                or result.comments or result.reviews or result.para_reviews
            if type(review_data) == "table" and #review_data > 0 then
                for _, item in ipairs(review_data) do
                    if type(item) == "table" and (item.ident or item.id) then
                        local ident = item.ident or item.id or ""
                        local count = item.count or item.comment_count or item.commentCount or 0
                        local found = false
                        for _, pr in ipairs(para_reviews) do
                            if pr.ident == ident then found = true; break end
                        end
                        if not found and ident ~= "" then
                            table.insert(para_reviews, { ident = ident, count = tonumber(count) or 0 })
                        end
                    end
                end
            end
        end
        
        -- 记录段评提取结果
        if opts.review then
            local ok_logger2, logger_mod2 = pcall(require, "fanqie.logger")
            if ok_logger2 and logger_mod2 then
                logger_mod2.info("[FanQie] 大灰狼段评提取:", "itemId=" .. tostring(item_id), "found=" .. tostring(#para_reviews))
            end
        end
        
        return {
            content = content,
            title = result.title or "",
            author = result.author or "",
            para_reviews = para_reviews,
            has_review = opts.review and #para_reviews > 0,
        }
    end

    error(string.format("大灰狼返回内容过短: itemId=%s, 长度=%s",
        tostring(item_id), tostring(#content)))
end

-- 大灰狼段评 API
-- ident: 来自 <comment> 标签的 ident URL（已注入 base_url、book_id、ssionid 等）
-- 大灰狼段评端点：/para_review（已实测跑通，保持原获取方式）
--   参数: book_id, item_id, para, source, cursor
--   响应: data.comments[], data.total, data.has_more, data.next_cursor
function Client:dahuilang_get_para_review(ident)
    local token, device_id, detected_url = self:_dahuilang_ensure_login()
    local dl = self.settings:get_source("dahuilang")
    local server_url = detected_url or H.trim(dl.server_url or "")
    local base = server_url:gsub("/+$", "")

    if base == "" then
        error("大灰狼服务器地址未配置")
    end

    -- 构建 JSON 端点 URL：/get_para_review → /para_review
    -- 只保留 book_id/item_id/para/source/cursor 参数
    local review_url = ident
    if review_url:find("/get_para_review", 1, true) then
        review_url = review_url:gsub("/get_para_review", "/para_review")
    elseif not review_url:find("/para_review", 1, true) then
        -- 如果 ident 不是标准端点，尝试从查询参数构建
        local query = review_url:match("%?(.+)$") or ""
        local params = {}
        for k, v in query:gmatch("([^&=]+)=([^&]*)") do
            if k == "book_id" or k == "item_id" or k == "para" or k == "source" or k == "cursor" then
                table.insert(params, k .. "=" .. v)
            end
        end
        review_url = base .. "/para_review"
        if #params > 0 then
            review_url = review_url .. "?" .. table.concat(params, "&")
        end
    end

    local cookie_str = "qttoken=" .. token
    if device_id and device_id ~= "" then
        cookie_str = cookie_str .. ";deviceId=" .. device_id
    end

    local headers = {
        ["User-Agent"] = FanQie.MOBILE_UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
        ["Cookie"] = cookie_str,
    }
    
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    if ok_logger and logger_mod then
        logger_mod.info("[FanQie] 大灰狼段评请求:", "url=" .. review_url:sub(1, 120))
    end
    
    local ok, text, code = pcall(function()
        return self:request({
            url = review_url,
            method = "GET",
            headers = headers,
            timeout = 10,
        })
    end)
    
    if not ok or not code or code < 200 or code >= 300 then
        error("大灰狼段评请求失败: HTTP " .. tostring(code or "nil"))
    end

    -- 日志：记录原始响应前 300 字符，便于诊断空数据问题
    if ok_logger and logger_mod then
        local preview = tostring(text or ""):sub(1, 300)
        logger_mod.info("[FanQie] 大灰狼段评响应: code=" .. tostring(code)
            .. " len=" .. tostring(#(text or ""))
            .. " preview=" .. preview)
    end

    local ok_decode, result = pcall(function()
        return self:json_decode(text)
    end)

    if not ok_decode or not result then
        error("大灰狼段评响应解析失败: " .. tostring(text or ""):sub(1, 200))
    end
    
    -- Token 过期重试
    if is_token_expired_error(result) then
        self.settings:clear_dahuilang_token()
        self:dahuilang_login()
        return self:dahuilang_get_para_review(ident)
    end
    
    return result
end

-- Generic source scheduler: iterate enabled+configured sources in priority
-- order, applying per-source rate limiting, and fall back to the next on
-- failure. Replaces the old hardcoded qingtian->official fallback.
-- opts: { review = bool }  -- 是否启用段评模式
function Client:get_chapter_content_with_fallback(book_id, item_id, opts)
    opts = opts or {}
    local t_start = now_ms()
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    local function log_info(...) if ok_logger and logger_mod then logger_mod.info(...) end end
    local function log_debug(...) if ok_logger and logger_mod then logger_mod.debug(...) end end
    local function log_error(...) if ok_logger and logger_mod then logger_mod.error(...) end end

    local SourceManager = require("fanqie.sources")
    local sources = SourceManager.get_active_sources(self.settings)
    if #sources == 0 then
        error("无可用书源（请在「设置 → 书源管理」中启用并配置至少一个源）")
    end

    -- 本轮放行请求记录的时间戳，供子进程→父进程合并限流状态。
    -- 子进程 fork 出 RATE_LIMIT_TIMESTAMPS 副本，记录的时间戳会随子进程退出丢失，
    -- 需经此返回值带回父进程由 SourceManager.merge_rate_limit_timestamps 合并。
    local recorded = {}
    local errors = {}
    for _, src in ipairs(sources) do
        local fetcher = self._source_fetchers[src.id]
        if fetcher then
            local rl = src.config.rate_limit or {}
            local ok_rl, wait, ts = SourceManager.rate_limit_check(src.id, rl.max_requests, rl.window_seconds)
            if not ok_rl then
                log_debug("[FanQie] 源被限流，跳过:",
                    "source=" .. src.id, "wait=" .. tostring(wait) .. "s")
                table.insert(errors, src.id .. ": 限流中(需等" .. tostring(wait) .. "s)")
            else
                if ts then
                    table.insert(recorded, { source_id = src.id, ts = ts })
                end
                log_info("[FanQie] 尝试源:",
                    "source=" .. src.id, "itemId=" .. tostring(item_id))
                local t_src = now_ms()
                local ok, result = pcall(fetcher, book_id, item_id, opts)
                local elapsed = now_ms() - t_src
                if ok and result and result.content then
                    log_debug("[FanQie][perf] 源成功:",
                        "source=" .. src.id,
                        "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
                        "itemId=" .. tostring(item_id),
                        "长度=" .. tostring(#result.content))
                    -- 第3返回值 recorded：本轮记录的限流时间戳，供父进程合并
                    return result, src.id, recorded
                end
                local err_msg = "未知错误"
                if type(result) == "string" then
                    err_msg = result
                elseif type(result) == "table" and result.message then
                    err_msg = result.message
                end
                err_msg = err_msg:gsub("[%c]+", " ")
                log_debug("[FanQie][perf] 源失败，切换下一源:",
                    "source=" .. src.id,
                    "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
                    "err=" .. err_msg)
                table.insert(errors, src.id .. ": " .. err_msg)
            end
        end
    end

    local total_elapsed = now_ms() - t_start
    log_error("[FanQie] 所有书源均失败:",
        "itemId=" .. tostring(item_id),
        "total=" .. string.format("%.0f", total_elapsed) .. "ms",
        "errors=" .. table.concat(errors, " | "))
    error("所有书源均失败: " .. table.concat(errors, " | "))
end

return Client