local H = require("lib.helper")

local FanQie = {}

FanQie.USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
FanQie.BASE_URL = "https://fanqienovel.com"
FanQie.THIRD_PARTY_ENDPOINT = "http://101.35.133.34:5000"

function FanQie.normalize_base(base)
    local b = H.trim(base)
    if not b:match("^http") then
        b = "https://" .. b
    end
    if b:sub(-1) == "/" then
        b = b:sub(1, -2)
    end
    return b
end

function FanQie.ensure_trailing_query_base(base)
    if base:find("?", 1, true) then
        return base
    end
    return base .. "?"
end

-- is_unified_api removed: endpoints are now probed dynamically by trying
-- unified format first, then legacy format. See client.lua.

-- derive_batch_full_base and derive_directory_base removed:
-- client.lua now constructs URLs directly and tries both formats sequentially.

function FanQie.derive_raw_full_url(endpoint, item_id)
    local base = FanQie.normalize_base(endpoint)
    return base .. "/api/raw_full?item_id=" .. H.url_encode(item_id)
end

function FanQie.make_shelf_params()
    return {
        aid = 1967,
        iid = 0,
        version_code = 57700,
        update_version_code = 57700,
    }
end

function FanQie.make_batch_full_params(item_ids)
    return {
        item_ids = item_ids,
        aid = 1967,
        device_platform = "android",
        iid = 0,
        update_version_code = 0,
        key_register_ts = 0,
        epub = 0,
    }
end

function FanQie.shelf_url()
    return FanQie.BASE_URL .. "/reading/bookapi/bookshelf/info/v:version/"
end

function FanQie.bookshelf_multidetail_url()
    return FanQie.BASE_URL .. "/api/bookshelf/multidetail"
end

function FanQie.progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/progress"
end

function FanQie.update_progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/update_progress"
end

function FanQie.directory_url(book_id)
    return FanQie.BASE_URL .. "/api/reader/directory/detail?bookId=" .. H.url_encode(book_id)
end

function FanQie.content_batch_url()
    return FanQie.BASE_URL .. "/api/reader/content/batch"
end

function FanQie.batch_full_url(item_ids)
    local params = FanQie.make_batch_full_params(item_ids)
    local parts = {}
    for key, value in pairs(params) do
        local encoded_value
        if type(value) == "table" then
            encoded_value = H.url_encode(table.concat(value, ","))
        else
            encoded_value = H.url_encode(value)
        end
        table.insert(parts, key .. "=" .. encoded_value)
    end
    return FanQie.BASE_URL .. "/reading/reader/batch_full/v?" .. table.concat(parts, "&")
end

function FanQie.chapter_content_url(book_id, item_id)
    return FanQie.BASE_URL .. "/api/reader/chapter/content?book_id=" .. H.url_encode(book_id) .. "&item_id=" .. H.url_encode(item_id)
end

function FanQie.reader_url(item_id)
    return "https://fanqienovel.com/reader/" .. item_id
end

function FanQie.is_valid_book_id(book_id)
    return book_id and tostring(book_id) ~= ""
end

function FanQie.normalize_book_id(book_id)
    return tostring(book_id or "")
end

return FanQie