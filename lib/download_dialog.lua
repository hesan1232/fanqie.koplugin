local UIManager = require("ui/uimanager")
local ok_device, device = pcall(require, "device")
local Screen = ok_device and device.screen or nil
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local TextWidget = require("ui/widget/textwidget")
local ProgressWidget = require("ui/widget/progresswidget")
local Button = require("ui/widget/button")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Font = require("ui/font")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local DownloadDialog = {}
DownloadDialog.__index = DownloadDialog

function DownloadDialog:new(ui, title)
    local self = setmetatable({}, DownloadDialog)
    self.ui = ui
    self.title = title or _("Downloading")
    self.progress = 0
    self.status = ""
    self.cancelled = false
    self:create_widget()
    return self
end

function DownloadDialog:create_widget()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local dialog_w = math.floor(screen_w * 0.8)
    local dialog_h = math.floor(screen_h * 0.35)

    -- Build content vertically
    local content = VerticalGroup:new{
        align = "center",
    }

    -- Title
    self.title_widget = TextWidget:new{
        text = self.title,
        face = Font:getFace("cfont", 24),
        bold = true,
        alignment = "center",
    }
    table.insert(content, self.title_widget)

    -- Status text
    self.status_text = TextWidget:new{
        text = "",
        face = Font:getFace("cfont", 18),
        alignment = "center",
    }
    table.insert(content, self.status_text)

    -- Progress bar
    self.progress_widget = ProgressWidget:new{
        width = math.floor(screen_w * 0.7),
        height = 20,
        percentage = 0,
        margin_top = 15,
        margin_h = 10,
    }
    table.insert(content, self.progress_widget)

    -- Percentage text
    self.percent_text = TextWidget:new{
        text = "0%",
        face = Font:getFace("cfont", 16),
        alignment = "center",
    }
    table.insert(content, self.percent_text)

    -- Cancel button
    local cancel_btn = Button:new{
        text = _("取消"),
        width = math.floor(dialog_w * 0.4),
        callback = function()
            self.cancelled = true
            self:close()
        end,
    }

    local btn_container = CenterContainer:new{
        dimen = {
            w = dialog_w,
            h = cancel_btn:getSize().h + 10,
        },
        cancel_btn,
    }
    table.insert(content, btn_container)

    -- Frame to hold content
    local frame = FrameContainer:new{
        background = 0,
        bordersize = 2,
        padding = 15,
        radius = 8,
        width = dialog_w,
        height = dialog_h,
        content,
    }

    -- CenterContainer to center the frame on screen
    self.dialog = CenterContainer:new{
        dimen = {
            w = screen_w,
            h = screen_h,
        },
        frame,
    }
end

function DownloadDialog:show()
    UIManager:show(self.dialog)
    UIManager:forceRePaint()
end

function DownloadDialog:update(progress, status)
    if self.cancelled then
        return false
    end
    self.progress = progress or 0
    self.status = status or ""
    self.progress_widget:setPercentage(self.progress)
    self.percent_text:setText(string.format("%d%%", math.floor(self.progress * 100)))
    self.status_text:setText(self.status)
    UIManager:forceRePaint()
    return true
end

function DownloadDialog:close()
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
end

function DownloadDialog:is_cancelled()
    return self.cancelled
end

return DownloadDialog
