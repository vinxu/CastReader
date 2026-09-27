# AO3 账户书架与章节播放集成

日期：2026-09-27。范围：仅 iOS AO3；不实现 Wattpad，不提交 App Store。
基线：main `9eb758b`（包含 iOS 1.2.46 / 69 源码 `3051b15`）。
工作树：`/Users/xuxuheng/.codex/worktrees/ao3-wattpad-library/CastReader`。

## 用户流程

首页 → 书架来源 → AO3 → AO3 官方登录页 → 识别登录身份 → 分页同步阅读历史 → 首页作品卡片 → 朗读 / 解读。

AO3 History 代表访问过的作品，不提供 Kindle 式精确阅读光标。CastReader 单独保存当前章节、段落和原文锚点；重新同步元数据保留本地收听位置。没有 AO3 账号的用户仍可使用现有网页链接入口阅读公开作品；账户书架需要真实 AO3 账号。

## 实现

- `AO3Models`：限定 HTTPS 官方域名、作品和章节 URL、账号身份、作品稳定 ID 与本地位置。
- `AO3LibraryStore`：CastReader 账号隔离、AO3 账号隔离、部分同步不删除旧作品、完整同步保留位置、解绑拒绝迟到结果。
- `AO3ConnectionModel`：直接在 account-scoped WKWebsiteDataStore 登录；不收集密码、Cookie 或上游 token。识别身份后进入 History，最多同步最近 25 页，达到上限时保留旧书架并明确提示。
- `AO3HomeSection / AO3LibraryView`：首页最近作品、搜索、重新同步、统一播放器入口。
- AO3 JavaScript adapter：从官网章节导航识别同作品上一章 / 下一章；向原有正文桥附带账号身份和章节信息；继续排除条款、评论、摘要和作者备注。
- `AO3ChapterPreloader`：只在同一 WebKit 资料中准备相邻下一章，不自动接受提示、不把下一章显示为当前章、不持久化正文。
- `WebReaderBridge`：自动换章、手动换章取代在途自动换章、旧音频和标注作废、首段 TTS 及首个讲解块预加载、实际落页后核对内容和设置再使用缓存。
- 复用现有 Read / Explain 的音色、额度、共享播放器所有权、词级高亮、自动滚动、重播与解释标注。
- 新文案提供中文及英文。

## 有界预加载

每次仅准备一个相邻章节。正文上限为 5,000 段 / 300,000 UTF-16 字符；超出时回到正常加载。朗读在当前章最后两段播放时准备下一章首段，首段上限 2,000 UTF-16 字符。解读预加载沿用现有 Pro 门禁，仅对 32,000 字符以内的相邻章准备首块；超出时正文仍可正常打开并走原解读管线。预加载失败不影响当前章。

## 验证

218 个不同 XCTest 方法最近一次结果通过（AO3 21 项、埋点 25 项、其他相关回归 172 项），另有 2 项来源页 UI 检查通过。范围、复测及未验收项详见 [测试记录](../reports/ao3-library-20260927/verification.md)。

- 真实 WKWebView 正文提取、提示层、DOM 替换、bfcache。
- 两页登录后 History 扫描至书架提交；私有身份和迟到响应隔离。
- 可控 TTS 传输 + 实际 AVPlayer：自然换章、预加载命中、手动翻页、换章中暂停、当前章重播。
- 可控 QuickRead 传输 + 实际 Explain VM / AVPlayer：预加载、重播、换章内容替换。
- 现有共享播放器、恢复、账号与其他书架的相关回归。

## 真实站点验收限制

本环境的浏览器工具明确拒绝访问 AO3，结束了该站点操作；未尝试绕过该限制。用户还没有可用 AO3 账号。模拟测试不能证明真实账户绑定成功，也不能证明线上风控、登录失效、真实付费语音接口或云端解读延迟的表现。本次不将这些环节标为已验收，不因模拟测试通过而发布。

用户允许使用 Gmail 授权；AO3 并非 Google OAuth 登录。AO3 需要邀请链接创建独立账号，可在官方邀请队列登记邮箱，或使用已有用户提供的剩余邀请。开发阶段没有创建账号、填写密码或接受条款。

## 结构证据

按 AO3 开源站点模板实现可见页面解析：
- https://github.com/otwcode/otwarchive/blob/master/app/views/readings/index.html.erb
- https://github.com/otwcode/otwarchive/blob/master/app/views/readings/_reading_blurb.html.erb
- https://github.com/otwcode/otwarchive/blob/master/app/views/users/sessions/_greeting.html.erb
- https://github.com/otwcode/otwarchive/blob/master/app/views/layouts/application.html.erb

邀请制度参考：https://archive.transformativeworks.org/faq/invitations?language_id=zh-CN
