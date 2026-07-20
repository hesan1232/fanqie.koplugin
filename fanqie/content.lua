local function rshift(n, k)
    return math.floor(n / (2 ^ k))
end

local FanQie = require("fanqie.fanqie")

local ok_logger, logger = pcall(require, "logger")
if not ok_logger then
    logger = nil
end
local LOG_MODULE = "[FanQie]"

local H = require("fanqie.helper")

local Content = {}

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64_encode(data)
    local len = #data
    local out_len = math.floor((len + 2) / 3) * 4
    local out = {}
    out[out_len] = ""
    local idx = 1
    for i = 1, len, 3 do
        local a = data:byte(i)
        local b = i + 1 <= len and data:byte(i + 1) or 0
        local c = i + 2 <= len and data:byte(i + 2) or 0
        local n = a * 65536 + b * 256 + c
        out[idx] = b64chars:sub(rshift(n, 18) % 64 + 1, rshift(n, 18) % 64 + 1)
        out[idx + 1] = b64chars:sub(rshift(n, 12) % 64 + 1, rshift(n, 12) % 64 + 1)
        if i + 1 <= len then
            out[idx + 2] = b64chars:sub(rshift(n, 6) % 64 + 1, rshift(n, 6) % 64 + 1)
        else
            out[idx + 2] = "="
        end
        if i + 2 <= len then
            out[idx + 3] = b64chars:sub(n % 64 + 1, n % 64 + 1)
        else
            out[idx + 3] = "="
        end
        idx = idx + 4
    end
    return table.concat(out)
end

local function basename_safe(value)
    value = tostring(value or ""):gsub("[^%w%._-]", "_")
    if value == "" then
        value = "fanqie"
    end
    return value
end



function Content.book_cache_dir(settings, book_id)
    return settings.cache_dir .. "/" .. basename_safe(book_id)
end

-- Cache index: persists item_id → file path mapping across restarts
function Content.save_cache_index(settings, book_id, cached_chapters)
    local dir = Content.book_cache_dir(settings, book_id)
    H.make_dir(dir)
    local index_path = H.join_path(dir, "cache_index.lua")
    local parts = { "return {" }
    for item_id, path in pairs(cached_chapters or {}) do
        if H.is_str(item_id) then
            table.insert(parts, string.format("  [%q] = %q,", item_id, path))
        end
    end
    table.insert(parts, "}")
    H.write_file(index_path, table.concat(parts, "\n"))
end

function Content.load_cache_index(settings, book_id)
    local ok_state, _state = pcall(require, "lib.state")
    if ok_state and _state then
        local cached = _state.getChapterIndexCache(book_id)
        if cached then
            return cached
        end
    end

    local dir = Content.book_cache_dir(settings, book_id)
    local index_path = H.join_path(dir, "cache_index.lua")
    if not H.file_exists(index_path) then
        return {}
    end

    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(index_path)
    if attr then
        local now = os.time()
        local mtime = attr.modification
        if mtime and (now - mtime) > 86400 then
            return {}
        end
    end

    local ok, index = pcall(dofile, index_path)
    if not ok or not H.is_tbl(index) then
        return {}
    end

    if ok_state and _state then
        _state.setChapterIndexCache(book_id, index)
    end

    return index
end

function Content.verify_cache_path(path)
    if not path then return false end
    return H.file_exists(path)
end

function Content.book_resolved_dir(settings, book_id, book)
    if book and H.is_str(book.cache_dir) and book.cache_dir ~= "" then
        return book.cache_dir
    end
    local function dirname(path)
        if H.is_str(path) then
            return path:match("^(.*)/[^/]+$")
        end
    end
    local dir = book and dirname(book.cached_file)
    if not dir and book and H.is_tbl(book.cached_chapters) then
        for _i, chapter_path in pairs(book.cached_chapters) do
            dir = dirname(chapter_path)
            if dir then
                break
            end
        end
    end
    return dir or Content.book_cache_dir(settings, book_id)
end

local function filename_safe(value)
    value = tostring(value or ""):gsub("[%z%c/\\:%*%?\"<>|]", "_")
    value = H.trim(value)
    value = value:gsub("%s+", " ")
    if value == "" then
        value = "fanqie"
    end
    return value
end

local function utc_modified()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function media_type_for(data)
    if data:sub(1, 8) == "\137PNG\r\n\026\n" then
        return ".png", "image/png"
    elseif data:sub(1, 3) == "\255\216\255" then
        return ".jpg", "image/jpeg"
    elseif data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return ".gif", "image/gif"
    elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return ".webp", "image/webp"
    end
    return ".bin", "application/octet-stream"
end

-- Public wrapper: returns (ext, media_type) only for valid image data, else nil
function Content.detect_image_type(data)
    if type(data) ~= "string" or #data < 12 then return nil end
    local ext, mt = media_type_for(data)
    if mt and mt:match("^image/") then
        return ext, mt
    end
    return nil
end

local function xml_escape(value)
    value = tostring(value or "")
    value = value:gsub("&", "&amp;")
    value = value:gsub("<", "&lt;")
    value = value:gsub(">", "&gt;")
    value = value:gsub("\"", "&quot;")
    return value
end

local function body_fragment(xhtml)
    xhtml = tostring(xhtml or "")
    local body = xhtml:match("<body[^>]->([^<]-)</body>")
        or xhtml:match("<body[^>]->(.*)")
    if body then
        return body
    end
    xhtml = xhtml:gsub("<%?xml.-%?>", "")
    xhtml = xhtml:gsub("<!DOCTYPE.-%>", "")
    return xhtml
end

local PUA_CODE = { { 58344, 58715 }, { 58345, 58716 } }
local PUA_CHARSET = {
    { "D","在","主","特","家","军","然","表","场","4","要","只","v","和","?","6","别","还","g","现","儿","岁","?","?","此","象","月","3","出","战","工","相","o","男","直","失","世","F","都","平","文","什","V","O","将","真","T","那","当","?","会","立","些","u","是","十","张","学","气","大","爱","两","命","全","后","东","性","通","被","1","它","乐","接","而","感","车","山","公","了","常","以","何","可","话","先","p","i","叫","轻","M","士","w","着","变","尔","快","l","个","说","少","色","里","安","花","远","7","难","师","放","t","报","认","面","道","S","?","克","地","度","I","好","机","U","民","写","把","万","同","水","新","没","书","电","吃","像","斯","5","为","y","白","几","日","教","看","但","第","加","候","作","上","拉","住","有","法","r","事","应","位","利","你","声","身","国","问","马","女","他","Y","比","父","x","A","H","N","s","X","边","美","对","所","金","活","回","意","到","z","从","j","知","又","内","因","点","Q","三","定","8","R","b","正","或","夫","向","德","听","更","?","得","告","并","本","q","过","记","L","让","打","f","人","就","者","去","原","满","体","做","经","K","走","如","孩","c","G","给","使","物","?","最","笑","部","?","员","等","受","k","行","一","条","果","动","光","门","头","见","往","自","解","成","处","天","能","于","名","其","发","总","母","的","死","手","入","路","进","心","来","h","时","力","多","开","已","许","d","至","由","很","界","n","小","与","Z","想","代","么","分","生","口","再","妈","望","次","西","风","种","带","J","?","实","情","才","这","?","E","我","神","格","长","觉","间","年","眼","无","不","亲","关","结","0","友","信","下","却","重","己","老","2","音","字","m","呢","明","之","前","高","P","B","目","太","e","9","起","稜","她","也","W","用","方","子","英","每","理","便","四","数","期","中","C","外","样","a","海","们","任" },
    { "s","?","作","口","在","他","能","并","B","士","4","U","克","才","正","们","字","声","高","全","尔","活","者","动","其","主","报","多","望","放","h","w","次","年","?","中","3","特","于","十","入","要","男","同","G","面","分","方","K","什","再","教","本","己","结","1","等","世","N","?","说","g","u","期","Z","外","美","M","行","给","9","文","将","两","许","张","友","0","英","应","向","像","此","白","安","少","何","打","气","常","定","间","花","见","孩","它","直","风","数","使","道","第","水","已","女","山","解","d","P","的","通","关","性","叫","儿","L","妈","问","回","神","来","S","","四","望","前","国","些","O","v","l","A","心","平","自","无","军","光","代","是","好","却","c","得","种","就","意","先","立","z","子","过","Y","j","表","","么","所","接","了","名","金","受","J","满","眼","没","部","那","m","每","车","度","可","R","斯","经","现","门","明","V","如","走","命","y","6","E","战","很","上","f","月","西","7","长","夫","想","话","变","海","机","x","到","W","一","成","生","信","笑","但","父","开","内","东","马","日","小","而","后","带","以","三","几","为","认","X","死","员","目","位","之","学","远","人","音","呢","我","q","乐","象","重","对","个","被","别","F","也","书","稜","D","写","还","因","家","发","时","i","或","住","德","当","o","l","比","觉","然","吃","去","公","a","老","亲","情","体","太","b","万","C","电","理","?","失","力","更","拉","物","着","原","她","工","实","色","感","记","看","出","相","路","大","你","候","2","和","?","与","p","样","新","只","便","最","不","进","T","r","做","格","母","总","爱","身","师","轻","知","往","加","从","?","天","e","H","?","听","场","由","快","边","让","把","任","8","条","头","事","至","起","点","真","手","这","难","都","界","用","法","n","处","下","又","Q","告","地","5","k","t","岁","有","会","果","利","民" }
}

local function utf8_codepoint(str, i)
    local b1 = str:byte(i)
    if not b1 then return nil, i end
    if b1 < 0x80 then
        return b1, i + 1
    elseif b1 >= 0xC2 and b1 <= 0xDF then
        local b2 = str:byte(i + 1)
        if not b2 then return nil, i end
        return (b1 - 0xC0) * 0x40 + (b2 - 0x80), i + 2
    elseif b1 >= 0xE0 and b1 <= 0xEF then
        local b2 = str:byte(i + 1)
        local b3 = str:byte(i + 2)
        if not b2 or not b3 then return nil, i end
        return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80), i + 3
    elseif b1 >= 0xF0 and b1 <= 0xF4 then
        local b2 = str:byte(i + 1)
        local b3 = str:byte(i + 2)
        local b4 = str:byte(i + 3)
        if not b2 or not b3 or not b4 then return nil, i end
        return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80), i + 4
    end
    return nil, i
end

function Content.decode_pua_content(content)
    if not content then return "" end
    local result = {}
    local i = 1
    while i <= #content do
        local code, next_i = utf8_codepoint(content, i)
        if not code then
            table.insert(result, content:sub(i, i))
            i = i + 1
            goto continue
        end
        local decoded = false
        for mode = 1, 2 do
            local range = PUA_CODE[mode]
            if code >= range[1] and code <= range[2] then
                local bias = code - range[1]
                local charset = PUA_CHARSET[mode]
                if bias + 1 <= #charset and charset[bias + 1] ~= "?" then
                    table.insert(result, charset[bias + 1])
                    decoded = true
                end
                break
            end
        end
        if not decoded then
            table.insert(result, content:sub(i, next_i - 1))
        end
        i = next_i
        ::continue::
    end
    return table.concat(result)
end

function Content.strip_html(html)
    if not html then return "" end
    html = html:gsub("<br%s*/?>", "\n"):gsub("</p%s*>", "\n")
    html = html:gsub("</div%s*>", "\n"):gsub("</h[1-6]%s*>", "\n")
    html = html:gsub("<[^>]+>", ""):gsub("&nbsp;", " ")
    html = html:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    html = html:gsub("&quot;", "\""):gsub("&#39;", "'")
    html = html:gsub("&ldquo;", "\u{201C}"):gsub("&rdquo;", "\u{201D}")
    html = html:gsub("&hellip;", "\u{2026}"):gsub("&mdash;", "\u{2014}"):gsub("&ndash;", "\u{2013}")
    return html
end

local function utf8_char(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
    elseif code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + (math.floor(code / 0x40) % 0x40), 0x80 + (code % 0x40))
    elseif code < 0x110000 then
        return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + (math.floor(code / 0x1000) % 0x40), 0x80 + (math.floor(code / 0x40) % 0x40), 0x80 + (code % 0x40))
    end
    return ""
end

function Content.decode_html_entities(text)
    if not text then return "" end
    text = text:gsub("&nbsp;", " "):gsub("&amp;", "&")
    text = text:gsub("&lt;", "<"):gsub("&gt;", ">")
    text = text:gsub("&quot;", "\""):gsub("&#39;", "'")
    text = text:gsub("&ldquo;", "\u{201C}"):gsub("&rdquo;", "\u{201D}")
    text = text:gsub("&lsquo;", "\u{2018}"):gsub("&rsquo;", "\u{2019}")
    text = text:gsub("&hellip;", "\u{2026}"):gsub("&mdash;", "\u{2014}"):gsub("&ndash;", "\u{2013}")
    text = text:gsub("&#(%d+);", function(code)
        return utf8_char(tonumber(code, 10))
    end)
    text = text:gsub("&#x([0-9a-fA-F]+);", function(code)
        return utf8_char(tonumber(code, 16))
    end)
    return text
end

function Content.clean_chapter_content(raw_content, title)
    if not raw_content then return "" end

    local content = raw_content

    content = content:gsub("<header[^>]->[%s%S]-</header>", "")
    content = content:gsub("<script[^>]->[%s%S]-</script>", "")
    content = content:gsub("<style[^>]->[%s%S]-</style>", "")
    content = content:gsub("<!--[%s%S]--->", "")

    local body_match = content:match("<body[^>]->([%s%S]-)</body>")
    if body_match then
        content = body_match
    end

    local paragraphs = {}
    local para_regex = "<p[^>]->([%s%S]-)</p>"
    local pos = 1
    while true do
        local start_pos, end_pos, inner = content:find(para_regex, pos)
        if not start_pos then break end
        inner = inner:gsub("<br%s*/?>", "\n"):gsub("<[^>]+>", "")
        inner = Content.decode_html_entities(inner)
        local trimmed = H.trim(inner)
        if trimmed ~= "" then
            table.insert(paragraphs, "<p>" .. xml_escape(trimmed) .. "</p>")
        end
        pos = end_pos + 1
    end

    if #paragraphs == 0 then
        local plain = content:gsub("<[^>]+>", "")
        plain = Content.decode_html_entities(plain)
        local lines = {}
        for line in plain:gmatch("[^\n]+") do
            line = H.trim(line)
            if line ~= "" then
                table.insert(lines, "<p>" .. xml_escape(line) .. "</p>")
            end
        end
        paragraphs = lines
    end

    return table.concat(paragraphs, "\n")
end

function Content.txt_to_xhtml(text)
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local parts = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^(.-)%s*$") or ""
        if line ~= "" then
            table.insert(parts, "<p>" .. xml_escape(line) .. "</p>")
        end
    end
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head><title></title></head>\n'
        .. '<body>\n' .. table.concat(parts, "\n") .. '\n</body></html>'
end

function Content.normalize_chapters(payload, book_id)
    local records = payload
    if type(payload) == "table" and payload.data then
        records = payload.data
    end
    if type(records) ~= "table" then
        return {}
    end
    -- Official API returns chapterListWithVolume as a 2D array:
    -- [[chapter1, chapter2, ...], [chapter101, ...]]
    -- Each volume is directly an array of chapters, not an object with chapterList property
    if type(records.chapterListWithVolume) == "table" then
        local flattened = {}
        for _, volume in ipairs(records.chapterListWithVolume) do
            if type(volume) == "table" then
                for _, ch in ipairs(volume) do
                    if type(ch) == "table" and ch.itemId then
                        table.insert(flattened, ch)
                    end
                end
            end
        end
        if #flattened > 0 then
            return flattened
        end
    end
    -- Direct chapter list fields (official + third-party variants)
    if type(records.chapterList) == "table" then
        return records.chapterList
    end
    -- Try extracting chapters from allItemIds if chapterListWithVolume/chapterList is empty
    if type(records.allItemIds) == "table" and #records.allItemIds > 0 then
        local chapters = {}
        for i, item_id in ipairs(records.allItemIds) do
            table.insert(chapters, {
                itemId = item_id,
                title = "第" .. tostring(i) .. "章",
                index = i - 1,
            })
        end
        return chapters
    end
    if records.bookId or records.updated then
        records = { records }
    end
    for record_index, record in ipairs(records) do
        if tostring(record.bookId or "") == tostring(book_id) then
            return record.updated or record.chapterInfos or record.chapters
                or record.item_list or record.list or record.chapterList or {}
        end
    end
    return records
end

function Content.first_readable_chapter(chapters)
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tostring(chapter.title or "") ~= "封面" then
            return chapter
        end
    end
end

function Content.readable_chapters(chapters)
    local out = {}
    for chapter_index, chapter in ipairs(chapters or {}) do
        if tostring(chapter.title or "") ~= "封面" then
            table.insert(out, chapter)
        end
    end
    return out
end

function Content.download_remote_images(client, xhtml, used_names, progress)
    local assets = {}
    used_names = used_names or {}
    used_names.__remote_image_hrefs = used_names.__remote_image_hrefs or {}
    local remote_image_hrefs = used_names.__remote_image_hrefs
    local function remote_url(src)
        local url = tostring(src or "")
        if url:match("^//") then
            url = "https:" .. url
        end
        if url:match("^https?://") then
            return url
        end
    end
    local img_total = 0
    xhtml:gsub('src=(["\'])(.-)%1', function(_, src)
        if remote_url(src) then
            img_total = img_total + 1
        end
    end)
    if img_total == 0 then
        return xhtml, assets
    end
    local index = 0
    local body = xhtml:gsub('src=(["\'])(.-)%1', function(quote, src)
        local url = remote_url(src)
        if not url then
            return "src=" .. quote .. src .. quote
        end
        index = index + 1
        if progress then
            progress(index, img_total)
        end
        local cached_href = remote_image_hrefs[url]
        if cached_href then
            return "src=" .. quote .. "../" .. cached_href .. quote
        end
        local ok, data = pcall(function()
            return client:get_binary(url, { referer = FanQie.BASE_URL .. "/" })
        end)
        if not ok or not data or #data == 0 then
            return "src=" .. quote .. src .. quote
        end
        local ext, mt = media_type_for(data)
        if not mt:match("^image/") then
            return "src=" .. quote .. src .. quote
        end
        local fname = ext
        local counter = 1
        while used_names[fname] do
            fname = "img" .. tostring(counter) .. ext
            counter = counter + 1
        end
        used_names[fname] = true
        local href = "images/" .. fname
        remote_image_hrefs[url] = href
        table.insert(assets, {
            href = href,
            media_type = mt,
            data = data,
        })
        return "src=" .. quote .. "../" .. href .. quote
    end)
    return body, assets
end

function Content.fetch_catalog(client, book)
    local book_id = book.book_id or book.bookId
    local result = client:fetch_chapter_directory(book_id)
    local chapters = Content.readable_chapters(Content.normalize_chapters(result, book_id))
    book.chapters = chapters
    return chapters
end

function Content.fetch_chapter_content(client, settings, book, chapter)
    local book_id = book.book_id or book.bookId
    local item_id = chapter.itemId or chapter.item_id
    local result = client:get_chapter_content_with_fallback(book_id, item_id)
    local content = result.content or ""
    local title = result.title or chapter.title or ""
    if result.author and result.author ~= "" and (not book.author or book.author == "未知") then
        book.author = result.author
    end

    -- Only decode PUA if content actually contains PUA codepoints
    -- PUA range U+E3F8-U+E55C encodes to UTF-8 starting with 0xEE (238)
    -- Normal Chinese text (U+4E00-U+9FFF) starts with 0xE4-0xE9, never 0xEE
    if content:find("\238", 1, true) then
        content = Content.decode_pua_content(content)
    end

    local cleaned = Content.clean_chapter_content(content, title)
    return '<?xml version="1.0" encoding="utf-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>' .. xml_escape(title) .. '</title></head>\n'
        .. '<body>\n' .. cleaned .. '\n</body></html>'
end

-- ---------------------------------------------------------------------------
-- HTML format (standalone .html files, one per chapter)
-- ---------------------------------------------------------------------------

function Content.save_chapter_html(settings, book, chapter, xhtml, assets, css)
    local book_id = book.book_id or book.bookId
    local dir = Content.book_cache_dir(settings, book_id)
    H.make_dir(dir)
    local item_id = tostring(chapter.itemId)
    local path = dir .. "/" .. "chapter_" .. item_id .. ".html"
    local title = chapter.title or book.title or "FanQie"

    -- inline remote images as base64 data URIs if downloaded
    local body = body_fragment(xhtml)
    if assets and #assets > 0 then
        local href_to_data = {}
        for _, a in ipairs(assets) do
            local ext = a.href:match("%.(.+)$") or ""
            href_to_data[a.href] = "data:" .. a.media_type .. ";base64," .. base64_encode(a.data)
        end
        body = body:gsub('src=(["\'])(.-)%1', function(q, src)
            src = src:gsub("^%.%./", "")
            if href_to_data[src] then
                return 'src=' .. q .. href_to_data[src] .. q
            end
            return 'src=' .. q .. src .. q
        end)
    end

    css = css or [[body { font-size: 1.05em; }]]
    local html = [[<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>]] .. xml_escape(title) .. [[</title>
<style>
]] .. css .. [[
</style>
</head>
<body>
<h1>]] .. xml_escape(title) .. [[</h1>
]] .. body .. [[
</body>
</html>]]
    H.write_file(path, html)
    return path
end

function Content.fetch_chapter_html(client, settings, book, chapter)
    local book_id = book.book_id or book.bookId
    local item_id = tostring(chapter.itemId)
    
    local ok_fetch, xhtml = pcall(Content.fetch_chapter_content, client, settings, book, chapter)
    if not ok_fetch then
        error("fetch_chapter_content failed: " .. tostring(xhtml))
    end
    
    local css = [[body { font-size: 1.05em; }]]
    local assets = {}
    local cache = settings:get("cache", {})
    if cache.download_book_images then
        local used_names = {}
        local ok_img, inline_xhtml, inline_assets = pcall(Content.download_remote_images, client, xhtml, used_names)
        if ok_img then
            xhtml = inline_xhtml
            for _, a in ipairs(inline_assets) do
                table.insert(assets, a)
            end
        end
    end
    local path = Content.save_chapter_html(settings, book, chapter, xhtml, assets, css)
    book.cached_chapters = book.cached_chapters or {}
    book.cached_chapters[item_id] = path
    book.cached_file = path
    book.item_id = chapter.itemId
    book.reader_url = book.reader_url or FanQie.reader_url(chapter.itemId)
    Content.save_cache_index(settings, book_id, book.cached_chapters)
    return path, chapter
end

return Content