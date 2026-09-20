# 安卓本轮问题在 iOS 的对照定位

> 后续：用户已授权修复，实施与验证见 [iOS 对齐修复记录](iOS-Kindle-Playback-Parity-Fix-2026-09-19.md)。本文保留修复前的定位结论。

本轮只定位，不修产品代码、不提交发布。对照 Android `340710a`（换声、连续播放、Kindle 标注与翻页）及 `fc4af1a`（完整脚注过滤），以 iOS 1.2.41（63）送审工作树的现有源码为依据。

## 结论

| 问题 | iOS 结论 | 证据等级与范围 |
|---|---|---|
| 只跳编号、不跳解释正文 | **存在，P1**。iOS 仍是句末小号上标过滤；本页两个引用及解释都未过滤 | 原华为书页经模拟器真实 Vision、生产 Kindle OCR 入口和语音投影重放 |
| 朗读与解读的脚注开关口径不同 | **存在，P1**。朗读调用投影，解读当前页和预读输入直接使用原始文档 | 源码链路确认；未登录真实 Kindle，未捕获线上 Explain 请求 |
| 段间等音频时翻页不续播 | **存在于微信读书消费的续播判定，P1**；不能直接套到 Kindle | 真实 ReadAloud VM / AVPlayer + 延迟 TTS 模拟器复现，桥接调用点确认 |
| Mark 没画完就进入翻页流程 | **存在缺少动画完成条件的时序缺口，P1** | 实际解读 VM / 播放器 / 多行 mark 锚定测量；真实书籍上可见翻页时刻待验收 |
| 预读切换导致笔触变细、多行丢失 | **未复现安卓原来的笔宽/路径故障**；但进行中动画会被当作已完成，仍有跳变风险 | 静态 WebKit/SwiftUI 可见墨量测试通过；动画进度丢失由源码确认 |
| `E-TURN`：重复 I、文本与词框顺序不一致 | **本次未复现** | 同一安卓失败页经 iOS 生产 OCR 成功，文字和词框顺序一致 |
| 手动翻页抢占旧预读任务 | iOS 已在异步等待前停止旧播放、取消任务并改变代次 | 源码与翻页/设置所有权回归支持；held 页面真实上/下翻仍需登录后操作 |
| 设置后 Play 反向暂停、后台预读时不能恢复 | 未发现安卓相同的双重 toggle / `isPageTurning` 拦截路径 | iOS 睡眠恢复只清标志，按钮交给 Explain VM；现有暂停恢复专项通过 |
| 长段换声串行生成已读前缀 | iOS 1.2.41 已有可信后缀生成与目标音色缓存 | 相关实际 VM / 播放器测试通过；不是云端延迟或所有锚点条件的性能保证 |
| 请求自身超时被当作用户取消 | 未发现 Android `withTimeout` 的同一原因 | Swift 区分 URLError 超时和任务取消，超时后只重试未播尾部的回归通过 |

## 1. 完整脚注过滤尚未对齐

`KindleFootnoteSpeech.swift:42–60` 明确将功能限制为句末独立识别的小号上标，策略版本为 `kindle-vision-reference-v2`。它逐段处理，没有“正文引用—本页解释段”的配对逻辑；`isReference` 也只接受独立的纯数字词。

将安卓保留的脚注页像素送入 iOS `recognizeKindle` 后：

- 识别到 **7 段**，全部词框来自 Vision，规范化文本与词框串联内容完全一致。
- 定义正文仍为第 **3、4 段**，两段开启过滤前后完全相同；**删词数为 0**。
- iOS 本次实际识别的相关词是 `declination|2|`、`inclination|3|`、定义开头 `12` 和 `[3]`。这与华为曾出现的 `[21`、`[2l` 不完全相同，不能直接照搬 Android 的 OCR 特例。
- 当前设置文案也明确写着“保留正文数字和脚注内容”，与用户最新要求不一致。

更重要的是输入链路未统一：

1. 朗读的 `buildTextQueue`、当前页续读准备、下一页音频预读均调用 `KindleFootnoteSpeech.prepare`（`KindleBookView.swift:9623、12841、13135`）。
2. `buildTextQueueForCurrentPage` 在普通解读模式返回原始文档（`:9535`）；`makeExplainVM` 直接接受该文档（`:8711`）。
3. `startExplainFirstBlockPrefetch` 直接把原始文档交给 `prefetchFirstBlock`（`:13213`）。因此只扩展朗读的过滤函数，仍不能让解读遵守同一个开关。

证据：[脚注重放结果](../reports/ios-android-parity-diagnosis-20260919/diagnosis-footnotes.json)。原始书页及完整 OCR 文本仅保留本机私有诊断产物，报告不复制整页内容。

## 2. 自然音频间隙被误判为没有续播意图

定位在 `ReadAloudViewModel.shouldResumeAfterManualLivePageTurn`（`:1067`），由微信读书 `WebReaderBridge.handleWeReadPageChanging` 使用（`:2664`）。

模拟器让第一段真实音频播完，第二段 TTS 延迟返回，捕获到：

| 状态 | 结果 |
|---|---|
| VM active | true |
| 用户主动暂停 | false |
| 播放器等待下一片 / moreSegmentsExpected | true / true |
| 当前正在发声 | false |
| 已结束的 currentSegment 仍保留 | true |
| VM 判断“正在等待可播放音频” | true |
| 手动翻页后应续播 | **false** |

原因：当音频归当前 VM 所有而且暂时不发声时，续播判断还要求 `currentSegment == nil`。但自然片段结束后 AVPlayer 仍保留旧片段，导致真实的等待状态不符合条件。它与 Android 本轮 `STATE_ENDED + moreSegmentsExpected` 时误用瞬时播放状态的故障相似。

**Kindle 不直接使用这个判定。** 它的 `shouldResumeAfterUserPageTurn`（`KindleBookView.swift:8175`）另有 book ID / 当前片段与准备状态判断。本次不能宣称 Kindle 也已复现这个停播问题。

证据：[自然间隙复现](../reports/ios-android-parity-diagnosis-20260919/diagnosis-natural-gap.json)。这是生产 VM / AVPlayer 与受控 TTS 的实测，不是操作在线微信读书页面的最终验收。

## 3. 标注结束与页面完成不是同一个条件

`ExplainViewModel.onBlockComplete` 在音频及 plan 完成后调用 `onDocumentFinished`（`:2213–2273`）。Kindle 立即进入 `advanceToNextExplainPageIfNeeded`（`KindleBookView.swift:10036、11377`）；该流程等待预读/页面确认，但**没有等待当前页 mark 动画结束**。

模拟器通过真实 Explain VM、AVPlayer、MarkAnchoring 和 PhotoAnchorResolver 得到一个两行 mark：

- 实際解析出的 mark 绘制时长：**2,200 ms**。
- mark 发布到文档完成回调：**约 565 ms**。
- 回调发生时，按该 mark 的实际路径时长仍有约 **1,635 ms** 未完成。

证据：[标注时序测量](../reports/ios-android-parity-diagnosis-20260919/diagnosis-ink-completion.json)。用的是受控正文、几何和音频，不是线上书页录像。页面确认和网络可能额外拖延，因此这个测量证明“缺少完成条件、可以过早发出翻页请求”，不能当作每次可见页面都提前 1.6 秒切换的结论。

### 预读时还会丢失进行中的动画进度

`maybePrepareExplainPageDuringAudioTail` 把全部 `owner.activeMarks` 写入 `initiallyDrawnMarks`（`:11310`）。这些 ID 表示“已触发”，并不表示“已画完”。`KindleExplainVisualHoldView` 再以 `animateOnAppear: false` 渲染它们（`:79–113`），`MarkInkView` 直接将进度设为 1（`MarkOverlay.swift:38`）。

所以 iOS 仍可能在开始预读时突然补齐一笔；这与 Android 的旧笔宽变化是不同问题。现有 21 项容器测试包含多行路径、7 种工具 × 3 种权重的 live/redraw 属性一致性，以及 live/native 的实际墨量比较，均通过。**静态外观通过不代表动画连续性通过。**

## 4. 本轮未复现或已有保护的部分

### OCR 与翻页确认

安卓 `E-TURN` 失败页在模拟器经 iOS 生产 Kindle OCR 入口得到 **4 段**；全部词框来自 Vision，文本与词框顺序一致，未出现华为 ML Kit 的重复 I 及整页顺序拒绝。iOS 的 `rebuildLine` 从同一个排序后的词列表构造文本和词框（`OCRService.swift:1547`），没有 Android 原来“追加文字与重排词框分开做”的同一实现。

iOS `validateKindleDocument` 主要检查覆盖率，而非逐字相等；本次额外比较了实际输出的规范化串，不能把单纯的生产校验通过等同于所有页面的顺序正确。证据：[失败页重放](../reports/ios-android-parity-diagnosis-20260919/diagnosis-etturn.json)。

翻页确认已有方向、稳定像素、单次派发和未知派发恢复保护。本轮 21 项翻页证据测试、31 项设置所有权测试通过。`performManualPageTurn` 在第一个 await 前停止旧播放、取消旧任务和改变 epoch；但真实 held 页面上一页/下一页/暂停交错操作仍列为登录后的必测项。

### 音色、预读与超时

iOS 当前版已有后缀生成、A→B→A 已完成音频缓存、跨书源有界预读和音色归属检查。13 项已有 SpeechPipeline 测试及 7 项 ReadAloudContinuation 测试通过，包括短前缀跳过、错内容拒绝、保留页面不能抢新页面音频、暂停预读、失败后只重试未播尾部、迟到响应与超时恢复。

这些是可控传输下的功能证据，不是社区/私人音色生产服务延迟测量。Android 报告中另有“微信读书网络错误页还能播放旧音频”的未解决异常；iOS 导航失败有重试与入口恢复，但瞬时错误分支未直接停播，仍需真实页面故障注入区分“旧正文仍可见”与“已变成错误页”。本轮不将它判为已通过。

## 验证基线及限制

- iOS 工作树：`CastReader-mobile-voice-explore-20260914`，HEAD `febfeab` 加既有 1.2.41 送审增量；没有使用主目录旧分支。
- 原模拟器：`CastReader-Release-1.2.40-Store`，实际安装版本 **1.2.41（63）**。启动后停留在 CastReader 登录页，尚不能访问已绑定 Kindle。已请用户登录；未修改账号、Cookie 或绕过绑定。
- 独立诊断模拟器：iPhone 15 Pro Max / iOS 26.5，UUID `98451CEA-5D9C-4668-9B7D-F254B7A0D237`。构建目录 `/tmp/CastReaderKindleDiagnosisBuild20260919`，诊断源码副本 `/tmp/CastReader-iOS-Kindle-Diagnosis-20260919`。
- **211 个产品 Swift 文件与原工作树逐文件哈希一致。** 额外诊断测试只写在 `/tmp` 副本；本工作树仅新增本文和脱敏报告，没有修产品代码、重装用户真机或发布。摘要见 [source-identity.json](../reports/ios-android-parity-diagnosis-20260919/source-identity.json)。
- 共 **125 个不同的模拟器检查用例**，最终观测断言通过。诊断用例有意验证“当前缺陷确实发生”，其通过不表示产品缺陷修好了。初次时序测试因只提供一句话，被短块规划器以 `noBlock0` 拒绝；改为满足既有契约的两句话，并进一步使用真实多行 mark 几何后完成测量。该初次失败和各轮结果保留在 [test-summary.json](../reports/ios-android-parity-diagnosis-20260919/test-summary.json)，没有把整轮初次结果改写为通过。
- 不把源码检查、旧华为截图重放、受控音频和在线 Kindle 连续播放混为同一种证据。**真实 Kindle 登录后多页朗读/解读与手动抢占验收尚未完成。**

## 后续修复顺序建议（尚未实施）

1. 先修复自然音频间隙的续播意图，保留用户暂停、睡眠和任务所有权的优先级；同时回归各书源调用点。
2. 将确认后的完整脚注投影统一用于朗读、解读、预读和缓存身份，保留原 OCR 几何与定位。增加 iOS Vision 本次独有的词内竖线、`12` 等样本，歧义时不删正文。
3. 为同一 mark 保存起笔时刻与持续时间，使 live/held 切换保留绘制进度；自动翻页等待剩余笔触和最终展示帧，等待有界且可被手动翻页、暂停、切模式取消。
4. 在绑定书架恢复后，补真实书页的连续播放、最后一笔触发、held 前后翻、暂停再翻及网络失败状态验证，再决定是否进入修复与发布阶段。
