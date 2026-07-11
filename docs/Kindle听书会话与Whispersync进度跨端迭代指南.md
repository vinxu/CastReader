# Kindle 听书会话与 Whispersync 进度跨端迭代指南

## 1. 背景

CastReader 的 Kindle 听书同时涉及三种状态：

1. Kindle 当前显示的真实书页。
2. Amazon Whispersync 保存的本地/云端阅读位置。
3. CastReader 在当前书页内保存的句子级播放游标。

它们用途不同，不能互相覆盖。实测曾出现：Kindle 当前显示 `location 1097`，Amazon 弹窗提示云端最近位置为 `1088`；同时，CastReader 的冷启动“继续听”需要等待约 9-11 秒并可能因 pageKey 不匹配而回退。活跃会话内的重新挂接则可在约 59ms 内完成。

因此本轮不再追求 CastReader 冷启动时主动跳回历史句子，而是明确所有权：

- Kindle 决定打开哪一页、是否采用云端位置。
- 用户决定 Whispersync 弹窗选“是”还是“否”。
- CastReader 只在当前活跃会话中精确恢复句子和播放状态。
- 持久化句子锚点保留为安全提示和后续能力，不得在 pageKey 不一致时驱动 Kindle 翻页。

## 2. 产品目标

### 2.1 首页和书架

- 活跃播放会话存在时，只显示全局 MiniPlayer。
- Kindle 书架不再额外显示独立的“继续听”卡片或耳机按钮，避免同一本书重复出现。
- 点击普通书封只打开 Kindle 阅读页，不自动播放。
- 点击 MiniPlayer 是重新挂接现有会话，语义是 `ensurePlaying`，不是 `toggle`：
  - 已播放：保持播放。
  - 正在 loading：保持 loading，不重复启动。
  - 已暂停但会话仍在：进入书页并恢复播放。
- 用户关闭 MiniPlayer 即明确结束当前会话。下次普通打开按 Kindle 当前页开始，不承诺冷启动精确续播。

### 2.2 Kindle 同步弹窗

当 Kindle 显示 “Most Recent Page Read” 或同义本地化弹窗时：

- CastReader 不自动点击“是”或“否”。
- 用户选择前，停止旧页朗读/解读及其 TTS、QuickRead、OCR 预取任务。
- 暂时禁用底部翻页、播放、TOC 和顶部模式切换，显示轻量提示。
- 用户选择后，以弹窗消失或页面导航开始为信号，等待最终真实 visible page 稳定。
- 弹窗出现前正在播放：在最终页按原模式重新开始。
- 弹窗出现前处于停止/暂停：只更新当前页，不自动播放。

### 2.3 自动翻页

- 自动和手动按钮翻页共用同一条“驱动 Kindle -> 验证真实页 -> 继续播放”链路。
- 每次翻页只发送一个 Kindle transport 动作，然后以 100-200ms 轮询真实 visible page；同一个方向不得同时向 body/document/window 重复发送会冒泡的键盘事件。
- transport 的真机顺序统一为：main world scrubber -> 已挂载且未禁用的 Kindle chevron（即使视觉隐藏）-> 单次阅读区边缘点击 -> synthetic keyboard 最后 fallback。前后台恢复后 scrubber 可能被 Kindle 暂时回收，因此不能从 `no-scrubber` 直接跳到 keyboard。
- 每种 transport 只派发一次：scrubber 只发一组 `ionInput + ionChange`，chevron 只 click 一次，边缘点击只发一组 pointer down/up + click。两端都不能根据 DOM 返回值直接宣布翻页成功。
- 约 900ms 内未观察到真实 visible page 变化时，才允许发送另一种 transport fallback。
- fallback 后仍需校验真实 pageKey，不能以点击成功或 DOM 返回值代替翻页成功。
- 最终仍失败时，安全停止当前翻页恢复，不播放预测页内容。

预加载不预测唯一下一页：扩展会对最近 held blobs 做低优先级 OCR。翻页完成后，主链路用实际可见图片的 content-key 查 OCR cache；命中直接使用，inflight 则 await 同一任务，未命中才现场 OCR。TTS/QuickRead 继续校验实际 pageKey + textFingerprint。

## 3. 状态真相优先级

从高到低：

1. **Kindle 当前可见页**：唯一正文主链路，OCR、朗读、解读、高亮都从它产生。
2. **Amazon 本地/云端位置**：只由 Kindle 和用户的同步选择处理。
3. **CastReader 活跃会话**：保存当前模式、播放状态和当前页句子游标，用于 UI 重新挂接。
4. **CastReader 持久化锚点**：仅当同 bookId、同真实 pageKey 且正文校验通过时恢复；否则安全回当前页首段。
5. **预测/预取缓存**：低优先级候选，永远不能改变当前页。

禁止：

- 依据 CastReader 历史锚点自动回答 Kindle 同步弹窗。
- pageKey 不一致时用 OCR 文本相似度跨页强行恢复。
- 用 scrubber 的目标 key 直接当作当前页真相。
- 为了扫描 TOC、重新挂接 MiniPlayer 或旋转屏幕 reload Kindle 页面。

## 4. 共享状态矩阵

| 入口/事件 | 已有同书活跃会话 | 无活跃会话 | 是否自动播放 |
|---|---:|---:|---:|
| 点击 MiniPlayer | reattach + ensurePlaying | 不应出现入口 | 是，幂等 |
| 点击书封 | reattach 页面但不改变播放意图 | 正常打开 Kindle | 否 |
| Kindle 同步弹窗出现 | 停止旧任务，记录原播放意图 | 锁定控制 | 否 |
| 弹窗关闭，之前正在播放 | 最终页重抓并按原模式开始 | 不适用 | 是 |
| 弹窗关闭，之前已停止 | 更新最终页 | 更新最终页 | 否 |
| 前后台/锁屏/旋转 | 只 reattach UI/viewport | 保持 Kindle 页 | 否 |
| 用户关闭 MiniPlayer | 结束唯一播放会话 | 无操作 | 否 |

## 5. WebView 桥接契约

### 5.1 同步弹窗事件

WebView 只上报结构化字段，不上传弹窗正文或书籍正文。

弹窗显示/隐藏：

```json
{
  "type": "kindle-sync-dialog",
  "visible": true,
  "localLocation": 1097,
  "cloudLocation": 1088
}
```

用户选择：

```json
{
  "type": "kindle-sync-dialog-choice",
  "visible": true,
  "choice": "yes",
  "localLocation": 1097,
  "cloudLocation": 1088
}
```

`choice` 只能是 `yes`、`no`、`unknown`。该事件只用于状态和日志，客户端不得代替用户点击。

### 5.2 DOM 探测

候选容器：

- `ion-alert`
- `ion-modal`
- `[role="dialog"]`
- `[aria-modal="true"]`
- `.alert-wrapper`
- `.modal-wrapper`
- 容器及其开放的 `shadowRoot`

当前识别英文和简体中文标题、位置及按钮：

- 标题：`Most Recent Page Read`、`Most Recent Location`、`最近阅读页/阅读位置`
- 位置：`location N`、`位置 N`
- 选择：`Yes/No/OK/Cancel/Stay` 及对应中文

DOM selector 和文案都不是稳定 API，必须保留以下 fallback：

- 只在可见 modal/dialog 中匹配，避免命中隐藏模板。
- 标题匹配失败时不锁死阅读器。
- `localLocation/cloudLocation` 解析失败可为空，仍允许用户操作 Kindle 弹窗。
- 页面导航开始时也视为弹窗解析阶段结束，防止旧 JS context 来不及发送 hidden。

### 5.3 生命周期

```text
dialog shown
  -> generation + 1
  -> capture wasPlaying + mode
  -> cancel active playback and all old work
  -> disable CastReader controls

user chooses in Kindle
  -> observe choice for diagnostics only
  -> wait for dialog hidden OR navigation start

resolution
  -> debounce about 650ms
  -> wait document/page-ready/image-stable
  -> capture real visible pageKey
  -> reset old live page state
  -> resume only when wasPlaying=true
```

快速连续导航、退出或切书时，所有异步步骤必须用 generation/task token 丢弃旧结果。

## 6. CastReader 句子锚点

共享字段仍保留：

- `schemaVersion=1`
- `readerImplementationVersion=1`
- `bookId`
- 真实 `pageKey`
- `pageTextHash`（SHA-256）
- `paragraphIndex`
- `wordIndex/charOffset`
- `anchorPhrase` 与 `anchorWordOffset`
- `voice`
- `speed`
- `updatedAt`

恢复约束：

- 只允许同 bookId + 同真实 pageKey。
- hash 相同可直接定位。
- hash 变化时才做 anchor phrase 匹配。
- 模糊匹配阈值 0.84；最佳与次佳差小于 0.12 时视为歧义，回页首。
- 旧 schema、pageKey 不同或正文无法校验时都安全失效。
- 连续播放使用 coalescing/throttle 持久化，并在停播、翻页、退后台时立即 flush。

本轮 UI 不暴露冷启动“继续听”，因此锚点当前主要用于活跃会话、诊断和未来 Kindle 提供可靠定位 API 后的升级。

## 7. iOS 实现位置

- `Views/Kindle/KindleHomeSection.swift`：删除重复的 Continue Listening 卡片。
- `Views/Kindle/KindleLibraryView.swift`：书架恢复为单一普通打开入口。
- `Views/Kindle/KindleBookView.swift`：活跃会话 ensurePlaying、冷恢复禁用、同步弹窗状态机、控件锁定、最终页恢复、native-first 翻页。
- `Services/KindleWebScripts.swift`：同步弹窗探测和选择事件、原生翻页优先。
- `Models/KindleModels.swift`：同步弹窗结构化事件和句子锚点模型。
- `Services/KindleLibraryStore.swift`：锚点持久化。
- `ViewModels/ReadAloudViewModel.swift`：句子游标更新和 flush。
- `Localizable.xcstrings`：弹窗期间提示的中英文文案。
- `CastReaderTests/CastReaderTests.swift`：锚点、ensurePlaying gate、同步弹窗 JS bridge 测试。

## 8. Android 落地要求

Android 不照搬 Swift 类型，但必须对齐产品状态和桥接字段：

1. 删除 Kindle 区域中与全局 MiniPlayer 重复的“继续听”入口；书封点击保持 open-only。
2. MiniPlayer 进入 Kindle 时调用幂等 `ensurePlaying`，禁止调用 toggle。
3. 无活跃 Kindle WebView/ViewModel 会话时，不根据持久化锚点自动导航或 autoplay。
4. 在 Kindle WebView 注入同步弹窗 observer，并通过现有 JS bridge 上报相同 JSON 字段。
5. 同步弹窗出现后取消当前页 TTS/QuickRead/OCR/prefetch，禁用 Compose 控件；绝不自动点击 Kindle 按钮。
6. 弹窗消失或 navigation started 后，等待真实 visible page 稳定；仅按之前的播放意图恢复。
7. 一次翻页只发送一个 transport 动作并轮询真实 pageKey；键盘事件只向一个焦点目标 dispatch 一次，让事件自然冒泡，禁止分别对多个 DOM 层级重复发送。
8. 统一使用 session/generation 防止旧 OCR、TTS、QuickRead、popup resolution 污染新页。
9. Release 日志只记录 bookId/pageKey 截断、hash、location 数值、策略、耗时和 reason；不得记录正文、弹窗全文、OCR head/tail。
10. OCR 候选缓存按 content-key 保存；翻页后以实际 pageKey 命中，不得因预测 `afterKey` 不一致丢弃同一页面的 OCR。TTS/QuickRead 仍需 pageKey + textFingerprint 匹配。

建议 Android 事件日志：

```text
kindleSyncDialog shown local=1097 cloud=1088 wasPlaying=Y mode=read generation=42
kindleSyncDialog choice=no generation=42
kindleSyncDialog resolved reason=hidden pageKey=... resume=Y elapsedMs=...
kindlePageTurn strategy=scrubber|chevron|tap-zone|keyboard direction=next dispatchCount=1 changed=Y elapsedMs=...
kindleOcrCache pageKey=... result=hit|inflight|fresh elapsedMs=...
kindleContinue route=existing-session ensurePlaying=Y reload=N elapsedMs=...
kindleContinue route=cold ignored reason=no-live-session
```

## 9. 验收用例

### UI

- 首页同一本 Kindle 书不会同时出现 MiniPlayer、Continue Listening 卡片和书架书封三个入口。
- 只有活跃会话显示 MiniPlayer；关闭后入口消失。
- 普通点书不自动播放。

### 会话

- 后台正在播放同一本书，点 MiniPlayer 只 reattach，不 reload、不暂停、不重复 TTS。
- loading 时重复点 MiniPlayer，不产生第二个任务。
- 横竖屏、前后台、锁屏回来后 pageKey 和分页模式不变。

### Whispersync

- 构造/等待本地位置与云端位置不同的 Kindle 弹窗。
- 选择 No：保留当前页，若之前播放则从该页重新开始。
- 选择 Yes：等待 Kindle 跳转后的真实页，若之前播放则从新页重新开始。
- 用户未选择时 CastReader 所有可能改变书页的控件不可用。
- 弹窗文案识别失败时不崩溃、不自动操作、不泄漏正文。

### 翻页和云端进度

- 连续自动翻 10 页，每页 pageKey 真正变化，朗读/高亮对应当前页。
- 手动滑动、底部按钮、自动翻页混用后结果一致。
- 等待 Kindle 同步并重新打开，记录 Amazon 弹窗中的本地/云端 location，比较不同 transport 的云端进度更新率。
- 每次翻页必须记录 transport 和 dispatchCount；`dispatchCount > 1` 视为实现错误。
- 实际页已在候选缓存中时，日志不应再次出现该页的 fresh OCR。

### 隐私和性能

- Release 日志搜索不到 Kindle/OCR 正文和同步弹窗全文。
- 活跃会话 MiniPlayer 进入到声音恢复不触发网络重抓；目标 P50 <= 2.5s、P95 <= 5s。
- 无活跃会话普通打开不承担 CastReader 冷恢复的 9-11s 等待。

## 10. 已知边界

Amazon 未提供公开的 Kindle 阅读进度写入 API。CastReader 不能可靠地直接把 `location 1097` 写入 Whispersync，也不应调用未验证的私有接口。当前最稳妥的策略是只触发一次 Kindle 自己的 transport、观察真实页和后续云端同步结果；当 Amazon DOM 变化时，弹窗和翻页 selector 需要根据脱敏日志更新。
