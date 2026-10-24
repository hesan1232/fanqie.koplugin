--[[--
番茄阅读设备身份：本机生成画像，经 device_register 换取 device_id/install_id。
移植自 book.koplugin/source/fanqie/reading/device.lua，改为本地 Client 同步 HTTP。
禁止复用别人的 did；每台 KOReader 安装各自持久化一份。

@module fanqie.reading.device
--
-- 版权与许可：
--   Copyright (C) 月读 (AnkioTomas/moon) contributors
--   本文件移植自月读的 KOReader 插件（book.koplugin），原作以 GNU GPLv3 发布。
--   本仓库整体以 GPL-3.0-only 分发，全文见根目录 LICENSE，
--   上游来源清单见 THIRD_PARTY_NOTICES.txt。
--]]

local Aes = require("fanqie.reading.aes")
local Crypto = require("fanqie.reading.crypto")
local bit = require("bit")

local Device = {}

local REGISTER_HOST = "log.snssdk.com"
local REGISTER_PATH = "/service/2/device_register/"
local TIMEOUT = 20

-- 画像模板（不含服务端签发的 id）。
local PROFILE_TEMPLATE = {
    channel = "43536163a",
    version_code = "73733",
    version_name = "7.3.7.33",
    device_type = "P30",
    device_brand = "HUAWEI",
    language = "zh",
    os_api = "31",
    os_version = "12",
    resolution = "1280*720",
    dpi = "240",
    host_abi = "arm64-v8a",
    rom_version = "S643.217451.03386707",
}

local function uuid4()
    local raw = Crypto.urandom(16)
    local b = { raw:byte(1, 16) }
    b[7] = bit.bor(bit.band(b[7], 0x0f), 0x40)
    b[9] = bit.bor(bit.band(b[9], 0x3f), 0x80)
    return string.format(
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8],
        b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16])
end

---@return table 本地画像（含 cdid/openudid，尚无 device_id）
function Device.newLocalProfile()
    local out = {}
    for k, v in pairs(PROFILE_TEMPLATE) do
        out[k] = v
    end
    out.cdid = uuid4()
    out.openudid = Aes.to_hex(Crypto.urandom(8))
    out.clientudid = uuid4()
    return out
end

---@param src table|nil
---@return table|nil
function Device.normalize(src)
    if type(src) ~= "table" then return nil end
    local profile = type(src.device_profile) == "table" and src.device_profile or src
    local device_id = tostring(src.device_id or "")
    local install_id = tostring(src.install_id or "")
    if device_id == "" or install_id == "" then
        return nil
    end
    local out = Device.newLocalProfile()
    for k, v in pairs(PROFILE_TEMPLATE) do
        if profile[k] ~= nil and tostring(profile[k]) ~= "" then
            out[k] = tostring(profile[k])
        end
    end
    if profile.cdid and profile.cdid ~= "" then out.cdid = tostring(profile.cdid) end
    if profile.openudid and profile.openudid ~= "" then out.openudid = tostring(profile.openudid) end
    if profile.clientudid and profile.clientudid ~= "" then
        out.clientudid = tostring(profile.clientudid)
    elseif src.clientudid and src.clientudid ~= "" then
        out.clientudid = tostring(src.clientudid)
    end
    out.device_id = device_id
    out.install_id = install_id
    out.version_code = tostring(out.version_code or PROFILE_TEMPLATE.version_code)
    out.version_name = tostring(out.version_name or PROFILE_TEMPLATE.version_name)
    return out
end

--- 持久化到用户设置（跨会话复用，避免重复注册）。
---@param settings table
---@param device table
local function persist(settings, device)
    settings:set("reading_device", {
        install_id = device.install_id,
        device_id = device.device_id,
        clientudid = device.clientudid,
        device_profile = {
            channel = device.channel,
            version_code = device.version_code,
            version_name = device.version_name,
            device_type = device.device_type,
            device_brand = device.device_brand,
            language = device.language,
            os_api = device.os_api,
            os_version = device.os_version,
            resolution = device.resolution,
            dpi = device.dpi,
            host_abi = device.host_abi,
            cdid = device.cdid,
            openudid = device.openudid,
            rom_version = device.rom_version,
        },
    })
    settings:flush()
end

---@param client table
---@param profile table
---@return string url, string body, table headers
local function buildRegisterRequest(client, profile)
    local now = os.time() * 1000 + math.random(0, 999)
    local openudid = profile.openudid
    local cdid = profile.cdid
    local qs = table.concat({
        "ac=wifi",
        "channel=" .. tostring(profile.channel),
        "aid=1967",
        "app_name=novelapp",
        "version_code=" .. tostring(profile.version_code),
        "version_name=" .. tostring(profile.version_name),
        "device_platform=android",
        "ssmix=a",
        "device_type=" .. tostring(profile.device_type),
        "device_brand=" .. tostring(profile.device_brand),
        "language=" .. tostring(profile.language),
        "os_api=" .. tostring(profile.os_api),
        "os_version=" .. tostring(profile.os_version),
        "openudid=" .. tostring(openudid),
        "manifest_version_code=" .. tostring(profile.version_code),
        "resolution=" .. tostring(profile.resolution),
        "dpi=" .. tostring(profile.dpi),
        "update_version_code=" .. tostring(profile.version_code),
        "_rticket=" .. tostring(now),
        "cdid=" .. tostring(cdid),
    }, "&")
    local body = {
        magic_tag = "ss_app_log",
        header = {
            display_name = "番茄小说",
            update_version_code = tonumber(profile.version_code) or 73733,
            manifest_version_code = tonumber(profile.version_code) or 73733,
            aid = 1967,
            channel = profile.channel,
            package = "com.dragon.read",
            app_version = profile.version_name,
            version_code = tonumber(profile.version_code) or 73733,
            sdk_version = "3.7.2.cn",
            os = "Android",
            os_version = profile.os_version,
            os_api = tonumber(profile.os_api) or 31,
            device_model = profile.device_type,
            device_brand = profile.device_brand,
            device_manufacturer = profile.device_brand,
            cpu_abi = profile.host_abi,
            density_dpi = tonumber(profile.dpi) or 240,
            resolution = (tostring(profile.resolution or "")):gsub("%*", "x"),
            language = profile.language,
            timezone = 8,
            access = "wifi",
            not_request_sender = 0,
            rom_version = profile.rom_version,
            cdid = cdid,
            openudid = openudid,
            clientudid = profile.clientudid or uuid4(),
            region = "CN",
            tz_name = "Asia/Shanghai",
            tz_offset = 28800,
            sim_region = "cn",
            req_id = uuid4(),
            apk_first_install_time = now - 86400000,
            is_system_app = 0,
            sdk_flavor = "china",
        },
        _gen_time = now,
    }
    local ua = string.format(
        "com.dragon.read/%s (Linux; U; Android %s; zh_CN; %s; Build/%s;tt-ok/3.12.13.4-tiktok)",
        profile.version_code, profile.os_version, profile.device_type,
        tostring(profile.rom_version):match("^[^%+]+") or "S643")
    return "https://" .. REGISTER_HOST .. REGISTER_PATH .. "?" .. qs,
        client:json_encode(body),
        {
            ["Content-Type"] = "application/json; charset=utf-8",
            ["User-Agent"] = ua,
            ["Accept-Encoding"] = "identity",
        }
end

-- 注册响应可能把 19 位编号写成 JSON 裸数字。解码前先补引号，避免 rapidjson
-- 按 double 舍入，之后把失真的设备身份持久化。只处理这两个已知编号字段。
local function quote_bigint_ids(text)
    if type(text) ~= "string" then return text end
    for _i, key in ipairs({ "device_id", "install_id" }) do
        local pattern = '("' .. key .. '"%s*:%s*)(%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d+)'
        -- 整段返回会再次经过 gsub 的 % 展开；只替换数字段，避免 JSON 其它
        -- 字段里的百分号被误解释，也不要把超长数字当普通 number 处理。
        text = text:gsub(pattern, "%1\"%2\"")
    end
    return text
end

--- 同步向 log.snssdk.com 注册，拿到本机专属 device_id/install_id。
---@param client table 本地 HTTP 客户端（Client 实例）
---@param settings table
---@return table|nil device, string|nil err
function Device.register(client, settings)
    local profile = Device.newLocalProfile()
    local url, body, headers = buildRegisterRequest(client, profile)
    local text, code = client:request({
        url = url,
        method = "POST",
        headers = headers,
        body = body,
        timeout = TIMEOUT,
    })
    if not code then
        return nil, "device_register 请求失败（请放行 log.snssdk.com）"
    end
    if code < 200 or code >= 300 then
        return nil, "device_register HTTP " .. tostring(code)
    end
    if not text or text == "" then
        return nil, "device_register 空响应"
    end
    local ok, data = pcall(function() return client:json_decode(quote_bigint_ids(text)) end)
    if not ok or type(data) ~= "table" then
        return nil, "device_register 响应无效"
    end
    local device_id = tostring(data.device_id_str or data.device_id or "")
    local install_id = tostring(data.install_id_str or data.install_id or "")
    if device_id == "" or install_id == "" then
        return nil, "device_register 未返回 device_id"
    end
    profile.device_id = device_id
    profile.install_id = install_id
    persist(settings, profile)
    local ok_logger, logger = pcall(require, "fanqie.logger")
    if ok_logger and logger then
        logger.info("[FanQie] device_register ok", "did=" .. device_id, "iid=" .. install_id)
    end
    return profile
end

--- 已有身份直接返回；否则同步注册。
---@param client table
---@param settings table
---@return table|nil device, string|nil err
function Device.ensure(client, settings)
    local cached = Device.get(settings)
    if cached then
        return cached
    end
    return Device.register(client, settings)
end

--- 同步取已落盘身份；没有则返回 nil（调用方应走 ensure）。
---@param settings table
---@return table|nil
function Device.get(settings)
    return Device.normalize(settings:get("reading_device", nil))
end

return Device
