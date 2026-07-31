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
-- Returns (ok:bool, wait_seconds:number).
-- max_requests == 0 (or nil) means unlimited.
function SourceManager.rate_limit_check(source_id, max_requests, window_seconds)
    if not max_requests or max_requests <= 0 then
        return true, 0
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
        return false, (wait > 0 and wait or 0)
    end
    table.insert(valid, now)
    RATE_LIMIT_TIMESTAMPS[source_id] = valid
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
