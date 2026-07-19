local M = {
    _mark = "_fanqie_patch",
}

local H = require("lib.helper")

M.verifyPatched = function()
    local ReaderToc = require("apps/reader/modules/readertoc")
    return ReaderToc[M._mark] == true
end

M.is_plugin_disabled = function()
    if G_reader_settings and G_reader_settings.readSetting then
        local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
        if plugins_disabled and plugins_disabled["fanqie"] == true then
            return true
        end
    end
    return false
end

local is_fanqie_path = function(file_path, instance)
    if instance and instance.document and instance.document.file then
        file_path = instance.document.file
    end
    return H.is_str(file_path) and file_path:lower():find('/fanqie/', 1, true) or false
end

M.install = function()
    if M.is_plugin_disabled() then
        return
    end
    if M.verifyPatched() then
        return
    end

    local Event = require("ui/event")

    local ReaderToc = require("apps/reader/modules/readertoc")
    local original_onShowToc = ReaderToc.onShowToc
    function ReaderToc:onShowToc()
        if is_fanqie_path(nil, self.ui) then
            self.ui:handleEvent(Event:new("ShowFanQieToc"))
            return true
        else
            return original_onShowToc(self)
        end
    end
    ReaderToc[M._mark] = true

    local ReadHistory = require("readhistory")
    local original_addItem = ReadHistory.addItem
    function ReadHistory:addItem(file, ts, no_flush)
        if is_fanqie_path(file) then
            return
        end
        return original_addItem(self, file, ts, no_flush)
    end
end

return M