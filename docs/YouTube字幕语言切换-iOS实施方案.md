# YouTube 字幕语言切换 · iOS 实施方案

> 前置阅读：`docs/listen-to-youtube-ios-plan.md`（v1 基线）、`docs/iOS-Nine-Language-Service-Contract.md`（九语合同）。
> 本文只覆盖**原生多语字幕轨切换**。机器翻译轨（`tlang`）是另一件事，见 §11。

## 0. 现状结论

**选轨规则**（v1 已上线）：跟 App 内语言设置走，不是视频语言，也不直接是系统语言。

| 环节 | 位置 |
|---|---|
| UI 语言 → `preferredLanguage` | [MainTabView.swift:839](../CastReader/Views/MainTabView.swift:839) `preferredYouTubeCaptionLanguage` |
| 注入网页 `PREFERRED_LANGUAGE` | [YouTubeWebScripts.swift:617](../CastReader/Services/YouTubeWebScripts.swift:617) |
| 排序打分 | [YouTubeWebScripts.swift:1888](../CastReader/Services/YouTubeWebScripts.swift:1888) `orderedTracks` |
| 正文语言复核 | [YouTubeTranscriptService.swift:308](../CastReader/Services/YouTubeTranscriptService.swift:308) `validatedPlaybackLanguage` |
| 九语闸门 | [YouTubeTranscript.swift:761](../CastReader/Models/YouTubeTranscript.swift:761) `YouTubeTranscriptLanguagePolicy` |

rank：精确语言码人工(0) → 精确 ASR(1) → 基码人工(2) → 基码 ASR(3) → 英语人工(4) → 英语 ASR(5) → 其他人工(8) → 其他 ASR(9)。取排序后**第一个真抓到 cue 的**候选。

**已经就位的地基**（这是本方案成本低的原因）：

- `YouTubeTranscriptCacheKey = videoId + trackLanguage + trackIdentity + cue指纹` → 同一视频多语字幕天然并存
- `YouTubeTTSAudioCacheKey` 含 `transcriptFingerprint + voiceCode + playbackLanguage` → 换轨音频天然不串
- `contentSessionKey = "youtube-<cacheKey.storageKey>"` → **换轨即换会话**
- [MainTabView.swift:700](../CastReader/Views/MainTabView.swift:700) 已有「同 `document.id`、不同 `contentSessionKey` 则先 close」的分支 —— 正是换轨这个场景
- [ReadAloudViewModel.swift:461](../CastReader/ViewModels/ReadAloudViewModel.swift:461) 语言纠正 override 对 YouTube 按 `contentSessionKey` 存，注释已写明「每条轨是自己的 content session，旧纠正不得污染新轨」

**因此音色与 TTS 语言不需要额外代码**：`coordinator.open(新document)` 会重建 `ReadAloudViewModel`，其 `init` 用 `document.language`（= 新轨语言）取 `AppSettings.shared.voice(for:)`，即用户为该语言设置的偏好音色。

**缺口只有三处**：① 可用轨列表没上报；② 提取无法指定轨；③ 没有 UI 入口。

---

## 1. 产品定义

**入口**：朗读页头部 `YouTubeArtworkHeader` 的元信息行，把「频道 · 字幕稿」改成「频道 · `[English ⌄]`」，chip 可点。

**交互**：
1. 点击 → 弹语言面板（当前轨打勾）
2. 选中语言 L → 缓存命中则**秒切**；未命中则遮罩重新提取
3. 切换成功 → 从**同一时间点**继续，用新语言音色朗读
4. 切换失败 → **保留原会话继续播**，只弹提示，不把用户扔在空页

**边界**：
- 可用轨 ≤ 1 时不显示 chip
- 非九语轨在列表里置灰 + 「暂不支持朗读」说明（不隐藏——用户需要知道这个视频有该语言字幕）
- 自动生成轨标 badge「自动生成」

**与「纠正朗读语言」的区别 —— 不要复用同一个入口**：

| | 纠正朗读语言（已有） | 切换字幕语言（本方案） |
|---|---|---|
| 改什么 | 同一份文本换 TTS 语言/音色 | 换文本源（另一条字幕轨） |
| 场景 | 语言误判 | 视频有多语字幕 |
| 会话 | 不变 | 新 `contentSessionKey` |
| 入口 | 播放条音色面板 | 朗读页头部 chip |

混用的后果：用德语音色念英文字幕。

---

## 2. 数据契约变更

### 2.1 envelope 增 `availableTracks`

`schemaVersion` **保持 1**：JS 与 native 同包发布，每次提取注入的都是当次 JS，不存在跨版本 envelope。新增可选字段即可，`YouTubeTranscriptExtractionEnvelope` 的 `schemaVersion == 1` 校验不动。

JS 侧（[YouTubeWebScripts.swift:2622](../CastReader/Services/YouTubeWebScripts.swift:2622) `makeEnvelope`）：

```js
// makeEnvelope 内新增
availableTracks: null,   // null = 未知；[] = 明确无

// 拿到 player.tracks 后（2752 行 orderedTracks 附近）立即填充，
// 与抓取成败无关 —— 失败时列表同样有用
envelope.availableTracks = orderedTracks(player.tracks, uiLanguage)
  .slice(0, 40)
  .map(function (candidate) {
    return trackEnvelope(candidate.track, candidate.index);
  })
  .filter(Boolean);
```

复用现成的 `trackEnvelope()`（[YouTubeWebScripts.swift:1953](../CastReader/Services/YouTubeWebScripts.swift:1953)），它已经只输出 `{id, name, languageCode, kind, vssId, index}`。

> **铁律**：`baseUrl` 绝不能进列表。带签名的 timedtext URL 是 bearer 凭据，v1 已经刻意让 `YouTubeCaptionTrack.baseURL` 存 track id 而非真 URL（[YouTubeTranscriptService.swift:461](../CastReader/Services/YouTubeTranscriptService.swift:461) 的注释），这条不能破。

截断 40 条是防御性上限，与 `cues.count <= 200_000` 同类。

### 2.2 新 model `YouTubeCaptionTrackOption`

放 `Models/YouTubeTranscript.swift`（Foundation-only，Share Extension 也编）：

```swift
struct YouTubeCaptionTrackOption: Codable, Equatable, Sendable, Identifiable {
    let id: String              // vssId，或 languageCode|kind|name|index
    let languageCode: String
    let name: String?
    let kind: String?           // "asr" / "manual"

    var isAutomatic: Bool { kind?.lowercased() == "asr" }

    /// 能否朗读：走九语闸门，UI 据此置灰
    var isPlayable: Bool {
        (try? YouTubeTranscriptLanguagePolicy.playbackLanguage(for: languageCode)) != nil
    }
}
```

`YouTubeTranscriptDocument` 增 optional 字段：

```swift
let availableTracks: [YouTubeCaptionTrackOption]?   // nil = 旧缓存，未知
```

**必须是 optional**：旧缓存文件 decode 时为 nil，UI 退化为「只有当前语言」而不是崩。

**绝不能进 `cacheKey`**：`YouTubeCacheStore.cacheKey(for:)` 只用 `videoId + trackLanguage + trackIdentity + 指纹`。若把列表算进去，YouTube 上新一条字幕轨就会让所有旧缓存和进度失效。

去重与规范化在 native 侧做（同 `languageCode + kind` 只留第一条，`languageCode` 走 `normalizedLanguage`）。

### 2.3 指定轨提取

`YouTubeTranscriptService.extract` 增参数：

```swift
struct YouTubeTrackRequest: Equatable, Sendable {
    let id: String?             // vssId 优先
    let languageCode: String
    let isAutomatic: Bool
}

func extract(
    _ reference: YouTubeVideoReference,
    preferredLanguage: String,
    requestedTrack: YouTubeTrackRequest? = nil,   // 新增
    timeout: TimeInterval = defaultExtractionTimeout,
    onTranscriptReady: ((YouTubeTranscriptDocument) -> Void)? = nil
) async throws -> YouTubeTranscriptDocument
```

沿 `ActiveRequest` → `documentStartScripts(...)` → `extractionAdapter(...)` 一路透传，JS 侧注入三个字面量 `REQUESTED_TRACK_ID / REQUESTED_TRACK_LANGUAGE / REQUESTED_TRACK_KIND`，在 `orderedTracks` 之后置顶：

```js
function pinRequestedTrack(candidates) {
  if (!REQUESTED_TRACK_ID && !REQUESTED_TRACK_LANGUAGE) return candidates;
  var exact = null, loose = null;
  candidates.forEach(function (candidate) {
    var track = candidate.track;
    var identity = trackEnvelope(track, candidate.index);
    if (!identity) return;
    if (REQUESTED_TRACK_ID && identity.id === REQUESTED_TRACK_ID) {
      if (!exact) exact = candidate;
      return;
    }
    if (!loose &&
        languageAliasMatches(track, REQUESTED_TRACK_LANGUAGE) &&
        (isASR(track) ? 'asr' : 'manual') === REQUESTED_TRACK_KIND) {
      loose = candidate;
    }
  });
  var pinned = exact || loose;
  if (!pinned) {
    note('requested track missing id=' + String(REQUESTED_TRACK_ID || '') +
         ' lang=' + String(REQUESTED_TRACK_LANGUAGE || ''));
    return [];                                  // ← 见下方「失败语义」
  }
  return [pinned];
}
```

**失败语义（重要）**：指定轨模式下**不做跨语言 fallback**。找不到就返回空候选集，让 adapter 走既有失败路径。理由：用户明确要德语，静默给他英语比失败更糟——而 v1 的 fallback 链是为「首次打开、无明确诉求」设计的。

`cuesMatchCandidateLanguage` 与 native `validatedPlaybackLanguage` 的严格校验**一律不放宽**。换轨恰恰是最容易拿到机翻轨的场景。

### 2.4 新 failure case

```swift
case trackUnavailable = "track_unavailable"
```

`YouTubeTranscriptFailure` 是 `String` + `CaseIterable` + `Codable`，新增 case 要同步改的位置：

1. `errorDescription`（[YouTubeRouteCenter.swift:318](../CastReader/Services/YouTubeRouteCenter.swift:318)）→ 「这个语言的字幕暂时读不到」，九语齐全
2. `MainTabView.youtubeAnalyticsFailureReason` 映射
3. **`ProductAnalytics` 的 `yt_extract_fail` reason 白名单**（[ProductAnalytics.swift:805](../CastReader/Services/ProductAnalytics.swift:805)）—— 硬编码数组，漏改会在运行时抛 `AnalyticsSchemaError`
4. `docs/analytics/mobile-events-v2.json` + `ProductAnalyticsTests`

---

## 3. 切换流程

新建 `Services/YouTubeCaptionLanguageSwitcher.swift`（`@MainActor final class`，`MainTabView` 持有 `@StateObject`）：

```swift
@MainActor
final class YouTubeCaptionLanguageSwitcher: ObservableObject {
    enum State: Equatable { case idle, switching(String), failed(String) }
    @Published private(set) var state: State = .idle
    private var task: Task<Void, Never>?
}
```

### 状态机

```
用户选中语言 L
  │
  ├─ 0. 单飞：task?.cancel()，YouTubeTranscriptService.shared.cancel()
  │
  ├─ 1. 记录 resumeAnchorMs = 当前段 startMs（跨轨对齐锚点）
  │     并对旧轨 commit 一次 progress
  │
  ├─ 2. 查缓存 mostRecentPreferredTranscript(videoId:, preferredLanguage: L)
  │     命中且 baseLanguage(track.languageCode) == L  →  跳到 5（秒切，无遮罩）
  │
  ├─ 3. state = .switching(L)，展示遮罩（可取消）
  │
  ├─ 4. extract(reference, preferredLanguage: L, requestedTrack: option)
  │     ├─ 成功 → validatedPlaybackLanguage + firstPlayableParagraph 校验 → storeTranscript
  │     └─ 失败 → state = .failed，保留原会话，toast 提示 ← 关键：不 close 旧会话
  │
  ├─ 5. document = YouTubeReadingDocumentBuilder.make(transcript:cacheHit:)
  │
  ├─ 6. 换会话：
  │     if coordinator.session?.document.id == document.id,
  │        coordinator.session?.id != document.contentSessionKey { coordinator.close() }
  │     coordinator.open(document, mode: .read, autoplay: false, analyticsContext: ctx)
  │
  ├─ 7. 定位：paragraphIndex = YouTubeReadingDocumentBuilder.startingParagraph(
  │            in: transcript, startSeconds: resumeAnchorMs / 1000)
  │
  └─ 8. 起播：抄 MainTabView.startYouTubePlayback 的音频缓存判断
         cachedAudioPlayback 命中 → readVM.startWithCachedSegments(...)
         未命中 → readVM.jump(to: paragraphIndex)
```

第 6 步的 close 条件与 [MainTabView.swift:699](../CastReader/Views/MainTabView.swift:699) 现有分支完全一致——`ReadingDocument.id` 对同一视频恒为 `"youtube-<videoId>"`，只有 `contentSessionKey` 变，必须显式 close 才能触发 VM 重建。

**建议重构**：把 `startYouTubePlayback` 里第 7–8 步那段（resume 锚点 → 音频缓存命中 → `startWithCachedSegments`/`jump`）抽成 `YouTubePlaybackStarter`，首开与切换共用，避免两处逻辑漂移。

### 跨轨进度对齐

**只用 `startMs`**。不同语言的分段边界完全不同，段号无意义，字符级对齐更无意义。`startingParagraph(in:startSeconds:)` 已经支持按时间定位 + 落到可朗读段。

旧轨的 `progress` 按旧 `cacheKey` 留在缓存里，切回去仍在原处。

### 并发与取消

- 切换期间禁用语言 chip（`state == .switching` 时置灰）
- 遮罩「取消」→ `task.cancel()` + `service.cancel()` → `state = .idle`，原会话继续播（此时**没有** close 过，天然回滚）
- 与首开路径互斥：`activeYouTubeRequestID != nil` 时不允许切换

---

## 4. UI 规格

### 4.1 语言 chip

`YouTubeArtworkHeader`（[YouTubeListenView.swift:272](../CastReader/Views/YouTube/YouTubeListenView.swift:272)）的元信息行：

```swift
HStack(spacing: 5) {
    if let channel = transcript.metadata.channelName, !channel.isEmpty {
        Text(channel); Text("·")
    }
    if switchableTracks.count > 1 {
        Button { onOpenLanguagePanel() } label: {
            HStack(spacing: 3) {
                Text(displayName(of: transcript.track))
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .buttonStyle(.plain)
        .disabled(switcher.state.isSwitching)
        .accessibilityIdentifier("youtubeCaptionLanguageChip")
    } else {
        Text(AppLocalized("字幕稿"))
    }
}
```

### 4.2 语言面板 —— 用 overlay，不要用 sheet

`ReaderHostView` 已经挂了 paywall `.sheet`（[ReaderHostView.swift:519](../CastReader/Views/Reader/ReaderHostView.swift:519)、[:1716](../CastReader/Views/Reader/ReaderHostView.swift:1716)），CLAUDE.md 避坑第 9 条：同屏多 sheet 互吞。

抄 `PlaybackVoicePanelOverlay`（[VoiceBrowserView.swift:563](../CastReader/Views/Settings/VoiceBrowserView.swift:563)）的形状——ZStack + 半透明遮罩 + 底部圆角面板，它就是为「不改变阅读器测量尺寸」而这么写的。新建 `Views/YouTube/YouTubeCaptionLanguagePanel.swift`。

行内容：

```
✓  English                          原文 · 人工
   日本語                            自动生成
   Deutsch                          人工
   ─────────────────────────────
   Tiếng Việt        暂不支持朗读     ← 置灰，不可点
```

- 语言名用 `Locale.current.localizedString(forLanguageCode:)`，失败回落 track 自带 `name`
- 排序沿用 envelope 里 `orderedTracks` 已排好的顺序，不可朗读的沉底
- P1：已缓存的轨加 `checkmark.circle` 小标（查 `mostRecentPreferredKey`）

### 4.3 切换遮罩

复用 `YouTubeExtractionPresentation`，加一个 case：

```swift
case switching(YouTubeListenRequest, targetLanguage: String)
```

文案「正在切换到 <语言> 字幕…」，保留取消按钮。失败不进遮罩的 `.failure`（那个是首开语义，取消会 acknowledge 掉整个 request），改用轻量 toast。

---

## 5. 额度与计费

- 换语言 = 新一轮 TTS 生成。音频 cacheKey 含 `transcriptFingerprint + playbackLanguage`，新轨必然 miss，重新生成
- 免费用户照常消耗每日 20min，**不开任何旁路**（与 `docs/listen-to-youtube-ios-plan.md` §231 一致）
- P1：语言面板底部显示剩余额度（`QuotaManager` 已有），避免用户切完发现听不了

---

## 6. 埋点

新增两个事件，必须同步改 `docs/analytics/mobile-events-v2.json` + `ProductAnalyticsTests` + `scripts/verify_mobile_analytics_contract.rb`：

| 事件 | required | optional |
|---|---|---|
| `yt_caption_language_open` | `trackCount` | `playableTrackCount` |
| `yt_caption_language_switch` | `fromLanguage`, `toLanguage`, `kind`, `cacheHit` | `elapsedMs` |

失败复用 `yt_extract_fail` + `reason: "track_unavailable"`（记得改 §2.4 里那个硬编码白名单）。

**禁用字段红线**：不得带 `title` / `url` / `videoId` / 字幕正文。`language` / `kind` / 计数是安全的。`ProductAnalytics.validate` 遇到禁用字段是**抛错**不是静默剥离。

---

## 7. 本地化

新增文案，`CastReader/Localizable.xcstrings` 九语齐全（en / zh-Hans / ja / es / fr / de / pt-BR / it / hi）：

- 「字幕语言」「自动生成」「人工字幕」「暂不支持朗读」
- 「正在切换到 %@ 字幕…」
- 「这个语言的字幕暂时读不到，已保留当前语言」

改 xcstrings **只能文本插入**，任何整体 `json.dump` 回写都会重排全文件（见 memory `xcstrings-serialization-format`）。批量补齐参考 `scripts/sync_german_localizations.py`。

---

## 8. 测试

| 文件 | 用例 |
|---|---|
| `YouTubeTranscriptTests` | envelope 解析 `availableTracks`：缺失→nil、超 40 条截断、同 lang+kind 去重、含 `baseUrl` 时不落库 |
| `YouTubeWebScriptsTests` | `extractionAdapter` 注入 `REQUESTED_TRACK_*` 字面量、转义正确；`pinRequestedTrack` 无匹配时返回空 |
| `YouTubeCacheStoreTests` | 同视频两语并存；切轨后各自 progress 不污染；audio cacheKey 不串 |
| `YouTubeCaptionLanguageSwitchTests`（新） | 时间锚点跨轨定位；提取失败保留原会话；连点单飞；取消回滚 |
| `ReadingLanguageTests` | 切轨后旧轨的 `correctReadingLanguage` override 不生效 |
| `EvalTests` | 改完先跑（memory `eval-harness-readaloud-explain`） |

新增 Swift 文件记得改 `project.pbxproj` 四处，用 `xcodeproj` Ruby gem 脚本，别手改。

---

## 9. 分期

**P0（可用）—— 已实现（2026-08-12）**：`availableTracks` 上报 → 指定轨提取 → 语言面板 → 换会话 → 时间锚定 → 失败回滚 → 埋点 → 九语文案

**P1（好用）—— 已实现（2026-08-12）**：已缓存标记、离线门禁、额度提示、面板内语言搜索，外加「缓存命中不闪遮罩」

**P2**：翻译轨（见 §11）

### P1 落地要点

| 能力 | 实现 |
|---|---|
| 缓存标记 | `YouTubeCacheStore.captionLanguageAvailability(videoId:voiceCodeByLanguage:)` 一个 actor turn 算出所有语言状态 |
| 离线门禁 | `Utils/NetworkReachability.swift`（NWPathMonitor）+ `YouTubeCaptionLanguagePickerPolicy.isSelectable` |
| 额度提示 | 面板底部条，仅非 Pro 显示：剩余分钟 +「切换语言会重新生成朗读音频」 |
| 语言搜索 | 轨数 > 8 时出现，匹配本地化显示名 / 语言码 / 页面自带名 |
| 遮罩时机 | `Phase.resolving` → 180ms 后才升 `.switching`，缓存命中的秒切不覆盖阅读器 |

三个执行中的判断：

1. **badge 分两级**。完全下载（字幕稿 + 该语言音色的全部音频）才标「已下载」；只有字幕稿的标「可立即切换」。一级标记会在播到未缓存段落时把承诺戳穿。
2. **`captionLanguageAvailability` 刻意不 touch `lastAccessAt`**。仅仅打开面板就刷新一个视频下所有语言的访问时间，会扭曲 LRU 淘汰顺序——`testCaptionLanguageAvailabilityDoesNotDisturbEvictionOrder` 守这条。
3. **`NetworkReachability.isOnline` 默认 `true` 且从不自行锁定 offline**。它只是提示：判错时最坏是让用户等一次超时，而不是把功能锁死。离线拦截只作用于「未缓存」的行——已缓存的语言离线照切。

### P0 落地与本方案的差异

实现时改动了四处，都是执行中发现原设计有洞：

1. **去重按基码而非全码**。`YouTubeCaptionTrackOption.normalized` 用 `baseLanguage + kind` 折叠，`en-US` 与 `en-GB` 合成一行——它们用同一个英语音色，列两行只是让用户在两个看起来一样的选项间挑。
2. **JS 在 pin 失败时直接 post 错误并 return**，而不是「返回空候选集」。空集会让后续的 transcript-panel / endpoint 车道继续跑——那两条路**不绑定候选**，`cuesMatchCandidateLanguage(cues, null)` 恒真，于是会把页面默认语言的字幕当成用户要的语言返回。
3. **native 加了第二道闸**：`YouTubeTranscriptEnvelopeDecoder.document(from:requestedTrack:)` 校验最终 `languageCode` 的基码与请求一致，否则抛 `.trackUnavailable`。必要性在于 unverified source（bridge/endpoint/capture）会用**检测到的**语言覆盖 claimed 语言，德语请求拿回英语正文时不会自然报错——JS 的粗检测也分不出 de/en 这种同字母表的语言对。
4. **起播复用抽的是 `MainTabView.beginYouTubeAudio`**（首开与切换共用尾段），不是独立的 `YouTubePlaybackStarter`；切换遮罩是独立的 `YouTubeCaptionLanguageSwitchOverlay` 而非给 `YouTubeExtractionPresentation` 加 case——两者取消语义不同（切换取消要回到仍在播放的原会话，首开取消要 acknowledge 掉路由请求）。

### 遗留

- **Android 契约未同步**：`ruby scripts/verify_mobile_analytics_contract.rb` 会报 `missing event: yt_caption_language_open / yt_caption_language_switch`。Android 实现同功能时补 `AnalyticsContract.kt`。
- **端到端真实视频未验证**：模拟器上 YouTube 对 WebKit 触发登录/bot 墙（`restricted`），提取本身进不去，切换链路无法在该环境跑通。已验证的是：全量单测 771 通过、适配器 JS 经 `node --check` 语法通过、失败兜底 UI 正常。真机回归时优先验证「多语视频切换 → 音色随语言变 → 从同一时间点续播」。

---

## 10. 风险

| 风险 | 应对 |
|---|---|
| YouTube 改 `captionTracks` 结构 → `availableTracks` 为空 | 面板优雅退化成「只有当前语言」，chip 隐藏。选择器写宽（与 Kindle 同理） |
| 「列表里有但切不过去」（指定轨 + 双重语言校验都严格） | 必须有明确失败文案，不能转圈；`diagnostics` 记 `requested_track_missing` 便于线上定位 |
| 连点语言切换 | switcher 单飞 + `service.cancel()`；`state == .switching` 时 chip 禁用 |
| 长视频重新提取 30s+ | 遮罩可取消，取消即回原会话（尚未 close，天然回滚） |
| 旧缓存 `availableTracks == nil` | 视为「未知」而非「无」。P1 可在缓存命中且列表为 nil 时后台补一次探测 |

---

## 11. 与翻译轨（tlang）的关系

`docs/listen-to-youtube-ios-plan.md` §8 的 P2「翻译朗读」是**另一条路**：用 YouTube 自带机翻轨，让用户用母语听外语视频。

两者不能混实现：

- 本方案切的是**视频作者/YouTube 提供的原生轨**，正文语言校验必须严格
- 翻译轨要求主动加 `tlang` 参数，而 v1 的 JS 现在是**主动删掉 `tlang`**（[YouTubeWebScripts.swift:1998](../CastReader/Services/YouTubeWebScripts.swift:1998)）来防机翻污染

做翻译轨时需要一条独立的、显式标注「机器翻译」的通道，且 cacheKey 要能区分 `lang` 与 `lang+tlang`。**先落地本方案，翻译轨等基线数据再评估。**
