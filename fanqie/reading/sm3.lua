--[[--
SM3 哈希（国密）。纯 LuaJIT。
移植自 book.koplugin/source/fanqie/reading/sm3.lua，供四神签名 X-Argus 使用。

@module fanqie.reading.sm3
--]]

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift = bit.lshift, bit.rshift

local Sm3 = {}

local function u32(x)
    return band(x, 0xffffffff)
end

local function rotl(x, n)
    n = n % 32
    return u32(bor(lshift(x, n), rshift(x, 32 - n)))
end

local function ff(j, x, y, z)
    if j <= 15 then
        return bxor(x, y, z)
    end
    return bor(band(x, y), band(x, z), band(y, z))
end

local function gg(j, x, y, z)
    if j <= 15 then
        return bxor(x, y, z)
    end
    return bor(band(x, y), band(bnot(x), z))
end

local function p0(x)
    return bxor(x, rotl(x, 9), rotl(x, 17))
end

local function p1(x)
    return bxor(x, rotl(x, 15), rotl(x, 23))
end

local function t_j(j)
    return j <= 15 and 0x79cc4519 or 0x7a879d8a
end

local function bytes_to_u32_be(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return u32(bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d))
end

local function u32_to_bytes_be(x)
    x = u32(x)
    return string.char(
        band(rshift(x, 24), 0xff),
        band(rshift(x, 16), 0xff),
        band(rshift(x, 8), 0xff),
        band(x, 0xff)
    )
end

---@param msg string
---@return string 32 bytes
function Sm3.hash(msg)
    msg = tostring(msg or "")
    local iv = {
        0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
        0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
    }
    local bitlen = #msg * 8
    msg = msg .. "\128"
    while (#msg % 64) ~= 56 do
        msg = msg .. "\0"
    end
    -- 64-bit big-endian length
    local hi = math.floor(bitlen / 0x100000000)
    local lo = bitlen % 0x100000000
    msg = msg
        .. u32_to_bytes_be(hi)
        .. u32_to_bytes_be(lo)

    for off = 1, #msg, 64 do
        local w = {}
        for i = 0, 15 do
            w[i] = bytes_to_u32_be(msg, off + i * 4)
        end
        for j = 16, 67 do
            w[j] = u32(bxor(p1(bxor(w[j - 16], w[j - 9], rotl(w[j - 3], 15))), rotl(w[j - 13], 7), w[j - 6]))
        end
        local w1 = {}
        for j = 0, 63 do
            w1[j] = u32(bxor(w[j], w[j + 4]))
        end
        local a, b, c, d, e, f, g, h = unpack(iv)
        for j = 0, 63 do
            local ss1 = rotl(u32(rotl(a, 12) + e + rotl(t_j(j), j)), 7)
            local ss2 = u32(bxor(ss1, rotl(a, 12)))
            local tt1 = u32(ff(j, a, b, c) + d + ss2 + w1[j])
            local tt2 = u32(gg(j, e, f, g) + h + ss1 + w[j])
            d = c
            c = rotl(b, 9)
            b = a
            a = tt1
            h = g
            g = rotl(f, 19)
            f = e
            e = p0(tt2)
        end
        iv[1] = u32(bxor(iv[1], a))
        iv[2] = u32(bxor(iv[2], b))
        iv[3] = u32(bxor(iv[3], c))
        iv[4] = u32(bxor(iv[4], d))
        iv[5] = u32(bxor(iv[5], e))
        iv[6] = u32(bxor(iv[6], f))
        iv[7] = u32(bxor(iv[7], g))
        iv[8] = u32(bxor(iv[8], h))
    end
    local out = {}
    for i = 1, 8 do
        out[i] = u32_to_bytes_be(iv[i])
    end
    return table.concat(out)
end

---@param msg string
---@return string hex
function Sm3.hex(msg)
    return (Sm3.hash(msg):gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

return Sm3
