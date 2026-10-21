--[[--
封面网格：布局度量（`metrics`）+ 单格单元（`CoverCellWidget`）+ 「显示方式」对话框。

布局（一格）：
    ┌──────────────┐
    │ ╭─────────[更新]╮ │  ← 圆角封面 + 1px 细描边（在列槽内**居中**）；
    │ │   封面    │ │     状态徽章**叠在封面右上角**（不吃纵向空间）
    │ ╰──────────╯ │
    │    书名…      │  ← 单行，超宽省略号
    │  122/256章    │  ← 可选：信息短行（书架=章节进度；书城=字数·在读）
    │  ▓▓▓▓░░░░░   │  ← 可选：细进度条（书架）
    └──────────────┘

## 为什么行数是**显式**的（v2.15.0 改）

v2.13 那版让行数由「列宽 → 封面高 → 格高」反推：好处是任何屏都放得下，坏处是
**行数不可预期、也不可调**（同一台机器上换个字号，页数就变了），而且反推出来的
格高往往把封面顶到满屏 ⇒ 看上去「铺得太满、没有留白」。现在改成：

  * 显示方式直接给「列×行」档位（3×3 / 3×4 / 4×3 / 4×4）+ **自定义**（用户填「列×行」）；
  * 行高 = 可用高度按行数均分；封面按 2:3 算出来后**在列槽里居中** ⇒ 左右自然留白；
  * 每行左右各垫一个 `sidePad()` 宽的 HorizontalSpan ⇒ 屏幕两侧留白对称
    （`Menu.item_group` 是 `VerticalGroup{align="left"}`，不垫的话整排会贴死左边）；
  * `rows == 0`（AUTO_ROWS）保留旧的反推行为，供没有设置过行数的老配置兜底。

@module fanqie.cover_cell
--]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local S = require("fanqie.ui_style")

-- 🔴 `_`（gettext）与 `T`（`ffi/util.template`，`%1` 占位符）**是两回事**，
--    混用会导致「文案里的 %1 原样漏出」或「invalid option '%1'」。
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local T = ok_ffiutil and ffiutil.template or function(fmt, ...) return fmt end

local UIManager = require("ui/uimanager")

-- helper 只为 `close_widget`（只在「显示方式」对话框里用），拿不到就退化成不关旧的
-- —— 不因为一个工具函数把整个网格拖下水。
local ok_H, H = pcall(require, "fanqie.helper")
if not ok_H then H = nil end

-- 日志（拿不到就静默 —— 网格不能因为日志组件挂掉）
local ok_Log, Log = pcall(require, "fanqie.logger")
if not ok_Log or not Log then Log = nil end

local CoverCell = {}

-- 🔴 构建标记：随每次改动本文件手动更新。「关于」里会显示它 —— 用户报告
-- 「改了没生效」时，先看这个标记对不对：标记是旧的 ⇒ 设备上这份文件**没换上**，
-- 是解压/覆盖环节的问题，别去改代码。
CoverCell.BUILD = "20261021a"

-- 封面宽高比 2:3（与番茄封面一致，也与 book.koplugin 的 `cw * 3 / 2` 同口径）
local COVER_RATIO = 1.5

-- 列/行的合法范围。列下限 2（1 列不如直接用列表），行下限 1、上限 8。
CoverCell.GRID_COLS_MIN, CoverCell.GRID_COLS_MAX = 2, 8
CoverCell.GRID_ROWS_MIN, CoverCell.GRID_ROWS_MAX = 1, 8
--- `rows == AUTO_ROWS` ⇒ 行数按屏高自动反推（老配置兜底，新档位不用它）。
CoverCell.AUTO_ROWS = 0

--- 「显示方式」里的预设档位（列, 行）。
CoverCell.GRID_PRESETS = { { 3, 3 }, { 3, 4 }, { 4, 3 }, { 4, 4 } }
CoverCell.DEFAULT_COLS, CoverCell.DEFAULT_ROWS = 3, 4

-- ------------------------------------------------------------------ 留白令牌
-- 三个值都由这里出，书架与书城共用 ⇒ 两边的网格留白天然一致。
--- 网格左右页边距（每行两端各垫这么宽）。
function CoverCell.sidePad() return S.sz(14) end
--- 列间距。
function CoverCell.gap() return S.sz(14) end
--- 行间距。
function CoverCell.rowGap() return S.sz(20) end

-- ------------------------------------------------------------------ 布局解析

local function clamp_int(v, lo, hi)
    v = math.floor(tonumber(v) or 0)
    if v < lo then v = lo end
    if v > hi then v = hi end
    return v
end

--- 夹紧一组 (cols, rows)。
--- ⚠️ 三档语义必须分清，混了就出「莫名空页」：
---   * `rows == nil` / 认不出来的值 → **默认档 4**（跟 settings 的默认值同口径）；
---   * `rows <= 0`（含显式的 0）→ `AUTO_ROWS`，交给 `metrics` 按屏高反推（老配置兜底）；
---   * 其余 → 夹到 `[GRID_ROWS_MIN, GRID_ROWS_MAX]`。
--- 「缺省」与「显式要自动」是两件事：混成同一个的话，`resolve_view({})`（没有 settings）
--- 会拿到「自动」，而用户在设置里看到的默认又是 4 行 —— 两边对不上。
---@return number cols
---@return number rows 0 = 自动
function CoverCell.normalize_layout(cols, rows)
    cols = clamp_int(cols ~= nil and cols or CoverCell.DEFAULT_COLS,
        CoverCell.GRID_COLS_MIN, CoverCell.GRID_COLS_MAX)
    if rows == nil then
        rows = CoverCell.DEFAULT_ROWS
    else
        rows = math.floor(tonumber(rows) or CoverCell.DEFAULT_ROWS)
        if rows <= 0 then
            rows = CoverCell.AUTO_ROWS
        else
            rows = clamp_int(rows, CoverCell.GRID_ROWS_MIN, CoverCell.GRID_ROWS_MAX)
        end
    end
    return cols, rows
end

-- 🔴 不能把多字节分隔符（`×` `、` 全角空格）直接写进 Lua 的字符集 `[...]`：
--    Lua 的字符类**按字节**匹配，`[×]` 等于「0xC3 或 0x97 任一字节」——
--    用户输入的**真 `×`（两字节）反而匹配不上**（实测：`4×5` / `4、5` / `4　5` 全部解析失败）。
--    所以先折成 ASCII 再解析。转义一律用十进制字节值，避免源码里夹非 ASCII 字面量。
local LAYOUT_SEP = "[xX%*%,%-/ \t]"
local SEP_FOLD = {
    { "\195\151", "x" },       -- × (U+00D7) 乘号
    { "\227\128\129", "," },   -- 、(U+3001) 顿号
    { "\227\128\128", " " },   -- 　(U+3000) 全角空格
}

--- 把多字节分隔符折成 ASCII（`×`→x、`、`→,、全角空格→半角）。
local function fold_separators(s)
    for _i, pair in ipairs(SEP_FOLD) do
        s = s:gsub(pair[1], pair[2])
    end
    return s
end

--- 解析用户手填的「列×行」。空/非法/越界一律返回 nil（调用方据此提示，不静默取默认值）。
--- 允许只填列数（视为「列 × 自动行数」）。
--- ⚠️ 「只填列数」与「显式写 0 行」**不是一回事**：前者是文档里写明的简写（行数自动），
---    后者是用户打错（提示里写的是「行 1~8」）。所以 `4x0` 一律判非法 ——
---    静默当成「自动」的话，用户明明写错了却看不出来。
---@param text string|nil
---@return number|nil cols
---@return number|nil rows 0 = 自动
function CoverCell.parse_layout(text)
    if type(text) ~= "string" then return nil end
    local s = fold_separators(text):match("^%s*(.-)%s*$") or ""
    if s == "" then return nil end
    local c_str, r_str = s:match("^(%d+)%s*" .. LAYOUT_SEP .. "%s*(%d+)$")
    local cols, rows
    if c_str then
        cols, rows = tonumber(c_str), tonumber(r_str)
        if not cols or not rows then return nil end
        if rows < CoverCell.GRID_ROWS_MIN or rows > CoverCell.GRID_ROWS_MAX then return nil end
    else
        -- 只填了一个数字：按「列数」理解，行数自动
        cols = tonumber(s:match("^(%d+)$"))
        rows = CoverCell.AUTO_ROWS
        if not cols then return nil end
    end
    if cols < CoverCell.GRID_COLS_MIN or cols > CoverCell.GRID_COLS_MAX then return nil end
    return math.floor(cols), math.floor(rows)
end

--- 档位文案：「3×4」/「3 列 · 行数自动」。
--- ⚠️ T 必须是 `ffi/util.template` 的 `%1` 口径（不是 string.format）。
function CoverCell.layout_label(cols, rows)
    cols = math.floor(tonumber(cols) or CoverCell.DEFAULT_COLS)
    rows = math.floor(tonumber(rows) or 0)
    if rows <= 0 then
        return T(_("%1 列 · 行数自动"), tostring(cols))
    end
    return T(_("%1×%2"), tostring(cols), tostring(rows))
end

--- 「显示方式」对话框的全部可选项（不含「取消」）。
--- 每项：{ label, current, mode, cols, rows, custom? }。
--- 非网格项也带上当前 cols/rows —— 切到列表再切回来时布局不会被重置。
function CoverCell.layout_options(mode, cols, rows)
    cols, rows = CoverCell.normalize_layout(cols, rows)
    local opts = {}
    opts[#opts + 1] = {
        label = _("列表"),
        current = mode ~= "grid",
        mode = "list", cols = cols, rows = rows,
    }
    for _i, preset in ipairs(CoverCell.GRID_PRESETS) do
        local pc, pr = preset[1], preset[2]
        opts[#opts + 1] = {
            label = T(_("封面网格 %1"), CoverCell.layout_label(pc, pr)),
            current = mode == "grid" and cols == pc and rows == pr,
            mode = "grid", cols = pc, rows = pr,
        }
    end
    -- 当前档位不在预设里（老配置 / 自定义填过）⇒ 单列一项回显，否则用户看不出自己在哪档
    local in_presets = false
    for _i, preset in ipairs(CoverCell.GRID_PRESETS) do
        if preset[1] == cols and preset[2] == rows then in_presets = true break end
    end
    if mode == "grid" and not in_presets then
        opts[#opts + 1] = {
            label = T(_("封面网格 %1（当前）"), CoverCell.layout_label(cols, rows)),
            current = true,
            mode = "grid", cols = cols, rows = rows,
        }
    end
    opts[#opts + 1] = {
        label = _("自定义列×行…"),
        current = false, custom = true,
        mode = "grid", cols = cols, rows = rows,
    }
    return opts
end

-- ------------------------------------------------------------------ 度量

--- 书名行高度（字号 13 的 xx_smallinfofont 一行）。
function CoverCell.titleLineH()
    return S.sz(16)
end

--- 书名区总高度 = 书名与封面之间的空隙 + 一行书名。
function CoverCell.titleExtra()
    return S.sz(5) + CoverCell.titleLineH()
end

--- 「信息短行」行高度（字号 12 的 xx_smallinfofont 一行）。
--- 书架格画章节进度（`entry.chapters`）、书城格画「字数 · 在读」（`entry.meta`）。
--- 所以它**不算进默认** `titleExtra()` —— 算了的话两边的网格都会白留一条空隙。
--- 调用点自己按需加上：
--- `title_extra = CoverCell.titleExtra() + CoverCell.metaExtra()`。
function CoverCell.metaLineH()
    return S.sz(14)
end

--- 「信息短行」的额外高度 = 与上一行的空隙 + 一行文字。
function CoverCell.metaExtra()
    return S.sz(2) + CoverCell.metaLineH()
end

--- 「细进度条」的额外高度 = 与上一行的空隙 + 条高。
---
--- 🔴 只有书架格画进度条（书城格没有 `entry.progress`），而这一行的高度以前**没人预留**：
--- 书架传 `titleExtra() + metaExtra()`，格子里却还要多画一条 `sz(3) + sz(4)` 的条 ⇒
--- 内容恒比 `cell_h` 高 7px，居中后上下各溢出一截（徽章被压掉半个就是在这里叠加的）。
--- 调用点与 `metaExtra()` 一样按需相加。
function CoverCell.progressExtra()
    return S.sz(3) + S.sz(4)
end

--- 网格度量。
---@param avail_w number 内容区可用宽度（已扣掉左右页边距）
---@param avail_h number 内容区可用高度（已扣掉标题栏与底部分页条）
---@param cols number|nil 期望列数（缺省 3，夹到 [2,8]）
---@param opts table|nil { rows = number（0/缺省 = 按屏高自动反推）,
---                        gap = number, row_gap = number, title_extra = number }
---@return table metrics
function CoverCell.metrics(avail_w, avail_h, cols, opts)
    opts = opts or {}
    cols = clamp_int(cols ~= nil and cols or CoverCell.DEFAULT_COLS,
        CoverCell.GRID_COLS_MIN, CoverCell.GRID_COLS_MAX)
    avail_w = math.max(1, math.floor(tonumber(avail_w) or 1))
    avail_h = math.max(1, math.floor(tonumber(avail_h) or 1))
    local gap = opts.gap or CoverCell.gap()
    local row_gap = opts.row_gap or CoverCell.rowGap()
    local title_extra = opts.title_extra or CoverCell.titleExtra()

    local slot_w = math.max(1, math.floor((avail_w - gap * (cols - 1)) / cols))

    local want_rows = math.floor(tonumber(opts.rows) or 0)
    if want_rows < CoverCell.GRID_ROWS_MIN or want_rows > CoverCell.GRID_ROWS_MAX then
        want_rows = nil
    end

    local cw, ch, cell_h, rows
    if want_rows then
        -- 显式行数：可用高度按行均分 ⇒ 格高；封面按 2:3 算完再夹进列槽 ⇒ 两侧留白
        rows = want_rows
        cell_h = math.max(title_extra + S.sz(24),
            math.floor((avail_h - row_gap * (rows - 1)) / rows))
        ch = math.max(1, cell_h - title_extra)
        cw = math.max(1, math.floor(ch / COVER_RATIO))
        if cw > slot_w then
            cw = slot_w
            ch = math.max(1, math.floor(cw * COVER_RATIO))
        end
    else
        -- 自动反推（老口径，保持原行为）：列宽定封面高，封面高 + 书名区定格高，格高反推行数
        cw = slot_w
        ch = math.floor(cw * COVER_RATIO)
        cell_h = ch + title_extra
        rows = math.max(1, math.floor((avail_h + row_gap) / (cell_h + row_gap)))

        if rows < 2 and cell_h > avail_h then
            -- 连一行都放不下（小屏 / 超大字号 / 行数被压到 1）：压封面高度，仍保持 2:3
            ch = math.max(S.sz(36), avail_h - title_extra)
            cw = math.max(1, math.floor(ch / COVER_RATIO))
            cell_h = ch + title_extra
            rows = 1
        end
    end

    return {
        cols = cols,
        rows = rows,
        auto_rows = not want_rows,
        gap = gap,
        row_gap = row_gap,
        title_extra = title_extra,
        slot_w = slot_w,
        cw = cw,
        ch = ch,
        cell_h = cell_h,
        grid_h = rows * cell_h + (rows - 1) * row_gap,
        perpage = cols * rows,
    }
end

--- 封面控件：走 ui_style 的统一圆角封面（含细描边与四角裁切）。
local function build_cover(entry, m)
    return S.cover(entry.cover_path, m.cw, m.ch)
end

local CoverCellWidget = InputContainer:extend{
    entry = nil,
    metrics = nil,
    dimen = nil,
}

function CoverCellWidget:init()
    local entry = self.entry or {}
    local m = self.metrics
    self.ges_events = {
        TapCell = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldCell = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }

    local clipped_cover, cover_frame, cover_inner = build_cover(entry, m)

    -- 状态徽章（更新 / 连载中 / 已完结 / 已断更）：**叠在封面右上角**，不占纵向空间。
    --
    -- 以前它是 VerticalGroup 里的独立一行（封面 → 书名 → 章节进度 → 进度条 → 徽章），
    -- 但那一行的高度**没有任何调用点算进 `title_extra`**（书架传的是
    -- `titleExtra() + metaExtra()`，书城只加 metaExtra）⇒ 格子里需要的高度
    -- 恒比 `cell_h` 多出「徽章 + 间距」那一截，`CenterContainer` 居中后上下各溢出
    -- 十几像素，被相邻行/分页条压掉 —— 用户看到的就是「每本书竖向都显示不全」
    -- （徽章只露出半截，进度条也贴边）。叠到封面上以后它不再参与纵向排版，
    -- 书名 / 章节 / 进度条按原有预留量就能完整放下（书架另补 `progressExtra()`）。
    local cover_stack = clipped_cover
    if type(entry.tag) == "string" and entry.tag ~= "" then
        local badge = S.badge(entry.tag, 12)
        local bs = badge:getSize()
        local inset = S.sz(4)
        -- 右上角：OverlapGroup 只有在子件带 `overlap_offset`（且没有 `overlap_align`）
        -- 时才按这对坐标摆；`overlap_align = "right"` 会走另一分支、把 offset 忽略掉。
        local bx = m.cw - bs.w - inset
        if bx < 0 then bx = 0 end                       -- 封面比徽章还窄（4~8 列小屏）：贴左不越界
        local by = inset
        if by + bs.h > m.ch then by = math.max(0, m.ch - bs.h) end
        badge.overlap_offset = { bx, by }
        -- `allow_mirroring = false`：镜像版式下 OverlapGroup 会翻转 x，徽章会跑到左上角
        cover_stack = OverlapGroup:new{
            dimen = Geom:new{ w = m.cw, h = m.ch },
            allow_mirroring = false,
            clipped_cover,
            badge,
        }
        -- 诊断锚点：设备日志里出现这行 = 跑的这份 cover_cell 就是「叠加」实现；
        -- 报「标签还在章节下面」却没有这行 ⇒ 设备上的 cover_cell.lua 是旧文件。
        if Log then
            Log.info("[网格] 徽章叠加 tag=", tostring(entry.tag),
                     " offset=", tostring(bx), ",", tostring(by),
                     " cover=", tostring(m.cw), "x", tostring(m.ch),
                     " build=", CoverCell.BUILD)
        end
    end

    local kids = {
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = m.slot_w, h = m.ch },
            cover_stack,
        },
    }

    -- 书名：单行、超宽省略号（TextWidget 的 max_width 默认 truncate_with_ellipsis）
    local title = TextWidget:new{
        text = tostring(entry.title or ""),
        face = S.face("xx_smallinfofont", 13),
        max_width = math.max(1, m.slot_w - S.sz(6)),
        fgcolor = S.ink,
    }
    kids[#kids + 1] = VerticalSpan:new{ width = S.sz(5) }
    kids[#kids + 1] = title

    -- 弱化信息短行（单行、超宽省略号；高度由 metrics 的 title_extra 预留）：
    --   * 书架格：`entry.chapters`「读到哪了」（`122/256 章` / 没读过是 `未读 256 章`）；
    --   * 书城格：`entry.meta`「字数 · 在读」。
    -- 两个槽位共用一行（chapters 优先）；都没有就不画。
    local meta_line = nil
    if type(entry.chapters) == "string" and entry.chapters ~= "" then
        meta_line = entry.chapters
    elseif type(entry.meta) == "string" and entry.meta ~= "" then
        meta_line = entry.meta
    end
    if meta_line then
        kids[#kids + 1] = VerticalSpan:new{ width = S.sz(2) }
        kids[#kids + 1] = TextWidget:new{
            text = meta_line,
            face = S.face("xx_smallinfofont", 12),
            max_width = math.max(1, m.slot_w - S.sz(6)),
            fgcolor = S.muted,
        }
    end

    -- 书架格：读到哪了的细进度条（0~1，未提供就不画）
    if type(entry.progress) == "number" then
        local pct = entry.progress
        if pct < 0 then pct = 0 end
        if pct > 1 then pct = 1 end
        kids[#kids + 1] = VerticalSpan:new{ width = S.sz(3) }
        kids[#kids + 1] = S.progressBar(math.max(S.sz(24), m.slot_w - S.sz(16)), S.sz(4), pct * 100)
    end

    -- ⚠️ 状态徽章**不在这里**：它叠在封面右上角（见上面 `cover_stack`），
    --    一旦放回这个纵向序列就会重新占高度、把书名/进度条挤出去。

    -- 🔴 整格内容**顶部对齐**（v2.16.24）：以前外面套一层
    --    `CenterContainer{dimen={slot_w, cell_h}}` 做垂直居中，内容一旦比 `cell_h`
    --    高（字号/字体度量差一两像素就够），居中会把溢出量**上下各分一半** ——
    --    上面那一半正好画到上一行（书城里就是「排序/状态」那排胶囊）身上，
    --    因为 `item_group` 在控件行之后绘制、把胶囊盖住。用户看到的就是
    --    「网格第一行和排序状态重合」。
    --    现在直接把 VerticalGroup 交给 `box`（FrameContainer 从左上角画子件），
    --    溢出只会往下走；`metrics` 已经把 `title_extra` 按行预留好，正常不溢出。
    --    ⚠️ 不要换成 `TopContainer`：它只是 WidgetContainer 的空壳，而且
    --    `ui/widget/container/topcontainer` 在回归 harness 里没有桩。
    local group = VerticalGroup:new(kids)

    -- 选中态：整格铺一层浅底。背景常驻（FrameContainer 只在有 background 时才画），
    -- 尺寸不随选中变化 ⇒ 不会引起重排/抖动。
    local box = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = nil,
        width = m.slot_w,
        height = m.cell_h,
        dimen = self.dimen,
        group,
    }
    self._box = box
    self._cover_frame = cover_frame
    self._cover_inner = cover_inner
    self[1] = box
end

function CoverCellWidget:onTapCell()
    if self.entry and self.entry.on_tap then self.entry.on_tap() end
    return true
end

function CoverCellWidget:onHoldCell()
    if self.entry and self.entry.on_hold then self.entry.on_hold() end
    return true
end

--- 选中态：整格浅底 + 封面描边加深（墨水屏上没有高亮色，只能靠灰度层次）。
function CoverCellWidget:onFocus()
    if self._box then self._box.background = S.surface end
    if self._cover_frame then self._cover_frame.color = S.ink end
    return true
end

function CoverCellWidget:onUnfocus()
    if self._box then self._box.background = nil end
    if self._cover_frame then self._cover_frame.color = S.border end
    return true
end

--- 造一格。
---@param entry table { title, cover_path, progress?, tag?, on_tap?, on_hold? }
---@param m table CoverCell.metrics 的返回值
---@return table widget
function CoverCell.build(entry, m)
    return CoverCellWidget:new{
        entry = entry,
        metrics = m,
        dimen = Geom:new{ w = m.slot_w, h = m.cell_h },
    }
end

-- ------------------------------------------------------------------ 显示方式对话框
--
-- 两个视图（书架 / 书城）共用同一套按钮与「自定义」输入框：唯一不同的是
-- `on_apply` 里往哪个 settings 键写（`ui.shelf` / `ui.store`）—— 所以对话框本身
-- 放这里，设置写入留在各自的 view 里（那里才有 kind）。

--- 显示方式对话框。
---@param spec table { current_mode, current_cols, current_rows,
---                    on_apply = function(mode, cols, rows),
---                    owner = table|nil, field = string|nil } —— owner/field 用于
---       把对话框挂在菜单上（菜单关闭时统一收掉）并在开新的之前关掉旧的。
function CoverCell.show_view_dialog(spec)
    spec = spec or {}
    local owner, field = spec.owner, spec.field or "_view_dialog"
    local ButtonDialog = require("ui/widget/buttondialog")

    local function close_old()
        if not owner then return end
        local old = owner[field]
        owner[field] = nil
        if old and H and H.close_widget then H.close_widget(old) end
    end
    close_old()

    local function apply(mode, cols, rows)
        if spec.on_apply then pcall(spec.on_apply, mode, cols, rows) end
    end

    local buttons = {}
    -- 🔴 循环变量不能叫 `_`：本模块的 gettext 就是局部名 `_`。
    for _i, o in ipairs(CoverCell.layout_options(spec.current_mode,
            spec.current_cols, spec.current_rows)) do
        local label = o.label .. (o.current and "  ✓" or "")
        if o.custom then
            buttons[#buttons + 1] = { {
                text = label,
                callback = function()
                    close_old()
                    CoverCell.show_custom_layout_dialog(o.cols, o.rows, function(c, r)
                        apply("grid", c, r)
                    end, owner, field)
                end,
            } }
        else
            buttons[#buttons + 1] = { {
                text = label,
                callback = function()
                    close_old()
                    apply(o.mode, o.cols, o.rows)
                end,
            } }
        end
    end
    buttons[#buttons + 1] = { { text = _("取消"), callback = close_old } }

    local dialog = ButtonDialog:new{
        title = _("显示方式"),
        title_align = "center",
        buttons = buttons,
    }
    if owner then owner[field] = dialog end
    UIManager:show(dialog)
end

--- 「自定义列×行」输入框。填错**不关框**（就地提示，让用户改）——关掉再让用户
--- 重新翻一遍菜单是最糟的交互。
---@param cols number 当前列数（作为输入初值）
---@param rows number 当前行数（0 = 自动）
---@param on_ok function(cols, rows)
---@param owner table|nil
---@param field string|nil
function CoverCell.show_custom_layout_dialog(cols, rows, on_ok, owner, field)
    local InputDialog = require("ui/widget/inputdialog")
    local InfoMessage = require("ui/widget/infomessage")
    cols, rows = CoverCell.normalize_layout(cols, rows)

    local dialog
    local function dismiss()
        if owner and field then owner[field] = nil end
        if dialog and H and H.close_widget then H.close_widget(dialog) end
        dialog = nil
    end

    local range_hint = T(_("列 %1~%2、行 %3~%4"), tostring(CoverCell.GRID_COLS_MIN),
        tostring(CoverCell.GRID_COLS_MAX), tostring(CoverCell.GRID_ROWS_MIN),
        tostring(CoverCell.GRID_ROWS_MAX))

    dialog = InputDialog:new{
        title = _("自定义列×行"),
        input = tostring(cols) .. "x" .. tostring(rows > 0 and rows or CoverCell.DEFAULT_ROWS),
        input_hint = _("格式：列x行，如 4x5") .. "（" .. range_hint .. "）",
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = dismiss,
                },
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local c, r = CoverCell.parse_layout(dialog:getInputText())
                        if not c then
                            UIManager:show(InfoMessage:new{
                                text = T(_("格式不对：请填「列×行」，%1"), range_hint),
                                timeout = 3,
                            })
                            return
                        end
                        dismiss()
                        if on_ok then pcall(on_ok, c, r) end
                    end,
                },
            },
        },
    }
    if owner and field then owner[field] = dialog end
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return CoverCell
