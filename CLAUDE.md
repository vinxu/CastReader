# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **声音克隆修改前强制入口**：修改 iOS `VoiceClone*`、克隆 TTS、区域/账号/额度，或
> `reports/nari-dynamic-voice-clone-poc/**` Worker/部署代码前，必须完整阅读
> `https://github.com/scmyyan/readout-web/blob/e42b21ef2899f549f75d7a3bafda051dfed39a8c/docs/voice-clone-system-architecture.md`
>（Architecture ID `voice-clone-system-v1`）。遵守 speaker-only、iOS 双区隔离、试听
> 非阻塞、结构化不存在、无预设音色/跨区回退和 reader-before-writer 合同。相关 commit
> 必须包含 `Voice-Clone-Architecture-Reviewed: voice-clone-system-v1`。跨仓库精确版本以
> `docs/contracts/voice-clone-architecture.lock.json` 为准，并先运行
> `python3 scripts/voice_clone_architecture_gate.py verify-lock --require-pinned`。

## 产品定位

CastReader iOS 是**工具型 TTS 应用**（不是图书 app）。两大产品线：

- **朗读（Read Aloud）**：TTS + 词级高亮 + 自动滚动「三位一体」，像老师指读，帮用户**同时用耳朵和眼睛**锁定注意力。
- **解读（Explain / QuickRead）**：TTS 朗读 LLM 生成的**讲解**（非原文），同时在**原文**上按时间点动画绘制**手写体标注**（高亮/下划线/圈/序号）。

内容入口分两类：
- **自带内容**：拍照/相册（Vision OCR）、文件（PDF/EPUB/DOCX/TXT/MD）、输入文本、粘贴板、网址、系统分享（Share Extension）、Safari 扩展。
- **绑定书库**：**Kindle Cloud Reader**（read.amazon.com）与**微信读书**（weread.qq.com）—— 都在用户已登录的 WKWebView 里实时取页，**不落库正文、不存凭据**。

外加 **九语全量本地化**、**音色浏览器**、**Pro 付费（StoreKit 2）+ 免费额度闸门**。

> 历史：本仓库曾是图书阅读器（书城/角色分析/多角色对话 TTS），已整体移除。git 历史里的 Book/Character/Dialogue/Explore 均为旧代码。

## Auto Run on Simulator

当用户要求启动/运行项目时，自动编译→装模拟器→运行，遇编译错误自行修复直到成功。

```bash
xcodebuild -workspace CastReader.xcworkspace -scheme CastReader -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build build
xcrun simctl install <UDID> build/Build/Products/Debug-iphonesimulator/CastReader.app
xcrun simctl launch <UDID> com.same.castreader
```

> **取 UDID**：先 `xcrun simctl list devices available | grep iPhone`（同名设备有重复时**必须用 UDID**，否则 `-destination` 报 "Unable to find a device"）。Bundle id = `com.same.castreader`。
>
> **destination 全部 ineligible 时**先查 Xcode 平台组件：`xcodebuild -showdestinations -workspace ... -scheme CastReader`。若报 `iOS <ver> is not installed`，说明当前 Xcode 需要的 iOS 平台没装（`xcrun simctl list runtimes` 里的模拟器 runtime 版本对不上也一样无解），需在 **Xcode → Settings → Components** 装平台；这不是仓库问题，改代码无法绕过。

## Build Commands

```bash
# 编译（必须用 workspace，含 SPM 依赖）
xcodebuild -workspace CastReader.xcworkspace -scheme CastReader -destination 'platform=iOS Simulator,id=<UDID>' build
# 测试
xcodebuild test -workspace CastReader.xcworkspace -scheme CastReader -destination 'platform=iOS Simulator,id=<UDID>'
```
或 Xcode：⌘B / ⌘R / ⌘U。

### 6 个 target（`CastReader` scheme 会连扩展一起构建）

| target | bundle id | 说明 |
|---|---|---|
| CastReader | `com.same.castreader` | 主 app，部署目标 **iOS 17.6** |
| CastReader Safari Extension | `com.same.castreader.SafariExtension` | Safari Web Extension |
| CastReader Share Extension | `com.same.castreader.ShareExtension` | 系统分享入口 |
| CastReader Widget | `com.same.castreader.Widget` | 主屏小组件 |
| CastReaderTests / CastReaderUITests | — | 单测 / UI 测试 |

主 app **依赖并 embed 三个扩展**，所以扩展坏了主 app 也编不过。App Group = `group.com.same.castreader`（Share/Safari 扩展与主 app 交换数据的唯一通道）。

> **Safari 扩展的网页资源已入本仓库**：`CastReader Safari Extension/Resources/`（manifest.json / background.js / content-scripts / _locales 九语 / assets …），随包发布，克隆仓库即可编译，**不再依赖兄弟仓库 readout-desktop**。
>
> 这些资源在 pbxproj 里是 **folder reference**（`lastKnownFileType = folder`，如 `assets` / `chunks` / `brainrot-bg`），所以增删目录内的网页文件**不需要改 pbxproj**——与主 app 每个 `.swift` 必须登记 4 处的规则相反。资源本身仍由扩展仓库 readout-desktop 构建产出，更新时把产物整体覆盖进 `Resources/` 即可。

### WebReader JS bundle（改了 TS 才需要重新构建）

`WebReader/` 用 esbuild 把扩展 readout-desktop 的 DOM 高亮/标注 JS 打成单文件 IIFE，**产物 `CastReader/WebAssets/bundle.js` 已入 git**，日常编译不需要 node：

```bash
cd WebReader && npm install && npm run build   # → ../CastReader/WebAssets/bundle.js
```

### 密钥

`Secrets.xcconfig`（已 gitignore，模板见 `Secrets.example.xcconfig`）→ Info.plist → `Constants.API.quickReadAPIKey`。缺失时解读 401，其余功能不受影响。

### 新增/删除源文件 → 必须改 project.pbxproj

工程是传统格式（objectVersion 55，**非** Xcode 16 文件系统同步组），每个 `.swift` 必须登记到 4 处（FileReference / BuildFile / Group.children / Sources phase）。**手改易错，用 `xcodeproj` Ruby gem 脚本**（已安装）：

```ruby
# 增：require 'xcodeproj'; 解析 CastReader 组；ensure_group 创建子目录组；
#     group.new_reference(name) + target.add_file_references([ref]); project.save
# 删：project.files.select{...}.each{ |f| f.build_files.each(&:remove_from_project); f.remove_from_project }
```
注意：多行 shell 变量传参易丢 token，给脚本传**显式空格分隔的参数**。参考 `scripts/add_epub_files.rb`、`scripts/add_share_extension.rb`。

## App Store 发布自动化

用户说「提交 App Store 审核 / 发布 iOS 新版本」时走个人 Skill `submit-castreader-ios-to-app-store`；项目内 SOP 见 `docs/iOS-AppStore-Release-SOP.md`，多语文案源为 `docs/CastReader-AppStore-Metadata-8-Languages.md`。不得输出 `.p8`/JWT/签名凭据，不得为过审擅自改价格、订阅、地区、App Privacy、年龄分级或法律声明。

## 架构

- **SwiftUI**，App target 部署目标 **iOS 17.6**（project 默认与测试 target 仍是 15.5）。可用 iOS 16/17 API，但代码沿用防御式写法（带关联值 enum 手动 `Equatable`、拆分复杂 View）。
- **入口** `CastReaderApp.swift`：启动 `ProductAnalytics.startAppSession()` / `ProManager.start()` / `QuotaManager.rollIfNewDay()` / `VoiceCatalogService.start()`，并异步刷 `TTSEndpoint` + `QuickReadEndpoint` 远程配置。前台再刷 Pro/额度/音色目录。`onOpenURL` 处理 `castreader://share-inbox|pro|account`。
- **导航**：`MainTabView` 三 Tab —— **首页 `HomeView` / 中间凸起 ➕（快速导入，非真 Tab）/ 音色 `VoiceBrowserView`**。**设置是 `.sheet`**（首页右上角齿轮），**文库/历史 `LibraryView` 在设置内**。
- **阅读器常驻顶层，不用 fullScreenCover**：`ReaderHostView`（自有内容）与 `KindleBookView`（Kindle）在会话存活期间一直挂在 `MainTabView` 的 ZStack 里，收起=`offset` 移出屏幕而非 dismiss。**View 永不重建 → 保留滚动位置、UITextView registry、WKWebView、解读 mark、后台播放**。`PlayerCoordinator`（自有内容）/ `KindlePlaybackCenter`（Kindle）各自持有会话并驱动 Mini Player。
- **`AppOrientationLock`**：按 owner 叠加的方向锁（WeRead 阅读时锁竖屏；阅读器收起时 `lockCurrent` 冻结当前方向，避免离屏 WKWebView 被旋转 reflow 打断 TTS）。
- **依赖（SPM）**：ZIPFoundation 0.9.20（解 EPUB zip）、SwiftSoup 2.13.5（XHTML → 段落）。**无第三方 SDK**（登录、支付、埋点全自研）。

### 统一文档模型（核心抽象）—— `Models/ReadingDocument.swift`

八种输入源在朗读高亮与解读 mark 的**定位**上走同一接口，收敛为三条渲染路径：

| `ReadingSourceKind` | 渲染路径 | 定位方式 |
|---|---|---|
| `.photo` / `.kindle` | `isOCRImageRendered` → `PhotoReaderCanvas` / `KindleReaderView` | 原图 aspectFit + Vision 归一化 bbox |
| `.web` / `.docx` / `.weread` | `isWebRendered` → `WebReaderView` + `WebReaderBridge` | WKWebView DOM，JS bridge 驱动高亮 |
| `.text` / `.epub` | `isNativeTextRendered` → `TextReaderView` + `ReaderTextView` | `processedDisplayText` 内字符范围 |
| `.pdf` | `PDFReaderView`（自成一路） | PDFKit `characterBounds` overlay，保原排版 |

| 类型 | 说明 |
|------|------|
| `ReadingDocument{sourceKind, language, paragraphs, imageData?, imagePixelSize?}` | 统一文档 |
| `ReadingParagraph{id, text, type, words:[OCRWord], bboxNorm?, imageData?}` | 段落；OCR 源带词 bbox，image 段带图片字节 |
| `OCRWord{id, text, bboxNorm}` | Vision 归一化 bbox（**原点左下**） |
| `ReadingGeometry` | Vision 归一化(左下) ↔ SwiftUI 点(左上, aspectFit) 换算 |
| `ReadingAnchorResolver`（协议）+ `PhotoAnchorResolver` | 段落+词索引 / 段落+字符范围 → 可绘制矩形 |

构建器 `Utils/DocumentBuilder.swift`：`fromMarkdown` / `fromPlainText` / `fromPDF`（PDFKit）/ `fromTextFile` / `fromEPUB`。

### 关键服务 / VM

| 模块 | 类型 | 职责 |
|------|------|------|
| `TTSService` | actor 单例 | 云端单声道 TTS：`generateTTSForParagraph` 流式回调 AudioSegment |
| `AudioPlayerService` | class 单例 | 播放队列、`loadSegment`、`moreSegmentsExpected` 流式标志、`$currentTime`/`$currentSegment` |
| `OCRService` | actor 单例 | Vision + Tesseract 双引擎 OCR → `ReadingDocument`（逐词 bbox + 段落聚类） |
| `QuickReadService` | actor 单例 | 解读后端：fast-block0(快道)/extract-plan(SSE)/extract-block/compose-block |
| `ProManager` | @MainActor 单例 | 综合 Pro（`isPro = storeKitPro \|\| serverPro`）、StoreKit purchase/restore/manage |
| `QuotaManager` | @MainActor 单例 | 免费额度（服务端优先 + 本地 fail-open，每日午夜重置） |
| `AuthService`(+Apple) | @MainActor 单例 | Google(ASWebAuthenticationSession+PKCE) / Apple 登录 |
| `MobileSessionStore` | actor 单例 | `/api/mobile-auth/session` 会话 token，存 Keychain |
| `ProBackendService` | actor 单例 | `/api/pro/status`、`/api/pro/listen-track` |
| `APIService` | actor 单例 | 上传(STS/COS)、文档列表、Markdown 拉取、云端 TTS |
| `HistoryStore` | @MainActor 单例 | 文库=本地历史，**纯本地不上云**：`index.json` 元数据 + `<id>.payload` 原始数据 |
| `KindleLibraryStore` / `WeReadLibraryStore` | @MainActor 单例 | 书架元数据 + 进度锚点缓存（**凭据只留在 WKWebView website data store**） |
| `VoiceCatalogService` | ObservableObject 单例 | 服务端音色目录拉取 + 缓存 + 静态兜底 |
| `ProductAnalytics` | 单例 | 自研埋点 → `castreader.ai/api/events`，事件契约见 `docs/analytics/mobile-events-v2.json` |
| `ReadAloudViewModel` | @MainActor | 朗读编排：逐段 TTS→入队→词级高亮→自动推进→额度计时 |
| `ExplainViewModel` | @MainActor | 解读编排：三段式 + 块时间线 marks 触发 + `MarkAnchoring` 锚定 |
| `PlayerCoordinator` / `KindlePlaybackCenter` | @MainActor | 播放会话所有权 + Mini Player + 阅读器升降 |

> **音频回调单一所有权**：`AudioPlayerService.onPlaybackComplete` 只有一个；ReadAloud 与 Explain 两 VM 共享同一播放器，故回调只在 `start()` 时由当前激活模式 `activate()` 设置，并用 `isActive` 门控 `onTick`。切模式时旧 VM `deactivate()`。

### 后端端点

```
Constants.API.baseURL          = https://api.castreader.ai           # 云端 TTS
Constants.API.readerServiceURL = http://api.castreader.ai:8123        # 文档/上传（http，已在 ATS 例外）
Constants.API.webURL           = https://castreader.ai                # 账号 / Pro / 埋点

/api/captioned_speech_partly           # 单声道云端 TTS（partly 流式，带时间戳）
/api/tts/catalog?contract=...          # 音色目录
/sts /async-md-upload-by-url /upload   # STS 凭证 + 文件上传
/documents                             # 文档列表
/api/pro/status  /api/pro/listen-track  /api/pro/verify-apple
/api/auth/sign-in/social  /api/mobile-auth/session
/api/events                            # 埋点
```

**两个端点走 COS 远程配置**（换后端零发版，启动时刷新、失败保留缓存）：

| enum | 远程配置 | 兜底 |
|---|---|---|
| `TTSEndpoint` | `.../tts-endpoints.json` | CN 时区→CN 节点，其他→US；CN 失败回退 US |
| `QuickReadEndpoint` | `.../quickread-config.json` | `https://qr.castreader.ai` |

> ⚠️ `Constants.API.quickReadBaseURL` 等常量**已不再被调用**，只是兜底参考值。运行时地址一律来自 `QuickReadEndpoint.base()`。**绝不再用旧的 `quickread.castreader.ai:8444`**。
>
> **解读鉴权**：quickread 后端要求 `x-api-key`（`Constants.API.quickReadAPIKey`）+ `x-device-id`。key 为空 → **401**（控制条显示「重试解读」）。**402 = 免费额度用满**，应弹付费墙而不是报错。

## 九语全功能合同

权威语言目录与顺序固定：`en / zh / ja / es / fr / de / pt-BR(内部主码 pt) / it / hi`。完整合同见 **`docs/iOS-Nine-Language-Service-Contract.md`**（新增语言或改动检测/OCR/句界前必读）。要点：

- `SupportedTTSLanguage`（`Utils/LanguageDetector.swift`）是唯一语言真相源——语言集合、顺序、BCP-47 归一化、默认音色、Vision OCR locale、`timestampMode` 全在这里。
- **UI 文案必须九语齐全**：`CastReader/Localizable.xcstrings`、`InfoPlist.xcstrings`、`CastReader Share Extension/Localizable.xcstrings` 每个 key 都要有 9 个 locale。业务 View 不得写死某语言，一律 `AppLocalized("…")`（走 `AppLanguageManager` 的 in-app 语言覆盖，不只是系统语言）。改 xcstrings JSON 时用 `separators=' : '` 保持格式；批量补齐参考 `scripts/sync_german_localizations.py`。
- **句界统一走 `ReadingSentenceContract`**（`Models/TTSTimestamp.swift`）：覆盖 `。！？；…` / `.!?;` / 天城文 `।॥` / 尾随引号，并含德语缩写白名单（`z. B.` / `bzw.` / `usw.` 不切句）。别在各输入格式里自己切句。
- **词级高亮与语言无关**：每个音频 segment 独立校验 timestamp 数量/覆盖率/单调性/时间区间，通过才用词级，失败只让**当前 segment** 退回句级。中文/日文整句只有一个 timestamp 的响应判为句级（`timestampMode`：zh/ja = `segment`，其余 = `word`）。
- **OCR 多语言只负责选语言**，产出文字和几何时必须用**一个确定的语言 profile**。Vision 不支持 Hindi → 必须用 `hin` Tesseract 模型，不得静默退回英文。九个 traineddata 随包在 `CastReader/WebAssets/KindleOCR/tesseract-wasm/`（eng/chi_sim/jpn/spa/fra/deu/por/ita/hin + jpn_vert）。

## 核心子系统细节

### 拍摄 OCR + 照片叠加（`Services/OCRService.swift`、`Views/Reader/PhotoReaderCanvas.swift`）

- `CameraView`（`UIImagePickerController`，模拟器无相机时回退相册）→ `CaptureFlowViewModel.process` → OCR。
- Vision 返回行级 observation，逐词 `boundingBox(for:)` 取归一化 bbox（原点左下）；按垂直间隙/缩进聚类成段落。**Hindi 走 `KindleTesseractOCRService`**（隐藏 WKWebView 跑 tesseract-wasm，与 Kindle 用同一套模型），并用置信度打分决定 Vision / Tesseract 谁胜出。
- OCR 必须用**原始、方向归正后的像素**；JPEG 压缩只允许在 OCR 完成后用于显示与历史存储。
- `PhotoReaderCanvas`：照片 `aspectFit`；朗读高亮当前词 bbox；解读把手写标注画在原文上。坐标换算见 `ReadingGeometry`（**翻转 Y**：`y = fitted.minY + (1-n.maxY)*fitted.height`）。
- `Info.plist` 需 `NSCameraUsageDescription` + `NSPhotoLibraryUsageDescription`。

### 朗读（`ViewModels/ReadAloudViewModel.swift`、`Views/Reader/TextReaderView.swift`+`ReaderTextView.swift`）

- 每段 `TTSService.generateTTSForParagraph` 流式入队（生成用 `speed:1.0`，播放用 `AudioPlayerService.setPlaybackRate`）。
- **词级高亮统一在 `currentSegment.timestamps` 内按时间定位**（每个 segment 是独立 AVPlayerItem，`currentTime` 相对当前 segment）：text 源映射为 `processedDisplayText` 内字符范围 `highlightRange`；OCR 源用游标对齐到词 `photoHighlightWordIndex`；web 源经 bridge 下发。
- **整段预对齐缓存**：词→字符范围的对齐在段落级一次算好，**不要每帧 `indexOf`**（EPUB 长段卡死的根因）。
- 文本渲染走 `ReaderTextView`（精简 UITextView，`ReaderRoundedBackgroundLayoutManager` 画 4px 圆角高亮 + `rects(forCharRange:)` 供解读定位）。

### 解读（`ViewModels/ExplainViewModel.swift`、`Utils/MarkAnchoring.swift`+`HandwrittenMark.swift`、`Views/Reader/MarkOverlay.swift`）

- TTS 读的是 LLM **讲解文本**（非原文）。每块：`extractBlock`→TTS→拼块时间线→`composeBlock` 回填 `at`→入队播放；首块可走 `fast-block0` 快道秒开。
- 播放中按「块时间线」elapsed（前序 segment 时长 + 当前 segment currentTime）触发 marks。
- `MarkAnchoring.locate(markText, near:)`：把 mark 锚文本（可能带【】或被改写）**模糊匹配**到原文字符范围（归一化+首尾窗口）；失败即跳过（fail-open）。
- `HandwrittenMark` 用确定性 `SeededGenerator`（同 mark 重绘不抖）生成手写 `Path`；`MarkInkView` 用 `Shape.trim` 做落笔动画。**iOS 端无需上传截图**，marks 客户端文本锚定。配色须遵守 `docs/高亮与mark颜色统一规范.md`。
- **场景化解读**：`ExplainContentType`（paper / book / report / contract / study / manual）从首页场景入口一路带到后端 prompt，规范见 `docs/场景解读适配规范.md`、`docs/划重点批注-场景化需求.md`。
- **长文档按「批」分批**（`setupBatchScopeIfLarge`）：PDF/EPUB 按 ~3000 字一批 plan（对齐网页体量保 mark 密度），**别改回逐页**——mark 稀疏是批太大，不是锚定坏了。
- **SSE 解析坑（已踩）**：`URLSession.AsyncBytes.lines` 会**吞掉 SSE 事件之间的空行**，不能靠空行判定事件边界——`QuickReadService` 改为「遇到下一个 `event:` 行或空行就 flush 上一个事件」，否则 block0 会被后续 done 覆盖、报 `noBlock0`。

### Kindle（`Views/Kindle/`、`Views/Reader/KindleReaderView.swift`、`Services/Kindle*`）

全项目最大子系统（`KindleBookView.swift` ~11k 行 + `KindleWebScripts.swift` ~7.8k 行）。**内容始终来自用户已登录的 read.amazon.com WKWebView**，CastReader 只持久化书籍元数据与本地阅读位置。

- `KindleWebScripts`：注入 read.amazon.com 的 JS 集合（书架扫描、翻页、TOC、页面渲染图抓取、布局探针）。**Amazon 频繁改 markup，选择器要写宽**。
- 页面渲染图 → tesseract-wasm OCR（按书籍语言 profile 单语言路由，含日文竖排 `jpn_vert`）→ `ReadingDocument(.kindle)`，图片段 + 词 bbox，朗读/解读复用同一管线。
- `KindleLibraryRecoveryService`：书籍失效时的一键同步恢复状态机。
- `KindlePlaybackCenter`：Kindle 自己的播放会话中心 + Mini Player + 保活升降（与 `PlayerCoordinator` 平行）。
- 跨端文档（**动 Kindle 前先读**）：`docs/Kindle适配-产品与技术方案.md`、`docs/Kindle朗读适配-问题与最终方案.md`、`docs/Kindle_TOC_跨端对齐实现指南.md`、`docs/Kindle下一页预加载与预生成跨端对齐指南.md`、`docs/Kindle听书会话与Whispersync进度跨端迭代指南.md`、`docs/Kindle失效书籍一键同步恢复跨端指南.md`。

### 微信读书（`Services/WeRead*`、`Models/WeReadModels.swift`、`Views/WeRead/`）

**live-render bridge，不是 API client**：WeRead 常把章节 DOM 画进 Canvas 后移除 DOM，所以在 document-start 抓取瞬时布局，且只用于当前可见页。**不 OCR、不保存章节正文、不存凭据。**

> **登录会话铁律**（`docs/WeRead-iOS-Login-Session-Contract.md`，2026-07-23 真机事故复盘）：二维码可见起到进入书架为止，**必须保留同一个 WKWebView 实例、同一个 document、同一个登录 UID**。禁止 `load`/`reload`/`goBack`/重建 WebView，禁止因深浅色变化、前后台切换、几何变化或 SwiftUI 重绘而重新导航。主题只能在**首次加载前**用 cookie/URL 准备；加载后改主题只允许设 `overrideUserInterfaceStyle`。当时的 bug 就是 `updateTheme(isDark:)` 在生命周期变化时重新 load，换掉了正在轮询的 UID → 微信显示扫码成功但 App 进不去。
>
> `wr_avatar`/`wr_name`/`wr_gender`/`wr_theme`/`wr_localvid`/`wr_fp` 是展示类 cookie，**不能单独用来判定已登录**。诊断日志只许记 cookie 名、页面可见性、导航次数、认证布尔值，**不得记 cookie 值 / UID / token**。

高亮与分页契约见 `docs/WeRead-iOS-Highlight-Pagination-Contract.md`；契约测试 `scripts/test-weread-ios-contract.mjs`（node 直接跑）。

### Google Play 图书（`Services/GoogleBooks*`、`Models/GoogleBooksModels.swift`、`Views/GoogleBooks/`、`WebReader/src/play-books.ts`）

第三个绑定书库，**复用 `.web` 渲染路径**（`WebReaderView` + `bundle.js` + `WebReaderBridge`），不 OCR、不存正文、不存凭据。方案全文见 `docs/GooglePlayBooks-iOS适配方案.md`（动之前先读）。三条铁律：

- **正文在跨源 iframe**（`books.googleusercontent.com/books/reader/frame`），主帧 `play.google.com` **只有阅读器 UI**。所以 bundle 用 `forMainFrameOnly: false` 注入所有帧；主帧只装 `window.CR` 转发壳（postMessage → 子帧），**绝不在主帧提取正文**。native 的 `evaluateJavaScript` 只到主帧，靠这层转发才能驱动子帧高亮。
- **`<p>.textContent` 是整章不是当前页**：Google 把整个 `.gb-segment` 渲进 `reader-rendered-page` 再裁剪分页。必须用 `visibleCharRange()` 的二分查找求可见字符区间，直接读 textContent 会一页读完整章。
- **翻页只认可见区指纹**（`playBooksSignature()`：几何 + segment 位移 + 文本头尾），确认超时**不重试**（重试点击会跳页）。跨页断句复用微信读书已验证的 `WeReadCrossPageSpeechContract`。

登录必须设完整 Mobile Safari UA（`GoogleBooksWebScripts.mobileSafariUserAgent`）——WKWebView 默认 UA 缺 `Version/… Safari/…`，Google 判为「不安全的浏览器」拒绝登录。

### 网页 / DOCX（`Views/Reader/WebReaderView.swift` + `Services/WebReaderBridge.swift`）

- `WebReaderView` 加载 URL 或本地渲染文件，注入 `WebAssets/bundle.js`（扩展同源的 DOM 高亮/标注 JS）。DOCX 在 WebView 内用 mammoth.js 转 HTML（**不上传后端**）。
- `WebReaderBridge`（WKWebView Coordinator）双向桥：JS→native `ready`/`rendered`/`paragraphTapped`/`log`/`error`；native→JS `CR.init`/`updateAudioSegments`/`updateSentenceHighlight`/`updateWordHighlight`/`scrollTo`/`setColor`/`setActive`。
- **TTS 全部在 native**（`ReadAloudViewModel` + `AudioPlayerService`），WebView 只负责渲染 + 高亮。
- `WebExtractionReadiness`：正文提取太弱（段落 < 3 或字符 < 200）时判为失败，走兜底。

### EPUB（原生解析渲染，含图片）—— `Services/EpubNativeEngine.swift`+`Utils/HtmlParser.swift`

弃 epub.js/WebView（整本 DOM 高亮 overlay + `setActive` flood → 性能崩），改纯本地原生解析（回译 Android `EpubNativeEngine.kt`/`HtmlParser.kt`）：

- `EpubNativeEngine.parse(data:)`：ZIPFoundation 解包 → `META-INF/container.xml` 找 OPF → SwiftSoup(`Parser.xmlParser()`) 解析 manifest+spine → 内嵌图片(media-type `image/*`)存 `[规范化href: Data]` → 按 spine 逐章 XHTML 经 `HtmlParser` 抽段落 → 合并、重排连续 id、图片相对 href 回填字节。**三套坐标统一相对 OPF 目录**（images key / 章节 href / `resolveImageHref` 输出）；`zipPath()` 才转 zip 根。`SwiftSoup.Document` 须显式限定（本仓库另有 `Models/Document.swift` 同名）。
- `HtmlParser.parse(xhtml)`：SwiftSoup 递归遍历 body 按 tag 分派（img/figure/h1-6/p/blockquote/pre/li/div），跳过 script/style/nav/toc/pageno；parse 开头全局 `remove` 噪声(linenum/pageno/dropcap)以免 per-element clone（SwiftSoup `copy()` 返 Node 非 Element）。
- 走 **TextReaderView 原生渲染**：图片段用 `EpubImageDecoder.downsampled`(ImageIO 缩略图降采样) 渲染。**图片段 text 置空但占 id**（保 index 连续 → mark 锚定/分批不错位），`isReadable=false` 朗读自动跳过封面图。大书 `Task.detached` 后台解析。自检 `CastReaderTests/EpubNativeEngineTests`。

### 系统分享 / Safari 扩展（`Services/ShareInbox.swift`、`SafariExtensionBridge.swift`、两个 extension target）

- **Share Extension**：`ShareViewController` 收 URL/文本/图片/PDF/EPUB/DOCX 写入 App Group 的 Share Inbox（`ShareInboxRecord`，带 `mode: read|explain`），主 app 经 `castreader://share-inbox` 唤起并在首页显示未读数。扩展自己也读 App Group 里的 `interfaceLanguage` 做本地化（与主 app 的 in-app 语言一致）。**占位标题存语义枚举而非译好的字符串**，这样切语言时历史记录跟着变。
- **Safari Extension**：`SafariExtensionBridge.syncFromApp()` 只往 App Group 写**最小身份/权益快照**（`isPro` 等）；**StoreKit 校验永远留在主 app**。
- 校验脚本：`scripts/verify_share_extension.rb`。

### 登录 / 账号（`Services/AuthService.swift`(+Apple)、`Models/UserAccount.swift`、`Views/Auth/`）

- **Google**：原生 `ASWebAuthenticationSession + PKCE` 直连 Google（**无第三方 SDK**），换 code→token→解析 id_token 得 email/name/picture/sub。`callbackURLScheme` 由会话内部拦截，**无需 Info.plist URL scheme**。
- **Apple**：SwiftUI `SignInWithAppleButton`（4.8 合规）。需 entitlement `com.apple.developer.applesignin`（`CastReader/CastReader.entitlements`）。
- best-effort 把 id_token 发 `POST /api/auth/sign-in/social`（better-auth）换后端 user id；失败不影响登录，Pro 退回 device_id 维度。资料存 UserDefaults，token 存 Keychain（`KeychainStore`）。

### Pro / 付费 / 额度（`Services/ProManager.swift`+`QuotaManager.swift`+`ProBackendService.swift`、`Views/Paywall/`）

- **综合 Pro**：`isPro = storeKitPro || serverPro`。iOS 主通道是 **StoreKit 2 内购**；Web 端用 **Stripe**，已付费者登录/设备关联后经 `serverPro` 同步到 iOS。一致性标准见 `docs/Pro一致性标准.md`。
- `GET /api/pro/status?device_id=&user_id=&local_date=` 回填 Pro + 额度；`POST /api/pro/listen-track` 上报朗读秒数；`POST /api/pro/verify-apple` 上报已签名的 StoreKit 2 transaction。`device_id` 复用 visitor id。`QuotaManager` 服务端值优先、fail-open 本地计数。
- 免费额度：每日 20min 朗读 / 3 次解读 / 仅基础音色 / 速度≤2.0x；本地午夜重置；「读完本篇」宽限 15min 硬上限。闸门检查点（仅额度处硬阻，出错 fail-open）：开始朗读/解读、选 Pro 音色、speed>2.0x。
- StoreKit：`Transaction.currentEntitlements` + `Transaction.updates`；`openManageSubscriptions`；本地测试用根目录 `Configuration.storekit`（Edit Scheme→Run→Options→StoreKit Configuration 关联，否则付费页显示「加载订阅…」）；生产 `ai.castreader.pro.{monthly,yearly}`。
- 首页 Pro 卡片规格见 `docs/Home-Pro-Upsell-Card-Spec.md`。

### 音色（`Models/VoiceCatalog.swift`、`Views/Settings/VoiceBrowserView.swift`）

服务端 catalog 驱动 + **静态九语兜底**：远端目录缺某语言时回落 `fallbackAll` 的离线默认（`status: "offline-default"`），保证首启/离线每种语言都有可用音色。改语言集合时记得升 `VoiceCatalogService.cacheKey`（当前 `tts_voice_catalog_v2_nine_language_cache`），否则旧缓存会盖掉新语言。

**声音克隆**（`VoiceClone*`）当前已开启：
`Constants.Features.voiceCloningEnabled = true`。创建文本可选，成功不等待固定试听；
global/CN 的 session、列表、缓存和资产不得互相恢复。完整跨端/后端合同以本文件顶部
强制入口指向的 `voice-clone-system-v1` 为准，不能根据这一段单独修改接口。

### 埋点（`Services/ProductAnalytics.swift`）

自研，双格式 payload（v2 字段权威 + legacy 键兼容已部署的 `/api/events`）。事件契约 `docs/analytics/mobile-events-v2.json`，校验脚本 `scripts/verify_mobile_analytics_contract.rb`，测试 `CastReaderTests/ProductAnalyticsTests.swift`。`validate` 同时做**必填字段校验**（如 `explain_start` 必带 `contentSource/contentFormat/language/scenario`）和**禁用字段校验**——`content`/`text`/`ocrText`/`fileName`/`title`/`url`/`urlPath`/`referrer`/`email`/`imageData`/`rawError`/`responseBody` 出现即抛错，不是静默剥离。加事件要同步改契约 + 测试。隐私边界见 `docs/CastReader-数据采集与隐私边界.md`。

### 上线前必填配置清单
- `Constants.API.quickReadAPIKey`（经 `Secrets.xcconfig`）：解读后端 `x-api-key`，否则 401。
- `Constants.GoogleOAuth.clientID`：已填；换环境时注意。
- App Store Connect 订阅产品 + scheme 关联 `Configuration.storekit`。
- Apple 开发者后台为 App ID 开启 Sign in with Apple capability。

## 测试与自检

```bash
xcodebuild test -workspace CastReader.xcworkspace -scheme CastReader -destination 'platform=iOS Simulator,id=<UDID>'
node scripts/test-weread-ios-contract.mjs      # 微信读书契约
ruby scripts/verify_mobile_analytics_contract.rb
ruby scripts/verify_share_extension.rb
```

`CastReaderTests/` 8 个文件 ~155 个测试：`CastReaderTests`（综合）、`EvalTests`（**朗读/解读数值自检，改完先跑这个**）、`VoiceCatalogTests`、`WebReaderEvalTests`、`EpubNativeEngineTests`、`PaymentTests`、`ProductAnalyticsTests`、`VoiceCloneTests`。

## 避坑指南 (iOS Best Practices)

1. **带关联值 enum 要手动 `: Equatable`** 才能用 `!=`/`==`（如 `ReadingParagraphType`、`TTSStatus`、`ExplainStatus`）。
2. **`CGFloat`/`UIColor` 等需 `import UIKit`**（SourceKit 单独分析新文件时常误报 "No such module 'UIKit'"/"Cannot find 'Constants'"，**以 `xcodebuild` 真实编译为准**）。
3. **`.greatestFiniteMagnitude` 在 `CGSize(...)` 里要写 `CGFloat.greatestFiniteMagnitude`** 否则 ambiguous。
4. iOS 16+ API（Layout 协议、presentationDetents、Charts）即便部署目标 17.6 也尽量少用，保持与既有防御式代码一致。
5. **复杂 View 拆 `@ViewBuilder` 子视图**避免类型检查超时（`KindleBookView`/`HomeView` 已经很大，新逻辑优先开新文件）。
6. `fileImporter` 的 `UTType` 用 `UTType(identifier:)` 安全创建（epub/docx 可能未内置）。
7. API 字段类型可能不一致/为 null → Model 用可选 + 自定义解码；解码失败先打印原始响应 + `error`（含 codingPath）。
8. 含空格的 URL 必须 `addingPercentEncoding` 否则 `URL(string:)` 返回 nil。
9. **同屏多个 `.sheet` 会互相吞**——同一个 View 上多个 sheet 请合并成单个 `item:` 驱动的 sheet，或改用 `confirmationDialog`。
10. **绑定书库的 WKWebView 是有状态资产**：别为了刷新 UI 去 reload/重建，别在离屏时让它经历旋转/reflow（见 WeRead 铁律与 `AppOrientationLock`）。

## TTS 引擎 — 仅云端（本地 Kokoro/FluidAudio 已移除）

曾有本地 Kokoro CoreML 引擎（FluidAudio/FluidAudioTTS + ESpeakNG），为减小包体积（约 -35MB）已**整体移除**——现仅云端 TTS。`AudioSegment.isWavFormat` 字段保留但恒为 false（云端均 mp3）。如需恢复离线引擎，参考 git 历史的 `LocalTTSService` / `ModelDownloadService` / `TTSModelSettingsView` 及 `TTSProvider` 路由 + SPM FluidAudio 依赖。

## TTS 文本渲染 — 直接渲染 TTS 文本，不映射回原文

TTS 返回的 `processedText` 与原文有差异（标点/空格规范化）。**不要把 timestamps 映射回原文**（会找不到/不同步）。朗读当前段渲染 `processedDisplayText`（segments 的 `text` 拼接），高亮在其中按词定位；未生成段落渲染 `paragraph.text`。`AudioSegment{text, timestamps:[TTSTimestamp{word,start,end}], unprocessedText, speaker?}`。

## TTS 播放竞态 — `moreSegmentsExpected` 标志

流式生成时音频可能播得比生成快。`AudioPlayerService`：队列空但 `moreSegmentsExpected==true` 时置 `waitingForNextSegment` 等待，新 segment 到达继续；`==false` 才 `onPlaybackComplete`。VM 端：生成前 `clearQueue()` + `moreSegmentsExpected=true`，生成完/出错都要复位 `false`；切段先 `cancelCurrentRequest()`。

**内存警告不得停播**：`hasActivePlayback` 时忽略 `didReceiveMemoryWarning` 的 `clearQueue()`——播放队列是活跃音频管线，不是可丢缓存。

## 自动滚动

`TextReaderView` 用 `ScrollViewReader`：朗读时 `currentParagraphIndex` 变化滚到该段（`anchor:.center`）；解读时滚到最新 mark 所在段。photo 模式整页可见无需滚动。
