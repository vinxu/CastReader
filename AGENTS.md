# AGENTS.md

## 1.2.42 已送审与主线整合（2026-09-20）

- 1.2.41（63）已由 App Store Connect 确认为 READY_FOR_SALE。其已发应用源码摘要 `8670be15e6d5e31df8752192c9b694a81f5149c65a22ce2c0eeb429d75f3dd06` 已逐文件重建核对，完整增量固化在 `94499d2`；不得只从旧报告的 `febfeab` 或单独 `9935c6d` 打包。
- 本次统一保留 `9935c6d`（跨页、完整字幕、EPUB 目录、PDF 内存）和正式合并的 `d4e427c`（EPUB 插图、PDF 原页/OCR 坐标）。冲突整合保留新目录解析和每页内存释放；解析缓存版本提升为 4。
- 发布分支 `codex/ios-release-1.2.42` 的应用源码 `1ce1e56` 已推送并同步到远端 `main` 和原集成分支 `codex/mobile-voice-explore-20260914`，包含解读动画结束后的翻页代次修复，以及暂停朗读后明确启动解读的暂停意图修复。今后从最新远端 `main` 建立发布分支，先合并功能再打包；必须执行 `bash scripts/build-voice-toc-integration.sh --check`。脚本检查本批必备祖先，缺任何一项都拒绝继续。
- 1.2.42（64）已于 2026-09-20 15:13:39 +08:00 正式提交，版本及审核单 `c1501e0f-69a3-4238-b58f-2bac9818b971` 均 WAITING_FOR_REVIEW，审核通过自动发布。两区真实朗读/解读核心通过，最终全量 1,837 通过、0 失败、11 跳过；以 `docs/iOS-1.2.42-Release-Report.md` 的实际状态为准。历史安装、额度、审核状态仅在其原时间有效。
- 送审后的 Safari 恢复要求已由用户明确为**仅 Mac Safari**。Mac 扩展使用独立的 `com.castreader.CastReader` 容器与公证安装包；不得为此撤回 iOS 1.2.42（64）、给 iOS 加入未验收的 Safari target，或把 iOS 提交成功当作 Mac 已开放。Mac 的最终源码/验收/签名/下载恢复由 Safari 专项发布记录分别确认。
- 用户进一步明确 iPhone/iPad Safari 尚未做产品适配，**不需要开启**。在用户另行明确要求前，不将移动端 Safari 适配、安装、启用或发布纳入迭代；不把它作为 Mac Safari 发布前置。手机原生 App 功能照常保留，隔离的 Safari 准备分支不合入发布主线。

## App Store 1.2.41 已送审（2026-09-19）

- 本工作树当前 App / Share / Widget 为 **1.2.41（63）**，已于北京时间 00:54:15 提交，版本及 Review Submission 均为 **WAITING_FOR_REVIEW**，审核通过后自动发布；尚不代表已上线。上一版 1.2.40 为 READY_FOR_SALE。
- 最终候选增加保留会话换声归属检查及完成后换声缓存修复；正常开发包 dylib UUID `D99F968F-0D02-3FE8-BBDD-516F69C86B2C`。源码摘要和二进制摘要见 `reports/ios-release-1.2.41/candidate-identity.json`、`device-candidate.json`。
- 最终候选已于 9 月 18 日 23:05 安装确认；此前 19:41 断连失败及同版本修复前包不得作为最终验证。源码/配置 SHA-256 为 `8670be15e6d5e31df8752192c9b694a81f5149c65a22ce2c0eeb429d75f3dd06`，HEAD `febfeab` 加本轮增量，测试后源码未变。
- 相关套件 99 项通过；最终全量 1,778 通过、9 跳过、0 失败。中国/中文与国际/英文的真实朗读、解读 × 常规、社区、私人声音均通过，包含换声和暂停恢复。记录与边界见 `docs/iOS-1.2.41-Release-Report.md`，不因继续任务重复测试未变化候选。
- 归档 `build/CastReader-1.2.41-63.xcarchive`，独立 DerivedData `/tmp/CastReader1241Archive63`。上传 IPA 三个组件分发签名正常、`get-task-allow=false`；九语资源与夹具排除检查通过。Build ID `aa33b7a4-cbc2-4c7d-aa76-a626434af0b8` 为 VALID / APP_STORE_ELIGIBLE；审核单 `f5a6f1f5-9eed-49f4-aa99-da89538a0e0f`。11 语更新说明和 45 张现有截图审计通过。后续从本工作树及报告中的源码摘要继续集成，不从主目录旧基线打包。
- 用户授权重置国际区当前克隆用量并新增中国区 24 小时临时测试权益；后者到 2026-09-19 15:30:23.313Z 自动到期，保留测试产生用量及原有订阅。原国际区账号、中文讲解和曹操音色已恢复。下节旧余额及“最新安装”均为历史测试记录。

## 语音管线延迟优化本地包（2026-09-18）

- **最新安装为 16:25 的 1.2.40（62）开发包**，dylib UUID `879CD501-8239-360F-9770-538301984509`，应用/工程 tracked diff SHA-256 `a5f616168a50e7ab629c71ac433b4ee85eebcbc0809e1c5a30be639a15c345ef`，包含下述短前缀门槛修正。用户重新授权镜像真机验证，取代先前不占用手机的临时安排。
- 16:50–16:52 追加快速翻页专项：下一页连续点 3 次后播放、播放中上一页连续点 3 次、前后交替 6 次均恢复播放；最后一组回到原页走 2.5 秒无页面变化恢复分支。27 条克隆响应全部 200，未复现停播。最后已暂停，服务端日志克隆余额 12 秒；后续不可用此余额做长时克隆测试，也不能把额度耗尽误判为翻页故障。
- 16:25–16:38 实际复测《茶花女》/曹操：全程 9 次自动、2 次手动翻页，127 条克隆响应均 200。单独不干预连续窗口约 5 分钟内 6 次自动翻页，52 次音频衔接中位数 94 ms，最长 1.176 s；未复现停播。暂停后换声跳过 104 字符、仅请求 42 字符，切回曹操缓存命中、无新请求且保持暂停。具体小于 48 字符边界未单独在线复现，不以这些样本替代该边界回归；解读完整标注验收未在这次延长朗读测试中完成。详情见下述报告的第二轮真机记录。
- 14:15 安装到用户 iPhone 的开发包为 **1.2.40（62）**，包含增量预读、换声后缀/缓存、共用有界预读、可验证标注的解读短块。dylib UUID `40ECF280-7C11-3EF7-BB06-CA73D4804A9E`。不是 App Store 更新。
- 已安装应用/工程 tracked diff SHA-256：`549d9502dd533f9a6c34226bdb0a42310795dcb45610712c4919179b8a0409cc`；另含新增 `SpeechStreamBuffer.swift`，SHA-256 `b1e4593a7d714e7cf3af0482b7d013e53b4932e5a2ca6f5bb2d45800cbd2d4b9`。独立 DerivedData 为 `/tmp/CastReaderSpeechDevice20260918`。
- 14:15 包之后移除了换声后缀的 48 字符门槛，保留完整前缀与当前片段校验；先完成模拟器/可控网络验证，16:25 已安装，见上方最新记录。
- 《茶花女》+ 曹操线上段间 158 ms/115 ms，32 条克隆响应均 200；换声仍有 3.413 s/6.008 s 样本，冷恢复约 9 s，不得描述为全面秒播。详细验证、范围与剩余项见 `docs/voice-discovery-2026-09-14/shared-speech-latency-results-2026-09-18.md`。

## 微信读书克隆停播本地修复包（2026-09-18）

- 最近安装到用户 iPhone 的开发包为 **1.2.40（62）**，源码 `febfeab` 加本轮 3 个应用文件补丁，位于当前 `CastReader-mobile-voice-explore-20260914` 工作树。应用 diff SHA-256：`ad16bc7ea776e8e9b4af0f35a7528cce6d2cee3bf200c2da43cab29698293e72`；dylib UUID `A9D28E6D-4059-3288-B7AB-0837154C92FA`。09:51:38 启动。
- 修复跨页克隆请求身份冲突、预读/前台分段身份差异，以及中文换音色拆段后的续读失败。240 项模拟器、11 项真机可控 TTS / AVPlayer 回归通过。10:10–10:15 镜像直接操作《茶花女》+「曹操」：4 次手动翻页、1 次自动翻页、与晓悦往返切换及暂停/继续均恢复播放，56 条克隆响应全部 200、没有 409 或恢复失败。仍有长段生成/预读 8–10 秒延迟，详见 `docs/voice-discovery-2026-09-14/weread-clone-playback-fix-2026-09-18.md`。
- 这不是新的 App Store 提交，与下节同版本 Build 62 商店候选的二进制不同。后续以源码差异和 UUID 区分，仍须通过 `scripts/build-voice-toc-integration.sh --check` 后在独立 DerivedData 构建。

## App Store 1.2.40 送审基线（2026-09-16）

- 当前已提交并回读为 `WAITING_FOR_REVIEW` 的版本为 **1.2.40（62）**，应用源码 **`5c45b75`**；工作树 `/Users/xuxuheng/Documents/.worktrees/CastReader-mobile-voice-explore-20260914`，分支 `codex/mobile-voice-explore-20260914`。归档为该工作树 `build/CastReader-1.2.40-62.xcarchive`，后续截图测试/文档提交不改变包内应用源码。
- 包含下节音色发现、切换并发和额度修复，保留 `64c2dbd`、`633f6bb`、`ad4b885`、`a4a3ee0`、`24b28e3`、`48998e7` / `f94b41d`。另修复法语短发现页内外两层懒加载触发的布局循环；仅有界推荐内容使用 `VStack`，完整音色列表继续懒加载。
- 发布记录及所有检测结果见 `docs/iOS-1.2.40-Release-Report.md`。后续增量集成从此基线继续，打包前运行 `bash scripts/build-voice-toc-integration.sh --check`，使用独立 DerivedData。不得从主目录旧分支打包覆盖。
- 9 月 16 日送审时未重装用户 iPhone；当时最后开发测试源码为下节 `9f946ac`（Build 61）。9 月 18 日新的本地安装见顶部记录。商店候选等待审核不代表已上线。

## 音色发现与 EPUB 目录本地集成（2026-09-15）

- 当前本地 iPhone 迭代在 `/Users/xuxuheng/Documents/.worktrees/CastReader-mobile-voice-explore-20260914`，分支 `codex/mobile-voice-explore-20260914`。
- 测试包必须同时保留音色发现与个人 / 朋友声音入口 `633f6bb`、EPUB TOC 与滚动分支 `ad4b885`（功能提交 `513c674`），以及发布源码祖先 `64c2dbd`。单独从任一功能分支打包会遗漏另一项。
- 打包前执行 `bash scripts/build-voice-toc-integration.sh --check`；真机用同脚本 `--device`，通过 `CASTREADER_DEVICE_DERIVED_DATA` 指定独立构建目录。此脚本会检查三个祖先再执行原发布基线校验。
- 上一轮真机应用源码 `e573cde`：在上述集成上修复跨音色时间戳拆词 / 合词的续读对齐，并收敛切换事务的成功、失败、取消出口。202 项模拟器回归通过；8 项真机播放链路测试通过（可控 TTS 音频，真实 VM / AVPlayer，含 Kindle 三类音色往返）。验收证据见 `docs/voice-discovery-2026-09-14/reading-voice-switch-fix-2026-09-15.md`。
- 前轮真机应用源码 `a4a3ee0` 修复音色面板误拦只读页面稳定检查、页尾等待取消后切换丢失播放意图；保留该修复。见 `docs/voice-discovery-2026-09-14/voice-switch-page-stop-2026-09-15.md`。
- 前轮真机应用源码 `24b28e3`：切换先建立前台准备事务，后台克隆预读等待音频就绪；重试遵守服务端准备状态、Retry-After 与总期限。保留上述全部祖先。11 项针对性测试及 224 项模拟器回归通过（部分重叠）；8 个不同真机用例通过，其中一次系统音频中断影响页尾前置条件，原样单独复测通过。17:18:35 安装、17:19:14 启动，1.2.40（61），dylib UUID `FF840347-F072-32CB-B7CF-C7344FF5DC49`。503 已定位为社区音色准备租约竞争，需要配套后端共享准备与跨实例等待修复；区域部署与实际 API 验收见 `docs/voice-discovery-2026-09-14/voice-preparation-concurrency-2026-09-15.md`。
- 当前真机应用源码 `9f946ac`：额度查询不可用时保留已确认余额，过滤过期的额度响应，后台预读不弹出全局额度警告。158 项模拟器测试通过、3 项 StoreKit 授权相关测试跳过；2 项真机隔离状态测试通过。18:34:37 安装、18:34:39 启动，1.2.40（61），dylib UUID `05B062F6-09BE-3EFB-8D85-0AB458D7B31D`。保留 `24b28e3` 及上述全部祖先，另确认 `48998e7` / `f94b41d` 已包含。中美后端实际状态接口验证通过。证据见 `docs/voice-discovery-2026-09-14/clone-quota-unknown-2026-09-15.md`。
- 本节记录本地测试过程；随后已基于该集成提交上节 Build 62。不得把目录合并提交 `487c746` 单独视为该切换问题已修复。

## 打包与本地真机包的基线校验（2026-09-14）

- 前版 iOS 1.2.39（60）应用源码为 `64c2dbd934d34e7b000c8def1a4c8ee5dc94ab23`；2026-09-16 提交新版本前已回读为 `READY_FOR_SALE`。工作树：
  `/Users/xuxuheng/Documents/.worktrees/CastReader-kindle-offline-five-phases-20260912`，分支 `codex/kindle-offline-five-phases-20260912`。后续 UI 测试和发布文档提交不改变该包的应用源码。
- 候选包包括 Kindle 离线功能和 AO3 修复合并 `d58e296`，并保留已验证发布祖先 `b6dd4d7` 和 1.2.38 集成快照 `5f863c4`。上传、提审状态及签名/测试证据见 `docs/iOS-1.2.39-Release-Report.md`；候选包或等待审核均不等于已经上线。
- 主目录的 `codex/adaptive-voice-clone-denoise` 工作树不是该构建基线。不得仅因当前目录或更大的 Build 号就在此打包覆盖真机，也不得整文件覆盖发布分支。
- 该版离线、AO3、“更多 / Aa / 睡眠定时”实现已包含在顶部 1.2.40 送审基线中，后续增量从顶部工作树继续。原发布基线脚本仍由 `build-voice-toc-integration.sh` 调用。本次 App Store 送审没有覆盖用户手机安装。
- 后续发布更新时，以已验证的新发布提交更新本节，核对祖先关系、源码差异、独立 DerivedData 与回归结果后再安装；版本号不是源码基线证据。
- 本轮至少保留 Kindle 位置恢复、手动翻页确认、预热书架遮挡、原生字号重排、WeRead/Kobo 恢复和播放器失败恢复的发布版实现。不得用旧工作树的新功能实现替换这些子系统。

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## 产品定位

CastReader iOS 是**工具型 TTS 应用**（不是图书 app）。两大产品线：

- **朗读（Read Aloud）**：TTS + 词级高亮 + 自动滚动「三位一体」，像老师指读，帮用户**同时用耳朵和眼睛**锁定注意力。
- **解读（Explain / QuickRead）**：TTS 朗读 LLM 生成的**讲解**（非原文），同时在**原文**上按时间点动画绘制**手写体标注**（高亮/下划线/圈/序号）。

两个输入入口（替代选书）：**①摄像头拍摄**（端上 Vision OCR）、**②上传文件 / 输入文本**。外加 **设置** 与 **Pro 付费（StoreKit 2）+ 免费额度闸门**。

> 历史：本仓库曾是图书阅读器（书城/角色分析/多角色对话 TTS），已整体移除。如在 git 历史里看到 Book/Character/Dialogue/Explore 等，均为旧代码。

## Auto Run on Simulator

当用户要求启动/运行项目时，自动编译→装模拟器→运行，遇编译错误自行修复直到成功。

```bash
xcodebuild -workspace CastReader.xcworkspace -scheme CastReader -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build build
xcrun simctl install <UDID> build/Build/Products/Debug-iphonesimulator/CastReader.app
xcrun simctl launch <UDID> com.same.castreader
```

> **模拟器名**：AGENTS.md 历史写的是 "iPhone 13 Pro"，但本机可能不存在。先 `xcrun simctl list devices available | grep iPhone` 取一个真实 UDID（同名设备有重复时**必须用 UDID**，否则 `-destination` 报 "Unable to find a device"）。Bundle id = `com.same.castreader`。

## Build Commands

```bash
# 编译（必须用 workspace，含 SPM 依赖）
xcodebuild -workspace CastReader.xcworkspace -scheme CastReader -destination 'platform=iOS Simulator,id=<UDID>' build
# 测试
xcodebuild test -workspace CastReader.xcworkspace -scheme CastReader -destination 'platform=iOS Simulator,id=<UDID>'
```
或 Xcode：⌘B / ⌘R / ⌘U。

## App Store 发布自动化

当用户说“提交到 App Store 审核”“提交到应用市场去审核”“发布 iOS 新版本”或等价表达时，必须使用个人 Skill `$submit-castreader-ios-to-app-store`：

`/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/SKILL.md`

完整提交指令默认授权到正式送审与状态回读。按 `docs/iOS-AppStore-Release-SOP.md` 五步执行：确认基线 → 核心服务 → 一次归档上传 → 资料差异检查 → 提交回读。同一候选的有效结果复用，失败后只重测受影响范围。

**送审核心门禁：朗读 / 解读 × Kokoro / 克隆四条管线必须在实际地区服务上验证，克隆覆盖社区 `vl_` 与私人 `vc_`，含真实出声、高亮/原文标注、续播、切换及额度。** 操作与证据见 `docs/iOS-Core-Service-Release-Gate.md`；试听或单测总数不能替代核心验收。

App 九语、商店 11 locale。文案以当前 ASC 资料与本版差异为准，旧八语/1.2.20 模板仅作历史参考。默认保留标题、副标题、未修改字段及有效截图。不得输出 `.p8`、JWT 或签名凭据，不得为过审擅自修改价格、订阅、地区、App Privacy、年龄分级或法律声明。

### 新增/删除源文件 → 必须改 project.pbxproj

工程是传统格式（objectVersion 55，**非** Xcode 16 文件系统同步组），每个 `.swift` 必须登记到 4 处（FileReference / BuildFile / Group.children / Sources phase）。**手改易错，用 `xcodeproj` Ruby gem 脚本**（已安装）：

```ruby
# 增：require 'xcodeproj'; 解析 CastReader 组；ensure_group 创建子目录组；
#     group.new_reference(name) + target.add_file_references([ref]); project.save
# 删：project.files.select{...}.each{ |f| f.build_files.each(&:remove_from_project); f.remove_from_project }
```
注意：多行 shell 变量传参易丢 token，给脚本传**显式空格分隔的参数**。

## 架构

- **SwiftUI**，App target 部署目标 **iOS 17.6**（`project.pbxproj` 内 app target；project 默认与测试 target 仍是 15.5）。可用 iOS 16/17 API，但代码沿用防御式写法（带关联值 enum 手动 `Equatable`、拆分复杂 View）。
- **入口**：`CastReaderApp.swift`（启动 `ProManager.start()` + `QuotaManager.rollIfNewDay()`）。
- **导航**：`MainTabView` 三 Tab —— 首页（`HomeView`）/ 文库（`LibraryView`）/ 设置（`SettingsView`）。阅读宿主 `ReaderHostView` 全屏模态，顶部切「朗读/解读」。
- **依赖（SPM）**：ZIPFoundation（解 EPUB/DOCX 的 zip）、SwiftSoup（EPUB 章节 XHTML → 段落，Jsoup 的 Swift 移植）。

### 统一文档模型（核心抽象）—— `Models/ReadingDocument.swift`

让「拍摄照片+OCR」与「重排纯文本」两种源，在朗读高亮与解读 marks 的**定位**上走同一接口。

| 类型 | 说明 |
|------|------|
| `ReadingDocument{sourceKind(.photo/.text), language, paragraphs, imageData?, imagePixelSize?}` | 统一文档 |
| `ReadingParagraph{id, text, type, words:[OCRWord], bboxNorm?}` | 段落；photo 源带 OCR 词 |
| `OCRWord{id, text, bboxNorm}` | Vision 归一化 bbox（**原点左下**） |
| `ReadingGeometry` | Vision 归一化(左下) ↔ SwiftUI 点(左上, aspectFit) 坐标换算 |
| `ReadingAnchorResolver`（协议）+ `PhotoAnchorResolver` | 段落+词索引 / 段落+字符范围 → 可绘制矩形 |

构建器 `Utils/DocumentBuilder.swift`：`fromMarkdown`（复用 `MarkdownParser`）/ `fromPlainText` / `fromPDF`（PDFKit 本地提取）/ `fromTextFile`。

### 关键服务 / VM

| 模块 | 类型 | 职责 |
|------|------|------|
| `TTSService` | actor 单例 | 云端单声道 TTS：`generateTTSForParagraph` 流式回调 AudioSegment（本地 Kokoro 引擎已移除以减小包体积） |
| `AudioPlayerService` | class 单例 | 播放队列、`loadSegment`、`moreSegmentsExpected` 流式标志、`$currentTime`/`$currentSegment` |
| `OCRService` | actor 单例 | Vision `VNRecognizeTextRequest` → `ReadingDocument(.photo)`（逐词 bbox + 段落聚类） |
| `QuickReadService` | actor 单例 | 解读后端：extract-plan(SSE)/extract-block/compose-block |
| `ProManager` | @MainActor OO 单例 | 综合 Pro（`isPro = storeKitPro \|\| serverPro`）、StoreKit purchase/restore/manage、`Transaction.updates` |
| `QuotaManager` | @MainActor OO 单例 | 免费额度（服务端优先 + 本地 fail-open，每日午夜重置） |
| `AuthService` | @MainActor OO 单例 | Google(ASWebAuthenticationSession+PKCE) / Apple 登录，账号资料 |
| `ProBackendService` | actor 单例 | readout-web 公开端点：`/api/pro/status`、`/api/pro/listen-track` |
| `APIService` | actor 单例 | 上传(STS/COS)、文档列表、Markdown 拉取、云端单声道 TTS |
| `ReadAloudViewModel` | @MainActor OO | 朗读编排：逐段 TTS→入队→词级高亮→自动推进→额度计时 |
| `ExplainViewModel` | @MainActor OO | 解读编排：三段式 + 块时间线 marks 触发 + `MarkAnchoring` 锚定 |

> **音频回调单一所有权**：`AudioPlayerService.onPlaybackComplete` 只有一个；ReadAloud 与 Explain 两 VM 共享同一播放器，故回调只在 `start()` 时由当前激活模式 `activate()` 设置，并用 `isActive` 门控 `onTick`。切模式时旧 VM `deactivate()`。

### 后端端点（`Utils/Constants.swift`）

```
全球线路：baseURL / quickReadBaseURL / webURL = https://api.castreader.ai
中国线路：baseURL / webURL = https://api.castreader.cn
中国 QuickRead：quickReadBaseURL = https://quickread.castreader.cn
# ServiceRouting 在进程启动时冻结；产品区域与服务线路可在测试包中独立切换。
# CN QuickRead 直连专用备案入口；上游切换和容灾仅在对应入口服务端完成。

/api/captioned_speech_partly         # 单声道云端 TTS（partly 流式，带时间戳）
/api/mobile/upload/sts               # 新版受保护 STS（cms_ session）
/api/mobile/upload/notify            # COS 上传完成通知（cms_ session；服务端注入 canonical user）
# /async-md-upload-by-url 与 /upload 仅供旧已发布二进制兼容，新版不得调用
/documents                            # 文库文档列表
/api/quickread/extract-plan          # 解读：SSE，事件 stage/block0/done/error
/api/quickread/extract-block         # 解读：逐块讲解文本
/api/quickread/compose-block         # 解读：用 TTS timestamps 回填 mark.at
```

> **受保护 API 鉴权**：新版 QuickRead 与 STS 都只发送所选线路的服务端 `cms_` session（`Authorization: Bearer` + `X-Auth-Provider: session`）。客户端不得内置上游 API key，也不得用 `device_id` 或可伪造的 user/email 代替账号身份。历史 `/sts` 仅由服务端为已发布旧版保留兼容，新版不得回退。

## 核心子系统细节

### 拍摄 OCR + 照片叠加（`Services/OCRService.swift`、`Views/Reader/PhotoReaderCanvas.swift`）

- `CameraView`（`UIImagePickerController`，模拟器无相机时回退相册）→ `CaptureFlowViewModel.process` → OCR。
- Vision 返回行级 observation，逐词 `boundingBox(for:)` 取归一化 bbox（原点左下）；按垂直间隙/缩进聚类成段落。
- `PhotoReaderCanvas`：照片 `aspectFit`；朗读高亮当前 OCR 词 bbox；解读把手写标注画在原文上。坐标换算见 `ReadingGeometry`（**翻转 Y**：`y = fitted.minY + (1-n.maxY)*fitted.height`）。
- `Info.plist` 需 `NSCameraUsageDescription` + `NSPhotoLibraryUsageDescription`。

### 朗读（`ViewModels/ReadAloudViewModel.swift`、`Views/Reader/TextReaderView.swift`+`ReaderTextView.swift`）

- 每段 `TTSService.generateTTSForParagraph` 流式入队（生成用 `speed:1.0`，播放用 `AudioPlayerService.setPlaybackRate`）。
- **词级高亮统一在 `currentSegment.timestamps` 内按时间定位**（每个 segment 是独立 AVPlayerItem，`currentTime` 相对当前 segment）：text 源映射为 `processedDisplayText` 内字符范围 `highlightRange`；photo 源用游标对齐到 OCR 词 `photoHighlightWordIndex`。
- 文本渲染走 `ReaderTextView`（精简 UITextView，`ReaderRoundedBackgroundLayoutManager` 画 4px 圆角高亮 + `rects(forCharRange:)` 供解读定位）。

### 解读（`ViewModels/ExplainViewModel.swift`、`Utils/MarkAnchoring.swift`+`HandwrittenMark.swift`、`Views/Reader/MarkOverlay.swift`）

- TTS 读的是 LLM **讲解文本**（非原文）。每块：`extractBlock`→TTS→拼块时间线→`composeBlock` 回填 `at`→入队播放。
- 播放中按「块时间线」elapsed（前序 segment 时长 + 当前 segment currentTime）触发 marks。
- `MarkAnchoring.locate(markText, near:)`：把 mark 锚文本（可能带【】或被改写）**模糊匹配**到原文字符范围（归一化+首尾窗口）；失败即跳过（fail-open）。
- `HandwrittenMark` 用确定性 `SeededGenerator`（同 mark 重绘不抖）生成手写 `Path`；`MarkInkView` 用 `Shape.trim` 做落笔动画。**iOS 端无需上传截图**，marks 客户端文本锚定。
- **SSE 解析坑（已踩）**：`URLSession.AsyncBytes.lines` 会**吞掉 SSE 事件之间的空行**，不能靠空行判定事件边界——`QuickReadService` 改为「遇到下一个 `event:` 行或空行就 flush 上一个事件」，否则 block0 会被后续 done 覆盖、报 `noBlock0`。

### EPUB（原生解析渲染，含图片）—— `Services/EpubNativeEngine.swift`+`Utils/HtmlParser.swift`

弃 epub.js/WebView（整本 DOM 高亮 overlay + `setActive` flood → 性能崩），改纯本地原生解析（回译 Android `EpubNativeEngine.kt`/`HtmlParser.kt`/`EpubReaderScreen.kt`）：

- `EpubNativeEngine.parse(data:)`：ZIPFoundation 解包 → 读 `META-INF/container.xml` 找 OPF → SwiftSoup(`Parser.xmlParser()`) 解析 manifest(id→href,type)+spine(顺序) → 内嵌图片(media-type `image/*`)解字节存 `[规范化href: Data]` → 按 spine 逐章 XHTML 经 `HtmlParser` 抽段落 → 合并、重排连续 id、图片相对 href 回填字节。**三套坐标统一相对 OPF 目录**（images key / 章节 href / `resolveImageHref` 输出）；`zipPath()` 才转 zip 根。`SwiftSoup.Document` 须显式限定（CastReader 另有 `Models/Document.swift` 同名）。
- `HtmlParser.parse(xhtml)`：SwiftSoup 递归遍历 body 按 tag 分派（img/figure/h1-6/p/blockquote/pre/li/div），跳过 script/style/nav/toc/pageno；parse 开头全局 `remove` 噪声(linenum/pageno/dropcap)以免 per-element clone（SwiftSoup `copy()` 返 Node 非 Element）。产出 `[EpubBlock]`(type+text+imageHref)。
- `DocumentBuilder.fromEPUB` → `ReadingDocument(.epub)`，走 **TextReaderView 原生渲染**（`.epub` 已从 `isWebRendered` 移除）：图片段(`type==.image`)用 `EpubImageDecoder.downsampled`(ImageIO 缩略图降采样，对齐 Coil)渲染，其余段复用文本/词高亮/mark 管线。**图片段 text 置空但占 id**（保 index 连续 → mark 锚定/解读分批不错位），`isReadable=false` 朗读自动跳过封面图。
- 朗读/解读/MarkAnchoring **零改动复用**（与 text/PDF 源同管线，`currentParagraphIndex==para.id`）；解读分批同 PDF（`setupBatchScopeIfLarge`）。大书后台线程解析（`HomeView` EPUB 入口 `Task.detached`）避免卡 UI。自检 `CastReaderTests/EpubNativeEngineTests`（真实 EPUB 段落/图片/id 连续性）。

### 登录 / 账号（`Services/AuthService.swift`(+Apple)、`Models/UserAccount.swift`、`Views/Auth/`）

- **Google**：原生 `ASWebAuthenticationSession + PKCE` 直连 Google（**无第三方 SDK**），换 code→token→解析 id_token 得 email/name/picture/sub。`callbackURLScheme` 由会话内部拦截，**无需 Info.plist URL scheme**。需在 `Constants.GoogleOAuth.clientID` 填入真实 iOS OAuth client id（未填时登录页优雅隐藏 Google 入口）。
- **Apple**：SwiftUI `SignInWithAppleButton`（4.8 合规）。需 entitlement `com.apple.developer.applesignin`（`CastReader/CastReader.entitlements`，已设 `CODE_SIGN_ENTITLEMENTS`；真机/上架需在开发者后台开启该 capability）。
- best-effort 把 id_token 发 `POST /api/auth/sign-in/social`（better-auth）换后端 user id；失败不影响登录，Pro 退回 device_id 维度。账号资料存 UserDefaults，token 存 Keychain。

### Pro / 付费 / 额度（`Services/ProManager.swift`+`QuotaManager.swift`+`ProBackendService.swift`、`Views/Paywall/`）

- **综合 Pro**：`isPro = storeKitPro || serverPro`。iOS 主通道是 **StoreKit 2 内购**（Apple 合规）；Web 端用 **Stripe**，已付费者登录/设备关联后经服务端 `serverPro` 同步到 iOS。
- **服务端 Pro/额度**（readout-web 公开端点，`Constants.API.webURL`）：`GET /api/pro/status?device_id=&user_id=&email=&local_date=` 回填 Pro + 额度；`POST /api/pro/listen-track` 上报朗读秒数。`device_id` 复用 visitor id；登录后必须尽量同时附 `user_id` 与 `email`。`QuotaManager` 服务端值优先、fail-open 本地计数。启动/前台/登录/购买后 `ProManager.refresh()`。
- 免费额度：每日 20min 朗读 / 3 次解读 / 仅基础音色 / 速度≤2.0x；本地午夜重置；"读完本篇" 宽限 15min 硬上限。闸门检查点（仅额度处硬阻，出错 fail-open）：开始朗读/解读、选 Pro 音色、speed>2.0x。
- StoreKit：`Transaction.currentEntitlements` + `Transaction.updates` 监听；`openManageSubscriptions`；本地测试用根目录 `Configuration.storekit`（Edit Scheme→Run→Options→StoreKit Configuration 关联，否则付费页显示"加载订阅…"）；生产 `ai.castreader.pro.{monthly,yearly}` 在 App Store Connect 配置。**后端目前无 Apple IAP 收据校验**——iOS 端 StoreKit 权益为本地权威；如需服务端入账需后端新增 receipt-verify。
- **跨端 Pro 一致性硬标准**：详见 `docs/Pro一致性标准.md`。所有 iOS / Android / Web / 扩展 / 扩展上传文件朗读页都必须走同一套 `/api/pro/status` 口径。Google `sub`、Apple user id、OAuth `account_id` 不是订阅主键；服务端必须归一化到后端 `user.id`，客户端登录后必须尽量传 `device_id + user_id + email`。禁止只靠 `device_id` 判定登录用户 Pro，禁止某个入口单独实现 Pro 逻辑。

### 上线前必填配置清单
- `Constants.GoogleOAuth.clientID`：Google iOS OAuth client id。
- App Store Connect 订阅产品 + scheme 关联 `Configuration.storekit`。
- Apple 开发者后台为 App ID 开启 Sign in with Apple capability。

## 避坑指南 (iOS Best Practices)

1. **带关联值 enum 要手动 `: Equatable`** 才能用 `!=`/`==`（如 `ReadingParagraphType`、`TTSStatus`、`ExplainStatus`）。
2. **`CGFloat`/`UIColor` 等需 `import UIKit`**（纯 `import SwiftUI` 用 `UIColor` 会报错；但文件已在 iOS target 时 `import SwiftUI` 通常够——SourceKit 单独分析新文件时常误报 "No such module 'UIKit'"/"Cannot find 'Constants'"，**以 `xcodebuild` 真实编译为准**）。
3. **`.greatestFiniteMagnitude` 在 `CGSize(...)` 里要写 `CGFloat.greatestFiniteMagnitude`** 否则 ambiguous。
4. iOS 16+ API（Layout 协议、presentationDetents、Charts）即便部署目标 17.6 也尽量少用，保持与既有防御式代码一致。
5. **复杂 View 拆 `@ViewBuilder` 子视图**避免类型检查超时。
6. `fileImporter` 的 `UTType` 用 `UTType(identifier:)` 安全创建（epub/docx 可能未内置）。
7. API 字段类型可能不一致/为 null → Model 用可选 + 自定义解码；解码失败先打印原始响应 + `error`（含 codingPath）。
8. 含空格的 URL 必须 `addingPercentEncoding` 否则 `URL(string:)` 返回 nil。

## TTS 引擎 — 云端朗读与 Kindle 离线系统朗读

常规在线朗读使用云端 TTS（`TTSService` → `APIService.generateTTS` 单声道流式）。原本地 Kokoro/FluidAudio CoreML 引擎已整体移除；不要为了 Kindle 离线功能重新引入这些依赖。`AudioSegment.isWavFormat` 字段保留，云端音频仍为 mp3。

Kindle 离线书由 `KindleOfflineBookReaderModel` 配合 `SystemSpeechPlaybackService` 使用原生 `AVSpeechSynthesizer`。下载只保存整本页图、封面与顺序清单；朗读时按需用端上 Vision OCR 识别，不能把 OCR 加回下载串行流程。入口在播放器“更多”中保存、设置的“离线书籍”中读取。中文/日文按句子高亮，英文按词高亮；收起阅读器保留迷你播放器。跨页期间暂停能力以模型的 `canPausePlayback` 为准，不能仅用瞬时语音状态或页面 loading 状态禁用暂停。

## TTS 文本渲染 — 直接渲染 TTS 文本，不映射回原文

TTS 返回的 `processedText` 与原文有差异（标点/空格规范化）。**不要把 timestamps 映射回原文**（会找不到/不同步）。朗读当前段渲染 `processedDisplayText`（segments 的 `text` 拼接），高亮在其中按词定位；未生成段落渲染 `paragraph.text`。`AudioSegment{text, timestamps:[TTSTimestamp{word,start,end}], unprocessedText, speaker?}`。

## TTS 播放竞态 — `moreSegmentsExpected` 标志

流式生成时音频可能播得比生成快。`AudioPlayerService`：队列空但 `moreSegmentsExpected==true` 时置 `waitingForNextSegment` 等待，新 segment 到达继续；`==false` 才 `onPlaybackComplete`。VM 端：生成前 `clearQueue()` + `moreSegmentsExpected=true`，生成完/出错都要复位 `false`；切段先 `cancelCurrentRequest()`。

## 自动滚动

`TextReaderView` 用 `ScrollViewReader`：朗读时 `currentParagraphIndex` 变化滚到该段（`anchor:.center`）；解读时滚到最新 mark 所在段。photo 模式整页可见无需滚动。舒适区精细化（15%~70% + 手动打断回弹）可后续按需加。
