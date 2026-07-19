local bit, err = pcall(require, "bit")
if not bit then
    local function toUInt32(x)
        return (x % 4294967296)
    end
    
    local function band_func(a, b, ...)
        local result = toUInt32(a)
        b = toUInt32(b)
        local r = 0
        local bit_val = 1
        for _ = 1, 32 do
            if (result % 2 == 1) and (b % 2 == 1) then
                r = r + bit_val
            end
            result = math.floor(result / 2)
            b = math.floor(b / 2)
            bit_val = bit_val * 2
        end
        for i = 1, select('#', ...) do
            local c = toUInt32(select(i, ...))
            result = r
            r = 0
            bit_val = 1
            for _ = 1, 32 do
                if (result % 2 == 1) and (c % 2 == 1) then
                    r = r + bit_val
                end
                result = math.floor(result / 2)
                c = math.floor(c / 2)
                bit_val = bit_val * 2
            end
        end
        return r
    end
    
    local function bor_func(a, b, ...)
        local result = toUInt32(a)
        b = toUInt32(b)
        local r = 0
        local bit_val = 1
        for _ = 1, 32 do
            if (result % 2 == 1) or (b % 2 == 1) then
                r = r + bit_val
            end
            result = math.floor(result / 2)
            b = math.floor(b / 2)
            bit_val = bit_val * 2
        end
        for i = 1, select('#', ...) do
            local c = toUInt32(select(i, ...))
            result = r
            r = 0
            bit_val = 1
            for _ = 1, 32 do
                if (result % 2 == 1) or (c % 2 == 1) then
                    r = r + bit_val
                end
                result = math.floor(result / 2)
                c = math.floor(c / 2)
                bit_val = bit_val * 2
            end
        end
        return r
    end
    
    local function bxor_func(a, b, ...)
        local result = toUInt32(a)
        b = toUInt32(b)
        local r = 0
        local bit_val = 1
        for _ = 1, 32 do
            if (result % 2 ~= b % 2) then
                r = r + bit_val
            end
            result = math.floor(result / 2)
            b = math.floor(b / 2)
            bit_val = bit_val * 2
        end
        for i = 1, select('#', ...) do
            local c = toUInt32(select(i, ...))
            result = r
            r = 0
            bit_val = 1
            for _ = 1, 32 do
                if (result % 2 ~= c % 2) then
                    r = r + bit_val
                end
                result = math.floor(result / 2)
                c = math.floor(c / 2)
                bit_val = bit_val * 2
            end
        end
        return r
    end
    
    local function bnot_func(a)
        a = toUInt32(a)
        local r = 0
        local bit_val = 1
        for _ = 1, 32 do
            if a % 2 == 0 then
                r = r + bit_val
            end
            a = math.floor(a / 2)
            bit_val = bit_val * 2
        end
        return r
    end
    
    local function lshift_func(a, b)
        a = toUInt32(a)
        b = b % 32
        for _ = 1, b do
            a = a * 2
            if a >= 4294967296 then
                a = a - 4294967296
            end
        end
        return a
    end
    
    local function rshift_func(a, b)
        a = toUInt32(a)
        b = b % 32
        for _ = 1, b do
            a = math.floor(a / 2)
        end
        return a
    end
    
    local function rol_func(a, b)
        a = toUInt32(a)
        b = b % 32
        for _ = 1, b do
            local bit = a >= 2147483648 and 1 or 0
            a = a * 2
            if a >= 4294967296 then
                a = a - 4294967296
            end
            a = a + bit
        end
        return a
    end
    
    local function ror_func(a, b)
        a = toUInt32(a)
        b = b % 32
        for _ = 1, b do
            local bit = a % 2
            a = math.floor(a / 2)
            if bit == 1 then
                a = a + 2147483647 + 1
            end
        end
        return a
    end
    
    band = band_func
    bor = bor_func
    bxor = bxor_func
    bnot = bnot_func
    lshift = lshift_func
    rshift = rshift_func
    rol = rol_func
    ror = ror_func
else
    band = bit.band
    bor = bit.bor
    bxor = bit.bxor
    bnot = bit.bnot
    lshift = bit.lshift
    rshift = bit.rshift
    rol = bit.rol
    ror = bit.ror
end

local Crypto = {}

local function u32(n)
    return band(n, 0xffffffff)
end

local function add(...)
    local result = 0
    for i = 1, select("#", ...) do
        result = u32(result + select(i, ...))
    end
    return result
end

local function le_word(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    return bor(b1, lshift(b2, 8), lshift(b3, 16), lshift(b4, 24))
end

local function word_to_le_hex(n)
    return string.format(
        "%02x%02x%02x%02x",
        band(n, 0xff),
        band(rshift(n, 8), 0xff),
        band(rshift(n, 16), 0xff),
        band(rshift(n, 24), 0xff)
    )
end

local md5_s = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local md5_k = {}
for i = 1, 64 do
    md5_k[i] = math.floor(math.abs(math.sin(i)) * 4294967296)
end

function Crypto.md5_hex(message)
    message = tostring(message or "")
    local bit_len = #message * 8
    local padding_len = (56 - (#message + 1) % 64) % 64
    message = message .. string.char(0x80) .. string.rep("\0", padding_len)
    message = message .. string.char(
        band(bit_len, 0xff),
        band(rshift(bit_len, 8), 0xff),
        band(rshift(bit_len, 16), 0xff),
        band(rshift(bit_len, 24), 0xff),
        0, 0, 0, 0
    )

    local a0 = 0x67452301
    local b0 = 0xefcdab89
    local c0 = 0x98badcfe
    local d0 = 0x10325476

    for chunk = 1, #message, 64 do
        local m = {}
        for i = 0, 15 do
            m[i] = le_word(message, chunk + i * 4)
        end

        local a, b, c, d = a0, b0, c0, d0
        for i = 0, 63 do
            local f, g
            if i < 16 then
                f = bor(band(b, c), band(bnot(b), d))
                g = i
            elseif i < 32 then
                f = bor(band(d, b), band(bnot(d), c))
                g = (5 * i + 1) % 16
            elseif i < 48 then
                f = bxor(b, c, d)
                g = (3 * i + 5) % 16
            else
                f = bxor(c, bor(b, bnot(d)))
                g = (7 * i) % 16
            end
            f = add(f, a, md5_k[i + 1], m[g])
            a, d, c, b = d, c, b, add(b, rol(f, md5_s[i + 1]))
        end

        a0 = add(a0, a)
        b0 = add(b0, b)
        c0 = add(c0, c)
        d0 = add(d0, d)
    end

    return table.concat({
        word_to_le_hex(a0),
        word_to_le_hex(b0),
        word_to_le_hex(c0),
        word_to_le_hex(d0),
    })
end

return Crypto