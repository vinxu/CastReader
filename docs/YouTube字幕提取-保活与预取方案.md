# YouTube 字幕提取 · 保活 WebView + 后台续拉方案

> 前置：`docs/YouTube字幕语言切换-iOS实施方案.md`（P0/P1 已实现）。本文解决切换语言慢的问题。

## 0. 问题与结论

切换语言慢，慢在**每次都重跑一遍完整 bootstrap**：新建 WKWebView → 导航 watch 页 → 等 player response → 等 PO token → 才发 timedtext 请求 → 拿到结果立刻 `tearDown` 销毁。

而单条 timedtext fetch 的超时上限只有 **1.7 秒**（[YouTubeWebScripts.swift:2116](../CastReader/Services/YouTubeWebScripts.swift:2116)）。剩下全是 bootstrap。

**为什么不能把 bootstrap 结果缓存下来**：最关键的 PO token 是 short-lived + video-scoped，且设计上从不离开页面世界（[YouTubeWebScripts.swift:161](../CastReader/Services/YouTubeWebScripts.swift:161) 的注释）；track `baseUrl` 带 `expire=` 签名，是 bearer 凭据，仓库刻意不落盘（`XCTAssertFalse(document.track.baseURL.contains("expire="))`）。**该复用的不是凭据，是那个已经跑完 bootstrap 的 WebView。**

| 方案 | 首次打开 | 切换 |
|---|---|---|
| 现状 | 基准 | 同首次 |
| M1 保活 | **不变** | 只剩 1 次 fetch |
| M1 + M2 续拉 | **不变** | 命中缓存则 0 网络 |

**首次打开耗时不得回归**是本方案的硬约束：拿"第一次变慢"换"切换变快"是倒退。

---

## 1. M1：保活 WebView

### 1.1 概念

`YouTubeTranscriptService` 引入 warm session：提取成功后不销毁 WebView，保留供**同一 videoId** 的后续请求复用。

```swift
private final class WarmSession {
    let videoId: String
    let token: String            // 页面侧校验用，复用期间不变
    let webView: WKWebView
    let hostingWindow: UIWindow
    var lastUsedAt: Date
    var idleTask: Task<Void, Never>?
    var availableTracks: [YouTubeCaptionTrackOption]
}

private var warmSession: WarmSession?
```

`takeActive` → `tearDown` 现在无条件销毁（[YouTubeTranscriptService.swift:1192](../CastReader/Services/YouTubeTranscriptService.swift:1192)）。改为：成功路径把 WebView 移交给 warm session，失败路径仍然销毁。

**只对同一 videoId 复用**——proof 是 video-scoped，换视频必须重建，没有例外。

### 1.2 页面侧：可重入入口

adapter 现在是一次性的：`run()` 跑完 `postOnce(envelope)` 就结束。需要在 post 之后注册常驻入口：

```js
// 在 postOnce(envelope) 之后
window.__crYtExtractTrack = async function (requestToken, trackId, languageCode, kind) {
  if (requestToken !== REQUEST_TOKEN) return;      // 页面自己调用无效
  // 复用当前内存里的 capturedSubtitleProof / player.tracks / fetchViaMainWorld
  // 结果经同一个 messageHandler post，带 native 传入的 followUpId 区分
};
```

复用的都是已在内存中的状态：`capturedSubtitleProof`、`player.tracks`、`officialCaption`、`fetchViaMainWorld`。不需要重新导航、不需要重新等 proof。

**安全**：`REQUEST_TOKEN` 校验必须保留——这是防止页面脚本自己触发提取的现有边界，复用入口不能把它绕开。native 每个 follow-up 请求另发一个 `followUpId`，用于把响应对上号。

**改了 adapter 就要 bump bootstrap 版本**（见记忆 `kindle-reader-hardening-primitives` 的同类要求）。

### 1.3 native 侧：follow-up 请求

```swift
func extract(
    _ reference: YouTubeVideoReference,
    preferredLanguage: String,
    requestedTrack: YouTubeTrackRequest? = nil,
    ...
) async throws -> YouTubeTranscriptDocument {
    if let warm = warmSession, warm.videoId == reference.videoId, let requestedTrack {
        if let document = try? await extractFromWarmSession(warm, requestedTrack) {
            return document
        }
        // 保活路径失败一律回退完整 bootstrap，不把失败暴露成产品错误
        discardWarmSession()
    }
    // ...既有完整路径
}
```

`evaluateJavaScript` 一律走 `evaluateJavaScriptBounded`（8s 上限）——记忆 `kindle-reader-hardening-primitives`：产品代码里的无界 WebView 等待已经清零，这条不能破。

### 1.4 生命周期（方案的主要工作量）

一个隐藏的 youtube.com 页面常驻是有代价的，销毁条件必须穷尽：

| 触发 | 处理 |
|---|---|
| 空闲超时（建议 **180s**） | 销毁 |
| `didEnterBackgroundNotification` | 销毁 |
| `didReceiveMemoryWarning` | 销毁 |
| 请求的 videoId 不同 | 销毁重建 |
| 阅读器关闭该 YouTube 会话 | 销毁 |
| follow-up 返回 403 / 空 cue（proof 失效） | 销毁 + 回退完整 bootstrap |
| WebView 发生非预期导航 | 销毁 |

最后一条要特别处理：YouTube 是 SPA，页面自己可能导航/刷新。`navigationDelegate` 在保活期间要继续持有，任何主帧导航都视为状态失效。

**内存**：媒体已被 content rule list 屏蔽，比正常 watch 页轻，但仍有数十 MB。空闲 180s 即销毁是主要缓解手段。

> 项目里已有同样的哲学——CLAUDE.md 避坑第 10 条「绑定书库的 WKWebView 是有状态资产，别为了刷新 UI 去 reload/重建」。Kindle / 微信读书都这么做，只是 YouTube 提取器当初被当成一次性工具。区别在于那些 WebView 用户可见、生命周期跟着阅读器；这个是隐藏的，所以**必须自己管到底**。

---

## 2. M2：后台续拉

### 2.1 时机

**在首轨 `continuation.resume` 之后**启动，绝不阻塞首次可听。依赖 M1 的常驻入口和保活的 WebView。

### 2.2 策略

- **串行**：bridge 的 fetch 通道是单槽位无关联 id 的（`document.body.dataset.crYtFetchUrl` + 无 token 的事件），并发会串包。adapter 里那句 "The vendored bridge has no per-request correlation token" 就是在说这事。串行 + 每条之间留间隔（建议 **500ms**），顺带降低限流风险。
- **只拉可朗读的语言**：`YouTubeCaptionTrackOption.isPlayable`（九语闸门）为假的轨拉了也不能听。
- **排序**：UI 语言 → 英语 → 其余，人工轨优先于 ASR。
- **上限**：最多 **6 条**。有些视频有 30+ 社区轨，全拉是浪费。
- **落盘**：每条拉到即 `storeTranscript`，独立 cacheKey。面板的「可立即切换」标记会自然亮起，不需要额外通知机制。
- **可中断**：用户手动选了某语言，若续拉正在拉别的，立即中止并优先拉目标轨。
- **不碰额度**：拉的是字幕稿，不生成 TTS，与 `QuotaManager` 无关。

### 2.3 缓存与淘汰

一条 30 分钟字幕稿约 50–150KB，6 条 ≈ 0.3–0.9MB。上限 500MB / 50 视频，放得下。

**待确认**：预取的轨在 LRU 里应该比用户真正听过的轨更早被淘汰。现在 `lastAccessAt` 一视同仁，预取会让它们看起来和主动使用一样"新"。建议给 manifest entry 加一个 `wasPrefetched` 标记，淘汰时优先。

---

## 3. 埋点

现有 `yt_extract_done` 加两个可选字段（同步 `mobile-events-v2.json` + `ProductAnalyticsTests` + Android 契约）：

- `warmSession: Bool` —— 这次提取是否命中保活
- `prefetchedTrackCount: Int` —— 续拉成功条数

`yt_caption_language_switch` 已有 `cacheHit`，补 `elapsedMs` 实际值，用于验收前后对比。

---

## 4. 验收

| 项 | 标准 |
|---|---|
| 首次打开 | `yt_extract_done.elapsedMs` 分布**无回归**（硬门槛） |
| 切换（保活命中） | 显著低于完整 bootstrap，目标 ≤ 3s |
| 切换（预取命中） | 无网络请求，≤ 500ms |
| 内存 | 保活期间峰值增量可接受，空闲 180s 后回落 |
| 生命周期 | 后台 / 内存警告 / 换视频 / 非预期导航后，WebView 确实已释放（单测 + Instruments） |

**回归重点**：保活复用了页面里那份 `player.tracks`，必须验证 SPA 导航后不会拿到别的视频的轨——现有 `EXPECTED_VIDEO_ID` 校验要在 follow-up 路径里同样生效。

---

## 4.5 实测：成本确实全在页面侧（2026-08-12，真机 iPhone 15 Pro Max）

一次被 bot 墙拦下的提取，`ReaderRunLog` 里的分解：

```
CRYT stage=request_started            elapsedMs=3
CRYT stage=content_rule_lookup_started elapsedMs=3
CRYT stage=content_rule_ready         elapsedMs=10
CRYT stage=navigation_started         elapsedMs=11
CRYT stage=message_received           elapsedMs=5738
```

| 阶段 | 耗时 |
|---|---|
| native 全部（建 WebView + content rule + 发起导航） | **11 ms** |
| 页面侧（加载 → player → 判定） | **5727 ms** |

这还是**提前失败**的路径。成功路径要再加 proof 等待（500–900ms）和 timedtext 请求，而单条 fetch 上限只有 1.7s。**native 开销可忽略，保活省掉的正是那 5 秒以上的页面部分。**

> 采集方式：`recordStage` / envelope / diagnostics 同时写进 app 沙盒的 `Documents/reader-refocus.log`（DEBUG-only），用 `xcrun devicectl device copy from --domain-type appDataContainer` 拉取。设备 console 那条路走不通——`NSLog` 走 os_log，`idevicesyslog` 抓不到，`log collect --device-udid` 要 root。

## 5. 分期与风险

**M1 保活 —— 已实现（2026-08-12），真机未验证**：代码完成、779 单测通过、已覆盖安装到真机。验证窗口被一轮 bot 验证墙（`LOGIN_REQUIRED` / `restricted_video`）挡掉了，成功路径一次都没跑通，因此**保活复用的实际收益尚未被观测到**。

> 那轮拦截**与保活无关**，已定位为 VPN 出口 IP 的信誉问题——换一个节点后立刻全部正常，且同样的挑战在保活存在之前就出现在模拟器上。曾据此错误地把 `warmSessionEnabled` 关掉，现已恢复默认开启，并保留 `-CastReaderDisableYouTubeWarmSession` 启动参数（DEBUG）用于将来做单变量 A/B。

恢复这条线时第一件事：找一个能正常解析的多语视频，同一视频连切两次语言，看第二次是否跳过 bootstrap。

**M2 续拉未开始。**

→ **M2 续拉**（依赖 M1 的常驻入口）→ **M3 可选**：评估把主帧 `cachePolicy` 从 `.reloadIgnoringLocalAndRemoteCacheData` 放宽。M3 要单独实测，那个策略大概率是为了防 SPA 缓存导致的视频串台，动它要有专门的串台回归。

| 风险 | 应对 |
|---|---|
| 隐藏 WebView 常驻内存 | 空闲 180s + 后台 + 内存警告三重销毁 |
| proof 中途失效 | follow-up 失败即销毁保活并回退完整 bootstrap，用户只感知"这次慢一点" |
| YouTube 限流（续拉） | 串行 + 500ms 间隔 + 上限 6 条；观察 `yt_extract_fail` 是否上升 |
| SPA 自行导航导致状态错乱 | 保活期间保留 navigationDelegate，任何主帧导航即销毁 |
| adapter 变复杂 | 常驻入口只复用内存状态，不新增网络协议；`REQUEST_TOKEN` 校验不放宽 |
