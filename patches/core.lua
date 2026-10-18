local M = {
    _mark = "_fanqie_patch",
    _mark_link = "_fanqie_patch_link",
    -- 导航补丁（ReaderPaging & ReaderRolling）版本化标记：
    -- 升级时改变此值即可强制重新安装，无需改动 _mark / _mark_link。
    -- v3: 回退向前翻页拦截（前天版本逻辑），仅保留向后翻页的上一章拦截
    _mark_nav = "_fanqie_patch_nav_v3",
    -- v2.16.21：段评拦截从「只拦 onGotoLink」升级为「onTap 主拦 + onGotoLink 兜底」。
    -- 🔴 必须换新标记：老版本装过的设备上 `_mark_link` 已经是 true，
    --    若沿用旧标记，`install()` 第一行 `if verifyPatched() then return end`
    --    会直接返回 ⇒ 新加的 onTap 层永远装不上，症状与没升级一模一样。
    _mark_link_v2 = "_fanqie_patch_link_v2",
}

local H = require("fanqie.helper")

M.verifyPatched = function(modname)
    if modname == "ReaderLink" then
        local ReaderLink = require("apps/reader/modules/readerlink")
        -- 版本化的新标记是唯一判据：老设备上的 _mark_link 已被旧补丁置 true，
        -- 不能再当「装好了」的证据（见 M._mark_link_v2 注释）。
        return ReaderLink[M._mark_link_v2] == true
    end
    -- 默认检查所有补丁是否都已安装
    local ReaderToc = require("apps/reader/modules/readertoc")
    if ReaderToc[M._mark] ~= true then return false end
    local ReaderLink = require("apps/reader/modules/readerlink")
    if ReaderLink[M._mark_link_v2] ~= true then return false end
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

--- 判断一个文档路径是不是「番茄缓存目录里的章节文件」。
--
-- 🔴 v2.16.21 修：以前只认路径里有没有 `/fanqie/`，**对真实缓存文件恒为假**。
--    真实路径由 `Content.book_cache_dir()` 决定：
--        <cache_dir>/<book_id>/chapter_<item_id>.html
--    其中 `cache_dir` 默认是 `<koreader>/fanqie/cache`（**小写** fanqie，来自
--    DataStorage 的插件数据目录），但用户在设置里改过下载目录后会变成任意路径
--    （真机日志里出现的是 `/mnt/us/番茄小说/7544766518324644889/chapter_xxx.html`）。
--    `file_path:lower()` 之后 `番茄小说` 不会变成 `fanqie`，于是：
--        · ReaderToc / ReadHistory / 翻页 / 段评链接 **全部补丁**的守卫都为假；
--        · 症状就是「补丁装上了、标记也是 true，可一个都不生效」——
--          v2.16.20 之前段评拦截从来没命中过（日志里零条 onFanQieParaReview）。
--
--    改成**结构判据**，不依赖目录名、也不依赖大小写：
--        ① 尾部是章节文件名 `.../chapter_<item_id>.html`（与
--           `state.book_id_from_path` 同一口径）；
--        ② 其父目录名满足书号形状（`basename_safe` 只保留 [%w%._-] ⇒ 纯数字 /
--           字母数字）。
--    只要满足这两条，就是番茄写出来的章节文件；用户自己丢在别处的
--    `chapter_x.html` 不会凑成「父目录像书号 + 文件名像章节」的形状，也不会被
--    误判成番茄章节，所以宁可用结构判据也**不**去读全局 settings
--    （补丁在 require 阶段没有插件实例，读 settings 会引入 KOReader-版本相关的
--     依赖，而且拖慢每次翻页/点链接）。
--- @param file_path string|nil
--- @param instance table|nil  ReaderToc / ReaderLink / ReaderPaging 等（取 .ui）
--- @return boolean
local is_fanqie_path = function(file_path, instance)
    if instance and instance.document and instance.document.file then
        file_path = instance.document.file
    end
    if not H.is_str(file_path) or file_path == "" then
        return false
    end
    -- 兼容 Windows 风格分隔符（真机是 Unix，但回归桩/开发机可能用 \）
    local normalized = file_path:gsub("\\", "/")
    if not normalized:match("/chapter_[^/]+%.html$") then
        return false
    end
    local parent = normalized:match("/([^/]+)/chapter_[^/]+%.html$")
    -- 书号经 basename_safe 后只含 [%w%._-]；要求至少 6 位，避免 `/a/chapter_b.html`
    -- 这种人工构造路径被误判。
    return parent ~= nil and #parent >= 6 and parent:match("^[%w%._-]+$") ~= nil
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
    -- 🔴 这里必须拦**两层**，只拦 onGotoLink 是不够的（v2.16.21 真机事故）：
    --
    --   crengine 文档点链接的实际路径是
    --     ReaderLink:onTap → getLinkFromGes → **showLinkBox** → onGotoLink
    --   `showLinkBox` 里对 crengine 分支的判断是：
    --     `elseif link and link.xpointer ~= "" then return self:onGotoLink(link, ...)`
    --   —— 也就是说 **`link.xpointer` 为空时直接 return nil，根本走不到
    --   onGotoLink**。而 crengine 只会把「能在文档里解析到的锚点」放进
    --   link_xpointer；`fanqie-para:18` 这种自定义 scheme 不是文档内锚点，
    --   解析结果为**空串**，于是：
    --      ① showLinkBox 判空 → 返回 nil → tap 事件继续往外传；
    --      ② 某些 KOReader 版本 / 设置下（larger_tap_area_to_follow_links
    --         打开，或该版 onTap 在没有 xpointer 时改走 onGoToPageLink）
    --         最终仍会兜到 onGotoLink，用 `link.xpointer`（此时是**空串**或
    --         被改写过的串）当 URL ⇒ 弹「Invalid or external link: …」。
    --   用户看到的 `评论无效或外部链接：fanqie-paea:18` 就是后者：串已经不是
    --   我们写的 `fanqie-para:`，而是被中间环节动过的样子。
    --
    -- 结论：**只要 link.xpointer 为空，就不能指望 onGotoLink 能拿到原始 href**。
    --   所以补丁分两层：
    --     层 A（主）：猴补丁 `ReaderLink.onTap` —— 在调用原函数**之前**，
    --       用 `getLinkFromGes` 拿到 (link_xpointer, a_xpointer)；
    --       `a_xpointer` 是指向 <a> 元素本身的 xpointer，**与 href 无关**，
    --       空 href / 自定义 scheme 一样有值。于是改为取该元素的
    --       `href` 属性（getAttributeFromXPointer），认出 fanqie-para: 就
    --       直接派事件并**吃掉这次 tap**。
    --     层 B（兜底）：保留 onGotoLink 拦截，覆盖「别处直接调 onGotoLink」
    --       的路径（如脚注弹窗 / 搜索结果跳转）。
    local ReaderLink = require("apps/reader/modules/readerlink")

    -- 从 <a> 元素 xpointer 取 href：crengine 没有现成的公开 API，
    -- 用 getText/属性查询都不可靠 ⇒ 直接用 document:getHTMLFromXPointer。
    -- ⚠️ 只取很小的一段（90 字符足够装下 href="fanqie-para:#NNN"），
    --    避免整段 HTML 过桥（跨 C 边界字符串很贵）。
    local function fanqie_para_idx_from_a_xpointer(ui, a_xpointer)
        if type(a_xpointer) ~= "string" or a_xpointer == "" then return nil end
        local doc = ui and ui.document
        if not doc or type(doc.getHTMLFromXPointer) ~= "function" then return nil end
        local ok, html = pcall(doc.getHTMLFromXPointer, doc, a_xpointer, 0, false)
        if not ok or type(html) ~= "string" then return nil end
        -- 同时认新格式 `fanqie-para:#18` 与旧缓存里的 `fanqie-para:18`
        -- （老章节文件已经写死在设备上，重下才会更新，不能只认新格式）
        local idx = tonumber(html:match('href%s*=%s*["\']fanqie%-para:%s*#?(%d+)'))
        return idx
    end

    if not ReaderLink[M._mark_link_v2] then
        local original_onTap = ReaderLink.onTap
        function ReaderLink:onTap(arg, ges)
            if self.ui and is_fanqie_path(nil, self.ui) and ges and ges.pos
                    and not self.ui.paging
                    and type(self.getLinkFromGes) == "function" then
                -- 只有一个精确命中的 <a> 才拦（getLinkFromGes 内部已做
                -- 「点是否落在链接上」的坐标判定），不扩张点击热区。
                local ok_l, link = pcall(self.getLinkFromGes, self, ges)
                local a_xp = ok_l and type(link) == "table" and link.a_xpointer or nil
                local idx = a_xp and fanqie_para_idx_from_a_xpointer(self.ui, a_xp) or nil
                if idx then
                    self.ui:handleEvent(Event:new("FanQieParaReview", idx))
                    return true
                end
            end
            return original_onTap(self, arg, ges)
        end

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
                    -- `#?` 兼容旧缓存里的 `fanqie-para:18` 与新格式 `fanqie-para:#18`
                    local idx = tonumber(link_url:match("fanqie%-para:%s*#?(%d+)"))
                    if idx then
                        self.ui:handleEvent(Event:new("FanQieParaReview", idx))
                        return true
                    end
                end
            end
            return original_onGotoLink(self, link, neglect_current_location,
                allow_footnote_popup)
        end
        ReaderLink[M._mark_link_v2] = true
        -- 老标记也顺手置上：万一有其他代码还在看它，别让它变成 false
        ReaderLink[M._mark_link] = true
    end
end

return M
