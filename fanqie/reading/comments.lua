--[[--
番茄段评（/novel/commentapi/…）：App 协议实现。

移植自 kindle-forge `backend/fanqie/app_api.py` 的段评部分（§10）与
`backend/fanqie/api.py` 的 `get_para_comments`，协议细节见仓库根
《番茄段评接口-逆向分析.md》。关键坑：

  - idea/list（段评统计）只能 **GET 无 body**（POST 带 body → 200 空响应）
  - comment/list（段评列表）是 POST，但**绝不能带 x-ss-stub**（带上必回 110001）
  - comment_source=2 路由段评列表；reply/list 必须用 comment_source=5
  - body 必填：comment_source / comment_type=1 / group_type=15 /
    business_param.book_id；翻页是 body 里的 cursor 字符串偏移（首屏 ""）
  - 签名不合规时服务端返回的是 **200 空响应**（不是 4xx），所以「空响应」
    必须当失败上报，绝不能静默当成「本段没有段评」。

与 kindle-forge 的对应关系（改这里时请同步对照 Python 那份）：

  Comments.stats           ← app_api.comment_stats + normalize_stats
  Comments.list            ← app_api.fetch_comments
  Comments.replies         ← app_api.fetch_replies
  Comments.flatten_comment ← app_api.flatten_comment

🔴 **用户头衔在 `user_tag.user_title_info[].zh_title`**（v2.12.0 接入）：
  不是顶层字段、不在 base_info 里。`icon`/`label` 分别是图片与颜色 JSON，
  墨水屏一律不用，只取纯文本 `zh_title`；挂件 `sticker.sticker.name` 一并收。
  抽取函数 `Comments.titles_of(tag)`（结构注释与实测取值都写在它上面），
  两条 flatten 都会带上 `titles` / `is_vip`。
  ⚠️ 别在显示层重新解析 user_tag —— 归一化只做一次。

⚠️ 错误语义刻意对齐 kindle-forge 的 `_signed_request`：失败一律
返回非 nil 的 `err`（Python 那份是直接 raise RuntimeError）。
调用方必须把它转成用户可见的错误，不要退化成「0 条评论」。

@module fanqie.reading.comments
--
-- 版权与许可：本仓库以 GPL-3.0-only 分发，全文见根目录 LICENSE，
-- 上游来源清单见 THIRD_PARTY_NOTICES.txt。
--]]

local Crypto = require("fanqie.reading.crypto")
local Device = require("fanqie.reading.device")
local Reading = require("fanqie.reading")

local Comments = {}

local COMMENT_IDEA_PATH = "/novel/commentapi/idea/list/%s/v1/"
local COMMENT_LIST_PATH = "/novel/commentapi/comment/list/%s/v1/"
local COMMENT_REPLY_PATH = "/novel/commentapi/reply/list/%s/v1/"

local COMMENT_SOURCE = 2        -- 段评列表路由用
local COMMENT_TYPE = 1
local COMMENT_GROUP_TYPE = 15
local COMMENT_MAX_COUNT = 50    -- 单次上限
local REPLY_SOURCE = 5          -- 段评回复的 comment_source 必须是 5
local REPLY_MAX_COUNT = 50

local TIMEOUT = 20

-- commentapi 公共 query：在 reading 通用 query 上追加 compliance_status。
local function comment_query(device, ts_ms)
    local q = Crypto.build_common_query(device, ts_ms)
    q.compliance_status = "0"
    return q
end

--- 段评统计（idea/list，GET）。
---@param client table 本地 HTTP 客户端（Client 实例）
---@param settings table
---@param item_id string 章节ID
---@return table|nil stats { [段落序号 number] = { count, user_count, is_author_comment } }
---@return string|nil err 失败原因（非 nil 表示请求失败，不是「没有段评」）
function Comments.stats(client, settings, item_id)
    local device, derr = Device.ensure(client, settings)
    if not device then
        return nil, derr or "设备身份注册失败"
    end
    local data, err = Reading.signed_call(client, "comment_stats", device,
        COMMENT_IDEA_PATH:format(tostring(item_id)), comment_query, nil)
    if not data then
        return nil, err
    end
    local raw = data.data and data.data.data or {}
    if type(raw) ~= "table" then
        raw = {}
    end
    -- 归一化：键为段落序号（JSON 里是字符串），过滤 count<=0
    local out = {}
    for k, v in pairs(raw) do
        local pid = tonumber(k)
        if pid and type(v) == "table" then
            local n = tonumber(v.count) or 0
            if n > 0 then
                out[pid] = {
                    count = n,
                    user_count = tonumber(v.user_count) or 0,
                    is_author_comment = v.is_author_comment == true,
                }
            end
        end
    end
    return out
end

--- 段评列表一页（comment/list，POST 不带 x-ss-stub）。
---@param client table
---@param settings table
---@param item_id string 章节ID
---@param book_id string 书籍ID
---@param para_index number 段落序号（正文 blk 的 p_idx）
---@param opts table|nil { count, cursor, sort, item_version }
---   sort（2026-10-26 APK 字节码级还原：GetCommentListRequest.UgcSortEnum 只有三个值）：
---     1=SmartHot 智能热门（App 默认，权重在服务端）2=TimeAsc 时间正序 3=TimeDesc 时间倒序。
---     旧版默认传 0 是 web 协议语义（0=最热），App 枚举里没有 0 —— 缺省一律按 1。
---@return table|nil data_list 原始条目数组（未经归一，用 flatten_comment 转换）
---@return table|nil info { cursor, has_more, total }
---@return string|nil err
function Comments.list(client, settings, item_id, book_id, para_index, opts)
    opts = opts or {}
    local device, derr = Device.ensure(client, settings)
    if not device then
        return nil, nil, derr or "设备身份注册失败"
    end
    local body = client:json_encode({
        chapter_id = tostring(item_id),
        comment_source = COMMENT_SOURCE,
        comment_type = COMMENT_TYPE,
        group_type = COMMENT_GROUP_TYPE,
        count = math.min(math.floor(tonumber(opts.count) or 20), COMMENT_MAX_COUNT),
        -- UgcSortEnum：1=SmartHot（App 默认）/ 2=TimeAsc / 3=TimeDesc。
        -- 0 不在枚举里（旧 web 语义），缺省按 1 走「智能热门」。
        sort = math.floor(tonumber(opts.sort) or 1),
        cursor = tostring(opts.cursor or ""),
        business_param = {
            book_id = tostring(book_id),
            item_version = tostring(opts.item_version or "0"),
            para_index = math.floor(tonumber(para_index) or 0),
        },
    })
    local data, err = Reading.signed_call(client, "comment_list", device,
        COMMENT_LIST_PATH:format(tostring(item_id)), comment_query,
        function(c) return body end)
    if not data then
        return nil, nil, err
    end
    local d = data.data or {}
    if type(d.data_list) ~= "table" then
        -- code==0 但没有 data_list：服务端没给数据（可能被限流/风控），
        -- 上报成错误而不是空列表，避免上层显示成「共 0 条」。
        return nil, nil, "段评列表响应缺少 data_list"
    end
    local info = type(d.common_list_info) == "table" and d.common_list_info or {}
    return d.data_list, info
end

--- 段评回复（reply/list，POST）。回复哪条只由 URL 里的 {comment_id} 决定，
--- body 里唯一必填的是 comment_source=5（count 不给默认 0 → 空数组）。
---@param client table
---@param settings table
---@param comment_id string|number 被回复的段评ID
---@param opts table|nil { count, cursor }
---@return table|nil reply_list, table|nil comment_list_info, string|nil err
function Comments.replies(client, settings, comment_id, opts)
    opts = opts or {}
    local device, derr = Device.ensure(client, settings)
    if not device then
        return nil, nil, derr or "设备身份注册失败"
    end
    local body = client:json_encode({
        comment_id = tostring(comment_id),
        comment_source = REPLY_SOURCE,
        comment_type = COMMENT_TYPE,
        group_type = COMMENT_GROUP_TYPE,
        count = math.min(math.floor(tonumber(opts.count) or REPLY_MAX_COUNT), REPLY_MAX_COUNT),
        cursor = tostring(opts.cursor or ""),
    })
    local data, err = Reading.signed_call(client, "reply_list", device,
        COMMENT_REPLY_PATH:format(tostring(comment_id)), comment_query,
        function(c) return body end)
    if not data then
        return nil, nil, err
    end
    local d = data.data or {}
    if type(d.reply_list) ~= "table" then
        return nil, nil, "段评回复响应缺少 reply_list"
    end
    local info = type(d.comment_list_info) == "table" and d.comment_list_info or {}
    -- ⚠️ 「空成功」闸门（2026-10-17，排查「展开回复后空白」时定性）：
    --    commentapi 对被风控的请求同样回 200 + code=0，只是 reply_list 为空数组
    --    （与「签名不合规回 200 空响应」同一族，只是这次有 JSON 壳）。若放行，
    --    上层会把这份空结果当「成功、零条回复」缓存住（expanded + pages=1）⇒
    --    展开后空白，且「纯展开零请求」分支把它**粘死**（收起再展开也永远不再
    --    发请求）。第一页就 0 条而服务端 total>0 ⇒ 明确报错，让上层弹「失败」。
    --    （total 也可能一并被抹成 0 —— 那一种由 main.lua 的合并闸门按评论自身的
    --    reply_count 兜住，两层缺一不可。）
    if #(d.reply_list) == 0 and tonumber(info.total or 0) > 0 then
        return nil, nil, "段评回复列表返回为空（可能被风控），total=" .. tostring(info.total)
    end
    return d.reply_list, info
end

-- 单条评论最多展示几个头衔。实测一条最多 2 个（「作家」+「次元破壁神」），
-- 但接口没保证；一屏几十条评论，头衔太多会把头行挤成两行。
Comments.MAX_TITLES = 3

--- 从 user_tag 抽取**纯文本**头衔列表。
--
-- 真实结构（2026-10-14 抓真实响应实测，见 .workbuddy/tools/_probe_comment_title*.py；
-- 2026-10-25 复探（v2.16.32）：user_tag 字段没有变，补齐了 App 有而我们漏的标签）：
--   user_tag = {
--     is_author / is_vip / is_blue_vip / is_cp / is_official_cert = bool,
--     user_title_info = { { zh_title = "作家",      en_title = "author",
--                           is_author_title = true,  is_vip_title = false,
--                           intro = "<JSON 字符串>", -- {title_name,title_id,…}
--                           label = "<JSON 字符串>", -- {title_text,title_default_color,…}
--                           icon  = "<JSON 字符串>"  -- {icon_default_url,icon_width,…}
--                         }, … },
--     sticker = { is_worn = true, sticker = { name = "故事合伙人", url = …, … } },
--     fan_rank_num / fan_ranklist_title = 粉丝榜（实测恒 0/""，App 也不渲染成文字）
--   }
--
-- 🔴 只取 `zh_title`，且**跳过 `is_vip_title == true` 的条目**（v2.16.32）：
--   · `icon` 是**图片**、`label` 是**颜色 JSON** —— 墨水屏既画不了色，
--     也不该为一个头衔再发起一次图片请求（段评图已经够贵了）。
--   · `zh_title` 实测取值：「作家」「作家Lv.2」「vip」「svip」「次元破壁神」
--     「灵感探索者」「满级诡客」「巅峰造浪人」…（vip/svip 就是小写英文原样）。
--     🔴 App 里 VIP 是**图标**不是文字标签 —— 旧版照单全收把「vip」渲染成
--     「［vip］」，就是用户报的「标签和 App 上显示的不一样」。
-- ⚠️ `user_title_info` 里少数条目**没有 zh_title**（或为空串）——必须跳过，
--    否则会渲染出空括号「［］」。
-- ⚠️ 挂件（`sticker.sticker.name`，如「故事合伙人」）在 App 里同样是名字旁的
--    装饰，一并收进头衔列表（`is_worn == false` 的不算）。
-- 🔴 布尔标签补齐（v2.16.32）：App 会渲染「官方」「小编」徽标而旧版没显示 ——
--    `is_official_cert` → 「官方」、`is_cp` → 「小编」；`is_vip`/`is_blue_vip`
--    在 App 里都是图标，文字渲染跳过（否则满屏［VIP］比 vip 头衔还吵）。
--
-- 🔴 顺序与去重对齐《番茄小说-开源阅读书源.json》（v2.16.35）：
--    该书源 jsLib 的 `fqCommentTags()` 是同一份协议的另一份成熟实现，它给出的
--    优先级是 **身份徽标 → 头衔 → 粉丝榜 → 作者赞过 → 挂件**，并且有三个容易被
--    漏掉的判定：
--      1. 官方/小编 与 作者 是**互斥**的身份徽标（if/elseif）—— 不能既打「作者」
--         又打「官方」，一条评论的头部只认一个身份；
--      2. 本书作者走 `pushTitles(true)`：把 `is_author_title` 的条目从「头衔流」
--         里**剔除**（它内容通常就是「作家」），否则会出现「［作者］［作家］」
--         这种同义重复 —— 这是旧版真实存在的观感问题；
--      3. 粉丝榜只在 `fan_rank_num` 属于 1..100 且 `fan_ranklist_title` 非空时才
--         成文字（App 里是带名次的彩底徽标，墨水屏只取文案）。
--    「作者赞过」三个来源（`user_action.author` / `has_author_digg` /
--    `author_digg_time`）由 flatten 归一成 `author_digg` 传进来；本书作者自己
--    发的段评不标它（书源同样把 digg 按 `is_author !== true` 过滤）。
--
-- @param tag table user_info.user_tag（可为 nil）
-- @param author_digg boolean|number|nil 「作者赞过」标记（见 flatten_comment）
-- @return table 字符串数组（保持接口给的顺序，已去重，最多 MAX_TITLES 个）
function Comments.titles_of(tag, author_digg)
    local out = {}
    if type(tag) ~= "table" then return out end

    -- `_` 是 KOReader 的全局 gettext。本模块刻意不在顶层 require gettext
    -- （保持「纯数据模块可离线单测」），取不到就原样返回中文。
    local function tr(s)
        if type(_) == "function" then return _(s) end
        return s
    end

    local seen = {}
    local full = false
    local function add(name)
        if full or type(name) ~= "string" then return end
        name = name:match("^%s*(.-)%s*$")
        if name == "" or seen[name] then return end
        seen[name] = true
        out[#out + 1] = name
        if #out >= Comments.MAX_TITLES then full = true end
    end

    local list = tag.user_title_info
    -- `skip_author_title` = 本书作者分支：把「作家」这类身份头衔剔出去（去重）
    local function add_titles(skip_author_title)
        if type(list) ~= "table" then return end
        local used = 0
        local function one(t)
            if full or type(t) ~= "table" then return end
            if t.is_vip_title == true then return end          -- VIP 是图标语义
            if skip_author_title and t.is_author_title == true then return end
            local before = #out
            add(t.zh_title)
            if #out > before then used = used + 1 end
        end
        for _i, t in ipairs(list) do one(t) end
        -- 万一拿到的是「数字键的对象表」（部分解码器/服务端把空数组写成 {}），
        -- ipairs 一条都取不到 ⇒ 退回 pairs 再扫一遍。
        if used == 0 and next(list) ~= nil and type(list[1]) ~= "table" then
            for _k, t in pairs(list) do one(t) end
        end
    end

    local digg = (author_digg == true or author_digg == 1) and tag.is_author ~= true

    if tag.is_official_cert == true or tag.is_cp == true then
        add(tag.is_official_cert == true and tr("官方") or tr("小编"))
        add_titles(false)
        if digg then add(tr("作者赞过")) end
    elseif tag.is_author == true then
        add(tr("作者"))
        add_titles(true)   -- 剔除 is_author_title：防「［作者］［作家］」重复
    else
        add_titles(false)
        local rank = tonumber(tag.fan_rank_num)
        local ft = tag.fan_ranklist_title
        if rank and rank >= 1 and rank <= 100 and type(ft) == "string" then
            add(ft)
        end
        if digg then add(tr("作者赞过")) end
    end

    -- 挂件（装扮）永远排最后：它是装饰，不是身份。过期的挂件不算
    -- （`expire_time` 秒级时间戳，-1 = 永久，缺字段按永久兜底）。
    local st = tag.sticker
    if type(st) == "table" and st.is_worn == true then
        local inner = st.sticker
        if type(inner) == "table" then
            local e = tonumber(st.expire_time)
            if not e or e == -1 or (e > 0 and e > os.time()) then
                add(inner.name)
            end
        end
    end
    return out
end

--- `content.image_data_list` → **单图对象数组**（不管外面套了几层）。
---
--- 🔴 真实结构（2026-10-14 实测，app commentapi，`.workbuddy/tools/_probe_comment_images.py`）：
---      content.image_data_list = { image_data = { {web_url=…, width=360, height=220, …} } }
---    注意 `image_data` 是**字符串 key**，它的 **value（数组）才是图片**。
---    旧代码 `for _, v in pairs(content.image_data_list) do images[#images+1] = v end`
---    存进去的是 value —— 也就是那个数组本身 ⇒ `normalize_images` 里
---    `wrap.image_data` 取到 nil，再退化成「把这个数组当成一条图片记录」⇒
---    `web_url` / `dynamic_url` / `url` 全是 nil ⇒ **整条评论的图片被静默丢掉**。
---    症状：段评**一条图都看不到**（连「正在后台加载…」的占位行都没有），
---    而文字、头衔、点赞、点击交互全部正常 —— 所以很容易被误判成「渲染或下载的问题」。
---
--- 三种形态都要吃（服务端换过一次外层，缓存里也可能残留旧形态）：
---   A `{ image_data = {…} }`（map，key 是 "image_data"）  ← 当前实测
---   B `{ {…}, … }`（数组，元素才是单图）                  ← 旧缓存
---   C `{…}`（本身就是单图对象）
local function collect_images(image_data_list)
    local out = {}
    local function take(v, depth)
        if type(v) ~= "table" or depth > 4 then return end
        if next(v) == nil then return end              -- 空表：不是图，别塞进去
        if type(v.image_data) == "table" then          -- 形态 A
            take(v.image_data, depth + 1)
            return
        end
        if #v > 0 then                                 -- 形态 B
            for _i, one in ipairs(v) do take(one, depth + 1) end
            return
        end
        out[#out + 1] = v                              -- 形态 C：单图对象
    end
    take(image_data_list, 0)
    return out
end

--- 段评条目 → 扁平结构（app_api.flatten_comment 的等价物）。
--- 字段真实位置（实测）：点赞数 / 回复总数都在 comment.stat（顶层），
--- expand.common_stat 恒为 {}，expand.reply_show_count 只是列表页预览条数。
---@param item table 原始条目
---@return table 扁平字段（user_name / text / digg_count / reply_count / create_time / is_author …）
function Comments.flatten_comment(item)
    local c = (type(item) == "table" and (item.comment or item)) or {}
    local common = type(c.common) == "table" and c.common or {}
    local user_info = type(common.user_info) == "table" and common.user_info or {}
    local base = type(user_info.base_info) == "table" and user_info.base_info or user_info
    local tag = type(user_info.user_tag) == "table" and user_info.user_tag or {}
    local ex = type(c.expand) == "table" and c.expand or {}
    local pos = type(ex.comment_pos) == "table" and ex.comment_pos or {}
    local content = type(common.content) == "table" and common.content or {}
    local stat = type(c.stat) == "table" and c.stat
        or (type(ex.comment_stat) == "table" and ex.comment_stat or {})
    local act = type(c.user_action) == "table" and c.user_action or {}

    -- 「作者赞过」的**三个**来源（书源 fqFlattenComment 同款）：user_action.author
    -- （1/true）、顶层 has_author_digg、author_digg_time>0。
    -- 只取 user_action 会漏掉后两种 —— 老接口只回时间戳的那种。
    local author_digg = act.author == true or act.author == 1
        or c.has_author_digg == true
        or (tonumber(c.author_digg_time) or 0) > 0

    return {
        comment_id = c.comment_id,
        user_id = base.user_id,
        user_name = base.user_name or common.user_name,
        avatar = base.user_avatar,
        is_author = tag.is_author == true,
        -- 头衔（纯文本数组，见 Comments.titles_of 的注释）。顺序已含「作者」徽标，
        -- 显示层**不要**再补一个（会变成「［作者］［作者］」）。
        titles = Comments.titles_of(tag, author_digg),
        author_digg = author_digg,
        is_vip = tag.is_vip == true or tag.is_blue_vip == true,
        text = content.text or common.text or "",
        images = collect_images(content.image_data_list),
        create_time = common.create_timestamp or common.create_time,
        digg_count = tonumber(stat.digg_count) or 0,
        user_digg = act.user_digg == true,
        reply_count = tonumber(stat.reply_count) or 0,
        reply_preview_count = tonumber(ex.reply_show_count) or 0,
        para_index = pos.start_para_index,
        para_src_content = ex.para_src_content,
        item_version = ex.item_version,
    }
end

--- 段评回复条目 → 扁平结构（app_api.flatten_reply 的等价物）。
--- ⚠️ 与段评条目不同：回复对象的公共块叫 **Common（大写 C）**；
---    sub_reply 实测恒空（段评回复是平铺结构），层级只能靠
---    reply_to_reply_id 指向父回复，还原层级请用 build_reply_tree。
---@param item table 原始回复条目
---@return table 扁平字段
function Comments.flatten_reply(item)
    if type(item) ~= "table" then return {} end
    local common = type(item.Common) == "table" and item.Common
        or (type(item.common) == "table" and item.common or {})
    local user_info = type(common.user_info) == "table" and common.user_info or {}
    local base = type(user_info.base_info) == "table" and user_info.base_info or user_info
    local tag = type(user_info.user_tag) == "table" and user_info.user_tag or {}
    local content = type(common.content) == "table" and common.content or {}
    local stat = type(item.stat) == "table" and item.stat or {}
    local act = type(item.user_action) == "table" and item.user_action or {}
    local to_info = type(item.reply_to_user_info) == "table" and item.reply_to_user_info or {}
    local to_base = type(to_info.base_info) == "table" and to_info.base_info or to_info

    local parent_reply_id = item.reply_to_reply_id
    if parent_reply_id == "" then
        parent_reply_id = nil
    end

    local author_digg = act.author == true or act.author == 1
        or item.has_author_digg == true
        or (tonumber(item.author_digg_time) or 0) > 0

    return {
        reply_id = item.reply_id,
        parent_comment_id = item.reply_to_comment_id,
        parent_reply_id = parent_reply_id,
        reply_to_user_id = to_base.user_id,
        reply_to_user_name = to_base.user_name,
        user_id = base.user_id,
        user_name = base.user_name,
        avatar = base.user_avatar,
        is_author = tag.is_author == true,
        titles = Comments.titles_of(tag, author_digg),
        author_digg = author_digg,
        is_vip = tag.is_vip == true or tag.is_blue_vip == true,
        text = content.text or "",
        images = collect_images(content.image_data_list),
        create_time = common.create_timestamp or common.create_time,
        digg_count = tonumber(stat.digg_count) or 0,
        user_digg = act.user_digg == true,
        reply_count = tonumber(stat.reply_count) or 0,
    }
end

--- 扁平回复列表 → 嵌套树（build_reply_tree 的 Lua 版，对齐 kindle-forge）。
--- 父回复被分页切开时该节点退化成根节点（**不丢条**）；每个节点带 depth。
---@param flat table 扁平回复数组（flatten_reply 的产物）
---@return table roots 根节点数组，children 递归嵌套
function Comments.build_reply_tree(flat)
    local by_id = {}
    local order = {}
    for _, r in ipairs(flat or {}) do
        if r.reply_id then
            local node = {}
            for k, v in pairs(r) do
                node[k] = v
            end
            node.children = {}
            by_id[r.reply_id] = node
            order[#order + 1] = node
        end
    end

    local roots = {}
    for _i, node in ipairs(order) do
        local parent = node.parent_reply_id and by_id[node.parent_reply_id]
        if parent and parent ~= node then
            parent.children[#parent.children + 1] = node
        else
            roots[#roots + 1] = node
        end
    end

    -- 防环（kindle-forge 的同名函数没有这一步）：若服务端给出互相引用的回复
    -- （A 的父是 B、B 的父是 A），上面的挂法会形成**没有根的环**，walk 从空的
    -- roots 出发 ⇒ 整环的回复被**静默丢弃**（既看不到、也没报错）。
    -- 这里把「从已确定的根不可达」的节点提升为根：层级可能看起来平一点，
    -- 但绝不丢条。正常数据（真有根）不受影响 —— 提升分支永不触发。
    do
        local reachable = {}
        local stack = {}
        for _j, r in ipairs(roots) do
            stack[#stack + 1] = r
        end
        while #stack > 0 do
            local n = stack[#stack]
            stack[#stack] = nil
            if not reachable[n] then
                reachable[n] = true
                for _j, c in ipairs(n.children) do
                    stack[#stack + 1] = c
                end
            end
        end
        for _j, node in ipairs(order) do
            if not reachable[node] then
                local parent = node.parent_reply_id and by_id[node.parent_reply_id]
                if parent then
                    -- 先从父的 children 摘掉自己，断开「父→子→父」这条环边
                    for k, c in ipairs(parent.children) do
                        if c == node then
                            table.remove(parent.children, k)
                            break
                        end
                    end
                end
                roots[#roots + 1] = node
                local st = { node }
                while #st > 0 do
                    local m = st[#st]
                    st[#st] = nil
                    if not reachable[m] then
                        reachable[m] = true
                        for _j, c in ipairs(m.children) do
                            st[#st + 1] = c
                        end
                    end
                end
            end
        end
    end

    local function walk(nodes, depth)
        -- 时间正序，保持与 App 端一致的阅读顺序
        table.sort(nodes, function(a, b)
            return (tonumber(a.create_time) or 0) < (tonumber(b.create_time) or 0)
        end)
        for _k, node in ipairs(nodes) do
            node.depth = depth
            walk(node.children, depth + 1)
        end
    end
    walk(roots, 0)

    return roots
end

-- ===========================================================================
-- 段评图片
-- ===========================================================================
-- 原始结构（实测 2026-10，app commentapi）：
--   comment.common.content.image_data_list = { image_data = { {…}, {…} } }
--   单个 image_data 项：
--     web_url / dynamic_url / expand_web_url  ← 三者实测**同一条**签名 URL
--     thumb_nails = { { dynamic_url = … } }   ← 实测也只是同一条（表情类）
--     width / height / image_type / id / format("")
--
-- ⚠️ `flatten_comment` / `flatten_reply` 已经把层级拆平（`collect_images`），
--    存进 `images` 的是**单图对象**，可以直接取 `im.web_url`。
--    但磁盘上的 `para_reviews_*.lua` 缓存可能是旧版本写的（那时候存的是
--    `{ image_data = {…} }` 甚至 `{ {…} }`），所以 `normalize_images` 里
--    对这两种包装形态仍然要兼容 —— 删缓存不是修复手段。
--
-- ⚠️ 图片格式由 CDN 路径后缀决定，**不能**靠 Accept 头协商（实测三种 Accept
--    都返回同一种内容）。两种后缀：
--      ~tplv-…:300:0.awebp   → WebP（image_type=2，平台表情/动图）—— KOReader 可渲染
--      ~tplv-…-jpeg.heic     → HEIC（image_type=1，用户上传的原图）
--    HEIC 是 HEVC 编码的 HEIF（ftypheic + hvcC 实测），设备端无解码器 →
--    **不可显示**，必须显式告知用户，不能静默丢图。

local IMAGE_EXT_UNSUPPORTED = {
    heic = true, heif = true, avif = true, tif = true, tiff = true,
}

--- 从 URL 路径后缀判定图片格式（**小写**、无点）。判定失败返回 nil。
--- 必须 lower()：CDN 现在给的是小写，但大写后缀（.HEIC）会被误判成
--- 「未知格式 → 可显示」，进而让设备去解码 HEIC 失败。
local function image_ext(url)
    if type(url) ~= "string" then return nil end
    local path = url:match("^[^?]*") or url
    local ext = path:match("%.([%a%d]+)$")
    return ext and ext:lower() or nil
end

-- ---------------------------------------------------------------------------
-- HEIC → 可显示格式（借服务端实时转码）
-- ---------------------------------------------------------------------------
-- HEIC 是 HEVC 编码的 HEIF，KOReader 设备端**没有解码器**，下载下来也渲不出来，
-- 所以在设备上自己转码是不可能的。但番茄的图片 CDN 支持**按后缀实时转码**：
--
--   实测（2026-10-14，脚本 .workbuddy/tools/_probe_heic{,2,3}.py）
--     签名 host（p3-reading-sign.fqnovelpic.com）的 **path 整体被签名覆盖**
--       ⇒ 改动 path 任何一段（含后缀）必 403；给 query **追加**参数不破坏签名，
--         但 x-tos-process / x-oss-process / format / image_format 等一律不生效。
--     改走**无签名 host** + **公共模板**则可行：
--       https://p3-novel.byteimg.com/<原 path 到 ~tplv 之前>~tplv-1yzifmftcy-expand:<宽>:0:0.webp
--       → 200 image/webp（服务端实时转码）
--   证据：
--     · 4 个不同图 ID × 2 个桶（tos-cn-i-1yzifmftcy / tos-cn-i-0000）全部 200；
--     · 后缀 .webp / .jpeg / .jpg / .png 都可（.jpeg 与 .jpg 返回完全相同的字节）；
--     · 宽度 144/200/600/800/1080 均生效（144→1.4KB、1080→21.8KB）；
--     · 不存在的图 ID → 404（**不是**通配放行）；p9-novel → 403 ACCESS DENIED（用 p3/p6）。
--   ⚠️ 必须**换掉样式名**：原样式（如 s85hriknmn-jpeg）是私有模板，无签名访问 403；
--      模板还必须带尺寸参数，少写 `:w:0:0` 回 400「incorrect template」。
--   ⚠️ 只对 `tos-cn-i-*` 对象桶与 `img/novel-static` 路径有效：
--      `ies.fe.effect`（平台表情）换 host 后 403 domain forbidden，故白名单外一律不动。
--   附带好处：转出来的 URL **不带签名**，不再受 x-expires（约 1 个月）约束。

--- 转换后请求的目标宽度（px）。段评图内嵌上限 ≈ 内容宽 × 0.6，设备逻辑宽度多为
--- 600–1080，取 800 兼顾清晰与流量。
local CONVERT_WIDTH = 800
local NOSIGN_HOST = "https://p3-novel.byteimg.com"
local PUBLIC_STYLE = "1yzifmftcy-expand"

--- 把 URL 换成「无签名 host + 公共模板 + webp」形态，让 HEIC 之类的不可显示格式
--- 被服务端转码成 WebP 后再下载。
--- 只处理白名单路径；识别不出（表情路径、未知 host、无 `~tplv` 段）时返回 nil，
--- 调用方保留原来的「不可显示」判定，不猜。
---@param url string 原始 URL（可带签名 query）
---@param width number|nil 目标宽度，默认 800
---@return string|nil converted URL
function Comments.to_webp_url(url, width)
    if type(url) ~= "string" or url == "" then return nil end
    local nq = url:match("^[^?]*")                   -- 去掉 query（签名都在 query 里）
    local host, path = nq:match("^https?://([^/]+)(/.*)$")
    if not host or not path then return nil end
    -- 只认番茄自家的图片域；陌生 host 一律不重写（避免把任意 URL 指到我们的 CDN）
    if not (host:find("fqnovelpic.com", 1, true) or host:find("byteimg.com", 1, true)) then
        return nil
    end
    local head = path:match("^(.*)~tplv")            -- `~tplv` 样式段之前的部分
    if not head or head == "" then return nil end
    -- 白名单：对象桶 / 公共静态目录（其余路径实测换 host 后 403）
    if not (head:match("^/tos%-cn%-i%-[%w]+/[^/]+$")
        or head:match("^/img/novel%-static/[^/]+$")) then
        return nil
    end
    local w = math.floor(tonumber(width) or CONVERT_WIDTH)
    if w < 16 then w = 16 end
    if w > 2048 then w = 2048 end
    return string.format("%s%s~tplv-%s:%d:0:0.webp", NOSIGN_HOST, head, PUBLIC_STYLE, w)
end

--- 把 flatten_* 里的 images 归一成扁平列表。
--- 返回数组，每项
---   { url, fetch_url, width, height, image_type, format, converted, displayable }。
--- `url` 是服务端原值（提示文案用）；`fetch_url` 才是实际要下载的地址
--- （HEIC 转换过则指向转码 URL，否则与 url 相同）。`format` 是**实际下载**格式。
--- 顺序保留服务端给出的顺序（表情类前面可能重复出现同一条，原样保留）。
function Comments.normalize_images(images)
    local out = {}
    if type(images) ~= "table" then return out end
    for _i, wrap in ipairs(images) do
        local entries
        if type(wrap) == "table" and type(wrap.image_data) == "table" then
            -- 外层包装：{ image_data = { {…}, … } }
            entries = wrap.image_data
            if entries.web_url or entries.url then
                entries = { entries }   -- 服务端只给单个对象（非数组）时的兜底
            end
        elseif type(wrap) == "table" and #wrap > 0 then
            -- 数组形态：{ {…}, … } —— 旧版本 flatten_* 直接存下来的就是这一层
            -- （见 collect_images 的注释：那正是「一条图都看不到」的根因）。
            -- 旧缓存里就是它，所以这里必须能吃。
            entries = wrap
        elseif type(wrap) == "table" then
            entries = { wrap }          -- 已扁平化（当前版本）的兜底
        end
        for _j, im in ipairs(entries or {}) do
            if type(im) == "table" then
                local url = im.web_url or im.dynamic_url or im.url
                    or (type(im.thumb_nails) == "table"
                        and type(im.thumb_nails[1]) == "table"
                        and im.thumb_nails[1].dynamic_url)
                if url and url ~= "" then
                    local ext = image_ext(url)
                    local unsupported = (ext and IMAGE_EXT_UNSUPPORTED[ext] == true) or false
                    -- 不可显示格式：先试着换成公共模板让服务端转码成 WebP。
                    -- 转成了就照常下载显示（format 改成真实下载格式，缓存名才与内容一致）。
                    local fetch_url, fmt, converted = url, ext, false
                    if unsupported then
                        local conv = Comments.to_webp_url(url)
                        if conv then
                            fetch_url, fmt, converted = conv, "webp", true
                        end
                    end
                    out[#out + 1] = {
                        url = url,
                        fetch_url = fetch_url,
                        width = tonumber(im.width) or 0,
                        height = tonumber(im.height) or 0,
                        image_type = tonumber(im.image_type),
                        format = fmt,
                        converted = converted,
                        -- 后缀缺失/未知时**按可显示处理**：宁可下载后渲染失败
                        -- 也不要因为判不出来就直接隐藏（失败会在 UI 上出声）。
                        -- HEIC 系：转码成功才算可显示，转不了就如实说不能显示。
                        displayable = (not unsupported) or converted,
                    }
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- 头像：同一套「不可显示就换服务端转码」的规则，但**尺寸另算**
-- ---------------------------------------------------------------------------
-- 实测（2026-10-26，`.workbuddy/tools/_probe_avatar_heic.py` / `_probe_comment_img_coverage.py`）：
--   · 真实用户头像多是**签名 host + 私有模板**，后缀 `.heic`
--     （`p9-reading-sign.fqnovelpic.com/tos-cn-i-1yzifmftcy/<id>~tplv-s85hriknmn-jpeg-v1:144:0.heic?签名`）
--     ⇒ 必须换 host + 公共模板，与正文图同一条路；
--   · 默认/公共头像走 `p3-novel.byteimg.com/img/novel-static/<id>~tplv-1yzifmftcy-expand:200:0:0.heic`
--     （本来就无签名 + 公共模板），换模板同样 200；
--   · 还有一类 passport 域（`p9-passport.byteacctimg.com` 的 `.image`、
--     `p-passport-sign.bytedance.net` 的 `.jpeg`）——**白名单外、也本来就不是 HEIC**
--     （实测 `.image` 返回 PNG）⇒ to_webp_url 返回 nil，按原 URL 下载即可。
--   · 覆盖率（3 份真实抓包，120 个头像）：116 个可转，4 个是 passport 域（无需转）。
--- 头像请求宽度。144 实测 1.7 KB（200 时 2.7 KB）——段评里按 26 逻辑像素渲染，
--- 144 已足够，且比正文图的 800 省一个数量级的流量。
local AVATAR_WIDTH = 144

--- 头像 URL 归一。字段口径与 `normalize_images` 的单项**完全一致**，
--- 便于 main.lua 用同一套下载/缓存代码（`fetch_url or url`、`format` 决定扩展名）。
---@param url string|nil 服务端给的 user_avatar
---@return table|nil entry { url, fetch_url, width, height, image_type, format, converted, displayable }
function Comments.avatar_entry(url)
    if type(url) ~= "string" or url == "" then return nil end
    local ext = image_ext(url)
    local unsupported = (ext and IMAGE_EXT_UNSUPPORTED[ext] == true) or false
    local fetch_url, fmt, converted = url, ext, false
    if unsupported then
        local conv = Comments.to_webp_url(url, AVATAR_WIDTH)
        if conv then
            fetch_url, fmt, converted = conv, "webp", true
        end
    end
    return {
        url = url,
        fetch_url = fetch_url,
        width = AVATAR_WIDTH,
        height = AVATAR_WIDTH,
        image_type = nil,
        format = fmt,
        converted = converted,
        displayable = (not unsupported) or converted,
    }
end

Comments.TIMEOUT = TIMEOUT
Comments.COMMENT_MAX_COUNT = COMMENT_MAX_COUNT
Comments.REPLY_MAX_COUNT = REPLY_MAX_COUNT
Comments.COMMENT_SOURCE = COMMENT_SOURCE
Comments.REPLY_SOURCE = REPLY_SOURCE

return Comments
