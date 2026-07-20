local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Screen = Device.screen

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local DownloadProgress = InputContainer:extend{
    title = _("下载中"),
    on_cancel = nil,
}

local function clamp(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function DownloadProgress:init()
    self.dimen = Screen:getSize()
    self.cancelled = false

    local frame_width = math.floor(Screen:getWidth() * 0.82)
    local frame_height = math.floor(Screen:getHeight() * 0.60)
    local content_width = frame_width - Size.padding.large * 2
    local content_height = frame_height - Size.padding.large * 2
    local group = VerticalGroup:new{align="center"}

    self.title_widget = TextBoxWidget:new{
        text = self.title or _("下载中"),
        face = Font:getFace("ffont", 22),
        bold = true,
        width = content_width,
        height = math.floor(content_height * 0.15),
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    group[#group + 1] = self.title_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.large}

    self.progress = ProgressWidget:new{
        width = content_width,
        height = Screen:scaleBySize(20),
        percentage = 0,
        fillcolor = Blitbuffer.COLOR_BLACK,
        padding = Size.padding.small,
        margin = Size.margin.tiny,
    }
    group[#group + 1] = self.progress
    group[#group + 1] = VerticalSpan:new{width = Size.padding.small}

    self.percent_widget = TextBoxWidget:new{
        text = "0%",
        face = Font:getFace("cfont", 19),
        width = content_width,
        height = math.floor(content_height * 0.07),
        height_adjust = false,
        alignment = "center",
    }
    group[#group + 1] = self.percent_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.large}

    self.status_widget = TextBoxWidget:new{
        text = _("准备下载……"),
        face = Font:getFace("cfont", 18),
        width = content_width,
        height = math.floor(content_height * 0.48),
        height_adjust = false,
        height_overflow_show_ellipsis = true,
        alignment = "center",
    }
    group[#group + 1] = self.status_widget
    group[#group + 1] = VerticalSpan:new{width = Size.padding.large}

    self.buttons = ButtonTable:new{
        width = content_width,
        show_parent = self,
        zero_sep = true,
        buttons = {{
            {
                text = _("取消下载"),
                callback = function()
                    if self.cancelled then return end
                    self.cancelled = true
                    self.status_widget:setText(_("正在取消……"))
                    self:_redraw()
                    if self.on_cancel then self.on_cancel() end
                end,
            },
        }},
    }
    group[#group + 1] = self.buttons

    local fixed_area = CenterContainer:new{
        dimen = Geom:new{x=0, y=0, w=content_width, h=content_height},
        group,
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = Size.padding.large,
        fixed_area,
    }
    self[1] = CenterContainer:new{
        dimen = self.dimen,
        self.frame,
    }
end

function DownloadProgress:_redraw()
    local target = (self.frame and self.frame.dimen) or self.dimen
    UIManager:setDirty(self, function()
        return "fast", target
    end)
end

function DownloadProgress:setState(state)
    state = state or {}
    local current = tonumber(state.current) or 0
    local total = tonumber(state.total) or 0
    local percent = tonumber(state.percent)
    if not percent then
        percent = total > 0 and (current / total) or 0
    elseif percent > 1 then
        percent = percent / 100
    end
    percent = clamp(percent, 0, 1)

    local labels = {
        prepare = _("准备下载"),
        catalog = _("读取目录"),
        content = _("获取章节正文"),
        done = _("下载完成"),
        error = _("下载失败"),
        cancelled = _("下载已取消"),
    }
    local rows = {}
    rows[#rows + 1] = labels[state.stage] or tostring(state.stage or _("处理中"))
    if total > 0 then rows[#rows + 1] = string.format(_("章节 %d / %d"), current, total) end
    if state.chapter and state.chapter ~= "" then rows[#rows + 1] = state.chapter end
    if state.message and state.message ~= "" then rows[#rows + 1] = state.message end
    local percent_text = tostring(math.floor(percent * 100 + 0.5)) .. "%"
    local status_text = table.concat(rows, "\n")
    local signature = percent_text .. "\n" .. status_text
    if signature == self._last_signature then return end
    self._last_signature = signature
    self.progress:setPercentage(percent)
    self.percent_widget:setText(percent_text)
    self.status_widget:setText(status_text)
    self:_redraw()
end

function DownloadProgress:isCanceled()
    return self.cancelled
end

function DownloadProgress:show()
    UIManager:show(self, "ui")
end

function DownloadProgress:close()
    UIManager:close(self, "ui")
end

return DownloadProgress