local TestUtils = require("tests.test_utils")

local function trim(str)
    if not str then return "" end
    return str:gsub("^%s+", ""):gsub("%s+$", "")
end
string.trim = trim

local FanQie = require("fanqie.fanqie")

local tests = {
    {
        name = "urlencode basic",
        func = function()
            TestUtils.assert_equal("hello%20world", FanQie.urlencode("hello world"))
            TestUtils.assert_equal("test%26test", FanQie.urlencode("test&test"))
            TestUtils.assert_equal("abc123", FanQie.urlencode("abc123"))
        end
    },
    {
        name = "normalize_base with http",
        func = function()
            TestUtils.assert_equal("https://fq.shusan.cn", FanQie.normalize_base("https://fq.shusan.cn"))
            TestUtils.assert_equal("https://fq.shusan.cn", FanQie.normalize_base("https://fq.shusan.cn/"))
        end
    },
    {
        name = "normalize_base without protocol",
        func = function()
            TestUtils.assert_equal("https://fq.shusan.cn", FanQie.normalize_base("fq.shusan.cn"))
            TestUtils.assert_equal("https://fq.shusan.cn", FanQie.normalize_base("fq.shusan.cn/"))
        end
    },

    {
        name = "shelf_url",
        func = function()
            local url = FanQie.shelf_url()
            TestUtils.assert_contains(url, "/reading/bookapi/bookshelf/info/v:version/")
        end
    },
    {
        name = "book_info_url",
        func = function()
            local url = FanQie.book_info_url()
            TestUtils.assert_contains(url, "/api/book/simple/info")
        end
    },
    {
        name = "progress_url",
        func = function()
            local url = FanQie.progress_url()
            TestUtils.assert_contains(url, "/api/reader/book/progress")
        end
    },
    {
        name = "directory_url",
        func = function()
            local url = FanQie.directory_url("12345")
            TestUtils.assert_contains(url, "bookId=12345")
        end
    },
    {
        name = "batch_full_url",
        func = function()
            local url = FanQie.batch_full_url({ "1", "2", "3" })
            TestUtils.assert_contains(url, "/reading/reader/batch_full/v?")
            TestUtils.assert_contains(url, "item_ids=1%2C2%2C3")
        end
    },
    {
        name = "chapter_content_url",
        func = function()
            local url = FanQie.chapter_content_url("book1", "ch1")
            TestUtils.assert_contains(url, "book_id=book1")
            TestUtils.assert_contains(url, "item_id=ch1")
        end
    },
    {
        name = "reader_url",
        func = function()
            local url = FanQie.reader_url("123")
            TestUtils.assert_equal("https://fanqienovel.com/reader/123", url)
        end
    },
    {
        name = "is_valid_book_id valid",
        func = function()
            TestUtils.assert_true(FanQie.is_valid_book_id("123"))
            TestUtils.assert_true(FanQie.is_valid_book_id("abc"))
        end
    },
    {
        name = "is_valid_book_id invalid",
        func = function()
            TestUtils.assert_false(FanQie.is_valid_book_id(nil))
            TestUtils.assert_false(FanQie.is_valid_book_id(""))
        end
    },
    {
        name = "normalize_book_id",
        func = function()
            TestUtils.assert_equal("123", FanQie.normalize_book_id(123))
            TestUtils.assert_equal("abc", FanQie.normalize_book_id("abc"))
            TestUtils.assert_equal("", FanQie.normalize_book_id(nil))
        end
    },
    {
        name = "derive_raw_full_url unified api",
        func = function()
            local url = FanQie.derive_raw_full_url("https://fq.shusan.cn", "7657134435204071960")
            TestUtils.assert_contains(url, "/api/raw_full?")
            TestUtils.assert_contains(url, "item_id=7657134435204071960")
        end
    },
    {
        name = "derive_raw_full_url with ip endpoint",
        func = function()
            local url = FanQie.derive_raw_full_url("http://101.35.133.34:5000", "12345")
            TestUtils.assert_equal("http://101.35.133.34:5000/api/raw_full?item_id=12345", url)
        end
    },
}

return {
    name = "FanQie API Tests",
    tests = tests
}