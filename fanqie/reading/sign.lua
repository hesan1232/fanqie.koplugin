--[[--
番茄四神签名：X-Khronos / X-Ladon / X-Helios / X-Argus。
移植自 book.koplugin/source/fanqie/reading/sign.lua（原始来自 fanqie-re/fanqie_sign.py）。
依赖 LuaJIT：bit / ffi / ffi.sha2。

@module fanqie.reading.sign
--]]

local Aes = require("fanqie.reading.aes")
local Sm3 = require("fanqie.reading.sm3")
local Text = require("fanqie.reading.text")
local ffi = require("ffi")
local bit = require("bit")

-- ffi/sha2 为 KOReader 自带模块；加载失败时给出明确错误（由 official 源捕获后回退其它源）。
local ok_sha2, sha2 = pcall(require, "ffi/sha2")
if not ok_sha2 or type(sha2) ~= "table" or type(sha2.md5) ~= "function" then
    error("fanqie.reading.sign: 需要 ffi/sha2 模块（KOReader 自带）")
end
local md5 = sha2.md5

local Sign = {}

local AID = 1967
local LADON_AID = 3019
local LICENSE_ID = 1611921764
local SDK_VERSION_STR = "v04.04.05-ov-android"
local SDK_VERSION = 134744640

local SIGN_KEY = Aes.from_hex(
    "ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c")
local INNER_SALT = string.char(0xf2, 0x81, 0x61, 0x6f)
-- Z 常量：LuaJIT 字符串 cast 不可靠，拆成高低 32 位拼。
local SIMON_Z = bit.bor(
    ffi.cast("uint64_t", 0x046D678B),
    bit.lshift(ffi.cast("uint64_t", 0x3DC94C3A), 32))

local function u64(n)
    if type(n) == "cdata" then return n end
    if type(n) == "string" then return ffi.cast("uint64_t", n) end
    return ffi.cast("uint64_t", n)
end

local function u64_to_le(v)
    local p = ffi.new("uint64_t[1]", v)
    return ffi.string(p, 8)
end

local function le_to_u64(s)
    local p = ffi.new("uint64_t[1]")
    ffi.copy(p, s, 8)
    return p[0]
end

local function ror64(v, n)
    n = bit.band(n, 63)
    v = u64(v)
    if n == 0 then return v end
    return bit.bor(bit.rshift(v, n), bit.lshift(v, 64 - n))
end

local function rol64(v, n)
    n = bit.band(n, 63)
    v = u64(v)
    if n == 0 then return v end
    return bit.bor(bit.lshift(v, n), bit.rshift(v, 64 - n))
end

local urandom = require("fanqie.reading.crypto").urandom

local function pkcs7_pad(data, block)
    return Aes.pkcs7_pad(data, block or 16)
end

-- ---------------------------------------------------------------------------
-- protobuf
-- ---------------------------------------------------------------------------

local function varint(v)
    -- 无符号 32-bit：LuaJIT bit.* 对高位当有符号，不能直接 rshift。
    if type(v) ~= "number" then v = tonumber(v) or 0 end
    v = v % 0x100000000
    if v < 0 then v = v + 0x100000000 end
    local out = {}
    while v >= 0x80 do
        out[#out + 1] = string.char(bit.bor(bit.band(math.floor(v), 0x7f), 0x80))
        v = math.floor(v / 128)
    end
    out[#out + 1] = string.char(v)
    return table.concat(out)
end

local function pb_field(idx, wire, payload)
    return varint(bit.bor(bit.lshift(idx, 3), wire)) .. payload
end

local function pb_varint(idx, val)
    return pb_field(idx, 0, varint(val))
end

local function pb_bytes(idx, data)
    return pb_field(idx, 2, varint(#data) .. data)
end

local function pb_str(idx, s)
    return pb_bytes(idx, s)
end

-- ---------------------------------------------------------------------------
-- Ladon / Helios
-- ---------------------------------------------------------------------------

local function encrypt_ladon_block(hash_table, block)
    local data0 = le_to_u64(block:sub(1, 8))
    local data1 = le_to_u64(block:sub(9, 16))
    for i = 0, 0x21 do
        local h = le_to_u64(hash_table:sub(i * 8 + 1, i * 8 + 8))
        data1 = bit.bxor(h, data0 + ror64(data1, 8))
        data0 = bit.bxor(data1, ror64(data0, 0x3d))
    end
    return u64_to_le(data0) .. u64_to_le(data1)
end

local function build_ladon_hash_table(md5hex_ascii)
    local table_buf = md5hex_ascii:sub(1, 32) .. string.rep("\0", 272 + 16 - 32)
    local temp = {
        le_to_u64(table_buf:sub(1, 8)),
        le_to_u64(table_buf:sub(9, 16)),
        le_to_u64(table_buf:sub(17, 24)),
        le_to_u64(table_buf:sub(25, 32)),
    }
    local buffer_b0 = temp[1]
    local buffer_b8 = temp[2]
    -- drop first two; keep as queue
    local queue = { temp[3], temp[4] }
    local parts = { table_buf:sub(1, 8) } -- will rebuild
    -- rebuild table as byte array
    local bytes = { table_buf:byte(1, #table_buf) }
    for i = 0, 0x21 do
        local x9 = buffer_b0
        local x8 = ror64(buffer_b8, 8)
        x8 = x8 + x9
        x8 = bit.bxor(x8, u64(i))
        queue[#queue + 1] = x8
        x8 = bit.bxor(x8, ror64(x9, 61))
        local le = u64_to_le(x8)
        for j = 1, 8 do
            bytes[(i + 1) * 8 + j] = le:byte(j)
        end
        buffer_b0 = x8
        buffer_b8 = table.remove(queue, 1)
    end
    local out = {}
    for i = 1, 272 + 16 do
        out[i] = string.char(bytes[i] or 0)
    end
    return table.concat(out)
end

---@param khronos number
---@param random4 string|nil 4 bytes
---@return string base64
function Sign.encrypt_ladon(khronos, random4)
    local data = string.format("%d-%d-%d", khronos, LICENSE_ID, LADON_AID)
    random4 = random4 or urandom(4)
    assert(#random4 == 4)
    local keygen = random4 .. tostring(AID)
    local md5hex = md5(keygen) -- hex string from ffi/sha2?
    -- ffi/sha2.md5 returns hex by default in KOReader
    if #md5hex == 32 and not md5hex:find("[^%x]") then
        -- hex ascii
    else
        md5hex = Aes.to_hex(md5hex)
    end
    local table_ = build_ladon_hash_table(md5hex)
    local padded = pkcs7_pad(data, 16)
    local enc = {}
    for i = 1, #padded, 16 do
        enc[#enc + 1] = encrypt_ladon_block(table_, padded:sub(i, i + 15))
    end
    return Text.base64Encode(random4 .. table.concat(enc))
end

-- ---------------------------------------------------------------------------
-- Argus
-- ---------------------------------------------------------------------------

local function derive_inner_key()
    return Sm3.hash(SIGN_KEY .. INNER_SALT .. SIGN_KEY)
end

local function simon_key_expansion(key4)
    local key = {}
    for i = 1, 4 do key[i] = key4[i] end
    for i = 5, 72 do
        local tmp = bit.bxor(ror64(key[i - 1], 3), key[i - 3])
        tmp = bit.bxor(tmp, ror64(tmp, 1))
        local bit_i = bit.band(bit.rshift(SIMON_Z, (i - 5) % 62), u64(1))
        -- Python: bit = 1 if (Z & (1 << ((i-4)%62))) else 0; i starts at 4
        -- our i is 1-based word index; Python i=4 → key[4], ((4-4)%62)=0
        -- Lua i=5 → corresponds to Python i=4
        local py_i = i - 1 -- 0-based? Python: for i in range(4, 72): key[i]
        -- In Python key[0..3] init, then i=4..71
        -- Our key[1..4] init, i=5..72 where key[i] = Python key[i-1]
        -- Python bit: (i - 4) % 62 for i in 4..71
        local shift = (i - 5) % 62 -- when i=5 → 0 = Python (4-4)%62
        bit_i = bit.band(bit.rshift(SIMON_Z, shift), u64(1))
        local not_prev = bit.bnot(key[i - 4])
        key[i] = bit.bxor(bit.bxor(bit.bxor(not_prev, tmp), bit_i), u64(3))
    end
    return key
end

local function simon_encrypt_block(block, round_keys)
    local x_i = le_to_u64(block:sub(1, 8))
    local x_i1 = le_to_u64(block:sub(9, 16))
    for i = 1, 72 do
        local rk = round_keys[i]
        local tmp = x_i1
        local f = bit.band(rol64(x_i1, 1), rol64(x_i1, 8))
        x_i1 = bit.bxor(bit.bxor(bit.bxor(x_i, f), rol64(x_i1, 2)), rk)
        x_i = tmp
    end
    return u64_to_le(x_i) .. u64_to_le(x_i1)
end

local function simon_encrypt(data, key32)
    assert(#data % 16 == 0 and #key32 == 32)
    local key4 = {
        le_to_u64(key32:sub(1, 8)),
        le_to_u64(key32:sub(9, 16)),
        le_to_u64(key32:sub(17, 24)),
        le_to_u64(key32:sub(25, 32)),
    }
    local rks = simon_key_expansion(key4)
    local out = {}
    for i = 1, #data, 16 do
        out[#out + 1] = simon_encrypt_block(data:sub(i, i + 15), rks)
    end
    return table.concat(out)
end

local function get_bodyhash(stub_hex)
    local raw
    if stub_hex and stub_hex ~= "" then
        local ok, decoded = pcall(Aes.from_hex, stub_hex)
        raw = ok and decoded or string.rep("\0", 16)
    else
        raw = string.rep("\0", 16)
    end
    return Sm3.hash(raw):sub(1, 6)
end

local function get_queryhash(query)
    if query and query ~= "" then
        return Sm3.hash(query):sub(1, 6)
    end
    return Sm3.hash(string.rep("\0", 16)):sub(1, 6)
end

local function encrypt_enc_pb(data, length)
    local d = { data:byte(1, #data) }
    local xor_array = { unpack(d, 1, 8) }
    for i = 9, length do
        d[i] = bit.bxor(d[i], xor_array[((i - 1) % 8) + 1])
    end
    local rev = {}
    for i = length, 1, -1 do
        rev[#rev + 1] = string.char(d[i])
    end
    return table.concat(rev)
end

local function u32_shl(v, n)
    -- bit.lshift 对 >2^30 的值会按有符号 32 位溢出；用乘法保 uint32。
    v = bit.band(v, 0xffffffff)
    for _ = 1, n do
        v = bit.band(v * 2, 0xffffffff)
    end
    return v
end

---@param query string
---@param timestamp number unix seconds (khronos)
---@param device_id string
---@param opts table|nil
---@return string base64
function Sign.encrypt_argus(query, timestamp, device_id, opts)
    opts = opts or {}
    local version_name = opts.version_name or "7.3.7.33"
    local aid = opts.aid or AID
    local device_type = opts.device_type or "P30"
    local os_version = opts.os_version or "12"
    local rand_val = opts.rand_val
    if not rand_val then
        local r = urandom(4)
        rand_val = bit.band(
            bit.bor(bit.lshift(r:byte(1), 24), bit.lshift(r:byte(2), 16),
                bit.lshift(r:byte(3), 8), r:byte(4)),
            0x7fffffff)
    end

    local pb = table.concat({
        pb_varint(1, u32_shl(0x20200929, 1)),
        pb_varint(2, 2),
        pb_varint(3, rand_val),
        pb_str(4, tostring(aid)),
        pb_str(5, tostring(device_id)),
        pb_str(6, tostring(LICENSE_ID)),
        pb_str(7, version_name),
        pb_str(8, SDK_VERSION_STR),
        pb_varint(9, SDK_VERSION),
        pb_bytes(10, string.rep("\0", 8)),
        pb_varint(11, 0),
        pb_varint(12, u32_shl(timestamp, 1)),
        pb_bytes(13, get_bodyhash(opts.body_stub)),
        pb_bytes(14, get_queryhash(query)),
        pb_varint(20, 738),
        pb_bytes(23, table.concat({
            pb_str(1, device_type),
            pb_str(2, os_version),
            pb_str(3, "googleplay"),
            pb_varint(4, 0x48000000),
        })),
    })

    local padded = pkcs7_pad(pb, 16)
    local enc_pb = simon_encrypt(padded, derive_inner_key())
    local prefix = string.char(0xf2, 0xf7, 0xfc, 0xff, 0xf2, 0xf7, 0xfc, 0xff)
    local inner = encrypt_enc_pb(prefix .. enc_pb, #enc_pb + 8)
    local head = string.char(0xa6, 0x6e, 0xad, 0x9f, 0x77, 0x01, 0xd0, 0x0c, 0x18)
    local buf = head .. inner .. "ao"
    local function md5_bin(s)
        local h = md5(s)
        if #h == 32 and not h:find("[^%x]") then
            return Aes.from_hex(h)
        end
        return h
    end
    local aes_key = md5_bin(SIGN_KEY:sub(1, 16))
    local aes_iv = md5_bin(SIGN_KEY:sub(17, 32))
    local encrypted = Aes.cbc_encrypt(buf, aes_key, aes_iv, true)
    return Text.base64Encode(string.char(0xf2, 0x81) .. encrypted)
end

---@param query_string string
---@param device_id string
---@param opts table|nil
---@return table headers
function Sign.sign_headers(query_string, device_id, opts)
    opts = opts or {}
    local khronos = opts.khronos or os.time()
    return {
        ["X-Khronos"] = tostring(khronos),
        ["X-Ladon"] = Sign.encrypt_ladon(khronos, opts.ladon_random4),
        -- X-Helios 与 X-Ladon 同一算法，只是随机数独立。
        ["X-Helios"] = opts.helios or Sign.encrypt_ladon(khronos, opts.helios_random4),
        ["X-Argus"] = Sign.encrypt_argus(query_string, khronos, device_id, {
            version_name = opts.version_name,
            device_type = opts.device_type,
            os_version = opts.os_version,
            rand_val = opts.rand_val,
        }),
    }
end

Sign.derive_inner_key = derive_inner_key

return Sign
