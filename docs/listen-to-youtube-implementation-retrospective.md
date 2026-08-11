# Listen to YouTube v1：功能总结、问题复盘与 Android 对齐基线

> 最终更新：2026-08-11  
> iOS 状态：开发、自动化、真实 iPhone 安装与用户验收完成  
> Android 状态：以本文与 `listen-to-youtube-ios-to-android-handoff.md` 的最终合同继续实现和验收

> **后续真机增量**：音乐歌词段尾高亮、首页三条内容模块、解析提速、正文语言与 `tlang` 校验，以及 Android 登录/超时/DNS 分层处理，已统一固化在 `docs/listen-to-youtube-ios-android-final-alignment.md`；Android 对齐以该文档为最高优先级。

## 1. 功能最终形态

Listen to YouTube 是“公开字幕稿朗读”，不是 YouTube 视频播放器，也不是下载器：用户分享或粘贴一个公开 YouTube 视频链接，CastReader 在隔离 WebView 中读取页面公开提供的字幕轨，把字幕转成原生阅读文档，再用 CastReader 自有 TTS 朗读。

完整用户链路：

1. 从系统分享、首页粘贴、剪贴板提示、示例、深链或历史进入；所有入口归一化为同一种请求。
2. 校验并规范化 `watch`、`m.youtube`、`youtu.be`、`shorts`、播放列表当前 `v=` 和 `t=` 起播时间。
3. 优先读取有效缓存；未命中时在隔离、不可见、单飞的 WebView 中提取元数据、字幕轨、cue、高清封面和 storyboard。
4. 按语言偏好选择人工/自动字幕轨，把 cue 稳定分段成原生字幕稿。
5. 首段 TTS 生成完成即开始播放，后续边生成边入队；支持词级高亮、自动滚动、点段跳播、倍速、音色、迷你播放器、锁屏/后台和进度恢复。
6. 顶部高清封面承载清晰的全宽画面，当前时间对应的 storyboard 预览帧按清晰度自适应为全宽或同步小窗；点时间戳才回到 YouTube。
7. 字幕、当前音色 TTS、进度、封面和 storyboard 存在 App 私有有界缓存；最多 50 个视频或 500 MiB，损坏自愈，徽标只在资源真实齐全时显示“已缓存”。
8. 外部分享进入持久 FIFO，只有真正出现可听播放 tick 后才 ack；失败、被杀或意外中断不会丢分享。

明确边界：不读取或缓存 YouTube 音视频流，不做 ASR/翻译，不做 OAuth，不绕过登录、年龄、会员、地区、私享或下架限制，不把页面杂讯冒充字幕。

## 2. 最终架构

```text
六类入口
  → URL/时间解析与统一路由
  → transcript cache 命中，或隔离 WebView 冷提取
      → 真实平台浏览器指纹 + 桌面内容模式
      → 播放器状态/轨道选择
      → 官方 decorated timedtext + PO token
      → json3 / srv3 / 无 fmt
      → 结构化 transcript panel 最后兜底
  → cue 校验与稳定分段
  → ReadingDocument(.youtube)
  → 既有 TTS / quota / player / highlight / history
  → transcript + TTS + progress + artwork 私有缓存
```

WebView 使用独立持久站点数据域，可保留提取器自己的 consent 状态，但不继承 Safari、Chrome 或 YouTube App 的登录 Cookie，也不影响 Kindle/Kobo/云盘等其他 WebView 会话。成功、失败、取消和超时都会销毁提取 WebView；随机 request token、精确 origin 和 video ID 防止旧回调或跨视频结果污染当前请求。

## 3. 字幕链路遇到的问题与最终解法

### 3.1 URL 与入口并不是“粘贴后打开页面”这么简单

- 移动端、短链、Shorts、播放列表和 query/fragment 起播时间格式不同。
- 相似恶意 host、credentials、显式 port、冲突的重复参数和整数溢出必须拒绝。
- Share Extension/Intent 进程寿命短，若只用内存事件，冷启动、进程被杀或失败重试都会丢请求。

最终用纯函数规范化 URL，并让所有入口进入统一 coordinator；外部分享先落持久 FIFO，可听确认后才删除。

### 3.2 过度拦截媒体资源误伤字幕

早期为了确保“不播放 YouTube 视频”，对 media resource 做了笼统拦截。这会把浏览器的字幕 `<track>` 或触发字幕模块所需资源一并挡掉，页面看似加载成功但永远没有 cue。

最终只拦截已确认的 `*.googlevideo.com` 音视频流，不使用会误伤 text track 的泛 media 规则；同时禁用自动播放，提取完成立即销毁页面。

### 3.3 页面未激活字幕模块

仅解析初始 HTML 或设置过于激进的 `preload=none` 时，YouTube 不一定触发字幕运行时和官方 timedtext 请求。最终保留播放器初始化所需的页面行为，在不加载音视频流的边界内等待字幕模块产出。

### 3.4 伪装桌面 Chrome 导致完整性校验失败

早期 iOS 把 WKWebView 的 UA 硬改为 macOS Chrome。UA 与真实 WebKit TLS/JS/Client Hints 指纹不一致，YouTube BotGuard/PO-token 会把它视为异常会话：请求可能返回 HTTP 200，却是 0 字节正文，因此十几秒后只能超时或误报网络失败。

最终删除 `customUserAgent`，保留真实 WebKit 指纹，仅使用 `.preferredContentMode = .desktop` 请求桌面页面。Android 同样必须使用真实 Android WebView 身份，通过平台设置请求桌面内容，不能复制一个虚假的桌面 Chrome 版本。

### 3.5 丢失官方 decorated timedtext URL

目标视频明明存在两条人工字幕轨，但普通 caption `baseUrl` 和自行拼接 URL 均返回空内容。页面自身发出的 `/api/timedtext` 请求带有短时 PO token；早期适配器只保留普通 baseUrl，把真正能用的 decorated URL 丢掉。

最终方案：

- 在页面主世界捕获官方请求，必要时从 Resource Timing 恢复。
- 只接受 HTTPS、精确同源 `/api/timedtext`、精确 video/language/kind、非空 `pot`、`potc=1` 的候选。
- token 只存在本次 JS 内存，完整 URL/token 永不进入日志、埋点、native 错误、文件或 transcript identity。
- 可信 URL 按 `json3 → srv3 → 无 fmt` 请求；再尝试普通 baseUrl；最后才用结构化 transcript panel。

这修复了 `wpb-DrbhEiY`：真机获得 907 条 cue，timedtext HTTP 200、95,581 bytes，冷提取约 7.9 秒。

### 3.6 官方 transcript endpoint 并非通用替代品

直接调用页面 transcript endpoint 对该视频返回 `400 FAILED_PRECONDITION`。它只能作为严格受控的页面 fallback，不能假设“视频有字幕 = endpoint 一定可直接调用”，也不能以服务端 API 或 OAuth 偷换本期产品边界。

### 3.7 错误分类掩盖了真实原因

“没有字幕”“网络连接失败”和“视频有轨道但本会话无法取得正文”是三件不同的事。早期空响应最终被映射成 no captions/network，用户看到的事实明显不对，日志也无法定位。

最终增加 `caption_access`：已确认有可选轨道，但 decorated/raw/panel 都无法取得或 HTTP 200 空体时，明确提示字幕暂时无法读取并允许重试。`no_captions` 只用于确定没有可读轨道；明确网络异常才是 `network`。

### 3.8 DOM fallback 容易读取页面杂讯

整页 `innerText`、时间戳按钮、无障碍说明和折叠标题都可能“看起来像字幕”。另一个坏缓存形态是多条文本全部变成 `00:00`。

最终只解析结构化 timestamp/text 子节点；多 cue 却全部同一 0ms 判 malformed 并清除旧缓存，绝不朗读页面杂讯。

### 3.9 超时、取消与旧回调竞态

WebView 导航、bridge、panel、native timeout 若各自重新计时，总等待会失控；新请求取消旧请求后，旧页面还可能迟到回调污染新视频。

最终使用从导航开始计算的 42 秒 native 硬上限和 34.5 秒 adapter 预算；全链路 single-flight、随机 identity 和一次性 continuation，完成后统一释放 WebView/callback。

### 3.10 日志本身可能泄露凭据

为了查空响应若直接打印请求 URL，会把 PO token 和签名参数写入 Console/xcresult。最终 DEBUG 诊断只记录阶段、状态码、byte/cue/track 数、耗时和脱敏原因；URL、query、token 和 bridge payload 全部禁止输出。

## 4. 画面模糊问题与最终解法

### 4.1 根因是源像素，不是裁剪二次压缩

旧实现固定优先 storyboard L2。目标视频的 L2 单帧只有 160×90，sprite sheet 为 800×450；iPhone 15 Pro Max @3x 全宽大约需要 1194×672 物理像素，把 160×90 放大 7 倍以上必然模糊。缓存保留原始 bytes，`CGImage.cropping` 没有再次 JPEG 压缩，因此调缓存格式无法凭空补回细节。

### 4.2 最终清晰度策略

- 在所有合法候选中选择单 tile 像素面积最大者，而不是固定 L2；目标视频最终选到 L3 320×180、10 秒一帧、15 张 sheet，像素面积提升 4 倍。
- 同时收集 videoDetails、microformat、Open Graph 等缩略图候选，按声明尺寸和 `maxres/sd/hq` 质量选择最高合法封面；目标视频可用 1280×720。
- storyboard tile 达到全宽物理像素 80% 覆盖时才允许全宽；不足时使用高清封面全宽，当前 storyboard 作为 120–180pt 同步小窗。
- 使用高质量插值，把切帧淡入缩短到约 150ms；这些只改善观感，不能替代真实源分辨率。
- artwork schema 升到 2，使旧低清图片元数据重新提取，但保留 transcript、TTS 和进度。
- “已缓存”同时要求声明的高清封面和全部 storyboard sheet 可解码，不能因已有低清分镜就跳过封面。

### 4.3 图片与缓存安全

每张资源最大 20 MiB，宽高各不超过 8192，总像素不超过 32M；storyboard sheet 还必须满足 tile grid 最小尺寸，sheet 数最多 512。先探测尺寸再采样解码，裁剪 rect 必须 clamp；坏图、缺最后一张 sheet、异常 manifest 会自愈并继续有界重试，永不阻塞字幕或首音。

## 5. 其余工程问题与经验

- TTS 队列短暂为空但仍有生成任务时不能误判全文结束，依靠 `moreSegmentsExpected` 等价状态等待后续 segment。
- 当前段高亮必须以 CastReader TTS 返回的 processed text/timestamps 为准，不能把时间戳硬映射回 YouTube 原 cue 文本。
- 点段落是在 App 内跳 TTS，点时间戳才跨 App 回视频；二者语义必须分开。
- 缓存身份必须绑定 video、轨道 provenance、transcript fingerprint、voice 和 schema，避免换轨/换音色串数据。
- 非空文件不代表有效缓存；JSON、音频、图片和 manifest 都要验证并自愈。
- 高频缓存写入不能反复取消刷新任务，否则徽标会饥饿；使用 single-flight + coalesced trailing refresh。
- 历史/徽标只读检查不能刷新 LRU；只有真实读取或播放才 touch。
- 本机一度出现共享 per-user fork 上限、残留 Gradle/UTP launcher、模拟器 launchd EAGAIN 和锁屏无法自动 launch。这些是测试基础设施问题，不是产品链路修复；最终证据必须区分“代码通过”“设备安装成功”和“用户真机操作已验收”。

## 6. iOS 最终验证证据

- 问题 URL：`https://m.youtube.com/watch?v=wpb-DrbhEiY&pp=iggCQAE%3D&ra=m`
- 真实 iPhone 两次冷提取均成功：2 条人工轨、选中 `zh-Hans`、907 cue、95,581 bytes、约 7.89–7.90 秒。
- 真实页面 storyboard：L3、320×180、10,000ms、15 sheets；高清封面 1280×720。
- Swift 静态解析、生成 JS `node --check`、`git diff --check` 通过。
- `YouTubeTranscriptTests`、`YouTubeCacheStoreTests`、`YouTubeWebScriptsTests`、`YouTubeTranscriptServiceTests` 定向套件通过；真实 iPhone live XCTest 通过。
- App build、link、sign、install 成功，bundle id `com.same.castreader`。
- 最新真机结果包：`/Users/xuxuheng/Library/Developer/Xcode/DerivedData/CastReader-cwsteljoauziumebymxdgiipcrjz/Logs/Test/Test-CastReader-2026.08.10_17-49-24-+0800.xcresult`。
- 2026-08-10 用户最终手工验收：字幕可以朗读，图片已清晰，无剩余阻断问题。

## 7. Android 本次必须完成的增量

Android 现有实现不得重写或回退，需在已完成的入口、路由、播放器、UI、缓存和测试基础上补齐最终 iOS 差异：

1. 删除硬编码/伪造桌面 Chrome UA，保留 Android WebView 真实身份并用平台方式请求桌面内容。
2. 将媒体拦截收窄到 `*.googlevideo.com` 音视频流，证明不会误杀字幕 track。
3. 捕获并严格验证官方 decorated timedtext URL；加 Resource Timing fallback；token 仅留 JS 内存且日志完全脱敏。
4. 实现 `json3 → srv3 → 无 fmt` 的 decorated/raw 重试和 200 空体处理。
5. 增加 `caption_access` 领域错误、UI 文案、本地化、埋点白名单与缓存 fallback 语义。
6. storyboard 改为选择像素面积最大的合法候选，并增加整 sheet 尺寸/像素上限测试。
7. 缩略图多源择优；实现高清封面全宽 + 低清同步帧小窗/足够清晰时全宽的自适应 UI。
8. 增加 artwork schema 升级，只刷新旧 artwork；完整离线 coverage 同时要求 thumbnail 和全部 storyboard sheets。
9. 用相同问题 URL完成真实 Android WebView 冷提取，不用 iOS fixture 伪装成功；记录轨道、cue、段落、耗时、首音、画面层级和 WebView 销毁证据。
10. 完成 unit、lint、各 flavor debug/release、connected/instrumentation、安装、冷启动、分享/粘贴到首音、缓存离线重开的回归；失败后自行修复并重跑，P0/P1 归零后才宣布完成。

## 8. Android 完成门

Android 最终报告必须给出：功能对照表、修改文件、每套命令及通过数/report、APK 绝对路径、安装目标、冷启动结果、真实 URL cue/paragraph/首音计时、高清封面/同步分镜截图或 UI 证据、PO-token 脱敏证明、故障注入/缓存自愈证据、独立 P0/P1 复核结论。

若仅因外部网络或设备不可用无法完成某项，必须提供原始日志、已排除项与重试记录；不能把 fixture、编译成功或 iOS 用户验收代替 Android 自己的端到端证据。
