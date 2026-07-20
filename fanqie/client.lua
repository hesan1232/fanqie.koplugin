local ltn12 = require("ltn12")
local Cookie = require("fanqie.cookie")
local FanQie = require("fanqie.fanqie")
local H = require("fanqie.helper")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
local NODE_CACHE_TTL = 5 * 60 -- 5 minutes
local SHELF_CACHE_TTL = 10 * 60 -- 10 minutes for shelf cache
local unpack_args = unpack or table.unpack

local Client = {}
Client.__index = Client

local NODE_CACHE = {}
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
    text = text or ""
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
    local results = { pcall(transport.request, request) }
    transport.TIMEOUT = previous_timeout
    if not results[1] then
        error(results[2])
    end
    table.remove(results, 1)
    return unpack_args(results)
end

function Client:new(settings)
    local obj = setmetatable({
        settings = settings,
    }, self)
    -- Use module-level NODE_CACHE so endpoint availability persists
    -- across FileManager and ReaderUI plugin instances
    obj.node_cache = NODE_CACHE
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

    local _, code, resp_headers, status = transport_request(transport, {
        url = opts.url,
        method = opts.method or (body and "POST" or "GET"),
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response),
    }, opts.timeout)

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

function Client:mark_node_failed(endpoint)
    self.node_cache[endpoint] = { available = false, last_check = os.time() }
end

function Client:mark_node_success(endpoint)
    self.node_cache[endpoint] = { available = true, last_check = os.time() }
end

function Client:get_available_endpoints()
    local endpoints = self.settings:get_fanqie_api_endpoints()
    local now = os.time()
    local available = {}
    for i, e in ipairs(endpoints) do
        local cached = self.node_cache[e]
        if cached and not cached.available and (now - cached.last_check) < NODE_CACHE_TTL then
            goto continue
        end
        table.insert(available, e)
        ::continue::
    end
    return available
end

function Client:has_third_party_endpoints()
    return #self:get_available_endpoints() > 0
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

function Client:third_party_request(endpoint, path, opts)
    opts = opts or {}
    local base = FanQie.normalize_base(endpoint)
    local url = base .. path

    local headers = {
        ["User-Agent"] = FanQie.USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
    }
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    if opts.method and opts.method:upper() ~= "GET" then
        headers["Content-Type"] = "application/json"
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = opts.method or "GET",
        headers = headers,
        body = opts.body,
    })

    if code and code >= 200 and code < 300 then
        return self:json_decode(text)
    end
    local err_msg = http_error(self, code, text, resp_headers)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
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
    local err_msg = http_error(self, code, text, resp_headers)
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
    local err_msg = http_error(self, code, text, resp_headers)
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
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
        ["Cookie"] = Cookie.to_header(cookies),
    }
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
    
    local shelf_info = self:fetch_shelf_info()
    if not shelf_info or not shelf_info.data then
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
    local official_err
    local ok, result = pcall(function()
        return self:get_json(FanQie.directory_url(book_id))
    end)
    
    local has_valid_data = false
    if result and result.data then
        if type(result.data.chapterListWithVolume) == "table" and #result.data.chapterListWithVolume > 0 then
            has_valid_data = true
        elseif type(result.data.chapterList) == "table" and #result.data.chapterList > 0 then
            has_valid_data = true
        elseif type(result.data.allItemIds) == "table" and #result.data.allItemIds > 0 then
            has_valid_data = true
        end
    end
    
    if ok and (result and result.code == 0 and result.data or has_valid_data) then
        return result
    end
    if not ok then
        official_err = result
    else
        official_err = "official API code=" .. tostring(result and result.code)
            .. " message=" .. tostring(result and result.message or "")
    end

    -- Fallback to third-party endpoints
    local endpoints = self:get_available_endpoints()
    for i, endpoint in ipairs(endpoints) do
        local ok_tp, tp_result = pcall(function()
            return self:fetch_chapter_directory_third_party(endpoint, book_id)
        end)
        if ok_tp and tp_result then
            self:mark_node_success(endpoint)
            return tp_result
        else
            self:mark_node_failed(endpoint)
        end
    end

    -- Re-throw official API error if all third-party failed
    error(official_err or "Failed to fetch chapter directory from all sources")
end

function Client:fetch_chapter_directory_third_party(endpoint, book_id)
    local base = FanQie.normalize_base(endpoint)
    -- Try unified API format first: /api/book?book_id=xxx
    local ok, result = pcall(function()
        return self:third_party_request(endpoint, "/api/book?book_id=" .. H.url_encode(book_id))
    end)
    if ok and result and result.code == 200 and result.data and result.data.code == 0 and result.data.data then
        return result.data
    end
    -- Fallback to legacy format: /api/reader/directory/detail?bookId=xxx
    ok, result = pcall(function()
        return self:third_party_request(endpoint, "/api/reader/directory/detail?bookId=" .. H.url_encode(book_id))
    end)
    if ok and result and result.code == 0 and result.data then
        return result
    end
    error("Third-party directory API returned invalid data")
end

function Client:fetch_batch_full_content_from_endpoint(endpoint, item_ids, book_id)
    local item_id_str = type(item_ids) == "table" and table.concat(item_ids, ",") or tostring(item_ids)

    -- Try unified API format first: /api/content?tab=批量&item_ids=xxx
    local ok, result = pcall(function()
        local params = "tab=" .. H.url_encode("批量") ..
            "&item_ids=" .. H.url_encode(item_id_str) ..
            (book_id and "&book_id=" .. H.url_encode(book_id) or "")
        return self:third_party_request(endpoint, "/api/content?" .. params)
    end)
    if ok and result and result.code == 200 and result.data and result.data.chapters then
        local data = {}
        local item_id_array = {}
        for id in item_id_str:gmatch("[^,]+") do
            table.insert(item_id_array, id)
        end
        for idx, ch in ipairs(result.data.chapters) do
            local key = ch.item_id or ch.id or item_id_array[idx] or "chapter_" .. idx
            if key and ch and ch.content then
                data[key] = {
                    content = ch.content or "",
                    title = ch.title or "",
                    item_id = key,
                }
            end
        end
        local has_content = false
        for _, value in pairs(data) do
            if value and value.content and H.trim(value.content):len() > 0 then
                has_content = true
                break
            end
        end
        if has_content then
            return { code = 0, data = data }
        end
    end

    -- Fallback to legacy format: /reading/reader/batch_full/v?item_ids=xxx
    ok, result = pcall(function()
        local params = "item_ids=" .. H.url_encode(item_id_str) ..
            "&aid=1967&device_platform=android&iid=0&update_version_code=0&key_register_ts=0&epub=0"
        return self:third_party_request(endpoint, "/reading/reader/batch_full/v?" .. params)
    end)
    if ok and result and result.code == 0 and result.data then
        local has_content = false
        for _, value in pairs(result.data) do
            if value and value.content and H.trim(value.content):len() > 0 then
                has_content = true
                break
            end
        end
        if has_content then
            return result
        end
    end

    error("Endpoint returned empty content")
end

function Client:fetch_chapter_content_via_proxy(item_id)
    local proxy_base = self.settings:get("fanqie_proxy_base", "")
    if proxy_base == "" then
        error("No proxy base configured")
    end
    local url = FanQie.normalize_base(proxy_base) .. "/api/fanqie-content/" .. H.url_encode(item_id)
    return self:get_json(url)
end

function Client:fetch_chapter_content_via_reader(item_id)
    local proxy_base = self.settings:get("fanqie_proxy_base", "")
    if proxy_base == "" then
        error("No proxy base configured for reader page")
    end
    local url = FanQie.normalize_base(proxy_base) .. "/api/fanqie-reader/" .. H.url_encode(item_id)
    return self:get_text(url)
end

function Client:get_chapter_content_with_fallback(book_id, item_id)
    local content, title

    -- Try each endpoint once with both raw_full and batch formats
    local endpoints = self:get_available_endpoints()
    if endpoints and #endpoints > 0 then
        for _, endpoint in ipairs(endpoints) do
            -- Try raw_full format
            local ok, raw_data = pcall(function()
                local url = FanQie.derive_raw_full_url(endpoint, tostring(item_id))
                local result = self:get_json(url)
                if result and result.code == 200 and result.data and result.data.content then
                    if H.trim(result.data.content):len() > 0 then
                        self:mark_node_success(endpoint)
                        local t = result.data.title or ""
                        if t == "" and result.data.novel_data and result.data.novel_data.book_name then
                            t = result.data.novel_data.book_name
                        end
                        local author = ""
                        if result.data.novel_data and result.data.novel_data.author then
                            author = result.data.novel_data.author
                        end
                        return { content = result.data.content, title = t, author = author }
                    end
                end
                -- Try legacy /api/content format on same endpoint
                local base = FanQie.normalize_base(endpoint)
                result = self:get_json(base .. "/api/content?item_id=" .. H.url_encode(tostring(item_id)))
                if result and result.code == 200 and result.data and result.data.content then
                    if H.trim(result.data.content):len() > 0 then
                        self:mark_node_success(endpoint)
                        return { content = result.data.content, title = result.data.title or "" }
                    end
                end
                error("empty content from " .. endpoint)
            end)
            if ok and raw_data and raw_data.content then
                return { content = raw_data.content, title = raw_data.title or "" }
            end

            -- Try batch format on same endpoint
            ok, raw_data = pcall(function()
                local result = self:fetch_batch_full_content_from_endpoint(endpoint, { tostring(item_id) }, book_id)
                if result and result.code == 0 and result.data then
                    local ch = result.data[tostring(item_id)]
                    if ch and ch.content and H.trim(ch.content):len() > 0 then
                        self:mark_node_success(endpoint)
                        return { content = ch.content, title = ch.title or "" }
                    end
                end
                error("empty batch content from " .. endpoint)
            end)
            if ok and raw_data and raw_data.content then
                return { content = raw_data.content, title = raw_data.title or "" }
            end

            self:mark_node_failed(endpoint)
        end
    end

    -- Fallback: proxy (only if fanqie_proxy_base is configured)
    local proxy_base = self.settings:get("fanqie_proxy_base", "")
    if proxy_base ~= "" then
        local ok, proxy_data = pcall(function()
            return self:fetch_chapter_content_via_proxy(item_id)
        end)
        if ok and proxy_data and proxy_data.content then
            content = proxy_data.content
            title = proxy_data.title or ""
            return { content = content, title = title }
        end

        -- Fallback: reader page (uses same proxy_base)
        local reader_ok, reader_html = pcall(function()
            return self:fetch_chapter_content_via_reader(item_id)
        end)
        if reader_ok and reader_html then
            local data = self:parse_reader_page(reader_html)
            if data then
                local result = self:extract_chapter_content_from_reader(data)
                if result then
                    return { content = result.content, title = result.title or "" }
                end
            end
        end
    end

    error("All content fetch methods failed")
end

function Client:parse_reader_page(html)
    if not html then return nil end

    local next_data_match = html:match('<script%s+id=["\']__NEXT_DATA__["\']%s*>([%s%S]-)</script>')
    if next_data_match then
        local ok, data = pcall(function()
            return self:json_decode(next_data_match)
        end)
        if ok then
            return data
        end
    end

    local initial_state_match = html:match('window.__INITIAL_STATE__%s*=%s*([%s%S]-);')
    if initial_state_match then
        local sanitized = initial_state_match:gsub("undefined", "null")
        local ok, data = pcall(function()
            return self:json_decode(sanitized)
        end)
        if ok then
            return data
        end
    end

    local content_str_match = html:match('"content"%s*:%s*"([^"]+)"')
    if content_str_match and #content_str_match > 100 then
        return { content = content_str_match }
    end

    return nil
end

function Client:extract_chapter_content_from_reader(data)
    if not data then return nil end

    local paths = {
        { "reader", "chapterData", "content" },
        { "reader", "chapter", "content" },
        { "reader", "content" },
        { "props", "pageProps", "initialState", "reader", "chapterData", "content" },
        { "props", "pageProps", "initialState", "reader", "content" },
        { "props", "pageProps", "reader", "content" },
        { "props", "pageProps", "initialState", "reader", "chapter", "content" },
        { "props", "pageProps", "chapter", "content" },
        { "chapter", "content" },
        { "content" },
    }

    for i, path in ipairs(paths) do
        local current = data
        local valid = true
        for j, key in ipairs(path) do
            if current and type(current) == "table" and current[key] ~= nil then
                current = current[key]
            else
                valid = false
                break
            end
        end
        if valid and current and H.is_str(current) and H.trim(current):len() > 0 then
            local title = ""
            if data.reader and data.reader.chapterData and data.reader.chapterData.title then
                title = data.reader.chapterData.title
            elseif data.reader and data.reader.chapter and data.reader.chapter.title then
                title = data.reader.chapter.title
            elseif data.chapterData and data.chapterData.title then
                title = data.chapterData.title
            end
            return { content = current, title = title }
        end
    end

    return nil
end

return Client