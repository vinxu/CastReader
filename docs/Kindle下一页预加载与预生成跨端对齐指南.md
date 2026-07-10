# Kindle 下一页预加载与预生成跨端对齐指南

本文用于指导 iOS 对齐 Android 和 Chrome 扩展的 Kindle 连续朗读/解读预加载能力。重点不是“猜下一页然后驱动播放”，而是把 Kindle 原生翻页、blob/OCR 预热、TTS/QuickRead 预生成三件事拆开，确保主链路稳定，预加载只负责加速。

参考实现：

- Android: `/Users/xuxuheng/Documents/CastReader-Android/app/src/main/java/com/same/castreader/ui/screens/kindle/KindleViewModel.kt`
- Android JS bridge: `/Users/xuxuheng/Documents/CastReader-Android/app/src/main/java/com/same/castreader/kindle/KindleWebScripts.kt`
- Chrome 扩展 Kindle OCR cache: `/Users/xuxuheng/Documents/MyProject/readout-desktop/src/extractors/kindle-ocr-cache.ts`
- Chrome 扩展 Kindle extractor: `/Users/xuxuheng/Documents/MyProject/readout-desktop/src/extractors/kindle.ts`
- Chrome 扩展 QuickRead: `/Users/xuxuheng/Documents/MyProject/readout-desktop/src/ui/quickread-client.ts`
- iOS Kindle bridge: `/Users/xuxuheng/Documents/CastReader/CastReader/Services/KindleWebScripts.swift`

## 一句话原则

翻页永远以 Kindle 当前真实可见页为准。预测的下一张 blob 只能用于 OCR/TTS/QuickRead 预热，不能成为“是否允许翻页、是否切换页面、是否播放”的前置条件。

正确链路：

1. 当前页正常朗读或解读。
2. 当前页内容准备完成后，后台找可能的下一页 blob，做 OCR 和预生成。
3. 当前页播放结束时，先驱动 Kindle 原生翻页。
4. 等 Kindle 渲染出新的真实可见页。
5. 以新可见页的 key + 文本 fingerprint 校验缓存。
6. 命中则秒播，未命中则现场 OCR/生成。
7. 进入新页后继续预热再下一页。

错误链路：

1. 先找下一页 blob。
2. 找不到就不翻页或报错。
3. 找到了就直接认为它是下一页。
4. 用户手动翻页后仍使用旧预测任务。

这种链路会导致错页、回头播、找不到页面图片、两页后停止、快速翻页时任务堆积。

## Kindle 页面里的几个身份

必须区分这些概念：

- `visiblePage`: WebView 当前真实可见的 Kindle 页面。
- `visiblePageKey`: 当前可见 blob 的稳定内容 key。
- `predictedBlob`: 从 held blob 列表里推测的下一页候选。
- `preparedPage`: 已对某个 blob 做过截图/OCR/段落重建的缓存。
- `prefetchedRead`: 已为候选页生成好的朗读起始 TTS。
- `prefetchedExplain`: 已为候选页生成好的 QuickRead block0 和 TTS。
- `epoch/generation`: 当前播放或预加载轮次。任何异步结果回来时都必须校验 generation。

`predictedBlob` 不等于 `visiblePage`。只有 Kindle 真正翻页后，重新 capture 出来的页面才是主链路事实。

## Chrome 扩展如何拿到预测 blob

扩展分 MAIN world 和 ISOLATED world：

1. MAIN world hook `URL.createObjectURL`。
2. 当 Kindle 创建 image blob URL 时，计算稳定内容 key。
3. key 算法是 `sha256(blob.size + first 256 bytes)`，只取前 8 byte hex。
4. MAIN world 用原始 `createObjectURL` 再造一个 live URL，避免 Kindle revoke 原 URL 后图片失效。
5. 保存：
   - `originalUrl -> contentKey`
   - `contentKey -> liveUrl`
   - `heldPageKeys` 创建顺序列表
6. 重复 key 出现时先 delete 再 set，刷新 Map 插入顺序。
7. LRU 只保留最近一批 Kindle 页面，扩展 OCR cache 里 OCR 结果最多 50 条。

扩展文件里的关键点：

- `kindle-intercept.content.ts`
  - 持有 `keyToLiveUrl`
  - 写入 DOM attribute: `data-castreader-kindle-blob-live-urls`
  - 写入 DOM attribute: `data-castreader-kindle-blob-keys`
- `kindle-ocr-cache.ts`
  - `getKeyToLiveUrlPairs()` 按创建顺序返回 `[contentKey, liveUrl]`
  - `getInflightOcr()` / `setInflightOcr()` 防止主路径和预取重复 OCR 同一页
- `kindle.ts`
  - `triggerPrefetchNextPages()` 触发后台 OCR
  - `peekNextPageOcrText()` 给解读预取拿下一页 OCR 文本

### 扩展的候选选择逻辑

扩展不是从 DOM 里找“下一页”。Kindle 的下一页 blob 很可能还没有挂到 DOM。扩展从 MAIN world 持有的 `keyToLiveUrlPairs()` 里拿候选。

重要细节：

- `keyToLiveUrlPairs()` 的顺序是 blob 创建顺序。
- 最新创建的 blob 在末尾。
- 普通 OCR 预热会反向迭代最近 N 张，因为 Kindle 常常预渲染当前位置附近的页面。
- 解读的“下一页文本”不是直接拿最近 blob，而是：
  1. 用当前页 OCR 文本定位当前页在 ordered list 中的位置。
  2. `currentIndex + 1` 才是下一页。
  3. 如果 N+1 没 OCR，只补 OCR 这一张。

这点很关键：用于解读预取时，必须用“当前页文本匹配 ordered list”定位，再取后继。否则容易把上一页、旁边页、预渲染但不是下一页的 blob 拿来预生成。

## 扩展的 OCR 队列模型

Tesseract WASM 是单线程。扩展用优先级队列避免预取堵住主路径：

- 当前可见页 OCR: `high`
- 预取 OCR: `low`
- 新 high 任务插到所有 low 前面。
- 当前正在跑的 OCR 不能取消，但队列里还没开始的 low 可以取消。
- 新一轮预取开始前调用 `clearStaleLowQueue()`，丢弃旧 low 任务。
- low 任务真正被 worker 取出时再跑 `isStale()`，如果已经缓存或过期就 reject。

iOS/Android 不一定需要同名队列，但必须有等价能力：

- 主路径永远优先。
- 旧预取不会累积。
- 快速翻页只保留最终可见页对应任务。
- stale 结果不能写入当前 UI。

## Android 当前实现结构

Android 当前收敛后的结构可以作为 iOS 的对齐参考：

- `scheduleNextPagePrefetch(webView, afterKey, reason, force)`
  - 触发下一页预热。
  - 会 bump `nextPagePreloadGeneration`。
  - 新任务开始前取消旧 `nextPagePrefetchJob`。
  - 根据当前模式判断 read 或 explain。

- `prefetchKeyPlan(webView, currentKey)`
  - 从 JS bridge 获取当前 key、observed keys、held keys、all keys。
  - 产出 `orderedKeys` 和 `candidateKeys`。

- `prefetchCandidatesForMode(currentKey, plan, explainMode)`
  - 朗读可以使用普通候选。
  - 解读必须优先使用 `orderedKeys.drop(currentIndex + 1)`。
  - 不再使用 “current + nearby” 的候选顺序作为解读预生成顺序。

- `prefetchPreparedPageForKey(...)`
  - 对候选 pageKey 抓快照/OCR。
  - 复用 `inflightPreparedPage`，避免同一个 pageKey 重复 OCR。
  - 每一步都检查 generation。

- `ensureReadStartSegmentsPrepared(...)`
  - 为朗读候选页提前生成起始 TTS。

- `scheduleExplainFirstBlockPrefetch(...)`
  - 为解读候选页提前跑 QuickRead `extractPlan`，准备 block0 的 TTS。
  - 当前配置会最多准备 3 个候选，避免 Kindle 预渲染顺序有小偏差。

- `consumePrefetchedExplainFirstBlock(page)`
  - 真实翻页后，只按当前 `currentPageKey` 取缓存。
  - 还要校验 `textFingerprint`。
  - key 或 fingerprint 不一致就丢弃，回到现场生成。

## Android 已踩过的坑

### 1. 预测 blob 反客为主

错误表现：

- 点下一页时先找 `next blob`。
- 找不到就报 `no-next-page`。
- 用户只是翻页，却出现“准备 Kindle 页面失败”。

正确修正：

- 手动下一页或自动下一页都先调用 Kindle 原生翻页。
- 翻页后 wait visible page changed。
- 再 capture 当前真实可见页。
- 预测 blob 只用于缓存命中，不影响翻页动作。

### 2. 候选顺序错导致预取命中率低

错误表现：

- 预取日志里 selected 是前一页或旁边页。
- 真正翻过去的 key 不在 selected 里。
- 解读两三页后开始现场生成，卡顿明显。

根因：

- 候选列表混入 `nearby/current/observed visible`，并且顺序放在 `orderedKeys` 前面。
- Kindle 预渲染的 nearby 不一定是阅读顺序上的下一页。

正确修正：

- 解读预生成的选择应以 `orderedKeys` 为主。
- 先找到 currentKey 在 orderedKeys 里的 index。
- 从 index + 1 开始顺序取候选。
- candidateKeys 只能作为兜底，不能覆盖 ordered 后继顺序。

### 3. 先 OCR 很多候选，再选择

错误表现：

- 页面快结束了，预生成还在 OCR 多个候选。
- QuickRead block0 没来得及生成。
- 翻页后仍然卡。

正确修正：

- 解读模式不要先扫 8 到 12 个候选再决定。
- 应按 ordered 后继顺序准备，达到目标数量就停。
- 当前建议目标：下一页至少 1 个，允许额外准备 2 个作为容错。

### 4. 只预取第一页，没有滚动预取

错误表现：

- A 播放时预取了 B。
- 进入 B 后没有继续预取 C。
- B 到 C 又卡。

正确修正：

- 每次进入新页，不管是命中预取还是现场生成，都要立即启动下一轮：
  - A 播放时预取 B。
  - 进入 B 后预取 C。
  - 进入 C 后预取 D。

### 5. 旧任务污染当前页

错误表现：

- 用户快速翻页 A -> B -> C。
- B 的 OCR/QuickRead 结果晚回来，覆盖了 C 的 UI 或 cache。
- 解读 mark 画在错误页面。

正确修正：

- 每次手动翻页、目录跳转、自动翻页都 bump page/preload/explain generation。
- OCR、QuickRead、TTS prepare 任何 async 回来时必须检查：
  - generation 是否还一致。
  - pageKey 是否等于目标。
  - textFingerprint 是否等于当前 capture。
  - mode 是否仍是 read/explain 当前模式。

### 6. key 命中但文本不一致

错误表现：

- Kindle re-render 后 key 或页面几何状态变化。
- overlay/highlight/mark 对不上。

正确修正：

- 缓存消费不能只看 key。
- 解读至少校验 `textFingerprint = length + hash`。
- 如果布局、方向、字体、页模式变化，必须清旧 overlay 并重新 capture。

## 朗读预生成链路

目标：当前页播放时，下一页的 OCR 和起始 TTS 尽量已经准备好。翻页后如果命中缓存，直接继续朗读。

建议 iOS 链路：

1. 当前页 `captureVisiblePage`。
2. OCR 得到 paragraphs、word bboxes、page image size。
3. 开始朗读当前页。
4. 当前页 OCR/TTS 起播后，调用 `scheduleReadNextPagePrefetch(currentPageKey)`。
5. 预取任务：
   - 从 `keyToLiveUrlPairs` 或等价 held blob 列表拿 ordered candidates。
   - 定位 currentKey 后面的候选。
   - 对候选 pageKey 做 snapshot/OCR。
   - 生成第一段或前几段 TTS。
   - 写入 `readPrefetchCache[pageKey]`。
6. 当前页播放完成：
   - 先驱动 Kindle 原生下一页。
   - 等 `visiblePageKey != oldKey`。
   - capture 新 visible page。
   - 如果 `readPrefetchCache[newKey]` 命中且 fingerprint 一致，直接用预生成 TTS。
   - 否则现场生成。
7. 如果播放状态是 playing，则自动继续播；如果用户是在停止状态手动翻页，只准备页面，不自动开始朗读。

### 朗读缓存建议字段

```swift
struct KindleReadPrefetch {
    let pageKey: String
    let textFingerprint: String
    let page: OcrPage
    let startSegments: [PreparedTTSSegment]
    let createdAt: Date
}
```

### 朗读取消规则

- 用户手动快速翻页：取消旧预取任务。
- 用户从朗读切到解读：取消朗读预取。
- 用户停止播放：可以保留短期 OCR cache，但取消 TTS 预生成。
- 预取任务完成时发现 generation 旧了，只能丢弃。

## 解读预生成链路

目标：当前页解读时，下一页的 QuickRead `block0 + TTS` 已经准备好。翻页后命中时可以直接播放 block0，同时继续拉 block1..N。

建议 iOS 链路：

1. 当前页 OCR 完成，构建 QuickRead request。
2. 当前页 `extractPlan`。
3. block0 一到就开始播放。
4. 当前页 plan ready 或 block0 ready 后，启动 `scheduleExplainNextPagePrefetch(currentPageKey)`。
5. 预取任务：
   - 取 ordered 后继候选。
   - OCR 候选页。
   - 为候选页构造 QuickRead request。
   - 带上 `prevSummary`，避免下一页像重新开场。
   - 调用 `extractPlan`。
   - 只准备 block0 的 TTS，拿到后缓存。
6. 当前页解读播放结束：
   - 先驱动 Kindle 原生下一页。
   - 等新 visible page 稳定。
   - capture/OCR 新 visible page。
   - 用 `pageKey + textFingerprint` 查 `explainPrefetchCache`。
   - 命中则直接播放 prefetched block0。
   - 同一 job 继续请求 block1..N。
   - 未命中则现场 `extractPlan`。
7. 进入新页后马上再调下一轮预取。

### 解读缓存建议字段

```swift
struct KindleExplainPrefetch {
    let afterKey: String
    let pageKey: String
    let textFingerprint: String
    let jobId: String
    let totalBlocks: Int
    let block0: QrSection
    let preparedBlock0: PreparedBlock
    let baseURL: String
    let apiKey: String
    let deviceId: String
    let outputLanguage: String
    let voice: String
    let pageSummary: String?
    let createdAt: Date
}
```

### 解读预取的 prev_summary

Kindle 是分页连续解读，不应该每页都像独立文章重新开场。下一页预取时应带：

- 上一页 QuickRead 返回的 `page_summary`。
- 如果没有 page_summary，就用最近已播解说文本 + 当前页尾部 OCR 文本拼一个短 summary。
- 长度控制在 1200 到 1600 字符。

### block0-only 的风险

只预生成 block0 可以明显改善“翻页后的第一声延迟”，但如果 block0 很短，block1 仍可能卡。更平滑的方案：

- MVP: 预生成 block0。
- 稳定后: 如果 totalBlocks > 1，后台继续预取 block1 的 `extractBlock + TTS`，但优先级低于当前页主播放。
- 不能因为 block1 预取失败影响主链路。

## 快速手动翻页的规则

无论用户怎么翻页，都以最终稳定可见页为准。

建议状态机：

```text
Playing current page
  -> user turns page
  -> cancel current page audio
  -> bump pageGeneration
  -> cancel low priority preloads
  -> wait debounce 250-400ms for page stable
  -> capture final visible page
  -> if previous state was playing: continue read/explain
  -> if previous state was idle: only prepare page, do not auto start
```

注意：

- 用户快速连点下一页时，不要每一次都完整 OCR/QuickRead。
- 只保留最后一次稳定页。
- 旧页的 inflight OCR 可以自然结束，但结果不能安装到当前 UI。
- 旧页的 QuickRead/TTS 任务必须取消或丢弃结果。

## 自动翻页的规则

自动翻页发生在当前页播放完成后：

1. 当前页最后一个朗读 segment 或解读 block 播完。
2. 调用 Kindle 原生翻页。
3. 不要先要求“已经找到下一页 blob”。
4. 等真实 visible page changed。
5. capture 新页。
6. 命中预取则消费预取。
7. 未命中则现场生成。
8. 继续播放。

自动翻页失败只应发生在：

- Kindle 真的已经到书末。
- Kindle 原生翻页控件不可用。
- 翻页后长时间没有可见 blob。

不能因为 `predicted next blob` 缺失而判失败。

## 预测 blob 如何验证

预取命中必须经过两层验证：

1. `pageKey` 一致。
2. `textFingerprint` 一致。

推荐 fingerprint：

```swift
func kindleTextFingerprint(_ page: OcrPage) -> String {
    let text = page.blocks.map(\.text).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return "\(text.count):\(text.hashValue)"
}
```

跨平台更稳定可以用 SHA-1/MD5，而不是 Swift `hashValue`，因为 Swift hash 每进程可能不同。如果只做内存内校验，`hashValue` 可用；如果要落盘，必须用稳定 hash。

另外建议加一个宽松 `textSimilar`：

- 去空白、标点、符号。
- 小写。
- 比较前 120 到 160 个有效字符。
- 相同、互为前缀、或匹配率大于 0.8 即可认为同页。

用途：

- key 不可靠或 re-render 时，辅助判断缓存是否仍可用。
- 但一旦 textSimilar 失败，必须退回现场生成，不能继续讲错页。

## 日志验收标准

iOS 实现时建议补同类日志，方便和 Android 对齐。

朗读正常链路应看到：

```text
kindleRead current page ready key=A
kindleReadPrefetch start after=A candidates=B,C
kindleReadPrefetch ready key=B ocr=hit tts=ready
kindleAutoAdvance start from=A
kindleAutoAdvance visible key=B
kindleReadPrefetch consume key=B
kindleRead start key=B prefetched=true
kindleReadPrefetch start after=B candidates=C,D
```

解读正常链路应看到：

```text
kindleExplain pipeline-start key=A
kindleExplain plan key=A total=...
kindleExplainPrefetch start-batch from=A to=B,C
kindleExplainPrefetch ready from=A to=B total=...
kindleAutoAdvanceExplain visible key=B
kindleExplain prefetch-cache-hit key=B
kindleExplainPrefetch consume key=B
kindleExplainPrefetch start-batch from=B to=C,D
```

快速手动翻页应看到：

```text
manualTurn start old=A direction=next wasPlaying=true
preload cancel generation=...
manualTurn queued/superseded
visible stable key=D
old result dropped generation mismatch
resume current visible key=D mode=read/explain
```

异常日志不要只有“找不到图片”，要能看出是哪一层失败：

- `native-turn-unavailable`
- `visible-page-not-changed`
- `no-visible-blob-after-turn`
- `prefetch-miss`
- `prefetch-stale-generation`
- `prefetch-text-mismatch`
- `ocr-empty`
- `quickread-plan-timeout`

## iOS 需要实现/复核的 checklist

1. Kindle WebView bridge 持有 blob live URL。
   - hook `createObjectURL` 或等价方式。
   - 有 `contentKey -> liveUrl`。
   - 重复 key 刷新顺序。
   - 保留最近约 24 张即可。

2. 能暴露 ordered blob pairs 给 Swift。
   - 顺序必须是创建顺序。
   - 预取选择要能从当前页定位到后继页。

3. OCR 有 cache 和 inflight 合并。
   - 同 pageKey 不重复 OCR。
   - 主路径优先于预取。
   - 新一轮预取取消旧 low priority 任务。

4. 翻页动作不依赖预测 blob。
   - 下一页/上一页先触发 Kindle 原生翻页。
   - 翻页后等真实 visible page。
   - 真实 visible page 才进入主播放/解读。

5. 朗读预生成。
   - 当前页播放时准备下一页 OCR。
   - 准备下一页起始 TTS。
   - 翻页后命中则直接播。
   - 未命中现场生成。

6. 解读预生成。
   - 当前页 block0 或 plan ready 后开始预取下一页。
   - 下一页预取至少做到 `extractPlan + block0 TTS`。
   - 带 `prevSummary`。
   - 命中时消费同 job 的 block0，后续 block 用同 jobId 续拉。
   - 进入新页后继续滚动预取再下一页。

7. 快速手动翻页。
   - debounce 到最终 visible page。
   - 取消旧预取和旧播放。
   - 如果翻页前是播放态，最终页继续播放。
   - 如果翻页前是停止态，最终页只准备，不自动播放。

8. UI 不被预加载污染。
   - 预取不显示重 loading。
   - 正常翻页只显示轻量底部 loading。
   - 预取失败不 toast，不挡主链路。
   - 只有主路径失败才提示用户。

9. 横竖屏/字体/版式变化。
   - 这些会改变 blob rect 和 OCR 坐标。
   - 必须清 overlay/mark/word route。
   - 重新 capture 当前 visible page。
   - 旧预取只可按 text fingerprint 复用，不可复用旧几何。

## 和普通 Web 解读的不同

普通 Web 解读顺滑，是因为：

- DOM 文本稳定。
- 不需要 OCR。
- 不需要 blob key。
- 不需要 Kindle 原生翻页。
- 分批可以在同一个文档上下文里继续请求。

Kindle 卡顿的核心多了四层：

- page blob 捕获。
- OCR。
- visible page 与 predicted blob 的一致性校验。
- 每页可能是新的 QuickRead job。

所以 Kindle 必须有 page-level 预生成，否则只靠 QuickRead block 流式生成不够。

## 推荐最终架构

```text
Kindle WebView Bridge
  - visible page snapshot
  - native page turn
  - keyToLiveUrl ordered pairs
  - page mode / geometry

Page Cache
  - pageKey -> OcrPage
  - pageKey -> inflight OCR
  - LRU

Preload Coordinator
  - generation
  - read preload task
  - explain preload task
  - low priority cancellation
  - candidate selection

Playback Coordinator
  - read/explain mode
  - playing/idle state before manual turn
  - auto advance after page finished
  - consume matching prefetch

Render Layer
  - word highlight
  - explain marks
  - subtitle
  - clear stale overlay on page/mode/layout change
```

这套架构里，只有 `Playback Coordinator` 可以决定当前播放哪一页。`Preload Coordinator` 只能提供“如果你真的进入这个 pageKey，我这里有缓存”的加速结果。

## 最小可交付顺序

1. 先保证原生翻页稳定，不依赖 predicted blob。
2. 再做朗读下一页 OCR 预热。
3. 再做朗读起始 TTS 预生成。
4. 再做解读下一页 OCR 预热。
5. 再做解读 block0 预生成。
6. 最后做 block1 低优先级预生成和更激进的多候选容错。

不要反过来先做大范围预测，否则很容易把预加载变成主链路阻塞源。

