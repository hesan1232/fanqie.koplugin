-- 给现有 KOReader 字体追加 emoji 回退，不改变正文字体、字号或仿粗。
-- 字体构造方式参考 seaneasysaid/fanqie.koplugin-fixed 的 review_popup/face_factory.lua；
-- 这里只保留评论视图所需的一小段适配，不替换 KOReader 的默认回退链。
--
-- ⚠️ 缓存键必须用**原字体的 hash**：字形缓存的键是 face.hash + bold，
--    克隆后若改成新 hash，同一字号会与其它视图的字形互相串用。

local ok_freetype, Freetype = pcall(require, "ffi/freetype")
local H = require("fanqie.helper")

local M = { path = nil, checked = false, cache = {} }
local FONT_REL = "fonts/NotoEmoji-Regular.ttf"
local PLUGIN_DIR = "fanqie.koplugin"

local function candidate_paths()
    local list = {}
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if ok_ds and DataStorage then
        local ok_full, data_dir = pcall(DataStorage.getFullDataDir, DataStorage)
        if ok_full and type(data_dir) == "string" and data_dir ~= "" then
            list[#list + 1] = data_dir .. "/plugins/" .. PLUGIN_DIR .. "/" .. FONT_REL
        end
        local ok_rel, rel_dir = pcall(DataStorage.getDataDir, DataStorage)
        if ok_rel and type(rel_dir) == "string" and rel_dir ~= "" then
            list[#list + 1] = rel_dir .. "/plugins/" .. PLUGIN_DIR .. "/" .. FONT_REL
        end
    end
    -- 兜底：KOReader 以插件目录为工作目录启动时的相对路径
    list[#list + 1] = "plugins/" .. PLUGIN_DIR .. "/" .. FONT_REL
    if H.get_data_dir then
        local ok, base = pcall(H.get_data_dir)
        if ok and type(base) == "string" then
            list[#list + 1] = base:gsub("/fanqie$", "") .. "/plugins/" .. PLUGIN_DIR .. "/" .. FONT_REL
        end
    end
    return list
end

local function font_path()
    if M.checked then return M.path end
    M.checked = true
    for _i, path in ipairs(candidate_paths()) do
        if H.file_exists(path) then M.path = path break end
    end
    local ok_Log, Log = pcall(require, "fanqie.logger")
    if ok_Log and Log then
        if M.path then
            Log.info("[emoji] 表情字体: " .. M.path)
        else
            Log.warn("[emoji] 未找到表情字体，段评表情将显示为占位符")
        end
    end
    return M.path
end

local function make_face(path, size)
    local ok, ftsize = pcall(Freetype.newFaceSize, path, size)
    if not ok or not ftsize then return nil end
    local face = {
        orig_font = path,
        realname = path,
        size = size,
        orig_size = size,
        ftsize = ftsize,
        hash = path .. "|" .. tostring(size),
        hb_features = { "+kern", "+liga" },
        fallbacks = {},
    }
    -- KOReader 的 _completeFaceProperties 会给回退 face 补这一项（xtext 侧读取）；
    -- 手建 face 也要补，否则仿粗路径缺少强度值。
    if type(ftsize.getEmboldenHalfStrength) == "function" then
        local ok_emb, half = pcall(ftsize.getEmboldenHalfStrength, ftsize, 0.18)
        if ok_emb then face.embolden_half_strength = half end
    end
    face.getFallbackFont = function(num)
        if not num or num == 0 then return face end
        return face.fallbacks[num] or false
    end
    return face
end

--- 返回追加了 emoji 的字体副本；字体或 FreeType 不可用时返回原 face。
function M.with_fallback(face)
    if type(face) ~= "table" or not face.ftsize or not ok_freetype then return face end
    local path = font_path()
    if not path then return face end
    -- 🔴 键用原字体的 hash：克隆体与原件必须共享字形缓存口径
    local key = tostring(face.hash or face.orig_font or "") .. "|" .. tostring(face.size)
    if M.cache[key] then return M.cache[key].clone end

    local emoji = make_face(path, face.size)
    if not emoji then return face end
    local clone = {}
    for k, v in pairs(face) do clone[k] = v end
    clone.fallbacks = {}
    local original_fallback = face.getFallbackFont
    local original_fallbacks = face.fallbacks
    local emoji_index
    clone.getFallbackFont = function(num)
        if not num or num == 0 then return clone end
        if clone.fallbacks[num] ~= nil then return clone.fallbacks[num] end
        if emoji_index and num > emoji_index then
            clone.fallbacks[num] = false
            return false
        end
        local fallback
        if type(original_fallback) == "function" then
            local ok, value = pcall(original_fallback, num)
            if ok then fallback = value end
        elseif type(original_fallbacks) == "table" then
            fallback = original_fallbacks[num]
        end
        if fallback then
            clone.fallbacks[num] = fallback
            return fallback
        end
        -- 原默认链结束后才放 emoji；xtext 最多使用 16 个字体（含主字体）。
        if not emoji_index then
            if num > 15 then
                emoji_index = 15
                clone.fallbacks[num] = false
                return false
            end
            emoji_index = num
        end
        if num == emoji_index then
            clone.fallbacks[num] = emoji
            return emoji
        end
        clone.fallbacks[num] = false
        return false
    end
    M.cache[key] = { clone = clone }
    return clone
end

return M
