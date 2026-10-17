--[[--
封面缓存的有效期与清理。

问题（v2.15.0 前）：两处封面缓存都只判 `file_exists` —— 一旦落盘就**永不失效**。
书城的书封面会随活动/版本换图，书架的封面也可能换，于是一台常用设备上：

    <下载目录>/store_covers/<book_id>.jpg   书城/榜单/搜索的封面
    <下载目录>/covers/<书名>.jpg            书架的封面

会只增不减。本模块提供三件事：

  * `is_fresh(path, days)` —— 命中缓存前先问一句「这张还新鲜吗」，过期就当没有；
  * `prune(dir, days)`     —— 删掉过期文件，返回删了几张 / 释放了多少字节；
  * `stats(dir)`           —— 目录占用（给菜单里的「清理（当前 12.3 MB / 86 张）」用）。

🔴 **只删这一层目录里的图片文件，绝不递归。** 封面目录旁边就是书库缓存
`<下载目录>/books/<book_id>/`（整本书的章节），递归删下去等于把用户下载的书全删了。
所以这里既不递归、也只认封面会用到的图片后缀。

`days = 0` 表示**永不失效**：这一档下 `is_fresh` 恒真、`prune` 什么都不删
（有些用户就是不想让封面翻来覆去地重下）。

段评图片（`comment_images/`）也走本模块，但单位是**分钟**（见
`COMMENT_TTL_*` / `is_fresh_minutes` / `prune_minutes`）—— 每次打开段评都会
按需重下，这个量级只增不减得更快。

@module fanqie.cover_cache
--]]

local lfs = require("libs/libkoreader-lfs")

local H = require("fanqie.helper")

-- `_` = gettext（原样返回），`T` = `ffi/util.template`（`%1` 占位符）。两者不能混用。
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

local CoverCache = {}

CoverCache.DAY = 86400

--- 有效期档位（天）；0 = 永不失效。对话框与菜单共用这一份。
--- 🔴 三处必须同口径：这里 / `settings.lua` 的 `COVER_CACHE_DAYS_DEFAULT` /
---    `main.lua` 里菜单的回退表（`CoverCache and CoverCache.DAYS_PRESETS or {…}`）。
---    默认 3 天：封面只是「看一眼就不再用」的东西，且书城的封面会随活动换图，
---    留着只会占本地空间（用户就是这么提的）。
CoverCache.DAYS_PRESETS = { 3, 7, 9, 30, 0 }
CoverCache.DAYS_DEFAULT = 3

-- ===== 段评图片（comment_images/）的分钟级有效期 =====
-- 🔴 默认值与 `settings.lua` 的 `COMMENT_IMAGE_TTL_DEFAULT` 同口径（改一处要改两处）。
--    默认 60 分钟（用户提的量级是「十分钟或者一个小时」）：段评图片每次打开
--    段评都会按需重下并覆盖同名文件，过期图在命中前就被当成「没有」。
CoverCache.MIN = 60
CoverCache.COMMENT_TTL_PRESETS = { 10, 30, 60, 180, 0 }
CoverCache.COMMENT_TTL_DEFAULT = 60

-- 只处理封面会用到的后缀。目录里若混进别的东西（残留的 .part / .tmp / 用户丢的文件），
-- 一律不碰 —— 清理缓存不是「清空目录」。
local IMAGE_SUFFIX = {
    jpg = true, jpeg = true, png = true, webp = true, gif = true, bmp = true,
}

--- 文件后缀（小写，无点）。取不到返回 ""。
function CoverCache.suffix(name)
    if type(name) ~= "string" then return "" end
    return (name:match("%.([%w]+)$") or ""):lower()
end

--- 纯逻辑：按「文件年龄（秒）」判断是否还在有效期内。
--- days <= 0 ⇒ 永不失效；age 不是数字 ⇒ 当新鲜（判不了就别乱失效）。
---@param age number|nil 文件年龄（秒）
---@param days number
---@return boolean
function CoverCache.is_fresh_age(age, days)
    days = tonumber(days) or 0
    if days <= 0 then return true end
    if type(age) ~= "number" then return true end
    return age < days * CoverCache.DAY
end

--- 文件最后修改时间（秒）。取不到返回 nil。
function CoverCache.mtime(path)
    if type(path) ~= "string" or path == "" then return nil end
    local ok, m = pcall(lfs.attributes, path, "modification")
    if not ok or type(m) ~= "number" or m <= 0 then return nil end
    return m
end

--- 文件年龄（秒）。取不到返回 nil。
function CoverCache.age(path, now)
    local m = CoverCache.mtime(path)
    if not m then return nil end
    local t = tonumber(now) or os.time()
    return math.max(0, t - m)
end

--- 缓存文件是否还在有效期内。
--- ⚠️ 本函数**不管文件在不在**（在不在由调用方的 `file_exists` 判）：取不到 mtime 时
---    保守返回 true —— 在 lfs 不可用的设备上判成过期，会变成「每次进书架都重下一遍」，
---    那比多留一张旧封面糟得多。
---@param path string
---@param days number 0 = 永不失效
---@param now number|nil 便于测试注入
---@return boolean
function CoverCache.is_fresh(path, days, now)
    days = tonumber(days) or 0
    if days <= 0 then return true end
    local age = CoverCache.age(path, now)
    if age == nil then return true end
    return CoverCache.is_fresh_age(age, days)
end

-- 🔴 `lfs.dir` 返回**两个**值 `(iter, dir_obj)`，必须都留着。
--    KOReader 用的是标准 LuaFileSystem：`dir_iter` 第一句就是
--    `luaL_checkudata(L, 1, DIR_METATABLE)` —— 目录句柄是**泛型 for 的 state**
--    （第二个返回值），不是迭代闭包的 upvalue。写成
--    `local ok, iter = pcall(lfs.dir, dir)` 再 `for name in iter do`，
--    state 就是 nil ⇒ 第一轮迭代直接抛
--    "bad argument #1 to 'for iterator' (directory metatable expected, got nil)"。
--    v2.16.0~v2.16.15 四处都是这么写的，于是 prune / clear / stats 在设备上
--    恒等于「什么都没做」：缓存管理三行占用显示「（读取占用失败）」、
--    清空缓存报 0 张、封面永不过期。
--    KOReader 自己的写法统一是 `local ok, iter, dir_obj = pcall(lfs.dir, p)`
--    + `for f in iter, dir_obj do`（见 frontend/util.lua:792、frontend/docsettings.lua:508）。
--    回归桩以前只返回一个闭包、也不校验 state ⇒ 这个形态错误一直假绿。

--- 目录占用：{ files = 张数, bytes = 字节 }。只统计图片后缀的文件。
function CoverCache.stats(dir)
    local out = { files = 0, bytes = 0 }
    if type(dir) ~= "string" or dir == "" then return out end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok or not iter then return out end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and IMAGE_SUFFIX[CoverCache.suffix(name)] then
            out.files = out.files + 1
            out.bytes = out.bytes + (H.file_size(dir .. "/" .. name) or 0)
        end
    end
    return out
end

--- 清理过期封面。
---@param dir string 封面目录（store_covers / covers）
---@param days number 0 = 永不失效（直接返回，什么都不删）
---@param now number|nil
---@return table { removed = n, bytes = 释放字节, kept = 保留数, failed = 删失败数 }
function CoverCache.prune(dir, days, now)
    local out = { removed = 0, bytes = 0, kept = 0, failed = 0 }
    days = tonumber(days) or 0
    if days <= 0 then return out end
    if type(dir) ~= "string" or dir == "" then return out end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)   -- dir_obj 必须留着，见 stats 上方说明
    if not ok or not iter then return out end

    local t = tonumber(now) or os.time()
    local limit = days * CoverCache.DAY
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and IMAGE_SUFFIX[CoverCache.suffix(name)] then
            local path = dir .. "/" .. name
            local m = CoverCache.mtime(path)
            if not m then
                out.kept = out.kept + 1
            elseif (t - m) >= limit then
                local size = H.file_size(path) or 0
                if H.delete_file(path) then
                    out.removed = out.removed + 1
                    out.bytes = out.bytes + size
                else
                    out.failed = out.failed + 1
                end
            else
                out.kept = out.kept + 1
            end
        end
    end
    return out
end

--- 清空该目录下**全部**封面（菜单里的「清空封面缓存」）。
--- 同样只删这一层的图片文件、不递归 —— 理由见文件头。
function CoverCache.clear(dir)
    local out = { removed = 0, bytes = 0, kept = 0, failed = 0 }
    if type(dir) ~= "string" or dir == "" then return out end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)   -- dir_obj 必须留着，见 stats 上方说明
    if not ok or not iter then return out end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and IMAGE_SUFFIX[CoverCache.suffix(name)] then
            local path = dir .. "/" .. name
            local size = H.file_size(path) or 0
            if H.delete_file(path) then
                out.removed = out.removed + 1
                out.bytes = out.bytes + size
            else
                out.failed = out.failed + 1
            end
        else
            out.kept = out.kept + 1
        end
    end
    return out
end

--- 自动清理：**一天最多一次**（上次时间戳存 settings）。
--- 每次开书架都扫一遍目录在小屏设备上是没必要的 I/O。
---@param settings table Settings 实例
---@param dirs table 封面目录列表
---@param now number|nil
---@return table|nil nil = 今天已经跑过了
function CoverCache.maybe_auto_prune(settings, dirs, now)
    if type(settings) ~= "table" or type(settings.get_cover_cache_days) ~= "function" then
        return nil
    end
    local t = tonumber(now) or os.time()
    local last = 0
    if type(settings.get_cover_cache_pruned_at) == "function" then
        last = tonumber(settings:get_cover_cache_pruned_at()) or 0
    end
    if last > 0 and (t - last) < CoverCache.DAY then return nil end

    local days = tonumber(settings:get_cover_cache_days()) or CoverCache.DAYS_DEFAULT
    local total = { removed = 0, bytes = 0, kept = 0, failed = 0 }
    for _i, dir in ipairs(dirs or {}) do
        local r = CoverCache.prune(dir, days, t)
        total.removed = total.removed + r.removed
        total.bytes = total.bytes + r.bytes
        total.kept = total.kept + r.kept
        total.failed = total.failed + r.failed
    end
    if type(settings.set_cover_cache_pruned_at) == "function" then
        settings:set_cover_cache_pruned_at(t)
    end
    return total
end

--- 段评图片有效期档位文案：分钟 / 整小时 / 永久（菜单与确认框共用）。
function CoverCache.minutes_label(minutes)
    minutes = math.floor(tonumber(minutes) or 0)
    if minutes <= 0 then return _("永久（不失效）") end
    if minutes < 60 then return T(_("%1 分钟"), tostring(minutes)) end
    if minutes % 60 == 0 then return T(_("%1 小时"), tostring(minutes / 60)) end
    return T(_("%1 分钟"), tostring(minutes))
end

--- 段评图缓存是否还在有效期内（分钟级；0 = 永不失效）。
--- 语义与 `is_fresh` 一致：取不到 mtime 时保守返回 true（判不了就别乱失效，
--- 否则会变成「每次开段评都把所有图重下一遍」）。
---@param path string
---@param minutes number 0 = 永不失效
---@param now number|nil 便于测试注入
---@return boolean
function CoverCache.is_fresh_minutes(path, minutes, now)
    minutes = tonumber(minutes) or 0
    if minutes <= 0 then return true end
    local age = CoverCache.age(path, now)
    if age == nil then return true end
    return age < minutes * CoverCache.MIN
end

--- 清理过期段评图（分钟级）。结构与 `prune` 相同，只是时间单位不同；
--- 同样只删这一层的图片文件、绝不递归（旁边就是章节缓存与书库）。
---@param dir string 段评图片目录（comment_images）
---@param minutes number 0 = 永不失效（直接返回，什么都不删）
---@param now number|nil
---@return table { removed = n, bytes = 释放字节, kept = 保留数, failed = 删失败数 }
function CoverCache.prune_minutes(dir, minutes, now)
    local out = { removed = 0, bytes = 0, kept = 0, failed = 0 }
    minutes = tonumber(minutes) or 0
    if minutes <= 0 then return out end
    if type(dir) ~= "string" or dir == "" then return out end
    local ok, iter, dir_obj = pcall(lfs.dir, dir)   -- dir_obj 必须留着，见 stats 上方说明
    if not ok or not iter then return out end

    local t = tonumber(now) or os.time()
    local limit = minutes * CoverCache.MIN
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." and IMAGE_SUFFIX[CoverCache.suffix(name)] then
            local path = dir .. "/" .. name
            local m = CoverCache.mtime(path)
            if not m then
                out.kept = out.kept + 1
            elseif (t - m) >= limit then
                local size = H.file_size(path) or 0
                if H.delete_file(path) then
                    out.removed = out.removed + 1
                    out.bytes = out.bytes + size
                else
                    out.failed = out.failed + 1
                end
            else
                out.kept = out.kept + 1
            end
        end
    end
    return out
end

--- 段评图自动清理：**一小时最多一次**（上次时间戳存 settings）。
--- 挂在「打开段评弹窗」上；过期图在命中前已被 `is_fresh_minutes` 当成
--- 「没有」（预取会重下并覆盖），这里只负责回收磁盘。
---@param settings table Settings 实例
---@param dirs table 段评图片目录列表
---@param now number|nil
---@return table|nil nil = 一小时内已经跑过了
function CoverCache.maybe_auto_prune_comment_images(settings, dirs, now)
    if type(settings) ~= "table"
        or type(settings.get_comment_image_ttl_minutes) ~= "function" then
        return nil
    end
    local t = tonumber(now) or os.time()
    local last = 0
    if type(settings.get_comment_images_pruned_at) == "function" then
        last = tonumber(settings:get_comment_images_pruned_at()) or 0
    end
    if last > 0 and (t - last) < 3600 then return nil end

    local minutes = tonumber(settings:get_comment_image_ttl_minutes())
        or CoverCache.COMMENT_TTL_DEFAULT
    local total = { removed = 0, bytes = 0, kept = 0, failed = 0 }
    for _i, dir in ipairs(dirs or {}) do
        local r = CoverCache.prune_minutes(dir, minutes, t)
        total.removed = total.removed + r.removed
        total.bytes = total.bytes + r.bytes
        total.kept = total.kept + r.kept
        total.failed = total.failed + r.failed
    end
    if type(settings.set_comment_images_pruned_at) == "function" then
        settings:set_comment_images_pruned_at(t)
    end
    return total
end

--- 字节数 → 人读文案（菜单里显示占用用）。沿用 1024 进制。
function CoverCache.human_bytes(n)
    n = tonumber(n) or 0
    if n < 0 then n = 0 end
    if n < 1024 then return tostring(math.floor(n)) .. " B" end
    if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
    if n < 1024 * 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
    return string.format("%.2f GB", n / (1024 * 1024 * 1024))
end

--- 有效期档位文案（菜单 / 对话框共用）。
function CoverCache.days_label(days)
    days = math.floor(tonumber(days) or 0)
    if days <= 0 then return _("永久（不失效）") end
    return T(_("%1 天"), tostring(days))
end

return CoverCache
