# iOS 四平台翻页连续性实施与验收

## 基线与范围

- 从远端 main `f1c423e312cdcfbf121b11428aa7867b35488a84` 增量修改；分支 `codex/ios-four-platform-pagination-20260929`。1.2.47 (70) 已送审的归档保持冻结。
- 依据 `readout-desktop/docs/ebook-pagination-mobile-parity-guide-2026-09-29.md` 与同目录 acceptance-template。扩展结果仅作为实现参考。
- Kindle、微信读书、Google Play Books、Kobo，各自覆盖朗读和解读。
- 用户确认先完成 iPhone；没有可用 iPad。禁止模拟器替代真机，iPad 横竖屏/双栏标为未验收。
- 初始性能目标：warm 附加等待 P95 ≤100 ms、max ≤200 ms；全部超标列出原因。语义标点停顿保留，媒体事件不冒充声学静音。
- 长测目标：最终构建每个优先组合前台连续 ≥30 分钟、≥3 完整章节、≥20 自动翻页。书长导致未达标必须记录，不用人工跳章替代。

## 架构审计与缺陷

| ID / 指南 | 已证实的实现问题 | 处理方向 | 状态 |
|---|---|---|---|
| IOS-P01 / C03,C04 | AudioPlayerService 预热仅加载 asset tracks/duration，消费时重建 AVPlayerItem；不是解码就绪交接 | 有界、静音预解码的播放器租约，消费转移原实例；取消只释放自己的资源 | 已实现，待最终真书验收 |
| IOS-P02 / W01,W02,Q04 | WeRead predictNext 有按可见字数猜下一页，Explain 允许相似文本复用 | 原生 HorizontalReader 页序、chapter UID、glyph offset 与 paintPageFinish；精确来源才复用 | 已实现，待最终真书验收 |
| IOS-P03 / C07 | ReadAloudViewModel 用 duration × 字符比例生成跨页时间 | 真实 cue 映射；粒度不足显式错误，禁止伪造时间 | 已实现，待最终真书验收 |
| IOS-P04 / O02,O05,O06 | Kobo 原文/Range 包含隐藏行内标签；frameClip 只拒绝几乎透明 iframe，没有等待父容器淡入完成 | 共用规范化 Text 节点映射；#BookView / ReadingOrderView 绘制门禁 | 已实现，待最终真书验收 |
| IOS-P05 / C11,Q07 | WeRead 手动导航可能沿用 Explain 恢复意图 | 手动导航撤销 Explain 与预取，自动翻页单独持有 owner | 已实现，待最终真书验收 |

## 验收台账

所有单元格初始均为未执行。后续每次记录真实安装 SHA、加载脚本身份和原始证据；不复用旧版本的长测结论。

| 平台 | 模式 | 合同/故障注入 | iPhone 功能 | 最终构建长测 |
|---|---|---|---|---|
| Kindle | 朗读 | 41 轮 native restore/overlay 与 sync 共 18 项通过 | 41 轮真书启动、切模式及暂停定点通过；最终矩阵未完 | 未执行 |
| Kindle | 解读 | 41 轮恢复源与 capture lease 用例通过 | Read→Explain 及连续两次自动翻页标注定点通过；完整矩阵未完 | 未执行 |
| WeRead | 朗读 | 已执行，最新候选扩大回归中 | 预设真书四次翻页通过；克隆 cue 缺失阻塞 | 未完成 |
| WeRead | 解读 | 37 轮目录取消与迟到旧重试回归通过 | 35 轮试读墙→目录第一章→解读→第二章定点通过；最终矩阵未完 | 未完成 |
| Play Books | 朗读 | 43 轮 Google WK 39 项通过/1 跳过 | 真书 1.5×、跨页词高亮功能定点通过；约 804 ms 同片段等待失败；SVG 封面待复验 | 未完成 |
| Play Books | 解读 | 旧页清理受控用例通过；同 producer 接管未关闭 | 43 轮切模式/自动下一页/实际圈线定点观察，未等同取消矩阵或性能通过 | 未执行 |
| Kobo | 朗读 | 生产脚本两/三页受控回归通过 | 未执行最终真书验收 | 未完成 |
| Kobo | 解读 | 未执行 | 未执行 | 未执行 |

## 交接合同

原生页序、源 UTF-16 范围、媒体 part 顺序分别保留。所有异步提交校验会话/代次/当前配置。精确目标页已绘制、当前锚点可用以后，才按用户 play 意图释放媒体；pause/stop 优先。WAIT_CONSUMPTION 不设资源超时，WAIT_RESOURCE 与 WAIT_PRESENTATION 分别设截止时间。未知章节结尾不等于全书结束。

解读复用同一个计划 job/producer，接管首段已解码资源；清理预取时不得释放已转移资源。手动导航清理旧摘要、标注与任务。诊断仅保存身份摘要、源范围、单调时间和原因，不记录正文、凭据或媒体 URL。

## 执行证据（阶段性，不等同最终验收）

- 2026-09-29 17:18，iPhone 15 Pro Max 真机、候选 Debug 1.2.48 (71)：第一轮 PaginationContinuityTests 8 项 + AudioPlaybackFailureRecoveryTests 7 项通过，共 15 项、0 失败。真实 AVPlayer preroll 已完成，交接保持原实例，原所有者清理不能释放已接管的媒体。结果包 `/tmp/CastReaderPagination-core-20260929.xcresult`。
- 17:25 第二轮增加媒体时钟冻结/恢复/暂停优先和真实 WKWebView 原生页桥接。原生桥接测试首次在单帧等待后读取过早，5 个断言失败；保留原始结果，不计作通过。正在改为等待可观测绘制回执，并增加来源和事件检查。
- 尚未完成：部分音频跨页的持续 producer 交接、Google 原生临时分页 DOM 对接、Kobo 断词与首字下沉、Explain 首段解码交接，以及最终构建四平台真实长测。当前候选不可宣称全面验收或送审。

- 原生桥接复验进一步发现：翻页请求和源字形更新后，旧 `ready` 会保留到下一次 RAF，存在一帧旧画面被认可的窗口。已改为原生导航前同步撤销 ready、绑定精确目标；预加载修订和 paint 回执同步发布。新增 fixture 保留“未绘制时不得 ready”断言，未通过前不记为修复完成。

### 17:30–18:10 真机受控链路结果

- `/tmp/CastReaderPagination-native-race-20260929.xcresult`：13 项通过；原生翻页请求同步撤销旧 ready，原地更新字形对象不会复用旧指纹。
- `/tmp/CastReaderPagination-google-20260929.xcresult`：53 项、1 条条件跳过、0 失败（Pagination + Google 原桥接回归）。
- `/tmp/CastReaderPagination-producer-20260929.xcresult`：45 项、0 失败（Audio failure recovery + Pagination + WeRead availability）。验证视觉翻页期间延迟 partly 响应仍由原 producer 加入原队列、粗粒度/错误后续 cue 在入队前整体拒绝。
- `/tmp/CastReaderPagination-cue-ack-20260929.xcresult`：57 项、1 条条件跳过、0 失败。实际 Kobo 生产脚本 → WebReaderBridge → Read VM → AVPlayer 边界冻结 → 原生按钮翻页 → Range 绘制 → 回执 → 同 item 恢复。发现旧固定等待导致约 789 ms 媒体暂停；该阶段性能不通过。
- `/tmp/CastReaderPagination-three-page-20260929.xcresult`：20 项、0 失败。按目标页实际几何连续采样 + 绘制确认替代自动翻页固定稳定等待。连续三页两次翻页仍只有一个完整源 TTS 请求；三次可控页面媒体 hold 为 125.1、122.4、115.1 ms。低于 max 200 ms，但样本太少且高于 P95 100 ms，不作性能通过声明。
- 这些测试运行真实 iPhone 的 WKWebView/AVPlayer，书页/网络输入受控，**不是**四个平台登录真书长测，也不是声学静音测量。Xcode 附加诊断收集曾失败，实际 test 执行结果单独读取。

### 待解决与复验

- 微信读书早期真书曾为 NormalReader 纵向模式；18:15 后真实《茶花女》已进入 HorizontalReader 并产生原生字形页身份。NormalReader 兼容性仍未验收，不把当前横向模式通过泛化到纵向模式。
- WeRead 多页持续同句的逐词映射与连续原生列身份；Google 临时排版跨框架真书；Kobo 跨页断词、未知章节末；四平台解读的任务交接与取消，均需逐项复验。
- 指南新增 C16 极短标题预缓冲与 C17 幂等连字符规范化。C17 和媒体 item 结束与页面回执竞态正在实现/测试。
- 扩展参考目录存在其他任务的未提交改动。后续构建固定引用 `/tmp/castreader-pagination-extension-9694b2c/src`（从提交 `9694b2c3dd368b959012309cadf508ab2cad4b67` 导出），不会把正在修改的扩展源码无记录带入候选。iOS 新的 native adapters 保留本地增量。
- 当前源码未冻结，最终 8 个组合与 iPad 状态仍如上表未验收。不得发布“100% 不停顿”的结论。

### 18:10–18:52 微信读书翻页时机专项

- 用户纠正：当前可见页读完必须对应翻页，不得在旧页读完下一页第一段再翻。预读完成仅表示资源就绪，不授予翻页或跨视觉边界播放的权限。
- 修复预取晋升绕过 source cue 校验的问题；所有已生成 parts 在入队前整体校验。跨页时间戳不可靠时，不再落入“整句结束才翻页”的分支。
- 修复 `loadSegments` 内部 `stop` 清除刚安装的边界；只转移与同会话和入队 segment 匹配的待触发边界。完整页边界由实际媒体结束触发，取消基于预取提前量的翻页。
- 第 16 轮 27 项中有 1 项失败（整页预取先于播放器进入 playing，未重试）；增加播放状态到达后的准备/安装。第 17 轮 27 项全部通过，结果 `/tmp/CastReaderPagination-page-end17-20260929.xcresult`。
- 18:34 真书私人克隆音色：后端返回的中文 source cue 不足，`prefetch_cue_rejected reason=source_cue_coverage_missing`，上一段结束后停止。这仍是未修复问题，不能以防止错页的保护性停止作为连续性验收通过。证据 `/tmp/castreader-pagination-live16-reader.log`。
- 18:41 真书预设晓萱：页尾目标 10.019541667 秒，实际媒体 hold 10.026850167 秒（约晚 7.3 ms），已触发原生翻页，但高亮回执误判导致未续播。进一步定位到 `callAsyncJavaScript` 误选 completion-handler/Void 重载；已改为 `contentWorld:` 的真正 async API。
- 第 18 轮新增 WeRead 中文生产桥全链路 fixture，发现 main executor 忙时边界 callback 延迟约 107 ms；回执错误也被同例复现。原始失败结果 `/tmp/CastReaderPagination-weread-bridge18-20260929.xcresult` 保留。
- 第 19 轮使用 AVPlayerItem 的临时 `forwardPlaybackEndTime` 由媒体引擎直接钳制当前可见源边界，页面确认后清除上限并继续同一 item；中间人工结束事件不计作句子播完。主线程阻塞 400 ms 故障注入仍停在真实 cue；恢复后继续原媒体且 Pause/新 owner 优先。
- 18:52 第 19 轮真机 36 项全部通过（Pagination 29 + Audio failure recovery 7），包括 WeRead 原生页生产脚本→WebReaderBridge→Read VM→AVPlayer→绘制回执→同句续播；结果 `/tmp/CastReaderPagination-native-end19-20260929.xcresult`。构建 `/tmp/castreader-pagination-build19.log`，测试 `/tmp/castreader-pagination-native-end19-test.log`。
- 以上仍是阶段性受控验证；最终构建真书长测、克隆 cue、三页同句及其余四平台/模式验收未完成。当前候选 1.2.48 (71) 为命令行开发构建覆盖参数，未修改已送审项目版本。

### 18:53–19:03 真实页尾、MP3 结束和跨三页

- 第 19 轮真书已在 10.019541667 秒 cue 准确 hold（记录 10.019541），页面回执 94.8 ms 后释放。但实际 MP3 句尾略短于估算时长，结束事件被错误归类为人工视觉截点，导致句后段落未启动。
- 第 20 轮将人工结束判断收紧为“当前媒体时间确实处于该视觉截点”，不再用整句估算 duration 判断。新增真实 2 秒数据、2.2 秒服务器 duration 的回归；37 项全部通过，`/tmp/CastReaderPagination-mp3-end20-20260929.xcresult`。
- 第 20 轮真书《茶花女》预设晓萱，18:57:19–18:59:43 已连续四次自动翻页，四次均完成页面确认、原音频后缀续播和后续段落晋升，无 source cue rejection。原始证据 `/tmp/castreader-pagination-live20-reader.log` / `live20.log`；导航属于实际原生页 `geometry=native-glyphs`。
- 四次 hold→release：116.8、117.6、103.3、130.7 ms。媒体时钟边界最大观察偏差约 0.235 ms；这是媒体事件和页面确认指标，未做声学静音测量。max <200 ms，P95 尚不满足 ≤100 ms，且不是最终构建长测。
- 第 21 轮改用当前真实 cue 与当前页 source interval 绘制续页高亮；同句跨三页时，保持 producer，并在每个确认页重新安装下一真实页边界。新增生产 WeRead 脚本三页 fixture，两次 0.35/0.9 秒翻页、一个自然句请求通过。38 项全部通过，`/tmp/CastReaderPagination-three-page21-20260929.xcresult`。
- 第 22 轮从原生列提取后续可见页边界，在一个完整中文请求内加入每处空白提示，并在音频入队前验证所有已知边界；后续粗 cue 不得被第一处正确 cue 掩盖。跨三页请求及 cue 校验回归通过，扩大回归仍在执行。
- 微信读书克隆中文真实 cue 缺失仍未解决。四平台其他模式、最终长测和 iPad 没有因以上局部通过而自动变为验收通过。

### 19:03–19:10 扩大回归

- 第 22 轮 87 项测试有 5 个失败断言，保留 `/tmp/CastReaderPagination-multicue22-20260929.xcresult`：两个预读预算用例依赖默认 1.0 倍速，但用户手机设为 1.5，测试现保存/恢复速度并显式设定测试速度；一个横跨 8 类输入的用例在 WeRead/Google/Kobo 独立 VM 无页面回调时被新增整页 hold 卡住（3 个断言），产品已改为仅在页面回调接入时安装整页门禁。
- 完整页结束改由实际 AVPlayerItem didEnd 触发，不靠服务端或容器估算时长的定时器；新增 1.4 秒估算/2 秒实际音频验证，仍在实际 2 秒结束才翻。跨页源 cue 仍由媒体引擎设置精确上限。
- 第 23 轮 88 项、0 失败：Pagination 33、Audio failure recovery 7、SpeechPipeline 28、WeReadPageAvailability 20。结果 `/tmp/CastReaderPagination-final-edge23-20260929.xcresult`。
- 包含页面错误/超时、手动切页、解读页暂存、页内恢复、旧 VM 所有权与正常流式预读。名为 iPadViewport 的用例仍是在 iPhone WKWebView 中调整几何的夹具，不能记为 iPad 真机通过。
- 代码审计追加发现：跨页句显示在新页时 `currentParagraphIndex=-1`，原播放按钮会误走 start。第 24 轮补充保留同一音频的按钮暂停/恢复及迟到回执检查，正在构建验证。

- 第 24 轮 92 项真机回归全部通过（Pagination 34、Audio failure 7、权益刷新暂停 3、SpeechPipeline 28、WeReadAvailability 20）。结果 `/tmp/CastReaderPagination-carry-controls24-20260929.xcresult`，含跨页 carry 上的真实按钮暂停/恢复，确认同一 AVPlayer、无重复生成、迟到回执尊重暂停。
- 第 24 轮源码摘要 `06377f7f76ac447a1e82bb94686b639c2d7993f36ba919cfd97dd9d832798836`；debug dylib UUID `CAAF88A4-146E-3A69-A98C-7F82BE98BCDC`。可复核文件散列与测试计数见 `reports/ios-pagination-20260929/candidate-24.json`。19:15 启动同包真书复验，不复用第 20 轮的真书结果替代。


### 19:19 后：用户听感未通过，继续修复额外停顿

- 用户明确反馈：微信读书在翻页处仍有断句式暂停，扩展听感更顺滑。本次反馈覆盖此前“页身份与时机通过”的局部结论；整体连续性仍未验收。
- 对照扩展当前 `src/core/weread-continuous-reading.ts` 与 `audio-manager.ts`：原生源偏移拼完整自然句，跨页只转移视觉锚点；音频继续复用当前 decoder，下一段提前准备。扩展同样有视觉确认等待，不应误述为无条件让隐藏页继续播放。
- 扩展 WeRead 长测文档 `docs/weread-continuity-validation-2026-09-29.md` 记录：晓萱 1.5 倍，原生交接中位 22.2 ms、最大 71.4 ms；段间 ended→playing 中位 3.5 ms、P95 7.1 ms。开头仍有一例 391.2 ms，不能称全场零等待。构造中文音频 A/B 的页边界空白提示未增加第二次合成，页面边界处原音频已有约 279 ms 静音；不能由此推断所有语音样本一致。
- iOS 第 24 轮真书日志 `/tmp/castreader-pagination-live24-reader.log`：19:18:06 整页 hold→release 130 ms，随后下段 playing 再等 124 ms，共约 254 ms；19:18:38 同句跨页 135 ms 页面等待 + 48 ms 媒体恢复，约 183 ms。此前仅统计 hold→release 会低估用户实际听到的附加等待。这些事件不是逐采样声学测量。
- 第 25 轮改动：以本页最后词 end 开始翻页，在同一媒体内有有效下一词 start 时保留这段实测间隔的媒体推进，只在目标页未确认而下一词已到时冻结。时间戳相接时不杜撰空隙。预解码按实际播放倍速准备；倍速改变撤销旧 preroll 回执。构建通过，但第一次测试因手机锁屏取消，无测试通过结论。
- 第 26 轮把下一源 cue 与 Canvas 交接合并为 JS 内绘制，带原操作 UUID、目标 contentFingerprint 的两帧回执直接提交；避免 Swift→JS 再次 init/highlight/确认的重复往返。真实 iPhone 回归发现两/三页 fixture 的快速回执没有生效（两项失败），普通回退可续播。定位为 host 在收到旧 page-changing 后迟到的 clearHighlight 擦除了 JS 新高亮；第 27 轮保留原生自动交接中 JS 自己的同步清理，取消这条重复 host 清理，复验中。
- 此轮未部署后端，未修改或重新提交已送审 1.2.47。中文克隆 cue 缺失、四平台所有模式最终长测仍待完成。

- 第 27 轮 `/tmp/CastReaderPagination-atomic27-20260929.xcresult`：真实 iPhone 的 PaginationContinuity 37 + Audio failure recovery 7 + entitlement pause 3，共 47 项、0 失败。两/三页 fixture 均收到带当前操作 UUID 的 JS 绘制回执；同一句仅一个源 producer。新窗口用例证明提前确认不冻结当前媒体时钟，超时仍由媒体引擎钳制到下一词，用户 Pause 可阻止迟到回执恢复。
- 第 27 轮 dylib UUID `716715DE-A222-3DA2-80B3-1FA78578F7CC`；包含新增文件的源码清单见 `reports/ios-pagination-20260929/candidate-27.json`。更多语音/WeRead 回归及真书实测结果另补，不能据 47 项受控测试宣布实际听感通过。


### 19:40 后：实际速度、句子高亮与剩余媒体恢复等待

- 第 27 轮另 48 项通过（SpeechPipeline 28 + WeReadPageAvailability 20），共 95 项、0 失败。受控通过不覆盖以下真书缺陷。
- 真书《茶花女》第四章、晓萱：19:41:12.931 请求翻页，19:41:13.029 视觉回执释放，19:41:13.131 才恢复 playing。约 98 ms 页面等待 + 102 ms 媒体恢复，共约 200 ms；本轮听感未通过。证据 `/tmp/castreader-pagination-live27-reader.log`。
- 用户截图同时显示多句高亮，播放器速度标签 1.5×，但同轮日志实际 `rate=1.00`。两个缺陷均承认，不能用标签证明速度生效。
- 19:42:04 的停止对应测试者主动暂停：媒体 7.926353 秒，下一视觉边界 8.070833 秒，尚差约 0.145 秒。本次停止不是自动翻页故障，不能混入故障统计。
- 速度根因：Continue Listening 已恢复段落并预激活 VM，随后直接重建音频，不走 `start()`；初始化时设置订阅尚无播放所有权，1.5× 未写入播放器，仍为默认 1.0×。修正为取得播放会话时立即绑定实际有效速度；新增四平台冷恢复测试，分别核验预生成速率与 AVPlayer 实际 rate。
- 中文高亮根因：无逐词显示时将一个 transport part 当作一个句子；一个 part 可含多句，`segmentTexts` 又令 JS 扩大到完整音频文本。现在保持一个音频 part，用保留的真实 cue 选择当前原文句子，只发送句子源范围；粗 cue 覆盖多句时清除过期高亮，不猜测句间时间。新增真实 AVPlayer 单 part 两句、粗 cue 两种回归。
- 对照扩展的 `weread-continuous-reading.ts`：句末判定忽略 U+200B–U+200D/U+FEFF，iOS 缺失；现在按相同规则判断，保留原始源偏移和 glyph 几何。新增原生适配器零宽字符回归。
- 第 28–30 轮媒体修正：同一 item 被视觉边界冻结后，在页面绘制期间按当前倍速 preroll；回执后恢复已激活的播放器，避免重复激活 AVAudioSession；接管预解码 item 不重复改 timePitchAlgorithm。保留暂停、所有权、失败恢复门控。
- 第 29 轮设备目标构建因 Xcode 明确要求解锁超时；generic iOS 真机目标编译通过，未运行模拟器。第 30 轮包含句末零宽字符规则，正在构建，尚无新真机验收结论。用户已被提示在 iPhone 本机解锁以恢复测试通道。

## 21:19 补充：32 轮真实镜像与目录切换故障

- 32 轮真机核心回归 52 项通过；补充四平台回归 162 项，1 项真实联网 shell 测试按既有条件跳过、161 项通过。结果分别为 `/tmp/CastReaderPagination-speed-highlight32-20260929.xcresult` 和 `/tmp/CastReaderPagination-four-platform32-20260929.xcresult`。这仍是受控输入回归，不等于四平台真实书籍长测通过。
- Play Books C19/C20 增量 measurement 更新、native anchor 位移裁切已补齐；本地真实 DOM fixture 16 项通过，相关物理 iPhone WKWebView 回归通过。Kindle 本地 native ordering 5,000 随机变更 / 20,000 ownership 检查通过；Kobo 可见段落与最后一句扩展的本地 fixture 通过。
- 32 轮真书《茶花女》晓萱：从 Continue Listening 进入后，实际 AVPlayer 日志为 1.50，与 UI 一致。镜像可见一句高亮。21:09:29.372 → 21:09:29.602 首次页交接约 230 ms；21:10:07.537 → 21:10:07.751 第二次约 214 ms，仍超过 warm 最大 200 ms 目标。不可仅凭 visual_release 约 115–123 ms 宣称无停顿。
- 21:10:25 自动下一页到达微信读书试读结束；21:10:29 超时停止。之后用户通过目录回到第一章，native readiness 一直未确认；21:11:12 启动 Explain 却仍发送第四章末页 101 字旧来源。真实截图显示字幕与第一章不相干、标注绘制在空白处。这是 P0 失败，**当前候选不交付**。证据 `/tmp/castreader-pagination-live32-reader.log` 与用户 21:15 截图。
- 根因：原生翻页 pendingTarget 在试读墙后未释放；目录意图只停止当时播放的 VM，没有撤销两种模式保留的旧来源。目录超时还可能恢复旧音频。33/34 轮新增显式 navigation reset 和两模式来源撤销；34 轮新回归进一步暴露 Explain 会忽略超时后的新页，35 轮继续补恢复路径。未以保护性停止代替功能验收。

- 35 轮目录来源专项 2 项真机通过；镜像依次执行第四章末页 → 试读结束 → 目录第一章 → Explain → 自动下一页 → 目录第二章，第一章字幕讲述观察人性/转述往事，标注覆盖对应原文，第二章标注也对应当前内容。此前空白处的旧章节标注不再出现。此为特定场景通过，不等于长测或全部模式通过。
- Kindle 35 轮真书首次播放于 21:24:10 触发位置冲突弹窗（local 2733/cloud 2731），句子流旧页 raster 遮住弹窗，工具条却等待用户确认，无法继续。36 轮将停止翻页时的句子流/视觉预取一起撤销，并让原生确认弹窗优先显示；真机复验待进行。
- 36 轮同时修复 WeRead 手动目录跳转仍自动重启 Explain 的行为。新增生成中跳章的迟到回包取消测试。
- 历史 Node WeRead 合约脚本因旧 SSR 字符串、旧 UI 布局、旧 TTS 方法名及 drawImage 推测下一页断言而已不适配当前源码。保留原始失败日志，改为验证平衡 SSR 解析、不执行尾部代码、原生邻页身份、生成者队列收尾等当前行为；`/tmp/castreader-weread-contract-47-20260929.log` 已通过。没有为使测试通过改变生产排序规则。

- 36 轮 Kindle sync/navigation 18 项回归通过。新增 WeRead 生成中目录取消测试失败：QuickReadService 将 URLError.cancelled 当成可重试网络异常，try? sleep 又吞掉任务取消，重复发送旧请求。37 轮在重试前/失败后检查取消、退避 sleep 传播取消，排除 cancelled 重试。37 轮 5 项专项全部通过，包含导航取消、来源阻断恢复、401 同线路刷新与普通网络失败回归。


### 21:36–21:44：Kindle 真书切模式错页

- 37 轮真书《A Journey to the Centre of the Earth》朗读实际 rate=1.50，镜像观察到自动翻页及对应单词高亮。原生同步弹窗本轮未再次出现，因此尚不能将 36 轮弹窗可见性修改记作真书复验通过。
- 21:38:49 从正在朗读的 held 页切到 Explain，日志来源 key=4f6d47d6bc7f，实际 WebView 可见 key=4e7b562f8081；旧页的讲解与 OCR 坐标被绑定到下一张图片。镜像标注落点与字幕不一致，P0 失败。证据 `/tmp/castreader-kindlelive37-failure.log`；不能把之后自动换页自愈作为修复。
- 根因：句子源预取在旧页 raster 下已执行原生 Next；切模式移除 raster 并取消句子流，却直接使用旧页 snapshot 重建 VM，没有恢复原生可见页、没有重装对应 overlay。
- 38 轮在停止旧 owner 后等待在途原生动作退出，最多撤销本会话三次前向预取，要求精确原生页身份及稳定几何，安装同源 overlay 后才启动新模式。暂停后切模式也恢复可见页但不自动播放；不是本会话预取造成的陌生页禁止通过回退猜测。增加真实 WK 原生 renderer 的恢复与拒绝错页回归，结果待补。

- 38/39 轮新用例分别因缺少 mounted-surface 通知、夹具使用 previous 而非真实原生 PreviousPage 参数失败；未放宽生产确认条件。40 轮物理 iPhone 18 项全部通过，`/tmp/CastReaderPagination-mode-source40-20260929.xcresult`。40 轮 app 源码与 39 相同，仅修正测试夹具；随后用同包继续镜像真书复验。

- 40 轮镜像恢复正确旧页后，overlay 因旧 capture session 被拒绝，`stale-session`；此次为功能失败。41 轮恢复后重新锁定当前页并更新 session，新增实际 overlay 安装断言，18 项真机回归通过。
- 41 轮真书 21:57:44 Read→Explain：source-confirmed、playback start 与 explain geometry 均为 key=2cb84c581061。随后 21:58:14/21:58:27 自动解读分别提交 8d9b746ba9c9/947b26375e1f；镜像字幕、圈线与原文相符。21:59 暂停后切 Read 保持同页且未自动播放。证据 `/tmp/castreader-kindlelive41.log`。这是故障定点通过，不替代最终构建长测。
- Google 真书 Moody's Addresses 在封面停留后于 21:54:32 被空正文 watchdog 判成无法打开，出现 Sign In Again。封面仍正常显示，当前证据不支持账号已失效；作为新的入口缺陷继续定位。证据 `/tmp/castreader-pagination-live40-reader.log`。


### 22:12–22:18：Google 实书与审计重新对照

- 用户重新指定主指南、执行模板、审计 validation，三份全文已重新核对。主指南 C01–C23、K01–K12、W01–W09、G01–G14、O01–O10、Q01–Q10、R01–R08、T01–T17 都继续适用；不存在“扩展全部完成，因此直接算 iOS 通过”的结论。当前是 iOS 自有 WKWebView，Android 和第三方原生 App 不属于本次已验证载体。
- 42 轮 Google WK 40 个用例：38 通过、1 跳过、1 新封面用例失败（3 个断言）。图片首屏仍等待 15 秒，43 轮补启动检测；43 轮同一套 40 用例为 39 通过、1 既有网络用例跳过。
- 43 轮真实 Moody’s Addresses：22:13:42 首次 playing actual rate=1.50；22:14:07.519 visual request → 07.609 hold → 08.259 页提交 → 08.324 release → 08.413 playing。分别为原生提交约 740 ms、同片段暂停到恢复约 804 ms，性能失败；不能拿 65 ms 提交后交接代替总等待。镜像词高亮跟随正文，随后 Read→Explain，自动翻页标注实际覆盖对应印刷文本。此为功能定点观察，尚无完整覆盖账本/长测/声学 A/B。
- 43 轮仍未识别真书封面。44 轮临时结构诊断证明实际为 native shown + loaded 下的 SVG image，非 HTML img；45 轮补此结构，且手动从正文回封面撤销两种模式的旧来源。临时结构探针已删除，45 轮构建通过、专项测试进行中。
- 44 轮重开 Google 保存页时出现“内容已改变，无法精确恢复”提示；保留为续读待定位项，未把安全拒绝恢复记成完成。
- 未关闭重点：R01 Kobo 真书几何/源覆盖、R02 解读首段媒体+同 producer 接管、R03 跨章准备、R04 慢请求及所有等待归因、R05 性能、R06 最终构建长测、R07 分阶段取消实际延迟、C21/G13 关闭末段、C22/G14 完成画面、私人克隆 source cue 缺失。

### 22:27–22:38 真机 iteration 47：Google 封面关闭，连续朗读仍失败

- 图像封面留在当前页超过 60 秒，无登录错误；原生下一页可离开封面，目录进入正文后由用户动作启动朗读。此前 SVG 封面空文本误报登录失效已完成定点复验。
- 同一实际书籍从 22:31:08 连续朗读，前四个自动边界的日志 hold→playing 分别为 99 / 258 / 252 / 256 ms。99 ms 的观测器回调晚于实际媒体截止，不能充当真实额外停顿上限。其余三项已超过 max 200 ms，判失败。
- 第五次自动翻页在 22:33:37.226 提交新页，37.295 释放朗读会话；镜像留在 13/177 且按钮变为重试。确认路径在缺少已绘制锚点时停止，尚需记录 source range 与 DOM 映射根因。此测试到此结束，不计最终连续长测。
- 日志：`/tmp/castreader-pagination-live47-reader.log`；控制台 `/tmp/castreader-pagination-live47.log`。
- iteration 48 仅编译成功，未安装；其解释媒体租约按内容 key 计数存在旧 payload 可能清理新同字节资源的问题，49 改为精确资源实例，并补账号边界强制释放测试。49 测试中，不能标为通过。

### 22:41–23:02 真机 iteration49/50 与 Kobo 实书

- 49 的 PaginationContinuity / SpeechPipeline 共74项通过；50 的 PaginationContinuity / GoogleBooksWebBridge 共90项中89通过、1原有网络跳过。新增精确媒体实例租约、账号边界释放、迟到时钟不倒退、首个锚点暂未绘制仍保持等待的生产桥回归通过。
- Google49 从原失败页继续跨越至少6个边界，未重现立刻停止；时序竞争仍由50新增测试验证，最终性能未通过。
- Kobo50《Falls From Grace》真实朗读跨页，当前词高亮可见；切 Explain 后原文标注位置定点正确。一次 carry hold→release 335ms，仍超标，不能填最终通过。
- 连续 Explain 至少5次切页，全部预取 hit=N，重新调用 plan，prevSummaryChars=0：这是尚未关闭的连续性问题。原始 layout trace 显示 clip宽430、column宽380、gap50，预取却使用430+50步长，导致下一页截取范围不等于真实页面。53修正为380+50，并增加真实WK列布局预测/实际下一页范围对比；尚待运行结果与实书复验。
- 23:00:26.008 手动下一页，26.012 释放 Explain 会话并清除旧标注，26.952 提交新页；23:02 镜像保持空闲、无旧字幕/标注，无新播放日志。超过60秒未复活（不是全部五阶段取消矩阵）。
- 51、52仅编译，未分别安装。53组合候选加入同一 plan producer 在block0就绪后先准备媒体、done晚到更新权威块数、取消隔离；首个PreparedBlock内部仍完整收集，不可据此宣称Q02全部关闭。
- 证据 `/tmp/castreader-pagination-live50-reader.log`、`/tmp/castreader-pagination-live50.log`。

## 2026-09-29 23:18 — iteration 53 Kobo 真书连续解读

- 真机 Falls From Grace，1.5×，23:11:21 首声后自动推进到 23:17:47；21 次自动页提交，15 次具备可消费 payload 的翻页全部 `hit=Y`，其余路径包含章界、短标题页和未及时准备的冷路径。不是 30 分钟/三完整章节最终长测。
- 同一 `qrc_` job 在新页接管；首媒体 `decoded=true`，播放器使用预备资源，未重新写入首音频。正文手写标注截图观察匹配当前可见文字；这不替代全程语义审核。
- 第一页结束 23:11:32.094 → 原生新页提交 32.422（328 ms）→ 实际 playing 32.537（另 115 ms，总 443 ms）。原生动画、播放器附加等待分别保留；尚未通过 warm P95 和音频 A/B 验收。
- 新发现：多块页面只预备 block0，后继 block1 在新页开始后才生成，23:13:00 后产生数秒块间等待；提前准备下一视觉页不能解决这个等待。iteration54 增加同 job 的一个有界后继块 producer，接管时不重复请求。
- 新发现：短标题页预取被最小文本长度拒绝，同一预测触发 23 条重复 noBlock0 记录；需避免重复预备不满足门槛的页面。
- `setActive` 已按页/模式变化发送，播放 tick 不再重复发指令。
- 原日志：`/tmp/castreader-pagination-live53.log`、`/tmp/castreader-pagination-live53-reader.log`，设备文件 `Documents/reader-pagination-20260929-230704.log`。

## 2026-09-29 23:18 — iteration 54 候选（测试中）

- 精确首块媒体之外，预取同 job 的一个后继块；准备结果及媒体租约跨页交给新 generation，普通 rolling window 负责更后的块。停止/换源取消原 producer。
- Google/Kobo 预取仍在进行时，将原任务转交已提交新页，避免丢弃半成品后重做计划。
- Explain 接管同时验证源段落 ID 与 UTF-16 范围；仅文本相同不再足够。
- manifest：`reports/ios-pagination-20260929/candidate-54.json`。构建成功，真机回归执行中；尚未真书复验。

### 23:26 iteration54/55 回归

- iteration54：148 项真机回归全部通过（GoogleBooksContract69 / Pagination48 / SpeechPipeline31）。
- iteration55：77 项真机测试，76 通过、1 项既有网络条件跳过。包括16秒慢请求保持同 producer、停止后取消、不发重复计划；Google生产WK桥43项包含该跳过。
- 将接管额外15秒计时取消，沿用原 producer 的请求/资源 deadline；短标题页在发起预取前校验，避免播放tick反复抛noBlock0。
- 新候选已装机；真实页复验、性能、克隆 cue 和最终矩阵仍未完成。

### 23:43 iteration55 真书复验与克隆时间戳根因

- WeRead《茶花女》第三章、My Voice 21 私人克隆，23:28:28–23:29:04 多段请求明确要求 source timing，但返回 cueCount=0；23:29:04.111 `source_cue_coverage_missing` 导致页边界前停止。1.5× 实际播放器 rate 已确认；此组合失败，预设音色结果不能替代。
- 只读检查美国现行服务：`castreader-clone` 仍使用原 consumer handler，`castreader-clone-alignment` 现行版本 `20260909-us-shared-v1` 的 `caption_pipeline.py` 也将 zh/ja/ko 放在 `SEGMENT_LANGUAGES`，`eligible` 只含字母语言。中文为空时间戳是当前服务端策略，不是 iOS 丢字段。未修改、重启或部署生产服务；后续修改必须遵循完整备份与隔离候选门禁。
- Kobo《Falls From Grace》、同一私人克隆、实际1.5×，23:38:12首声后至23:43测试者暂停。17次自动翻页，其中15次消费预备payload全部hit=Y；13次后继块准备、12次接管记录，同job无重做。原文标注镜像定点符合当前正文。见 `reports/ios-pagination-20260929/live55-kobo-explain.json`。
- 15次命中的原生请求→提交P95/max399ms，提交→playing P95/max195ms，前项结束→playing P95/max580ms。额外等待P95仍超100ms，不通过流畅度验收。这是约5分钟定点验证，不是30分钟/3章最终验收。
- 对Q02重新核对固定扩展源码：`PreparedQuickreadPage` 的ready要求 **first complete section** 解码，并非要求该section内部首个transport part即可播放。iOS已在首个完整block就绪后转交，并让同job后继继续供给；因此“等待block0内部完整音频与compose”本身不是Q02反例。剩余证据应聚焦首block不等整页、持续producer不重复、资源有界、取消与真书等待，不能凭术语不一致增加未经依据的拆句。

### 23:48 iteration56/57 媒体交接回归失败

- 56移除每段重复AVAudioSession激活、已解码媒体的重复静音切换，并同步处理已ready媒体。48项物理iPhone分页回归47通过、1失败。
- 原生结束通知在后继3秒音频的currentTime=0时到达，导致未读就发起下一次Next；57只加诊断，专项3次稳定复现。未放宽断言，候选不交付。
- 58在清理人工endpoint时仅对有效值写回invalid，检验是否是已经开始的decoder被无效重复边界写入扰动。仍待真机结果，不作修复结论。
- 证据：`/tmp/castreader-pagination-media56.log`、`/tmp/CastReaderPagination-media56-20260929.xcresult`、`/tmp/castreader-pagination-end57.log`、`/tmp/castreader-pagination-test57b-reader.log`。

## 2026-09-30 00:10：候选58–60后续核验（仍不交付）

- 候选58真实 iPhone PaginationContinuity48 + SpeechPipeline34 全部通过；整页自然结束用例另重复3/3通过。冗余写入 `forwardPlaybackEndTime = invalid` 的0秒结束问题未再出现。`candidate-58.json` 固定源码与二进制身份。
- 58 Kobo Explain 真书定点测到22次自动翻页，8次 Heart + 14次 My Voice21 分开统计。私人克隆14次均命中已解码首块；commit→playing P95/max130ms，native request→commit max382ms，ended→playing max512ms。保留Fade总等待，未达到warm P95≤100ms。没有声音A/B及最终30分钟证明。详见 `live58-kobo-explain.json`。
- 58切音色后，当前块已改为新声音，但旧缓存后继直到边界才重新TTS：00:00:14.655→00:00:17.902等待3247ms。作为新缺陷记录，不能用后面的预取命中覆盖。
- 59增加Kobo导航能力就绪查询；初始化期间不消耗恢复搜索次数，保持最新候选页和账号/书籍会话所有权。保存页先到达会取消等待，迟到ready不再翻页。45项真机WK桥接：44通过、1既有Google网络用例跳过；Kobo浏览器fixture通过。实际恢复另验：58搜索64页仍失败，59仅关闭过早尝试子问题，不声称整个恢复问题解决。
- 60正在编译音色切换后的后继缓冲修正：保留缓存讲解文本与原文marks，丢弃旧音色的未来媒体；当前块重建完/用户恢复后补齐有界后继。增加播放中切换、暂停后切换再恢复两项真实AVPlayer回归，尚待结果。
- 中文私人克隆服务端仍将zh/ja/ko归到segment-language，未调用当前Qwen对齐器。Qwen官方项目列有中文能力，但这不证明当前部署已满足源覆盖或延迟。已找到原始本地部署工作树 `Documents/.worktrees/CastReader-clone-alignment-20260908`（有未提交工作，仅只读），以及共享服务包装源；尚未修改、重启或发布生产对齐服务。

## 2026-09-30 00:24 迭代 60–62（不是最终验收）

- 60：真机 SpeechPipeline 36/36 通过；换音色后提前重建下一块，暂停时不提前出声，恢复后补齐预取。仍须真实书籍验证。
- 61：真机 WK bridge 45 通过、1 项既有网络跳过；Kobo 页切换期间刷新不再并发发起第二次定位。但真实 Kobo 仍耗尽 64 次搜索，未恢复远处保存位置，缺陷继续开放。
- 62：真机 SpeechPipeline 36/36 通过；整页摘要按文档、来源指纹和 job 绑定，停止及来源变化后失效。章界与冷路径衔接未关闭。证据见 candidate-62.json。
- 最终构建未冻结；八组合长测、中文私人克隆真实时间戳、音频 A/B 和 warm 延迟验收均未完成。

## 2026-09-30 00:49 迭代 63–64：当前页音频优先

- 62 真书切换到私人克隆后，虽然提前重建后继块，下一页 speculative TTS 仍抢占同一串行后台队列。当前页块间产生 3471 ms 等待；另一次经过过短页面后没有预取可接管，等待 10102 ms。两条保留为失败样本，见 live62-kobo-explain.json 及原始日志。
- 63 为每个未来页 TTS 子请求增加动态准入：当前页及其一个直接后继块完整可播后，才发起未来页的 speculative 请求；接管成当前 job 后提升为 readAhead，且不等待自己造成死锁。下一页 LLM plan 仍可提前进行。
- 63 的45项真机回归43通过、2失败，原因是两个测试的 compose 夹具返回了不符合真实接口的 JSON，引入重试等待。64 仅修复夹具为有效 section，未放宽时限或生产检查；45/45通过（SpeechPipeline37、调度器8）。系统诊断包收集报错，但测试套件及 xcodebuild 明确成功。
- candidate-64.json 固定本次源码与二进制。实书换音色、短页面冷路径、最终八组合长测仍待完成。

## 2026-09-30 01:07 迭代 64 实书与 65–66 媒体回归

- 64 Kobo 实书自动翻页18次（5次Heart、13次MyVoice21），均为首媒体已解码的预取命中；克隆 commit→playing P95/max160ms、原生 request→commit max410ms、ended→playing max571ms，仍未达到warm P95≤100ms。换音色后当前页后继提前完成，原来的3471ms等待未重现，但该块切换仍为224ms。见 live64-kobo-explain.json。
- 65 将当前页一个直接后继块的前两个媒体提前解码，并用精确实例租约跨 clearQueue 接管；不随全部文本缓存保留解码器。85项真机回归84通过、1失败：暂停后换音色时 clearQueue 清掉 pause intent，后继生成没有背压。新测试使用有效 compose 响应后暴露竞态，未修改断言。
- 66 在换音色开始与新音频入队两处保留 pause intent。40项真机回归通过（SpeechPipeline37、暂停/所有权/媒体租约3）。播放中与暂停后恢复两条测试均验证接管同一个已解码 AVPlayer；实书复验待完成。
- 新脚本 scripts/analyze-live-explain-turns.py 保留全部自动页提交，分开warm命中/冷路径/未出声短页。62旧统计漏计一张短页，现改为25次总提交（24次有后续声音、1次短页未出声），14次clone warm路径P95/max176ms，2次cold路径含10102ms总等待。失败样本未剔除。
- 64重开Kobo再次耗尽64次恢复搜索，界面提示未能精确恢复。该续读缺陷仍开放；后续手动启动不能抵消失败。

## 2026-09-30 08:22 迭代67–68：衔接调度与Kobo远处续读（待真机）

- 66 实书段间虽然复用精确已解码 AVPlayer，仍有129–210ms等待，其中完成回调到入队约41–100ms。67将同一MainActor上的完整且音色一致的缓存后继直接入队，去掉不必要Task调度；构建成功，未单独安装或验收。
- 66控制台留存01:09:33–03:25:29间475次整页完成回调，最后playing为03:25:26；01:13之后没有同步镜像观察，随后有系统中断及数据连接断开。这不能当作475次确认翻页、无干预长测、全书收尾或语义/音频验收。摘要见live66-console-retrospective.json，设备ReaderRunLog待导出。
- 68新增Kobo原生进度提示，与书UUID、实际朗读源结构指纹一起写入checkpoint。新页先呈现、旧音频后保存时仍保留旧页位置；相同来源对应不同位置时不猜测。重开先尝试一次原生定位，再以原有段落/上下文hash确认；布局变化、原生拒绝或超时后保留有界相邻页搜索，错书进度不能调用。原生进度不能直接授权出声。旧checkpoint不含该字段，继续保留原校验搜索能力，不能承诺旧记录均已远处恢复。
- 新增3项WK恢复用例（远处定位后仍需验源、拒绝回退、错书不跳转）及1项实际播放器保存旧页位置用例，等待物理iPhone执行。Kobo浏览器fixture已通过（含单页进度、双页拒绝、非法页数和书ID）。
- 首次编译因WebKit异步调用签名失败，改为async接口后构建成功；代码复核追加调用前、返回后及超时的会话/账号隔离，重新编译成功。第一次浏览器fixture失败是夹具已同步改变页面，却在30ms后仍断言“视觉离开前不能清高亮”；该子场景改为明确hold原生页面，再验证保留/手动取消，未放宽生产检查。
- 08:09时镜像超时、安装通道unavailable，未安装68。用户随后已连接并解锁，正在恢复通道；相关物理测试和真实书籍恢复仍为NOT_RUN，最终八组合矩阵保持未通过。

### 08:26 安装通道复核

- 用户已重新连接并解锁；镜像恢复，但devicectl仍为unavailable、ddiServicesAvailable=false、tunnelState=unavailable，USB总线未出现iPhone。Xcode真机测试返回找不到指定设备，0项执行；不是用模拟器补验，也不计为产品回归失败/通过。
- 候选68最终build-for-testing成功，Debug dylib UUID `09C975A8-2FEC-3089-8267-5D11AD266FB5`，source identity `418731024a125fe6783a28d479439de5f6c774663b7cad775b5dff10a1fc7aaf`，实际安装仍为66。新包包含67同步后继入队及68Kobo保存进度提示。
- 物理回归命令包含SpeechPipeline、GoogleBooksWebBridge、ReadingResume、PaginationContinuity；待设备数据通道恢复后执行，再做新保存checkpoint远处重开、换音色/暂停、实书边界时间与标注验收。

### 08:34 数据恢复、完整旧日志和68隔离复测

- 数据通道已恢复，08:28由Xcode安装68并开始真实iPhone回归。首批Kobo视口夹具initial rendered等待失败，随后OReilly视口用例挂起，193秒时中断；没有把它记为全绿。相同Kobo视口与4项新续读回归隔离复测5/5通过，播放器/暂停/语音管线另跑有超时保护的套件。
- 66设备ReaderRunLog已完整导出并重新统计：476次自动页提交（11 preset +465 clone）；clone中411次预解码命中，commit→playing P95 161ms / max192ms；另外52次可出声但未完全预备路径，最长commit→playing13011ms、ended→playing13366ms；2个短页未出声。不能只报告411次warm命中。详见live66-kobo-explain.json。
- 03:25:29最后页面结束后仍请求Next，03:25:34判定javascript-no-change，随后恢复旧页visual；这不是明确书末收尾通过。书末原生边界/零多余Next仍需修复验收。
- 01:13后的源/语义和声音未同步观察，虽有完整事件日志，仍不折算为最终构建长测。

### 2026-09-30 08:40 — candidate 68 真实设备核心回归

- 物理 iPhone 核心回归 175/175 通过：PaginationContinuity 48、ReadingResume 90、SpeechPipeline 37。测试 08:36 结束；Xcode 附加诊断收集失败不改变 XCTest 已完成结果，但其日志照常保留。
- 原 68b 批次的 Kobo 初始化失败与后续 OReilly 挂起没有被这轮结果覆盖。Kobo 同二进制隔离复测已通过；剩余 WebKit 批次待执行。
- 用户反馈屏幕持续闪动且不解读。刚才自动回归确会重复切页及重建队列，但尚不能据此排除正常流程缺陷；08:40 已退出测试并启动正常 app，准备镜像复现。镜像当前提示 iPhone in Use，等待锁屏。
- 证据：`/tmp/castreader-pagination-core68.log`、`/tmp/CastReaderPagination-core68-20260930.xcresult`；当前实际书籍日志 `/tmp/castreader-pagination-live68.log`。不计入最终八组合验收。

### 2026-09-30 09:41 — candidate 68 微信读书实际解读与 69 提前规划

- 正常 app 镜像实测《茶花女》：中文原文、英文 af_heart、实际 AVPlayer rate=1.50，13 次自动翻页，第三章进入第四章；截图观察中字幕与本页原文标注继续更新，没有持续闪动。此前用户反馈与自动回归时间相邻，不能据此断言只有测试导致。
- `live68b-weread-explain.json` 保留逐页记录：request→commit max125ms，commit→playing P95/max189ms，ended→playing max289ms。额外等待 P95 未达100ms标准。09:34:48发生系统音频 route removal/interruption，后续恢复原因未证实，不计无中断长测。
- 09:39:40左右手动暂停，09:41仍保持同页同字幕，设备日志没有新的playing/end/turn；已观察至少60秒未自行续播。
- 69将下一页规划的启动从“首音频入队后”提前到“本页权威plan完成”；只改变规划启动时机，当前页首块+后继音频仍优先。预取接管用文档ID+源指纹识别，避免接管后等待自身音频储备的死锁。待真机测试，不声称已改善实际冷路径或warm间隔。
- build69b因嵌套函数主actor标注失败，修正后69c、补充idle路径后69d编译通过。40项SpeechPipeline真机回归启动，最终八组合仍未验收。

### 2026-09-30 09:51 — candidate 69 physical regression result

Same binary, existing debug launch argument isolates unit host from restoration of a real reading window: 3 new regressions passed; then 116 selected tests: 115 passed, 1 opt-in live-network test skipped, zero failures. Suites: Speech 40, Kindle native 6, WeRead availability 22, Google/Kobo WK 48 including the skipped live-shell case. OReilly iPad viewport was excluded (not a target platform; earlier hang remains recorded). Original interrupted Speech69 failure is retained; this does not constitute live four-platform acceptance. Relaunched normal app for live observation.

### 2026-09-30 10:05 — real WeRead reopening failure / candidate 70

Candidate69 normal app reproduced 19 opening restore turns to trial wall, then a stale first-page commit at 09:52:44; returning via catalog to the same fourth-chapter first page was rejected, leaving Explain with no source. This is a real restoration defect, not merely test-host flashing. Raw log `/tmp/castreader-pagination-live69-reader.log`; candidate69 records SHA/failure. Candidate70 binds callbacks/deadlines to page revision+account, checks current visibility before fallback, covers intermediate search, and exposes native painted chapter offsets. Physical regression 114 tests: 113 pass, one new test fails at returning to identical page after blocking stale source (2 recorded assertions including timeout). Candidate71 additionally retires JS duplicate-page identity and binds native chapter URL/offset to heard source checkpoint, so later Explain/visible pages cannot pair their location with older Read audio. None of these results count as final platform acceptance.

### 2026-09-30 10:22 — candidate72 physical regression

Candidate71: 113/115 tests passed, two immediate-pause checkpoint cases failed (three assertions). Candidate72 snapshots actual owned AVPlayer progress before synchronous checkpoint flush. Its 203-test physical suite: 202 passed; all91 ReadingResume,40Speech,24WeRead passed. Pagination carry-pause-resume observed position0.3 unchanged after200ms in one test. Same binary three isolated repeats passed, but intermittent resume latency remains unresolved; original failure retained, test and thresholds unchanged. Source identity e5992dcc29361f99137bbaad54f1f1dee0d53aa129f53627d2bceb4a704a8f10. These are regression results, not final eight-combination live acceptance.

### 2026-09-30 10:26 — real opening regression and candidate73

Candidate72 actual opening failed before first source: at10:21:46 hidden cover + controls not mounted was classified unavailable, causing native paint evidence to be discarded. Body appeared but source stayed empty. Manual catalog fourth chapter restored source10:22:38; Explain then played10:24:29, next plan started10:24:25.673 before first audio; one real automatic turn and corresponding captions/marks observed before manual Pause10:25. This is limited recovery evidence, not an acceptance pass.

Candidate73 treats hidden-cover/no-controls as waiting, no longer treats extraction diagnostics as authoritative unavailability, and separates source retirement from navigation invalidation. Source identity2828ec72bd3218407f99f95a11cbbbef3846c2503619f064751965cee90de261, dylib1C46E215-1087-3358-9D58-1DBF2B745FA5. Initial test compile failed (attempted publisher of non-published property), corrected without changing assertions' intent; build73b succeeds. Added real WK initial unpainted body regression; timeout regression also verifies that retiring source does not clear native paint. Node contracts and diff whitespace pass; physical test in progress.

### 2026-09-30 10:40 — candidate73 exact resume split result; candidate74

Physical targeted73:26/26 passed. Real73 opening no longer retired native paint on pending controls. New checkpoint chapter restore passed after viewing a different chapter in Explain and restarting: fourth chapter paragraph3, audio resume0.238369896s, actual1.50×. Subsequent single-page offset check FAILED: saved native chapter6/offset1652, paragraph5,6.844797792s reopened at prior page. Page mismatch correctly prevented replay; precise continuation still failed.

Read-only analysis of public provider asset9.cab69770.js (no content API calls, no provider code executed): HorizontalReader.scrollTo uses changePage, which unconditionally floors odd page indexes to the prior even spread. Candidate74 waits for real paint and corrects only proven single-page odd-target/prior-even mismatch using exactly one semantic native Next. Native pointer/key/catalog intent cancels pending correction; disabled control is respected. Node fixture now reproduces provider flooring, verifies one odd correction/zero even correction/disabled control/manual cancellation. Build pending. Final acceptance remains false.

### 2026-09-30 10:53 — precise native restore and nonblocking Play

Candidate74 real odd-offset restore failed and remains recorded. Candidate75 preserved provider UID types and normalized glyph offsets; real saved chapter6/offset1652 matched after exactly one native correction10:49:01.429, paragraph5 resumed6.844797792s10:49:28.951; first progress6.889s, actual1.50×. Five automatic turns recorded through10:51:56, screenshots show single-sentence highlights. Not a final continuity pass: one carried sentence ended10:50:55.394 but following paragraph first played10:51:03.573 (8179ms); request began only after page commit and took11151ms. This cold failure is retained, not dismissed as server-only.

User reported the persistent resume banner and dead Play button. Candidate76 removes the banner from portrait/landscape controls; explicit Play can start the verified current paragraph when its historical cursor is unavailable. Automatic resume still requires matching source; unavailable/retired pages cannot speak. Physical ReadingResume94/94 passed, including four-provider fallback, retired-source rejection and damaged-checkpoint recovery. Live76 pending; final eight-platform/mode matrix remains unaccepted.

### 2026-09-30 11:08 — nonblocking recovery, prepared carry and split Latin words

76 Kobo real fallback displayed no resume banner and the first Play entered generation; that request failed404 because the chosen voice was a leftover fixture ID. A normal voice selection followed, with actual1.5× speech and matching visible word highlights. At10:58:07 the stream stopped with cross_page_coarse_cue at a page ending “illustra-”. Not accepted; user interaction and the error are retained in candidate76.

77 allows one adjacent WeRead preview earlier when current ready audio has a12s reserve or all remaining current-page audio is ready, while keeping queue release bound to the actual last paragraph and confirmed page identity. On carried-sentence commits, a source/voice-matched prepared successor is adopted instead of discarded and regenerated.76 physical tests passed, including exact reuse and wrong-voice rejection. No live77 evidence.

78 follows frozen extension Kindle/Kobo behavior for a single Latin word visibly spanning two adjacent pages: retain the first fragment until the actual whole-word end; use the following actual cue for the presentation window. No interpolated subword times. Multiword/CJK phrase cues, invalid whole-source coverage and a word spanning multiple page edges remain rejected. Also fixes explicit Retry after a validation failure retired the audio session.56 physical tests passed (Pagination53 + resume recovery3), including true AVPlayer continuation and actual failure→Retry. Real78 reproduction and final long tests pending.

### 2026-09-30 11:08–11:24 — extension parity, retained preparation and stale source identity

Frozen extension KoboContinuousReading keeps a continuous chapter/source/audio session. iOS still transfers page-local state; WebView equivalence alone does not prove architecture or acceptance parity.

Live78 Heart and Maya each crossed the original illustrations split-word boundary. Maya's following paragraph still waited about4.9s: the geometry-prepared successor was discarded at the carry commit. Continued live78 failed11:16:11: carry source184..<205 was compared with stale cue91..<98; anchor acknowledgement timed out11:16:18.915 and stopped. The11:17 pause tap happened after this stop. Earlier successful turns are not a final continuity pass.

Candidate79 adopts the verified Google/Kobo prepared successor through a carry commit and fences WeRead preview task cancellation by generation. Three physical production-bridge/player tests passed (`/tmp/CastReaderPagination-prepared79-20260930.xcresult`). A separately added regression then reproduced the live coordinate defect: different source units reuse transport id1-0; the old carry returned range{5,7} instead of{198,6}. Original failure: `/tmp/CastReaderPagination-stale-carry79-20260930.xcresult`.

Candidate80 retires the completed carry's source identity before another unit can reuse that transport id, retaining the successor producer and decoded buffer. Physical regression in progress; no live80 or final acceptance claim yet.

The reference guide changed on September30 to add Kindle K13–K16 response recovery requirements; current SHA7318a7b5c2c52ecc5e4e0ec164cb8120f0785fa715e7703fd4c9f76f77e264dd. Read the linked recovery report; cache admission, shared failure budget, pause/late-response behavior require explicit mobile checks. Earlier guide hashes remain historical evidence.

### 2026-09-30 11:25–11:48 — real Kobo/WeRead carry evidence and decoder-lifetime regression

Candidate80 physical Pagination55 + WeReadAvailability25 passed (80 total). Real Kobo Maya1.5× ran11:27:24–11:33:36:22 automatic turns,7 prepared carry adoptions, no observed cue/anchor rejection. It still fails performance: release-to-playing P95 176ms/max208ms; native request-to-commit P95 376ms/max381ms; held-media-to-playing P95 612ms/max694ms. These event-clock measurements are not an acoustic pass, and six minutes is not the required final long test. Raw evidence and cutoff: `reports/ios-pagination-20260929/live80-kobo-read-metrics.json`.

Candidate81 only adds Kobo transition diagnostics and audio-route latency. Three physical production-bridge tests passed. Real Kobo Heart1.5×11:36:10–11:38:34:7 held-turn samples,6 prepared carry adoptions, release-to-playing max192ms, total held-to-playing max599ms. First usable changed native source260–303ms, stable source300–336ms, validation6–9ms, extraction15–25ms. These timings do not prove animation alone accounts for the first300ms. Speaker outputLatency0.5ms and IO buffer10ms were reported. Original Kobo settings were retained; no silent switch to None.

Same candidate81 then ran real WeRead zf_0011.5×11:38:34–11:46:05:12 automatic native turns,8 prepared successor adoptions, no observed source/anchor failure. Release-to-playing P95/max183ms, held-to-playing P95/max391ms, so performance remains failed. `live81-weread-read-metrics.json` is separated from the preceding Kobo sample. Screenshots show the visible sentence highlighted; no acoustic/30min/full-chapter acceptance claim.

Read-ahead bytes were ready, but subsequent decoders repeatedly arrived as decoded=false: replacing paragraph N's queue discarded prepared paragraphs N+2 onward. New physical regression on the unchanged81 product reproduced all three assertions: third decoder lost when paragraph two starts, decoded readiness lost, a new player used at paragraph three. Failure retained in `/tmp/CastReaderPagination-decoder82-red-20260930.xcresult`. Candidate82 pins each read-ahead paragraph's exact media until it is consumed or cancelled; transferred decoders cannot be released by stale lease cleanup. Freed decoder slots are refilled in source order under the existing six-decoder cap. Physical regression is running; no live82 or final acceptance yet.

### 2026-09-30 11:50–11:58 — decoder regression passes; actual WeRead trial wall

Candidate82 physical63/63 passed (Pagination56 + ReadAloudContinuation7). Real WeRead at the fourth chapter's final page adopted all five prefetched paragraphs decoded=true. Adoption-to-playing event intervals median109ms/max115ms; preceding81 decoded=false samples79 had median190ms/max297ms. Different passages and unequal sample counts: diagnostic evidence, not paired acoustic A/B or proof of final performance.

At11:52:07 real native Next reached the provider's “试读结束” page. Current code waited4.2s then retired its source on confirmation timeout. This is not a successful chapter handoff. Read-only provider asset inspection confirmed `HorizontalReaderNeedPayPage` uses `.wr_horizontal_reader_needPay_container` and clickable `.wr_horizontal_reader_needPay_content_action` DIVs; the generic button-only gate detector missed that action. Candidate83 recognizes that visible component, its exact title and login/purchase action; it does not inspect or bypass unavailable content. Hidden templates and prose remain readable. Physical WeReadAvailability26/26 passed; live83 gate verification pending.

The Node contract initially failed because its historical assertion required adjacent preparation to wait for the final paragraph (changed in77). Updated it to check complete current TTS, active playback, a measured12s reserve/all-page-ready eligibility, and the separate final-paragraph-only queue-admission guard. Node contracts then passed. Original failure and later pass are separately retained in candidate83. All eight final platform/mode cells remain unaccepted.

### 2026-09-30 12:00–12:13 — real83 recovery and measured buffer-policy experiment

Real83 WeRead trial gate was identified11:59:39.770 after the last audio ended11:59:39.651; ownership was released11:59:39.777. No additional content access or forced Next was attempted. Catalog first-chapter selection restored a readable source12:00:12.310 without the persistent resume banner.

Read first-chapter sample12:00:40–12:02:58:3 automatic turns,2 prepared carry adoptions, later paragraphs and multipart tails decoded=true; release-to-playing max134ms, native commit max117ms, total hold max254ms. Explain12:05:31–12:07:28:2 automatic turns with prepared/decoded hits, commit-to-playing138/151ms, prior-end-to-playing248/258ms. Screenshots show marks on the corresponding visible prose. After explicit Pause, the same page/caption remained unchanged through12:12 (over60s) with no automatic revival. Separate reports: `live83-weread-read-metrics.json`, `live83b-weread-explain-metrics.json`. Neither is a full long test or acoustic acceptance.

Physical AVPlayer policy experiment on unchanged83 app:3 measured presentation resumes with default buffering policy70.8–79.0ms and3 with automatic waiting disabled67.9–72.9ms. Actual1.5× and held position were checked. This does not justify changing production buffering policy; the policy remains unchanged. WAV fixture results do not represent live MP3 listening. Evidence: `/tmp/CastReaderPagination-buffer-policy-20260930.xcresult`.

Candidate84 moves DEBUG diagnostic file appends off the playback/render executor to a serial utility queue, retains event-time timestamps, and reuses its formatter/file handle. No Release behavior or playback policy change. Build succeeded and installed; normal Google Play Books real-book Read began12:13:50. Final eight platform/mode cells remain unaccepted, with warm-gap and long-duration requirements still open.

### 2026-09-30 12:24–12:26 — Google real source and candidate85 paint handoff

Candidate84 actual Google Play Books Read (`Moody's Addresses`, af_heart, actual1.5×)12:13:30–12:23:55 cutoff:19 automatic source-page turns,17 prepared carry adoptions; no observed cue rejection/anchor timeout. Release-to-playing P95/max202ms, native request-to-commit max127ms, total hold max384ms. This10-minute sample fails the performance and final-duration requirements. Explain then completed4 automatic turns, all prepared/decoded hits, commit-to-playing max104ms and prior-end-to-playing max230ms. Screenshots show marks aligned with the displayed original English prose. Raw84 console/ReaderRunLog and separate Read/Explain reports retain both windows.

Detailed first-turn trace: native page committed12:14:32.999, but the host's subsequent init/highlight/confirmation round trip released audio only12:14:33.144. The page and cue did not share one paint receipt, causing an avoidable hold even after the correct page was already present.

Candidate85 sends the next actual source cue with its owned Kobo/Google turn. The adapter requires an exact unique source paragraph/range/text match, paints the corresponding visible intersection, and only acknowledges after paint with unchanged signature and extraction revision. Native still validates exact pending turn/hold identity and committed source. A source mismatch retains the ordinary host-confirmed path; no guessed timing or hidden-page playback. Also adds Kobo exact native last-page completion with zero extra Next; rounded100%, missing and invalid page indices do not prove book end. Browser Kobo fixture and compilation passed; physical bridge regressions pending. Source/binary identity: `reports/ios-pagination-20260929/candidate-85.json`.

### 2026-09-30 12:34 — paint contract and proven book-end drain

Candidate85 targeted run preserved7 passes/2 failed negative fixtures: they replaced the adapter method after CR had captured its original reference, so did not inject the intended bad cue. Correcting the fixture interception to CR.gbNextPage made both mismatch/transient cases pass without a product change. A separately corrected book-end regression then reproduced the real defect: exact native book end retired the turn but left the ended player's presentation hold/buffering active (three failed assertions in `/tmp/CastReaderPagination-end85-redb-20260930.xcresult`).

Candidate86 resolves this hold only when the real media item has drained and the hold is explicitly at item end; book-end evidence cannot complete unfinished audio. Physical iPhone targeted10/10 passed in `/tmp/CastReaderPagination-paint86-20260930.xcresult`, including atomic page/cue paint, mismatched source fallback, real book-end hold completion, decoder lifetime and cancellation ownership. Normal86 real-book tests are starting. Final acceptance remains false for every platform/mode; fixture success is not an acoustic or long-session pass.

### 2026-09-30 12:43 — real whole-page prefetch cancellation, candidate87

Real86 Play Books Read12:38:00–12:41:05 recorded four released holds (release-to-playing max144ms, native request-to-commit max232ms, total held-to-playing max301ms), three prepared carry adoptions and successful native page/cue receipts. A fifth, abandoned hold is explicitly excluded from those percentiles and separately FAILED: current page ended12:38:51.624, next page first played12:38:56.281 (4657ms). Do not report the released-only percentiles as covering the whole sample.

The log showed repeated foreground-first-audio cancellation of the same partly next-page producer on AVPlayer part transitions. The isolated bridge fixture initially passed because it omitted WebReaderView.updateUIView's repeated setActive calls. Adding the same host entry point to real WKWebView/AVPlayer events reproduced3 requests for one successor on unchanged86 (`/tmp/CastReaderPagination-preload86-redb-20260930.xcresult`). Candidate87 defers only NEW speculative producers while foreground media is unavailable; it retains admitted work, whose cancellation still belongs to source/voice/mode/manual-navigation ownership. The existing scheduler prioritizes foreground requests. Full physical PaginationContinuity regression is running. This issue is not attributed to the server or omitted as a cold-path exception.

Candidate87 full physical PaginationContinuity61/61 passed at12:45:43, including the new repeated-host-update regression (one successor request) and existing pause/late-owner, decoder retention, source timing, same-cue and book-end tests. Normal87 real-book verification starts12:46; no final acceptance claim.

### 2026-09-30 12:51 — same-page improvement and user phone break

Real87 same Google failure page now had all three successor parts ready12:47:09.503. Page end12:47:32.161→next playing12:47:32.395=234ms, versus86's4657ms regeneration gap. Three-turn cutoff12:48:45 release max139ms/native165ms/totalhold245ms remains short diagnostic evidence. Candidate88 extends exact atomic paint to whole-page prepared successors; build passed, physical tests pending.

Kindle87 real Read started around12:50 after retaining native location2832. Actual1.5× and matching word highlight observed, and an automatic page changed. User took phone away12:51 and requested resume in one hour. Playback was paused, mini-player confirmedPaused then closed; saved position retained. No full KindleRead or Explain pass claimed. Resume instructions in `reports/ios-pagination-20260929/resume-after-phone-break-20260930.md`.

### 2026-09-30 13:47–14:01 — Kindle revalidation and saved-tail regression

User resumed physical iPhone testing and asked to check the existing Kindle adaptation before changing it. Candidate87, preset Heart at actual1.5×, read13:47:29–13:52:12:8 automatic visible-page presentations and4 batches containing cross-page sentences. Screen observations showed word highlights on the current page. There were no source-failure events in this sample. Of29 item handoffs, the initial saved-tail resume took6211ms; the remaining28 had P95 148ms/max150ms. These are player event intervals, not acoustic silence, and the sample is shorter than final acceptance. Pause remained in effect for over60s.

Kindle Explain on87 then completed3 automatic page handoffs with prepared next-page audio/source. End-to-next-playing was2150/2524/1595ms, including1059–1984ms before semantic commit began. The existing final-ink drain and post-boundary page activation remain performance work; ready prefetch alone does not make this path seamless. Marks seen in the mirror were anchored to the displayed text. Pause remained effective for over60s. Manual Previous then Next returned to the same visible page, key976fc7c27475, using the prepared-next adoption path. Evidence: `live87b-kindle-read-metrics.json`, `live87b-kindle-explain-metrics.json`, and `live87b-kindle-source-events.log` under the report directory. No complete chapter/30-minute/acoustic pass is claimed.

The saved-tail gap was reproduced through real AVPlayer and controlled HTTP responses on the physical device: both new KindleContinuousInput tests failed before the fix because the restored final word entered the player before its successor was ready (`/tmp/CastReaderPagination-resume89-red-20260930.xcresult`). Candidate89 prepares a preset successor during saved-position regeneration, then uses the existing bounded startup gate when the verified restored suffix is under1.5s. It retains user pause and skips already-read source. BLOB ordering and sentence assembly are unchanged. Candidate89 includes88's whole-page opening cue paint; build passed and physical continuous-input/Pagination/ReadingResume regression is running. Final matrix remains unaccepted.

Candidate89 physical iPhone regression completed14:03:55:167/167 passed (KindleContinuousInput10, Pagination63, ReadingResume94), including both new saved-tail cases and88's whole-page cue paint cases. WeRead JavaScript contracts and diff whitespace checks passed. Normal89 real Kindle verification starts14:04; no final long-session or acoustic claim.

### 2026-09-30 14:14–14:25 — Kindle real Read and final-ink regression

Candidate89 real Kindle Read, Heart at actual1.5×,14:09:50–14:14:23.838:7 automatic page presentations,26 media handoffs P95 150ms/max152ms, no source failure. Early successor preparation ran concurrently with saved-position regeneration; first handoff95ms. This cursor had a longer remaining suffix, so it does not independently repeat the under1.5s gate or pair with the earlier6211ms sample. Details: `live89b-kindle-read-metrics.json`.

The existing final-ink drain was reproduced with physical AVPlayer: complete narration ended1706ms before navigation became allowed. Candidate90 fits the whole pen path into the authoritative fully generated audio tail at the actual playback rate, retaining its phase across renderer handoff and bounded natural duration when no authoritative tail exists. No BLOB order or source assembly change. Physical48/48 passed (SpeechPipeline41 and KindleMarkAnimationClock7), including1×,3×,pause/resume and stop. The three controlled audio-end-to-allowed-turn intervals were32.558/32.328/32.120ms. These isolate the ink gate; they do not include native page activation or prove real acoustic continuity. Candidate90 normal real-book Explain verification remains to be run. Identity and red/green bundles: `reports/ios-pagination-20260929/candidate-90.json`.

Candidate90 real Kindle Explain14:26:48–14:29:13 produced5 automatic page handoffs. End→navigation begin39–79ms; end→next playing571/546/581/721/580ms. Thus the final-ink excess was reduced, but full warm continuity still fails. Real mirror observations showed page-local marks on all sampled pages, with paused caption/page unchanged14:29–14:33. Source identities and individual timings: `live90-kindle-explain-metrics.json`. This is a short diagnostic interval, not final duration/acoustic acceptance. Candidate91 moves the existing exact-page stable check and OCR overlay installation under the prior-page hold, then requires a single-use native-object/session/anchor/geometry receipt and the unchanged native viewport before adoption. A mismatch keeps the original verification/recovery path. Physical regression pending.

Candidate91 physical targeted19/19 passed at14:39 (native page script9, mark clock7, final-ink/control3). Same-page reinstall, wrong/duplicate receipt, mounted page, capture-session, anchor replacement, layout change and removed overlay all reject stale prepared presentation. Integration ancestry gate and JavaScript syntax/diff checks passed. Normal91 launch14:39; real-book result pending.

### 2026-09-30 14:54 — candidate91 real-book and control counterexamples

Heart / actual1.5×, starting14:41:58: five automatic turns consumed matching one-use prepared-overlay receipts. Ended→playing358/378/373/397/530ms still fails the warm target. See `live91-kindle-explain-metrics.json`; these are application event clocks, not acoustic measurements.

The paused caption and page remained unchanged for seven minutes, including a mirror disconnect/reconnect. Foreground refocus nevertheless attempted to reinstall the old-page overlay on the intentionally prepared successor, repeatedly reporting `live-candidate-not-visible`. Paused Previous confirmed restoration of displayed8444f160ee3e then previous560d7849bb6b, but temporarily exposed the hidden successor and incorrectly restarted Explain. Record this as a control failure, not a pass. Evidence: `live91-kindle-controls.json` and `live91-kindle-controls-events.txt`.

Candidate92 keeps valid held-page presentation authoritative during foreground refocus, reuses Explain's paused manual-navigation intent, and excludes old-checkpoint restoration when creating a source-confirmed new page owner. Cold open and new-page progress persistence retain their existing behavior. Physical regression is running; final acceptance is still incomplete.

Candidate92 physical run after unlock:145/146 passed (native script9, ReadingResume95, Speech41/42). The new navigation test initially supplied one sentence to an entry requiring multiple units and failed before speech. Correcting that fixture exposed a separate production boundary: explicit Resume could temporarily be treated as paused navigation while AVPlayer reported waiting. Candidate93 preserves the owned transport request in planning/streaming, while explicit Pause and natural completed pages remain distinct. Speech and navigation regression is running. Both failed attempts remain recorded in candidate92's manifest; no all-green claim is made for92.

Candidate93 physical SpeechPipeline42 + KindleNavigationPosition7 passed49/49 at15:15:08. The new case checks active playback, explicit Pause, a delayed paused observation, immediate Resume intent while the decoder waits, and actual resumed playback. Candidate92's95 passing resume tests also cover choosing a confirmed new source without deleting prior history and restoring its newly persisted progress on cold reopen. Source identity `928fae1cb5b640dcab29661d4498c3643e001b2fc2ada5e8ef138267f373e42b`; app UUID `AD0012FC-AC02-338F-BD82-95FC39F35AD9`. Normal93 started15:15; mirror initially requires locking the phone after test execution. No real-book93 latency/control pass yet.

### 2026-09-30 15:23–15:28 — background snapshot counterexample

Candidate93 real Kindle Explain used Heart at actual1.5×. Its first warm page transition was317ms end→playing, with an exact staged overlay and decoded successor; this remains above the warm target. Pause on page372bed128413 retained its caption and marks. Sending the phone to Home then returning through the app switcher exposed a new failure: while inactive, SwiftUI reported a transient814×297 landscape surface, triggering `layout-orientation-pending`, cancelling the held page and stopping its owner. The reader returned showing the hidden successor48e0f3649a15. No unintended audio restart was observed, but the wrong visible position makes this FAIL. Evidence: `live93-kindle-controls.json` and `live93-kindle-events.log`. Paused manual navigation was not credited after this failure.

Candidate94 preserves the actual native viewport while inactive and rejects inactive layout repair/restart. The foreground path releases that snapshot so genuine rotation/reflow remains available. Build passed; physical viewport/settings/native-source regression is running. Final eight-combination acceptance remains incomplete.

Candidate94 physical regression passed45/45 (native source9, viewport/settings35, real paused transport1). Real Kindle Heart1.5× then retained the paused original page, caption and marks across Home/app-switcher foreground recovery. The inactive transient orientation callbacks were rejected without stopping the old owner. Paused Previous restored the displayed page and confirmed the actual previous page, then remained paused69s before Next; Next returned to the original page and remained paused in a later screenshot. However Previous exposed the hidden successor during its roughly0.8s navigation, so visual continuity still failed. Candidate95 retains an identity-scoped displayed-page raster across this manual transaction while stopping audio immediately; release occurs after target confirmation or termination. Build passed; targeted physical navigation regression and real visual recheck remain pending. Evidence: `live94-kindle-controls.json` and `live94-kindle-events.log`.

Candidate95 physical17/17 passed (native source9, navigation7, paused transport1). Its normal app started15:34:43, UUID `C086F16A-4272-3FAD-A8D9-C59CE9E257F7`, source identity `f204e8fcb93a960424e252409bcfcde5490e9917e53201fd628726d7f79f85ab`. Real manual Previous retained the raster from15:36:07.670 until15:36:08.531, after the correct target was confirmed15:36:08.518. The sampled final screen showed the actual previous page. This was active navigation: an audio interruption at15:36:00 had changed transport state, so the attempted Pause click resumed it before Previous. Do not credit the paused variant or full-frame visual proof. Mirroring subsequently showed `iPhone in Use`, still present15:38; user input requested to lock the phone. Current real-book verification remains unfinished. See `live95-kindle-controls.json`.

### 2026-09-30 16:05–16:18 — resumed physical acceptance

Same candidate95 resumed in the normal application with live Amazon Kindle, Heart, actual1.5×. Seven uninterrupted automatic Explain transitions before the explicit Pause measured291/341/324/350/365/366/382ms from prior audio ended to next playing. These remain over budget; this is application timing, not acoustic recording. Paused Previous at16:11:53.856 retained the original raster while restoring native index7 and confirming index6; Next at16:12:31.416 returned to the original key1f60fdc50f9c. Play remained visible for over60s after Next. Explicit Play subsequently restarted the returned page and continued automatically. Sampled screenshots show the intended controls and final pages, but do not establish every intervening frame. Evidence: `live95b-kindle-controls.json` / `live95b-kindle-events.log`.

Candidate96 replaces the fixed80ms after native hold removal with a fence tied to the exact SwiftUI hold's dismantle plus a subsequent displayed frame. Missing removal, stale IDs, cancellation and changed navigation ownership cannot authorize playback; a bounded timeout retains an explicit failure. Page identity/geometry receipts still precede release. Build passed; physical mounted-view/removal/cancellation and native-source/navigation regression is running. No candidate96 live-book pass or final four-platform pass yet.

Candidate96 physical27/27 passed: mounted-view/removal/ink11, native-source9, navigation7. Normal live Kindle Explain then completed10 automatic transitions,211–366ms ended→playing; native removal waits were28–39ms in the first six samples. A system interruption at16:22:06.882 and explicit resume separate the run; this is not continuous long-run evidence. Explain→Read request at16:27:42.839 restored the held source and started Read16:27:43.421. Earlier UI clicks had no captured app receipt and remain unclassified, not attributed to a proven hit-testing defect. Subsequent Read showed10 segment handoffs109–169ms and sampled word highlights on the correct visible text. Both modes still miss the strict warm P95 target. See `live96-kindle-turns.json` / `live96-kindle-events.log`.

Candidate97 computes the prepared Explain tail from the current decoder position instead of the last UI tick and adds boundary/ink-drain timing diagnostics. Physical17/17 passed (clock/fence11, real speech/ink/pause6), including a deliberately stale UI timestamp that must not extend the narration remainder. Normal application live verification is starting; no final acceptance claim.


### 2026-09-30 16:50，candidate97 真实末页与性能采样（未通过）

- 同一正常真机进程 37121 从16:32开始 Kindle Explain / Heart /实际1.5×。24次未进入末页重复窗口、未覆盖采样的应用事件间隔 P95=379ms，仍未达到目标。不能把其后重复页计为成功自动翻页。
- 16:43与16:45镜像均显示同一 End of the Voyage Extraordinaire 末页，但原生 cache index / key不断递增并生成新解读；记录为真实重复缺陷。16:47:45通过 devicectl终止该测试进程。其间Pause/Back镜像点击未捕获到应用回执，控件可用性仍需复验。
- Time Profiler 16:38:03.395–16:38:44.906（41.511秒）中，主线程Running采样约40.44秒；HomeView.body占约14.734秒、continueRecords约14.026秒（包含计时不可相加）。KindleRunLog仅37ms，原生手写hold仅5ms。直接证据定位到被覆盖首页仍计算完整ContentCatalog、恢复位置fingerprint和文件状态；不能把日志写入或手写路径宣称为主要瓶颈。采样区间不参与普通播放时延验收。
- 原始trace：`/tmp/CastReader-kindlelive97-profiler.trace`。摘要：`reports/ios-pagination-20260929/live97-profile-summary.json`；时间线：`live97-kindle-turns.json`、`live97-kindle-events.log`。
- candidate98只编译，尚未装机即被上述发现取代，未计为测试通过。

### candidate99 修复与回归执行中

- HomeView的活跃条件补齐Kindle覆盖态；隐藏首页不构建继续听目录。可见首页一次取得目录条目及位置标签，去掉重复扫描。
- Kindle原生页序增加startPositionId/endPositionId范围：相同原文范围的相邻cache槽不预取、不再次派发；迟到的重复原文不能只凭index确认。无原生末页进度证据时不将其宣称整书完成，但不再自动重播同一来源。
- 新增重复范围、迟到重复、同像素不同原生位置三条实际WKWebView回归。首次回归暴露旧夹具所有彩色页都使用1–20相同位置，导致既有下一页用例失败；夹具改为真实不同页范围，重复反例显式设置同范围。保留首次失败结果，正在重跑。
- 四平台最终验收仍未完成。


### 2026-09-30 17:03，candidate99真机复测与candidate100

- candidate99回归25/25通过（`/tmp/CastReaderPagination-native99b-20260930.xcresult`）；正常App UUID `5EBDD861-3D6E-3537-A29C-DF0668260E18`，source identity `eaac5b55c58d4f74282884a594f7fa5dcd7c9c8f18af5ea57655a27191628293`。
- 真书末页Explain于16:55:09.187明确记录native-source-unchanged并停止；到16:56:21手动切模式前无再次生成/播放，超过60秒。末页手写标注随hold移除而消失，candidate100改为保留同一已完成页的raster/ink，仍待复验。Read末页只做短观察，不计完整收尾验收。
- 镜像没有点击回执的问题，通过窗口AX Raise后点击恢复；目录和模式切换随后有实证。先前无回执点击不作为app控件故障定论。
- candidate99性能采样16:58:03.267–16:58:44.474：41.207秒内主线程运行采样24.231秒，HomeView.body579ms；相较97的40.44秒/14.734秒有改善。采样后普通Explain页间ended→playing为192/201/208ms，仍未达P95≤100ms。
- 17:00:18捕获第六次自动接管中止，日志abandoned-context-change，未有用户操作或新音频。保留为阻断缺陷，candidate100增加上下文归属、取消、窗口和旧VM状态详情；不能将五次自动成功称为最终通过。
- candidate100进一步移除MainTabView对AudioPlayerService全量objectWillChange订阅（此前只是评分提示门禁用到一个布尔状态，却被每次currentTime唤醒重建整棵根视图）。改为四个播放/缓冲状态合成且去重的reviewQuiescencePublisher，评分实际触发仍重读当前状态并经过原有2秒稳定门。新增100次媒体tick零根通知、缓冲/播放变化正确阻断的回归。构建通过，真机回归执行中。

### 2026-09-30 17:08–17:20，candidate100正常播放与candidate101待真机回归

- candidate100的真机回归26/26通过，正常进程37248、UUID `9A0D6557-1BB0-379C-9FB2-87B8C32D76EA`。Kindle / Heart /实际1.5×从17:08:27开始播放，到17:15:28共16次自动Explain交接，采集窗口未再出现candidate99的abandoned-context-change；尚不能据此关闭未知中止根因，也未补足三章/30分钟验收。
- Time Profiler17:08:50.673–17:09:31.868共41.195秒，主线程运行采样5977ms，HomeView13ms、MainTabView2ms。较99同长度样本的24231ms显著减少；两次采样场景不是相同原文的严格A/B。采样期间两次交接从常规时延统计排除。
- 其余14次交接：13次已提前准备页面为159–185ms，另一次未提前准备页面442ms；全部14次的P95/max均442ms。前者仍超过warm P95≤100ms，后者单独保留，不隐去。442ms路径有真实原生转页及两次稳定几何确认，没有错误声称为纯TTS网络延迟。这些均为应用事件间隔，不是声学静音测量。
- 镜像抽样中的原文/解读标注一致，后续17:15:37之后未再有播放推进日志。Pause点击和测试安装/设备断连时间相邻，本轮不将其记为独立完整60秒控制验收。candidate100末页标注保留尚未真书复验。
- 采样还显示未激活ReadAloudViewModel收到共享播放器paused事件时仍调用全目录进度投影。candidate101仅增加当前队列所有权守卫；显式暂停、切换模式在释放队列前保存的路径保持。新增不同真实播放器owner的历史零投影回归，并准备复测实际暂停/恢复保存。
- 未修复应用+新增测试的首次真机运行在安装阶段失败：IXRemoteErrorDomain6、Connection interrupted；零断言执行，不能写成红测已复现。原应用与测试已保存至`/tmp/CastReaderPagination-inactive101-red-products`，可通过`/tmp/castreader-pagination-inactive101-red.xctestrun`重跑。修复包101使用generic iOS目标完成编译，但尚未安装/执行回归。
- 当前Xcode为unavailable，镜像重连结果为iPhone Not Found，已请求恢复连接。证据：`live100-profile-summary.json`、`live100-kindle-turns.json`、`live100-kindle-events.log`、`candidate-101.json`。四平台八组合最终状态仍未通过。

### 2026-09-30 17:39–17:49，恢复连接后的101真机结果与102回归

- 用户恢复连接后，使用保留的未修复应用运行新回归，真实复现4次历史投影（期望0），结果`/tmp/CastReaderPagination-inactive101-redb-20260930.xcresult`。这与前一次安装失败分别记录。随后101真机96项ReadingResume及3项SpeechPipeline通过99/99；正常应用17:41:07启动，进程37446。
- Kindle实际Heart/1.5× Explain从17:42:19开始。保守排除17:45:45以后的所有控制窗口，前7次自动交接P95/max128ms（整数毫秒重算，临时统计脚本倍率错误已纠正），仍未达到100ms目标。逐事件记录见`live101-kindle-turns.json`，原始ReaderRunLog与本次launch的Kindle日志已压缩冻结。
- 暂停控制的指针一直遮住按钮，之前反复点击不能据此断言没有输入回执。将指针移到Mac标题栏后，17:47镜像明确为Play图标；到17:49再次观察，同一原文、字幕“Because these ducks nest on low,”及标注保持不变，超过60秒未自行续播。此为抽样画面与日志验证，不是每帧或精确点击响应时延证明。
- 102仅对已有staged回执且viewport、origin和reader状态一致的交接跳过重复脚本安装与页面锁定。仍重新观察当前native key，并消费精确的一次性页/锚点/几何回执；回执增加pageModeLocked检查，任何失败执行完整setup/recapture。新增解读transport请求/应用结果日志，后续不靠被指针遮挡的图标推断点击结果。脚本版本49，build102b通过，真机native/navigation/ink/control回归执行中。

### 2026-09-30 17:50–18:02，102真机结果及103增量

- 102原生页/导航/标注/控制33项真机回归全部通过。正常包17:50:24启动，UUID `BD8369AF-ECA0-3435-8E1D-A778F33B26B5`。Kindle Heart/1.5× Explain首声17:54:24.779，首声实际速率1.50。
- 到18:00:32暂停前共12次自动翻页。17:56:54.504–17:57:36.528为Time Profiler采样，排除其中1次；其余11次102–166ms，P95/max166ms，仍未达warm P95目标。应用事件时间差不能替代声学录音。无未解释abandoned事件出现在该段日志，但不能据此关闭99的历史故障。
- 用户使用手机期间17:56:41.380音频路由移除、17:56:41.859系统打断，17:57:02.918明确点击恢复，17:57:02.960恢复playing。该控制段不计连续播放。此前/此后连续时长不能相加。
- 暂停18:00:32.368收到、18:00:32.369应用为false；镜像Play图标、页图与字幕保持，18:01:50导出日志未有复播。允许进行中的预取在18:00:35.945完成，不触发迟到播放。
- 103增量：自动Explain下一页接管不重复登记book opening；首次明确启动、手动导航、换模式保留登记。原实现每页同步写整书架/历史/Widget投影，在restart到媒体adopt之间重复执行，与自动翻页属于同一收听会话不符。103 build通过，正在真机验证，尚无103真书结果。
- 102证据：`live102-kindle-turns.json`、`live102-kindle-events.log`、压缩原始日志与`live102-profile-summary.json`；所有八组合仍未最终通过。

### 2026-09-30 18:04–18:26，103 Kindle 真机定点结果

- 103真机导航、暂停、末笔取消及历史回归11/11通过。前两次因设备锁屏未执行断言；第三次结果为`/tmp/CastReaderPagination-history103c-20260930.xcresult`，不将启动失败写成断言通过。正常包18:04:55启动，UUID `999F6845-3989-3095-9A1D-BCD0B6AF3D11`，source identity `08edea6550277ba7aedf28bf04aa0eba16915660b7f3acfa5a2048efab94fac2`。
- Kindle / Heart /实际1.5× Explain在切模式前完成5次自动交接：102、101、91、96、90ms，P95/max102ms。样本较102有改善，仍没有达到严格P95≤100ms，且不是声学录音或最终长测。所有原始交接保留在`live103-kindle-turns.json`。
- 切Read后原文自动呈现与逻辑音频保留有定点记录，未按最终20页/3章要求计通过。18:10的一次批量Pause+Next未捕获Pause回执，Next为resume=true；不能把它记为暂停导航通过或已证明的暂停故障。
- 独立Pause于18:11:20确认后，Previous18:11:29、Next18:11:37均resume=false，上一页/原页图片正确返回。18:19与18:24镜像仍显示原页和Play；日志没有迟到复播。18:19:20系统音频打断及后续Home/返回属于控制窗口，不计连续播放。
- 证据：`live103-reader-final.log.gz`、`live103-kindle-probe-session.log.gz`、`live103-kindle-events.log`。18:26转入WeRead同一正常包验收。四平台八组合最终状态仍未通过。

### 2026-09-30 18:26–18:43，103 WeRead 真实朗读和解读

- 正常包WeRead《茶花女》Read / `zf_001` /实际1.5×，18:26:41至18:37:48控制切模式前记录20次页面提交、19次同媒体视觉hold、140次自然片段接管。镜像抽样从第一章进入第二章与第三章，完整章数未建立源覆盖账本；这不是30分钟/3整章最终长测。
- 19次hold→release P95/max135ms、hold→playing175ms、commit→playing53ms；自然片段接管P95 83ms、max871ms。分别保留，不用其中最小的一项代表停顿。声学录音尚未完成。
- 两处停顿失败：18:29:31短开头的准备音频只有0.84s（1.5×约0.56s），后继正文翻页后才发请求，ended→playing486ms；18:37:15已消费整页的carry结束后，VM未允许提前准备下一章标题，随后前景重生成为871ms。未归因为网络故障；请求时序和准备合同缺口均有真实日志。
- Explain / Heart /实际1.5×，18:37:48启动后三次自动页面接管，request→commit最大74ms、commit→playing36ms、ended→playing110ms。三个均消费预取并接管已解码媒体。原文标注和字幕抽样一致，不能作为所有帧/所有语义标注通过证明。
- Explain暂停后Previous18:40:30、Next18:40:58均restart=N；旧字幕和标注清理，18:42镜像保持新页空闲且未续播，超过60秒。18:43镜像工具报告Mac锁屏，转Play Books尚未成功，已请求解锁Mac；没有把点击尝试计作Play Books验收。
- 证据：`live103-weread-read-timing.json`、`live103-weread-explain-timing.json`、`live103-weread-events.log`、`live103-weread-reader-final.log.gz`。103 WeRead流畅度仍未通过。

### candidate104 短段与carry边界修复，真机回归中

- 仅已有精确下一页预测且为预设音色、开头少于3秒时，额外准备至多两段已知正文，受20秒/4MiB总reserve约束；末尾跨页源仍由原来的整句producer负责。目标页确认后转交同一个待完成任务及已解码租约；未确认源、变更音色、手动导航和停止不会接管旧回包。未将此预设路径宣称为克隆音色已验。
- carry-only页面在仍有已确认真实音频且没有新的未读段落时，可以提前准备紧邻页；实际翻页仍由媒体边界触发，暂停禁止预取和接管。
- 新增实际媒体回归：完整消费carry时仍可准备但暂停禁止；短开头接管待完成后继只请求一次；停止后迟到producer不復播。104编译通过，UUID `FCE5CB19-1166-3ED5-964F-E02110064DB0`，source identity `0b1ea4126682d007ed0b27665410b840777fc5c78d2901501b582a5bcf2efc72`。真实书页复验和四平台最终验收均未完成。

### 2026-09-30 19:50–20:00，104c 失败与105播放器修复

- 104首次回归116/117通过，短开头后继接管失败；夹具的页内0-0标识未重编号。修正夹具后，104c仍为46/48通过：短开头接管、暂停恢复后接管两项失败。保留两个xcresult与日志，不将夹具调整视为根因已经关闭。
- 104c时间线中，上一段结束回调触发同步画面确认，确认内部已经切到下一音频项；外层旧结束回调仍将新项的`currentItemCompletionDelivered`置为true。新项真实结束后回调被丢弃，后继虽生成完成却不再推进。
- 105在`reachPresentationBoundary`返回后再次校验AVPlayerItem身份与回调会话。旧项无权设置新项结束标志。相同短开头接管、暂停恢复、停止隔离及carry-only准备四项真机测试4/4通过：`/tmp/CastReaderPagination-adjacent105-20260930.xcresult`。
- 105编译通过，UUID `0B5DFE67-A034-3EA0-AEF0-ABC7829A1BCC`，source identity `165d424268cde3c99b4aecf877a8808234b0f02bc67f44cb6b952344296ae931`。SpeechPipeline48与PaginationContinuity63完整真机回归111/111通过，零失败、零跳过：`/tmp/CastReaderPagination-full105-20260930.xcresult`。四平台最终验收仍未完成。

### 2026-09-30 20:07–21:13，105真实书页复验（未最终验收）

- WeRead Read：预设zf_046、实际1.5×。第一段约10分钟、15次自动提交，114次自然音频项衔接P95=80ms、最大83ms；起播冷等待13029ms单独保留。随后回到第二章末尾15字carry-only页，下一章音频在carry结束前1255ms已准备；页末到标题实际playing141ms，标题到后继正文82ms，两项未完成reserve由同一producer接管。后一区间8次自动提交、49次自然项衔接P95=82ms、最大84ms。未把两段拼成30分钟验收，未宣称三个完整章节或听觉零静音。第三章首页上一页请求20:19:36.810 unavailable仍需解释。
- 网络：Moody’s Addresses三次-1001导航超时，Kobo Falling for the Movie Star一次-1001。用户恢复手机网络后进入According to Promise，使用该真实书本继续测，保留前面的失败记录。
- Play Books Read：预设af_heart、实际1.5×，20:48:30–20:58:25保留15次自动提交，全部15个hold的恢复都计入。页末到下一页playing最大7652ms，提交到playing最大6988ms。多数页报告geometry-miss，只有一次完整预测/carry接管；问题未关闭。原分析脚本漏掉没有显式visual_release却重建播放器的等待，本轮修正后保留这些等待；页内segment ID可在翻页后重用，自然项衔接改以新stage判断。
- Play Books Explain：21:01:15–21:11:50共28次自动提交，23次预取且解码就绪，提交到playing最大33ms、页末到playing最大112ms；其余5次冷路径最大14981ms。镜像看到Chapter12及对应原文标注；未据此宣称章节完整覆盖。朗读和解读均暂停后前后页可正确切换、旧标注清理；解读末次导航继续观察迟到响应。
- 报告的raw_sha256对应各自指定gzip原始日志，分别为`live105-reader-through2059.log.gz`与`live105-reader-through2113.log.gz`。来源覆盖账本、每帧高亮、声音静音时长及完整最终矩阵仍是未完成门禁。
- 106为定位Play Books测量来源拒绝原因加入页编号/布局/锚点/切页结果元数据，只读诊断，不修改源准入与播放规则。编译通过，未将其记为性能修复或最终验收。
