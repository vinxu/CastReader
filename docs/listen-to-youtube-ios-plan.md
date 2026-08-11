# Listen to YouTube — iOS 产品方案（可执行版）

> 2026-08-09 定稿。目标读者：执行落地的 Agent。
> 核心链路：**接收 YouTube 链接 → 端上 WKWebView 加载 → 字幕稿朗读（高亮跟随）**。
> 本文档自包含：架构决策、精确集成点、验收标准、合规红线全部在内。执行前先读 §0 的必读文件。

> **完成更新（2026-08-10）**：iOS 已完成实现、自动化、真实 iPhone 安装与用户验收；问题链接 `wpb-DrbhEiY` 已可朗读 907 条字幕 cue，高清封面与自适应 storyboard 展示已通过用户确认。最终实现、全部问题复盘和 Android 增量基线见 `docs/listen-to-youtube-implementation-retrospective.md` 与 `docs/listen-to-youtube-ios-to-android-handoff.md`。下方原始 checklist 保留为立项时验收设计，不用其未回填勾选状态覆盖最终证据记录。

> **最终差异更新（2026-08-11）**：歌词末词高亮、首页入口架构、字幕解析效率、字幕正文语言判别，以及 Android 登录/超时/网络阻挡处理，见 `docs/listen-to-youtube-ios-android-final-alignment.md`。该文档是 Android 后续执行的最高优先级增量合同。

---

## 0. 执行前必读（按顺序）

| 文件 | 读什么 |
|---|---|
| `CastReader/Views/Reader/WebReaderView.swift` | WKWebView 宿主的现有形态（Kindle/Kobo/GoogleBooks 共用） |
| `CastReader/Services/KindleWebScripts.swift` | **平台注入脚本的既定模式** —— YouTube 照此新建 |
| `CastReader/Services/LiveWebPlatform.swift` | 平台枚举/路由，YouTube 需要注册进去 |
| `CastReader/Services/TTSEndpoint.swift` + `AudioPlayerService.swift` | partly 流式 TTS 契约与播放编排（复用，不改） |
| `CastReader/Models/ReadingDocument.swift` | 文档数据模型，字幕稿要适配成它 |
| `CastReader Share Extension/ShareViewController.swift` | 分享入口与 App Group 交接（`group.com.same.castreader`） |
| `CastReader/ViewModels/ClipboardImportViewModel.swift` | 剪贴板检测（只探测不读取的隐私模式，勿破坏） |
| `readout-desktop/src/entrypoints/youtube-bridge.content.ts` | **字幕提取的真源实现**（浏览器扩展，已线上验证） |
| `readout-desktop/src/extractors/youtube.ts` | cue→段落分组算法（直接移植） |

**禁改区**：Kindle / WeRead 相关路径按最小改动原则，本功能不得触碰其任何文件。

---

## 1. 背景与目标

### 1.1 为什么做
- 浏览器扩展端 YouTube 字幕朗读已上线并实测通过（有字幕读字幕、无字幕读页面）。
- 移动端把链路缩到「分享 → 自动开播」，是 Kindle 绑定模式的第二次复用。
- 差异化在跨语言（外语视频用母语听），本期 v1 只做原文朗读，翻译是 P2（见 §8）。

### 1.2 数据上下文（诚实版）
- 扩展端 YouTube 使用量小（90 天 104 台设备），历史 D7≈0%。本功能是**战略押注**，不是数据驱动的必然。
- 因此**成本控制是一等要求**：最大化复用、不建新服务端、不做投机功能。

### 1.3 成功指标（上线 4 周评估）
| 指标 | 目标 |
|---|---|
| 分享→首音 p50 | **< 5s**（p95 < 12s） |
| 有字幕视频提取成功率 | ≥ 90% |
| 走完首个视频 ≥3 分钟的设备占比 | 基线建立（无历史参照） |
| Crash-free | 不低于现有版本 |

---

## 2. 产品定义

### 2.1 用户链路（主）
```
YouTube App / Safari 看视频
 → 系统分享面板 → 选 CastReader          （用户仅 2 次点击）
 → 主 App 打开，后台并行：
     WKWebView 静默加载视频页 → 注入 bridge → 拿到字幕 cues
     → 首段 TTS 生成（partly 流式）
 → 自动开播：字幕稿视图 + 逐段高亮 + 自动滚动
```

### 2.2 入口体系与发现性设计（⚠️ 核心产品决策）

**问题**：分享/贴链接是最短使用链路，但 iOS 用户无法「发现」它——分享面板里的 CastReader 要滚动才能看到，没人会知道这个功能存在。Kindle 的发现性来自「首页有专栏入口 + 首次进入有连接引导」，用户一用就懂。**YouTube 必须复制同一结构，双轨并行：专栏管发现，分享管效率。**

| 轨道 | 角色 | 实现 |
|---|---|---|
| **① 首页 YouTube 专栏卡**（发现性主载体） | 用户知道"这个 App 能听 YouTube" | 与 Kindle/Kobo/Google Books 并列的平台入口，点进 `YouTubeHomeView` |
| ② 系统分享（最短链路） | 学会之后的日常路径 | Share Extension，2 次点击开播 |
| ③ 剪贴板检测 | 兜底 | `ClipboardImportViewModel` 命中 YouTube URL → 弹「听这个视频？」 |
| ④ URL Scheme | 跨端唤起预留 | `castreader://youtube?url=<encoded>` |

**`YouTubeHomeView`（专栏页）三个区块：**

1. **首次引导**（对标 `KindleFirstLaunchFlowView` 的模式）：
   - 1-2-3 图解教学：「在 YouTube App 点分享 → 选 CastReader → 自动开始朗读」；
   - **「试听一个示例」按钮**：预置一条有字幕的公开视频链接，一键体验完整流程——用户不需要先学会分享手势就能感受到价值（这是把 Kindle "连接即懂" 的瞬间移植过来的关键）；
   - 引导只在未完成首次收听前展示，完成后折叠为顶部小条。
2. **粘贴框**：输入/粘贴链接直接开听（常驻）。
3. **收听历史**：听过的视频列表 = YouTube 的「书架」（标题/时长/进度/是否已缓存），支持续听与离线回放。这是回访的家——没有它，每次使用都要重新找入口。

**首次分享成功的 aha 时刻**：用户第一次通过分享进入并开播时，弹一次性提示「以后在 YouTube 里点分享就能听」，完成教学闭环。

**全局迷你播放器**：离开专栏页继续播放时沿用 `KindleMiniPlayerView` 的既有模式，不新造。

### 2.3 URL 识别规则（v1 全集）
```
youtube.com/watch?v={id}     youtu.be/{id}
youtube.com/shorts/{id}      m.youtube.com/watch?v={id}
携带 &t=123s / ?t=123 → 从该时间点所在段落开始朗读（免费的加分体验）
播放列表链接 → 只取当前 v= 的单视频
```

### 2.4 范围（In / Out）

**In（v1）**
- 有字幕视频（人工或自动生成字幕均可）的原文朗读
- 字幕稿视图：段落高亮、自动滚动、点段跳播、倍速、换声音（全部复用现有播放器控件）
- 每段「回视频」深链：`youtube://watch?v={id}&t={sec}`（未装 YouTube App 则回落 Safari）
- 进度记忆（`HistoryStore` 既有机制）
- 已生成音频段 + 字幕稿本地缓存（回放不重复计费/重复生成）

**Out（明确不做，v1 红线）**
- ❌ ASR 语音识别（需下载音频流 = ToS + App Store 5.2.3 双重红线）
- ❌ 任何视频/音频流下载
- ❌ 翻译朗读（P2，见 §8）
- ❌ YouTube 账号 OAuth 绑定
- ❌ 直播（live）视频
- ❌ 「offline YouTube」类措辞（合规见 §6）

### 2.5 失败场景与文案（诚实失败，宁可不支持）

| 场景 | 检测方式 | 用户文案（键名建议） |
|---|---|---|
| 无字幕 | bridge 返回空轨列表 | `ytNoCaptions`：「这个视频没有字幕，无法朗读」 |
| 直播 | 页面 isLive 标记 | `ytLiveUnsupported`：「暂不支持直播视频」 |
| 年龄限制/登录墙 | 播放器错误容器出现 | `ytRestricted`：「该视频需要登录 YouTube 查看，无法解析」 |
| 地区限制/下架/私享 | 播放器错误容器 | `ytUnavailable`：「该视频不可用」 |
| 提取硬超时（42s；正常目标仍 <5s） | 计时器 | `ytTimeout`：「解析超时，请重试」+ 重试按钮 |
| Cookie 同意墙（欧盟） | consent 域名重定向 | 归入 `restricted`，不得伪装成解析超时 |

所有失败**不得**降级为"读页面杂讯"——App 内没有"当前页面"语境，读碎片文本是负体验。这与扩展端行为（读页面兜底）刻意不同。

---

## 3. 技术方案

### 3.1 架构总览
```
ShareViewController ──App Group──▶ 主App 路由
                                     │ parseYouTubeURL()
                                     ▼
                    YouTubeTranscriptService（新）
                    ├─ 离屏 WKWebView（桌面内容模式, 1280×800）
                    ├─ 注入 YouTubeWebScripts（新, vendored bridge）
                    ├─ dataset/事件协议 ◀──▶ bridge
                    └─ 输出 [TranscriptCue]
                                     │ cuesIntoParagraphs()
                                     ▼
                    ReadingDocument 适配 ──▶ 现有 TTS/播放/视图栈
                    （TTSEndpoint partly 流式 + AudioPlayerService
                      + Reader 高亮视图 + HistoryStore 进度）
```

**核心决策：字幕在端上解析，禁止服务端解析。** 服务端拉 YouTube = 数据中心 IP 封锁 + pot 校验军备竞赛 + ToS 暴露主体变成我们。端上 WebView 以用户设备 IP、真实会话请求，与用户自己开浏览器无差别。这是 Kindle 已验证的模式。

### 3.2 模块 A：入口层（改 3 个文件）

**A1 `ShareViewController.swift`**
- `Info.plist` 激活规则补 `NSExtensionActivationSupportsWebURLWithMaxCount = 1`（现仅 File/Image/Text）。
- 收到 URL → 命中 §2.3 规则 → 写入 App Group（`group.com.same.castreader`）键 `pendingYouTubeURL` → `openURL` 唤起主 App。
- 未命中 YouTube 规则的 URL 走现有逻辑，零行为变化。

**A2 `ClipboardImportViewModel.swift`**
- 在既有 `looksLikeURL` 细分后追加 YouTube 判定；保持"只探测不读取"的隐私模式不变。

**A3 主 App 启动路由**
- `CastReaderApp.swift`（或现有 deep-link 处理处）消费 `pendingYouTubeURL`，进入 YouTube 收听流程。

### 3.3 模块 B：提取层（新建 2 个文件，核心工作量）

**B1 `Services/YouTubeWebScripts.swift`（模式抄 `KindleWebScripts.swift`）**

注入脚本 = **vendored 自扩展仓库的 bridge**，这是硬性要求：
- 来源：`readout-desktop` 构建产物中的 `youtube-bridge` 编译 JS（非手写重实现）。
- 文件顶部注释必须记录来源 commit hash，升级时整体替换。
- 两端共用一份提取逻辑 ⇒ YouTube DOM 变更时坏一起坏、修一次全好。

bridge 的既有协议（isolated↔main world，iOS 端沿用同一契约）：

| 通道 | 键/事件 | 语义 |
|---|---|---|
| `document.body.dataset` | `crYtTracks` | 字幕轨列表 JSON |
| | `crYtTracksVideoId` | 轨列表对应的 videoId |
| | `crYtTracksPending` | 拦截等待中标记 |
| | `crYtTranscript` | `{cues:[{text,startMs,durationMs}],log:[]}` |
| | `crYtFetchUrl` / `crYtFetchResult` | main-world 代理 fetch |
| 事件 | `__cr_yt_transcript_req__` → `__cr_yt_transcript_res__` | 请求/完成信号 |

iOS 侧另注入一段**适配器脚本**（新写，~30 行）：监听 `__cr_yt_transcript_res__` → `webkit.messageHandlers.crYt.postMessage(dataset.crYtTranscript)`，Swift 端由 `WKScriptMessageHandler` 接收。

**B2 `Services/YouTubeTranscriptService.swift`**
- 离屏 `WKWebView`：frame 1280×800（不上屏）；使用 `.preferredContentMode = .desktop` 请求桌面 DOM，但**不伪造 Chrome `customUserAgent`**。YouTube 的 BotGuard/PO-token 会校验浏览器指纹，iOS WebKit 伪装成 macOS Chrome 会导致官方 timedtext 请求表面返回 HTTP 200，实际响应为空。
- 官方字幕模块产生的 decorated timedtext URL 必须在主世界内存中保留（不得记录完整 URL/PO token），严格校验 video/language/kind 后按 `json3 → srv3 → 无 fmt` 重试。这是 2026-08-10 真机回归 `wpb-DrbhEiY` 能稳定取得 907 条 cue 的关键。
- 生命周期：document-start 安装媒体静默、vendored bridge 与 native adapter → 加载 `watch?v={id}`；native 硬上限 42s，adapter 预算 34.5s，字幕面板等待上限 24s。正常成功仍以 <5s 为目标，长预算只服务于页面 fallback 和诚实分类。
- 失败分类按 §2.5 检测顺序执行：先查播放器错误容器（restricted/unavailable/live），再看空轨（no_captions），最后 timeout。
- 2026-08-10 真实回归 `wpb-DrbhEiY`：匿名页面返回明确的 bot-verification `LOGIN_REQUIRED`，player response 不含 video ID/字幕轨，但同页 `ytInitialData` 仍含精确 video ID 与 transcript endpoint。适配器必须用这组严格匹配证据进入 transcript-panel fallback；若页面字幕请求仍被 YouTube 拒绝，则返回 `restricted`，绝不能返回 `player_timeout`。登录/机器人验证证据必须跨 runtime `UNPLAYABLE` 覆盖持续保留，并在正常流程、adapter 看门狗和异常终止三条路径上都优先于 timeout/unavailable/malformed 分类。
- 提取字幕的同时顺带采集视图头部所需元数据：`og:image` 缩略图 URL（下载一次缓存本地）、`og:title`、频道名（可得则取，不可得留空）——WebView 销毁后无法补采。
- **同时采集 storyboard 规格**（画面跟随功能的数据源，见 §3.6）：读取主世界 `ytInitialPlayerResponse.storyboards.playerStoryboardSpecRenderer.spec`（进度条预览帧的 sprite 图集模板）。实现方式：iOS 侧**补充注入脚本**（`WKUserScript` 默认运行在页面主世界，可直读该对象），经 `webkit.messageHandlers` 回传——**不修改 vendored bridge**，保持与扩展共用文件的纯净性。采不到（部分受限视频）则置空，画面跟随自动降级为静态缩略图。
- 成功后**立即销毁 WebView**（内存红线：视频页很重，绝不常驻）。
- 单飞行请求：同一时刻只允许一个提取任务，新请求取消旧任务。

### 3.4 模块 C：分段与数据模型（新建 1 个文件）

`Models/YouTubeTranscript.swift`：
```swift
struct YouTubeTranscriptCue { let text: String; let startMs: Int; let durationMs: Int }
struct YouTubeTranscriptDoc {
  let videoId: String; let title: String; let language: String?
  let cues: [YouTubeTranscriptCue]
  let paragraphs: [Paragraph]   // 每段保留 startMs（跳播/回视频/画面跟随的锚）
  let storyboard: YouTubeStoryboard?   // 无则画面跟随降级为静态缩略图
}

/// 进度条预览帧图集：spec 模板 → N 张 sprite 大图，每张按行列切成小帧，等间隔覆盖全片。
struct YouTubeStoryboard {
  let sheetURLTemplate: String   // 由 spec 解出，$L/$N 占位
  let tileWidth: Int; let tileHeight: Int
  let columns: Int; let rows: Int
  let intervalMs: Int            // 相邻帧的时间间隔
  let sheetCount: Int
  /// 核心查询：某时间点 → (第几张 sprite, 图内裁剪矩形)
  func frame(atMs: Int) -> (sheetIndex: Int, cropRect: CGRect)
}
```

storyboard spec 解析注意：格式有版本变体（`storyboard3_L$L/$N` 等），解析必须**防御式**——解不出就返回 nil 走降级，绝不让画面跟随的解析失败阻塞主流程（字幕朗读永远不依赖它）。在 sheet 数量、像素尺寸和缓存上限内选择**像素面积最大的合法层级**，不能固定 L2；YouTube 当前会给出 L3+，固定 L2 可能只得到 160×90 的单帧。

分组算法**逐行移植** `readout-desktop/src/extractors/youtube.ts` 的 `cuesIntoParagraphs`：
- 按 `startMs` 排序 → 相邻 cue 间隔 > **2000ms** 或累计 > **150 字符** 断段；
- 每段 `startMs` = 组内首 cue 的 startMs。
- 不要"改进"参数——这套值已在扩展端调过。

适配 `ReadingDocument`：每段落携带 `startMs` 作为自定义锚数据（参考 Kindle 文档如何带页锚）。

### 3.5 模块 D：TTS 与播放（复用，仅接线）

- 走 `TTSEndpoint.swift` 的 `captioned_speech_partly` 流式契约：首段生成即播，后续边生成边播。**不新建任何 TTS 路径。**
- 语言：用字幕轨自带语言码；⚠️ **`voice_code` 字段只在中/英时传**，其他语言不传（既有服务端契约，违反会出错）。
- 额度：接 `QuotaManager` / `pro/listen-track`，YouTube 朗读计入统一收听时长。免费 20 分钟/天的墙照常生效——不为 YouTube 开任何旁路。

### 3.6 模块 E：视图层（新建 2 个视图，控件全复用）

**E1 `Views/YouTube/YouTubeHomeView.swift`（专栏页，发现性载体）**
- 三区块见 §2.2：首次引导（含示例视频按钮）/ 粘贴框 / 收听历史。
- 首页平台入口注册：跟随 Kindle/Kobo 卡片的现有排布方式（`MainTabView.swift`），放在 Kindle 之后。
- 历史数据源：`HistoryStore` + 缓存索引（§3.7），不新建存储。
- 示例视频：链接放远程配置或常量（可运营更换），必须选**长期有效、有人工字幕**的公开视频。

**E2 `Views/YouTube/YouTubeListenView.swift`（收听视图）**

**⚠️ 决策记录：朗读界面是原生字幕稿视图，不是 YouTube 页面的 WebView。**

扩展在桌面上高亮 YouTube 原生 transcript 面板，是因为用户本来就在 youtube.com 上；这个方式**不能平移到 iOS**，四个硬理由：
1. **排版不可读**：提取依赖桌面 DOM（桌面 UA），把桌面版 YouTube 塞进手机屏 = 缩小的侧边栏字幕面板，作为主阅读面完全不合格；
2. **双音频冲突**：页面里的视频播放器与 TTS 抢声道，只能强制暂停视频——用户面对一个冻结的播放器听 TTS，状态诡异；
3. **内存/电量**：保活整个 watch 页（视频缓冲、广告、推荐流 JS）对移动端是持续消耗，Kindle 能保活是因为书页是静态的；
4. **离线与审核**：缓存回放必须原生渲染（WebView 无法离线）；且「界面就是字幕稿」直接支撑 §6 的 transcript reader 审核定性。

因此：WKWebView 仅在提取的 ~3-5 秒内离屏存在，随后销毁（§3.3）；用户全程只看到原生视图。

**界面规格（线框）：**
```
┌──────────────────────────────┐
│ ◀ 返回                    ⋯ │
│ ┌──────────────────────────┐ │
│ │  当前段画面(storyboard帧) │ │ ← 画面跟随:显示当前朗读段 startMs
│ │                    04:32 │ │    对应的视频帧,换段时交叉淡入
│ └──────────────────────────┘ │    点击 = 跳回 YouTube 该时间点
│ 视频标题（≤2 行）             │
│ 频道名 · 字幕稿               │ ← "字幕稿"字样常驻(合规定性)
├──────────────────────────────┤
│ 02:15  已读段落，常规样式      │
│                              │
│▌04:32  当前朗读段：高亮背景 + │ ← 自动滚动保持在视口 25-75% 安全区
│▌       左侧强调条             │    (滚动规则与扩展端一致)
│                              │
│ 06:01  未读段落…              │
├──────────────────────────────┤
│  ▶︎  ────●────  1.5×  声音   │ ← 复用现有播放控制条
└──────────────────────────────┘
```

**交互规则（点击目标严格分离，防误触跳出 App）：**
- 点**段落文字** = TTS 跳播到该段（App 内行为）；
- 点**时间戳 chip** = `youtube://watch?v={id}&t={startMs/1000}s` 回视频（跨 App 行为；`canOpenURL` 失败回落 https；`LSApplicationQueriesSchemes` 加 `youtube`）；
- 点**缩略图** = 回视频，取当前朗读段的时间点。

**同步机制（微妙但关键）**：高亮由 **TTS 播放进度驱动**（partly 分段的 `paragraphIndex`，与全产品现有模型一致），**不与视频时间轴对齐**——TTS 语速（尤其倍速下）≠ 视频语速，`startMs` 只作为跳播锚点和回视频锚点，绝不作为同步目标。试图对齐视频时间轴是 P3 配音方向的事，v1 严禁引入。

**画面跟随（storyboard follow）**：头部画面按 `storyboard.frame(atMs: 当前朗读段.startMs)` 取帧，时间戳角标同步更新。这让"听到哪、画面到哪"，且完全不播放视频。storyboard 是 YouTube 进度条预览小图，不是原视频 HD 截帧，因此采用自适应清晰度布局：达到物理显示宽度 80% 像素覆盖时可全宽显示；不足时用高清封面作全宽主图、当前 storyboard 帧作较小同步画中画，切帧淡入约 150ms。规则：
- 驱动源仍是 `paragraphIndex` 换段事件——**离散的按段换帧**，不做帧级连续动画（那又变成伪播放器了）；
- sprite 图集**懒加载**：先取当前段所在 sheet，前后各预取 1 张；下载失败静默保持上一帧；
- 无 storyboard（受限视频/解析失败）→ 降级为最高可用静态缩略图，功能不缺失只是画面不动；
- 缩略图候选合并 player response、microformat 与 `og:image`，按声明像素或标准文件名推断值选择最高分辨率；
- artwork 独立版本化，升级选层策略时只刷新字幕元数据与图片资源，既有 TTS 音频和阅读进度继续复用；
- 图集随字幕稿一并缓存（§3.7），离线回放画面照常跟随；
- 手动滚动浏览列表时头部**不**跟随滚动位置，仍锚定正在朗读的段（滚走了会有"回到当前位置"浮钮，沿用现有 Reader 惯例）。

**三个状态：**
1. **解析中**：字幕稿骨架屏 + 「正在解析字幕…」+ 取消按钮（目标 <5s，见 §1.3；首段 TTS 在此期间并行预生成）；
2. **播放中/暂停**：如线框；
3. **离线回放**：顶部小徽标「已缓存」，全功能可用（原生渲染的直接收益）。

**不出现在界面上的东西（刻意）**：视频播放器本体、评论、推荐流、任何 YouTube 页面元素。

- 入参带 `t=` 时：定位到该时间所属段落开始朗读。
- **锁屏/后台行为：严格跟随现有 Kindle 收听的行为，不引入新语义。**（执行时先实测 Kindle 现状并在 PR 描述里写明。）

### 3.7 模块 F：缓存

- Key：`videoId + trackLang`。内容：字幕稿 JSON + 已生成 mp3 段 + 缩略图 + storyboard sprite 图集（已下载的 sheet）。
- 上限：LRU 50 个视频或 500MB，先到先清。
- 回放已缓存内容不再计额度（与现有"重播不重复计费"语义一致，若现状不同则跟随现状）。

### 3.8 模块 G：埋点（⚠️ 三处同步铁律）

新事件（沿用移动端命名风格，最终以 `mobile-event-contract.ts` 现有风格为准）：

| 事件 | 时机 | 关键字段 |
|---|---|---|
| `yt_share_received` | 入口收到链接 | `entry: share/clipboard/scheme/paste/sample` |
| `yt_home_view` | 专栏页曝光 | `first_time: bool`（评估发现性漏斗的分母） |
| `yt_extract_done` | 提取成功 | `cue_count, paragraph_count, lang, elapsed_ms` |
| `yt_extract_fail` | 提取失败 | `reason: no_captions/live/restricted/unavailable/timeout` |
| 朗读事件 | 复用现有 `reading_start/…` | `source: 'youtube_ios'`（沿用现有 source 枚举风格） |

**必须同步三处**，缺一则事件静默丢失：
1. iOS 客户端发射
2. `readout-web/src/shared/analytics/mobile-event-contract.ts`
3. 服务端 `/api/events` 白名单（`VALID_EVENTS`）

### 3.9 隐私
- WebView 只加载用户明确分享的 URL；不注入任何浏览历史采集。
- 字幕文本仅发送至现有 TTS API 生成音频（与所有平台一致）；不落我们的服务器存储。
- 隐私清单（PrivacyInfo）如声明数据类型，本功能不新增类别。

---

## 4. 里程碑与验收

### M1 — 提取链路（预计 3-4 天）
交付：分享/剪贴板 → 提取成功 → 控制台输出段落。
验收：
- [ ] §2.3 全部 URL 形态解析正确（单测覆盖）
- [ ] 有字幕视频（人工字幕 ×3、自动字幕 ×3、中英日各 ≥1）提取成功
- [ ] §2.5 六类失败场景分类正确（无字幕/直播/年龄限制视频各实测 1 个）
- [ ] 提取后 WebView 确认销毁（Instruments 无泄漏）

### M2 — 播放闭环 + 专栏页（预计 5-6 天）
交付：自动开播 + 高亮 + 跳播 + 回视频 + 进度记忆 + `YouTubeHomeView`。
验收：
- [ ] 首页出现 YouTube 专栏卡；首次进入展示引导，「试听示例」一键走完整流程
- [ ] 粘贴框 / 剪贴板条 / 分享 三种入口都能到达同一收听视图
- [ ] 收听历史列表正确显示进度与缓存态，点击续听
- [ ] 分享→首音 p50 < 5s（10 次实测中位）
- [ ] 高亮逐段跟随、点段跳播准确
- [ ] 画面跟随：换段时头部帧与时间戳同步更新（storyboard 视频）；无 storyboard 视频降级为静态图不报错；离线回放画面照常跟随
- [ ] `t=` 入参从正确段落开播
- [ ] 回视频深链到达正确时间点（装/未装 YouTube App 两态）
- [ ] 杀 App 重进，进度恢复
- [ ] 额度计入验证：朗读 2 分钟后 `pro/status` 的 `listenSeconds` 增长一致

### M3 — 打磨与合规（预计 2-3 天）
- [ ] 缓存命中回放不再请求 TTS
- [ ] 埋点三处同步完成，`yt_extract_done/fail` 在服务端可查
- [ ] 全部失败文案 i18n（至少 en/zh）
- [ ] §6 合规清单逐项过

**真机测试矩阵**（M2/M3 各跑一遍）：
人工字幕长视频 / 自动字幕 / 无字幕 / Shorts / 直播 / 年龄限制 / 带 t= 链接 / 弱网（3G 档）/ 飞行模式回放缓存。

---

## 5. 风险与预案

| 风险 | 概率 | 预案 |
|---|---|---|
| YouTube 桌面 DOM 变更导致 bridge 失效 | 中 | 与扩展共用同一 bridge：扩展端先坏先修，iOS 换 vendored 版本即可；`yt_extract_fail` 突增做告警信号 |
| WKWebView 中 consent/登录/反机器人墙 | 中 | 先尝试严格 video-scoped transcript fallback；失败明确归入 `restricted`，并监测 `yt_extract_fail` 地区分布 |
| storyboard spec 格式变体解析失败 | 中 | 防御式解析，失败即降级静态缩略图；朗读主流程零依赖 |
| 视频页内存峰值 | 中 | 离屏 WebView 用完即毁；单飞行任务；M1 验收含泄漏检查 |
| App Store 审核质疑 | 低-中 | §6 措辞 + 审核备注模板；功能定性 transcript reader |
| 需求不及预期 | 高（已知） | 成功指标 4 周评估；扩展端 Phase 0 探针并行收集跨语言需求 |

---

## 6. App Store 合规清单（提审前逐项确认）

- [ ] 全部文案/截图/关键词**不出现** "offline YouTube" / "download" / "背景播放 YouTube" 类表述
- [ ] 功能命名与描述定性为「**字幕稿朗读 / transcript reader**」
- [ ] 不下载、不缓存、不重放任何视频/音频流（只有我们自己 TTS 生成的音频）
- [ ] 无字幕视频明确失败，不存在任何"绕过"路径
- [ ] 审核备注模板：*"This feature reads the publicly available caption text of a user-shared video aloud using our own TTS voices, with the transcript displayed on screen. It does not download, extract, or play back any video/audio stream from YouTube."*

---

## 7. 已知问题与刻意取舍（执行时不要"顺手修"）

1. 欧盟 consent 墙不自动点击——明确返回 `restricted` 并观察 fail 分布。
2. 无字幕视频不做 ASR——红线，永不"顺手加"。
3. 翻译朗读不在 v1——见 §8，勿提前实现。
4. Android 不在本文档范围——iOS 数据出来后另立方案。

## 8. P2 方向备忘（本期不做）

- **翻译朗读**：YouTube timedtext 自带 `tlang` 机器翻译轨，零翻译基建可做「外语视频用母语听」；质量不足再换自有 LLM 翻译。这是本功能真正的差异化，等 v1 建立基线后评估。
- 扩展端 Phase 0 跨语言需求探针（复用 `foreign-prompt-gate`）与本方案并行，不互相阻塞。

---

## 9. 交接注意事项

- 仓库：`~/Documents/CastReader`（Xcode 工程 `CastReader.xcworkspace`）。
- 构建/测试沿用仓库现有方式（先看 `CastReaderTests/` 的既有测试组织；bridge 协议、URL 解析、分段算法必须有单测）。
- 新增文件清单（预期全部改动面）：
  - 新建：`Services/YouTubeWebScripts.swift`、`Services/YouTubeTranscriptService.swift`、`Models/YouTubeTranscript.swift`、`Views/YouTube/YouTubeHomeView.swift`、`Views/YouTube/YouTubeListenView.swift`、bridge vendored JS 资源
  - 修改：`ShareViewController.swift`、Share Ext `Info.plist`、`ClipboardImportViewModel.swift`、`CastReaderApp.swift`（路由）、`LiveWebPlatform.swift`（平台注册）、主 App `Info.plist`（`LSApplicationQueriesSchemes` + `youtube`）
  - 跨仓库：`readout-web` 的 `mobile-event-contract.ts` + 服务端事件白名单
- 完成 M1/M2/M3 各里程碑后停下汇报，不要一口气做完再交付。
