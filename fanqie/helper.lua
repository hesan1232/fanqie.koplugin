local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local DataStorage = require("datastorage")

local M = {}

M.is_str = function(s)
    return type(s) == "string"
end

M.is_num = function(n)
    return type(n) == "number"
end

M.is_tbl = function(t)
    return type(t) == "table"
end

M.is_func = function(f)
    return type(f) == "function"
end

M.is_boolean = function(b)
    return type(b) == "boolean"
end

M.if_nil = function(a, b)
    if a == nil then
        return b
    end
    return a
end

M.trim = function(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

M.join_path = function(...)
    local args = {...}
    local path = ""
    for _, p in ipairs(args) do
        if p then
            path = path .. "/" .. p
        end
    end
    return path:gsub("/+", "/")
end

M.get_cache_path = function(book_id)
    local base_dir = DataStorage:getFullDataDir() .. "/fanqie"
    return M.join_path(base_dir, book_id)
end

M.make_dir = function(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    util.makePath(path)
    return lfs.attributes(path, "mode") == "directory"
end

M.file_exists = function(path)
    if not M.is_str(path) then return false end
    return lfs.attributes(path, "mode") == "file"
end

M.dir_exists = function(path)
    if not M.is_str(path) then return false end
    return lfs.attributes(path, "mode") == "directory"
end

M.delete_file = function(path)
    if M.file_exists(path) then
        return os.remove(path)
    end
    return true
end

M.write_file = function(path, data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        M.make_dir(dir)
    end
    local file, err = io.open(path, "wb")
    if not file then
        error(err)
    end
    file:write(data)
    file:close()
end

M.delete_dir = function(path)
    if not M.dir_exists(path) then return true end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = M.join_path(path, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                M.delete_dir(full_path)
            else
                os.remove(full_path)
            end
        end
    end
    return lfs.rmdir(path)
end

M.table_size = function(t)
    if not M.is_tbl(t) then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

M.split = function(str, sep)
    local result = {}
    local pattern = string.format("([^%s]+)", sep)
    for part in string.gmatch(str, pattern) do
        table.insert(result, part)
    end
    return result
end

M.url_encode = function(str)
    if not str then return "" end
    str = tostring(str)
    return str:gsub("[^a-zA-Z0-9%-_.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

return M