# AGENTS.md

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

完整提交指令默认授权：读取 App Store Connect 当前版本与最大 Build → 更新版本号 → 测试/归档/签名 → 上传并等待 `VALID` → 创建新版本 → 八语 App Info 与版本元数据 → 截图/审核资料/合规检查 → 绑定 Build → Review Submission → 状态回读。不要只停在打包、上传或保存草稿。

项目内 SOP 见 `docs/iOS-AppStore-Release-SOP.md`，八语文案源为 `docs/CastReader-AppStore-Metadata-8-Languages.md`。不得输出 `.p8`、JWT 或签名凭据，不得为过审擅自修改价格、订阅、地区、App Privacy、年龄分级或法律声明。

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

## TTS 引擎 — 仅云端（本地 Kokoro/FluidAudio 已移除）

曾有本地 Kokoro CoreML 引擎（FluidAudio/FluidAudioTTS + ESpeakNG 多语言发音字典），为减小包体积（约 -35MB，包 45M→10M）已**整体移除**——现仅云端 TTS（`TTSService` → `APIService.generateTTS` 单声道流式）。`AudioSegment.isWavFormat` 字段保留但恒为 false（云端均 mp3）。如需恢复本地/离线引擎，参考 git 历史的 `LocalTTSService` / `ModelDownloadService` / `TTSModelSettingsView` 及 `TTSProvider` 路由 + SPM FluidAudio 依赖。

## TTS 文本渲染 — 直接渲染 TTS 文本，不映射回原文

TTS 返回的 `processedText` 与原文有差异（标点/空格规范化）。**不要把 timestamps 映射回原文**（会找不到/不同步）。朗读当前段渲染 `processedDisplayText`（segments 的 `text` 拼接），高亮在其中按词定位；未生成段落渲染 `paragraph.text`。`AudioSegment{text, timestamps:[TTSTimestamp{word,start,end}], unprocessedText, speaker?}`。

## TTS 播放竞态 — `moreSegmentsExpected` 标志

流式生成时音频可能播得比生成快。`AudioPlayerService`：队列空但 `moreSegmentsExpected==true` 时置 `waitingForNextSegment` 等待，新 segment 到达继续；`==false` 才 `onPlaybackComplete`。VM 端：生成前 `clearQueue()` + `moreSegmentsExpected=true`，生成完/出错都要复位 `false`；切段先 `cancelCurrentRequest()`。

## 自动滚动

`TextReaderView` 用 `ScrollViewReader`：朗读时 `currentParagraphIndex` 变化滚到该段（`anchor:.center`）；解读时滚到最新 mark 所在段。photo 模式整页可见无需滚动。舒适区精细化（15%~70% + 手动打断回弹）可后续按需加。
