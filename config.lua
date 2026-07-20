-- FanQie Plugin Configuration
-- Copied from kindle-forge/public/config.js

return {
    cookie_string = "serial_uuid=1031015152114506443; serial_webid=1031015152114506443; passport_csrf_token=b015ffd9b6930d280c0fb11d37eb5372; passport_csrf_token_default=b015ffd9b6930d280c0fb11d37eb5372; s_v_web_id=verify_mqaofw34_5d0d1af7_cf3f_d17c_7b7f_f2dd0f934ab3; d_ticket=544fcb7d098f0de085d5c07ddbab0e6d62e74; n_mh=s2QV4omFysve5KKR5QoH3fScTpub5-lscewf289NsJ0; is_staff_user=false; has_biz_token=false; novel_web_id=1031015152114506443; csrf_session_id=1274318ce6a4c3583ea50dfba408f230; gfkadpd=2503,36144; passport_mfa_token=CjfEJwUKIOBL0Y5ncBXA0LdDF4rN8tE4TXJ5Lwi9YSB8G11jXpo0Jx3CftWCRxFC76PTD6Gawo8bGkoKPAAAAAAAAAAAAABQrg3PDrOnBSYmDv1%2F8DE2GLTPacjnIJqD6vXHEvuW7NXlRhmQHz7PfuLCOvjlgEUaMxC6qJcOGPax0WwgAiIBAxjaD2s%3D; odin_tt=84747e5cb44dd0ef395ae46bec55f7150b6464965fbb5ddcc628de18762c60915b6267068d1e0c7440c9e29ae6b13c886ec3ba8c6551218c2c46947418f5d285; passport_auth_status=2bf2236925933917deeba8f6ddce385a%2C; passport_auth_status_ss=2bf2236925933917deeba8f6ddce385a%2C; sid_guard=85c091352c40d59bd85de19b473d06c8%7C1784532716%7C5184000%7CFri%2C+18-Sep-2026+07%3A31%3A56+GMT; uid_tt=83f369977dd3a1184a6d25d582270ef1; uid_tt_ss=83f369977dd3a1184a6d25d582270ef1; sid_tt=85c091352c40d59bd85de19b473d06c8; sessionid=85c091352c40d59bd85de19b473d06c8; sessionid_ss=85c091352c40d59bd85de19b473d06c8; session_tlb_tag=sttt%7C2%7ChcCRNSxA1ZvYXeGbRz0GyP_________drFkkcpZ-8ND7qPUahROdxCA0QOnoNfLDvbM2Qd0tY3w%3D; sid_ucp_v1=1.0.0-KDc1MTgyYzE3NDIyZDQyMjk5YzIzNzVjMThlM2IwYjE5MDFlMzQ4OGYKHwieifC0-437BBDsnffSBhjHEyAMMLXT7Z8GOAJA8QcaAmhsIiA4NWMwOTEzNTJjNDBkNTliZDg1ZGUxOWI0NzNkMDZjOA; ssid_ucp_v1=1.0.0-KDc1MTgyYzE3NDIyZDQyMjk5YzIzNzVjMThlM2IwYjE5MDFlMzQ4OGYKHwieifC0-437BBDsnffSBhjHEyAMMLXT7Z8GOAJA8QcaAmhsIiA4NWMwOTEzNTJjNDBkNTliZDg1ZGUxOWI0NzNkMDZjOA; ttwid=1%7CulvHEkYVWV6mJYylFaFCrYXTTHCA5ewUvuzsUZa3gyw%7C1784532719%7C7b6c61b8efad4d3dcebf1dfc6cac69f14112dc28bb7ab913be0512ed6bbbeb3f",

    cookies = {
        ["serial_uuid"] = "",
        ["serial_webid"] = "",
        ["passport_csrf_token"] = "",
        ["passport_csrf_token_default"] = "",
        ["s_v_web_id"] = "",
        ["passport_mfa_token"] = "",
        ["d_ticket"] = "",
        ["odin_tt"] = "",
        ["n_mh"] = "",
        ["passport_auth_status"] = "",
        ["passport_auth_status_ss"] = "",
        ["sid_guard"] = "",
        ["uid_tt"] = "",
        ["uid_tt_ss"] = "",
        ["sid_tt"] = "",
        ["sessionid"] = "",
        ["sessionid_ss"] = "",
        ["session_tlb_tag"] = "",
        ["is_staff_user"] = "",
        ["has_biz_token"] = "",
        ["sid_ucp_v1"] = "",
        ["ssid_ucp_v1"] = "",
        ["novel_web_id"] = "",
        ["csrf_session_id"] = "",
        ["ttwid"] = "",
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
