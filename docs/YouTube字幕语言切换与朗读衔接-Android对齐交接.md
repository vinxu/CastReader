# YouTube 字幕语言切换 / 竖屏锁定 / 朗读衔接：iOS 增量与 Android 对齐交接

> **提取架构更新（2026-08-12）：** 本文的多语选轨、竖屏锁定和 TTS 衔接合同继续有效；涉及 `/watch`、desktop WebView、bot challenge、transcript endpoint 与 VPN 的提取实现/排障描述，已由 `docs/YouTube官方Embed字幕提取-Android重构交接.md` 取代。Android 重构应先执行新文档，不得继续以旧 watch 链路为基线。

> 更新日期：2026-08-12
> iOS 工程：`/Users/xuxuheng/Documents/CastReader`
> Android 工程：`/Users/xuxuheng/Documents/CastReader-Android`
> 基线合同：`docs/listen-to-youtube-ios-to-android-handoff.md` + `docs/listen-to-youtube-ios-android-final-alignment.md`
> iOS 设计全文：`docs/YouTube字幕语言切换-iOS实施方案.md`、`docs/YouTube字幕提取-保活与预取方案.md`

本文是**增量合同**，只覆盖三件事，其余行为沿用基线：

1. 字幕的多语言版本（选轨与切换）
2. 字幕稿阅读器的竖屏锁定
3. 朗读的预加载与段落衔接

iOS 侧已实现、已真机验收（真实 iPhone 15 Pro Max、真实公开视频）。Android 的目标同样不是逐行翻译 Swift，而是在 Media3 / Compose 架构上实现相同的**用户能力、失败语义与隐私边界**。文中所有耗时都是 iOS 真机实测值，供 Android 判断自己的实现是否落在合理区间。

---

## 1. 字幕的多语言版本

### 1.1 首次打开：选哪条轨

跟 **App 内语言设置**走 —— 不是视频语言，也不直接是系统语言；只有 in-app 语言设为「跟随系统」时才回落到系统首选语言。

排序规则（iOS 在注入页面的 JS 里实现，Android 同样应在页面侧完成，避免把整份轨列表来回搬运）：

| rank | 条件（人工 / ASR） |
|---|---|
| 0 / 1 | `languageAliasMatches(track, uiLanguage)` —— alias 完全相等 |
| 2 / 3 | `languageMatches(track, uiLanguage)` —— 全码相等**或**基码相等 |
| 4 / 5 | `languageAliasMatches(track, 'en')` |
| 6 / 7 | `languageMatches(track, 'en')` |
| 8 / 9 | 其余，保留原顺序 |

取排序后**第一个真能抓到 cue 的**候选，抓不到就顺位下移。这条 fallback 链只服务于「首次打开、App 在猜」的场景。

两个匹配函数不可混用，它们的差别正是 4/5 与 6/7 要分开的原因：

```js
normalizedLanguage(v) = String(v||'').trim().toLowerCase().replace(/_/g,'-')
baseLanguage(v)       = normalizedLanguage(v).split('-')[0]

languageAlias(v):
  /^zh-(cn|sg|hans)(-|$)/   → 'zh-hans'
  /^zh-(tw|hk|mo|hant)(-|$)/ → 'zh-hant'
  其余                        → normalizedLanguage(v)   // 保留地区，如 'en-us'

languageAliasMatches(t, w) = languageAlias(t.languageCode) === languageAlias(w)
languageMatches(t, w)      = 全码相等 || baseLanguage 相等
```

于是 `en-us` 与 `en-gb`：`languageAliasMatches` **不成立**，`languageMatches` **成立**。

**缺 6/7 档会真的分叉**：设视频有 `fr`(人工) 与 `en-GB`(人工)，UI 语言德语 —— iOS 给 `en-GB` rank 6 并选中；若把英语变体并入 8/9，则 `fr` 与 `en-GB` 同档，按 index 先后可能选中 `fr`。结果集合相同、首选不同。

### 1.2 上报可用轨列表

提取结果（envelope）里新增 `availableTracks`，元素形如：

```json
{ "id": ".de", "name": "Deutsch", "languageCode": "de", "kind": "asr", "vssId": ".de", "index": 1 }
```

三条硬约束：

- **绝不包含 `baseUrl`**。YouTube 的 timedtext URL 是带签名的短命 bearer 凭据，不出页面世界、不落盘。iOS 的 `YouTubeCaptionTrack.baseURL` 里存的是稳定 track id 而非真 URL，并有测试守着（断言不含 `expire=`）。
- **`null` 与 `[]` 语义不同**：`null` = 没读到轨列表（旧缓存 / 页面没给），选择器降级为「只显示当前语言」；`[]` = 页面明确说没有其他轨。
- 上限 40 条，页面给的列表是不可信输入。

**列表要在任何 fetch 之前就填好** —— 一个字幕读不出来的视频，仍然应该告诉用户它有哪些语言，重试时才能直接指定另一条轨。

#### 1.2.1 `id` 与缓存键 `trackIdentity` 是两样东西

**`availableTracks[].id`（双端已同构，可放心）**：

```js
id = String(track.vssId || [languageCode, kind, name, String(index)].join('|'))
// kind 取 'asr' | 'manual'；name 取 runs 展平后的文本
```

这个 id 只在**同一端内**闭环使用：上报时生成、指定轨时按 `identity.id === REQUESTED_TRACK_ID` 匹配。跨端不传递它，但规则一致意味着同一页面在两端算出同一个 id。

**缓存键里的 `trackIdentity` 不是这个 id**，而是四段拼接（分隔符 `U+001F`）：

```
trackIdentity = normalizedLanguage(languageCode) ␟ kind ␟ name ␟ <稳定 track id>
```

第四段（iOS 存在 `YouTubeCaptionTrack.baseURL` 字段里）分两种情况：

| 来源 | 第四段取值 |
|---|---|
| verified（`json3` / `srv3` / `base_url`） | `envelope.captionTrack.id`，即上面那个 id |
| unverified（`transcript_bridge` / `transcript_endpoint` / `transcript_fetch_capture`） | `"<前缀>:<videoId>:<languageCode>"` |

unverified 前缀分别为 `transcript-bridge` / `transcript-endpoint` / `transcript-capture`，且其中的 `languageCode` 是**从 cue 正文检测出来的**语言，不是轨声称的。

> ⚠️ **iOS 线上实际走的一直是 unverified 分支**：每次提取都是 `source=transcript_endpoint`，所以 vssId 从未进入缓存键。Android 要对齐 `trackIdentity` 就必须连这套前缀规则一起对齐。
>
> 不过缓存是各端**本地私有、不共享**的，因此 `trackIdentity` 不一致本身不影响任何现有功能；它要紧的场景是将来做跨端进度同步。**先对齐 `availableTracks[].id`（必须），`trackIdentity` 按上表实现即可（推荐）。**

### 1.3 去重按基码，不按全码

`en-US` 与 `en-GB` 折叠成一条（基码 + kind 去重）。它们用同一个英语音色，列两行只是让用户在两个看起来一样的选项之间挑。

### 1.4 切换契约

用户明确选定语言后，**行为与首次打开完全不同**：

- 提取时指定该轨（id 优先，语言+kind 兜底）
- **找不到就失败，绝不跨语言回退**。用户点了德语，静默给英语比失败更糟
- 失败时**保留当前会话继续播放**，只弹提示，绝不把用户扔在空页
- 缓存优先：该语言已在本地就直接用，不联网

### 1.5 两道语言防串闸门（最容易踩的坑）

iOS 在这里栽过一次，Android 必须原样实现：

**闸门一（页面侧）**：指定轨模式下，若排序后的候选集里找不到目标轨，**立即返回错误并终止**，不要「返回空候选集然后继续」。因为 transcript-panel / transcript-endpoint 这些**页面级车道不绑定候选轨**，候选为空时它们会照常返回页面默认语言的字幕，于是用户点德语拿到英语。

**闸门二（native 侧）**：拿到 cue 之后，再校验最终识别出的语言基码与请求语言一致，不一致抛 `track_unavailable`。这道必不可少 —— unverified 来源（bridge/endpoint/capture）会用**检测到的**语言覆盖 claimed 语言，而页面侧的粗检测分不出 de/en 这种同字母表语言对。

### 1.6 身份、缓存与恢复

- 缓存键 = `videoId + trackLanguage + trackIdentity + cue 指纹`，**同一视频的多语字幕天然并存**
- 音频缓存键含 `transcriptFingerprint + voiceCode + playbackLanguage`，换轨必然 miss、重新生成，不会串
- **换轨即换会话**：iOS 用 `contentSessionKey` 表达；重建播放会话后，音色与 TTS 语言自动取「该语言的用户偏好音色」，不需要额外代码
- **跨轨恢复只能用时间戳**。不同语言的分段边界完全不同，段号毫无意义
- 「纠正朗读语言」的用户覆盖必须按**轨**存，不能按视频存，否则切到新语言会被上一条轨的旧纠正污染

### 1.7 UI 规格

入口是阅读器头部元信息行的语言 chip（「频道 · English ⌄」）。**可选轨 ≤1 时不显示 chip**，退回纯文本标签。

面板（iOS 用 overlay 而非 sheet，因为阅读器已有付费墙 sheet；Android 用 BottomSheet 即可，注意与既有 sheet 的互斥）：

- 可朗读的语言保持页面排序，不可朗读的沉底但**仍然列出** —— 「这个视频有越南语字幕」本身就是用户要的信息，只是置灰不可选
- 自动生成轨标「自动生成」
- **两级下载标记**：完全下载（字幕稿 + 该语言音色的全部音频）标「已下载」；只有字幕稿的标「可立即切换」。一级标记会在播到未缓存段落时把承诺戳穿
- 轨数 > 8 出现搜索框，匹配本地化显示名 / 语言码 / 页面自带名
- 非 Pro 在底部显示今日剩余朗读额度 +「切换语言会重新生成朗读音频」。换语言 = 全量重新生成 TTS，这是真实成本，说在前面
- 离线且该语言未缓存 → 置灰并注明「需要联网才能获取」。已缓存的语言离线照切
- 网络状态判断必须 **fail-open**（默认在线、不自行锁定离线），判错的代价只应是白等一次超时，而不是锁死功能

切换遮罩要**延迟约 180ms 再显示**：缓存命中的切换在几十毫秒内完成，立刻升起全屏遮罩会闪一下。

### 1.8 埋点

新增两个事件，iOS / Android / 后端三端契约已同步登记（`scripts/verify_mobile_analytics_contract.rb` 现在应当通过）：

| 事件 | required | optional |
|---|---|---|
| `yt_caption_language_open` | `trackCount` | `playableTrackCount` |
| `yt_caption_language_switch` | `fromLanguage`, `toLanguage`, `kind` | `cacheHit`, `elapsedMs` |

另外 `yt_extract_fail` 的 reason 白名单新增 `track_unavailable`，`yt_extract_done` 新增可选字段 `warmSession`。

`youtubeEntry` / `youtubeFailure` / `youtubeCaptionKind` 三个值域已写进 canonical `docs/analytics/mobile-events-v2.json`，两端枚举与后端 `mobile-event-contract.ts` 都从这份值域对齐。Android 侧 `AnalyticsContract.kt` 的事件、属性与边界校验，以及 `ProductAnalytics.kt` 的 `youtubeCaptionLanguageOpen` / `youtubeCaptionLanguageSwitch` 封装都已就位，尚缺的只是 UI 层的调用点（面板打开时、切换完成时）。

**隐私红线不变**：不得带 `title` / `url` / `videoId` / 字幕正文。`language` / `kind` / 计数是安全的。

---

## 2. 竖屏锁定

字幕稿阅读器是「16:9 封面 + 时间戳列表」的单栏结构，横屏时封面吃掉大半视口，版式垮掉。**标记为竖屏专用**。

两个要点：

- 全屏阅读器**和收起后的 Mini Player 都要锁**。收起时不能放开 —— 阅读器在 iOS 上是移出屏幕而非销毁，放开锁会让离屏旋转在用户看不见的地方把布局重排。Android 若采用类似的常驻结构，同理
- iOS 上微信读书也锁竖屏，但**理由不同**（怕 WebView 播放中 reflow 打断 TTS）。两者不要合并成一条注释，将来改动时容易误判

---

## 3. 朗读的预加载与段落衔接

### 3.1 先看 iOS 实测，别照搬直觉

iOS 原本就有「始终领先一段」的预取。真机实测（人工英文字幕、9–12 秒/段）：

```
advance from=0            prefetched=1
prefetch promote para=1   ← 同一毫秒，0 延迟
prefetch start  para=2  chars=163
prefetch done   para=2  ← 生成只花 532ms
advance from=1            ← 12.9 秒后才播完这段
```

**预取生成 0.5–0.7 秒，段落时长 9–12 秒，缓冲绰绰有余。** 段落衔接的停顿感**不来自「没有预加载」**。Android 若也出现衔接停顿，先测这三个量再动手：段落时长、预取耗时、promote 到出声的间隔。

### 3.2 gap 的真实构成

iOS 的间隙全在播放器准备阶段：

```
promote para=2
  +1ms    写临时文件
  +50ms   AVURLAsset 解析、AVPlayerItem 到 readyToPlay
  +65ms   出声
```

即边界 gap **65–83ms**。iOS 尝试把磁盘写和 asset 预热挪到预取阶段，实测只降到 **61–64ms（省约 10ms）**——因为瓶颈是 item 准备那 50ms，而预热的 asset 实例没被播放路径复用。这个优化在 iOS 上**收益有限，已如实记录**。

**Android 在这件事上有结构性优势**：Media3 / ExoPlayer 的 `MediaSource` 播放列表天然会 preroll 下一项，把段落作为 playlist item 依次加入、而不是每段替换播放器，边界基本无缝。**建议 Android 直接走 playlist 路线，不要复制 iOS 的「替换当前 item」结构**，否则会继承这个 60ms 的间隙。

（iOS 若要根治，路径是保存预热好的 asset/item 给播放路径复用，或改用 `AVQueuePlayer`；两者都未做。）

### 3.3 已由 YouTube 字幕语义与 TTS 断句规范取代

本节旧的「>2000ms 或 >150 字符」方案与「尚未解决」结论已过期。iOS P0 已实现专用语义预处理，Android 也已完成对齐实施；现在一律以 `docs/YouTube字幕语义预处理与TTS断句-跨端实现规范.md` 为准。新合同同时覆盖 raw/speech/speaker 数据模型、环境音与角色标签剥离、rolling 去重、基于时间与标点的 utterance 断句，以及 audio/progress cache schema 迁移。

---

## 4. 三条血泪经验

**① 提取被 bot 墙拦时，先换 VPN 出口节点，不要从代码查起。**
`LOGIN_REQUIRED` / `restricted_video` / `document exposes an explicit bot-verification challenge` 连续出现、换视频没用、换节点立刻好 —— YouTube 按 IP 段做信誉评分，VPS / 数据中心 IP 天生低分。iOS 这次误判成本很高：先怀疑是自己新加的保活 WebView，据此关掉了功能，实际同样的挑战在保活存在之前就出现过。**相关性不等于因果**，尤其当同时变了网络和版本时。

**② PO token 目前一次都抓不到，字幕全靠 transcript endpoint 兜底。**
每次提取都是 `subtitle proof required=true captured=false`，成功路径是 `transcript_endpoint` 而非 `timedtext`。这意味着**单点依赖**：YouTube 收紧那个端点，功能会整体失效，而正规的 timedtext 路径早就不通了。任何「复用 proof + timedtext」的优化都会直接失败 —— iOS 的保活方案就是栽在这里。

**③ 保活提取 WebView 的方案已实现但默认关闭。**
思路是提取成功后不销毁页面，后续语言切换复用它的 proof 与轨列表，跳过整个页面 bootstrap（实测 native 开销仅 11ms，5.7 秒全在页面侧）。但因为 ②，follow-up 走 timedtext 必然失败。改造要把 follow-up 接到 transcript endpoint，实测收益约 1–1.5 秒（完整提取约 4 秒，其中 2 秒是 transcript 请求本身、换语言照样要付）。**Android 不建议先做这个**，性价比低于上面任何一项。

---

## 5. 验收标准

功能：

- [ ] 多语视频显示语言 chip；单语视频不显示
- [ ] 切换后**音色随语言变**（用该语言的用户偏好音色），且从**同一时间点**续播
- [ ] 切回已听过的语言：秒切、不联网、行尾有下载/可切换标记
- [ ] 切换失败：保留原会话继续播放 + 明确提示，不空页
- [ ] 指定德语时**绝不返回英语字幕**（构造一个只有英文 transcript 面板的视频验证闸门二）
- [ ] 不可朗读语言置灰但仍列出
- [ ] 离线：已缓存语言可切，未缓存置灰并说明
- [ ] 字幕稿阅读器横屏不旋转，收起 Mini Player 后仍不旋转

性能（附实测值，Android 应不劣于）：

- [ ] 预取生成 < 1s（iOS 0.5–0.7s）
- [ ] 段落边界间隙：iOS 61–64ms，**Android 走 playlist 应显著更低**
- [ ] 缓存命中的语言切换不显示全屏遮罩

隐私与合规：

- [ ] 轨列表、缓存、日志中均无签名 URL / PO token
- [ ] 埋点无 title / url / videoId / 字幕正文
- [ ] 官方 Embed 仅在系统硬静音下短暂初始化并有界暂停；不持久化 YouTube
  音视频流，CastReader 只用字幕文本生成朗读音频
