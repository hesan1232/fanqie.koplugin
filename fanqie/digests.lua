-- SHA-256（FIPS 180-4）纯 Lua 实现 —— 只用于校验更新包完整性。
--
-- 【为什么自带实现而不调外部命令】
-- 更新包校验是整个自更新链路唯一的**安全边界**：只有 sha256 与清单一致，才能确认
-- 下载到的 zip 确实是发布者上传的那一个（而不是镜像被替换 / 传输截断 / 被劫持的内容）。
-- 而设备端的 `sha256sum`、`openssl` 并不保证存在（Kindle 的 busybox 就没有），
-- 所以这里自带一份。
--
-- 依赖 LuaJIT 内置的 `bit` 库（KOReader 各平台均使用 LuaJIT）。加载失败时
-- `sha256()` 返回 nil + 原因，调用方据此提示「本设备不支持更新校验」而不是崩溃。
--
-- ⚠️ 常量表按标准**硬编码**，不要改成 `math.floor(math.abs(math.sin(i)) * 2^32)`
--    这样的运行时计算 —— 那个写法依赖 libm 的 sin 精度，跨平台可能有 1 ulp 差异，
--    乘以 2^32 之后就会取到差 1 的常量，导致校验**永远失败**且极难排查。
--
-- 与 koobone.koplugin / 觅阅（miuread）的 digests.lua 同源，保持同一套语义。

local ok_bit, bit = pcall(require, "bit")

local D = {}

-- 标准 K 常量：前 64 个质数立方根小数部分的前 32 位
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- 标准初始哈希值：前 8 个质数平方根小数部分的前 32 位
local H0 = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
}

--- 计算字符串的 SHA-256 十六进制摘要（小写 64 字符）。
--
-- bit 相关的局部化放在函数内（而不是模块级 `if bit then ... end` 包住整个实现）：
-- 那样写会让静态检查工具看不到导出字段，也更容易读错作用域。这里每次调用取一次
-- bit 的方法，开销可忽略 —— 校验一个几百 KB 的包只会调用本函数一两次。
--
-- @param input string 待摘要内容
-- @return string 摘要 | nil, string 原因
function D.sha256(input)
    if not ok_bit or not bit then
        return nil, "bit 库不可用"
    end

    local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
    local lshift, rshift, ror = bit.lshift, bit.rshift, bit.ror

    local function u32(x) return band(x, 0xffffffff) end

    local function plus(...)
        local v = 0
        for i = 1, select("#", ...) do
            v = u32(v + select(i, ...))
        end
        return v
    end

    local function be32(s, p)
        local a, b, c, d = s:byte(p, p + 3)
        return bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end

    local function behex(x)
        return string.format("%02x%02x%02x%02x",
            band(rshift(x, 24), 255), band(rshift(x, 16), 255),
            band(rshift(x, 8), 255), band(x, 255))
    end

    local s = tostring(input or "")
    local bits = #s * 8
    -- 消息填充：补一个 0x80，再补 0 到 (56 mod 64)，末尾 8 字节大端长度。
    -- 64 位长度的高 32 位恒为 0（更新包远小于 512MB），直接写字面量 0。
    local pad = (56 - (#s + 1) % 64) % 64
    s = s .. string.char(128) .. string.rep("\0", pad)
        .. string.char(0, 0, 0, 0,
            band(rshift(bits, 24), 255), band(rshift(bits, 16), 255),
            band(rshift(bits, 8), 255), band(bits, 255))

    local h = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }

    for pos = 1, #s, 64 do
        local w = {}
        for j = 0, 15 do
            w[j] = be32(s, pos + j * 4)
        end
        for j = 16, 63 do
            local x = bxor(ror(w[j - 15], 7), ror(w[j - 15], 18), rshift(w[j - 15], 3))
            local y = bxor(ror(w[j - 2], 17), ror(w[j - 2], 19), rshift(w[j - 2], 10))
            w[j] = plus(w[j - 16], x, w[j - 7], y)
        end

        local a, b, c, d, e, f, g, q = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for j = 0, 63 do
            local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = plus(q, s1, ch, K[j + 1], w[j])
            local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = plus(s0, maj)
            q, g, f, e, d, c, b, a = g, f, e, plus(d, t1), c, b, a, plus(t1, t2)
        end

        h[1], h[2], h[3], h[4] = plus(h[1], a), plus(h[2], b), plus(h[3], c), plus(h[4], d)
        h[5], h[6], h[7], h[8] = plus(h[5], e), plus(h[6], f), plus(h[7], g), plus(h[8], q)
    end

    local out = {}
    for i = 1, 8 do
        out[i] = behex(h[i])
    end
    return table.concat(out)
end

--- SHA-256 是否可用（不可用时更新器应拒绝安装）。
function D.available()
    return ok_bit and bit ~= nil
end

return D
