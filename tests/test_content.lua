local TestUtils = require("test_utils")
local Content = require("lib.content")

local tests = {
    {
        name = "decode_pua_content empty",
        func = function()
            TestUtils.assert_equal("", Content.decode_pua_content(nil))
            TestUtils.assert_equal("", Content.decode_pua_content(""))
        end
    },
    {
        name = "decode_pua_content with PUA chars",
        func = function()
            local pua_char1 = utf8.char(58344)
            local result = Content.decode_pua_content(pua_char1)
            TestUtils.assert_not_nil(result)
            TestUtils.assert_true(#result > 0)
        end
    },
    {
        name = "decode_pua_content with mixed content",
        func = function()
            local pua_char = utf8.char(58344)
            local result = Content.decode_pua_content("Hello" .. pua_char .. "World")
            TestUtils.assert_equal(11, #result)
        end
    },
    {
        name = "strip_html basic",
        func = function()
            local html = "<p>Hello <b>World</b></p>"
            local result = Content.strip_html(html)
            TestUtils.assert_true(result:find("Hello World"))
        end
    },
    {
        name = "strip_html with entities",
        func = function()
            local html = "&amp;lt;test&amp;gt;"
            local result = Content.strip_html(html)
            TestUtils.assert_equal("<test>", result)
        end
    },
    {
        name = "decode_html_entities basic",
        func = function()
            local text = "&amp;lt;test&amp;gt;"
            local result = Content.decode_html_entities(text)
            TestUtils.assert_equal("<test>", result)
        end
    },
    {
        name = "clean_chapter_content with html",
        func = function()
            local html = "<body><p>Chapter 1</p><p>This is the first paragraph.</p></body>"
            local result = Content.clean_chapter_content(html)
            TestUtils.assert_true(result:find("<p>"))
            TestUtils.assert_true(result:find("Chapter 1"))
        end
    },
    {
        name = "clean_chapter_content with script/style",
        func = function()
            local html = "<script>alert('test')</script><style>body{}</style><p>Hello</p>"
            local result = Content.clean_chapter_content(html)
            TestUtils.assert_false(result:find("script"))
            TestUtils.assert_false(result:find("style"))
            TestUtils.assert_true(result:find("Hello"))
        end
    },
    {
        name = "txt_to_xhtml basic",
        func = function()
            local text = "Line 1\nLine 2"
            local result = Content.txt_to_xhtml(text)
            TestUtils.assert_true(result:find("<html"))
            TestUtils.assert_true(result:find("<p>Line 1</p>"))
            TestUtils.assert_true(result:find("<p>Line 2</p>"))
        end
    },
    {
        name = "normalize_chapters with data wrapper",
        func = function()
            local payload = { data = { { bookId = "123", updated = { { itemId = 1, title = "Chapter 1" } } } } }
            local result = Content.normalize_chapters(payload, "123")
            TestUtils.assert_equal(1, #result)
            TestUtils.assert_equal("Chapter 1", result[1].title)
        end
    },
    {
        name = "normalize_chapters with direct list",
        func = function()
            local payload = { { itemId = 1, title = "Chapter 1" }, { itemId = 2, title = "Chapter 2" } }
            local result = Content.normalize_chapters(payload, "123")
            TestUtils.assert_equal(2, #result)
        end
    },
    {
        name = "first_readable_chapter skips cover",
        func = function()
            local chapters = { { title = "封面" }, { title = "Chapter 1" }, { title = "Chapter 2" } }
            local result = Content.first_readable_chapter(chapters)
            TestUtils.assert_equal("Chapter 1", result.title)
        end
    },
    {
        name = "readable_chapters filters cover",
        func = function()
            local chapters = { { title = "封面" }, { title = "Chapter 1" }, { title = "封面" }, { title = "Chapter 2" } }
            local result = Content.readable_chapters(chapters)
            TestUtils.assert_equal(2, #result)
            TestUtils.assert_equal("Chapter 1", result[1].title)
            TestUtils.assert_equal("Chapter 2", result[2].title)
        end
    },
}

return {
    name = "Content Tests",
    tests = tests
}