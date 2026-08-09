-- fanqie/qrlogin.lua
-- 番茄小说扫码登录模块
--
-- 流程参考 kindle-forge/backend/fanqie/qrlogin.py:
--   1. GET 登录页预热 cookie (passport_csrf_token)
--   2. GET /passport/web/get_qrcode/ 获取二维码 token + qrcode_index_url
--   3. 轮询 GET /passport/web/check_qrconnect/?token=... 直到 jar 出现 sessionid
--
-- UI 参考 miuread-koreader/miuread/auth.lua:
--   generation 防旧回调 + QRMessage 显示二维码 + UIManager:scheduleIn 轮询
--
-- 网络请求通过 fanqie/async.lua 在子进程执行，避免阻塞 UI 线程；
-- 子进程只做 HTTP + JSON 解析，不写 settings（fork 继承的 settings 对象
-- 在子进程的写不影响父进程），登录成功后在 UI 线程回调里持久化 cookie。

local Device = require("device")
local UIManager = require("ui/uimanager")
local QRMessage = require("ui/widget/qrmessage")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")

local Async = require("fanqie.async")
local Cookie = require("fanqie.cookie")
local H = require("fanqie.helper")
local Log = require("fanqie.logger")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

--- 从跨进程结果重建 jar。
--- async.lua 用 JSON 把子进程结果序列化传回父进程，但 rapidjson/dkjson 对
--- 纯字符串 key 的 hash table 编码时会丢成空 {}，导致 result.jar 跨进程后变空
--- （表现为 has_sessionid=true 但 self.jar 是空 table）。
--- 解决：work_func 返回时额外带 jar_str（Cookie header 字符串，序列化可靠），
--- 父进程优先用 jar_str 解析回 table，回退到 jar 字段。
local function rebuild_jar(result)
    if type(result) ~= "table" then
        Log.debug("[FanQieQR] rebuild_jar: result非table=" .. type(result))
        return {}
    end
    local jar_str = result.jar_str
    Log.debug("[FanQieQR] rebuild_jar: jar_str_len=" .. tostring(jar_str and #jar_str or "nil")
        .. " jar_type=" .. tostring(type(result.jar))
        .. " has_sessionid=" .. tostring(result.has_sessionid))
    if jar_str and jar_str ~= "" then
        local parsed = Cookie.parse_cookie_header(jar_str)
        local cnt = 0
        for _ in pairs(parsed) do cnt = cnt + 1 end
        Log.debug("[FanQieQR] rebuild_jar: parse得到" .. cnt .. "个cookie, jar_str前80=" .. tostring(jar_str):sub(1, 80))
        return parsed
    end
    Log.debug("[FanQieQR] rebuild_jar: jar_str为空，回退result.jar")
    return result.jar or {}
end

local QRLogin = {}
QRLogin.__index = QRLogin

local LOGIN_PAGE = "https://fanqienovel.com/main/writer/login"
local GET_QRCODE_URL = "https://fanqienovel.com/passport/web/get_qrcode/"
local CHECK_QR_URL = "https://fanqienovel.com/passport/web/check_qrconnect/"
local FANQIE_LOGIN_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36 Edg/151.0.0.0"

local POLL_INTERVAL = 2     -- 轮询间隔（秒）
local QR_TIMEOUT = 300      -- 二维码整体超时（秒），对应 qrlogin.py 的 expire

local COMMON_PARAMS = {
    passport_jssdk_version = "3.0.16",
    passport_jssdk_type = "normal",
    aid = "2503",
    language = "zh",
    account_sdk_source = "web",
}

--- 大小写无关地取响应头（LuaSocket 返回的 header 键是小写的，但兼容一下）
local function header_value(headers, name)
    if not headers then return nil end
    local target = name:lower()
    for k, v in pairs(headers) do
        if tostring(k):lower() == target then return v end
    end
    return nil
end

local function json_decode(text)
    if not ok_json or not json or not text then return nil end
    local ok, v = pcall(function()
        if json.decode then return json.decode(text) end
        return json:decode(text)
    end)
    if ok then return v end
    return nil
end

--- 把 params table 拼成 query string（H.url_encode 只能编码单个字符串）
local function build_query(params)
    local parts = {}
    for k, v in pairs(params) do
        table.insert(parts, tostring(k) .. "=" .. H.url_encode(tostring(v)))
    end
    table.sort(parts)
    return table.concat(parts, "&")
end

--- 从 cookie jar 提取 passport_csrf_token
local function extract_csrf(jar)
    if not jar then return "" end
    local v = jar["passport_csrf_token"]
    if v and v ~= "" then return v end
    return ""
end

--- 底层 GET 请求（手动管理 cookie，不走 client 的自动 cookie 注入）。
--- 在子进程中调用。返回 text, resp_headers 或抛错（由 Async 的 pcall 捕获）。
--- opts.redirect = false 可禁用自动重定向（用于手动处理重定向以保留中间 Set-Cookie）
local function http_get(client, url, jar, csrf, opts)
    local headers = {
        ["User-Agent"] = FANQIE_LOGIN_UA,
        ["Accept"] = "application/json, text/javascript, text/html, */*",
        ["Accept-Language"] = "zh-CN,zh;q=0.9",
        ["Referer"] = LOGIN_PAGE,
        ["sec-fetch-dest"] = "empty",
        ["sec-fetch-mode"] = "cors",
        ["sec-fetch-site"] = "same-origin",
    }
    if jar and next(jar) ~= nil then
        headers["Cookie"] = Cookie.to_header(jar)
    end
    if csrf and csrf ~= "" then
        headers["x-tt-passport-csrf-token"] = csrf
    end
    local req_opts = {
        url = url,
        method = "GET",
        headers = headers,
        timeout = 15,
    }
    if opts and opts.redirect ~= nil then
        req_opts.redirect = opts.redirect
    end
    local text, code, resp_headers = client:request(req_opts)
    -- 禁用重定向时 3xx 也是正常响应，不禁用时只有 2xx
    if not code then
        error("HTTP 无响应码")
    end
    if opts and opts.redirect == false then
        -- 禁用重定向模式：2xx 和 3xx 都返回
        if code < 200 or code >= 400 then
            error("HTTP " .. tostring(code))
        end
    else
        if code < 200 or code >= 300 then
            error("HTTP " .. tostring(code))
        end
    end
    return text, resp_headers or {}
end

--- @param client  fanqie.client 实例（提供 :request）
--- @param settings fanqie.settings 实例（提供 :set/:flush/:is_cookie_configured）
--- @param plugin   FanQiePlugin 实例（提供 showBusy/closeBusy）
function QRLogin:new(client, settings, plugin)
    local self = setmetatable({}, QRLogin)
    self.client = client
    self.settings = settings
    self.plugin = plugin
    self.generation = 0   -- 版本号，防止旧回调干扰当前登录状态
    self.jar = {}         -- 扫码期间的临时 cookie jar
    self.dialog = nil     -- QRMessage 对话框
    self.retry_dialog = nil
    self.started = 0      -- 开始时间（超时检测）
    self.poll_failures = 0
    self.login_completed = false  -- 登录已完成标志，防止 dismiss_callback 误清空 jar
    return self
end

function QRLogin:toast(text)
    UIManager:show(InfoMessage:new{ text = tostring(text) })
end

function QRLogin:_close_dialog()
    if self.dialog then
        local d = self.dialog
        self.dialog = nil
        UIManager:close(d)
    end
end

function QRLogin:_close_retry_dialog()
    if self.retry_dialog then
        local d = self.retry_dialog
        self.retry_dialog = nil
        UIManager:close(d)
    end
end

--- 取消登录：generation+1 使所有旧回调失效，关闭对话框，清空临时 jar
function QRLogin:cancel()
    self.generation = self.generation + 1
    self.login_completed = false
    self:_close_dialog()
    self:_close_retry_dialog()
    self.jar = {}
    self.started = 0
    self.poll_failures = 0
    self.plugin:closeBusy()
end

--- 启动扫码登录（外部入口）
function QRLogin:start()
    self:_begin()
end

--- 获取二维码并显示
function QRLogin:_begin()
    self:cancel()  -- 清理旧状态并 generation+1
    local gen = self.generation
    self.started = os.time()
    self.plugin:showBusy(_("获取二维码中..."))
    Log.info("[FanQieQR] 开始获取二维码")

    Async.run(function()
        -- 步骤1: 访问登录页预热 cookie（passport_csrf_token 等）
        local _, login_headers = http_get(self.client, LOGIN_PAGE, nil, nil)
        local jar = Cookie.merge_set_cookie({}, header_value(login_headers, "set-cookie"))
        local csrf = extract_csrf(jar)

        -- 步骤2: 请求 get_qrcode
        local params = {}
        for k, v in pairs(COMMON_PARAMS) do params[k] = v end
        params["need_logo"] = "true"
        params["next"] = LOGIN_PAGE
        local qr_url = GET_QRCODE_URL .. "?" .. build_query(params)
        local qr_text, qr_headers = http_get(self.client, qr_url, jar, csrf)
        jar = Cookie.merge_set_cookie(jar, header_value(qr_headers, "set-cookie"))
        csrf = extract_csrf(jar)  -- get_qrcode 可能刷新了 csrf

        local data = json_decode(qr_text)
        if type(data) ~= "table" then error("二维码响应非 JSON") end
        if data.message ~= "success" then
            error("接口返回: " .. tostring(data.message))
        end
        local d = data.data or {}
        local token = d.token or ""
        local qr_index_url = d.qrcode_index_url or ""
        if token == "" or qr_index_url == "" then
            error("二维码数据不完整")
        end
        return {
            token = token,
            qr_url = qr_index_url,
            jar = jar,
            jar_str = Cookie.to_header(jar),
            csrf = csrf,
            expire_time = tonumber(d.expire_time) or 0,
        }
    end, function(ok, result, err)
        self.plugin:closeBusy()
        if not ok or gen ~= self.generation then return end
        if err then
            Log.warn("[FanQieQR] 获取二维码失败:", err)
            self:show_retry(_("获取二维码失败:") .. "\n" .. tostring(err))
            return
        end
        self.jar = rebuild_jar(result)

        -- 显示二维码（KOReader 内置 QRMessage 把 URL 生成二维码图片）
        local size = math.floor(math.min(Device.screen:getWidth(), Device.screen:getHeight()) * 0.72)
        local dialog
        dialog = QRMessage:new{
            text = result.qr_url,
            width = size,
            height = size,
            scale_factor = 0.9,
            dismiss_callback = function()
                Log.debug("[FanQieQR] dismiss_callback: gen=" .. tostring(gen) .. " generation=" .. tostring(self.generation) .. " dialog_match=" .. tostring(self.dialog == dialog) .. " login_completed=" .. tostring(self.login_completed))
                if self.dialog == dialog then self.dialog = nil end
                -- 登录已完成时不再触发 cancel（_finish_login_success 关对话框会同步触发此回调，
                -- 仅靠 generation 判断不可靠——UIManager:close 的 dismiss_callback 时机早于
                -- generation+1 生效，会导致 jar 被清空）
                if gen == self.generation and not self.login_completed then
                    self:cancel()
                    self:toast(_("已取消登录"))
                end
            end,
        }
        self.dialog = dialog
        UIManager:show(dialog)
        Log.info("[FanQieQR] 二维码已显示，开始轮询 token=", tostring(result.token):sub(1, 12))
        self:_schedule(gen, result.token, result.csrf, result.expire_time)
    end, { timeout = 20 })
end

--- 轮询扫码状态
function QRLogin:_schedule(gen, token, csrf, expire_time)
    if gen ~= self.generation then return end
    -- 超时检测
    if os.time() - self.started > QR_TIMEOUT then
        self:show_retry(_("二维码已过期"))
        return
    end
    if expire_time and expire_time > 0 and os.time() > expire_time then
        self:show_retry(_("二维码已过期"))
        return
    end

    Async.run(function()
        local params = {}
        for k, v in pairs(COMMON_PARAMS) do params[k] = v end
        params["token"] = token
        params["next"] = "/"
        local url = CHECK_QR_URL .. "?" .. build_query(params)
        -- 关键：禁用自动重定向！check_qrconnect 确认后返回 302 + Set-Cookie(sessionid)，
        -- socket.http 默认 redirect=true 会跟随重定向并丢弃 302 的 Set-Cookie，导致 sessionid 丢失。
        -- 对应 Python 后端的 allow_redirects=False。
        local text, resp_headers = http_get(self.client, url, self.jar, csrf, { redirect = false })
        local raw_set_cookie = header_value(resp_headers, "set-cookie") or ""
        local new_jar = Cookie.merge_set_cookie(self.jar, raw_set_cookie)
        local has_sessionid = new_jar.sessionid and new_jar.sessionid ~= ""

        -- 调试日志：打印 Set-Cookie 原始值和 jar 状态（截断防刷屏）
        Log.debug("[FanQieQR] 轮询响应 Set-Cookie(前300): " .. tostring(raw_set_cookie):sub(1, 300))
        Log.debug("[FanQieQR] has_sessionid=" .. tostring(has_sessionid) .. " jar_keys=" .. (function()
            local keys = {}
            for k, _ in pairs(new_jar) do table.insert(keys, k) end
            table.sort(keys)
            return table.concat(keys, ",")
        end)())

        -- 如果响应已带回 sessionid，直接成功（不需要解析 JSON）
        if has_sessionid then
            return { status = "success", jar = new_jar, jar_str = Cookie.to_header(new_jar), has_sessionid = true, redirect_url = "" }
        end

        -- 尝试解析 JSON（3xx 重定向时 body 可能为空，pcall 防止解析失败崩溃）
        local data
        if text and #text > 0 then
            local ok, parsed = pcall(json_decode, text)
            if ok and type(parsed) == "table" then
                data = parsed
            end
        end

        if not data then
            -- 3xx 重定向但无 sessionid：可能是中间跳转，记录 location 继续轮询
            local location = header_value(resp_headers, "location") or ""
            Log.debug("[FanQieQR] 非JSON响应, location=" .. tostring(location):sub(1, 100))
            return { status = "redirect", jar = new_jar, jar_str = Cookie.to_header(new_jar), has_sessionid = false, redirect_url = location }
        end

        local d = data.data or {}
        local status = d.status or ""
        -- confirmed/success 状态时打印完整 data 便于排查
        if status == "confirmed" or status == "success" then
            Log.info("[FanQieQR] 确认状态 data=" .. text:sub(1, 500))
        end
        return {
            status = status,
            error_code = d.error_code,
            jar = new_jar,
            jar_str = Cookie.to_header(new_jar),
            has_sessionid = has_sessionid,
            redirect_url = d.redirect_url or "",
        }
    end, function(ok, result, err)
        if not ok or gen ~= self.generation then return end
        if err then
            self.poll_failures = (self.poll_failures or 0) + 1
            if self.poll_failures == 1 or self.poll_failures % 5 == 0 then
                Log.warn("[FanQieQR] 轮询失败 #" .. self.poll_failures .. ":", err)
            end
            -- 网络错误：稍后重试，不立即判定失败
            UIManager:scheduleIn(POLL_INTERVAL, function()
                self:_schedule(gen, token, csrf, expire_time)
            end)
            return
        end
        self.poll_failures = 0
        self.jar = rebuild_jar(result)

        if result.has_sessionid then
            -- sessionid 已在 cookie 中（确认后 302 响应的 Set-Cookie 中带回）
            self:_finish_login_success(gen)
            return
        end

        local status = result.status or ""
        if status == "success" or status == "confirmed" then
            -- 用户已确认，但 sessionid 不在 302 响应中（可能在 redirect_url 后续跳转中）
            Log.info("[FanQieQR] 用户已确认 status=" .. status .. ", 访问 redirect_url 获取 sessionid")
            if result.redirect_url and result.redirect_url ~= "" then
                self:_finish_with_redirect(gen, result.redirect_url, csrf)
            else
                -- 没有 redirect_url，尝试直接用已有 jar 保存
                Log.warn("[FanQieQR] " .. status .. " 但无 redirect_url")
                self:_finish_login_success(gen)
            end
        elseif status == "expired" then
            self:show_retry(_("二维码已过期"))
        elseif status == "scanned" or status == "confirming" or status == "confirm" then
            Log.info("[FanQieQR] 用户已扫码/确认中 status=", status)
            UIManager:scheduleIn(POLL_INTERVAL, function()
                self:_schedule(gen, token, csrf, expire_time)
            end)
        else
            -- new / redirect / 其他非终态：继续轮询
            Log.debug("[FanQieQR] 轮询中 status=", status)
            UIManager:scheduleIn(POLL_INTERVAL, function()
                self:_schedule(gen, token, csrf, expire_time)
            end)
        end
    end, { timeout = 15 })
end

--- 用户确认后访问 redirect_url 获取 sessionid（字节跳动 passport 标准流程）
-- check_qrconnect 返回 status=success + redirect_url，但 sessionid 不会直接下发，
-- 必须带上扫码期间的 cookie jar 访问 redirect_url，服务器才会在 Set-Cookie 中返回 sessionid。
-- 注意：socket.http 自动重定向不传递 Cookie 也不合并中间 Set-Cookie，必须手动跟随。
function QRLogin:_finish_with_redirect(gen, redirect_url, csrf)
    if gen ~= self.generation then return end
    self.plugin:showBusy(_("正在完成登录..."))
    Log.info("[FanQieQR] 访问 redirect_url:", tostring(redirect_url):sub(1, 80))

    Async.run(function()
        local url = redirect_url
        local jar = self.jar
        local max_redirects = 5

        for i = 1, max_redirects + 1 do
            -- 禁用自动重定向，手动处理以保留每一跳的 Set-Cookie
            local _, resp_headers = http_get(self.client, url, jar, csrf, { redirect = false })
            -- 合并这一跳的 Set-Cookie（sessionid 可能在任意一跳中返回）
            jar = Cookie.merge_set_cookie(jar, header_value(resp_headers, "set-cookie"))

            -- 检查是否拿到 sessionid
            if jar.sessionid and jar.sessionid ~= "" then
                Log.info("[FanQieQR] 第" .. i .. "跳获取到 sessionid")
                return { jar = jar, jar_str = Cookie.to_header(jar), has_sessionid = true }
            end

            -- 检查是否需要继续重定向
            local location = header_value(resp_headers, "location")
            if not location or location == "" then
                -- 不再重定向，检查最终 jar
                local has_sid = jar.sessionid and jar.sessionid ~= ""
                return { jar = jar, jar_str = Cookie.to_header(jar), has_sessionid = has_sid }
            end

            -- 处理相对路径的 location
            if not location:match("^https?://") then
                local scheme, host = url:match("^(https?)://([^/]+)")
                if scheme then
                    if location:sub(1, 1) == "/" then
                        location = scheme .. "://" .. host .. location
                    else
                        local prefix = url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
                        location = prefix .. location
                    end
                end
            end
            Log.debug("[FanQieQR] 重定向第" .. i .. "跳 -> " .. tostring(location):sub(1, 80))
            url = location
        end
        error("重定向次数超限(" .. max_redirects .. ")，未获取到 sessionid")
    end, function(ok, result, err)
        self.plugin:closeBusy()
        if not ok or gen ~= self.generation then return end
        if err then
            Log.warn("[FanQieQR] 访问 redirect_url 失败:", err)
            self:show_retry(_("完成登录失败:") .. "\n" .. tostring(err))
            return
        end
        self.jar = rebuild_jar(result)
        if result.has_sessionid then
            self:_finish_login_success(gen)
        else
            -- redirect 后仍然没有 sessionid，记录 jar 内容便于排查
            local keys = {}
            for k, _ in pairs(self.jar) do table.insert(keys, k) end
            Log.warn("[FanQieQR] redirect 后仍无 sessionid, jar keys=" .. table.concat(keys, ","))
            self:show_retry(_("登录失败：未获取到 sessionid"))
        end
    end, { timeout = 20 })
end

--- 登录成功：持久化 cookie 并关闭对话框
-- 直接用扫码获取的 jar 覆盖（不再合并 config.lua 中的旧 cookie，以后只走扫码登录）
function QRLogin:_finish_login_success(gen)
    Log.debug("[FanQieQR] _finish_login_success: gen=" .. tostring(gen) .. " generation=" .. tostring(self.generation) .. " dialog=" .. tostring(self.dialog ~= nil))
    if gen ~= self.generation then return end
    -- 先把 jar 复制到局部变量：_close_dialog 触发的 dismiss_callback 可能执行 cancel()
    -- 清空 self.jar，用局部副本保证 cookie 不丢失。
    local jar = {}
    for k, v in pairs(self.jar) do jar[k] = v end
    -- 标记登录已完成，dismiss_callback 据此跳过 cancel()
    self.login_completed = true
    self.generation = self.generation + 1
    self:_close_dialog()
    -- 用局部 jar 统计和持久化（self.jar 可能已被 dismiss_callback→cancel() 清空）
    local keys = {}
    local count = 0
    for k, v in pairs(jar) do
        table.insert(keys, k)
        count = count + 1
    end
    table.sort(keys)
    Log.info("[FanQieQR] 登录成功，扫码获取到 " .. count .. " 个 cookie: " .. table.concat(keys, ", "))
    Log.info("[FanQieQR] cookie header: " .. Cookie.to_header(jar))
    self.settings:set("cookies", jar)
    self.settings:flush()
    self.jar = jar  -- 恢复 self.jar（dismiss_callback 可能已清空）
    self:toast(_("登录成功"))
end

--- 显示重试对话框（generation+1 使旧回调失效，等待用户选择）
function QRLogin:show_retry(msg)
    self.generation = self.generation + 1
    self:_close_dialog()
    local dialog
    dialog = ButtonDialog:new{
        title = tostring(msg),
        title_align = "center",
        buttons = {
            {
                {
                    text = _("重新获取"),
                    callback = function()
                        if self.retry_dialog == dialog then self.retry_dialog = nil end
                        UIManager:close(dialog)
                        self:_begin()
                    end,
                },
                {
                    text = _("取消"),
                    callback = function()
                        if self.retry_dialog == dialog then self.retry_dialog = nil end
                        UIManager:close(dialog)
                        self:cancel()
                    end,
                },
            },
        },
    }
    self.retry_dialog = dialog
    UIManager:show(dialog)
end

return QRLogin
