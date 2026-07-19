# fanqie.koplugin

KOReader 插件，用于在电纸书设备上阅读番茄小说。

## 功能特性

- 📚 书架管理：浏览和搜索番茄小说
- 📖 章节阅读：支持章节导航和自动翻页
- 🔄 进度同步：自动同步阅读进度到服务器
- ⚡ 预下载：智能预下载后续章节
- 🎨 界面优化：适配墨水屏显示

## 安装方法

1. 下载插件压缩包
2. 将 `fanqie.koplugin` 文件夹复制到 KOReader 的 `plugins/` 目录
3. 重启 KOReader
4. 在菜单中找到「番茄书架」入口

## Cookie 获取方式

### 方法一：浏览器开发者工具

1. 打开浏览器（推荐 Chrome 或 Edge）
2. 访问 [番茄小说网页版](https://fanqie.com)
3. 登录你的账号
4. 按下 `F12` 打开开发者工具
5. 切换到「Application」（应用程序）标签页
6. 在左侧选择「Cookies」→ `https://fanqie.com`
7. 找到以下 Cookie 值并复制：
   - `sessionid`
   - `csrfmiddlewaretoken`
8. 将复制的 Cookie 字符串粘贴到插件配置中

### 方法二：浏览器扩展

安装 Cookie 导出插件（如「EditThisCookie」），一键导出 Cookie 字符串。

### 配置方法

在 `config.lua` 文件中配置 Cookie：

```lua
local Config = {
    cookie_string = "sessionid=xxx; csrfmiddlewaretoken=xxx; ...",
}
```

## ⚠️ 重要声明

### 接口说明

本插件使用的正文获取接口为第三方公开接口，**非官方 API**。

### 使用规范

1. **请勿一次性下载全本书**：插件默认仅预下载 5 章，请保持此设置
2. **请勿滥用接口**：频繁请求可能导致 IP 被封禁
3. **请合理阅读**：建议每天阅读时长不超过 2 小时，保护视力

### 免责声明

本插件仅供**技术分享和学习研究**目的使用：

- 本插件不提供任何小说内容，所有内容均来自公开网络
- 用户使用本插件产生的一切后果由用户自行承担
- 请尊重版权，支持正版阅读
- 如涉及侵权，请联系作者删除

## 技术说明

- 基于 Lua 语言开发，适配 KOReader 环境
- 使用 REST API 获取数据
- 本地缓存机制，减少网络请求

## 许可证

MIT License
