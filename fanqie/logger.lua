-- FanQie Plugin Logger
-- Wraps KOReader's logger with configurable debug level and file output.
-- Usage:
--   local Log = require("lib.logger")
--   Log.debug("some", "details")  -- only shown when developer_logs=true
--   Log.info("always shown")
--   Log.warn("warning")
--   Log.error("error")

local ok_ko_logger, ko_logger = pcall(require, "logger")
if not ok_ko_logger then
    ko_logger = nil
end

local Log = {}
local LOG_MODULE = "[FanQie]"

-- State (module-level, shared across instances)
local _settings = nil
local _log_file_path = nil

-- Max log file size before rotation (512 KB)
local MAX_LOG_SIZE = 512 * 1024

function Log.init(settings)
    _settings = settings
    if settings and settings.cache_dir then
        local cache_dir = settings.cache_dir
        local parent_dir = cache_dir:match("^(.*)/[^/]+$") or cache_dir
        _log_file_path = parent_dir .. "/fanqie.log"
    elseif settings and settings.data_dir then
        _log_file_path = settings.data_dir .. "/fanqie.log"
    end
end

local function is_debug_enabled()
    if not _settings then return false end
    local advanced = _settings:get("advanced", {})
    return advanced.developer_logs == true
end

-- Rotate log file if it exceeds MAX_LOG_SIZE
local function rotate_if_needed()
    if not _log_file_path then return end
    local lfs = require("libs/libkoreader-lfs")
    local ok, attr = pcall(function()
        return lfs.attributes(_log_file_path)
    end)
    if ok and attr and attr.size and attr.size > MAX_LOG_SIZE then
        local old_path = _log_file_path .. ".old"
        os.remove(old_path)
        os.rename(_log_file_path, old_path)
    end
end

local function format_args(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" then
            table.insert(parts, v)
        else
            table.insert(parts, tostring(v))
        end
    end
    return table.concat(parts, " ")
end

local function write_to_file(level, message)
    if not _log_file_path then return end
    rotate_if_needed()
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local line = string.format("[%s] %s %s: %s\n", timestamp, LOG_MODULE, level, message)
    local file = io.open(_log_file_path, "a")
    if file then
        file:write(line)
        file:close()
    end
end

function Log.debug(...)
    if not is_debug_enabled() then return end
    local message = format_args(...)
    if koLogger then
        koLogger.debug(LOG_MODULE, message)
    end
    write_to_file("DEBUG", message)
end

function Log.info(...)
    local message = format_args(...)
    if koLogger then
        koLogger.info(LOG_MODULE, message)
    end
    write_to_file("INFO", message)
end

function Log.warn(...)
    local message = format_args(...)
    if koLogger then
        koLogger.warn(LOG_MODULE, message)
    end
    write_to_file("WARN", message)
end

function Log.error(...)
    local message = format_args(...)
    if koLogger then
        koLogger.err(LOG_MODULE, message)
    end
    write_to_file("ERROR", message)
end

-- Get log file path for menu display
function Log.get_log_file_path()
    return _log_file_path
end

-- Clear log file
function Log.clear_log()
    if _log_file_path then
        os.remove(_log_file_path)
        os.remove(_log_file_path .. ".old")
    end
end

return Log
