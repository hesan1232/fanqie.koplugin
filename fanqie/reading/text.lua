--[[--
文字/编码工具（番茄 reading 协议子集）。
从 book.koplugin/utils/text.lua 摘取：Base64 编解码、URL 编码。
纯 Lua，零 KOReader 依赖。

@module fanqie.reading.text
--]]

local Text = {}

--- Base64 编码（标准字母表，输入按字节处理）。
---@param data string|nil
---@return string
function Text.base64Encode(data)
    data = tostring(data or "")
    if data == "" then
        return ""
    end
    local alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        b, c = b or 0, c or 0
        local n = a * 65536 + b * 256 + c
        out[#out + 1] = alpha:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        out[#out + 1] = alpha:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        if i + 1 > #data then
            out[#out + 1] = "="
            out[#out + 1] = "="
        elseif i + 2 > #data then
            out[#out + 1] = alpha:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
            out[#out + 1] = "="
        else
            out[#out + 1] = alpha:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1)
            out[#out + 1] = alpha:sub(n % 64 + 1, n % 64 + 1)
        end
    end
    return table.concat(out)
end

--- Base64 解码（容忍 URL-safe 字符与缺失填充）。
---@param data string|nil
---@return string
function Text.base64Decode(data)
    data = tostring(data or "")
    local alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    data = data:gsub("-", "+"):gsub("_", "/")
    local pad = #data % 4
    if pad > 0 then
        data = data .. string.rep("=", 4 - pad)
    end
    data = data:gsub("[^" .. alpha .. "=]", "")
    return (data:gsub(".", function(char)
        if char == "=" then
            return ""
        end
        local bits = ""
        local index = alpha:find(char, 1, true) - 1
        for b = 6, 1, -1 do
            bits = bits .. (index % 2 ^ b - index % 2 ^ (b - 1) > 0 and "1" or "0")
        end
        return bits
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(bits)
        if #bits ~= 8 then
            return ""
        end
        local byte = 0
        for i = 1, 8 do
            if bits:sub(i, i) == "1" then
                byte = byte + 2 ^ (8 - i)
            end
        end
        return string.char(byte)
    end))
end

--- URL 编码（RFC 3986 unreserved 保留，其余 %XX 大写）。
---@return string
function Text.urlEncode(value)
    return (tostring(value):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

return Text
