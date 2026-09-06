# iOS 1.2.35（55）播放器恢复发行交接

## 交付状态

- 归档、发行检查、Xcode 官方上传及 Apple 处理均完成：build55 为 **VALID / APP_STORE_ELIGIBLE**，非豁免加密声明为 false。
- Build ID：`e275d303-958c-430d-8fc8-39a6b4c35c10`。Xcode 上传完成于北京时间 2026-09-07 01:03:38；App Store Connect 记录 uploadedDate 为北京时间 01:04:43（API 原值 `2026-09-06T10:04:43-07:00`）。
- 归档：`build/CastReader-1.2.35-55.xcarchive`。
- 工作树：`/Users/xuxuheng/Documents/.worktrees/CastReader-ios-audio-recovery-release-1.2.35`。
- 归档源码提交：`b234463af4e7c4413172778df88538b581be0e52`。
- 本次边界是上传可审核产物。现有 1.2.34/build54 的审核不撤回，不修改 App Info、标题、副标题、releaseType 或其他商店元数据。
- 上传后回读：1.2.34 版本 `1db5a12c-64cd-4961-ad04-4ff117646723` 和 Review Submission `59fab953-41d1-4cd3-94f7-3221822b70f8` 均仍为 **WAITING_FOR_REVIEW**，发布方式仍为 **AFTER_APPROVAL**。Apple 当前不允许创建 1.2.35 App Store 版本；有效 build55 保留供发行协调使用。

## 基线与改动

从正式 1.2.34 完整发行基线 `578bd91` 追加 `20bc640`（原 `47f9541` Kindle 模式切换所有权保护）和 `a8954ca`（原 `b0b9dc1` 播放器恢复）。三项 target 的 Debug/Release 版本统一为 1.2.35/build55，提交 `b234463`。Kobo、Google Play Books、线路和本地化等原发行改动保留。

1.2.34/build54 已包含 `09dcb64` 普通 TTS 容错与 `814030a` Kindle 翻页后恢复；不能把这两项描述为本次首次进入审核版本。

本次播放器在本地技术失败后，用已经取得的同一段音频字节重建一次文件和 AVPlayer，恢复同一段内位置，保留队列和所有权，遵守暂停意图。预算耗尽后终止，不重用 failed item；旧生产者回调不能覆盖失败状态。写文件失败返回真实失败结果。没有增加时间戳/高亮硬门槛、跨区域/跨音色切换或无界重试。

## 验证

- 完整发行基线：40 个受影响单元测试全部通过，0 失败、0 跳过。包括 7 个新增真实 AVPlayer/文件恢复与竞态测试、6 个播放所有权测试、25 个产品遥测测试、队列已耗尽回归和 Kindle 翻页证据契约。
- 阅读模式切换 UI 检查：1 个通过，0 失败、0 跳过。
- 这是本次受影响回归；没有把上一版的完整单元/UI 套件或实网测试重复计为本次执行。上一版完整结果见 `docs/iOS-1.2.34-Release-Report.md`。
- Release archive 成功；三项 bundle 均为 1.2.35/build55、最低 iOS 17.6，签名有效，entitlements 与上一版归档一致。Xcode 在 archive 阶段使用开发签名，再由官方 App Store export 流程重新发行签名。
- 251 个源码/工程文件在测试后、归档前后的 SHA-256 一致；本地构建配置与上一版发行配置一致。
- 上传后再次核对：251 个源码/工程文件及归档内 128 个应用、扩展、符号等文件均未变化；只有归档根 Info.plist 被 Xcode 正常补写上传成功记录，另有独立审计保存该变化。
- 正式 app 119 个文件、30 类模拟书架/测试标记零匹配，Debug 正控成功检出 Google/Kobo 模拟书；正式编译没有 DEBUG 条件或内部发行开关。
- 非豁免加密声明为 false；11 语种更新说明本地预检通过。
- 本次未写入新版本商店资料、未新增截图或绑定审核。11 语种文案已保存为 `docs/AppStore-Whats-New-1.2.35.json`；标题、副标题及截图等后续沿用政策由发行协调继续执行，当前 1.2.34 资料保持原样。

证据保存在 `reports/ios-release-1.2.35-55/`：`IntegrationUnit.xcresult`、`ReaderModeUI.xcresult`、单元/UI 摘要、`preflight.txt`、`archive-audit.json`、`no-shelf-fixtures.json`、源码和归档文件哈希，以及 archive/export 日志。原始大型构建与测试产物仅本地保留。

## 归因与监控边界

两次 build53 `player_item_failed` 缺少原始 NSError 和失败音频字节，本次修复已确认的客户端恢复缺陷，没有声称已还原两次现场触发因素。跨日 EPUB 会话始于后端此次部署之前，没有失败段请求时间/身份来证明它由部署后的模型产生。新增 Kindle `page_turn_failed` 累计 3243 秒也不能确定具体导航分支。

build55 的 `read_first_audio` 需 AVPlayer 实际连续推进；应按 build 分组比较延迟，旧版的该指标可能仅表示准备播放。

远端终止事件仍使用原 schema，错误码细分 `file_write_failed`、`player_status_failed`、`player_end_failed`、`player_ready_timeout`、`player_resume_failed`，附安全 NSError 域别名和 n/p 编码的数字错误码，严格符合 `[a-z0-9_]{1,64}`。最多 48 条丰富诊断只保存在本地 Application Support，不上传正文、音频、URL、原始身份、NSError 文案或任意 userInfo。

非阻塞限制：Xcode 报告现有代码的弃用 API、Swift 6 迁移及 AppIntents 元数据提示；归档无错误。没有新增物理 iPhone 或已登录 Kindle 实网播放验证。
