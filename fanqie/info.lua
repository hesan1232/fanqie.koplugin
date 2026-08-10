-- 插件元信息集中管理：版本号、描述、关于文案
-- 所有需要展示版本/关于的地方统一从这里读取，避免多处维护不同步。
--   - main.lua: require("fanqie.info") 读取 version 和 about_template
--   - _meta.lua: pcall(require, "fanqie.info") 读取 version 和 description
--
-- about_template 用 T() 格式化，占位符：
--   %1 = 版本号（self.version）
--   %2 = 缓存目录（self.settings:get_download_dir()）

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

return {
    -- 版本号（唯一来源，main.lua 和 _meta.lua 都读这里）
    version = "2.2.0",

    -- 插件描述（_meta.lua 的 description 字段使用）
    description = _("在 KOReader 中阅读番茄小说，支持扫码登录、多书源、段评、两层智能缓存、进度同步，适配墨水屏黑白显示。"),

    -- 关于文案模板：main.lua 两处「关于」对话框共用
    -- 修改文案只需改这一处，两处关于对话框自动同步
    about_template = _("番茄小说插件 v%1\n\n为 KOReader 打造的墨水屏阅读体验，适配黑白电子墨水屏。\n\n核心特性:\n• 扫码登录: 番茄网页扫码，自动获取书架/进度/目录\n• 多书源聚合: 晴天 / 大灰狼 / 番茄官方，自动故障切换\n• 段评功能: 章节段落评论，开关常驻设置页，墨水屏黑白适配\n• 异步引擎: 目录获取/章节下载/进度上传/登录检测均在子进程执行，UI 零卡顿\n• 限流保护: 滑动时间窗口算法，防止书源服务器封禁\n• 两层缓存: 书架/目录采用内存主源+文件后备策略，显示层零文件IO\n• 静默刷新: 进入阅读自动更新目录，后台刷新书架不闪烁\n• 智能回退: 网络失败保留旧缓存，Cookie过期不丢失数据\n• 预下载: 阅读时后台自动下载后续章节\n• 进度同步: 进入阅读自动拉取云端进度，阅读中定期上传\n• 书源管理: 启用/禁用、限流配置、线路检测\n\n下载格式: HTML\n缓存目录: %2"),
}
