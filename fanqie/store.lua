--[[--
书城数据层：fanqienovel.com **网页**接口封装 + PUA 解码 + 字段归一化。

为什么单独一层：书城接口与 App reading 协议是两套东西——
  * 书城走网页接口，**不需要 a_bogus、不需要设备身份签名**；
  * 章节正文仍走 App reading 协议（见 fanqie/reading/）；
  * 书城返回的字段名五花八门（book_name / bookName / thumb_uri / thumbUri /
    cover_uri），且**部分接口的文本是 PUA 混淆的**，统一在本层消化掉，
    UI 只认一种记录形状。

接口清单（2026-10-14 复核实测，全部免 a_bogus、免 cookie）：

  | 用途       | 路径                                              | 登录 | PUA | page_index |
  |------------|---------------------------------------------------|------|-----|------------|
  | 分类树     | GET /api/author/book/category_list/v0/?gender=    | 否   | 否  | -          |
  | 书库列表   | GET /api/library/book_list?…                      | 否   | **是** | **0 起** |
  | 书库列表②  | GET /api/author/library/book_list/v0/?…           | 否   | **是** | **1 起** |
  | 搜索       | GET /api/author/search/search_book/v1?…           | **是** | 否 | 0 起     |
  | 推荐榜     | GET /api/rank/recommend/list?…                    | 否   | 否  | offset   |
  | 最近更新榜 | GET /api/rank/recent/update/list?…                | 否   | 否  | offset   |
  | 巅峰榜     | GET /api/author/misc/top_book_list/v1/?…          | 否   | 否  | **无**（恒 30 本） |
  | 作者榜     | GET /api/author/misc/top_author_list/v1/?…        | 否   | 否  | offset   |
  | 原创榜     | GET /api/rank/category/list?…                     | 否   | **是** | offset   |
  | 加入书架   | POST /reading/bookapi/bookshelf/add/v:version?…   | 是   | -   | -        |
  | 移出书架   | POST /reading/bookapi/bookshelf/delete/v:version?…| 是   | -   | -        |
  | 是否在书架 | GET  /reading/bookapi/bookshelf/check/v:version?…&book_id= | 是 | - | -    |
  | 书架名单   | GET  /reading/bookapi/bookshelf/info/v:version/?… | 是   | 否  | -        |
  | 书籍详情   | POST /api/bookshelf/multidetail                   | 是   | 否  | -        |
  | 阅读进度   | GET  /api/reader/book/progress                    | 是   | 否  | -        |

  ⚠️ `multidetail` **只返回在书架的书**（不在架 → `detail_list` 空数组、code 仍 0）；
     `item_show_title` / `item_abstract` **跟着请求体里的 `item_id` 走**
     —— 传进度里的 item_id 才是「最近阅读章节」，传 "0" 拿到的是第 1 章。

🔴 **gender 语义（男频/女频）—— 以站点自己的枚举为准，别想当然**：
  muye JS 里写着 `MALE = 1, FEMALE = 0`（标签表 `{1:"男频", 0:"女频"}`），
  `category_list/v0?gender=` 的实测返回值也完全对得上：
  `gender=1` → 男频树（西方奇幻/东方仙侠/战神赘婿/都市高武/抗战谍战…19 个主分类），
  `gender=0` → 女频树（女频悬疑/古风世情/宫斗宅斗/豪门总裁/青春甜宠/双男主…21 个），
  `gender=-1` → 全部（260 个，去重后），`gender=2/3` → 仅男女频共有的中性分类（76 个）。
  **即 1=男频、0=女频**（本插件 2026-10-14 之前写成 `male=0/female=1`，是反的，
  用户点「男频」看到的是女频分类）。
  网页 URL 里 `audience<gender>` 直接就是同一个数（`"audience"+filterArr[0]`）。

🔴 **原创榜 `/api/rank/category/list`（2026-10-14 实测，参数已解）**：
  必填 `app_id=2503`、`category_id`、`gender`、`rankMold`、`rank_list_type=3`、
  `rank_version`（**必须出现，值为空串** → 服务端解析并回填 `data.rankVersion`；
  给错值就回空表）。
  * `rankMold`：**1=新书榜、2=阅读榜**（muye JS 里是 `{read:2, new:1}`，
    榜单页 `/rank/<gender>_<mold>_<cat>` 的 DOM 分组也一一对应）；0 也返回数据但 UI 未用。
  * `rank_list_type` 只有 3 有效（0/1/2/4..10 都回 152 字节空表）。
  * `data`：`book_list` / `total_num`（恒 100）/ `rankVersion`。字段是 camelCase
    且 `bookName`/`author`/`abstract` 为 **PUA**，封面是**签名 CDN**。
  * ⚠️ `offset` **不会被服务端夹紧**：offset=100 仍返回 pos 101.. 的书，
    所以客户端必须按 `total_num` 自己刹车（见 store_ui 的 has_more 计算）。
  * `category_id=-1` 无效（空表）—— 必须给真实分类；可复用 `category_list` 的
    「主分类」集合（与榜单页列出的 19/18 项完全一致）。

🔴 **分页口径（2026-10-14 逐条实测，别凭"印象"改）**：
  * 两个书库接口**都**支持分页，`page_count` 上限实测到 100 都照单返回：
    `has_more`(bool) 与 `total_count` 都在 `data` 里，`book_list` 长度 == page_count。
  * 同一 `page_index` 连打两次结果**完全一致**（body 差异只有 `log_id`/`now` 时间戳），
    相邻页 **交集 0** ⇒ 翻页稳定、不重不漏。
  * 索引基准不同：`/api/library/book_list` 是 **0 起**，网页书库页真正用的
    `/api/author/library/book_list/v0/` 是 **1 起**（网页 URL `…/page_2` 对应
    `page_index=1`）。**照搬网页 curl 时必须减 1**。
  * 两者是**同一批书的不同排序**（分类 1456 各取 3 页，54 本交集 39），
    不是新旧关系；本插件用 0 起的那个（省一次偏移换算）。

🔴 已下线 / 不可用（不要再用）：
  * ⚠️ 旧记录写「`/api/author/misc/top_book_list/v1/` → data 恒为 null」——
    **该结论已作废**（2026-10-16 复核）：它是**顶层 `book_list`**、没有 data 包裹，
    旧探针按 `data` 找数据才误判成 null。现已接入「巅峰榜」（见 Store.rank_top）。
  * `/page/{book_id}` → 实测回 0 字节（仍是废接口）。
  * ⚠️ 曾经把 `/api/rank/category/list` 记成「参数未知 ⇒ 恒空 ⇒ 废弃」——
    那是**参数没给全**（缺 `rank_version=`/`rank_list_type=3`）导致的空表，
    不是接口废弃。2026-10-14 补齐参数后完全可用，已接入「原创榜」。

🔴 **「bookshelf/check 不可用」这条旧结论已作废**（2026-10-14 实测更正）：
  旧记录写「`/reading/bookapi/bookshelf/check/v:version/` → data 恒为 1，无法判断
  是否已在书架」。**错在没带 `book_id`** —— 缺参数时服务端回的是
  `{"code":100103,"message":"book_id 无效","data":null}`，把那个 null 读成「恒 1」
  就废掉了一个**完全可用**的接口。带参实测（`.workbuddy/tools/_probe_shelf_ops.py`
  / `_probe_shelf_check.py` / `_probe_shelf_check3.py`）：

  | 请求 | 响应 |
  | --- | --- |
  | `check?…&book_id=<在架书>` | `{"code":0,"data":1}` |
  | `check?…&book_id=<不在架书>` | `{"code":0,"data":0}` |
  | `check?…`（**不带 book_id**） | `{"code":100103,"message":"book_id 无效"}` |
  | `check?…&book_id=abc`（非数字） | `{"code":100103,"message":"book_id 无效"}` |
  | `check?…`（**不带 Cookie**） | `{"code":101108,"message":"无用户信息"}` |
  | `check/v:version/?book_id=<id>`（**只 book_id**） | `{"code":0,"data":1}` ✅ 参数可省 |

  ⇒ 判据就一句：**`code==0 and data==1` = 在书架**。请求只有 39 字节。
  ⚠️ 参数名必须是单数 `book_id`（`book_ids=` / `book_id=a,b` 都回 100103），
     重复给多个 `book_id` 只取第一个。
  ⚠️ 同理 `bookshelf/add` / `delete` **不需要 `x-secsdk-csrf-token`**：
     实测不带该头也回 `{"code":0,"message":"SUCCESS"}`（`book_id` 无效时才报错）。

🔴 **书架全量名单 = `/reading/bookapi/bookshelf/info/v:version/?…`** 的
  `data.book_shelf_info[]`（实测 144 本 / 24.7 KB，`book_id`/`add_shelf_time`/
  `modify_time`/`add_type`/`asterisked`/`book_type`）；增删后**立即生效**（无缓存）。
  另有 `/reading/bookapi/bookshelf/list/v:version/`（43.7 KB，`data.book_shelf_info_all[]`
  + `is_all=true` + `limit=2000` + `server_time`），差别不大，插件未用。
  ⚠️ 「是否在书架」**优先用 check**（39 B），别为此拉 24 KB 的名单。

⚠️ **历史误判（勿再犯）**：2026-10 曾把 `/api/author/library/book_list/v0/`
记为「恒返回 HTTP 200 + 0 字节 ⇒ 已下线」，并据此在文档里劝退该接口。
2026-10-14 用浏览器 curl 逐项复核，该接口**完全正常**（无 a_bogus / 无 cookie
/ 换 UA 都返回 200 + application/json + 29 KB 数据）。
当时那次「0 字节」是**单次请求的偶发结果被当成了接口语义** ——
判一个接口死活，必须换参数（page_index=1/2）多打几次再下结论。

所有函数返回 `(结果, err)`，**不抛异常**；err 是表 `{kind, message, code}`，
用 `Store.describe_error(err)` 转成用户可读文案。

📌 App 榜单（api5-normal-lf.fqnovel.com，见 fanqie.lua 顶部 APP_BASE_URL 注释）：
  * `GET /reading/bookapi/bookmall/cell/change/v1/` —— **榜单唯一真实数据源**
    （男频主榜 cell_id=7012498777642631182；出版物 cell_id=6943473182519066661
    + genre_type=160）。书籍在 **`data.cell_view.book_data`**。
    免签名 / 免 cookie，实测连打 40 次无失手。见 Store.APP_RANKS + Store.rank_cell。
  * `GET /reading/ugc/praise/rank/v1/` —— 礼物榜专用（cell 接口取不到），
    `rank_type` 0/1=男/女频礼物榜、9/10=男/女频礼物·书籍。
    条目形如 `{ book={…}, gift_value, rank }`。见 Store.APP_PRAISE + Store.rank_praise。
  * 🔴 两条最易踩的坑：① 榜单**分页无效**（offset=30/60 回与首页相同的 30 本）；
    ② 未知 `algo_type` 不报错而是**静默退化成默认榜**，必须校验 `cell_view.cell_name`。

@module fanqie.store
--]]

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
-- T 必须是 util.template（%1/%2 占位符）。定义成 _ 的话占位符**原样显示**
-- （书城标题出现「共 %1 本」、错误提示出现「%1」——实测踩中）。
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

local FanQie = require("fanqie.fanqie")
local H = require("fanqie.helper")
-- 🔴 两张 PUA 表**必须分开**：码位 → 汉字 的映射「接口内固定、接口间不通」。
-- 实测同一本书在书库接口与原创榜接口拿到的码位完全不同；拿错表会解出
-- 「通顺但错误」的中文（不报错、不崩），比解不出来危险得多。
local WebPUA = require("fanqie.webpua")     -- 书库接口 /api/library/book_list
local RankPUA = require("fanqie.rankpua")   -- 原创榜 /api/rank/category/list
local Log = require("fanqie.logger")

local Store = {}

-- 网页端 sort 语义（从 muye.js 的枚举里挖出来的，不是猜的）：
--   I = { HOT = 0, NEW = 1, NUMBER = 2 }；L = { hottes→0, newest→1, count→2 }
-- 实测 sort=3 返回空列表，说明只有 0/1/2 三个合法值。
Store.SORT = {
    hot = 0,     -- 最热
    new = 1,     -- 最新
    words = 2,   -- 字数
}

-- 🔴 1=男频、0=女频（站点 muye JS 的枚举就是 `MALE = 1, FEMALE = 0`，
--    category_list / rank 两个接口的实测返回值也都对得上）。
--    ⚠️ 曾写成 male=0/female=1 —— 结果是**点「男频」列出女频分类**（标签与内容互换），
--    而且不报错、不崩，纯静默错。改这里等于改所有 audience/榜单的语义，别凭印象动。
Store.GENDER = {
    male = 1,
    female = 0,
}

-- 原创榜的两种「榜」（站点枚举 `{ read = 2, new = 1 }`）。
-- 新书榜：30 万字以下、已签约未下架、已开始推荐且未断更、完结未超过 90 天；
-- 阅读榜：30 万字以上、已签约未下架、已开始推荐的番茄原创作品。都只排前 100 名。
Store.RANK_MOLD = {
    read = 2,
    new = 1,
}

-- 分类树的 label 顺序（服务端返回顺序是按 label 分组但组间无序，这里固定住）
Store.CATEGORY_LABEL_ORDER = { "主分类", "主题", "角色", "情节" }

-- 无 cookie 时书架接口回的码
local CODE_NOT_LOGGED_IN = 101108

-- ------------------------------------------------------------------ 内部工具

local function library_referer(gender)
    -- 实测：书库接口靠 Referer 认「来自书库页」。网页 URL 里 audience 的编号
    -- **就是 gender 本身**（muye JS：`s.push("audience" + filterArr[0])`，而
    -- filterArr[0] 正是发给 CATEGORY_LIST/LIBRARY_LIST 的 gender）。
    -- 所以这里不能用「等于 female 就 audience1」这种反推写法，直接把 gender 拼进去。
    -- gender 非 0/1（如 -1=全部）时网页会**省略** audience 段，这里退回男频。
    local g = tonumber(gender)
    if g ~= Store.GENDER.male and g ~= Store.GENDER.female then
        g = Store.GENDER.male
    end
    return FanQie.BASE_URL .. "/library/audience" .. tostring(g) .. "/page_1?sort=newest"
end

--- 统一的「服务端业务码」错误。
---@return table err
local function api_error(data, url)
    local code = tonumber(data and data.code)
    local msg = data and (data.message or data.msg) or nil
    local smsg = tostring(msg or "")
    -- 🔴 除 101108 外，还要认「**文案里说登录**」这一种（v2.16.2）：
    --    部分接口未登录时回的是 `{"code":-1,"message":"请先登录"}`（不是 101108），
    --    旧代码会把它归成 kind="api"，于是用户看到的是
    --    「书城接口返回业务错误 code=-1 message=请先登录（URL）」这种**原始报文**，
    --    既难懂又没告诉他该干什么。client.lua 的 is_auth_error 早就有同款文案识别，
    --    这里补齐，让「需要登录」统一走一条可操作提示。
    if code == CODE_NOT_LOGGED_IN or smsg:find("登录", 1, true) then
        return {
            kind = "auth",
            code = code,
            message = T(_("书城需要登录番茄账号（服务端返回：%1）"), tostring(msg or code)),
        }
    end
    return {
        kind = "api",
        code = code,
        message = T(_("书城接口返回业务错误 code=%1 message=%2（%3）"),
            tostring(code), tostring(msg or ""), url),
    }
end

local function shape_error(what, url)
    return {
        kind = "shape",
        message = T(_("书城接口返回结构不符合预期：%1（%2）"), what, url),
    }
end

--- PUA 混淆字段解码。含未映射码位时**照常返回**（尽量可读），但记一条日志。
---@param v string
---@param pua table|nil 解码表；缺省 WebPUA。🔴 表**按接口选**，传错会「通顺但错误」。
local function plain(v, pua)
    pua = pua or WebPUA
    if type(v) ~= "string" or v == "" then return v end
    if pua.has_unknown(v) then
        Log.warn("[FanQie][store] PUA 文本含未映射码位，原样保留:", v)
    end
    return pua.decode(v) or v
end

--- 把秒级/or 毫秒级时间戳统一成「数字（秒）」。识别不清时返回 nil。
local function to_seconds(v)
    local n = tonumber(v)
    if not n or n <= 0 then return nil end
    if n > 1e11 then return math.floor(n / 1000) end   -- 毫秒
    return math.floor(n)
end

-- ------------------------------------------------------------------ 归一化

--- 把各接口的原始记录归一成统一形状。
---@param rec table 原始记录
---@param source string "library"|"search"|"rank_recommend"|"rank_recent"|"rank_category"
---@return table|nil
function Store.normalize(rec, source)
    if type(rec) ~= "table" then return nil end
    local book_id = rec.book_id or rec.bookId
    if not FanQie.is_valid_book_id(book_id) then return nil end

    local book = {
        book_id = tostring(book_id),
        source = source,
        title = "",
        author = "",
        cover = nil,
        desc = "",
        category = nil,
        word_count = nil,
        read_count = nil,
        update_time = nil,
        -- 🔴 `item_id` **只允许**表示「阅读进度章节」（书架条目才有）。
        --    书城各接口给的 `last_chapter_id` / `lastChapterItemId` / `itemId` 都是
        --    **本书最新章**，语义完全相反 —— 早先直接写进 `book.item_id`，
        --    而 `openBook` 把它当「上次读到哪章」用 ⇒ **从书城点「开始阅读」直接跳到最后一章**。
        --    所以这里一律写进 `latest_chapter_item_id`，`item_id` 保持 nil。
        item_id = nil,
        latest_chapter_item_id = nil,
        book_type = nil,
        creation_status = nil,
    }

    if source == "library" then
        -- 字段：abstract/author/book_name/read_count/word_count 为 PUA 混淆文本；
        -- read_count 是**展示串**（如「未满1000人在读」），word_count 也是（「7935字」）
        book.title = plain(rec.book_name)
        book.author = plain(rec.author)
        book.desc = plain(rec.abstract)
        book.read_count = plain(rec.read_count)
        book.word_count = plain(rec.word_count)
        book.cover = FanQie.mobile_cover(rec.thumb_uri) or FanQie.mobile_cover(rec.thumb_url)
        book.update_time = to_seconds(rec.last_chapter_time)
        book.creation_status = tonumber(rec.creation_status)
        -- 书库（已在书架的书）也会带 book_type；=1 表示图集/漫画，
        -- 阅读时用来把「整章几十页大图」的下载超时讲清楚（见 main.lua:openChapter）。
        book.book_type = tonumber(rec.book_type)
    elseif source == "search" then
        -- ⚠️ 网页搜索端点已于 v2.16.15 停用（搜索只走下面的 search_lite）。此分支保留：
        --    它锁定了「网页搜索返回结构 → 书字段」的映射口径（明文 + last_chapter_id 是
        --    **最新章**、不是阅读进度），将来若再接别的搜索源可直接复用，不必重新踩坑。
        book.title = rec.book_name or ""
        book.author = rec.author or ""
        book.desc = rec.book_abstract or ""
        book.category = rec.category
        book.read_count = rec.read_count
        book.word_count = rec.word_count
        book.cover = FanQie.mobile_cover(rec.thumb_uri) or FanQie.mobile_cover(rec.thumb_url)
        -- ⚠️ 是**最新章**，不是阅读进度 —— 见上面 book 构造处 `item_id` 的注释。
        book.latest_chapter_item_id = rec.last_chapter_id and tostring(rec.last_chapter_id) or nil
        -- `book_type == 1` = 漫画/图集（正文章节是一串整页大图，见 content.parse_comic_pics）。
        -- 保留它：① 阅读时能把「整章几十页大图」的下载超时放宽；
        --          ② 详情页可以如实告诉用户「这是图集」。
        book.book_type = tonumber(rec.book_type)
        book.update_time = to_seconds(rec.last_chapter_time)
        book.creation_status = tonumber(rec.creation_status)
        book.last_chapter_title = rec.last_chapter_title
        book.first_chapter_id = rec.first_chapter_id and tostring(rec.first_chapter_id) or nil
    elseif source == "search_lite" then
        -- 免登录搜索（novel.snssdk.com，见 fanqie.lua 的 SEARCH_LITE_BASE 长注释）。
        -- 字段 snake_case 且**全是明文**（title/author/abstract 都不混淆）⇒ 不过 PUA 解码：
        -- 这不是「省一步」，而是正确性要求 —— 该接口的文本不在任何 PUA 表里，
        -- 硬套 plain() 只会平白多一层风险。
        -- ⚠️ 该接口**不返回** word_count / read_count / 最新章 / 总章数：
        --    对应字段保持 nil，UI 自然不显示（别用 0 或 "" 伪造，那会显示成「0人在读」）。
        book.title = rec.title or ""
        book.author = rec.author or ""
        book.desc = rec.abstract or ""
        book.category = rec.category
        -- 封面：原 thumb_url 直下 403，但作为 `mobile_cover` 的输入恰好合适
        -- （它只抠 novel-pic 路径，再拼无签名的 p6-novel CDN，实测 200 image/png）。
        book.cover = FanQie.mobile_cover(rec.thumb_url) or FanQie.mobile_cover(rec.audio_thumb_uri)
        -- creation_status 语义与网页侧一致（0=完结 / 1=连载），可直接进 creation_status_label。
        book.creation_status = tonumber(rec.creation_status)
        book.score = tonumber(rec.score)
    elseif source == "rank_recommend" then
        book.title = rec.bookName or ""
        book.author = rec.author or ""
        book.desc = rec.abstract or ""
        book.category = rec.category
        book.cover = FanQie.mobile_cover(rec.thumbUri)
    elseif source == "rank_recent" then
        book.title = rec.bookName or ""
        book.author = rec.author or ""
        book.category = rec.category
        -- ⚠️ 榜单的 `itemId` 是「这条推荐对应的章节」（一般是最新章），同样不是阅读进度。
        book.latest_chapter_item_id = rec.itemId and tostring(rec.itemId) or nil
        book.update_time = to_seconds(rec.updateTime)
        book.latest_chapter = rec.title
        -- 该接口**不返回封面**：不要伪造，交给上层按需用 multidetail 补
        book.cover = nil
    elseif source == "rank_top" then
        -- 巅峰榜（/api/author/misc/top_book_list/v1/）：字段 snake_case 且**明文**
        -- （book_name/author/category 都不混淆），封面 thumb_url 直接可用
        -- （已是签名 CDN 形式，仍过 mobile_cover 归一化）。rank_score 恒空串，不采。
        book.title = rec.book_name or ""
        book.author = rec.author or ""
        book.category = rec.category
        book.cover = FanQie.mobile_cover(rec.thumb_url)
        book.creation_status = tonumber(rec.creation_status)
    elseif source == "rank_category" then
        -- 原创榜（/api/rank/category/list）：camelCase 字段 + PUA 文本 + 签名封面。
        -- 🔴 PUA 用 **RankPUA**（这张表就是从这个接口学的），不是 WebPUA ——
        -- 两张表不通用，混用会得到「通顺但错误」的书名。
        book.title = plain(rec.bookName, RankPUA) or ""
        book.author = plain(rec.author, RankPUA) or ""
        book.desc = plain(rec.abstract, RankPUA) or ""
        -- read_count / wordNumber 都是**数字串**（不是书库那种「未满1000人在读」展示串），
        -- 但服务端偶尔会给空的 display 串，所以两条路都走：能转数字就转。
        book.read_count = tonumber(rec.read_count) or plain(rec.read_count, RankPUA)
        book.word_count = tonumber(rec.wordNumber)
        book.cover = FanQie.mobile_cover(rec.thumbUri)
        book.creation_status = tonumber(rec.creationStatus)
        book.update_time = to_seconds(rec.lastChapterUpdateTime)
        -- ⚠️ lastChapterTitle 是**明文**（本接口只有 bookName/author/abstract 是 PUA），
        -- 但仍照常过一遍解码：遇明文时 decode 原样返回，属于无副作用的安全操作。
        book.last_chapter_title = plain(rec.lastChapterTitle, RankPUA)
        -- ⚠️ 最新章的 item_id，**不是**阅读进度（见 book 构造处注释）。
        book.latest_chapter_item_id = rec.lastChapterItemId and tostring(rec.lastChapterItemId) or nil
        -- 榜单专属：当前名次（1 起）与较上期名次变化（正=上升、负=下降、0=不变）
        book.rank_pos = tonumber(rec.currentPos)
        book.rank_diff = tonumber(rec.rankPosDiff)
        book.category = rec.categoryV2 or rec.category
    elseif source == "rank_cell" then
        -- App 榜单主接口（bookmall/cell/change/v1/）：字段 snake_case 且**明文**
        -- （book_name/author/abstract 都不混淆），封面 thumb_url 是**签名 CDN**，
        -- 但仍过 mobile_cover 归一化成长期有效的公共 CDN 形式。
        -- ⚠️ creation_status 是**字符串** "0"(连载)/"1"(完结)，不是数字。
        -- ⚠️ word_number / read_count / score 都是数字串（"4263654" / "9.9"）。
        book.title = rec.book_name or ""
        book.author = rec.author or ""
        book.desc = rec.abstract or ""
        book.category = rec.category
        book.cover = FanQie.mobile_cover(rec.thumb_url) or FanQie.mobile_cover(rec.thumb_uri)
        book.word_count = tonumber(rec.word_number)
        book.read_count = tonumber(rec.read_count)
        book.score = tonumber(rec.score)
        book.creation_status = tonumber(rec.creation_status)
        book.tags = rec.tags
        -- is_ebook=1 ⇒ 出版物（榜单里出版物榜才有），记下来给详情页/列表脚注用
        book.is_ebook = tonumber(rec.is_ebook) == 1 or nil
    elseif source == "rank_praise" then
        -- 礼物榜（ugc/praise/rank/v1/）：条目是 `{ book = {…}, gift_value, rank }`，
        -- 书字段嵌在 `book` 里（由 normalize_list 之前先摊平，见 Store.rank_praise）。
        book.title = rec.book_name or ""
        book.author = rec.author or ""
        book.desc = rec.abstract or ""
        book.category = rec.category
        book.cover = FanQie.mobile_cover(rec.thumb_url) or FanQie.mobile_cover(rec.thumb_uri)
        book.word_count = tonumber(rec.word_number)
        book.creation_status = tonumber(rec.creation_status)
        -- 榜单专属：礼物值（名次由外层的 rank 字段补，见 Store.rank_praise）
        book.gift_value = rec.gift_value
        book.rank_pos = tonumber(rec.rank_pos)
    end

    return book
end

local function normalize_list(list, source, url)
    if type(list) ~= "table" then
        return nil, shape_error("列表字段不是数组", url)
    end
    local out = {}
    for _i, rec in ipairs(list) do
        local b = Store.normalize(rec, source)
        if b then out[#out + 1] = b end
    end
    return out
end

-- ------------------------------------------------------------------ 分类树

--- 分类列表。
---@param client table
---@param gender number|nil 0=男频 1=女频
---@return table|nil list, table|nil err
function Store.categories(client, gender)
    gender = tonumber(gender) or Store.GENDER.male
    local url = FanQie.store_category_url(gender)
    local data, err = client:web_get_json(url, { referer = library_referer(gender) })
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    local list = data.data
    if type(list) ~= "table" then return nil, shape_error("data 不是数组", url) end
    local out = {}
    for _i, c in ipairs(list) do
        if type(c) == "table" and c.category_id then
            out[#out + 1] = {
                category_id = tonumber(c.category_id),
                label = c.label or "",
                name = c.name or "",
                cover = FanQie.mobile_cover(c.cover_uri),
                desc = c.description or "",
            }
        end
    end
    return out
end

--- 按 label 把分类分组（顺序按 CATEGORY_LABEL_ORDER，未知 label 排在最后）。
---@return table 数组，每项 { label = "主分类", items = { … } }
function Store.group_categories(list)
    if type(list) ~= "table" then return {} end
    local buckets, order = {}, {}
    for _i, c in ipairs(list) do
        local label = c.label or ""
        if not buckets[label] then
            buckets[label] = {}
            order[#order + 1] = label
        end
        local b = buckets[label]
        b[#b + 1] = c
    end
    local known = {}
    for _i, label in ipairs(Store.CATEGORY_LABEL_ORDER) do known[label] = true end

    local groups = {}
    local function push(label)
        if buckets[label] and #buckets[label] > 0 then
            groups[#groups + 1] = { label = label, items = buckets[label] }
        end
    end
    for _i, label in ipairs(Store.CATEGORY_LABEL_ORDER) do push(label) end
    for _i, label in ipairs(order) do
        if not known[label] then push(label) end
    end
    return groups
end

-- ------------------------------------------------------------------ 书库列表

--- 书库列表（分类浏览）。
---@param opts table { page_index=0, page_count=18, gender=0, category_id=-1,
---                    creation_status=-1, word_count=-1, book_type=-1, sort=1 }
---@return table|nil { books = {…}, has_more = bool, total = number }, table|nil err
function Store.library(client, opts)
    opts = opts or {}
    local url = FanQie.store_library_url(opts)
    local data, err = client:web_get_json(url, { referer = library_referer(opts.gender) })
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    local dd = data.data
    if type(dd) ~= "table" then return nil, shape_error("data 不是对象", url) end
    local books, nerr = normalize_list(dd.book_list, "library", url)
    if not books then return nil, nerr end
    return {
        books = books,
        has_more = dd.has_more == true,
        total = tonumber(dd.total_count) or 0,
        page_index = tonumber(opts.page_index) or 0,
        page_count = tonumber(opts.page_count) or 18,
    }
end

-- ------------------------------------------------------------------ 搜索

--- 免登录搜索（novel.snssdk.com / api-lf.fanqiesdk.com）。
--- **免签名、免 cookie、免风控标识 `s_v_web_id`** —— 只需 aid / offset / q 三个参数，
--- 逐项实测记录在 fanqie.lua 的 `SEARCH_LITE_BASE` 注释里（含真分页、参数无效清单、字段清单）。
--- 走 `app_get_json`：该端点属 App 侧，用 `com.dragon.read/…` UA（实测带不带网页 Referer 都正常）。
---@param opts table|nil { page_index=0, offset=nil }
---@return table|nil { books={…}, total, has_more, next_offset, lite=true }, table|nil err
function Store.search_lite(client, keyword, opts)
    opts = opts or {}
    if type(keyword) ~= "string" or keyword == "" then
        return nil, { kind = "arg", message = _("请输入搜索关键词") }
    end
    local url = FanQie.search_lite_url(keyword, opts)
    local data, err = client:app_get_json(url)
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    local dd = data.data
    if type(dd) ~= "table" then return nil, shape_error("data 不是对象", url) end
    local books, nerr = normalize_list(dd.ret_data, "search_lite", url)
    if not books then return nil, nerr end
    return {
        books = books,
        -- 该接口**不返回总数**：宁可不给，也不拿本页条数冒充「共 N 本」
        -- （标题里的 total 会误导成「这本书只有 10 个结果」）。
        has_more = dd.has_more == true,
        -- 服务端直接给下一页偏移（= 本页 offset + 本页条数），比自己算 page_index*10 更准
        next_offset = tonumber(dd.offset),
        page_index = tonumber(opts.page_index) or 0,
        lite = true,
    }
end

--- 搜索书籍。**只走免登录端点**（v2.16.15）。
---
--- 历史：v2.16.4 是「网页接口优先、失败降级到免签名端点」。但网页搜索真正要的是浏览器
--- 安全 SDK 本地生成、且服务端只认它见过的那串 `s_v_web_id`；扫码登录链路不下发它
--- （逐跳实测见 fanqie.lua 的 SEARCH_LITE_BASE 注释）⇒ 没在浏览器里打开过番茄的设备，
--- 网页搜索**永远**失败：每次搜索都白打一次请求，再弹一句「已改用免登录搜索」。
--- 免签名端点免签名 / 免 cookie / 免风控标识，扫码登录（或干脆不登录）都能搜
--- ⇒ 没有保留网页路径的理由。删掉后首屏少一次失败请求，用户也不再需要看任何提示文案。
---
--- 返回值仍带 `lite = true`（字段少：没有字数 / 在读 / 最新章），调用方逻辑不变。
---@param keyword string
---@param opts table|nil { page_index=0, page_count=10 }
---@return table|nil { books = {…}, has_more, next_offset, lite = true }, table|nil err
function Store.search(client, keyword, opts)
    return Store.search_lite(client, keyword, opts)
end

-- ------------------------------------------------------------------ 榜单

--- 推荐榜。
function Store.rank_recommend(client, opts)
    opts = opts or {}
    local url = FanQie.store_rank_recommend_url(opts)
    local data, err = client:web_get_json(url, { referer = FanQie.BASE_URL .. "/" })
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    local dd = data.data
    if type(dd) ~= "table" then return nil, shape_error("data 不是对象", url) end
    local books, nerr = normalize_list(dd.list, "rank_recommend", url)
    if not books then return nil, nerr end
    return { books = books, total = tonumber(dd.total) or #books, offset = tonumber(opts.offset) or 0 }
end

--- 最近更新榜（total 可达 100，但一次只回 limit 条）。
function Store.rank_recent(client, opts)
    opts = opts or {}
    local url = FanQie.store_rank_recent_url(opts)
    local data, err = client:web_get_json(url, { referer = FanQie.BASE_URL .. "/" })
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    local dd = data.data
    if type(dd) ~= "table" then return nil, shape_error("data 不是对象", url) end
    local books, nerr = normalize_list(dd.data, "rank_recent", url)
    if not books then return nil, nerr end
    return { books = books, total = tonumber(dd.total) or #books, offset = tonumber(opts.offset) or 0 }
end

--- 巅峰榜（首页「番茄巅峰榜」栏）。免 a_bogus / 免 cookie；**恒回固定 30 本** ——
--- offset/limit 服务端一律无视（2026-10-16 实测：offset=30 与 limit=5 都回同一批），
--- 所以 has_more 恒 false，**别做翻页**。
--- 🔴 响应结构特殊：`book_list` 在**顶层**，没有 `data` 包裹（推荐榜/最近更新都是
---    `data.list` / `data.data`）—— 早期探针按 data 找数据，把它误判成「data 恒 null」。
function Store.rank_top(client, opts)
    opts = opts or {}
    local url = FanQie.store_rank_top_url(opts)
    local data, err = client:web_get_json(url, { referer = FanQie.BASE_URL .. "/" })
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    local books, nerr = normalize_list(data.book_list, "rank_top", url)
    if not books then return nil, nerr end
    -- 接口不给名次字段，但**返回顺序就是名次** —— 补上，列表徽章 #N 才有得显示
    for i, b in ipairs(books) do
        if b.rank_pos == nil then b.rank_pos = i end
    end
    return { books = books, total = #books, offset = 0, has_more = false }
end

-- ------------------------------------------------------------------ App 榜单

--- App 榜单的两个 cell（榜单页按性别下发不同 cell_id，实测同一 cell 换
--- gender_list_type 0/1/2 返回同一批数据 ⇒ cell 才是频道的决定因素）。
Store.APP_CELL = {
    male = "7012498777642631182",          -- 男频主榜
    publication = "6943473182519066661",   -- 出版物榜（genre_type=160）
}

--- App 榜单目录。`expect` = 期望的响应榜名（见 Store.rank_cell 的校验注释）。
--- group: "male" 男频 11 榜 / "pub" 出版物 6 榜。
Store.APP_RANKS = {
    { key = "app_recommend", group = "male", label = "推荐榜", algo = 101, expect = "推荐榜" },
    { key = "app_end",       group = "male", label = "完本榜", algo = 100, expect = "完本榜" },
    { key = "app_read",      group = "male", label = "阅读榜", algo = 111, expect = "阅读榜" },
    { key = "app_highscore", group = "male", label = "高分榜", algo = 115, expect = "高分榜" },
    { key = "app_reputation", group = "male", label = "口碑榜", algo = 104, expect = "口碑榜" },
    { key = "app_chase",     group = "male", label = "追更榜", algo = 109, expect = "追更榜" },
    { key = "app_comment",   group = "male", label = "热评榜", algo = 110, expect = "热评榜" },
    { key = "app_darkhorse", group = "male", label = "黑马榜", algo = 102, expect = "黑马榜" },
    { key = "app_hotsearch", group = "male", label = "热搜榜", algo = 103, expect = "热搜榜" },
    { key = "app_popular",   group = "male", label = "人气榜", algo = 146, expect = "人气榜" },
    { key = "app_peak",      group = "male", label = "巅峰榜", algo = 200, expect = "巅峰榜" },
    { key = "pub_recommend", group = "pub", label = "推荐榜", algo = 112, expect = "推荐榜" },
    { key = "pub_read",      group = "pub", label = "阅读榜", algo = 113, expect = "阅读榜" },
    { key = "pub_classic",   group = "pub", label = "名著榜", algo = 114, expect = "名著榜" },
    { key = "pub_favorite",  group = "pub", label = "收藏榜", algo = 129, expect = "收藏榜" },
    { key = "pub_new",       group = "pub", label = "新书榜", algo = 131, expect = "新书榜" },
    { key = "pub_collection", group = "pub", label = "典藏榜", algo = 196, expect = "典藏榜" },
}

--- 礼物榜目录（走 ugc/praise/rank/v1/，cell 接口取不到）。
Store.APP_PRAISE = {
    { key = "praise_male",       rank_type = 0,  label = "男频礼物榜" },
    { key = "praise_female",     rank_type = 1,  label = "女频礼物榜" },
    { key = "praise_male_book",  rank_type = 9,  label = "男频礼物·书籍" },
    { key = "praise_female_book", rank_type = 10, label = "女频礼物·书籍" },
}

local function app_group_params(group)
    if group == "pub" then
        return { cell_id = Store.APP_CELL.publication, genre_type = 160, gender_list_type = 1 }
    end
    return { cell_id = Store.APP_CELL.male, genre_type = 0, gender_list_type = 2 }
end

--- App 榜单（bookmall/cell/change/v1/）。
---@param opts table { rank_key="app_recommend", offset=0, limit=30 }
---@return table|nil { books, total, has_more, cell_name, cell_alias }, table|nil err
function Store.rank_cell(client, opts)
    opts = opts or {}
    local spec
    for _i, r in ipairs(Store.APP_RANKS) do
        if r.key == opts.rank_key then spec = r break end
    end
    if not spec then
        return nil, { kind = "arg", message = _("未知的榜单") }
    end
    local req = app_group_params(spec.group)
    req.algo_type = spec.algo
    req.offset = tonumber(opts.offset) or 0
    req.limit = tonumber(opts.limit) or 30
    local url = FanQie.app_rank_cell_url(req)
    local data, err = client:app_get_json(url)
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    local dd = data.data
    if type(dd) ~= "table" then return nil, shape_error("data 不是对象", url) end
    -- 🔴 书在 `data.cell_view.book_data`（**不是** data.book_data —— 早期探针读错这一层，
    --    把有数据的响应判成「空」，进而误得出「接口被限流」的结论）。
    local cv = dd.cell_view
    if type(cv) ~= "table" then return nil, shape_error("data.cell_view 不是对象", url) end
    -- 🔴 榜名校验：未知 algo_type 服务端**不报错**，静默退化成默认榜
    --    （实测 135→「推荐榜」、116→「完本榜」）—— 不校验就会把别的榜的数据
    --    当成本榜展示，用户看到的是「追更榜里全是推荐榜的书」这种无声错误。
    local cell_name = cv.cell_name or ""
    if cell_name ~= "" and spec.expect ~= cell_name then
        return nil, {
            kind = "rank_mismatch",
            message = T(_("榜单「%1」暂不可用（服务端返回的是「%2」）"), spec.label, cell_name),
        }
    end
    local books, nerr = normalize_list(cv.book_data, "rank_cell", url)
    if not books then return nil, nerr end
    if #books == 0 then
        return nil, {
            kind = "rank_empty",
            message = T(_("「%1」暂时没有数据"), spec.label),
        }
    end
    -- 顺序即名次（接口不带名次字段）
    for i, b in ipairs(books) do
        if b.rank_pos == nil then b.rank_pos = i end
    end
    return {
        books = books,
        total = #books,
        -- 🔴 不做翻页：offset=30/60 实测返回与首页**完全相同**的 30 本（交集 30/30），
        --    `has_more` 是乐观值。多翻一页只会得到重复书目。
        has_more = false,
        cell_name = cell_name,
        cell_alias = cv.cell_alias,
    }
end

--- 礼物榜（ugc/praise/rank/v1/）。男/女频由 rank_type 直接区分。
---@param opts table { rank_key="praise_male", offset=0, limit=30 }
function Store.rank_praise(client, opts)
    opts = opts or {}
    local spec
    for _i, r in ipairs(Store.APP_PRAISE) do
        if r.key == opts.rank_key then spec = r break end
    end
    if not spec then
        return nil, { kind = "arg", message = _("未知的榜单") }
    end
    -- 礼物榜服务端分页用 offset（next_offset 递增）；本版本只取首页 30 条。
    local url = FanQie.app_praise_rank_url{
        rank_type = spec.rank_type,
        page_index = 1,
        offset = tonumber(opts.offset) or 0,
        limit = tonumber(opts.limit) or 30,
    }
    local data, err = client:app_get_json(url)
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    local dd = data.data
    if type(dd) ~= "table" then return nil, shape_error("data 不是对象", url) end
    local list = dd.book_list
    if type(list) ~= "table" then return nil, shape_error("data.book_list 不是数组", url) end
    -- 条目形如 `{ book = {…}, gift_value, rank }`：先把书籍字段摊平一层
    -- （顺带把外层 rank/gift_value 塞进去，归一化里才能取到名次）。
    local flat = {}
    for _i, item in ipairs(list) do
        local bk = type(item) == "table" and item.book or nil
        if type(bk) == "table" then
            local copy = {}
            for k, v in pairs(bk) do copy[k] = v end
            copy.gift_value = item.gift_value
            copy.rank_pos = item.rank
            flat[#flat + 1] = copy
        end
    end
    local books, nerr = normalize_list(flat, "rank_praise", url)
    if not books then return nil, nerr end
    if #books == 0 then
        return nil, {
            kind = "rank_empty",
            message = T(_("「%1」暂时没有数据"), spec.label),
        }
    end
    for i, b in ipairs(books) do
        if b.rank_pos == nil then b.rank_pos = i end
    end
    return { books = books, total = #books, has_more = false }
end

--- 原创榜（男频/女频 × 阅读榜/新书榜 × 分类）。
---@param opts table { gender=1, rank_mold=2, category_id=1141,
---                    rank_version=nil, offset=0, limit=20 }
---@return table|nil { books, total, version, offset, has_more }, table|nil err
function Store.rank_category(client, opts)
    opts = opts or {}
    local gender = tonumber(opts.gender)
    if gender ~= Store.GENDER.male and gender ~= Store.GENDER.female then
        return nil, { kind = "arg", message = _("原创榜需要先选男频或女频") }
    end
    local category_id = tonumber(opts.category_id)
    if not category_id then
        return nil, { kind = "arg", message = _("原创榜需要先选一个分类") }
    end
    local url = FanQie.store_rank_category_url(opts)
    -- referer 用真实的榜单页，形如 /rank/<gender>_<mold>_<category>
    local referer = FanQie.BASE_URL .. "/rank/" .. tostring(gender) .. "_"
        .. tostring(tonumber(opts.rank_mold) or Store.RANK_MOLD.read) .. "_" .. tostring(category_id)
    local data, err = client:web_get_json(url, { referer = referer })
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    local dd = data.data
    if type(dd) ~= "table" then return nil, shape_error("data 不是对象", url) end
    local books, nerr = normalize_list(dd.book_list, "rank_category", url)
    if not books then return nil, nerr end
    local total = tonumber(dd.total_num) or #books
    local offset = tonumber(opts.offset) or 0
    return {
        books = books,
        total = total,
        -- 回传服务端解析出的榜单版本：翻下一页时带回去，避免榜单在翻页途中换榜
        version = dd.rankVersion,
        offset = offset,
        -- ⚠️ 服务端**不夹紧 offset**（offset=100 也照给 101.. 的书），
        --    所以「还有没有下一页」必须客户端自己算：拿满一页 **且** 还没到 total。
        has_more = (#books >= (tonumber(opts.limit) or 20)) and (offset + #books) < total,
    }
end

-- ------------------------------------------------------------------ 书架增删

--- 加入书架。`book_type`：0=小说（漫画也用 0，实测「非人哉」用 0 成功）。
---@return table|nil { book_id = "…" }, table|nil err
function Store.shelf_add(client, book_id, opts)
    opts = opts or {}
    if not FanQie.is_valid_book_id(book_id) then
        return nil, { kind = "arg", message = _("book_id 不能为空") }
    end
    local body = {
        identify_data = { {
            asterisked = false,
            -- Date.now() 语义：毫秒。服务端基本不用它，但字段缺失会被判非法。
            modify_time = tonumber(opts.modify_time) or (os.time() * 1000),
            book_type = tonumber(opts.book_type) or 0,
            book_id = tostring(book_id),
        } },
        -- AddBookShelfSource.User = 0（muye.js 枚举实测）
        add_book_source = 0,
    }
    local url = FanQie.store_shelf_add_url()
    local data, err = client:web_post_json(url, body, { referer = FanQie.BASE_URL .. "/" })
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    return { book_id = tostring(book_id) }
end

--- 移出书架。
function Store.shelf_remove(client, book_id)
    if not FanQie.is_valid_book_id(book_id) then
        return nil, { kind = "arg", message = _("book_id 不能为空") }
    end
    local body = {
        identify_data = { { book_id = tostring(book_id) } },
    }
    local url = FanQie.store_shelf_delete_url()
    local data, err = client:web_post_json(url, body, { referer = FanQie.BASE_URL .. "/" })
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    return { book_id = tostring(book_id) }
end

--- 这本书在不在书架里。
---
--- 判据只有一句：`code == 0 and data == 1` ⇒ 在架。
--- 🔴 一定要带 `book_id`（缺参数服务端回 100103「book_id 无效」，
---    历史上就是**没带参数**才被误记成「data 恒为 1，无法判断」）；
---    一定要带 Cookie（否则 101108「无用户信息」）。别拿 info 的全量名单来顶 ——
---    那是 24.7 KB，这个只要 39 字节。
---@return boolean|nil 在架?, table|nil err
function Store.shelf_check(client, book_id)
    if not FanQie.is_valid_book_id(book_id) then
        return nil, { kind = "arg", message = _("book_id 不能为空") }
    end
    local url = FanQie.shelf_check_url(book_id)
    local data, err = client:web_get_json(url, { referer = FanQie.BASE_URL .. "/" })
    if not data then return nil, err end
    if tonumber(data.code) ~= 0 then return nil, api_error(data, url) end
    return tonumber(data.data) == 1, nil
end

-- ------------------------------------------------------------------ 错误文案

--- 把 err 表转成用户可读的一行文案。
function Store.describe_error(err)
    if err == nil then return "" end
    if type(err) == "string" then return err end
    if type(err) ~= "table" then return tostring(err) end
    -- client.lua 的 auth_expired 表（理论上不会走到这里，兜底）
    if err.auth_expired == true then
        return _("Cookie 已过期，请重新登录番茄账号")
    end
    local kind = err.kind
    if kind == "empty" then
        return _("书城接口返回空响应（多为被限流，请稍后重试）")
    elseif kind == "not_json" then
        return _("书城接口返回了非 JSON 内容（可能触发了风控，请稍后重试）")
    elseif kind == "auth" then
        return _("请先登录番茄账号（书城部分接口需要 Cookie）")
    elseif kind == "transport" then
        return T(_("网络请求失败：%1"), tostring(err.message or ""))
    end
    return tostring(err.message or err)
end

-- ------------------------------------------------------------------ 排序文案

function Store.sort_label(value)
    local v = tonumber(value)
    if v == Store.SORT.hot then return _("最热") end
    if v == Store.SORT.words then return _("字数") end
    return _("最新")
end

function Store.gender_label(value)
    if tonumber(value) == Store.GENDER.female then return _("女频") end
    return _("男频")
end

--- 原创榜的榜名文案（Store.RANK_MOLD.read → 阅读榜）。
function Store.rank_mold_label(value)
    if tonumber(value) == Store.RANK_MOLD.new then return _("新书榜") end
    return _("阅读榜")
end

-- 书库「是否完结」筛选：服务端 creation_status 语义（-1=不限, 0=已完结, 1=连载中）
Store.CREATION_STATUS = {
    any = -1,
    finished = 0,
    ongoing = 1,
}

function Store.creation_status_label(value)
    local v = tonumber(value)
    if v == Store.CREATION_STATUS.finished then return _("已完结") end
    if v == Store.CREATION_STATUS.ongoing then return _("连载中") end
    return _("不限")
end

-- ------------------------------------------------------------------ 批量书籍详情

--- 书架 multidetail 批量详情（POST，需要 Cookie）。
-- 🔴 **只返回「已在书架」的书**（2026-10-14 实测更正）：
--    请求 3 本、其中 2 本在架 → `detail_list` 只回 2 条；单独请求 1 本不在架的
--    书 → `detail_list` 为空数组且 `code` 仍是 0（**不是错误**）。
--    未登录 → `{"code":-1,"message":"请先登录"}`。
--    旧注释写的「book_id 不要求在书架里」是错的 —— 书城列表调用本函数时，
--    不在书架的书拿不到任何增强字段，`Store.apply_detail` 不会被触发（静默降级）。
-- 响应 data.detail_list[]：creation_status / update_status / update_stop /
-- last_chapter_update_time / serial_count（总章数）/ real_chapter_order（读到第几章）/
-- abstract（简介）/ item_show_title + item_abstract（**跟着请求体的 item_id 走**，
-- 传进度里的 item_id 就是「最近阅读章节」，传 "0" 则是第 1 章）。
-- 返回 map[book_id] = detail 表；失败返回 nil, err（调用方应静默降级）。
function Store.book_details(client, book_ids, opts)
    if type(book_ids) ~= "table" or #book_ids == 0 then
        return {}, nil
    end
    local books = {}
    for i, id in ipairs(book_ids) do
        books[i] = { book_id = tostring(id), item_id = "0" }
    end
    local url = FanQie.store_multidetail_url()
    local data, err = client:web_post_json(url, { books = books }, opts)
    if not data then
        return nil, err
    end
    if tonumber(data.code) ~= 0 then
        return nil, {
            kind = "biz",
            code = data.code,
            message = T(_("书城接口返回业务错误 code=%1 message=%2（%3）"),
                tostring(data.code), tostring(data.message or ""), url),
        }
    end
    local dd = type(data.data) == "table" and data.data or {}
    if type(dd.detail_list) ~= "table" then
        return nil, {
            kind = "unexpected",
            message = T(_("书城接口返回结构不符合预期：%1（%2）"), "data.detail_list", url),
        }
    end
    local out = {}
    for _i, d in ipairs(dd.detail_list) do
        if type(d) == "table" and d.book_id ~= nil then
            out[tostring(d.book_id)] = d
        end
    end
    return out, nil
end

--- 把 multidetail 的 detail 归并进归一化的 book（就地修改）：
--- status_text 用 kindle-forge 的口径（FanqieShelf.vue formatStatus）：
---   creation_status == "0" → 已完结；update_stop == "1" → 已断更；否则连载中。
--- 注意 multidetail 的字段是**字符串**，而书库接口的 creation_status 是数字 —— 都兼容。
function Store.apply_detail(book, d)
    if type(book) ~= "table" or type(d) ~= "table" then return book end
    local finished = tostring(d.creation_status) == "0"
        or tonumber(d.creation_status) == 0
    local stopped = tostring(d.update_stop) == "1"
    if finished then
        book.status_text = _("已完结")
    elseif stopped then
        book.status_text = _("已断更")
    else
        book.status_text = _("连载中")
    end
    local serial = tonumber(d.serial_count)
    if serial and serial > 0 then
        book.total_chapters = serial
    end
    -- multidetail 的 creation_status 与书库接口同义，回写让别处（详情框等）口径一致
    if d.creation_status ~= nil then
        book.creation_status = tonumber(d.creation_status)
    end
    book.detail = {
        update_status = tonumber(d.update_status),
        last_chapter_update_time = tonumber(d.last_chapter_update_time),
        real_chapter_order = tonumber(d.real_chapter_order),
    }
    return book
end

--- 便捷：批量拉详情并就地合入 books（book.book_id 匹配）。返回合入条数。
--- 同一 book_id 出现多条时**每条都合入**（比如同页列表里同一本书出现两次）。
function Store.enhance_books(client, books, opts)
    if type(books) ~= "table" or #books == 0 then return 0 end
    local ids, groups = {}, {}
    for _i, b in ipairs(books) do
        local id = b and b.book_id and tostring(b.book_id) or nil
        if id then
            local g = groups[id]
            if not g then
                g = {}
                groups[id] = g
                ids[#ids + 1] = id
            end
            g[#g + 1] = b
        end
    end
    local map, err = Store.book_details(client, ids, opts)
    if not map then
        return nil, err
    end
    local n = 0
    for id, d in pairs(map) do
        local g = groups[id]
        if g then
            for _k, b in ipairs(g) do
                Store.apply_detail(b, d)
                n = n + 1
            end
        end
    end
    return n, nil
end

return Store
