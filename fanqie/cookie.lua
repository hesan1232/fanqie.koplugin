local Cookie = {}

function Cookie.parse_cookie_header(header)
    local cookies = {}
    if not header or header == "" then
        return cookies
    end
    header = header:gsub("^%s*[Cc]ookie:%s*", "")
    for part in header:gmatch("([^;]+)") do
        local key, value = part:match("^%s*([^=]+)=(.-)%s*$")
        if key and value then
            cookies[key] = value
        end
    end
    return cookies
end

function Cookie.extract_from_curl(curl)
    if not curl or curl == "" then
        return "", nil
    end

    local cookie = curl:match("%-H%s+['\"][Cc]ookie:%s*(.-)['\"]")
        or curl:match("%-b%s+['\"](.-)['\"]")
        or curl:match("%-%-cookie%s+['\"](.-)['\"]")
    local data = curl:match("%-%-data%-raw%s+['\"](.-)['\"]")
        or curl:match("%-%-data%s+['\"](.-)['\"]")
        or curl:match("%-d%s+['\"](.-)['\"]")

    return cookie or curl, data
end

function Cookie.to_header(cookies)
    local parts = {}
    for key, value in pairs(cookies or {}) do
        table.insert(parts, key .. "=" .. value)
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

-- Set-Cookie 标准属性（小写匹配），这些不应该作为 cookie 名持久化。
-- 避免像 Path=/、Domain=xxx、Expires=Mon 等属性被误存导致后续 Cookie header 被
-- 带上奇怪字段；同时 Expires 值里带逗号（Mon, 01 Jan ...）会被旧正则切断产生
-- 错误的键，必须用"按 \r\n 切分多条，每条取第一个非属性 key=value"的策略。
local SET_COOKIE_ATTRS = {
    ["path"] = true, ["domain"] = true, ["expires"] = true, ["max-age"] = true,
    ["secure"] = true, ["httponly"] = true, ["samesite"] = true,
    ["priority"] = true, ["partitioned"] = true, ["comment"] = true,
    ["version"] = true, ["discard"] = true,
}

function Cookie.merge_set_cookie(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then
        return cookies
    end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            Cookie.merge_set_cookie(cookies, value)
        end
        return cookies
    end
    local sc = tostring(set_cookie)
    -- LuaSocket 会把多个 Set-Cookie 响应头用 ", " 合并成一个字符串
    -- （HTTP/1.1 允许同名头用逗号合并，但 Set-Cookie 是例外，不应合并）。
    -- 但 Set-Cookie 的 Expires 属性值里合法含有逗号（"Mon, 01 Jan 2026 ..."），
    -- 不能直接按逗号切分。策略：
    -- 1. 先把 "Expires=值," 中的逗号用占位符保护（值里不含 ; 和 ,，到第一个逗号止）
    -- 2. 按换行或逗号切分成多条
    -- 3. 每条取第一个非属性的 name=value 作为 cookie
    -- 4. 还原占位符
    local PLACEHOLDER = "\x01"
    sc = sc:gsub("([Ee][Xx][Pp][Ii][Rr][Ee][Ss]=[^,;]-)%,", "%1" .. PLACEHOLDER)
    for seg in sc:gmatch("[^,\r\n]+") do
        seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
        seg = seg:gsub(PLACEHOLDER, ",")
        if seg ~= "" then
            -- 每条 Set-Cookie 的第一个 key=value 是 cookie 名值对，
            -- 其后用 ; 分隔的都是属性（Path/Domain/Expires 等）。
            local cookie_name, cookie_value = seg:match("^([^=%s;]+)=([^;]*)")
            if cookie_name and cookie_value then
                local name_lower = cookie_name:lower()
                if not SET_COOKIE_ATTRS[name_lower] then
                    cookies[cookie_name] = cookie_value
                end
            end
        end
    end
    return cookies
end

function Cookie.has_login_cookie(cookies)
    if not cookies then return false end
    for key in pairs(cookies) do
        if cookies[key] and #tostring(cookies[key]) >= 8 then
            return true
        end
    end
    return false
end

return Cookie