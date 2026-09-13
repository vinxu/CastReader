# iOS 1.2.39（60）发布记录

已于 2026-09-14 00:30:33（Asia/Shanghai）提交 App Store 审核。版本和审核单均为 `WAITING_FOR_REVIEW`；沿用审核通过后自动发布。

## 来源与范围

- 用户授权：合并 `codex/ao3-reader-recovery-20260913` 到离线功能分支，完成打包前审查并提交 App Store。
- 工作树：`/Users/xuxuheng/Documents/.worktrees/CastReader-kindle-offline-five-phases-20260912`。
- AO3 来源提交：`11f331e`；合并提交：`d58e296`；最终应用源码：`64c2dbd934d34e7b000c8def1a4c8ee5dc94ab23`。
- 包含已验证的 `b6dd4d7` 祖先及 1.2.38 集成快照 `5f863c4`；未使用主目录旧分支源码替换发布子系统。
- 本次交付整本 Kindle 离线图片保存、本机封面、按需端上 OCR 与系统朗读、变速与中日文句子高亮、持久迷你播放器、设置入口及九种界面语言。
- 合入 AO3 网站提示后的正文恢复、章节切换与旧消息隔离。通用网页脚本保持不变，AO3 专用脚本与独立分支已验证产物完全一致。
- 发布前全量测试发现通用“离线”状态缺少七种语言，已补齐；删除已停用且指向旧文库入口的提示文案。

## 当前状态

合并、修复、回归、归档、上传、构建处理、商店资料审计及正式送审均已完成。最终归档包含自动翻页间隙的暂停修复；离线完整链路 25 项、设置与睡眠定时 8 项 UI 回归全部通过，无遗留测试失败。Xcode 于 2026-09-14 00:18:08（Asia/Shanghai）确认上传成功，零警告；上传记录已为 `COMPLETE`，Build 为 `VALID / APP_STORE_ELIGIBLE`。

- App Store 初始状态：1.2.38 `READY_FOR_SALE`，最高 Build 59，无活动审核提交。
- 新版本：1.2.39 / Build 60。
- Build ID / 上传记录 ID：`67c9e63f-f4d5-417f-9d96-297fb92c33fc`，已绑定准确版本，出口加密声明为 `false`。
- 待审版本 ID：`97b00cc5-b9eb-4bcf-9425-78e1faffc8c3`。
- 审核单 ID：`d9065521-1b02-4bc9-9825-54e8871ab7e9`；只有本次版本一个审核项，无无关项。
- 版本状态 / 审核单状态：`WAITING_FOR_REVIEW` / `WAITING_FOR_REVIEW`。
- Apple 提交时间：`2026-09-13T16:30:33.297Z`，即北京时间 2026-09-14 00:30:33。
- 待审 App Info ID：`a55cc93e-30b0-4f98-86e1-c778d1ec47b1`。
- 基线版本 ID：`cc42d487-9da6-49e5-b36d-357c6c94f4ca`；基线 App Info ID：`057ada58-395d-44c7-93f4-eda9f682a11c`。
- 发布方式：沿用 `AFTER_APPROVAL`，审核通过后自动发布；当前仍在等待审核，尚未上线。

## 已完成验证

- 首轮全量单元测试 1701 项：1693 通过、1 处文案缺失失败、7 跳过。修正后失败项单独复验通过；受影响完整 `LocalizationCatalogTests` 的 50 项全部通过，未跳过或放宽断言。
- 合并后的 AO3 7 项全部通过，包含延迟/隐藏网站提示、恢复与重复段落、换章及错误页、DOM 重建、缓存返回和消息地址校验。
- 七项既有跳过：三项 StoreKitTest 在当前 XCTest host 中 `notEntitled`；四项需手动开启的在线解读、Google Play Books、服务线路和 YouTube 测试。本次未修改支付实现，不将这些跳过表述为线上支付或真机验收完成。
- 编译后离线文案：186 个键 × 9 种界面语言通过；另核对 AO3 两条提示及通用“离线”状态在九种编译资源中存在。
- 正式归档 123 个文件扫描 50 个调试/测试标记，无命中，Debug 对照检查通过；未包含 Safari 扩展。
- 主 App、Share Extension、Widget 均为 1.2.39（60），最低 iOS 17.6；归档完整性与签名验证通过。归档本身使用开发签名；已另从本次 Xcode 上传管线保留最终 IPA，并确认三个组件均为 Apple Distribution 签名、`get-task-allow=false`，深度/严格签名验证通过，不是开发、Ad Hoc 或企业分发包。
- 归档后核对 308 个源码与资源文件，散列全部一致。后续提交 `e7b72bc` 仅修正 UI 测试中延迟创建控件的滚动步骤，不改变打包源码。
- 商店标题、副标题、描述、关键词、宣传文字、支持/营销与隐私链接均与 1.2.38 一致；11 种更新说明逐项回读一致。
- 审核联系人及无需演示账号设置保持不变；追加离线功能入口/前台保存要求与 AO3 修复的审核操作说明，回读一致。
- 四个中英文隐私政策/条款链接均最终返回 HTTP 200，未修改声明。
- 内容权利声明回读仍为 `USES_THIRD_PARTY_CONTENT`，与基线相同。
- 英文五张继承截图均 `COMPLETE`，校验和匹配仓库素材；人工查看既有截图内容与本次保留的功能一致。已核对九个地区各五张 `APP_IPHONE_67` 截图全部完成，共 45 张；`zh-Hant`、`es-MX` 沿用英语主地区截图。

## 界面回归中的修正

- 自动翻页把系统朗读短暂切为 finished/idle，原按钮也随页面加载禁用。现在以持续播放意图保持暂停可用，阅读器与迷你播放器共用同一条件；用户暂停立即撤销已排队的翻页。
- 针对该边界的单元复验通过；随后 AO3、离线阅读模型、系统朗读与睡眠定时共 52 项全部通过。变速、暂停、收起和重开的界面专项也通过。
- 小屏测试脚本修正：按实际位置双向滚动开关；最大辅助字号下，超过一屏的长说明分别验证首尾可完整滚动阅读；切换定时类型后滚动到新增的开始按钮。保留全文与可见性断言，不缩小用户字号，不隐藏内容。
- 最终离线完整套件 25 项全部通过：整本保存、失败/取消后继续、端上 OCR 和系统朗读、中日文句子高亮、九语界面、变速与暂停、收起/恢复、重启断点以及高长页面和大字号显示。
- iPhone SE 小屏九语最大辅助字号专项通过；变速与暂停、六组长说明、九语定时专项亦通过。最终完整设置与定时套件 8 项全部通过、零跳过，覆盖九语浅深色、最大辅助字号、长说明、语言错配菜单、定时到期与断点恢复、后台到期。
- 原先两份候选归档均已隔离，最终只允许上传包含暂停修复的新归档。

## 归档与证据

- 正式归档：`build/CastReader-1.2.39-60.xcarchive`。
- 独立 DerivedData：`/tmp/CastReader1239ArchiveDerivedData`。
- 正式归档日志：`/tmp/CastReader-1.2.39-60-archive-pause-fix.log`。
- 最终分发 IPA：`build/CastReader-1.2.39-60-AppStore.ipa`，40,388,141 字节；SHA-256：`b60a0fe73caa7c9da822466a6ca6c4d8a803e8435b2e69c01bb2c1d7c6ac1343`。
- 上传日志：`/tmp/CastReader-1.2.39-60-upload.log`。IPA 中 AO3 / 通用网页脚本与审计归档逐字节一致。
- 接口差异：当前 API key 读取 `buildUploads` 集合返回 HTTP 403，但从本次 Xcode 上传回执得到 ID 后，单条 `GET /v1/buildUploads/67c9e63f-f4d5-417f-9d96-297fb92c33fc` 可正常读取。最终已同时确认上传记录 `COMPLETE`（无错误、警告）和 Build `VALID / APP_STORE_ELIGIBLE`，未修改账号权限。处理方式已补入发布 SOP。
- 修正前归档已隔离为 `build/CastReader-1.2.39-60-before-localization-fix.xcarchive`，不得上传。
- 全量测试：`/tmp/CastReader-1.2.39-60-unit.xcresult`；修复复验：`/tmp/CastReader-1.2.39-localization-targeted.xcresult` 和 `/tmp/CastReader-1.2.39-localization-suite.xcresult`。
- 首轮界面测试：`/tmp/CastReader-1.2.39-ui.xcresult`；最终离线套件：`/tmp/CastReader-1.2.39-offline-final.xcresult`；大字号复验：`/tmp/CastReader-1.2.39-large-targeted.xcresult`；最终设置/定时：`/tmp/CastReader-1.2.39-settings-timer-final.xcresult`。
- 精确源码清单、归档字段与散列、版本创建、文案/调试隔离、测试摘要和商店回读证据：`reports/ios-release-1.2.39/`。
- 送审证据：`review-dry-run.json`、`review-submission.json`、`asc-audit-before.json`、`asc-audit-after.json`；分发与构建证据：`distribution-verification.json`、`upload-result.json`、`build-upload-complete.json`、`build-processing.json`、`build-attachment.json`（均在上述证据目录）。
- 本轮不覆盖用户手机安装、不清理账号或本机图书；模拟器结果不作为本轮真机验收声明。
