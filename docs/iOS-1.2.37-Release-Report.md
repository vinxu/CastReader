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

## 已完成的发布检查

- 单元检查：原始全量 1580 项。四个失败方法修正后，4 项目标复测、147 项受影响完整测试组（1 跳过）均无失败。合并结果 1573 项通过、7 项原有 opt-in 跳过、0 遗留失败。
- Release 归档签名与版本核验通过，三个产品均为 1.2.37 / 58；最低 iOS 17.6；非豁免加密声明 false。归档是开发签名，Xcode 官方 App Store export/upload 流程执行分发重签名。
- 正式包扫描通过：34 项书架测试标记和额外的进度测试启动标记均未出现在 Release 包；Debug 正对照有效。
- Xcode 上传成功；Build `609387b6-78b6-4ad2-bb93-9eede523e476` 达到 VALID / APP_STORE_ELIGIBLE。
- 商店版本 `e7f30c6a-f42a-4702-9a7f-8525577e00f8`，待提交 App Info `533af389-b786-4148-8dd0-239ea489b1bd`。
- 11 语 What's New 写入且逐字回读一致。App Info、其他版本文案、45 张截图保持不变，2 个地区使用主语言截图回退。
- 审核资料与当前内容版权声明保留；预审计无错误；正式提交 dry-run 已通过。
- 完整界面回归：101 项，84 通过、17 项原有 opt-in 跳过、0 失败；xcodebuild TEST SUCCEEDED，xcresult 独立汇总 Passed。百章 EPUB、各类长篇内容、后台/旋转/迷你播放器/冷启动，以及首页/文库/通知恢复最新停止点均通过。
- 已正式提交审核，版本与审核单均回读为 WAITING_FOR_REVIEW。

## 验证范围与保留限制

- 单元检查中的 7 项原有 opt-in/live 测试未启用；此次未借跳过测试绕开失败。界面测试中的账号依赖场景同样按现有 opt-in 条件执行，最终跳过清单保留在 UI 结果中。
- 实机 Kindle 的 Yes/No、暂停上一页/下一页、退出与冷启动后播放已在本次开发周期验证。物理手指横向滑动未通过镜像工具复测；延迟和连续反向滑动用真实 WKWebView 事件及原生消息链验证。
- 不将本次发布回归表述为所有平台、所有真实账号和所有网络条件已穷尽验证；保留具体测试和实机证据边界。
- 非阻断商店情况：推广文案原本为空，保持原样；zh-Hant、es-MX 截图沿用主语言回退。价格、订阅、地区、隐私、年龄分级及法律声明未调整。

## 归档与证据路径

- 发布源 commit：`b6dd4d7`。
- Archive：`/Users/xuxuheng/Documents/.worktrees/CastReader-reading-resume-real-libraries-20260909/build/CastReader-1.2.37-58.xcarchive`。
- 完整发布回执：`/Users/xuxuheng/Documents/CastReader/reports/ios-release-1.2.37-20260910`。
- 单元结果：`/tmp/CastReader-1.2.37-Unit-Tests.xcresult`；补充回归：`/tmp/CastReader-1.2.37-Affected-Suites.xcresult`。
- 完整界面结果：`/tmp/CastReader-1.2.37-UI-Tests.xcresult`。

## 正式提交回执

- 版本：1.2.37 / Build 58，处理状态 VALID / APP_STORE_ELIGIBLE。
- Version ID：`e7f30c6a-f42a-4702-9a7f-8525577e00f8`。
- Review Submission ID：`1892139e-5041-4c14-a56a-91e06822759b`。
- 提交时间：2026-09-10 01:55:53（Asia/Shanghai）；API 原值 `2026-09-09T17:55:53.655Z`。
- 审核单状态：`WAITING_FOR_REVIEW`；版本状态：`WAITING_FOR_REVIEW`。审核单包含且仅包含本次 1.2.37 版本。
- 发布方式：`AFTER_APPROVAL`，审核通过后自动发布；当前尚未上线。
- 提交后独立审计 `audit-after-review.json`：0 错误；版本仍为 WAITING_FOR_REVIEW，Build 58 为 VALID；名称保留检查通过，11 语资料、截图及审核资料可读。
- 原始回执：`review-submitted.json`。完整单元初次失败、修复后目标与整组回归、完整 UI 结果均独立保留，没有覆盖失败证据。
