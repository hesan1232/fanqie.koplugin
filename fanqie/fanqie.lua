local H = require("fanqie.helper")

local FanQie = {}

FanQie.USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
FanQie.MOBILE_UA = "Mozilla/5.0 (Linux; Android 10; Pixel 3) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
FanQie.BASE_URL = "https://fanqienovel.com"
-- App 端（api*.fqnovel.com）域名与 UA（v2.16.0）。
-- 🔴 与网页域名是**两套体系**：榜单主接口 /reading/bookapi/bookmall/cell/change/v1/
-- 只存在于 App 域，网页域同名路径不存在。实测（2026-10-16，见下）：
--   * 免签名、免 cookie（只认 aid=1967 等公共参数），男频 11 榜 + 出版物 6 榜全通；
--   * 连打 40 次无一次失败 ⇒ **没有限流**（曾因探针只读 `data.book_data`、
--     漏了真正的 `data.cell_view.book_data`，把好接口误判成「被 IP 软封」）；
--   * 分页无效：offset=30/60 返回与首页**完全相同**的 30 本（交集 30/30），
--     `has_more=true` 是乐观值 ⇒ 榜单一律单页、不做翻页；
--   * 未知 algo_type **不报错**，静默退化成默认榜（135→推荐榜、116→完本榜）
--     ⇒ 解析时必须校验响应 `cell_name` 与期望榜名一致。
FanQie.APP_BASE_URL = "https://api5-normal-lf.fqnovel.com"
FanQie.APP_UA = "com.dragon.read/6.5.3.32 (Linux; U; Android 13; zh_CN; VDE-AL10; Build/TP1A.220624.014;tt-ok/3.10.0.2)"
-- 手机端封面 CDN：只要图片路径（novel-pic/xxx），**无需签名、长期有效**。
-- 与 book.koplugin 的 FanQie.mobileCover / kindle-forge 的
-- src/utils/fanqieCover.js 保持一致。
FanQie.MOBILE_COVER_CDN = "https://p6-novel.byteimg.com"
FanQie.QINGTIAN_DEFAULT_URL = "https://v1.gyks.cf/"

function FanQie.normalize_base(base)
    local b = H.trim(base)
    if not b:match("^http") then
        b = "https://" .. b
    end
    if b:sub(-1) == "/" then
        b = b:sub(1, -2)
    end
    return b
end

function FanQie.qt_login_url(server_url)
    return FanQie.normalize_base(server_url) .. "/login_api"
end

function FanQie.qt_content_url(server_url)
    return FanQie.normalize_base(server_url) .. "/content"
end

function FanQie.make_shelf_params()
    return {
        aid = 1967,
        iid = 0,
        version_code = 57700,
        update_version_code = 57700,
    }
end

function FanQie.shelf_url()
    return FanQie.BASE_URL .. "/reading/bookapi/bookshelf/info/v:version/"
end

-- 「这本书在不在书架里」——**唯一可靠的判据**。
-- 🔴 2026-10-14 实测更正：旧结论写的「data 恒为 1，无法判断」是**因为没带 book_id**
--    （缺参数时服务端回 `{"code":100103,"message":"book_id 无效","data":null}`，
--     拿这个 null 当成「恒 1」是误读）。带上 book_id 后语义完全正确：
--     在架 → data:1；不在架 → data:0；book_id=abc → 100103；不带 Cookie → 101108 无用户信息。
-- 参数只要 `book_id` 就够（aid/iid 也可省），这里统一带上 make_shelf_params 保持同款。
function FanQie.shelf_check_url(book_id)
    local p = FanQie.make_shelf_params()
    return FanQie.BASE_URL .. "/reading/bookapi/bookshelf/check/v:version/"
        .. "?aid=" .. tostring(p.aid)
        .. "&iid=" .. tostring(p.iid)
        .. "&version_code=" .. tostring(p.version_code)
        .. "&update_version_code=" .. tostring(p.update_version_code)
        .. "&book_id=" .. H.url_encode(tostring(book_id or ""))
end

function FanQie.bookshelf_multidetail_url()
    return FanQie.BASE_URL .. "/api/bookshelf/multidetail"
end

function FanQie.progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/progress"
end

function FanQie.update_progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/update_progress"
end

function FanQie.directory_url(book_id)
    return FanQie.BASE_URL .. "/api/reader/directory/detail?bookId=" .. H.url_encode(book_id)
end

-- [已弃用] 旧网页正文接口：POST/GET /api/reader/chapter/content。
-- 番茄已对该接口启用风控，现返回 HTTP 515，官方源已改用 App reading 协议
-- （见 fanqie/reading.lua）。此函数保留仅作参考，不再被调用。
function FanQie.chapter_content_url(book_id, item_id)
    return FanQie.BASE_URL .. "/api/reader/chapter/content?book_id=" .. H.url_encode(book_id) .. "&item_id=" .. H.url_encode(item_id)
end

function FanQie.reader_url(item_id)
    return "https://fanqienovel.com/reader/" .. item_id
end

--- 把番茄封面地址收敛为**无签名**的手机端 CDN 地址。
--
-- App / web 接口返回的 thumb_url 是带签名的，形如
--   https://p9-novel-sign.byteimg.com/novel-pic/xxx~tplv-resize:225:300.image?x-expires=..&x-signature=..
-- x-expires 只给到次日，签名一旦过期，以该 URL 回源必然 403
-- （实测：签名 CDN 403 / text-html，无签名 p6 CDN 200 / image/jpeg），
-- 书架封面直接变空白。
--
-- 幂等：已是无签名地址时结果不变；路径无法识别但是完整 URL（外部地址 /
-- 用户自定义封面）时原样返回，避免把可用地址改坏。
function FanQie.mobile_cover(thumb)
    if type(thumb) ~= "string" or thumb == "" then
        return nil
    end
    local path = thumb:match("(novel%-pic/[^~%?#]+)")
        or thumb:match("(novel%-static/[^~%?#]+)")
    if not path then
        if thumb:match("^https?://") then
            return thumb
        end
        path = thumb
    end
    return FanQie.MOBILE_COVER_CDN .. "/" .. path .. "~tplv-shrink:320:0.image"
end

function FanQie.is_valid_book_id(book_id)
    return book_id and tostring(book_id) ~= ""
end

function FanQie.normalize_book_id(book_id)
    return tostring(book_id or "")
end

-- ===========================================================================
-- 书城（fanqienovel.com **网页**接口）
-- ===========================================================================
-- 与上面 App 协议接口的区别：书城接口是网页端用的，**不需要 a_bogus 签名、
-- 不需要设备身份**，绝大多数连 cookie 都不需要（只有书架增删/进度要登录）。
--
-- ⚠️ 不可用的（2026-10-14 复盘）：
--   /api/author/misc/top_book_list/v1/ ← data 恒为 null
--   /page/{book_id}                    ← 实测回 0 字节（与 book_list 不同，仍是废接口）
--   /api/author/library/book_list/v0/  ← **这个不是废接口**！2026-10 曾误记为
--     「恒返回 HTTP 200 + 0 字节 / 已下线」，2026-10-14 用浏览器 curl 复核：
--     免 a_bogus、免 cookie、换 UA 都稳定返回 200 + application/json + 29 KB，
--     且 page_index 分页有效（**1 起**，网页 URL 的 page_2 == page_index=1）。
--     当时是**一次偶发空响应被当成了接口语义**。
--   本插件仍用下面的 0 起接口（NEW_LIBRARY_LIST），两者是同一批书的不同排序。

-- 分类树（主分类/主题/角色/情节），data 是**数组**，明文无 PUA。
function FanQie.store_category_url(gender)
    return FanQie.BASE_URL .. "/api/author/book/category_list/v0/?gender=" .. tostring(gender or 0)
end

-- 书库列表（网页版）。字段 book_name/author/abstract/read_count/word_count
-- 是 PUA 混淆的，必须过 WebPUA.decode。sort: 0=最热 1=最新 2=字数。
function FanQie.store_library_url(opts)
    opts = opts or {}
    local parts = {
        "page_count=" .. tostring(opts.page_count or 18),
        "page_index=" .. tostring(opts.page_index or 0),
        "gender=" .. tostring(opts.gender or 0),
        "category_id=" .. tostring(opts.category_id or -1),
        "creation_status=" .. tostring(opts.creation_status or -1),
        "word_count=" .. tostring(opts.word_count or -1),
        "book_type=" .. tostring(opts.book_type or -1),
        "sort=" .. tostring(opts.sort or 1),
    }
    return FanQie.BASE_URL .. "/api/library/book_list?" .. table.concat(parts, "&")
end

-- 网页搜索（明文无 PUA）。⚠️ 实测**必须带 cookie**：无 cookie 返回
-- HTTP 200 + 0 字节；**不需要 a_bogus**。
function FanQie.store_search_url(keyword, opts)
    opts = opts or {}
    local parts = {
        "filter=" .. (opts.filter or "127%2C127%2C127%2C127"),
        "page_count=" .. tostring(opts.page_count or 10),
        "page_index=" .. tostring(opts.page_index or 0),
        "query_type=0",
        "query_word=" .. H.url_encode(keyword or ""),
    }
    return FanQie.BASE_URL .. "/api/author/search/search_book/v1?" .. table.concat(parts, "&")
end

-- ===========================================================================
-- 免登录搜索（头条系小说搜索端点 novel.snssdk.com）
-- ===========================================================================
-- 🔴 为什么需要它：网页搜索 `store_search_url` 真正要的是**风控标识 `s_v_web_id`**，
--    而不是登录态。该标识由浏览器安全 SDK **本地随机生成**（番茄首页挂的
--    `…/sec_sdk_build/3.8.0/captcha/index.js` 里写得很清楚：
--      ALPHA = "0123456789A-Za-z"; n = Date.now().toString(36);
--      r = 36 位随机（r[8]=r[13]=r[18]=r[23]="_"、r[14]="4"、r[19]∈{8,9,A,B}）
--      cookie 里写 "verify_" + n + "_" + r，有效期 60 天）
--    而**扫码登录链路任何一步都不下发它**（登录页 / get_qrcode / check_qrconnect /
--    首页 / 搜索页 / 书库，2026-10-16 逐跳实测 Set-Cookie 只有 passport_csrf_token）；
--    服务端又只认「它见过的那一串」——
--    实测：真值改 1 个字符 / 只换时间戳段 / 尾部补 1 字符 → **全部空响应**；
--          按上面算法严格自造 3 个值 → 全部空响应（同一时刻真值/哨兵正常 ⇒ 不是限流）；
--          把自造值先带去首页、带去埋点上报走一趟 → 再搜仍空。
--    ⇒ 没在**浏览器**里打开过番茄的机器，永远拿不到可用的 `s_v_web_id`。
--
--    所以搜索改走这个端点：只要 aid / offset / q 三个参数，
--    **免签名、免 cookie、免风控标识**，扫码登录（或干脆不登录）都能搜。
--
-- 🔴 实测（2026-10-16）：
--   · novel.snssdk.com 与备用域名 api-lf.fanqiesdk.com 返回**逐字节相同**的响应；
--   · **真分页**：offset=0/10/20 三页两两无交集，响应给 `data.offset` 作下一页偏移；
--   · `tab_type` / `device_platform` / `parent_enterfrom` / `page_count` / `limit` /
--     `search_type` / `filter` / `query_type` / `genre` / `category_id` / `sort` …
--     **一律无效**（响应字节数完全一致）⇒ 没有筛选能力，别做筛选 UI；
--   · 返回字段：book_id / title / author / abstract / category / creation_status /
--     genre / score / thumb_url / audio_thumb_uri，**没有** word_count / read_count /
--     最新章 / 总章数（这些位在 UI 上就是不显示，别伪造）；
--   · 封面：原 `thumb_url`（p6-tt.bytecdn.cn，带 ~tplv-shrink:640:0）直下 **403**，
--     但路径抠出来后按 `FanQie.mobile_cover` 归一化到 p6-novel.byteimg.com
--     实测 **200 image/png** ⇒ 照常用 mobile_cover；
--   · 搜到的 book_id **可直接用于番茄侧的目录接口**
--     （/api/reader/directory/detail 实测拿到 85 / 73 章）⇒ 搜完就能读。
FanQie.SEARCH_LITE_BASE = "https://novel.snssdk.com"
FanQie.SEARCH_LITE_FALLBACK_BASE = "https://api-lf.fanqiesdk.com"
FanQie.SEARCH_LITE_PAGE_SIZE = 10

--- 免登录搜索 URL。offset 从 **0** 起（= page_index * SEARCH_LITE_PAGE_SIZE）。
---@param keyword string
---@param opts table|nil { page_index=0, offset=nil }
function FanQie.search_lite_url(keyword, opts)
    opts = opts or {}
    local offset = opts.offset
    if offset == nil then
        local page_index = tonumber(opts.page_index) or 0
        offset = page_index * FanQie.SEARCH_LITE_PAGE_SIZE
    end
    return FanQie.SEARCH_LITE_BASE .. "/api/novel/channel/homepage/search/search/v1/"
        .. "?aid=1967&offset=" .. tostring(offset)
        .. "&q=" .. H.url_encode(keyword or "")
end

-- 推荐榜（明文无 PUA）。rank_list_type 1~10 实测返回同一批。
function FanQie.store_rank_recommend_url(opts)
    opts = opts or {}
    local parts = {
        "app_id=2503",
        "rank_list_type=" .. tostring(opts.rank_list_type or 3),
        "offset=" .. tostring(opts.offset or 0),
        "limit=" .. tostring(opts.limit or 20),
    }
    return FanQie.BASE_URL .. "/api/rank/recommend/list?" .. table.concat(parts, "&")
end

-- 最近更新榜（明文无 PUA），total 可达 100。
function FanQie.store_rank_recent_url(opts)
    opts = opts or {}
    local parts = {
        "app_id=2503",
        "rank_list_type=" .. tostring(opts.rank_list_type or 3),
        "offset=" .. tostring(opts.offset or 0),
        "limit=" .. tostring(opts.limit or 20),
    }
    return FanQie.BASE_URL .. "/api/rank/recent/update/list?" .. table.concat(parts, "&")
end

-- 巅峰榜（首页「番茄巅峰榜」）。**明文**无 PUA、带封面；**免 a_bogus、免 cookie**
-- （2026-10-16 实测：无签名 / 改参数 / 复用旧签名全部放行）。固定 30 本。
function FanQie.store_rank_top_url(opts)
    opts = opts or {}
    return FanQie.BASE_URL .. "/api/author/misc/top_book_list/v1/?limit="
        .. tostring(opts.limit or 50) .. "&offset=" .. tostring(opts.offset or 0)
end

-- 原创榜（分类榜）。字段 camelCase，bookName/author/abstract 是 **PUA**，
-- 封面是**签名 CDN**（必须走 FanQie.mobile_cover 归一化）。
--
-- 🔴 参数语义（2026-10-14 实测 + muye JS 枚举双向确认）：
--   gender     1=男频 / 0=女频（JS: MALE=1, FEMALE=0）
--   rankMold   1=新书榜 / 2=阅读榜（JS: { read: 2, new: 1 }）
--   rank_list_type **只有 3 有效**（0/1/2/4..10 一律回 152 字节的空表）
--   rank_version  **必须出现**，值为空串时服务端解析当前榜单并回填 data.rankVersion；
--                 给错值（如 1）就回空表。翻页时应把上一页回传的版本带回来。
--   category_id  必须是真实分类（-1 无效，空表）；可复用 category_list 的「主分类」
--   offset/limit offset 0 起、与 currentPos 1:1；limit 实测到 100 都照收，缺省 10；
--                ⚠️ offset 超 total（100）服务端**不夹紧**，会给 101.. 的书 ⇒ 客户端刹车
function FanQie.store_rank_category_url(opts)
    opts = opts or {}
    local parts = {
        "app_id=2503",
        "rank_list_type=3",
        "offset=" .. tostring(opts.offset or 0),
        "limit=" .. tostring(opts.limit or 20),
        "category_id=" .. tostring(opts.category_id or 0),
        -- 必须保留这个空值参数（少了它服务端直接回空表）
        "rank_version=" .. tostring(opts.rank_version or ""),
        "gender=" .. tostring(opts.gender or 1),
        "rankMold=" .. tostring(opts.rank_mold or 2),
    }
    return FanQie.BASE_URL .. "/api/rank/category/list?" .. table.concat(parts, "&")
end

-- ===========================================================================
-- App 榜单（api5-normal-lf.fqnovel.com，见文件顶部 APP_BASE_URL 的长注释）
-- ===========================================================================

--- App 榜单公共 query（所有 App 接口通用）。
function FanQie.app_common_params()
    return {
        "aid=1967",
        "channel=0",
        "os_version=0",
        "device_type=0",
        "device_platform=0",
        "iid=466614321180296",
        "version_code=999",
    }
end

--- 榜单主接口（男频主榜 cell_id=7012498777642631182，出版物 cell_id=6943473182519066661）。
--- opts: { cell_id, algo_type, category_id=0, offset=0, limit=30,
---         list_type="daily", gender_list_type=2, genre_type=0 }
function FanQie.app_rank_cell_url(opts)
    opts = opts or {}
    local parts = FanQie.app_common_params()
    local q = {
        "change_type=1",
        "offset=" .. tostring(opts.offset or 0),
        "limit=" .. tostring(opts.limit or 30),
        "cell_id=" .. tostring(opts.cell_id or ""),
        "algo_type=" .. tostring(opts.algo_type or ""),
        "category_id=" .. tostring(opts.category_id or 0),
        "list_type=" .. tostring(opts.list_type or "daily"),
        "gender_list_type=" .. tostring(opts.gender_list_type or 2),
        "genre_type=" .. tostring(opts.genre_type or 0),
    }
    return FanQie.APP_BASE_URL .. "/reading/bookapi/bookmall/cell/change/v1/?"
        .. table.concat(parts, "&") .. "&" .. table.concat(q, "&")
end

--- 礼物榜专用接口（cell/change 取不到礼物榜）。
--- rank_type：0=男频礼物榜 1=女频礼物榜 9=男频礼物·书籍 10=女频礼物·书籍。
function FanQie.app_praise_rank_url(opts)
    opts = opts or {}
    local parts = FanQie.app_common_params()
    local q = {
        "rank_type=" .. tostring(opts.rank_type or 0),
        "page_index=" .. tostring(opts.page_index or 1),
        "offset=" .. tostring(opts.offset or 0),
        "limit=" .. tostring(opts.limit or 30),
    }
    return FanQie.APP_BASE_URL .. "/reading/ugc/praise/rank/v1/?"
        .. table.concat(parts, "&") .. "&" .. table.concat(q, "&")
end

-- 加入 / 移出书架：:version 展开成 ?aid=..&iid=..&version_code=..&update_version_code=..
-- （与 App 协议同款公共 query，见 make_shelf_params）
function FanQie.store_shelf_add_url()
    local p = FanQie.make_shelf_params()
    return FanQie.BASE_URL .. "/reading/bookapi/bookshelf/add/v:version?"
        .. "aid=" .. tostring(p.aid)
        .. "&iid=" .. tostring(p.iid)
        .. "&version_code=" .. tostring(p.version_code)
        .. "&update_version_code=" .. tostring(p.update_version_code)
end

function FanQie.store_shelf_delete_url()
    local p = FanQie.make_shelf_params()
    return FanQie.BASE_URL .. "/reading/bookapi/bookshelf/delete/v:version?"
        .. "aid=" .. tostring(p.aid)
        .. "&iid=" .. tostring(p.iid)
        .. "&version_code=" .. tostring(p.version_code)
        .. "&update_version_code=" .. tostring(p.update_version_code)
end

-- 批量书籍详情（连载/完结/断更状态、总章数）。POST，必须带 Cookie
-- （无 Cookie 返回 code=-1）；book_id 不要求在书架里，城书也能查。
function FanQie.store_multidetail_url()
    return FanQie.BASE_URL .. "/api/bookshelf/multidetail"
end

return FanQie