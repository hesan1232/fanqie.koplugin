-- FanQie Plugin Configuration
-- Copy this file to config.lua and modify the values below

return {
    cookie_string = "",

    cookies = {
        ["ttwid"] = "",
        ["sessionid"] = "",
    },

    fanqie_api_endpoint = "http://101.35.133.34:5000",

    fanqie_proxy_base = "",

    sync = {
        pull_on_open = true,
        upload_on_close = true,
    },

    cache = {
        download_book_images = true,
        pre_download_chapters = 3,
        pre_download_groups = 2,
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