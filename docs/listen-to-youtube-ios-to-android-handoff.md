# Listen to YouTube：iOS 完成态与 Android 对齐交接

> 更新日期：2026-08-11  
> 上游方案：`docs/listen-to-youtube-ios-plan.md`  
> iOS 工程：`/Users/xuxuheng/Documents/CastReader`  
> Android 工程：`/Users/xuxuheng/Documents/CastReader-Android`

> **强制增量合同**：iOS 真机验收后的入口、歌词末词高亮、解析提速、正文语言校验和 Android 登录/超时阻挡处理，统一见 `docs/listen-to-youtube-ios-android-final-alignment.md`。该文档更新更晚，发生冲突时优先于本文。

## 1. 交接目标与完成状态

iOS 的 Listen to YouTube v1 已完成开发、自动化回归、模拟器与真实 iPhone 端到端验收、真实公开 YouTube 页面冷提取、缓存损坏注入与恢复验证。2026-08-10 用户已在真机确认目标视频可以朗读字幕且画面清晰度改善生效。本文件把已经落地的行为定义、代码入口、故障经验和测试标准固化为 Android 的实现契约。

Android 的目标不是逐行翻译 Swift，而是在现有 Kotlin、Compose、Hilt、Media3 和播放器架构上实现相同的用户能力与可靠性。除平台差异外，双端的输入、输出、失败语义、缓存真实性、播放语义、埋点和合规边界必须一致。

本期最终范围：

- 接收公开 YouTube 视频链接，提取人工或自动字幕，以 CastReader 自有 TTS 朗读字幕稿。
- 原生字幕稿阅读界面，词级高亮、自动滚动、点段跳播、倍速、换音色、进度恢复、迷你播放器。
- 段落对应 storyboard 静帧；无 storyboard 时回退缩略图或原生占位图。
- 字幕、当前音色生成的 TTS、静帧和进度使用 App 私有缓存；绝不缓存 YouTube 视频或音频流。
- 首页入口、示例、粘贴、系统分享、剪贴板提示、深链和历史全部汇入同一路由。
- 对无字幕、直播、受限、不可用、超时、网络与不支持语言诚实失败，不朗读页面杂讯。

明确不做：

- YouTube 音视频流下载、缓存、解析或播放。
- ASR、翻译朗读、YouTube OAuth、直播、伪装“离线 YouTube”。
- 新建服务端字幕解析或新建 TTS 通道。
- 绕过登录墙、年龄限制、地区限制、私享或下架状态。

## 2. 用户可见行为契约

### 2.1 入口和路由

支持下列 URL：

- `https://youtube.com/watch?v={11位id}`
- `https://m.youtube.com/watch?v={11位id}`
- `https://youtu.be/{11位id}`
- `https://youtube.com/shorts/{11位id}`
- 播放列表 URL 只取当前 `v=` 对应视频。
- `t=` 查询参数及 `#t=`、纯数字或 `1h2m3s` 形式的 fragment 被解析为起播锚点。

解析器只接受 HTTP/HTTPS、精确 YouTube host、无 credentials、无显式 port、合法 11 位视频 ID。重复但相同的 `v/t` 值可归一化接受，重复且互相冲突的值必须拒绝；同时拒绝相似域名、空白拼接、溢出时间和非法路径。

统一入口枚举：`share / clipboard / scheme / paste / sample / history`。所有入口只生成同一种 Listen Request，随后走同一提取、缓存、播放器和错误处理管线。

Android 对应入口：

- 首页 YouTube 卡片进入专栏页。
- `ACTION_SEND` 的 `text/plain` 与 URL 类型分享。
- `ACTION_VIEW` 深链；建议支持 `castreader://youtube?url=<encoded>`，同时遵守现有 App Links/导航结构。
- 专栏页粘贴框、示例、历史续听。
- 剪贴板只能在用户明确进入相关界面或主动操作后读取，保持 Android 隐私提示与现有产品行为。

### 2.2 持久分享队列

iOS Share Extension 使用 App Group 的持久 FIFO，最多 10 条，按 canonical URL 去重。最重要的语义是：

1. 收到分享后先持久化，不能只依赖一次 Intent/进程内事件。
2. 同一时刻只处理一个持久分享；新分享留在队列。
3. 提取失败、任务被系统/新请求中断、进程被杀或页面意外退出时不得删除；只有用户明确点击“取消”时可将当前项视为放弃并删除，随后继续下一项。
4. 只有该请求对应的 reader session 已出现可听声音后，才 acknowledge 并删除。
5. 手动粘贴、示例、历史等临时请求不能误删持久分享。

Android 应复用现有 `ShareIntentImporter` / `ShareInboxStore`，为 YouTube 加 typed payload 和上述确认门。`Activity` 重建、冷启动和进程恢复均需重新投递未确认项。

### 2.3 专栏页与首次教学

`YouTubeHome` 包含：

- 首次引导：YouTube 中点分享 → 选择 CastReader → 自动朗读。
- “试听一个示例”按钮，可运营替换且应使用长期存在、有公开字幕的视频。
- 常驻 URL 输入/粘贴区域。
- 收听历史：标题、进度、完整/部分缓存状态、续听。
- 第一次从系统分享成功听到声音后，只显示一次 aha 提示；是否展示以“实际可听播放确认”为准，不以打开页面或生成音频为准。
- 播放 tick 超过 `0.05s` 用于 durable share/aha 的可听确认；累计实际播放至少 `1s` 后才把首次教学记为已完成并在以后折叠。

### 2.4 收听页

用户看到原生字幕稿，不显示或保活 YouTube 网页：

- 顶部显示当前朗读段对应静帧及时间戳；点静帧回到 YouTube 对应时间。
- 标题最多两行，频道名可选，“字幕稿”定性常驻。
- 已读、当前、未读段落有明确视觉层级；当前段词级高亮并自动保持在可视舒适区。
- 点段落文字是在 App 内切换 TTS 段；点时间戳才跨 App 回视频，避免误触。
- 手动滚离当前段后显示“回到当前位置”。
- 播放控制复用全局播放器，离开专栏页后迷你播放器继续工作。
- URL 带 `t=` 时，从时间点所在或其后的第一个可朗读段落开始。
- 自然播放完一个段落后从下一段恢复；全文完成后下次从第一可读段开始，同时历史仍可显示 100%。
- 只包含音乐符号或没有可朗读字符的段落仍显示，但跳过 TTS、起播和恢复选择。

TTS 高亮由 CastReader 音频 segment/timestamp 驱动，不与原视频时间轴同步。YouTube `startMs` 只用于段落起播选择、静帧定位和回视频深链。

## 3. iOS 最终代码地图

Android 实施前必须阅读这些文件的最终实现，不要只读原始计划：

| 能力 | iOS 最终文件 |
|---|---|
| URL、cue、轨道、分段、storyboard、pending queue 模型 | `CastReader/Models/YouTubeTranscript.swift` |
| vendored bridge、适配脚本、DOM 与 playability 分类 | `CastReader/Services/YouTubeWebScripts.swift` |
| 隔离 WebView、请求拦截、单飞、42 秒 native / 34.5 秒 adapter 预算、结果解码 | `CastReader/Services/YouTubeTranscriptService.swift` |
| transcript/TTS/progress/artwork 缓存、LRU、完整性与自愈 | `CastReader/Services/YouTubeCacheStore.swift` |
| 六入口统一路由、分享 ack、Reader 文档转换、回视频 | `CastReader/Services/YouTubeRouteCenter.swift` |
| 首页、引导、粘贴、历史与缓存徽标 | `CastReader/Views/YouTube/YouTubeHomeView.swift` |
| 字幕稿、播放交互、静帧跟随、全量静帧预热 | `CastReader/Views/YouTube/YouTubeListenView.swift` |
| 解析覆盖层及失败重试 | `CastReader/Views/YouTube/YouTubeExtractionOverlay.swift` |
| Share Extension 接收与持久交接 | `CastReader Share Extension/ShareViewController.swift` |
| App 生命周期和路由承接 | `CastReader/CastReaderApp.swift`、`CastReader/Views/MainTabView.swift` |
| 播放、额度、历史与分析接线 | `CastReader/ViewModels/ReadAloudViewModel.swift`、`CastReader/Services/HistoryStore.swift`、`CastReader/Services/ProductAnalytics.swift` |
| bridge 真源副本 | `CastReader/WebAssets/YouTube/youtube-bridge.js` |
| 单测与 UI 验收 | `CastReaderTests/YouTube*Tests.swift`、`CastReaderTests/ProductAnalyticsTests.swift`、`CastReaderUITests/CastReaderUITests.swift` |

## 4. 字幕提取契约

### 4.1 WebView 边界

iOS 使用 **WebKit 自己真实的 UA/浏览器指纹**和 `.preferredContentMode = .desktop`、1280×800 的不可见 `WKWebView`，并使用固定 UUID 的独立持久 `WKWebsiteDataStore`；绝不把 iOS WebKit 伪装成桌面 Chrome。它不共享 Safari、默认 WebView 或书架平台 Cookie，但可保留 YouTube 提取器自己的 consent 状态。成功或失败后立即销毁 WebView。同一时刻只有一个提取任务，新请求取消旧请求，旧回调不能污染新 session。

Android 应实现等价边界：

- 保留 Android WebView 自己真实、可自洽的 UA/Client Hints/浏览器指纹，通过 WebSettings/viewport 请求桌面内容；禁止硬编码一个与真实内核不匹配的桌面 Chrome 版本。提取 WebView 不进入最终 UI。
- Android WebView 需要短暂 attach 到不可交互的真实 View/专用 Activity 中，以保证 renderer 和 document-start 脚本可靠运行；不能只创建一个永不 attach 的实例。
- 不共享用户 Chrome/YouTube App 登录态，也不能为了本功能清空 Kindle、Kobo、Google Books 等现有内嵌 WebView 会话。
- 优先使用独立 WebView 数据目录/进程或其他能保持平台会话隔离的方案。若使用 JavaScript bridge，只暴露单向字符串结果，不暴露文件、网络、反射或任意 native 能力；限制可信 origin，禁用文件访问和不需要的 WebView 能力。
- 页面加载期间只拦截并拒绝已确认的 YouTube 音视频流 host（至少 `*.googlevideo.com`）；字幕、`<track>`、HTML、脚本和图片必须能加载。不要用笼统的 media resource/MIME 规则，因为 WebView 可能把字幕轨也归入 media 并一并误杀。
- 禁止自动播放，禁止后台保活 watch 页面；取到结果后 `stopLoading`、移除 bridge/回调并 `destroy()`。
- 主线程 WebView 生命周期和协程 continuation 必须只有一次完成；timeout、取消和 WebView callback 之间做原子门控。
- 主 frame 最终只允许 `https://www.youtube.com/watch?v=<expectedVideoId>`；重定向到 consent、Google Accounts、Google sorry/reCAPTCHA 或 YouTube signin/verify 均归为 restricted，其他跨站导航 fail-closed。
- 原生消息同时校验主 frame、精确 HTTPS origin、每次请求的随机 token、requestVideoId 和结果 videoId。不要使用不受 origin 限制的裸 `addJavascriptInterface`；优先使用 AndroidX WebKit 的 origin-restricted WebMessage listener，且原生端继续校验 token/videoId。

用户明天即使从已登录 Chrome/YouTube App 分享，提取器也不会继承该登录 Cookie。这是刻意的安全边界：v1 只支持无需登录即可读取字幕的公开视频；登录、年龄、会员、私享内容必须诚实失败。

### 4.2 bridge 真源与协议

bridge 来源：

- 仓库：`readout-desktop`
- 真源：`src/entrypoints/youtube-bridge.content.ts`
- 记录 commit：`92d22744839bfb34c6c4f5d7152192729074919f`
- iOS、已构建 App 与 Safari Extension 最终 SHA-256：`877af9a72117d6c2afd0e303f74fe4bb03f5172e7c90ad9ac3788aeb77add02c`

Android 必须复用同一份构建产物，不能手写一个“近似版”。将 JS 放入 app asset，增加构建或单测校验 SHA；若真源升级，则三端整体升级、同步记录新 commit 与新 SHA。

bridge 的页面契约：

- `document.body.dataset.crYtTracks`
- `crYtTracksVideoId`
- `crYtTracksPending`
- `crYtTranscript`
- `crYtFetchUrl` / `crYtFetchResult`
- 事件 `__cr_yt_transcript_req__` → `__cr_yt_transcript_res__`

原生适配层负责把结果传回 native，并补采：video ID、title、channel、thumbnail、caption tracks、storyboard spec、live/playability 状态。默认 adapter 预算为 34.5 秒，native 从开始导航计算的硬超时为 42 秒，其中预留 7.5 秒给文档首包、document-start 与结果投递；字幕面板外层等待最多 24 秒，必须覆盖 vendored bridge 的 10 秒拦截 + 12 秒 DOM 等待。单次 native message 上限 20 MiB、cue 最多 200,000；超限、负时间/时长、整数溢出或 JSON 结构错误归入 malformed response，不能造成 OOM。

`LOGIN_REQUIRED` 的反机器人页面可能没有 `videoDetails` 或字幕轨，但 `ytInitialData` 仍包含精确 video ID 与 `getTranscriptEndpoint`。只有当 initialData video ID 严格等于请求视频、存在 transcript endpoint、且理由明确为 bot verification 时，才允许继续页面字幕 fallback；普通登录、年龄、会员、私享不可绕过。即使 media-blocked runtime response 评分更高并显示 `UNPLAYABLE`，也不能丢失 initial response 的登录/验证证据。该证据需要锁存到正常完成、adapter 看门狗、异常终止三条路径；fallback 失败必须保持 `restricted`，不能退化成 timeout/unavailable/malformed。

### 4.3 字幕取得与选择

提取顺序与 iOS 保持一致：

1. 在页面主世界拦截/观察 YouTube **自己发出的官方 decorated timedtext 请求**，只在 JS 内存中保留，绝不记录完整 URL 或 PO token；若主动捕获缺失，再从 Resource Timing 中恢复候选。
2. 候选 URL 必须同时满足 HTTPS、精确同源 `www.youtube.com`、精确 `/api/timedtext`、video ID/语言/kind 与已选择轨道一致、`pot` 非空且 `potc=1`，拒绝跨视频、跨轨道、跨 origin、缺 token 或未知路径。短期 token 只用于本次提取，不写入 transcript identity、日志、埋点或持久缓存。
3. 优先用上述可信 decorated URL，按 `fmt=json3 → fmt=srv3 → 删除 fmt` 重试；随后才尝试 track 的普通 `baseUrl` 同样三种格式。HTTP 200 但 0 字节/空 cue 仍算失败，不能当成功。
4. 最后才让 vendored bridge 打开 transcript panel，并按 DOM 的 timestamp/text 子节点结构化解析。

不能读取时间戳按钮、无障碍说明、折叠标题或整页 `innerText` 作为字幕。空 cue 必须是明确的 no captions 或失败，不得降级为页面杂讯。panel fallback 若得到多条 cue 却全部为 `0ms`，必须判 malformed，并清除可能命中的旧坏缓存，不能展示一列 `00:00`。

轨道选择与 iOS 一致：

1. 用户/设备首选语言的人工轨；
2. 同语言自动字幕；
3. 英语人工轨；
4. 英语自动轨；
5. 第一条可用轨。

轨道身份使用稳定 caption id/vssId、language、kind、name，不把短期签名 URL 作为永久身份。

支持播放语言：`en, zh, ja, es, fr, de, pt, it, hi`。地区后缀归一化到 base language。字幕轨存在但 TTS 不支持时显示 unsupported language，不能选另一个不诚实的文本或发送错误 voice 参数。全篇段落均无可朗读字符时也不能进入空播放器，按 `no_captions` 诚实失败。

### 4.4 cue 分段

分组必须与扩展和 iOS 行为一致：

1. 以 `startMs` 稳定排序；同时间保持原顺序。
2. cue 文本换行改为空格、trim；空文本跳过。
3. 当前段非空且“相邻 cue 间隔 `> 2000ms`”或“追加前当前 UTF-16 长度 `> 150`”时断段。
4. 段落 `startMs` 取第一条 cue；ID 从 0 连续递增。
5. 时间相加、秒转毫秒和 manifest 字节总数都做溢出保护；总数溢出使用饱和值或拒绝输入。

注意是 UTF-16 length、严格大于 150、在追加下一 cue 之前判断；不要改成字符数、`>=` 或追加后判断。

### 4.5 42 秒硬上限与失败优先级

默认 native 有 42 秒硬上限，adapter 有 34.5 秒内部预算，不是每阶段各自重新获得整段时间。优先识别页面 playability，再对 track/cue 结果分类：

| 原因 | Android/iOS 统一语义 |
|---|---|
| `invalid_url` | 非法或不受支持 URL |
| `no_captions` | 视频可用但没有可读字幕 |
| `live` | 正在直播或尚未开始的直播；有结束时间且已有静态字幕的直播回放不能误判 |
| `restricted` | 需要登录、年龄/会员等权限 |
| `unavailable` | 地区限制、私享、下架、删除或播放器明确不可用 |
| `timeout` | 总预算用尽，提供重试 |
| `network` | 明确网络失败，提供重试 |
| `caption_access` | 已确认视频有可选字幕轨，但官方字幕内容在当前会话中被拒绝、返回空体或全部可信取得方式失败；提示“暂时无法读取该视频字幕”，允许重试，不能误报“没有字幕”或普通网络失败 |
| `unsupported_language` | 有轨道但 CastReader TTS 不支持 |
| `malformed_response` | bridge/JSON/cue 结构无效 |
| `cancelled` | 用户或新 single-flight 请求取消；不弹错误噪音 |

失败后释放 WebView 和所有 callback；重试生成新的 request identity，旧结果必须被忽略。

网络响应分类必须按资源层级区分：watch/main-frame `401/403 → restricted`、`404/410 → unavailable`；单个 caption 子资源的 `400/401/403/404/410` 在没有页面级账号权限或视频不可用证据时，只说明该字幕取得方式失败，应继续其他可信来源，最终通常归 `caption_access`，不能把整段视频误判成登录或下架。`408/425/429/5xx` 与 DNS/连接错误属于可重试 network 证据；已经确认存在字幕轨，但 raw/decorated/panel 全部无法取得，或 caption HTTP 200 空体，在排除明确网络错误后归 `caption_access`。Google Accounts、consent、sorry/reCAPTCHA 与 YouTube signin/verify 主页面跳转均为 restricted。只有 network/timeout/caption_access 可以回退到同 URL/所选轨道的最新有效本地 transcript；no captions、live、restricted、unavailable 等权威失败不能用旧缓存伪装成功。

## 5. 播放、TTS、额度与进度

Android 必须复用：

- `PlaybackController` 负责 TTS 分段生成和流式状态。
- `AudioPlayerManager` / `AudioPlaybackService` 负责 Media3 播放、词级回调与前台服务。
- `GlobalPlayerState` 作为 YouTube Reader、迷你播放器和系统播放状态的唯一 UI 真源。
- 既有 `/api/captioned_speech_partly`，首段生成即播，后续边生成边播。
- 既有 Pro 与 quota 口径；YouTube 计入统一免费收听时长和 `/api/pro/listen-track`，不能旁路。

不可复制 iOS manager 层级；应给现有 Android 播放管线增加 YouTube document/source adapter。需要保证：

- 当前音频 segment 的 timestamps 驱动 TTS 实际文本的词级高亮。
- 新视频/点段跳播时取消旧生成，清理队列，避免旧 segment 串入。
- 音频队列暂空但还有生成任务时等待后续 segment，不误报全文完成。
- 速度和音色遵守既有免费/Pro 闸门；缓存变体必须绑定精确 voice 和 TTS schema。
- 中/英只有在既有服务端契约允许时传 `voice_code`；其他语言遵守当前 TTS request builder，不为 YouTube 写特例。
- 已生成但从未自然播放完成的缓存仍属于首次收听，不能借缓存绕过额度。只有段落完成后标记 replay eligible。
- 进度至少包括段落、稳定 segment ID、segment index、段内 fraction、按 duration 加权的 paragraph fraction 和更新时间。

## 6. storyboard、缩略图和画面跟随

storyboard 解析必须 fail-open：失败只降级静态缩略图，永不阻塞字幕或首音。

硬限制与规则：

- HTTPS URL，无 credentials，模板必须可完整替换 `$L/$N/$M/$S`，拒绝未知残留 token。
- tile 宽高 `1...8192`，columns/rows `1...1000`，interval `1...86,400,000ms`，frameCount `1...10,000,000`。
- 在所有满足安全上限的候选中按 **单 tile 像素面积最大**选择，面积相同时选更高 level；禁止固定 L2。`sheetCount <= 512`，并在解析、模型、缓存查询和预热每一层重复校验。整张 sprite sheet 的宽高各不超过 8192，总像素不超过 32,000,000。
- 缩略图应合并 `videoDetails`、microformat、`og:image` 等候选，并优先页面声明尺寸最大/`maxres`、`sd`、`hq` 质量更高的合法 HTTPS 候选；不能因为先读到低清 `og:image` 就停止。
- `frame(atMs)` 选择离散帧；段落变化时约 150ms 淡入，不做连续伪视频播放。
- 自适应展示：若 storyboard tile 宽度至少覆盖当前全宽物理像素的 80%，允许全宽显示；否则用最高质量封面作全宽主图，把当前 storyboard 帧作为约 120–180pt、随朗读段落同步的小窗。只有 storyboard 时仍可展示，但不得声称它是高清原视频帧。图片使用高质量插值。
- 当前 sheet 优先，邻近 sheet 可预取；首音不等待任何 artwork。
- 进入 Reader 后开启全量缺失 sheet 预热，当前 session 内使用 `0/2/6/18/54/60` 秒有界重试；每轮遇到第一张失败即停止该轮，避免继续轰击 CDN。单张失败不能写“已缓存”，以后进入仍可补齐。
- 预热任务与当前段图片加载分离，段落切换取消 visible-frame 请求时不能中断全量缓存。
- 同一轮多张写入合并一次缓存状态通知，避免每张图触发全量磁盘扫描。

静帧写缓存前必须验证真实可解码，不接受“非空 bytes 即图片”：

- 单资源最大 20 MiB。
- 宽高各 `1...8192`，像素总数不超过 32,000,000。
- Android 可用 `BitmapFactory.Options.inJustDecodeBounds` 验尺寸，再用采样解码验证内容；不要先完整解码不可信大图。
- storyboard sheet 还必须达到其 tile grid 的最低像素尺寸。
- 裁剪 rect clamp 到真实 bitmap bounds；错误时保持上一帧或降级缩略图。

## 7. 缓存与“已缓存”真实性

生产上限为 50 个不同视频或 500 MiB，任一超出即按视频级 LRU 淘汰。缓存位于 App 私有、可再生成且不参与设备备份的目录；文件名只用 SHA-256，绝不把原始视频 ID、URL、语言、音色或字幕文本拼入路径。

Transcript key 至少绑定：

- hashed video ID
- normalized track language
- stable selected-track identity hash
- transcript fingerprint

TTS key 至少绑定：

- transcript fingerprint
- exact voice code hash
- canonical playback language
- audio persistence schema version（iOS 当前为 4；Android 可有独立版本但本次必须升级并显式进入 key）
- paragraph index/variant

Artwork metadata 还必须有显式 schema/version。当前 iOS artwork schema 为 2：选择最高合法 storyboard，并把高清 thumbnail 当作一等资源。读取到旧 schema 时只刷新 artwork metadata/图片，保留已验证的 transcript、TTS 和进度，避免画质升级让用户重新生成整篇音频。

读取时验证 manifest 与文件内容；文件缺失、JSON 损坏、key 不匹配、音频为空、图片不可解码或越界 sheet 必须删除相应声明并降级为 miss，不能崩溃。所有文件操作检查 symlink 与 canonical path 仍在 cache root 内。manifest 写入应原子替换；启动维护延后到首音关键路径之后，执行孤儿清理、精确 byte recount 和 LRU pruning。字节求和使用饱和加法，防止异常 manifest 溢出变负数而逃逸配额。History/徽标的只读 peek 不得刷新 LRU；只有真实内容读取/播放才 touch。

“已缓存”只有在以下条件全部成立时才能显示：

1. transcript 在盘且可解码、身份匹配；
2. 当前所选 voice 的每一个可朗读段落都有完整 TTS；
3. 声明了 thumbnail URL 时，缩略图必须存在且可解码，不论是否同时存在 storyboard；
4. 有合法 storyboard 时，`0..<sheetCount` 每张均存在且可解码；
5. 两者都没有时，原生占位图不需要下载，可视为 artwork 完整。

其余只能显示“部分已缓存”或无徽标。历史页和 Reader header 必须调用同一个 coverage 计算函数，不能各自猜测。

缓存变更刷新采用 identity/generation 门控的 single-flight + coalesced trailing refresh：已有磁盘扫描时只记录还需一次尾刷，不能反复取消/重建 debounce 任务，否则连续 TTS 写入会造成永远刷新不到的 starvation。iOS 音频事件合并 350ms、artwork 事件立即刷新；Android 可用 Flow/actor/mutex 实现等价语义。

## 8. 埋点、历史与本地化

统一事件：

- `yt_share_received`：只在外部/主动新入口发送，`entry = share/clipboard/scheme/paste/sample`；history 续听不发送这个事件。
- `yt_home_view`：`first_time`
- `yt_extract_done`：`cue_count, paragraph_count, lang, elapsed_ms`
- `yt_extract_fail`：公开 reason 只允许 `no_captions/live/restricted/unavailable/caption_access/timeout/unsupported_language`。内部 `invalid_url/malformed_response` 映射为 `unavailable`，`network` 映射为 `timeout`，`cancelled` 不发送失败事件。
- 朗读沿用 `reading_start/...` 和 `contentFormat=youtube`。Android 使用 `contentSource=youtube_android` 前，必须同步 Android/iOS canonical JSON、readout-web TypeScript value domain、`/api/events` 白名单与合同测试；不得私自发送白名单外值。

在 Android 同步检查三处：客户端 enum/model、bundled `mobile-events-v2.json`、readout-web `/api/events` 合同与白名单。若服务端合同已经由 iOS 改好，应只扩充 Android source，不重复发明事件。事件严禁携带字幕、标题、URL、本地路径、账号、原始错误或响应内容。

历史记录需要保存 source URL、YouTube source kind、标题、封面引用、段落进度、session/cache identity；同一视频不同字幕轨不可错用 transcript/TTS。字幕、TTS 和图片只能存在有界 YouTube cache，不能复制进无界普通历史目录。历史页必须能在完全离线时打开已完整缓存内容且不发 TTS 请求。

所有用户文案覆盖 Android 已配置的 9 套资源：默认/英语、`zh`、`ja`、`es`、`fr`、`de`、`pt-rBR`、`it`、`hi`。UI 自动化至少验证英文和中文关键文案不会使用 raw key、截断或空 accessibility label。

## 9. Android 实现映射建议

| iOS 责任 | Android 首选落点 |
|---|---|
| `YouTubeTranscript.swift` | 新 `youtube/model` 领域模型与纯函数，不塞入无关大模型文件 |
| `YouTubeTranscriptService` | Hilt singleton/session owner；WebView UI 生命周期由专用 Activity/Compose host 管理，业务状态可测试 |
| `YouTubeWebScripts` | `app/src/main/assets/youtube/` + Kotlin loader + hash contract test |
| `YouTubeRouteCenter` | 单一 coordinator/ViewModel，承接 Intent、首页、paste、history 和 deep link |
| App Group pending queue | 扩展现有 `ShareInboxStore`，DataStore/原子文件持久 FIFO，首音后 ack |
| `ReadingDocument(.youtube)` | 给现有 Player document/source 增加 YouTube adapter 和 timeline anchor |
| `YouTubeCacheStore` actor | 单例 repository + `Mutex`/单线程 dispatcher；原子 manifest，文件 IO 不占 Main |
| `YouTubeHomeView` | Compose 专栏 route，复用首页卡片和历史视觉组件 |
| `YouTubeListenView` | Compose 原生 transcript screen，订阅 `GlobalPlayerState`，LazyColumn 自动滚动 |
| `YouTubeArtworkLoader` | Coil/OkHttp + app-private cache repository；visible frame 和 full warmup 两个 Job |
| Share Extension | `ACTION_SEND`/`ACTION_VIEW` intent-filter + typed importer |
| `UIApplication` 回视频 | YouTube app intent，失败回落 HTTPS `watch?v=&t=s` |

Android agent 应先检查现有 dirty worktree，保留其他任务修改；优先复用已有 share、播放器、历史、analytics 和 navigation，不做破坏性重构。

## 10. 分阶段实施与自我迭代要求

每个里程碑都必须执行“实现 → 自动测试 → 失败注入/手动检查 → P0/P1 自审 → 修复 → 重跑”，不得等全部写完才第一次构建。

### A. 纯合同层

- URL/time parser、track selector、stable grouping、storyboard parser/frame mapping。
- bridge asset/hash、消息 decoder、大小限制、playability/failure mapping。
- 单测覆盖合法、恶意、边界、整数溢出、相同时间 cue、UTF-16、多 spec 变体和 >512 sheet。

完成门：相关 unit tests 全绿，debug compile 通过。

### B. 提取与路由

- WebView 隔离、真实自洽 UA + 桌面内容模式、精确媒体流拦截、decorated timedtext/PO-token 恢复、42 秒 native / 34.5 秒 adapter 预算、single-flight、销毁。
- ACTION_SEND/VIEW、持久 FIFO、冷启动恢复、重试和取消；区分意外中断（保留）与用户显式取消（ack 后继续下一项）。
- 用本地 HTML/JS fixture 验证成功、空轨、受限、不可用、直播、timeout、late callback。
- 用至少一个真实公开字幕视频冷提取，记录 cue/paragraph 数、耗时、WebView 销毁证据。

完成门：fixture 与真实提取均通过；网络失败和重试不会丢队列。

### C. 播放与 UI

- 转换为播放器文档、首段即播、词级高亮、自动滚动、点段跳播、`t=` 起播、进度恢复、回视频。
- 首页引导/示例/粘贴/历史、分享 aha、全局迷你播放器。
- 音乐/空白段跳过、不支持语言、quota 与 voice gate。

完成门：Compose/UI tests、播放器单测、build/install/launch 全绿；首音确认后才 ack 的故障测试通过。

### D. 缓存、静帧与鲁棒性

- transcript/TTS/progress/thumbnail/storyboard、LRU、hash keys、corruption self-heal。
- truthful offline coverage、同音色完整命中、跨音色/跨轨道 miss、replay eligibility。
- storyboard 最高合法层、高清封面 + 同步小窗、自适应全宽、当前帧、全量预热、artwork schema 升级、重试、缓存通知 single-flight/trailing refresh。
- 注入：删最后一张 sheet、伪图片、超大尺寸、坏 JSON、缺音频、异常 manifest byte size、连续缓存通知。

完成门：每种注入均自动降级/补齐且不崩溃；完整离线重开不触发 transcript/TTS/artwork 网络。

### E. 最终回归

- `./gradlew test`
- `./gradlew lint`
- `./gradlew connectedAndroidTest`（有 emulator/device 时）
- `./gradlew assembleDebug`、`./gradlew installDebug`、启动主 Activity。
- 检查 APK 内 bridge SHA、manifest intent-filter、资源本地化、release lint/签名之外的静态问题。
- 独立做一次 P0/P1 code review；发现问题修复后必须重跑受影响套件和一次全量回归。

## 11. 最终验收矩阵

至少覆盖：

- watch、youtu.be、shorts、mobile、playlist 当前视频、query/fragment `t=`。
- 人工字幕、自动字幕；英文及至少一个非英文支持语言。
- 无字幕、直播、已结束直播、登录/年龄限制、不可用、网络断开、42 秒硬超时。
- 分享冷启动、热启动、连续分享、进程被杀、提取失败后重试、手动请求抢占。
- 首段播放、逐词高亮、自动滚动、点段跳播、倍速、换音色、锁屏/后台、迷你播放器。
- storyboard 多 sheet、无 storyboard 回退、图片失败、最后一 sheet 缺失后同 session 恢复。
- 杀 App 进度恢复、全文完成后从头、历史百分比正确。
- 部分缓存不冒充完整；完整缓存飞行模式回放；换 voice 必须重新生成对应缺失段。
- 免费额度、Pro voice/speed gate、listen-track 上报；缓存生成未播完不能免额度，完成后的重复播放遵循既有免重复计费语义。
- 9 种本地化资源存在，TalkBack 标签/可点击目标、深色模式、小屏和大字体基本可用。
- 确认没有请求、存储或播放任何 YouTube video/audio stream。

性能目标仍为分享到首音 p50 <5 秒、p95 <12 秒。开发环境受网络波动时要提供原始 10 次计时和中位数，不得用单次最好值代替。

## 12. iOS 实施经验与已消除的 P1

1. **非空图片 bytes 不代表图片有效。** 必须验证 decoder、尺寸、像素量和 storyboard 最低画布；否则坏文件会让“已缓存”撒谎且每次打开失败。
2. **页面提供的数量永远不可信。** storyboard sheetCount 必须在 parser/model/cache/prefetch 四层限 512。
3. **取消 debounce 会造成状态饥饿。** 高频音频写入持续 cancel 旧刷新，徽标可能永远不更新；正确结构是 single-flight 加合并尾刷。
4. **manifest 总数需要饱和加法。** Int64 溢出变负会绕过 500 MiB 限制。
5. **首音与完整缓存是两条任务链。** 当前帧/邻近帧服务 UI，全量 sheet warmup 独立运行；任何 artwork 都不得卡住首音。
6. **同 session 必须重试。** 只等下次打开会让一次瞬时丢包永久停在部分缓存；采用有界退避并允许以后重启系列。
7. **持久分享必须在 audible playback 后 ack。** 页面打开、字幕成功甚至音频写盘都不足以证明用户链路成功。
8. **缓存身份必须包含 provenance。** video ID 或 transcript fingerprint 单独都不够；同名/同文轨道、换音色和 schema 升级不能串缓存。
9. **DOM 文本非常容易误收。** 时间码、按钮 accessibility text 和折叠 UI 会看似有内容但不是字幕；只接受结构化 cue。
10. **WebView 登录态不可假设。** 系统浏览器已登录不等于 App WebView 已登录；本期刻意只承诺公开视频。
11. **UI 测试必须等真正可交互元素。** Lazy list 的第 0 项可能不在视口；查询全部候选并要求 `exists && isDisplayed/clickable`，accessibility label/value 非空。
12. **bridge 多副本必须按字节一致。** source/App/extension 任何一份漂移都会出现难以复现的跨端差异。
13. **不能伪造与内核不一致的浏览器身份。** iOS WebKit 硬改成 macOS Chrome UA 后，YouTube BotGuard/PO-token 完整性校验会让 timedtext 表面 HTTP 200、实际 0 字节。请求桌面内容应使用平台 API，而不是伪装另一个浏览器。
14. **普通 caption `baseUrl` 可能不够。** 页面播放器已经用 decorated timedtext URL 携带短时 PO token；丢弃它再重建裸 URL会稳定失败。必须捕获页面自己的可信请求并严格校验，且 token 不能落盘或进日志。
15. **“有轨道但取不到内容”不是“无字幕”。** 它是独立的 `caption_access`，否则用户会看到与事实矛盾的错误，日志也无法区分授权/完整性与网络问题。
16. **固定 L2 会把 160×90 拉伸到 Retina 全宽。** 应选最高合法层；即使 320×180 仍不足，也要用高清封面承载全宽视觉，把同步分镜缩为小窗。
17. **旧 artwork 缓存会掩盖画质修复。** schema 升级需精准失效图片元数据，但保留 transcript/TTS/progress；完整离线 coverage 还要同时计算封面和所有 storyboard sheet。

## 13. iOS 已有验证证据

当前最终证据：

- YouTube 聚焦回归：114/114，`/tmp/CastReader-YouTube-Final-Regression-Current-20260810-0724.xcresult`。构成：ProductAnalytics 16、Cache 29、History 2、ParagraphProgress 3、PlaybackAcceptance 2、ReadingBuilder 7、Storyboard 8、Track 2、Grouping 6、Model 2、Service 21、URL 7、WebScripts 9。
- UI + 故障注入最终验收：1/1，`/tmp/CastReader-YouTube-Device-Acceptance-Final-20260810-0718.xcresult`
- 真实公开页面冷提取：`/tmp/CastReader-YouTube-Live-Final-Signed-20260810-0634.xcresult`
  - 24 个不同 cue；真实 TTS 进入 `playing`；提取后 WebView 销毁；缓存重开 <5 秒。
- storyboard 故障注入：主动移走最后一张 M4，App 同 session 恢复；最终 sheet 0...4 完整；M0...3 为 800×450，M4 为 800×180。
- readout-web 分析合同：13/13，TypeScript `tsc --noEmit` 和 Prettier 通过。
- 最终签名模拟器构建：`/tmp/castreader-youtube-final-build/Build/Products/Debug-iphonesimulator/CastReader.app`
- 最终启动设备：iPhone 17 Pro Max simulator，UDID `F89CFFE3-77DD-43E5-B21B-EDAF6AAD4105`。
- 最终启动截图：`/tmp/castreader-youtube-final-launch.png`
- UI 附件：`/tmp/castreader-youtube-device-acceptance-final-attachments/`
- bridge SHA：`877af9a72117d6c2afd0e303f74fe4bb03f5172e7c90ad9ac3788aeb77add02c`
- 静态检查：plist、codesign、whitespace、本地化、bridge 多副本一致性均通过。

最终问题视频真机证据（2026-08-10）：

- URL：`https://m.youtube.com/watch?v=wpb-DrbhEiY&pp=iggCQAE%3D&ra=m`
- 原生 WebKit 会话检测到 2 条人工字幕轨，选择 `zh-Hans`；decorated timedtext 返回 HTTP 200、95,581 bytes，得到 907 条 cue，冷提取约 7.89–7.90 秒。
- storyboard 从旧 L2 `160×90` 升级为 L3 `320×180`、10,000ms 间隔、15 张 sheet；全宽使用 1280×720 高清封面，低清同步帧使用小窗展示。
- 真实 iPhone 定向 XCTest、最终 App 编译/链接/签名/安装均成功；最新结果包：`/Users/xuxuheng/Library/Developer/Xcode/DerivedData/CastReader-cwsteljoauziumebymxdgiipcrjz/Logs/Test/Test-CastReader-2026.08.10_17-49-24-+0800.xcresult`。
- 用户随后在同一台已解锁真机手工验收，确认字幕可以朗读且图片清晰度改善生效。

这些路径是本机临时验收证据，不应被 Android 当成自己的完成证明。Android 必须生成并汇报自己的 test reports、APK、设备/模拟器、日志和截图。

## 14. 合规与上线门

技术实现完成不等于获得第三方内容授权。当前技术边界遵守：字幕稿阅读器定性、只读用户明确提交的公开视频字幕、只生成 CastReader 自有 TTS、无 YouTube 音视频流下载/缓存/播放、受限内容不绕过。

但正式上架前仍需产品/法务确认 YouTube Developer Policies 与 Google Play 的第三方内容、知识产权和 WebView 政策。官方 captions API 的下载权限通常要求调用方可编辑对应视频，不能拿它作为任意公开视频字幕的无授权替代品。

产品文案、截图和商店描述不得出现“下载 YouTube”“离线 YouTube”“后台播放 YouTube”等表达。建议审核说明：本功能展示并朗读用户明确分享视频的公开字幕文本，音频由 CastReader 自有 TTS 生成，不下载、提取或回放视频/音频流。

## 15. Android 完成定义与最终汇报格式

只有同时满足以下条件，Android 任务才能声明完成：

- 本文件第 2–9 节的全部 v1 行为已实现，或明确指出经证据证明属于平台不适用项。
- 第 10–11 节测试完成；所有自动化为绿，P0/P1 自审问题已归零。
- debug APK 构建、安装、冷启动成功；至少一个真实公开字幕视频完成“分享/粘贴 → 提取 → TTS 首音 → 高亮 → 缓存重开”。
- 故障注入验证缓存真实性、损坏自愈、最后 sheet 恢复和 durable share ack。
- 没有把仅能由用户明日执行的浏览器/真机账户验收伪装成已自动完成。
- 无未说明的编译告警、崩溃、测试失败、占位实现或 TODO。

最终汇报需包含：

1. 实现文件与跨端功能对照表；
2. 每套测试的通过数、命令与 report/result 路径；
3. APK 绝对路径、安装目标 serial/型号、启动结果；
4. 真实公开视频 ID、cue/paragraph 数和首音计时；
5. 缓存/网络故障注入与恢复证据；
6. 独立 P0/P1 复核结论；
7. 只留真正需要用户明日真机/账号或上线授权确认的事项。
