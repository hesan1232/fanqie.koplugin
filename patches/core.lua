local M = {
    _mark = "_fanqie_patch",
    _mark_link = "_fanqie_patch_link",
    -- 导航补丁（ReaderPaging & ReaderRolling）版本化标记：
    -- 升级时改变此值即可强制重新安装，无需改动 _mark / _mark_link。
    -- v3: 回退向前翻页拦截（前天版本逻辑），仅保留向后翻页的上一章拦截
    _mark_nav = "_fanqie_patch_nav_v3",
}

local H = require("fanqie.helper")

M.verifyPatched = function(modname)
    if modname == "ReaderLink" then
        local ReaderLink = require("apps/reader/modules/readerlink")
        return ReaderLink[M._mark_link] == true
    end
    -- 默认检查所有补丁是否都已安装
    local ReaderToc = require("apps/reader/modules/readertoc")
    if ReaderToc[M._mark] ~= true then return false end
    local ReaderLink = require("apps/reader/modules/readerlink")
    if ReaderLink[M._mark_link] ~= true then return false end
    -- 导航补丁（ReaderPaging & ReaderRolling）— 版本化检查
    local ReaderPaging = require("apps/reader/modules/readerpaging")
    if ReaderPaging[M._mark_nav] ~= true then return false end
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    if ReaderRolling[M._mark_nav] ~= true then return false end
    return true
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

    -- =========================================================================
    -- 补丁1：ReaderToc — 番茄文档的目录交给插件处理
    -- =========================================================================
    local ReaderToc = require("apps/reader/modules/readertoc")
    if not ReaderToc[M._mark] then
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
    end

    -- =========================================================================
    -- 补丁2：ReadHistory — 番茄缓存文件不进入阅读历史
    -- =========================================================================
    local ReadHistory = require("readhistory")
    if not ReadHistory[M._mark] then
        local original_addItem = ReadHistory.addItem
        function ReadHistory:addItem(file, ts, no_flush)
            if is_fanqie_path(file) then
                return
            end
            return original_addItem(self, file, ts, no_flush)
        end
        ReadHistory[M._mark] = true
    end

    -- =========================================================================
    -- 补丁3：ReaderPaging — 在第一页前翻页时触发上一章
    -- =========================================================================
    local ReaderPaging = require("apps/reader/modules/readerpaging")
    if not ReaderPaging[M._mark_nav] then
        local original_onGotoViewRel = ReaderPaging.onGotoViewRel
        function ReaderPaging:onGotoViewRel(diff, no_page_turn)
            local old_pos = self:getTopPage()
            local result = original_onGotoViewRel(self, diff, no_page_turn)
            local new_pos = self:getTopPage()
            if diff < 0 and old_pos == 1 and old_pos == new_pos and is_fanqie_path(nil, self.ui) then
                self.ui:handleEvent(Event:new("FanQiePrevChapter"))
            end
            return result
        end
        ReaderPaging[M._mark_nav] = true
    end

    -- =========================================================================
    -- 补丁4：ReaderRolling — 滚动模式下第一页前翻页触发上一章
    -- =========================================================================
    local ReaderRolling = require("apps/reader/modules/readerrolling")
    if not ReaderRolling[M._mark_nav] then
        local original_onGotoViewRel_rolling = ReaderRolling.onGotoViewRel
        ReaderRolling.onGotoViewRel = function(rolling_self, diff)
            local scroll_mode = rolling_self.view.view_mode == "scroll"
            local old_pos = scroll_mode and rolling_self.current_pos or rolling_self.current_page
            original_onGotoViewRel_rolling(rolling_self, diff)
            local new_pos = scroll_mode and rolling_self.current_pos or rolling_self.current_page
            if diff < 0 and old_pos == new_pos and is_fanqie_path(nil, rolling_self.ui) then
                rolling_self.ui:handleEvent(Event:new("FanQiePrevChapter"))
            end
            return true
        end
        ReaderRolling[M._mark_nav] = true
    end

    -- =========================================================================
    -- 补丁5：ReaderLink — 拦截 fanqie-para:N 段评链接
    -- =========================================================================
    -- 原因：ReaderLink:showLinkBox() 直接调用 self:onGotoLink()（方法调用，
    --   非事件广播），所以插件自身的 onGotoLink 永远收不到。
    --   ReaderLink:onGotoLink 不认识 fanqie-para: 协议，会报"无效或外部链接"。
    -- 方案：猴补丁 ReaderLink.onGotoLink，在原函数之前检查 fanqie-para: 前缀，
    --   匹配则派发 FanQieParaReview 事件给插件，return true 阻止原逻辑。
    local ReaderLink = require("apps/reader/modules/readerlink")
    if not ReaderLink[M._mark_link] then
        local original_onGotoLink = ReaderLink.onGotoLink
        function ReaderLink:onGotoLink(link, neglect_current_location, allow_footnote_popup)
            if link and is_fanqie_path(nil, self.ui) then
                -- crengine: link.xpointer；PDF: link.uri
                local link_url = nil
                if self.ui.paging then
                    link_url = link.uri
                else
                    link_url = link.xpointer
                end
                if link_url and type(link_url) == "string"
                    and link_url:find("^fanqie%-para:") then
                    local idx = tonumber(link_url:match("fanqie%-para:(%d+)"))
                    if idx then
                        self.ui:handleEvent(Event:new("FanQieParaReview", idx))
                        return true
                    end
                end
            end
            return original_onGotoLink(self, link, neglect_current_location,
                allow_footnote_popup)
        end
        ReaderLink[M._mark_link] = true
    end
end

return M
