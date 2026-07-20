local I18n = {}

local zh = {
    ["FanQie"] = "番茄小说",
    ["Read FanQie (番茄小说) books in KOReader, cache chapters, and sync reading progress."] = "在 KOReader 中阅读番茄小说、缓存章节并同步阅读进度。",
    ["Bookshelf"] = "书架",
    ["Search"] = "搜索",
    ["Settings"] = "设置",
    ["Sync progress now"] = "立即同步进度",
    ["Book details"] = "书籍详情",
    ["Reload config.lua"] = "重新加载 config.lua",
    ["config.lua error:\n%1"] = "config.lua 错误：\n%1",
    ["config.lua loaded."] = "config.lua 已加载。",
    ["Renew cookie now"] = "立即续期 Cookie",
    ["Progress management"] = "进度管理",
    ["Pull progress on open"] = "打开时拉取进度",
    ["Upload progress on close"] = "关闭时上传进度",
    ["Download content"] = "下载内容",
    ["Book images"] = "书籍图片",
    ["Underlines and thoughts"] = "划线和想法",
    ["Confirm"] = "确认",
    ["Account management"] = "账号管理",
    ["Account status"] = "账号状态",
    ["Clear account data"] = "清除账号数据",
    ["%1 failed:\n%2"] = "%1 失败：\n%2",
    ["No network connection. Please connect Wi-Fi and try again."] = "当前没有网络连接，请连接 Wi-Fi 后重试。",
    ["No items."] = "没有条目。",
    ["Import FanQie cookie or cURL"] = "导入番茄小说 Cookie 或 cURL",
    ["Paste a raw Cookie header or a full cURL copied from FanQie API."] = "粘贴原始 Cookie header，或从番茄小说 API 复制的完整 cURL。",
    ["Cancel"] = "取消",
    ["Save"] = "保存",
    ["Could not find a valid cookie."] = "没有找到有效的 Cookie。",
    ["Cookie is not configured."] = "尚未配置 Cookie。",
    ["Renew cookie"] = "续期 Cookie",
    ["FanQie cookie renewed."] = "番茄小说 Cookie 已续期。",
    ["Cookie renewal completed, but response did not include succ=1."] = "Cookie 续期请求已完成，但响应里没有 succ=1。",
    ["configured"] = "已配置",
    ["missing"] = "缺失",
    ["Cookie: %1\nCache directory:\n%2"] = "Cookie：%1\n缓存目录：\n%2",
    ["Clear FanQie cookie? Cached books will remain."] = "清除番茄小说 Cookie？已缓存书籍会保留。",
    ["Clear"] = "清除",
    ["FanQie account data cleared."] = "番茄小说账号数据已清除。",
    ["Load bookshelf failed:\n%1"] = "加载书架失败：\n%1",
    ["Untitled"] = "未命名",
    ["Done"] = "已读完",
    ["FanQie Bookshelf"] = "番茄小说书架",
    ["Your FanQie shelf is empty."] = "番茄小说书架为空。",
    ["Loading bookshelf..."] = "正在加载书架...",
    ["%1 chapters"] = "%1 章",
    ["Not loaded"] = "未加载",
    ["Import cookie/cURL before loading chapters."] = "加载章节前请先导入 Cookie/cURL。",
    ["Loading chapter list..."] = "正在加载章节目录...",
    ["Load chapters failed:\n%1"] = "加载章节失败：\n%1",
    ["Chapter %1"] = "第 %1 章",
    ["Chapter"] = "章节",
    ["Cached"] = "已缓存",
    ["%1 words"] = "%1 字",
    ["Chapter list"] = "章节目录",
    ["No chapters."] = "没有章节。",
    ["Download chapter and read"] = "下载本章并阅读",
    ["Downloading chapter: %1"] = "正在下载章节：%1",
    ["Open cached book"] = "打开已缓存书籍",
    ["Download full book"] = "下载全书",
    ["Download all %1 chapters as one EPUB?"] = "将全部 %1 章下载为一个 EPUB？",
    ["Download"] = "下载",
    ["EPUB"] = "EPUB",
    ["Downloaded %1 chapters."] = "已下载 %1 章。",
    ["Downloaded %1 chapters.\n\nBook saved:\n%2\n\nRead now?"] = "已下载 %1 章。\n\n书籍已保存：\n%2\n\n现在阅读？",
    ["Close"] = "关闭",
    ["Not cached"] = "未缓存",
    ["No actions."] = "没有可用操作。",
    ["No cached file."] = "没有已缓存文件。",
    ["Import cookie/cURL before downloading book content."] = "下载书籍内容前请先导入 Cookie/cURL。",
    ["Downloading first chapter..."] = "正在下载第一章...",
    ["Downloading first chapter, please wait..."] = "正在下载第一章，请稍候...",
    ["Download failed:\n%1"] = "下载失败：\n%1",
    ["Read now"] = "立即阅读",
    ["Pull progress"] = "拉取进度",
    ["Remote progress: %1%"] = "远端进度：%1%",
    ["Search FanQie"] = "搜索番茄小说",
    ["Search failed:\n%1"] = "搜索失败：\n%1",
    ["Search: %1"] = "搜索：%1",
    ["No search results."] = "没有搜索结果。",
    ["on"] = "开",
    ["off"] = "关",
    ["Books"] = "书籍",
    ["%1 books"] = "%1 本书",
    ["Loading articles..."] = "正在加载文章列表...",
    ["Load articles failed:\n%1"] = "加载文章列表失败：\n%1",
    ["No articles."] = "没有文章。",
    ["Article"] = "文章",
    ["Download article and read"] = "下载文章并阅读",
    ["Downloading article: %1"] = "正在下载文章：%1",
    ["Import cookie/cURL before loading articles."] = "加载文章前请先导入 Cookie/cURL。",
    ["Import cookie/cURL before downloading articles."] = "下载文章前请先导入 Cookie/cURL。",
    ["Reading time report"] = "阅读时间上报",
    ["Enable reading time report"] = "启用阅读时间上报",
    ["Select target book"] = "选择目标书籍",
    ["Not configured"] = "未配置",
    ["Report status"] = "上报状态",
    ["Report book: %1\nStatus: %2"] = "上报书籍：%1\n状态：%2",
    ["Running"] = "运行中",
    ["Stopped"] = "已停止",
    ["Reported: %1 times, last: %2"] = "已上报：%1 次，最近：%2",
    ["Last error: %1"] = "最近错误：%1",
    ["Cookie expired"] = "Cookie 已过期",
    ["Only report when reading"] = "仅在阅读时上报",
    ["Reading time report started: %1"] = "阅读时间上报已启动：%1",
    ["Select a book to report reading time"] = "选择一本书用于上报阅读时间",
    ["Target book set: %1"] = "已设置目标书籍：%1",
    ["Downloading: %1"] = "正在下载：%1",
    ["Downloading images: %1"] = "正在下载图片：%1",
    ["Please select a target book"] = "请先选择目标书籍",
    ["Download cancelled"] = "下载已取消",
    ["Cancel download"] = "取消下载",
    ["Cache management"] = "缓存管理",
    ["Cache cleanup"] = "缓存清理",
    ["Cache directory"] = "缓存目录",
    ["Cache directory: %1"] = "缓存目录：%1",
    ["Download directory set to:\n%1"] = "下载目录已设置为：\n%1",
    ["Download directory set to:\n%1\nExisting downloads stay in the old location."] = "下载目录已设置为：\n%1\n已下载的内容仍保留在原位置。",
    ["Download directory changed. Move %1 cached book(s) to the new location?"] = "下载目录已更改。是否将 %1 本已缓存的书籍移动到新位置？",
    ["Move"] = "移动",
    ["Keep"] = "保留",
    ["Moving cached books..."] = "正在移动已缓存的书籍……",
    ["Moved %1 book(s) to:\n%2"] = "已将 %1 本书籍移动到：\n%2",
    ["Moved %1 book(s). %2 skipped (target already exists), %3 failed. These stay in the old location."] = "已移动 %1 本书籍。%2 本已跳过（目标已存在），%3 本失败。这些仍保留在原位置。",
    ["Cannot use this directory: %1"] = "无法使用该目录：%1",
    ["Invalid path."] = "路径无效。",
    ["Directory does not exist and could not be created."] = "目录不存在且无法创建。",
    ["Directory is not writable."] = "目录不可写。",
    ["Clear cache for \"%1\"?"] = "清除「%1」的缓存？",
    ["Clear all cache"] = "清除所有缓存",
    ["Clear all cache? Downloaded books and articles will be deleted."] = "清除所有缓存？已下载的书籍和文章将被删除。",
    ["[Cleanup] Clear all cache (%1)"] = "【清理】清除所有缓存（%1）",
    ["Cache cleared"] = "缓存已清除",
    ["No cached items"] = "没有缓存内容",
    ["%1 files, %2"] = "%1 个文件，%2",
    ["Author"] = "作者",
    ["Translator"] = "译者",
    ["Publisher"] = "出版社",
    ["Category"] = "分类",
    ["Word count"] = "字数",
    ["w words"] = "万字",
    ["Rating"] = "评分",
    ["%1 (%2 ratings)"] = "%1（%2 人评价）",
    ["Introduction"] = "简介",
    ["Loading book info..."] = "正在加载书籍信息...",
    ["Book info"] = "书籍信息",
    ["Clear book cache"] = "清除本书缓存",
    ["Bookshelf sort order"] = "书架排序",
    ["Last read time (newest first)"] = "最后阅读时间（最新优先）",
    ["Last read time (oldest first)"] = "最后阅读时间（最早优先）",
    ["Title A-Z"] = "书名 A-Z",
    ["Title Z-A"] = "书名 Z-A",
    ["Default order"] = "默认顺序",
    ["Reading progress"] = "阅读进度",
    ["Auto-associate"] = "自动关联",
    ["Manual: %1"] = "手动：%1",
    ["Auto: %1"] = "自动：%1",
    ["Auto-associate with FanQie book"] = "自动关联番茄小说书籍",
    ["Manually set report book"] = "手动设置上报书籍",
    ["Current book is not from FanQie, reading time not reported"] = "当前书籍非番茄小说书籍，不上报阅读时间",
    ["WIP"] = "开发中",
    ["About (v%1)"] = "关于（v%1）",
    ["FanQie Plugin v%1\n\nDisclaimer: This project is for personal learning and technical research only, not for commercial use. All consequences arising from the use of this project (including but not limited to account bans, data loss, etc.) are borne by the user. The project author assumes no responsibility. Please comply with FanQie's user agreement and applicable laws and regulations."] = "FanQie 插件 v%1\n\n免责声明：本项目仅供个人学习和技术研究使用，不得用于商业用途。使用本项目所产生的一切后果（包括但不限于账号封禁、数据丢失等）由使用者自行承担，项目作者概不负责。请遵守番茄小说的用户协议和相关法律法规。",
    ["Pre-download next %1 chapters"] = "预下载下 %1 章",
    ["Pre-download enabled"] = "已启用预下载",
    ["Pre-download disabled"] = "未启用预下载",
    ["Pre-download chapter count"] = "预下载章节数",
}

function I18n.language()
    local lang
    -- Use pcall to safely access G_reader_settings (may not exist in all KOReader versions)
    local ok, result = pcall(function()
        if G_reader_settings and G_reader_settings.readSetting then
            return G_reader_settings:readSetting("language")
        end
        return nil
    end)
    if ok and result then
        lang = result
    end
    -- Also try reading from KOReader module
    if not lang then
        ok, result = pcall(function()
            local KOReader = require("koreader")
            return KOReader.readSetting and KOReader:readSetting("language")
        end)
        if ok and result then
            lang = result
        end
    end
    return lang or "en"
end

function I18n.is_zh()
    return tostring(I18n.language()):lower():match("^zh") ~= nil
end

function I18n.tr(text)
    if I18n.is_zh() then
        return zh[text] or text
    end
    return text
end

return I18n