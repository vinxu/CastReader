# iOS 1.2.37（58）发布范围与验证

用户授权：将今天的 Kindle 适配、Bug 修复及进度相关改动一起打包并提交 App Store 审核。

## 发布源

使用本任务连续开发并安装到真机的工作副本 `codex/reading-resume-real-libraries-20260909`。包含线上 1.2.36 基线之后的 `33cf70a` Kindle 播放/高亮/界面稳定修复、`7d15e3a` 统一内容目录与进度恢复，以及其后的本地文档缓存、Kindle 翻页朗读所有权和手动位置修复。主目录有其他独立开发中的改动，未直接对其工作文件做覆盖。

本次功能：

- 统一内容目录、独立朗读记录和统一打开入口；首页、文库、提醒及系统入口使用内容 ID 查询最新进度。
- 长篇 EPUB/PDF/文本/网页/照片 OCR/字幕及连接书架恢复流程；首页“继续”右侧“查看全部”。
- 已解析 PDF/EPUB 的本地缓存及预计算恢复索引，降低再次打开延迟。
- Kindle 预加载、句尾/复合词高亮、解读标注与阅读界面修复。
- Kindle 冷恢复后翻页的播放所有权修复。
- Kindle 暂停手动翻页保存；Yes/No 尊重用户选择，旧记录失配不阻止播放；延迟及快速滑动确认最新画面。

不包含其他工作副本的克隆语音对齐诊断开关和尚未完成的实验。`WebReader/node_modules` 不纳入发布源提交。

## 版本选择与商店资料

App Store Connect 初始状态：1.2.36 READY_FOR_SALE，最大上传 Build 57，无活跃审核单；因此使用 1.2.37 / 58。
App、Share Extension、Widget 的 Debug/Release 版本保持一致。预检通过，Safari 未完成扩展不在 release targets 中。

11 语只更新 What's New，保留当前在线名称、副标题、描述、关键词、推广文案、链接与截图。当前 9 个语言各有 5 张截图；zh-Hant 与 es-MX 使用主语言回退。保留当前审核后自动发布方式。

## 回归检查发现与修正

- `testSystemContinueSelectionNeverSubstitutesForStaleExplicitID` 的旧断言把 Kindle 一律排除；统一目录已经支持 Kindle。改为验证指定 Kindle ID 正常路由，并新增删除该 ID 后不能误开其他内容的断言。
- `testKoboLaggingProviderBookmarkFindsSavedPageBeforeLoadingVM` 原来比较传入的原始 checkpoint；保存操作现在会补充 activity/revision。改为先回读持久化后的完整 checkpoint，并断言等待与找到目标页前后整条记录不变，同时验证初始 listenedSeconds=0、revision=1。未放宽页面或进度恢复断言。

- 完整翻译校验发现缺少“收听状态”及“正在恢复朗读位置…”的意大利语、巴西葡萄牙语；已补齐九语。原始全量单测 1580 项，7 项 opt-in 跳过，4 个测试方法产生 5 条失败断言；失败日志保留，修正后重跑目标测试和受影响完整测试组。

最终测试、归档、上传和审核回执在发布完成后补充。
