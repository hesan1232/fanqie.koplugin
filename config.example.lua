-- FanQie Plugin Configuration
-- Copy this file to config.lua and modify the values below

return {
    -- Cookie 保底配置（可选）：扫码登录优先，以下字段仅在未扫码时作为 fallback。
    -- 正常使用无需填写，菜单 → 番茄小说 → 扫码登录即可自动获取并持久化 Cookie。
    -- 如需手动填写：从浏览器复制 Cookie 字符串填入 cookie_string，
    -- 或在 cookies 表里填入 ttwid / sessionid 等键值。
    cookie_string = "",

    cookies = {
        ["ttwid"] = "",
        ["sessionid"] = "",
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