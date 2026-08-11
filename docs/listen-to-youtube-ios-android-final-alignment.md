# Listen to YouTube：iOS 最终调整与 Android 强制对齐合同

> 最终更新：2026-08-11  
> iOS 工程：`/Users/xuxuheng/Documents/CastReader`  
> Android 工程：`/Users/xuxuheng/Documents/CastReader-Android`  
> Android 执行任务：`019fe754-4123-7450-a560-20e50bcffe4d`

## 0. 文档优先级与目标

本文记录 iOS 首版完成后，经过真实 iPhone 使用反馈继续落地的最终调整。Android 必须在已有 Listen to YouTube 基础上补齐本文全部差异，并自行完成实现、自动测试、故障注入、真机日志、性能评测与迭代。

文档优先级如下：

1. 本文是 2026-08-11 最终增量合同，发生冲突时以本文为准。
2. 完整基础合同仍见 `docs/listen-to-youtube-ios-to-android-handoff.md`。
3. 问题复盘见 `docs/listen-to-youtube-implementation-retrospective.md`。
4. 原始立项范围见 `docs/listen-to-youtube-ios-plan.md`，其早期 checklist 不代表最终完成态。

Android 不能以“编译通过”“fixture 通过”或“iOS 已验收”代替自身完成证据。至少需要在真实 Android WebView 和真实设备上完成：

```text
分享或粘贴真实公开视频
  → 字幕成功/明确失败
  → 正确语言的 CastReader TTS 首音
  → 全段词级高亮完整
  → 首页最多 3 条内容
  → 缓存重开与进度恢复
```

## 1. 预设音乐视频与段尾词未高亮

### 1.1 复现与根因

iOS 预设/历史中的音乐视频（真实复现：Rick Astley - Never Gonna Give You Up）字幕常包含：

```text
♪ Inside we both know what's been going ♪ ♪
We know the game and we're gonna play it ♪
```

预设链接是正常的公开视频样例 `dQw4w9WgXcQ`，不是一种特殊“音乐播放模式”，仍走公开字幕 → CastReader TTS 的普通链路。

旧实现把 `♪/♫/♩/♬/🎵/🎶` 原样发送给 TTS。YouTube 用这些符号表达歌词行边界，但服务端 TTS 的文本规范化器、音频和 timestamps 对其处理并不一致，导致视觉段落还保留末尾单词，而返回的可高亮 timestamp 往往提前结束，表现为每段最后 2～3 个单词能听到却不高亮。旧质量门只看 timestamps 对正文的总体有序覆盖率；长歌词即使漏掉结尾仍可能达到 80%，被误判成可逐词高亮。

这不是 UI 绘制宽度问题，也不能通过“强行把高亮延长到段尾”修复。强行补范围会让时间同步失真，并在真正缺少音频词时错误高亮。

### 1.2 iOS 最终行为

最终修复不是单独“清掉音乐符”，而是四层防线。

第一层，所有前台生成、后台预取和“是否可朗读”判断统一经过 `SpeechTextSanitizer`：

- 段首连续音乐符号删除。
- 段内连续音乐符号转换为句号和空格，即歌词行边界变成自然句界。
- 只有音乐符号、没有任何可朗读字符的段落保留显示，但跳过起播、TTS、恢复点和预取。

第二层，当前段直接渲染 TTS 返回的 `processedText`，逐词高亮只消费该文本对应的 timestamps；禁止把 timestamps 猜测映射回原始 YouTube cue。

第三层，`TTSTimestampQuality` 除时间范围、start/end 单调、token 密度和至少 80% 有序正文覆盖外，还强制 timestamps 命中规范化正文的可读首端和末端。任何一端缺失，当前 audio segment 就降为整句/整 segment 高亮，不伪造 timestamp、不让段尾出现“音频仍在播但高亮消失”的空窗；后续质量正常的 segment 仍可恢复逐词高亮。

第四层，旧语义音频因 audio schema 升级失效，不能继续命中坏歌词 timestamps 缓存。当前 iOS schema 已因后续语言身份隔离升到 4；Android 使用自己的新版本号即可，但必须让旧 schema 2 缓存 miss 并重新生成。

权威示例：

```text
输入：♪ Inside we both know what's been going ♪ ♪ We know the game and we're gonna play it ♪
TTS：Inside we both know what's been going. We know the game and we're gonna play it.
```

iOS 代码与测试：

- `CastReader/Utils/LanguageDetector.swift`：`SpeechTextSanitizer`
- `CastReader/Models/TTSTimestamp.swift`：`TTSTimestampQuality` 的首尾完整性门
- `CastReader/ViewModels/ReadAloudViewModel.swift`：前台生成与下一段预取均调用 sanitizer
- `CastReader/ViewModels/ReadAloudViewModel.swift`：质量失败时仅当前 segment 降级为整句高亮
- `CastReaderTests/CastReaderTests.swift`：`testSpeechTextSanitizerConvertsMusicMarkersIntoSentenceBoundaries`、`testTimestampQualityIsLanguageNeutralAndFallsBackPerSegment`
- `CastReaderTests/YouTubeTranscriptTests.swift`：纯音乐 cue 跳过合同
- `CastReaderTests/YouTubeCacheStoreTests.swift`：schema/voice/language cache miss 合同

### 1.3 Android 对齐要求

Android 应在现有全局 TTS 请求构造层复用同一 sanitizer，不要只在 YouTube Compose 页面做视觉替换：

交接时静态审计的已知差异：Android `TTS.kt` 的 `TtsTimestampPolicy` 仍使用较宽松的 `MIN_COVERAGE = 0.60`，没有首尾命中门且未完整校验 end 单调；`PlaybackController.cleanForTTS` 没有音乐符规则；`YouTubeTtsAudioCacheSchema.Current` 仍为 2。Android agent 应以当前源码再核对后一次性收口，避免只修其中一层。

1. 同一组 6 类音乐符号、同一段首删除/段内句界规则。
2. foreground generation、prefetch、cache write、speakable predicate 使用同一规范化结果。
3. 高亮只消费服务端返回的 processed text/timestamps；YouTube 当前行显示 processed text，或实现等价的格式容错映射。
4. timestamp 质量门至少包含 start/end 范围和单调性、token 密度、有序覆盖率、可读首端命中、可读末端命中。
5. 质量不完整时清空该 segment 的逐词 timestamps 并使用既有整句 fallback；禁止人为补尾词时间。
6. 音频缓存 schema 从当前 Android 旧值升级；旧歌词音频不得命中。
7. 自动化必须证明最后一个词 `it`、`see` 等能在实际播放尾部被高亮；还要证明“缺尾 timestamp”会稳定整句降级，而不是只断言文本被替换。

验收用例：

- 包含多个 `♪ ♪` 行界的英文歌词。
- 段首、段中、段尾分别含音乐符号。
- 纯音乐符号段。
- 当前段自然播完、预取下一段、缓存重开三条路径。
- 连续至少 3 个歌词段；1.0x 与用户当前 1.5x；冷缓存与热缓存各一次。
- 完整 timestamps 时末词逐词高亮；不完整 timestamps 时整段 fallback，段尾绝不出现高亮空窗。

## 2. 首页入口与入口架构

### 2.1 产品定位

Listen to YouTube 不是“输入文本/导入文件”里的一个次级按钮。它的触发行为虽然是粘贴 URL，但产品层级与 Kindle 一样，是首页的一等内容来源。

最终首页顺序：

```text
继续阅读/场景入口
→ Kindle 内容模块
→ 听 YouTube 内容模块
→ Google Play 图书等其他书架模块
```

### 2.2 有历史时

- 标题：`听 YouTube`。
- 说明：`分享视频链接，朗读公开字幕稿`。
- 右侧唯一主入口：`＋ 粘贴视频链接`；点击进入完整 YouTube 页面，该页同时包含引导、粘贴、示例和全部历史。
- 内容纵向排列，最多 3 条；与 Kindle 横向书封排布区分。
- 只投影可合法路由的 YouTube history，按记录 ID 去重；排序为当前正在听 → 未完成（`0 < progress < 0.999`）→ 其他最近打开，同类按 `lastOpenedAt` 倒序稳定排序。
- 每条只展示横向封面、标题、时长/进度/缓存状态；不要额外放醒目的小播放按钮，点击整行即可续听。
- 模块底部不再显示 `查看全部`；完整历史统一从右侧入口进入。
- “首页外露条目无播放图标”只针对首页 3 条投影；完整 YouTube 页里的历史播放图标不在本次删除范围。
- 文本/图标使用 CastReader `AppTheme.primary` 品牌橙；不得另造红色或另一种橙色作为文字强调色。YouTube 红只允许用于必要的服务识别图形，不取代产品主色。

### 2.3 首次使用/空状态

没有历史时仍保留完整模块，不退回一条容易被输入功能淹没的普通输入栏：

- 一张空状态卡说明“朗读过的字幕稿会显示在这里”。
- 提供“粘贴视频链接”和“试听一个示例”。
- 首次成功必须以真实可听 playback tick 为准；仅打开页面、拿到字幕或写入音频缓存都不算学会。

### 2.4 六入口仍归一

首页模块升级不改变底层路由合同：

```text
share / clipboard / scheme / paste / sample / history
  → 同一种 YouTubeListenRequest
  → 同一缓存、提取、失败、播放器和 durable-share ack 管线
```

iOS 权威代码：

- `CastReader/Views/Home/HomeView.swift`
- `CastReader/Views/YouTube/YouTubeHomeView.swift`
- `CastReader/Services/YouTubeRouteCenter.swift`
- `CastReader/Views/MainTabView.swift`

Android 验收必须包含空状态、1 条、3 条、4 条以上、当前播放项、无底部“查看全部”、右侧入口可达完整历史，以及 TalkBack 整行可点击语义。

交接时静态审计的已知差异：Android `HomeScreen.kt` 仍主要显示静态 `YouTubeHomeEntryCard`；既有 `YouTubeHomeScreen`、`YouTubeHomeViewModel` 和 history/cache 状态可以复用。首页通用 Continue 已排除 YouTube，应继续保持，避免同一内容出现两次。

## 3. 字幕解析效率优化

### 3.1 性能问题拆分

“更快”不是缩短一个统一 timeout。必须分别优化：

- 权威无字幕：尽快给用户确定答复。
- 有字幕：尽早拿到第一份可信 cue。
- 缓存命中：不做重复磁盘解码或错误语言/音色探测。
- 首音：字幕完成后不再做阻塞式整段预热。

### 3.2 缓存与首音关键路径

iOS 最终策略：

1. 入口先做一次“key + 已验证 transcript document”的组合读取，避免先查 key 再从同一文件重复解码。
2. 缓存正文仍要通过实际语言和可朗读段校验；旧坏缓存不能为了速度被接受。
3. resume 段落、朗读语言和 voice 确定后再查精确音频 key。
4. 删除播放器之外的“整段 TTS 预热”；Reader/播放器建好后，由 `ReadAloudViewModel` 流式生成第一个 audio segment，收到即播，下一段随后预取。
5. artwork、缓存维护、manifest 清理均不阻塞 transcript-ready 或首音。

### 3.3 内容规则与 WebView 启动

- native 42 秒总预算从请求真正开始就计时，包含 content-rule lookup；不能让规则编译卡住而永不超时。
- 编译后的媒体拦截规则在进程内缓存，后续请求直接复用。
- WebView 使用固定 1280×800 viewport、真实内核身份和平台 desktop-content API。
- document-start 脚本先安装再导航；WebView 必须 attach 到真实但不可交互的宿主，避免 renderer/timer 不运行。

### 3.4 权威无字幕快速失败

无字幕不能仅凭“第一帧 tracks 为空”快速失败。iOS 只有同时满足下列正向证据并稳定后才返回 `no_captions`：

- 页面已进入 interactive/complete，网络不是离线。
- exact video ID 已匹配。
- initial player response 的 playability 为 `OK`（或平台等价的明确 playable），且 metadata 明确不是直播/已结束直播。
- 没有锁存的 signin/accounts/consent/sorry/机器人验证、年龄、会员、私享、地区等受限证据。
- initial player response、运行时 player response、vendored bridge 均无字幕轨。
- exact-video `ytInitialData` 没有 transcript endpoint。
- 官方 captions module 已 ready 且 track list 为空。
- 没有 decorated timedtext capture/resource、没有 native `<track>` 正向证据。
- 以上空证据至少从请求开始经过 3500ms、连续至少 4 个样本、稳定至少 1000ms。
- 返回前再做一次 bridge + synchronous snapshot；任何正向信号立即撤销 fast fail。
- 最终穷尽所有字幕来源时也不能退化成“`tracks` 为空且没看到 endpoint 就算无字幕”；只有上述 `conclusivelyNoCaptions` 权威门可以产出 `no_captions`。其余按已有证据归 `caption_access`、`timeout`、`network` 或结构错误。

真实 iOS 无字幕路径约 3.55 秒，而不是等待完整 42 秒。

实现审计警告：iOS fast-fail 门本身满足上述合同，但 2026-08-11 静态审计发现 vendored adapter 的最终穷尽分支仍保留一处旧的弱表达式（仅看 track 为空且未见 endpoint）。该兼容分支不是本文的正确合同，Android 禁止复制；Android 的所有 `no_captions` 出口都必须只读取严格的 `conclusivelyNoCaptions` 结果。

### 3.5 有字幕正向路径并行化

iOS 最终把可安全并发的相关请求并行，把无 correlation token 的旧 bridge 保持串行：

1. matching player 优先同步读取 `ytInitialPlayerResponse`，已有轨道/终态时不支付 bridge 单次等待。
2. direct `get_transcript` lane 在 player 匹配后立即启动，即使首帧尚无 endpoint；它只在本地轮询 `ytInitialData` 最多 6000ms，有 endpoint 才发网络请求。
3. direct lane 与 subtitle proof、官方 captions module/decorated URL hydration 并行。
4. direct cue 必须与所选 candidate 语言相容；否则不能抢赢。
5. direct 已返回可信 cue 时，官方等待立即停止。
6. 进入无 correlation token 的 transcript bridge 前必须先 await 已启动 direct lane，避免迟到响应被下一协议误消费。
7. BotGuard attestation 刷新 `bgevmc.cr()` 最多等待 800ms，不能吃掉整个字幕预算。
8. transcript panel 只作为最后兜底，并只读结构化 timestamp/text 行。

### 3.6 真实性能证据与 Android 门槛

真实 iPhone、链接 `https://youtu.be/K4nX1Fa7hdw`：

- request start → transcript ready：3114ms。
- 116 cues，正文英文检测置信度 1.00。
- request start → 首段音频开始播放：约 4.2 秒。

此前另两条成功视频 transcript-ready 约 6.77～7.14 秒，说明网络/页面状态仍会波动。Android 需要报告至少 10 次冷 profile 与 10 次已预热 profile 数据，不得只报最快一次：

- 无字幕明确答复目标：4 秒左右，且必须满足权威条件。
- 有字幕分享到首音：p50 < 5 秒，p95 < 12 秒；若设备/VPN环境不满足，必须附每次阶段日志和中位数，不能把失败隐藏为平均值。
- 42 秒是总硬上限，不因内部自动重试重置。

## 4. 不同语言字幕的语言判别

### 4.1 已发生的真实错误

链接：`https://youtu.be/K4nX1Fa7hdw?si=fXiXnKZS7Odn-J55`。

旧缓存出现：

```text
caption track: en / manual
cue text: 中文自动翻译
TTS request: lang=en
```

结果是中文正文被英文音色和英文 phonemizer 朗读。根因不是单一“语言识别器不准”，而是三层身份混淆：

1. App/UI 的 `zh-Hans` 被当成字幕事实语言，而它只能是选轨偏好。
2. YouTube 的 `tlang=zh` 自动翻译正文被套上原始 `lang=en` 轨道身份。
3. 语言纠正和音频缓存曾按视频/voice 过宽复用，旧错标能跨字幕 session 或共享 clone voice 继续命中。

### 4.2 三种语言必须分开

Android/iOS 都必须显式区分：

- `preferred/UI language`：只影响候选排序。
- `claimed track language`：YouTube 轨道声明的源语言。
- `detected cue language`：将真正发送给 TTS 的正文语言。

任何一项都不能无条件覆盖另外两项。

### 4.3 `tlang` 与候选绑定

- URL 的 `lang` 必须与 candidate 的 language/kind 一致。
- 若 decorated URL 尚未获取响应，且 `tlang` 与源 `lang` 不同，v1 删除 `tlang` 后请求原始字幕，同时保留同一合法 proof/client tuple。
- 若被动 capture 已经拿到带不匹配 `tlang` 的响应，正文已经被翻译，必须拒绝；删除 URL 参数不能把已返回的中文重新变回英文。
- v1 不把 YouTube 自动翻译冒充原字幕。翻译朗读仍是以后单独产品能力。

### 4.4 正文语言双重校验

JS 层先做保守的跨脚本 fast guard，至少能识别明显的中文/日文/韩文/天城文正文与候选不一致；拉丁语系的最终判断交给 native。

native 层：

- 最多采样前 80 cues、4000 字符。
- 先用脚本证据，再用平台语言识别器。
- 至少 48 个可读字符且置信度 ≥ 0.78 时视为强证据。
- candidate-bound 的 json3/srv3/native track/capture 若正文与 claimed language 强冲突，归 `caption_access`，不得缓存。
- transcript endpoint/panel 等未与候选结构绑定的来源必须用正文检测决定独立 track identity；若已有候选且强冲突，脚本应继续寻找原始轨，不能让翻译稿提前抢赢。
- 仅支持 `en, zh, ja, es, fr, de, pt, it, hi`；最终实际语言不支持时诚实报 `unsupported_language`。

### 4.5 缓存与人工纠正隔离

- fresh cache、network fallback cache 和新提取结果进入 Reader 前都运行正文语言校验。
- 旧的“英文轨 + 中文正文”缓存自动视为 miss，重新提取；不能要求用户清 App 数据。
- 用户人工纠正语言按 `contentSessionKey`（video + track provenance + transcript fingerprint）保存，禁止按 video ID 覆盖该视频以后选择的其他轨道。
- TTS audio key 必须包含 canonical playback language；voice code 不够，因为 clone voice 可能跨语言共享。
- iOS `YouTubeTTSAudioCacheSchema.current = 4`；Android 可用自己的版本号，但本次必须升级并使旧 key miss。

### 4.6 真机证据

同一 `K4nX1Fa7hdw` 修复后 iPhone 日志：

```text
caption source = transcript_endpoint
claimed = en
selected = en
detected = en
confidence = 1.00
readable characters = 3089
TTS language = en
```

Android 至少要验证：

- 上述英文视频在中文系统语言下仍取英文原字幕、英文 TTS。
- 中文源视频使用中文 TTS。
- `lang=en&tlang=zh` capture 不得缓存为 en。
- 同视频切换不同字幕 session 不串人工纠正。
- 同一 clone voice 的 en/zh 音频 storage key 不同。

## 5. Android 仍加载失败：iOS 如何解决登录、超时和字幕访问阻挡

### 5.1 先明确：iOS 没有使用 Google/YouTube 登录

iOS 最终没有走 Google OAuth，也不绑定用户 YouTube 账户，更不会继承已登录 Safari/Chrome/YouTube App 的 Cookie。功能承诺仍是“用户明确提交的、无需账号权限的公开视频字幕”。

iOS 能稳定工作的关键不是登录，而是给公开页面一个自洽、可持续、受限且可诊断的浏览器会话：

- 固定 UUID 的 YouTube 专用持久 `WKWebsiteDataStore`，只保留该提取器自己的匿名 visitor/consent 状态。
- 不与 Safari、系统浏览器、Kindle/Kobo/Google Books profile 混用。
- 使用真实 WebKit UA/指纹；只通过平台 API 请求 desktop content，绝不伪装 macOS Chrome。
- WebView 真正 attach 到透明、不可交互 window；脚本 document-start 注入，取完立即销毁视图，但持久 profile 保留。

### 5.2 早期为什么总是超时/网络失败

iOS 前期遇到的失败不是一个原因：

| 现象 | 真实根因 | 最终处理 |
|---|---|---|
| HTTP 200 但字幕 0 bytes | 伪造桌面 Chrome UA 与 WebKit 真实指纹不一致，BotGuard/PO token 不可用 | 删除 fake UA，保留真实 WebKit identity |
| 页面加载却永远无字幕 | 笼统阻断 media，把字幕 `<track>`/captions module 也挡掉 | 只拦截 `*.googlevideo.com` 音视频流 |
| 有轨道仍拿不到正文 | 裸 `baseUrl` 缺页面自身短时 proof/PO token | 捕获并验证官方 decorated `/api/timedtext` |
| 十几秒后笼统“网络失败” | 200 空体、caption access、真正网络错误混成同一类 | 拆分 `caption_access/network/timeout/no_captions` |
| 页面要求登录/验证 | initial response 与 media-blocked runtime response 证据被后者覆盖 | 锁存登录/验证证据，并仅对严格 public transcript 情况继续 |
| 整页文本看似有字幕 | transcript panel fallback 读了按钮/无障碍/时间码 | 只接受结构化 timestamp/text cues |
| 新请求偶发拿到旧视频 | WebView late callback 跨 session | single-flight + 随机 token + request/video ID + 一次完成门 |

### 5.3 iOS 的公开字幕取得阶梯

```text
exact-video player/initial response
  → 轨道/播放状态分类
  → 并发 direct get_transcript（有 endpoint 才联网）
  → 官方 captions module + decorated timedtext URL
      → json3
      → srv3
      → 无 fmt
  → native <track>/官方 timedtext response capture
  → 结构化 transcript panel bridge
  → 按证据分类失败
```

decorated URL 只允许：HTTPS、精确 `www.youtube.com` 同源、精确 `/api/timedtext`、expected video、candidate language/kind、一致 proof tuple、非空 `pot`、`potc=1`。完整 URL、query、token 永不进入 native 模型、缓存、日志、埋点或测试附件。

HTTP 语义要按资源层级区分：watch/main-frame 的 `401/403` 是 restricted，`404/410` 是 unavailable；单个 caption resource 的 `400/401/403/404/410` 若没有页面级账号权限或视频不可用证据，只说明这条字幕取得方式失败，继续其他可信来源，最终通常是 `caption_access`，不能凭单个字幕资源把整段视频误判成需要登录或已下架。`408/425/429/5xx` 与 DNS/连接错误才属于可重试 network 证据。

### 5.4 登录/机器人页不是一律立即失败

只有同时满足以下条件，iOS 才允许在一般 `LOGIN_REQUIRED` 播放器状态下继续尝试公开 transcript：

- 页面/initialData 的 video ID 精确等于请求 video。
- 页面明确是 bot-verification challenge，而不是年龄、会员、私享等权限。
- exact-video `ytInitialData` 已暴露 transcript endpoint。

成功拿到结构化公开 cue 后才把 playability 归回 playable。若 fallback 失败，仍保持 `restricted`；不能退化成 timeout、network 或 unavailable。真正的账号登录、年龄、会员、私享、地区和下架内容不会绕过。

### 5.5 Android 当前问题要分层处理

Android 华为日志已经出现至少三类互相独立的问题，禁止继续统一显示“需要登录”：

1. `canonical_host=false/mobile_host=false`：先被重定向到 consent/accounts/sorry/verify 等非 watch 页面。
2. 已进入 canonical watch，但 player 在平台窗口内未 hydration：`player_timeout`。
3. 系统网络层 `net::ERR_NAME_NOT_RESOLVED`：当前 VPN/DNS 无法解析，属于真实 network。

Android 应按平台做等价而非逐行照搬：

- 使用专用、持久、与 Kindle/Kobo/Google Books 隔离的 WebView profile；不能每次都是完全空的新匿名状态，也不能读取用户 Chrome 登录态。
- 若 profile 没有匿名 visitor 状态，可先用无 JS bridge、无 native message 能力、不可交互的短时临时 WebView初始化公开 YouTube 匿名会话；目标不超过 6 秒，若真机证明平台需要调整也必须计入同一 42 秒总预算。只检查允许的 cookie 名称/状态，不读取账号内容，不自动解决验证码。`CookieManager.flush()` 后销毁 bootstrap WebView，再建严格提取 WebView。
- consent/accounts/sorry/signin/verify 必须精确分类；普通受限内容仍 fail closed。匿名 session bootstrap 不是“自动点击同意”或绕过验证码。
- Huawei/Chromium player hydration 可使用经真机数据证明的独立平台窗口，但仍包含在 42 秒总预算内。
- `ERR_NAME_NOT_RESOLVED` 等明确瞬时网络错误可以最多安全重建一次：销毁旧 WebView、生成新 token/generation、旧 callback 全部作废；总预算不重置。再次失败就诚实返回 network。
- 自动重试不能把真实 restricted/private/age/member/geo/no-captions 变成网络重试。
- Release 构建也必须保留隐私安全的阶段日志，否则真机只看到 UI 文案无法定位。

### 5.6 必须输出的隐私安全阶段日志

每次请求至少记录，不含 URL query、字幕正文或 token：

```text
attempt/generation
elapsed_ms
anonymous_session_ready / bootstrap_result
main_frame classification
HTTP/WebView network error code
player matched / track count / transcript endpoint present
official decorated present（只记 bool）
每种 transcript source 的 status / bytes / cue_count
claimed / detected / selected language + confidence + sampled char count
terminal failure domain
WebView destroyed
transcript_ready / first_audio_ready
```

## 6. Android 强制测试矩阵

### 6.1 真实链接

| 目的 | 链接/视频 ID | 必须证明 |
|---|---|---|
| 原问题字幕访问 | `wpb-DrbhEiY` | 有字幕时不能误报无字幕/普通网络；成功源与耗时有日志 |
| 英文正文语言 | `K4nX1Fa7hdw` | 中文系统下 claimed/detected/TTS 均为 en |
| 音乐高亮 | `dQw4w9WgXcQ` 或当前 Rick Astley 样例 | 每段末词 timestamp 高亮完整 |
| 无字幕 | 选取确认无任何轨道的公开视频 fixture + 可控真实样本 | 权威 fast fail，不等满 42 秒 |

### 6.2 自动化

- sanitizer 与纯音乐段单测。
- timestamp 时间/单调/密度/覆盖/首尾质量门，以及完整逐词与缺尾整句 fallback 播放测试。
- 首页空/1/3/4+ 条 Compose 测试；新增语义断言证明首页无底部 `查看全部`、无行尾播放按钮，完整页入口仍可达。
- direct lane 与官方 proof 并发、bridge 串行合同测试。
- no-caption 空证据稳定窗口与正向信号撤销测试。
- `tlang` strip/reject、正文强冲突、unsupported language 测试。
- cache language/session/schema 隔离测试。
- bootstrap profile、cookie flush、旧 generation callback、一次网络重建、总预算不重置测试。
- restricted/no captions/network/timeout/caption access UI 与埋点映射测试。

### 6.3 最终完成门

Android 任务只有同时提供以下证据才能宣布完成：

1. 本文 1～5 节逐项功能对照表和修改文件。
2. 全量 unit、lint、global/cn debug/release compile 结果。
3. connected/instrumentation 的真实执行数；0 tests 不算通过。
4. APK 绝对路径、覆盖安装目标、冷启动结果。
5. 华为真机至少完成 `K4nX1Fa7hdw` 和一个音乐视频的“粘贴 → 字幕 → 正确语言 TTS → 末词高亮”。
6. `wpb-DrbhEiY` 若受当前 VPN/DNS 阻断，需同时用稳定网络复测；必须提供原始错误码、阶段日志和已排除项，不能用网络环境掩盖 App 自身问题。
7. 10 次性能表、p50/p95、无字幕时间、WebView 销毁证据。
8. 独立 P0/P1 复核归零；发现问题后完成修复和受影响套件重跑。

## 7. iOS 最终代码索引

| 合同 | iOS 文件 |
|---|---|
| 首页三条模块/完整页入口 | `CastReader/Views/YouTube/YouTubeHomeView.swift`、`CastReader/Views/Home/HomeView.swift` |
| 音乐符号规范化/可朗读判断 | `CastReader/Utils/LanguageDetector.swift` |
| timestamp 首尾完整性与逐词降级合同 | `CastReader/Models/TTSTimestamp.swift` |
| 前台 TTS、预取、高亮、语言纠正、音频 key | `CastReader/ViewModels/ReadAloudViewModel.swift` |
| fast fail、并发 direct、decorated URL、`tlang` | `CastReader/Services/YouTubeWebScripts.swift` |
| WebKit profile、安全边界、正文语言检测、阶段日志 | `CastReader/Services/YouTubeTranscriptService.swift` |
| transcript/TTS/progress/artwork cache | `CastReader/Services/YouTubeCacheStore.swift` |
| cache-first、Reader/首音启动 | `CastReader/Views/MainTabView.swift` |
| URL/cue/track/session models | `CastReader/Models/YouTubeTranscript.swift` |
| 对应回归 | `CastReaderTests/YouTube*Tests.swift`、`CastReaderTests/ReadingLanguageTests.swift`、`CastReaderTests/CastReaderTests.swift` |
