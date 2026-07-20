local TestUtils = require("test_utils")

local function simple_json_decode(s)
    local pos = 1
    local function skip_ws()
        while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local function parse_value()
        skip_ws()
        local ch = s:sub(pos, pos)
        if ch == "{" then
            pos = pos + 1
            local obj = {}
            skip_ws()
            if s:sub(pos, pos) == "}" then
                pos = pos + 1
                return obj
            end
            while true do
                skip_ws()
                local key = parse_value()
                skip_ws()
                if s:sub(pos, pos) ~= ":" then error("expected :") end
                pos = pos + 1
                local value = parse_value()
                obj[key] = value
                skip_ws()
                local next_ch = s:sub(pos, pos)
                if next_ch == "}" then
                    pos = pos + 1
                    return obj
                elseif next_ch ~= "," then error("expected , or }") end
                pos = pos + 1
            end
        elseif ch == "[" then
            pos = pos + 1
            local arr = {}
            skip_ws()
            if s:sub(pos, pos) == "]" then
                pos = pos + 1
                return arr
            end
            while true do
                table.insert(arr, parse_value())
                skip_ws()
                local next_ch = s:sub(pos, pos)
                if next_ch == "]" then
                    pos = pos + 1
                    return arr
                elseif next_ch ~= "," then error("expected , or ]") end
                pos = pos + 1
            end
        elseif ch == '"' then
            pos = pos + 1
            local str = ""
            while pos <= #s and s:sub(pos, pos) ~= '"' do
                if s:sub(pos, pos) == "\\" then
                    pos = pos + 1
                    local esc = s:sub(pos, pos)
                    if esc == "n" then str = str .. "\n"
                    elseif esc == "r" then str = str .. "\r"
                    elseif esc == "t" then str = str .. "\t"
                    elseif esc == "u" then
                        local code = tonumber(s:sub(pos+1, pos+4), 16)
                        str = str .. utf8.char(code)
                        pos = pos + 4
                    else str = str .. esc end
                else
                    str = str .. s:sub(pos, pos)
                end
                pos = pos + 1
            end
            pos = pos + 1
            return str
        elseif ch == "t" and s:sub(pos, pos+3) == "true" then
            pos = pos + 4
            return true
        elseif ch == "f" and s:sub(pos, pos+4) == "false" then
            pos = pos + 5
            return false
        elseif ch == "n" and s:sub(pos, pos+3) == "null" then
            pos = pos + 4
            return nil
        elseif ch:match("%d") or ch == "-" then
            local num_str = ""
            if ch == "-" then
                num_str = "-"
                pos = pos + 1
            end
            while pos <= #s and s:sub(pos, pos):match("%d") do
                num_str = num_str .. s:sub(pos, pos)
                pos = pos + 1
            end
            if s:sub(pos, pos) == "." then
                num_str = num_str .. "."
                pos = pos + 1
                while pos <= #s and s:sub(pos, pos):match("%d") do
                    num_str = num_str .. s:sub(pos, pos)
                    pos = pos + 1
                end
            end
            if s:sub(pos, pos):match("[eE]") then
                num_str = num_str .. s:sub(pos, pos)
                pos = pos + 1
                if s:sub(pos, pos) == "+" or s:sub(pos, pos) == "-" then
                    num_str = num_str .. s:sub(pos, pos)
                    pos = pos + 1
                end
                while pos <= #s and s:sub(pos, pos):match("%d") do
                    num_str = num_str .. s:sub(pos, pos)
                    pos = pos + 1
                end
            end
            return tonumber(num_str)
        else
            error("unexpected character: " .. ch)
        end
    end
    return parse_value()
end

local mock_json = {
    decode = simple_json_decode,
    encode = function(data)
        return "{}"
    end
}

package.loaded["json"] = mock_json

local tests = {
    {
        name = "node_cache mark and check",
        func = function()
            local Client = require("fanqie.client")
            local mock_settings = {
                get = function(_, key) return {} end,
                set = function() end,
                flush = function() end,
                get_fanqie_api_endpoints = function() return { "http://test.example.com" } end,
            }
            local client = Client:new(mock_settings)

            client:mark_node_success("http://test.example.com")
            local cached = client.node_cache["http://test.example.com"]
            TestUtils.assert_not_nil(cached)
            TestUtils.assert_true(cached.available)

            client:mark_node_failed("http://test.example.com")
            cached = client.node_cache["http://test.example.com"]
            TestUtils.assert_false(cached.available)
        end
    },
    {
        name = "get_available_endpoints filters failed",
        func = function()
            local Client = require("fanqie.client")
            local mock_settings = {
                get = function(_, key) return {} end,
                set = function() end,
                flush = function() end,
                get_fanqie_api_endpoints = function() return { "http://good.example.com", "http://bad.example.com" } end,
            }
            local client = Client:new(mock_settings)

            client:mark_node_failed("http://bad.example.com")
            local available = client:get_available_endpoints()
            TestUtils.assert_equal(1, #available)
            TestUtils.assert_equal("http://good.example.com", available[1])
        end
    },
    {
        name = "has_third_party_endpoints with endpoints",
        func = function()
            local Client = require("fanqie.client")
            -- Clear NODE_CACHE to avoid contamination from previous tests
            for k in pairs(Client.node_cache or {}) do
                Client.node_cache[k] = nil
            end
            local mock_settings = {
                get = function(_, key) return {} end,
                set = function() end,
                flush = function() end,
                get_fanqie_api_endpoints = function() return { "http://fresh.example.com" } end,
            }
            local client = Client:new(mock_settings)
            TestUtils.assert_true(client:has_third_party_endpoints())
        end
    },
    {
        name = "has_third_party_endpoints without endpoints",
        func = function()
            local Client = require("fanqie.client")
            local mock_settings = {
                get = function(_, key) return {} end,
                set = function() end,
                flush = function() end,
                get_fanqie_api_endpoints = function() return {} end,
            }
            local client = Client:new(mock_settings)
            TestUtils.assert_false(client:has_third_party_endpoints())
        end
    },
    {
        name = "parse_reader_page with NEXT_DATA",
        func = function()
            local Client = require("fanqie.client")
            local mock_settings = {
                get = function(_, key) return {} end,
                set = function() end,
                flush = function() end,
                get_fanqie_api_endpoints = function() return {} end,
            }
            local client = Client:new(mock_settings)

            local html = '<script id="__NEXT_DATA__">{"reader":{"chapterData":{"content":"test content"}}}}</script>'
            local data = client:parse_reader_page(html)
            TestUtils.assert_not_nil(data)
            TestUtils.assert_equal("test content", data.reader.chapterData.content)
        end
    },
    {
        name = "parse_reader_page with INITIAL_STATE",
        func = function()
            local Client = require("fanqie.client")
            local mock_settings = {
                get = function(_, key) return {} end,
                set = function() end,
                flush = function() end,
                get_fanqie_api_endpoints = function() return {} end,
            }
            local client = Client:new(mock_settings)

            local html = 'window.__INITIAL_STATE__ = {"reader":{"content":"state content"}};'
            local data = client:parse_reader_page(html)
            TestUtils.assert_not_nil(data)
            TestUtils.assert_equal("state content", data.reader.content)
        end
    },
    {
        name = "extract_chapter_content_from_reader various paths",
        func = function()
            local Client = require("fanqie.client")
            local mock_settings = {
                get = function(_, key) return {} end,
                set = function() end,
                flush = function() end,
                get_fanqie_api_endpoints = function() return {} end,
            }
            local client = Client:new(mock_settings)

            local data1 = { reader = { chapterData = { content = "path1", title = "Title1" } } }
            local result1 = client:extract_chapter_content_from_reader(data1)
            TestUtils.assert_equal("path1", result1.content)
            TestUtils.assert_equal("Title1", result1.title)

            local data2 = { content = "path2" }
            local result2 = client:extract_chapter_content_from_reader(data2)
            TestUtils.assert_equal("path2", result2.content)

            local data3 = { reader = { chapter = { content = "path3", title = "Title3" } } }
            local result3 = client:extract_chapter_content_from_reader(data3)
            TestUtils.assert_equal("path3", result3.content)
            TestUtils.assert_equal("Title3", result3.title)
        end
    },
}

return {
    name = "Client Tests",
    tests = tests
}