local TestUtils = require("tests.test_utils")

local Crypto = require("lib.crypto")

local tests = {
    {
        name = "md5_hex empty string",
        func = function()
            local result = Crypto.md5_hex("")
            TestUtils.assert_equal("d41d8cd98f00b204e9800998ecf8427e", result)
        end
    },
    {
        name = "md5_hex abc",
        func = function()
            local result = Crypto.md5_hex("abc")
            TestUtils.assert_equal("900150983cd24fb0d6963f7d28e17f72", result)
        end
    },
    {
        name = "md5_hex message digest",
        func = function()
            local result = Crypto.md5_hex("message digest")
            TestUtils.assert_equal("f96b697d7cb7938d525a2f31aaf161d0", result)
        end
    },
    {
        name = "md5_hex a",
        func = function()
            local result = Crypto.md5_hex("a")
            TestUtils.assert_equal("0cc175b9c0f1b6a831c399e269772661", result)
        end
    },
    {
        name = "md5_hex quick brown fox",
        func = function()
            local result = Crypto.md5_hex("The quick brown fox jumps over the lazy dog")
            TestUtils.assert_equal("9e107d9d372bb6826bd81d3542a419d6", result)
        end
    },
    {
        name = "md5_hex number",
        func = function()
            local result = Crypto.md5_hex(12345)
            TestUtils.assert_equal("827ccb0eea8a706c4c34a16891f84e7b", result)
        end
    },
    {
        name = "md5_hex nil",
        func = function()
            local result = Crypto.md5_hex(nil)
            TestUtils.assert_equal("d41d8cd98f00b204e9800998ecf8427e", result)
        end
    },
}

return {
    name = "Crypto Tests",
    tests = tests
}