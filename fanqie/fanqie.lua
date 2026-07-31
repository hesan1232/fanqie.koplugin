local H = require("fanqie.helper")

local FanQie = {}

FanQie.USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
FanQie.MOBILE_UA = "Mozilla/5.0 (Linux; Android 10; Pixel 3) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
FanQie.BASE_URL = "https://fanqienovel.com"
FanQie.QINGTIAN_DEFAULT_URL = "https://v1.gyks.cf/"

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

function FanQie.qt_login_url(server_url)
    return FanQie.normalize_base(server_url) .. "/login_api"
end

function FanQie.qt_content_url(server_url)
    return FanQie.normalize_base(server_url) .. "/content"
end

function FanQie.make_shelf_params()
    return {
        aid = 1967,
        iid = 0,
        version_code = 57700,
        update_version_code = 57700,
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