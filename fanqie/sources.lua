-- FanQie Plugin Source Manager
-- Central registry + rate limiter + active-source resolution for book sources.
-- Replaces the hardcoded "qingtian -> official" fallback with a generic
-- scheduler that iterates user-configured sources in priority order.
--
-- Usage:
--   local SM = require("fanqie.sources")
--   local active = SM.get_active_sources(settings)
--   for _, src in ipairs(active) do ... end

local H = require("fanqie.helper")

local SourceManager = {}

-- Static registry: source_id -> metadata (no user config here).
-- Used for menu display, configuration checks and fetcher dispatch.
SourceManager.REGISTRY = {
    qingtian = {
        name = "晴天聚合",
        configurable = true,        -- has editable server/account fields
    },
    dahuilang = {
        name = "大灰狼",
        configurable = true,       -- has editable server URL + token
    },
    official = {
        name = "官方API（解码）",
        configurable = false,
    },
}

-- Module-level rate-limit state: source_id -> array of timestamps.
-- Module-level so it persists across Client instances (matches legacy behavior).
local RATE_LIMIT_TIMESTAMPS = {}

local function trim(s)
    if s == nil then return "" end
    return H.trim(tostring(s))
end

-- Check (and record) one request against the rate limit for a source.
-- Returns (ok:bool, wait_seconds:number, recorded_ts:number|nil).
--   recorded_ts: 本次记录的时间戳（仅 ok=true 且该源启用了限流时非 nil）。
--   子进程无法把记录写回父进程，需把 recorded_ts 经返回值带回父进程合并。
-- max_requests == 0 (or nil) means unlimited.
function SourceManager.rate_limit_check(source_id, max_requests, window_seconds)
    if not max_requests or max_requests <= 0 then
        return true, 0, nil
    end
    window_seconds = window_seconds or 30
    local now = os.time()
    local stamps = RATE_LIMIT_TIMESTAMPS[source_id] or {}
    -- Drop expired timestamps
    local valid = {}
    for _, ts in ipairs(stamps) do
        if now - ts < window_seconds then
            table.insert(valid, ts)
        end
    end
    if #valid >= max_requests then
        local oldest = valid[1]
        local wait = window_seconds - (now - oldest)
        return false, (wait > 0 and wait or 0), nil
    end
    table.insert(valid, now)
    RATE_LIMIT_TIMESTAMPS[source_id] = valid
    return true, 0, now
end

-- Merge rate-limit timestamps recorded in a subprocess back into parent state.
-- 子进程 fork 出 RATE_LIMIT_TIMESTAMPS 的副本，在其中 rate_limit_check 记录的
-- 时间戳会随子进程退出而丢失。work_func 把这些时间戳经 rate_info 带回父进程，
-- 由 on_done 调用本函数合并，使父进程后续的限流判断看到真实计数。
-- recorded: array of { source_id = string, ts = number }
function SourceManager.merge_rate_limit_timestamps(recorded)
    if not recorded then return end
    for _, entry in ipairs(recorded) do
        if entry and entry.source_id and entry.ts then
            local stamps = RATE_LIMIT_TIMESTAMPS[entry.source_id] or {}
            -- 去重，避免同一时间戳被合并多次
            local found = false
            for _, ts in ipairs(stamps) do
                if ts == entry.ts then found = true break end
            end
            if not found then
                table.insert(stamps, entry.ts)
                RATE_LIMIT_TIMESTAMPS[entry.source_id] = stamps
            end
        end
    end
end

-- Peek (query only, no record) whether a request would be allowed right now.
-- Returns (would_ok:bool, wait_seconds:number).
-- Used by the download loop to actively wait for the window to recover before
-- issuing the actual fetch (which records the timestamp via rate_limit_check).
function SourceManager.rate_limit_peek(source_id, max_requests, window_seconds)
    if not max_requests or max_requests <= 0 then
        return true, 0
    end
    window_seconds = window_seconds or 30
    local now = os.time()
    local stamps = RATE_LIMIT_TIMESTAMPS[source_id] or {}
    local valid = {}
    for _, ts in ipairs(stamps) do
        if now - ts < window_seconds then table.insert(valid, ts) end
    end
    if #valid >= max_requests then
        local wait = window_seconds - (now - valid[1])
        return false, (wait > 0 and wait or 0)
    end
    return true, 0
end

-- Reset rate-limit state for a source (used after logout / config change).
function SourceManager.rate_limit_reset(source_id)
    RATE_LIMIT_TIMESTAMPS[source_id] = nil
end

-- Check whether a source is configured (skipped if not).
function SourceManager.is_configured(source_id, cfg, settings)
    cfg = cfg or {}
    if source_id == "qingtian" then
        local server = trim(cfg.server_url)
        local token  = trim(cfg.token)
        local user   = trim(cfg.username)
        return server ~= "" and (token ~= "" or user ~= "")
    elseif source_id == "dahuilang" then
        local server = trim(cfg.server_url)
        local token  = trim(cfg.token)
        local user   = trim(cfg.username)
        local key    = trim(cfg.key)
        return server ~= "" and (token ~= "" or key ~= "" or user ~= "")
    elseif source_id == "official" then
        -- Official chapter_content_url is public; always available as fallback.
        return true
    end
    return false
end

-- Return enabled + configured + non-dev sources, sorted by order ascending.
-- Each entry: { id=string, config=table, meta=table }
function SourceManager.get_active_sources(settings)
    local sources_cfg = settings:get("sources", {})
    local list = {}
    for source_id, meta in pairs(SourceManager.REGISTRY) do
        local cfg = sources_cfg[source_id]
        if cfg and cfg.enabled ~= false and not meta.in_development then
            if SourceManager.is_configured(source_id, cfg, settings) then
                table.insert(list, { id = source_id, config = cfg, meta = meta })
            end
        end
    end
    table.sort(list, function(a, b)
        return (a.config.order or 999) < (b.config.order or 999)
    end)
    return list
end

-- Return all registered sources (including disabled / dev / unconfigured),
-- sorted by order ascending. For menu display.
function SourceManager.get_all_sources(settings)
    local sources_cfg = settings:get("sources", {})
    local list = {}
    for source_id, meta in pairs(SourceManager.REGISTRY) do
        local cfg = sources_cfg[source_id] or {}
        table.insert(list, { id = source_id, config = cfg, meta = meta })
    end
    table.sort(list, function(a, b)
        return (a.config.order or 999) < (b.config.order or 999)
    end)
    return list
end

return SourceManager
