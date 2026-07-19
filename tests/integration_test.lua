local script_path = debug.getinfo(1, "S").source:sub(2)
local script_dir = script_path:match("^(.*[/\\\\])") or "./"
package.path = package.path .. ";" .. script_dir .. "?.lua;" .. script_dir .. "../?.lua;" .. script_dir .. "../lib/?.lua"

local http = require("socket.http")
local ltn12 = require("ltn12")

local function parse_config_js(path)
    local f = io.open(path, "r")
    if not f then error("Cannot open config.js: " .. path) end
    local content = f:read("*a")
    f:close()

    local cookies = content:match("fanqieCookies:%s*['\"](.-)['\"]")
    local endpoints_str = content:match("fanqieApiEndpoints:%s*%[(.-)%]")
    
    local endpoints = {}
    if endpoints_str then
        for endpoint in endpoints_str:gmatch("['\"](.-)['\"]") do
            table.insert(endpoints, endpoint)
        end
    end

    return {
        cookies = cookies or "",
        endpoints = endpoints
    }
end

local config = parse_config_js("d:/webProgram/project/kindle-forge/public/config.js")
print("========================================")
print(" FanQie Plugin - Integration Test")
print("========================================")
print("\nLoaded config from: kindle-forge/public/config.js")
print("Cookies length:", #config.cookies)
print("Endpoints:", #config.endpoints)
for i, e in ipairs(config.endpoints) do
    print("  [" .. i .. "]", e)
end

local http_endpoints = {}
for _, e in ipairs(config.endpoints) do
    if e:match("^http://") then
        table.insert(http_endpoints, e)
    end
end
print("\nHTTP Endpoints (for testing):", #http_endpoints)

local function simple_http_request(url, method, headers, body)
    method = method or "GET"
    headers = headers or {}
    local response = {}
    
    if body then
        headers["Content-Length"] = tostring(#body)
        headers["Content-Type"] = headers["Content-Type"] or "application/json"
    end
    
    local _, code, resp_headers = http.request({
        url = url,
        method = method,
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response),
        timeout = 15,
    })
    
    return table.concat(response), code, resp_headers
end

local function simple_json_decode(s)
    local pos = 1
    local function skip_ws()
        while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    
    local function parse()
        skip_ws()
        local ch = s:sub(pos, pos)
        
        if ch == "{" then
            pos = pos + 1
            skip_ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return {} end
            
            local obj = {}
            while true do
                skip_ws()
                local key = parse()
                skip_ws()
                if s:sub(pos, pos) ~= ":" then error("expected :") end
                pos = pos + 1
                local value = parse()
                obj[key] = value
                
                skip_ws()
                ch = s:sub(pos, pos)
                if ch == "}" then
                    pos = pos + 1
                    return obj
                elseif ch ~= "," then
                    error("expected , or }")
                end
                pos = pos + 1
            end
            
        elseif ch == "[" then
            pos = pos + 1
            skip_ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return {} end
            
            local arr = {}
            while true do
                table.insert(arr, parse())
                skip_ws()
                ch = s:sub(pos, pos)
                if ch == "]" then
                    pos = pos + 1
                    return arr
                elseif ch ~= "," then
                    error("expected , or ]")
                end
                pos = pos + 1
            end
            
        elseif ch == '"' then
            pos = pos + 1
            local str = ""
            while pos <= #s do
                ch = s:sub(pos, pos)
                if ch == "\\" then
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
                elseif ch == '"' then
                    pos = pos + 1
                    return str
                else
                    str = str .. ch
                end
                pos = pos + 1
            end
            error("unclosed string")
            
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
            if ch == "-" then num_str = "-"; pos = pos + 1 end
            while pos <= #s and s:sub(pos, pos):match("%d") do
                num_str = num_str .. s:sub(pos, pos)
                pos = pos + 1
            end
            if pos <= #s and s:sub(pos, pos) == "." then
                num_str = num_str .. "."
                pos = pos + 1
                while pos <= #s and s:sub(pos, pos):match("%d") do
                    num_str = num_str .. s:sub(pos, pos)
                    pos = pos + 1
                end
            end
            if pos <= #s and s:sub(pos, pos):match("[eE]") then
                num_str = num_str .. s:sub(pos, pos)
                pos = pos + 1
                if pos <= #s and (s:sub(pos, pos) == "+" or s:sub(pos, pos) == "-") then
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
    
    return parse()
end

local function test_third_party_api(endpoint)
    print("\n--- Testing Third-Party API: " .. endpoint .. " ---")
    
    local book_id = "7496166356807584792"
    local item_id = "7657134435204071960"
    
    local test_urls = {
        { name = "Book Info", path = "/api/book/" .. book_id },
        { name = "Directory", path = "/api/directory/" .. book_id },
        { name = "Chapter Content", path = "/api/content/" .. item_id },
    }
    
    for _, test in ipairs(test_urls) do
        local url = endpoint .. test.path
        print("\n  Testing:", test.name, "->", url)
        local ok, text, code = pcall(simple_http_request, url, "GET", {
            ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        })
        if ok and code == 200 then
            print("    ✓ HTTP 200 OK")
            local ok2, data = pcall(simple_json_decode, text)
            if ok2 then
                if test.name == "Book Info" then
                    print("    Title:", data.title or data.book_name or "N/A")
                    print("    Chapters:", data.chapterCount or data.serial_count or "N/A")
                elseif test.name == "Directory" then
                    local chapters = data.data or data
                    if type(chapters) == "table" then
                        print("    Total chapters:", #chapters)
                        if #chapters > 0 then
                            print("    First:", chapters[1].title or chapters[1].chapterName)
                            print("    Last:", chapters[#chapters].title or chapters[#chapters].chapterName)
                        end
                    end
                elseif test.name == "Chapter Content" then
                    local content = data.content or (data.data and data.data.content)
                    if content then
                        print("    Content length:", #content)
                        local preview = content:sub(1, 100):gsub("%s+", " ")
                        print("    Preview:", preview)
                    end
                end
            else
                print("    ✗ JSON parse error:", data)
                print("    Raw response (first 200 chars):", text:sub(1, 200))
            end
        else
            print("    ✗ Failed:", code or text)
        end
    end
end

for _, endpoint in ipairs(http_endpoints) do
    test_third_party_api(endpoint)
end

print("\n========================================")
print(" Integration Test Complete")
print("========================================")