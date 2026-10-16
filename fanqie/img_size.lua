--[[--
图片真实尺寸探测（PNG / JPEG / WebP），纯函数、零依赖。

为什么需要：段评图片的渲染尺寸此前只信服务端的 `width`/`height` 字段 —— 而
`~tplv…:300:0` 这类模板图**经常没有**这两个字段，字段给了也可能与实际转码产物
对不上。拿不到真实比例时渲染端只能退到「内容区宽 × 内容区宽」的**正方形**
兜底框，而 `ImageWidget:getSize()` 在给了 width/height 时**原样返回 box 尺寸**
（图片本身是按比例缩放的，画在比例不符的 box 里）⇒ 竖图/横图周围全是留白。

这里直接读**文件头**拿真实尺寸：三种格式的宽高都在头部几十字节里。

语义：
  * `probe(path)` → `w, h`（都 > 0）；读不到 / 解析不出 → `nil, nil`
    （调用方回退服务端字段，再回退正方形兜底）；
  * 结果按 path 记忆（进程内）：同一路径随视图重建被反复询问，不值得每次 io；
    重下覆盖后尺寸几乎总是不变（同 URL 同模板），不为它引入 lfs 依赖。
  * 损坏 / 非图片文件同样记 nil：别让一张坏图把每次渲染都变成重读。

@module fanqie.img_size
]]

local M = {}

local MEMO = {}

-- 大端 / 小端读 n 字节无符号
local function be(buf, i, n)
    local v = 0
    for k = 0, n - 1 do v = v * 256 + buf:byte(i + k) end
    return v
end

local function le(buf, i, n)
    local v = 0
    for k = n - 1, 0, -1 do v = v * 256 + buf:byte(i + k) end
    return v
end

-- PNG：8 字节签名 + 4 长度 + "IHDR" + 4 宽 + 4 高（大端）
local function png_size(buf)
    if #buf < 24 then return nil end
    if buf:byte(13) ~= 0x49 or buf:byte(14) ~= 0x48
        or buf:byte(15) ~= 0x44 or buf:byte(16) ~= 0x52 then
        return nil
    end
    return be(buf, 17, 4), be(buf, 21, 4)
end

-- WebP：RIFF 容器，三种 chunk 的宽高位置各不相同
local function webp_size(buf)
    if #buf < 30 then return nil end
    if buf:sub(9, 12) ~= "WEBP" then return nil end
    local fourcc = buf:sub(13, 16)
    if fourcc == "VP8X" then
        -- 1 flags + 3 reserved，随后 canvas 宽-1 / 高-1（各 3 字节小端）
        return le(buf, 25, 3) + 1, le(buf, 28, 3) + 1
    elseif fourcc == "VP8 " then
        -- 有损帧：3 字节 frame tag + 起始码 9D 01 2A + 宽/高（2 字节小端，低 14 位）
        if buf:byte(24) ~= 0x9D or buf:byte(25) ~= 0x01 or buf:byte(26) ~= 0x2A then
            return nil
        end
        return le(buf, 27, 2) % 16384, le(buf, 29, 2) % 16384
    elseif fourcc == "VP8L" then
        -- 无损：1 字节签名 0x2F，随后 14bit 宽-1 / 14bit 高-1 位打包（小端位序）
        if buf:byte(21) ~= 0x2F then return nil end
        local b1, b2, b3, b4 = buf:byte(22, 25)
        local w = b1 + (b2 % 64) * 256 + 1
        local h = math.floor(b2 / 64) + b3 * 4 + (b4 % 16) * 1024 + 1
        return w, h
    end
    return nil
end

-- SOF0~SOF15 里带尺寸的段（C4 DHT / C8 JPG / CC DAC 除外）
local JPEG_SOF = {
    [0xC0] = true, [0xC1] = true, [0xC2] = true, [0xC3] = true,
    [0xC5] = true, [0xC6] = true, [0xC7] = true,
    [0xC9] = true, [0xCA] = true, [0xCB] = true,
    [0xCD] = true, [0xCE] = true, [0xCF] = true,
}

local function jpeg_size(buf)
    -- 从 FF D8 之后逐 marker 段扫描；SOF 段内：1 精度 + 2 高 + 2 宽（大端）
    local i = 3
    while i + 9 <= #buf do
        if buf:byte(i) ~= 0xFF then return nil end       -- 段对齐坏了
        local marker = buf:byte(i + 1)
        if marker == 0x01 or (marker >= 0xD0 and marker <= 0xD9) then
            i = i + 2                                    -- 无长度字段的段
        elseif JPEG_SOF[marker] then
            return be(buf, i + 7, 2), be(buf, i + 5, 2)  -- w, h
        elseif marker == 0xDA then
            return nil                                   -- SOS：前面没有 SOF
        else
            i = i + 2 + be(buf, i + 2, 2)                -- 常规段：跳过整个段
        end
    end
    return nil
end

--- 探测图片真实宽高。头最多读 64 KiB（JPEG 的 EXIF/ICC 一般都在这个范围内）。
-- @treturn number|nil w
-- @treturn number|nil h
function M.probe(path)
    local hit = MEMO[path]
    if hit ~= nil then
        return hit[1], hit[2]
    end
    local w, h
    local f = io.open(path, "rb")
    if f then
        local head = f:read(65536) or ""
        f:close()
        if #head >= 24 then
            local is_png = head:byte(1) == 0x89 and head:sub(2, 4) == "PNG"
            local is_webp = head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP"
            if is_png then
                w, h = png_size(head)
            elseif is_webp then
                w, h = webp_size(head)
            elseif head:byte(1) == 0xFF and head:byte(2) == 0xD8 then
                w, h = jpeg_size(head)
            end
        end
        if not (w and h and w > 0 and h > 0) then
            w, h = nil, nil
        end
    end
    MEMO[path] = { w, h }
    return w, h
end

--- 测试钩子：清掉按路径的记忆（真实运行不需要）。
function M._reset_memo()
    MEMO = {}
end

return M
