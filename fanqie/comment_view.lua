--[[--
段评视图：可滚动、图片内嵌、回复一键展开。

与 TextViewer 的差别：内容不是纯文本，而是「头行 + 正文 + 内嵌图片 + 回复块」
的 VerticalGroup，装在 ScrollableContainer 里。

设计约束（有意为之，别"优化"回去）：
  * 评论块的「头行 + 正文」整体是**可点行**（`TapRow`）：点一下展开/收起**该条**回复；
    「… 还有 N 条回复」那一行**单独可点**，点它继续加载该条更多回复。
  * **内嵌图片也可点**（v2.12.0 起）：点图开全屏预览（落点 `on_image_tap`）。
    图片在 `inner` 里与「头行+正文」**平级**，不在后者的点击区之内
    ⇒ 点图不会误触「展开回复」。**不可显示的图（HEIC 等）不给 tap**；
    「正在后台加载…」的占位行可点（点它当场下载并打开，不必等预取）。
  * 为什么滚动区里点得动：`ScrollableContainer` 的 `ges_events` 只声明
    touch / swipe / hold / hold_pan / hold_release / pan / pan_release —— **没有 tap**；
    且 `ScrollableContainer:propagateEvent` 会把**视野内**的事件先交给子控件
    （不是先给自己）⇒ tap 先到 `TapRow`，pan 才轮到滚动。
    官方同姿势先例：`ui/widget/htmlboxwidget.lua`（词典弹窗里的链接就是
    `ges = "tap"` + `range = function() return self.dimen end` 塞在滚动区里）。
  * ⚠️ **别再写「内容区不能挂任何 tap」**：v2.8.0 那条结论说的是「**图片**上挂 tap
    跨版本转发不稳」（当时为点图放大做过），不是滚动区的限制。两者别混。
    （v2.12.0 已用真源码确认图片同样能被 `TapRow` 包住并接到 tap。）
  * v2.16.8 起没有「展开全部回复」批量按钮：单条展开/收起靠点头行，
    更多回复靠「… 还有 N 条回复」行。
  * 图片自动串行下载并逐张回填（refresh()），不需要用户逐张点；点图只是"想放大看"的捷径。

职责边界：
  * 本模块**只渲染**。头行文案、回复树、图片缓存路径的组装、以及「点一下要干什么」
    （`tap` / `more_tap` 里放什么、回调怎么落地）都在 main.lua；
  * refresh() 原地重建内容并**保持滚动位置**（图片下载完成后逐张回填用）。

data 结构（main.lua 组装，见 _renderParaReviewView）：
  comments = {
    {
      head  = "1. 名字",                       -- 头行（加粗；v2.16.11 只留序号+用户名）
      foot  = "赞 3 · 回复 5   ［展开 5 条回复］", -- 统计行（灰字小号，正文下方；含折叠标记）
      text  = "正文……",
      images = { { path = "/…/c_xx_1.webp", w = 240, h = 240,    -- 已下载
                   img_no = 1, tap = { no = 1, img = 1 } },
                 { note = "（图2：正在后台加载…）",               -- 占位（也可点）
                   img_no = 2, tap = { no = 1, img = 2 } },
                 { note = "（HEIC 图片，本设备无法显示）" } },     -- 不可点（无 tap）
      replies = { { head = "↳ 名字 · 赞 1", text = "……", images = {} }, … },
      more_replies = 5,                          -- 还有 N 条回复未加载
      tap      = { no = 1, collapse = false },   -- 点「头行+正文」回传；nil = 不可点
      more_tap = { no = 1, more = true },        -- 点「还有 N 条回复」回传
    }, …
  }
`tap` / `more_tap` / `images[i].tap` 都是**不透明载荷**：本模块原样交给
`on_block_tap(payload)` / `on_image_tap(payload)`，不含任何业务语义
（no / collapse / img 的含义在 main.lua）。回调应把 `payload` 直接转成一次
`showParaReviewReplies` / `showCommentImage`。
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
-- T 必须是 util.template（%1 占位符），见 store.lua 的同名教训。
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

local Screen = Device.screen

local CommentView = InputContainer:extend{
    title = "",
    comments = nil,          -- 数据块数组（见文件头注释）
    buttons_table = nil,     -- 底部按钮行（同 TextViewer 的格式）
    on_close = nil,
    on_block_tap = nil,      -- function(payload)：点「头行+正文」或「还有 N 条回复」
    on_image_tap = nil,      -- function(payload)：点内嵌图片（开全屏预览）
    width = nil,
    height = nil,
    -- 当前**阅读字号**（逻辑值）：本视图三档字号由它折算（见文件里的 font_sizes）。
    -- 传 nil / 越界都回默认基准；main.lua 从 `doc_settings:readSetting("font_size")` 取。
    reader_font_size = nil,

    text_padding = Size.padding.large,
    text_margin = Size.margin.small,
    button_padding = Size.padding.default,
    block_gap = nil,         -- 评论块间距（init 里按屏幕取值）
}

-- 图片内嵌显示的最大宽度比例（相对内容宽）：段评图通常是小图（240px 级），
-- 原尺寸即可；超过内容宽的等比压到内容宽的 70%。
local IMAGE_MAX_WIDTH_RATIO = 0.7

-- 字号（**逻辑值**，不是物理像素）。
-- 🔴 `Font:getFace(name, size)` 内部自己会做一次 `Screen:scaleBySize(size)`，所以这里
--    传进去的必须是**未缩放**的逻辑号：以前写的是 `Screen:scaleBySize(17)`，等于缩放了
--    两次 —— 在高 DPI 设备上字会大出一倍多，表现为「评论区比正文还大、一条短提示就撑出
--    横向滚动条」。这条规则与 ui_style 的 `S.face` 完全一致（那边也是先夹紧再交给 getFace）。
--
-- v2.16.0：三个数**不再写死**，改从一个**基准字号**推出来 —— 用户反馈「评论区字还是
--   太小了」。基准按**当前阅读字号**折算（`font_base_from_reader_size`），由调用方作为
--   `reader_font_size` 传进来（main.lua 从 `doc_settings` 取）；读不到就用默认基准。
--   🔴 基准**永不低于** `FONT_BASE_DEFAULT` —— 阅读字号调小的人不该反而看到更小的评论字
--      （那正是这次用户报的问题本身）。
local FONT_BASE_DEFAULT = 18   -- 正文基准（逻辑字号）
local FONT_BASE_MIN = 13       -- 墨水屏下限：再小就糊成一团
local FONT_BASE_MAX = 30       -- 上限：再大一条短评论就会撑出横向滚动条
-- 评论正文字号 / 阅读字号：比正文小一档（评论区是次要信息），但别小太多。
local FONT_BASE_RATIO = 0.86
-- 阅读字号的合理区间。⚠️ mupdf 的 `font_size` 是 1.0 量级的倍数（KOReader 自己用
-- `<5` / `>5` 区分 mupdf 与 crengine 两种语义），只有落在这个区间的值才认。
local READER_SIZE_MIN = 12
local READER_SIZE_MAX = 64

--- 阅读字号 → 评论区正文基准（逻辑字号）。读不到 / 越界一律回默认基准。
local function font_base_from_reader_size(size)
    size = tonumber(size)
    if not size or size < READER_SIZE_MIN or size > READER_SIZE_MAX then
        return FONT_BASE_DEFAULT
    end
    local base = math.floor(size * FONT_BASE_RATIO + 0.5)
    if base < FONT_BASE_DEFAULT then base = FONT_BASE_DEFAULT end
    return base
end

--- 由基准推出三档字号（都取整）：
---   头行 = 基准 - 1（加粗，视觉上不比正文重）；
---   正文 = 基准；
---   提示行 = 基准 - 4（弱提示，但不低于 `FONT_BASE_MIN`）。
local function font_sizes(reader_size)
    local base = font_base_from_reader_size(reader_size)
    if base < FONT_BASE_MIN then base = FONT_BASE_MIN end
    if base > FONT_BASE_MAX then base = FONT_BASE_MAX end
    return base - 1, base, math.max(FONT_BASE_MIN, base - 4)
end

--- 可点行：把一段内容包起来，tap 时把 `payload` 原样回传 `on_tap(payload)`。
---
--- 为什么这么做（而不是给 TextWidget 加 callback）：KOReader 的 `TextWidget` /
--- `TextBoxWidget` 都**不支持**通用文本 tap（`TextBoxWidget` 只有 `TapImage`），
--- 所以「可点」必须由容器承担 —— 与官方 `HtmlBoxWidget`（`TapText`）同一姿势。
--- 尺寸不自己算：`InputContainer` 继承的 `WidgetContainer:getSize()` 在 `self.dimen`
--- 为空时会回退到 `self[1]:getSize()`，正好是我们要的（子内容尺寸）。
---
--- ⚠️ 两条**不能想当然**的前提（回归里有源码守卫，别删）：
---   1. 事件是**先给子控件**的，而头行/正文/提示行都是 `TextBoxWidget`（它无条件注册了
---      `ges_events.TapImage`）。它只在「点到内嵌图」时 `return true`，
---      **纯文字 tap 返回 nil ⇒ 穿透到本行**；否则症状是「点了没反应」。
---   2. `TextWidget` **不是** InputContainer ⇒ 不吃手势。所以内容区里的文字**一律**用
---      `TextBoxWidget`（既吃手势语义一致，又能靠 `width` 折行 —— 见下面 `_append_block`
---      里关于横向滚动的注释），本文件已经不再引用 `TextWidget`。
local TapRow = InputContainer:extend{
    content = nil,   -- 要包起来的 widget（放成 self[1]）
    payload = nil,   -- 点击时原样回传（不透明，语义在外层）
    on_tap = nil,    -- function(payload)
}

function TapRow:init()
    if self.content then self[1] = self.content end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapRow = {
                GestureRange:new{
                    ges = "tap",
                    -- ⚠️ dimen 要等 paintTo 才有 ⇒ 必须用 range **函数**，
                    --    在 match() 时才求值（官方支持，见 ui/gesturerange.lua:32）。
                    range = function() return self.dimen end,
                },
            },
        }
    end
end

function TapRow:onTapRow()
    if self.payload ~= nil and self.on_tap then
        self.on_tap(self.payload)
    end
    return true
end

--- 需要时把内容包成可点行：`payload` 与 `callback` 都在才算（否则原样返回）。
--- 头行+正文、图片、「还有 N 条回复」三处共用同一姿势。
function CommentView:_wrap_tappable(content, payload, callback)
    if payload == nil or callback == nil then return content end
    return TapRow:new{ content = content, payload = payload, on_tap = callback }
end

--- 本实例的三档字号（头行 / 正文 / 提示）。
--- 做成方法并**缓存**在实例上：`refresh()` 原地换字号时把 `_font_head` 清掉即可重算，
--- 不必重建实例（refresh 只重建内容树，不复用不了构造参数）。
function CommentView:_fonts()
    if not self._font_head then
        self._font_head, self._font_body, self._font_note = font_sizes(self.reader_font_size)
    end
    return self._font_head, self._font_body, self._font_note
end

--- 单块渲染：头行 + 正文 + 图片（回复块的缩进由外层加左垫片）。
--- `block.tap` 存在时，「头行 + 正文」整体包成**可点行**（点一下展开/收起该条回复）；
--- `im.tap` 存在时，**该张图**（或其「正在后台加载…」占位行）单独包成可点行
--- （点一下开全屏预览）。两者互不重叠 —— 图片在 `inner` 里与正文行**平级**，
--- 不在正文行的点击区之内，所以点图不会误触「展开回复」。
function CommentView:_append_block(group, block, content_w, indent)
    if type(block) ~= "table" then return end
    -- 三档字号从实例上取（按阅读字号折算，见文件头 font_sizes）
    local FONT_HEAD, FONT_BODY, FONT_NOTE = self:_fonts()
    local text_w = content_w - (indent and Screen:scaleBySize(18) or 0)

    if indent then
        group[#group + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
    end

    local inner = VerticalGroup:new{ align = "left" }
    -- tap 目标 = 头行 + 正文；不可点时直接写进 inner（少一层容器）
    local body = inner
    if not indent and block.tap ~= nil and self.on_block_tap ~= nil then
        body = VerticalGroup:new{ align = "left" }
    end

    local head = block.head
    if type(head) == "string" and head ~= "" then
        body[#body + 1] = TextBoxWidget:new{
            text = head,
            face = Font:getFace("smallinfofont", FONT_HEAD),
            width = text_w,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_BLACK,
            bold = true,
        }
        body[#body + 1] = VerticalSpan:new{ width = Screen:scaleBySize(2) }
    end
    if type(block.text) == "string" and block.text ~= "" then
        body[#body + 1] = TextBoxWidget:new{
            text = block.text,
            face = Font:getFace("x_smallinfofont", FONT_BODY),
            width = text_w,
            alignment = "left",
            -- 一级评论与回复正文**同色**：以前回复是 DARK_GRAY，用户看着像
            -- "二级评论没显示"（灰字在墨水屏上对比度低、跟"已读/禁用"一个观感）。
            -- 层次交给左缩进 + 小字号 + 头行加粗区分，不靠颜色深浅。
            -- 🔴 **不要写「夜间白字」分支**：KOReader 的夜间模式是整屏 framebuffer
            --    反色（Kobo MTK 直接写 /proc/hwtcon/cmd 的 night_mode），不是换主题色；
            --    这里写黑，夜间会被反成白字；真写成 COLOR_WHITE 反而反成黑字看不见。
            --    TextBoxWidget 自己的默认 fgcolor 也是 COLOR_BLACK（同理）。
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end

    if body ~= inner then
        inner[#inner + 1] = self:_wrap_tappable(body, block.tap, self.on_block_tap)
    end

    -- 内嵌图片 / 加载中占位 / 不可显示提示
    for _k, im in ipairs(block.images or {}) do
        if type(im) == "table" and im.path and im.path ~= "" then
            local w = tonumber(im.w) or 0
            local h = tonumber(im.h) or 0
            local max_w = math.floor(content_w * IMAGE_MAX_WIDTH_RATIO)
            local iw
            if w > 0 and h > 0 then
                -- 等比算出**精确**渲染尺寸，直接传 width/height（不给 scale_factor
                -- ⇒ ImageWidget 拉伸到该尺寸；比例一致 ⇒ 无变形）。
                -- 🔴 不能再给 scale_factor=0 + 大 box：getSize 会**原样返回 box**
                --    （图片在 box 里居中），比例不符就是一整块留白 —— 旧实现
                --    w/h 缺失时 box 是 max_w×max_w 正方形，竖图/横图周围全空白
                --    （用户报的「好多都有留白」）。真实 w/h 由 main.lua 探测
                --    （fanqie/img_size.lua）后放进 im.w/im.h。
                local disp_w = math.min(w, max_w)
                local disp_h = math.floor(h * disp_w / w + 0.5)
                iw = ImageWidget:new{
                    file = im.path,
                    width = disp_w,
                    height = disp_h,
                    file_do_cache = true,
                }
            else
                -- 保底：连服务端字段和文件头都拿不到 → best-fit 正方形 box
                -- （best-fit 保持比例、图片在 box 内居中，无法避免排版留白，
                -- 但探测覆盖绝大多数图，走到这的只有损坏文件）
                iw = ImageWidget:new{
                    file = im.path,
                    width = max_w,
                    height = max_w,
                    scale_factor = 0,
                    file_do_cache = true,
                }
            end
            -- 本视图确实往屏幕上画过图片 ⇒ 关窗时要全刷（理由见 onClose）。
            -- ⚠️ 只认**真的造出 ImageWidget** 的分支：`{ note = "…" }` 那类占位/不可显示
            --    提示只是灰字，不产生图片残影，不该把纯文字页也拖成全刷。
            self._has_images = true
            inner[#inner + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
            inner[#inner + 1] = self:_wrap_tappable(iw, im.tap, self.on_image_tap)
        elseif type(im) == "table" and type(im.note) == "string" and im.note ~= "" then
            -- ⚠️ 必须用 TextBoxWidget（带 width ⇒ **会折行**）而不是 TextWidget：
            --    TextWidget 没有宽度上限，文案一长就把内容撑得比内容区还宽，而
            --    `ScrollableContainer` 是**双向**滚动的 ⇒ 屏幕上冒出一条横向滚动条。
            --    （同理：内容区里**不许**再出现无宽度上限的 TextWidget，回归里守着这条。）
            local note = TextBoxWidget:new{
                text = im.note,
                face = Font:getFace("xx_smallinfofont", FONT_NOTE),
                width = text_w,
                alignment = "left",
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            inner[#inner + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
            -- 「正在后台加载…」也可点（im.tap 只在可显示的图上才有）；
            -- 「本设备无法显示」不带 tap ⇒ 不可点。
            inner[#inner + 1] = self:_wrap_tappable(note, im.tap, self.on_image_tap)
        end
    end

    -- 统计行（v2.16.11）：「赞N · 回复N  时间 ［展开 N 条回复］/［收起］」
    -- 灰字小号，跟在正文/图片之后 —— 用户报头行太挤（日期/赞/回复数全塞第一行）；
    -- 折叠标记也在这行尾（v2.16.8 删过头行标记后可发现性归零）。
    -- 与「头行+正文」同一个 tap 载荷：点整行（含标记）就能展开/收起。
    if type(block.foot) == "string" and block.foot ~= "" then
        local foot = TextBoxWidget:new{
            text = block.foot,
            face = Font:getFace("xx_smallinfofont", FONT_NOTE),
            width = text_w,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        inner[#inner + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
        if block.tap ~= nil and self.on_block_tap ~= nil then
            inner[#inner + 1] = self:_wrap_tappable(foot, block.tap, self.on_block_tap)
        else
            inner[#inner + 1] = foot
        end
    end

    if indent then
        -- 回复块整体左缩进（左垫片 + 内容）
        -- 🔴 align 必须是 "top"：HorizontalGroup 只认 center/top/bottom
        --    （见 koreader frontend/ui/widget/horizontalgroup.lua:paintTo ——
        --    "left"/"right" 落进 else 分支，**只写一行 stderr 什么都不画**，
        --    而 getSize 不看 align ⇒ 块照常占高度却永远不渲染）。
        --    v2.16.0~v2.16.11 写成 "left"（VerticalGroup 的词汇），正是用户报的
        --    「评论能出来、回复只有一大块空白」的全部根因 —— 回复块占了位、
        --    一个像素都没画。stderr 警告只进 KOReader 自身日志，fanqie.log 看不到，
        --    设备侧零报错（回归桩当时照画不误 ⇒ 假绿了一路）。
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        group[#group + 1] = HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = Screen:scaleBySize(18) },
            inner,
        }
    else
        group[#group + 1] = inner
    end
end

--- 全量内容：评论块序列 + 块间分隔线。
function CommentView:_build_content(content_w)
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local FONT_BODY, FONT_NOTE = select(2, self:_fonts())
    local group = VerticalGroup:new{ align = "left" }
    local first = true
    -- 每次重建都从头统计（`_append_block` 里置 true）——它决定**关窗时是否全刷**，
    -- 见 onClose 的长注释。refresh() 会重跑本函数，所以统计天然跟着最新内容走。
    self._has_images = false
    for _i, c in ipairs(self.comments or {}) do
        if not first then
            group[#group + 1] = VerticalSpan:new{ width = self.block_gap }
            group[#group + 1] = LineWidget:new{
                background = Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{ w = content_w, h = Size.line.thin },
            }
            group[#group + 1] = VerticalSpan:new{ width = self.block_gap }
        end
        first = false
        self:_append_block(group, c, content_w, false)
        for _j, r in ipairs(c.replies or {}) do
            self:_append_block(group, r, content_w, true)
        end
        if tonumber(c.more_replies) and tonumber(c.more_replies) > 0 then
            group[#group + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
            local note = TextBoxWidget:new{
                text = T(_("… 还有 %1 条回复（点这行继续加载）"), tostring(c.more_replies)),
                face = Font:getFace("xx_smallinfofont", FONT_NOTE),
                width = content_w,
                alignment = "left",
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            }
            -- 这一行**单独可点**（与「头行+正文」的开关分开：展开 ≠ 加载更多）
            group[#group + 1] = self:_wrap_tappable(note, c.more_tap, self.on_block_tap)
        end
    end
    if first then
        group[#group + 1] = TextBoxWidget:new{
            text = _("（没有内容）"),
            face = Font:getFace("x_smallinfofont", FONT_BODY),
            width = content_w,
            alignment = "left",
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    end
    return group
end

function CommentView:init(reinit)
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    self.align = "center"
    self.region = Geom:new{ w = screen_w, h = screen_h }
    self.width = self.width or screen_w - Screen:scaleBySize(30)
    self.height = self.height or screen_h - Screen:scaleBySize(30)
    self.block_gap = self.block_gap or Screen:scaleBySize(8)

    if not reinit then
        if Device:hasKeys() then
            self.key_events.Close = { { Device.input.group.Back } }
        end
        if Device:isTouchDevice() then
            self.ges_events.TapClose = {
                GestureRange:new{ ges = "tap", range = self.region },
            }
        end
    end

    self.titlebar = TitleBar:new{
        title = self.title,
        fullscreen = false,
        show_parent = self,
        close_callback = function() self:onClose() end,
    }

    self.button_table = ButtonTable:new{
        width = self.width - 2 * self.button_padding,
        buttons = self.buttons_table or {},
        zero_sep = true,
        show_parent = self,
    }

    -- 🔴 内容宽必须先扣掉**竖滚动条**要占的横向槽位。
    --
    -- `ScrollableContainer:initState()`：
    --     _max_scroll_offset_x = max(0, content.w − (dimen.w − 3×scroll_bar_width))
    -- 只要内容高于一屏（本视图必然如此），它就把 3×scroll_bar_width（scaleBySize(18)）
    -- 当成「被滚动条吃掉」的宽度重算一次横向可滚范围。而我们的内容宽是**已经排好版的
    -- 固定值**，容器不会重排它 ⇒ 如果 `dimen.w − content.w` 小于那 18px，
    -- 屏幕上就必然多出一条**横向滚动条**，并且真的能用手指左右拖动。
    --
    -- 旧值只多给 `2×text_margin` = scaleBySize(4) < scaleBySize(18) ⇒ **每台设备都会滚**。
    -- 正确姿势（官方同款，见 ui/widget/scrolltextwidget.lua：`TextBoxWidget` 的 width 要减
    -- `scroll_bar_width + text_scroll_span`）：槽位从内容宽里扣掉、再加回容器宽。
    -- 这样 FrameContainer 的宽度仍然**恰好**是 self.width（不多不少）。
    local scrollbar_gutter = ScrollableContainer:getScrollbarWidth()
    local content_w = self.width - 2 * self.text_padding - 2 * self.text_margin - scrollbar_gutter
    local content_h = self.height - self.titlebar:getHeight() - self.button_table:getSize().h
        - 2 * self.text_padding - 2 * self.text_margin
    if content_h < Screen:scaleBySize(60) then
        content_h = Screen:scaleBySize(60)
    end

    -- 🔴 ScrollableContainer 必须以 cropping_widget 之名挂在 self 上：
    --    UIManager 依赖这个名字把内层 widget 的重绘请求裁剪到滚动区里。
    -- dimen.w = content_w + 竖滚动条槽位（理由见上面 content_w 的注释）：
    --    这样 `initState()` 算出的 `_max_scroll_offset_x` 恒为 0 ⇒ 不可能出横向滚动条，
    --    同时滚动条自己画在 `dimen.w − 2×scroll_bar_width` 处，正好落在这条槽位里。
    self.cropping_widget = ScrollableContainer:new{
        dimen = Geom:new{ w = content_w + scrollbar_gutter, h = content_h },
        show_parent = self,
        self:_build_content(content_w),
    }
    local textw = FrameContainer:new{
        padding = self.text_padding,
        margin = self.text_margin,
        bordersize = 0,
        self.cropping_widget,
    }

    self.frame = FrameContainer:new{
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.titlebar,
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = textw:getSize().h },
                textw,
            },
            CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = self.button_table:getSize().h },
                self.button_table,
            },
        },
    }
    self.movable = MovableContainer:new{
        ignore_events = { "swipe", "hold", "hold_release", "hold_pan", "touch", "pan", "pan_release" },
        self.frame,
    }
    self[1] = WidgetContainer:new{
        align = self.align,
        dimen = self.region,
        self.movable,
    }
end

--- 释放「自己造了 blitbuffer 却没有 free()」的控件所占的显存。
---
--- 🔴 为什么必须手工做（「打开几次评论区后闪退」的根因）：
---    KOReader 里 `WidgetContainer:free()` 是这样写的 ——
---        for _, widget in ipairs(self) do
---            if widget.free then widget:free() end
---        end
---    也就是说**没有 free 方法的控件会被整条跳过**。而 `TextBoxWidget`（本视图里数量最多
---    的控件：头行 / 正文 / 提示行全是它）恰恰就是「自造 `self._bb` 且没有 free」的那种：
---    它的 bb 只能等 Lua GC 去跑 cdata 的 finalizer。可是 bb 是 **FFI 分配**，Lua 侧看不见
---    它占了多少内存，GC 就不会因为「外部内存压力」而提前跑 ⇒ 反复开关评论区时，
---    每一轮都留下整棵内容树的 bb（一页评论几十个 TextBoxWidget，单个可上百 KB），
---    累积到设备内存上限就是**闪退**。
---    （官方 `ImageWidget:free` 是同一思路：只 free 自己造的那份 bb。）
---
--- ⚠️ 只处理**没有 free 方法**的控件：有 free 的（ImageWidget / TextWidget）交给它们自己 ——
---    ImageWidget 的 `_bb` 可能来自全局 `ImageCache`（多视图共享！），它有 `_bb_disposable`
---    记住「这份 bb 是不是我造的」，替它 free 会把别的视图正在用的 bb 一起打坏。
---    `pcall` 兜底：bb 可能已经被别的路径释放过，重复释放绝不该把界面带崩。
local function release_orphan_blitbuffers(w)
    if type(w) ~= "table" then return end
    if type(w.free) ~= "function" then
        local bb = w._bb
        if bb ~= nil and type(bb) ~= "string" then
            pcall(function() bb:free() end)
            w._bb = nil
        end
    end
    for i = 1, #w do
        release_orphan_blitbuffers(w[i])
    end
end

--- 原地重建（数据/按钮变了之后调）：保持滚动位置，图片回填时页面不跳。
---
--- ⚠️ 保存/恢复位置**必须**用 ScrollableContainer 自己的 API
---    （`getScrolledOffset` / `setScrolledOffset` + `initState`）。
---    别照抄 TextViewer 的 `scroll_widget:getCurrentRatio()` —— 那是 **ScrollHtmlWidget**
---    的方法，ScrollableContainer 上根本没有它（`pcall` 一把就静默跳过 ⇒ 「保持位置」永远没生效，
---    每下完一张图页面就跳回顶部）。这是 v2.8.0 自查出来的实效 bug。
function CommentView:refresh()
    local offset
    local old = self.cropping_widget
    if old and old.getScrolledOffset then
        local ok, o = pcall(old.getScrolledOffset, old)
        if ok and type(o) == "table" and type(o.y) == "number" then offset = o end
    end

    -- 🔴 旧框占的屏幕区域，**必须在重建前**取（重建后 `self.frame` 就指向新树了）：
    --    图片插进来会让框变高，而框是**居中**摆的 ⇒ 旧框的上下边缘不在新框里，
    --    只刷新框会在屏幕上留一圈旧框的残影。取副本，别存引用（新树 paintTo 时会
    --    原地改写自己那份 dimen，虽不是同一个表，但存副本零风险）。
    local old_frame_dimen = self.frame and self.frame.dimen
        and self.frame.dimen.copy and self.frame.dimen:copy() or nil

    -- 旧树立刻回收显存（理由见 release_orphan_blitbuffers 的注释）：
    -- 「图片逐张回填」会让本函数被调用很多次，不主动回收就会攒出一堆等 GC 的大 bb。
    -- 🔴 旧 ScrollableContainer 的**整屏画布 `_bb`** 也要先走官方 `reset()` 释放：
    --    它有 free 方法（容器语义）⇒ `self:free()` 只会递归释放它的**子件**，
    --    而画布只在它自己的 onCloseWidget 里释放 —— refresh 丢弃旧树时不发事件，
    --    不 reset 的话每次回填就漏一张 600×800 的画布（真机反复回图＝稳步涨内存）。
    release_orphan_blitbuffers(self[1])
    if old and type(old.reset) == "function" then
        pcall(old.reset, old)
    end
    self:free()
    self:init(true)

    local cw = self.cropping_widget
    if offset and cw and cw.setScrolledOffset then
        -- 内容会长高（图片插进来），先算一次内容尺寸拿到新的最大偏移，再夹紧 —— 否则可能
        -- 滚到超过内容的空白区。bookmapwidget 也是这个姿势（先 initState 再滚动）。
        if cw.initState then pcall(cw.initState, cw) end
        local maxy = tonumber(cw._max_scroll_offset_y) or offset.y
        local y = math.max(0, math.min(offset.y, maxy))
        pcall(cw.setScrolledOffset, cw, { x = offset.x or 0, y = y })
    end

    -- ⚠️ 只把**本视图**标脏，不要用 `setDirty("all", ...)`：
    --    "all" 会把 window_stack 上所有顶层 widget 全标脏 ⇒ 整屏重绘。
    --    图片是**逐张回填**的，每回填一张就整屏刷一次＝屏幕上不停闪。
    --    （官方惯例也是 `UIManager:setDirty(self, "partial", self.dimen)`。）
    --
    -- 🔴 region 必须**等这一帧画完再取**，所以传 lambda 而不是直接传 `self.frame.dimen`：
    --    新树的 frame 是刚 `FrameContainer:new` 出来的，而 `dimen` **只在 `paintTo()` 里写**
    --    （`frontend/ui/widget/container/framecontainer.lua:104-114`）⇒ 此处直接取恒为 **nil**；
    --    而 `UIManager:_refresh` 见到「partial 且无 region」会把 region 补成**整屏**
    --    （`frontend/ui/uimanager.lua:1175`：`region = region or Geom:new{...屏宽, 屏高}`）
    --    ⇒ 实际效果仍是「每回填一张图整屏刷一次」，就是用户看到的**「图片一加载就闪一下」**。
    --    pass 回调的写法正是官方对同一问题的答案（`UIManager:setDirty` 的 doc：
    --    "callback, will be issued after painting"）；本文件的 `onShow` / `onCloseWidget`
    --    也都是 lambda 形态 —— 只有这里漏了。
    UIManager:setDirty(self, function()
        local r = self.frame and self.frame.dimen
        if r and old_frame_dimen then
            -- 新旧框并集（见函数开头：框居中、高度随内容变 ⇒ 只刷一个会留残影）
            return "partial", r:combine(old_frame_dimen)
        end
        -- 兜底：新框还没被画过（理论上不会走到 —— 本回调就是在绘制后消费的）
        return "partial", r or old_frame_dimen
    end)
end

function CommentView:getContentSize()
    return self.movable.dimen
end

function CommentView:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.frame.dimen
    end)
    return true
end

function CommentView:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "partial", self.frame.dimen
    end)
    -- 🔴 关窗时显式回收显存：老版本 KOReader 的 `TextBoxWidget` 自造 `_bb` 且**没有**
    --    `free`/`onCloseWidget`，事件传播到它头上时什么都不释放 ⇒「反复开关评论区闪退」。
    --    （新版本已有 `TextBoxWidget:free(full)`，这个函数逐个检查 `free` 的存在性，
    --    对新版是无操作 —— 两种内核都安全。）
    release_orphan_blitbuffers(self[1])
    -- ⚠️ 这里**不要**再调 `self:free()`（v2.16.0 曾加过，已撤）：
    --    `UIManager:close` 发的 CloseWidget 事件会**先**传播给整棵子树
    --    （`WidgetContainer:propagateEvent` → 各自的 onCloseWidget：TextBoxWidget 释放
    --    `_bb`+`_xtext`、ScrollableContainer 释放整屏画布、ImageWidget/TextWidget 同理），
    --    等轮到本方法时子树已经释放过了；再 `self:free()` 是对整棵树的**第二遍** free
    --    —— 这正是「点下一页（按钮回调里关窗）秒闪退」的最高嫌疑。官方 TextViewer 的
    --    onCloseWidget 也只做 setDirty，不 free 自己。
end

function CommentView:onTapClose(arg, ges_ev)
    if ges_ev.pos and self.frame.dimen and ges_ev.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

function CommentView:onMultiSwipe()
    self:onClose()
    return true
end

--- 用户主动关闭（TitleBar 的 × / 点框外 / 多指下滑 / main.lua 的「关闭」按钮）。
---
--- 🔴 关窗后**要全刷一次**（`UIManager:setDirty(nil, "full")`），否则屏幕上留残影：
---    本节视图里有**内嵌图片**（`ImageWidget`，大面积深色像素），而 `onCloseWidget`
---    只申请了 `partial` + 本框区域 —— 墨水屏的局部刷新擦不干净整块图片，关掉之后
---    还能看见图的鬼影（用户实测：「有图的话会有残影」）。
---    `setDirty(nil, "full")` 的 region 落到全屏，会和 `onCloseWidget` 刚入队的那条
---    regional partial **合并**（`UIManager:_refresh` 的碰撞合并 + `update_mode`，
---    `refresh_modes.full = 9` 最高）⇒ 最终只刷一次，且是全刷。
--- ⚠️ 只在**本视图真画过图**时全刷（纯文字页的局部刷新足够干净，没必要黑闪一下）。
--- ⚠️ 会不会误伤「关旧开新」？不会：换页/展开回复走的 `CommentView:refresh()` 是
---    原地重建（不 close），而 `_renderParaReviewView` 的「关旧开新」分支用的是裸
---    `UIManager:close(viewer)` —— 只有走本函数的才是**用户主动关闭**。
--- ⚠️ `G_reader_settings:isTrue("avoid_flashing_ui")` 挡不住这一条（它只降级
---    flashui/flashpartial/带 region 的 partial）—— 这里要的正是「清残影」，全刷是目的不是副作用。
function CommentView:onClose()
    local needs_full = self._has_images == true
    UIManager:close(self)
    if needs_full then
        UIManager:setDirty(nil, "full")
    end
    if self.on_close then
        local cb = self.on_close
        self.on_close = nil
        pcall(cb)
    end
    return true
end

return CommentView
