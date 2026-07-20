local TestUtils = require("tests.test_utils")

local Cookie = require("fanqie.cookie")

local tests = {
    {
        name = "parse_cookie_header empty",
        func = function()
            local result = Cookie.parse_cookie_header(nil)
            TestUtils.assert_equal(0, #result)
        end
    },
    {
        name = "parse_cookie_header single cookie",
        func = function()
            local result = Cookie.parse_cookie_header("key=value")
            TestUtils.assert_equal("value", result["key"])
        end
    },
    {
        name = "parse_cookie_header multiple cookies",
        func = function()
            local result = Cookie.parse_cookie_header("a=1; b=2; c=3")
            TestUtils.assert_equal("1", result["a"])
            TestUtils.assert_equal("2", result["b"])
            TestUtils.assert_equal("3", result["c"])
        end
    },
    {
        name = "parse_cookie_header with Cookie prefix",
        func = function()
            local result = Cookie.parse_cookie_header("Cookie: a=1; b=2")
            TestUtils.assert_equal("1", result["a"])
            TestUtils.assert_equal("2", result["b"])
        end
    },
    {
        name = "extract_from_curl with -H cookie",
        func = function()
            local curl = '-H "Cookie: a=1; b=2"'
            local cookie, data = Cookie.extract_from_curl(curl)
            TestUtils.assert_equal("a=1; b=2", cookie)
            TestUtils.assert_nil(data)
        end
    },
    {
        name = "extract_from_curl with -b",
        func = function()
            local curl = '-b "a=1; b=2"'
            local cookie, data = Cookie.extract_from_curl(curl)
            TestUtils.assert_equal("a=1; b=2", cookie)
        end
    },
    {
        name = "extract_from_curl with --cookie",
        func = function()
            local curl = '--cookie "a=1; b=2"'
            local cookie, data = Cookie.extract_from_curl(curl)
            TestUtils.assert_equal("a=1; b=2", cookie)
        end
    },
    {
        name = "extract_from_curl with -d",
        func = function()
            local curl = '-d "{test: true}"'
            local cookie, data = Cookie.extract_from_curl(curl)
            TestUtils.assert_equal('{test: true}', data)
        end
    },
    {
        name = "to_header basic",
        func = function()
            local cookies = { a = "1", b = "2" }
            local result = Cookie.to_header(cookies)
            TestUtils.assert_contains(result, "a=1")
            TestUtils.assert_contains(result, "b=2")
        end
    },
    {
        name = "to_header empty",
        func = function()
            local result = Cookie.to_header(nil)
            TestUtils.assert_equal("", result)
        end
    },
    {
        name = "merge_set_cookie single",
        func = function()
            local cookies = {}
            local result = Cookie.merge_set_cookie(cookies, "ttwid=abc123; Path=/")
            TestUtils.assert_equal("abc123", result["ttwid"])
        end
    },
    {
        name = "merge_set_cookie multiple",
        func = function()
            local cookies = { a = "1" }
            local result = Cookie.merge_set_cookie(cookies, "a=2; b=3")
            TestUtils.assert_equal("2", result["a"])
            TestUtils.assert_equal("3", result["b"])
        end
    },
    {
        name = "merge_set_cookie table",
        func = function()
            local cookies = {}
            local result = Cookie.merge_set_cookie(cookies, {"a=1", "b=2"})
            TestUtils.assert_equal("1", result["a"])
            TestUtils.assert_equal("2", result["b"])
        end
    },
    {
        name = "has_login_cookie with valid",
        func = function()
            local cookies = { ttwid = "abcdefgh" }
            TestUtils.assert_true(Cookie.has_login_cookie(cookies))
        end
    },
    {
        name = "has_login_cookie with short value",
        func = function()
            local cookies = { ttwid = "abc" }
            TestUtils.assert_false(Cookie.has_login_cookie(cookies))
        end
    },
    {
        name = "has_login_cookie empty",
        func = function()
            TestUtils.assert_false(Cookie.has_login_cookie(nil))
            TestUtils.assert_false(Cookie.has_login_cookie({}))
        end
    },
}

return {
    name = "Cookie Tests",
    tests = tests
}