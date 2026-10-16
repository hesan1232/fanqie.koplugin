-- FanQie Plugin Configuration
-- Copy this file to config.lua and modify the values below

return {
    -- Cookie 保底配置（可选）：
    --   * 未扫码登录：以下字段**整体**作为登录态。
    --   * 已扫码登录：只**补齐**扫码拿不到的键，绝不覆盖扫码结果（v2.16.3 起）。
    -- 正常使用无需填写，菜单 → 番茄小说 → 扫码登录即可自动获取并持久化 Cookie。
    --
    -- 🔴 但有一个必须手填的场景：**书城搜索**。
    --    搜索接口只认风控标识 `s_v_web_id`（只带 sessionid / ttwid 都会回
    --    「HTTP 200 + 0 字节」），而**扫码登录拿不到它**（登录页 / 二维码接口 /
    --    首页 / 搜索页都不下发）⇒ 表现就是「书架能看、搜索一直加载失败」。
    --    解决办法：在浏览器打开 fanqienovel.com 并登录，从开发者工具复制完整
    --    Cookie（含 s_v_web_id）填到下面的 cookie_string，再从插件菜单点
    --    「重新加载配置文件」；看到「已补入本地缺失的 Cookie: s_v_web_id」即生效。
    cookie_string = "",

    cookies = {
        ["ttwid"] = "",
        ["sessionid"] = "",
        -- 书城搜索必需（浏览器里 s_v_web_id=verify_… 那一项）
        ["s_v_web_id"] = "",
    },

    -- 书源说明：v2.4.0 起章节正文/段评统一走番茄官方 App 协议，
    -- 无需任何账号配置；以下仅保留通用偏好设置。

    sync = {
        pull_on_open = true,
        upload_on_close = true,
        -- 阅读中定期上传进度的间隔（分钟）：0 = 关闭。默认 3。
        -- 只在进度有前进时才真的发包；读到一半退出也不会丢。
        upload_interval_minutes = 3,
    },

    cache = {
        download_book_images = true,
        pre_download_chapters = 3,
        pre_download_groups = 2,

        -- 批量下载（预下载 / 整本下载）节流。番茄服务端对短时间高频抓取有风控特征，
        -- 逐章连打会放大该特征；下面这组取值对齐官方 App 协议的生产实现：
        -- 章间隔 1.0~1.8s（1.0 + 抖动）+ 每 20 章长休 6s。
        request_interval = 1.0,           -- 章间隔（秒）；0 = 完全关闭节流
        request_interval_jitter = 0.6,    -- 抖动上限（秒）；固定节奏本身就是风控特征
        request_batch_size = 20,          -- 每多少章长休一次；0 = 关闭长休
        request_batch_rest = 6.0,         -- 长休时长（秒）；0 = 关闭长休
    },

    -- 书架排序（也可在书架左上角菜单里点选；菜单里的选择优先于这里）
    shelf = {
        sort_order = "last_read",  -- last_read | title | progress | shelf_order
        sort_asc = false,          -- 留空 / nil = 用该排序键的默认方向
    },

    reading = {
        max_level = 1000,
        min_level = 1,
        auto_navigate = true,
        auto_navigate_delay = 0,
        disable_double_tap_navigation = false,
        enable_reflow = false,
        sync_bookmark = true,
        sync_annotation = true,
        sync_reading_progress = true,
        sync_calendar = true,
        sync_notebook = true,
    },

    debug = {
        dump_network = false,
        log_request = false,
        log_response = false,
        log_session = false,
        log_error = false,
        log_level = "warn",
    },

    layout = {
        reading_font_size = 0,
        reading_line_height = 0,
        reading_text_alignment = 0,
        reading_margin_top = 0,
        reading_margin_bottom = 0,
        reading_margin_left = 0,
        reading_margin_right = 0,
    },

    notification = {
        enabled = true,
        duration = 3,
    },

    experimental = {
        enable_new_sync = false,
        enable_new_api = false,
    },
}