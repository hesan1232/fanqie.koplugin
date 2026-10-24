--[[--
UI 设计令牌：尺寸 / 字号 / 配色 / 圆角 / 进度条 / 徽章。

为什么单独一个模块：书架（`shelf_view.lua`）与书城（`store_view.lua`）此前各写
一套 FrameContainer 参数与颜色字面量，改一处忘一处就会「书架行距和书城不一样」。
现在两边都只从这里取值（参考 book.koplugin 的 `ui.components.bookui` +
`ui.components.surface` 的分工：页面负责布局，视觉属性集中在这）。

墨水屏原则（与 README「适配墨水屏显示，纯黑白配色，无毛玻璃无平滑动画」一致）：
  * 只用纯黑、纯白与四档灰：0x33 辅助文字 / 0x77 更弱提示 / 0xBB 描边 /
    0xDD 发丝线 / 0xEE 浅底。**不做 alpha 混合**（e-ink 上灰色会变成抖动噪点）；
  * 圆角靠「先画子件，再用背景色抹掉弧外像素」实现（见 `S.clip`），
    因为 `ImageWidget` 画的是方角矩形，光给容器设 radius 盖不住封面四角；
  * 所有尺寸一律过 `Screen:scaleBySize`，禁止写死像素（不同 DPI 设备差 2 倍以上）。

尺寸口径：`S.sz(n)` 与 `S.face(name, n)` 的 n 是**同一层**的逻辑值
（`Font:getFace` 内部自己会 `Screen:scaleBySize`），所以给字号用 `S.face` 即可，
绝不能再套一层 `S.sz`，否则字会比图标大一圈。

@module fanqie.ui_style
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Screen = Device.screen

local S = {}

-- ------------------------------------------------------------------ 尺寸

--- 逻辑像素 → 物理像素（含设备 DPI 缩放）。
function S.sz(n)
    return math.max(1, math.floor(Screen:scaleBySize(tonumber(n) or 0) + 0.5))
end

--- 字号下限：小于 10 在墨水屏上基本糊成一团。
function S.fontSize(n)
    return math.max(10, math.floor(tonumber(n) or 16))
end

--- `Font:getFace` 的统一入口（字号先过 fontSize 夹紧）。
function S.face(name, size)
    return Font:getFace(name or "smallinfofont", S.fontSize(size))
end

-- ------------------------------------------------------------------ 配色
--
-- ⚠️ 这些常量名不是随便写的：KOReader 的 blitbuffer 只提供 0x3/0x4/0x5/0x6/0x7/
--    0x9/0xB/0xD/0xE 这几档具名灰（对照 koreader-master 全量引用实测），
--    **没有 COLOR_GRAY_F**。写错的名字不会报错，只会静默拿到 nil ⇒ 文字变默认色。

S.ink     = Blitbuffer.COLOR_BLACK     -- 正文 / 书名
S.muted   = Blitbuffer.COLOR_GRAY_3    -- 0x33 辅助文字（作者、元信息），近黑但弱一档
S.hint    = Blitbuffer.COLOR_GRAY_7    -- 0x77 更弱的提示（页码、空态）
S.border  = Blitbuffer.COLOR_GRAY_B    -- 0xBB 封面描边
S.rule    = Blitbuffer.COLOR_GRAY_D    -- 0xDD 发丝分割线
S.track   = Blitbuffer.COLOR_GRAY_D    -- 0xDD 进度条空轨
S.surface = Blitbuffer.COLOR_GRAY_E    -- 0xEE 浅底（选中态 / 卡片）
S.paper   = Blitbuffer.COLOR_WHITE     -- 页面底色

-- ------------------------------------------------------------------ 圆角

--- 卡片 / 封面圆角半径。
function S.radius()
    return S.sz(6)
end

--- 胶囊圆角：按实际高度取半高，两端才是完整半圆。
function S.pillRadius(height)
    return math.max(1, math.floor((tonumber(height) or 1) / 2))
end

-- 圆角裁切容器：先画子件，再把四角弧外的像素涂成背景色。
-- 半径会夹到短边一半；无背景色或半径为 0 时退化成直接绘制（不裁）。
local RoundedClip = WidgetContainer:extend{
    radius = 0,
    background = nil,
}

--- 尺寸由构造时传入的 dimen 决定，不随子件变化。
function RoundedClip:getSize()
    return self.dimen
end

function RoundedClip:paintTo(bb, x, y)
    if self[1] == nil then return end
    self[1]:paintTo(bb, x, y)
    local w, h, r = self.dimen.w, self.dimen.h, self.radius
    local color = self.background
    if not color or not r or r <= 0 then return end
    r = math.min(r, math.floor(math.min(w, h) / 2))
    local rr = (r - 0.5) * (r - 0.5)
    for dy = 0, r - 1 do
        for dx = 0, r - 1 do
            if (dx + 0.5 - r + 0.5) ^ 2 + (dy + 0.5 - r + 0.5) ^ 2 > rr then
                bb:setPixel(x + dx, y + dy, color)
                bb:setPixel(x + w - 1 - dx, y + dy, color)
                bb:setPixel(x + dx, y + h - 1 - dy, color)
                bb:setPixel(x + w - 1 - dx, y + h - 1 - dy, color)
            end
        end
    end
end

--- 把子件按给定半径裁成圆角（用 background 抹角）。
--- ⚠️ 必须放在 FrameContainer **外层**：FrameContainer 的 radius 只作用于它自己画的
---    背景与描边，子件（封面图）仍是方角，会在四角戳出来。
function S.clip(child, radius, background)
    if not child then return nil end
    local size = child:getSize()
    return RoundedClip:new{
        dimen = Geom:new{ w = size.w, h = size.h },
        radius = radius or S.radius(),
        background = background or S.paper,
        child,
    }
end

-- ------------------------------------------------------------------ 组件

--- 圆角进度条（0–100），返回的对象带 `:setPercent(v)` 可就地更新。
--- 轨道 0xDD、填充纯黑；高度默认 sz(4)，在墨水屏上细而清晰。
function S.progressBar(width, height, percent)
    width = math.max(1, math.floor(tonumber(width) or 1))
    height = math.max(1, math.floor(tonumber(height) or S.sz(4)))
    local radius = S.pillRadius(height)

    --- 造一段定高的圆角色块（轨道或填充）。
    local function bar(w, color)
        w = math.max(1, math.floor(w))
        return FrameContainer:new{
            bordersize = 0,
            padding = 0,
            margin = 0,
            radius = radius,
            background = color,
            width = w,
            height = height,
            dimen = Geom:new{ w = w, h = height },
            -- FrameContainer 画圆角背景；空 Widget 只提供尺寸，避免矩形子项盖平圆角。
            Widget:new{ dimen = Geom:new{ w = w, h = height } },
        }
    end

    local progress = OverlapGroup:new{
        dimen = Geom:new{ w = width, h = height },
        bar(width, S.track),
    }
    --- 就地更新进度百分比（0–100，自动夹紧）。调用方仍需自行触发重绘。
    function progress:setPercent(value)
        value = tonumber(value) or 0
        if value < 0 then value = 0 end
        if value > 100 then value = 100 end
        local w = math.floor(width * value / 100 + 0.5)
        self[2] = w > 0 and bar(w, S.ink) or nil
        self._size = nil
        self:getSize()
    end
    progress:setPercent(percent)
    return progress
end

--- 圆角封面（列表行与网格格共用）。
--- 外框尺寸 w×h **含** 1px 细描边；内部图片等比缩放到恰好放进框内。
--- 返回 clipped（可直接摆进布局）、frame（改 `frame.color` 做选中态）、inner（图片控件）。
--- ⚠️ `require("ui/widget/imagewidget")` 写成**函数内**惰性加载：imagewidget 会连带拉起
---    renderglyph/renderimage 一长串依赖，放在模块顶层会把两个视图的加载成本抬高，
---    而封面只有在真的进入列表/网格时才需要。
function S.cover(path, w, h)
    local border = S.sz(1)
    local iw = math.max(1, math.floor(tonumber(w) or 1) - border * 2)
    local ih = math.max(1, math.floor(tonumber(h) or 1) - border * 2)
    local inner
    if type(path) == "string" and path ~= "" then
        local ImageWidget = require("ui/widget/imagewidget")
        inner = ImageWidget:new{
            file = path,
            width = iw,
            height = ih,
            -- scale_factor == 0：等比缩放到恰好放进 w×h（见 imagewidget 顶部注释）
            scale_factor = 0,
            file_do_cache = true,
        }
    else
        -- 封面还没下载好：画一个空框占位，格子尺寸保持稳定（否则整页会跳）
        local CenterContainer = require("ui/widget/container/centercontainer")
        local TextWidget = require("ui/widget/textwidget")
        inner = CenterContainer:new{
            dimen = Geom:new{ w = iw, h = ih },
            TextWidget:new{ text = "", face = S.face("smallinfofont", 12) },
        }
    end
    local frame = FrameContainer:new{
        bordersize = border,
        color = S.border,
        radius = S.radius(),
        padding = 0,
        margin = 0,
        background = S.paper,
        inner,
    }
    return S.clip(frame, S.radius(), S.paper), frame, inner
end

--- 小徽章（连载中 / 已完结 / 已断更 / 已读完…）：描边圆角小标签。
--- 纯描边不上底色 —— 墨水屏下填充块会把这一行压得很重。
--- ⚠️ 不要在 `S.face` 之外再套 `S.sz`：`Font:getFace` 内部已经 scaleBySize 过一次。
function S.badge(text, font_size)
    local TextWidget = require("ui/widget/textwidget")
    local label = TextWidget:new{
        text = tostring(text or ""),
        face = S.face("xx_smallinfofont", font_size or 12),
        fgcolor = S.ink,
        padding = 0,
    }
    -- FrameContainer:getSize() 只看**子件 + padding + border**，不看 width/height，
    -- 所以高度必须由 padding 撑出来，别指望 height。
    local h = label:getSize().h
    return FrameContainer:new{
        bordersize = S.sz(1),
        color = S.border,
        radius = S.pillRadius(h + S.sz(4)),
        background = S.paper,
        padding = 0,
        padding_left = S.sz(6),
        padding_right = S.sz(6),
        padding_top = S.sz(2),
        padding_bottom = S.sz(2),
        margin = 0,
        label,
    }
end

--- 反色小徽章（v2.16.29，榜单前三名次）：黑底白字。
--- 只用在「需要从一排描边徽章里跳出来」的极小元素上 —— 大面积填充在墨水屏上
--- 会显得很重，这个口径与 `S.badge` 是一对（普通/强调）。
function S.badge_ink(text, font_size)
    local TextWidget = require("ui/widget/textwidget")
    local label = TextWidget:new{
        text = tostring(text or ""),
        face = S.face("xx_smallinfofont", font_size or 12),
        fgcolor = S.paper,
        padding = 0,
    }
    local h = label:getSize().h
    return FrameContainer:new{
        bordersize = 0,
        radius = S.pillRadius(h + S.sz(4)),
        background = S.ink,
        padding = 0,
        padding_left = S.sz(6),
        padding_right = S.sz(6),
        padding_top = S.sz(2),
        padding_bottom = S.sz(2),
        margin = 0,
        label,
    }
end

return S
