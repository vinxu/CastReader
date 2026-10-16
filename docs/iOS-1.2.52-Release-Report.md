# iOS 1.2.52（89）Kindle 修复发布记录

**已完成：旧 1.2.52（87）撤回，1.2.52（89）重新提交；版本和审核单均为 WAITING_FOR_REVIEW。** 提交时间：北京时间 2026-10-16 12:10:22，12:10:56 独立回读确认。

## 源码与范围

- 合并主线：`e43dc1ea54480619fa0d7c847f0daf4c27b7680f`，PR https://github.com/vinxu/CastReader/pull/13 。
- 真机验收候选：`f6ccd3ead85b36a8d7e65a4b55703ab5a35e7c03`；合并后的应用、资源及配置逐文件 SHA-256 与候选一致。
- 基线：1.2.52（87），应用功能与已验收 1.2.51（86）一致；保留当前 main 的 Mac 1.2.51（88）配置。
- 修复 Amazon 登录页的受信隐私/帮助链接误判：明确点击的同站点链接在外部浏览器打开，保留登录表单与 cookies，不扩大 WebView 域名白名单。
- 网络和 WebContent 失败显示可重试状态，停止过期自动探测；显式重试启动新绑定/朗读分析会话。
- 生产 `navigation_blocked` 事件未记录目的 URL，不能断定所有线上事件都是隐私链接造成；通用 `tts_failed` 根因也未被本轮全部解释。

## 真机与模拟器验收

真机为 iPhone 15 Pro Max / iOS 26.7.1，安装正常 Release 1.2.52（89）开发签名包，未跳过 App 登录、未注入假书架或录制音频。

保留手机既有 Amazon US 登录态及阅读位置，重新进入连接同步页，书架由 23 本更新至 **29 本**。打开真实《A Journey to the Centre of the Earth》，使用 Emma `bf_emma`、用户原有 1.5× 速度，完成 **30 段、131.592 秒音频内容**（为已结束片段累计，不等于墙钟时间）。逐词高亮、自动跨页、暂停保持、继续播放通过，最后暂停在当前阅读位置。

真机本轮没有退出账号重新输入密码；真实新登录、Privacy Notice 打开外部 Safari 后返回原登录页、29 本同步及开书朗读已在同一应用修复源码的模拟器验证。模拟器使用隔离 DEBUG 账号范围，不能把它称作 CastReader 社交登录验收。

证据：`reports/ios-release-1.2.52-kindle/device-flow.json`、三张真机截图，以及前序 `reports/kindle-bind-recovery-20261016/verification.json` / `real-account-validation.json`。原始真机日志保存在本地 private 目录，不提交账号或阅读内容。

## 核心服务证据复用

按发布 SOP 的受影响范围复测规则，TTS、QuickRead、音频播放器、生成、鉴权、额度与区域路由未改；Read VM 只新增显式重试前的分析会话恢复，确定性失败重试回归已通过。本轮新增真机 Kindle 绑定/同步到常规音色朗读验证；**没有宣称重新跑了一遍全部音色矩阵**。

| 地区 / 语言 | Read 常规 | Read 社区 / 私人 | Explain 常规 | Explain 社区 / 私人 |
| --- | --- | --- | --- | --- |
| Global / English | PASS，复用；本轮 Emma 真机补验 | PASS / PASS，复用 | PASS，复用 | PASS / PASS，复用 |
| CN / 中文 | PASS，复用 | PASS / PASS，复用 | PASS，复用 | PASS / PASS，复用 |

社区音色 `vl_3553117ace9560c74c4a`；Global 私人 `vc_9d60f868d880442aac1f74e8053d5ef8`，CN 私人 `vc_63a448ca35794f57b0aea0e189a68cb3`；常规 CN `zf_001`。沿用 2026-10-15 真机新讲解、原文标注、连续播放、切换、额度证据，来源：`/Users/xuxuheng/.codex/worktrees/ios-bounded-preloading/CastReader/reports/mobile-release-20261015/RELEASE-REPORT.md`。原证据为 Debug 真机包；本轮是正常 Release 包受影响流程补验。任务未改后端，独立后端部署指纹仍未知。

## 自动化及打包

- 完整候选一次单测：**2330 项，2306 PASS / 23 SKIP / 1 FAIL**。唯一失败用例为既有 NativeLanguageAuditTests 印尼语/马来语阈值（两条断言），未放宽阈值；Xcode 结束码 65，不能称为全绿。PaymentTests 明确排除，未操作真实交易。
- KindleStorefront、ProductAnalytics、ReadingResume、ReadAloudContinuation、音频队列所有权和暂停意图相关套件通过。
- 祖先校验、Safari 包装、六份本地化词库检查通过；真机包 4 个组件均 1.2.52（89），29 个编译资源语言，54 个 fixture 标记扫描无命中。
- 归档：`build/CastReader-1.2.52-89.xcarchive`（已成功）。

## App Store 操作

- 原 1.2.52（87）已于北京时间 **2026-10-16 11:27:15** 撤回，版本读回 `DEVELOPER_REJECTED`，原 Review Submission 为 `COMPLETE`。
- 同一个版本 ID：`be73457d-4cfd-4e86-a165-5f0f49aa98f0`。
- 当前商店快照为 29 个 locale、522 个截图/视频素材位置，计划保持文案、标题、副标题、现有图片、审核资料及 AFTER_APPROVAL 行为。
- 新构建于北京时间 **2026-10-16 11:57:27** 官方 Xcode 上传成功。实际上传 IPA 113084199 bytes，SHA-256 `f92c17603ae05a3c85741dd0d938c18eba8bf173c17f0f9485888c352bc78295`。已保存同一文件，四组件分发签名与 `get-task-allow=false` 通过。
- 商店保留检查通过：**514 张图片 / 8 段视频，共 522 个素材位置**；顺序、文案和审核资料与撤回前快照相同，所有图片/视频及视频封面处理状态合格。
- Build `50400de5-fbb5-4a94-af50-eac8dc984fcc` 为 **VALID / APP_STORE_ELIGIBLE**，已绑定回原 1.2.52。
- 新审核单 `636625fd-da28-4d97-a29d-135a3e56c424` 于北京时间 **2026-10-16 12:10:22** 提交，仅包含本 iOS 版本；版本与审核单均 **WAITING_FOR_REVIEW**。
- 发布方式保持 **AFTER_APPROVAL（审核通过后自动发布）**；没有改动 Mac 审核、价格、订阅、地区、隐私或法律声明。
- 29-locale release audit 与 ASO 检查通过，标题/副标题完全保留。`final-readback.json` 为独立回读结果；本地证据目录 `reports/ios-release-1.2.52-kindle/`，含 archive/distribution verification、core-evidence、unit-summary、store-preservation 与提交回执。原始 private 日志、完整 xcresult、安装包与个人书架截图保留本地，不提交 Git。
