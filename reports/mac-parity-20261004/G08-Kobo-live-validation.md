# G08 Kobo 实际验收

日期：2026-10-05。状态：IN_PROGRESS；不能把书架可见或短时播放视为长时 Read/Explain 通过。

## 已观察的实际流程

- 05:30–05:33：打开 Two Tickets 后官方会话恢复页出现 Cloudflare Verifying；未操作、破解或绕过验证。05:32:44 官方页面自行恢复 HTTP 200 和账号书架，05:32:57 取得会话材料，原阅读窗口正常重载。随后 Bella 1x 真实播放、词高亮可用。
- 暂停后使用官方目录进入 Chapter One，停留暂停，显示 13–14/348。
- 书架 5 本书；按作者 Ruby 搜索得到两本 Ruby Landers 的书，清空恢复 5 本。无结果查询原 UI 没有说明文字；已补本地化空结果提示，等待新包实测。
- Connect 弹窗 Close 曾缩为 Cl…；已限制按钮尺寸并移除 Catalyst 默认装饰，等待新包实测。

## 保留的失败证据

1. `g08-kobo-long-read`：窗口尺寸/界面切换后出现自动翻页无变化，05:39:03.948 `anchor_ack_timeout`。Retry Read Aloud 按钮无效，手动移到新页后仍不能恢复。该次不计长时通过。
2. `g08-kobo-mini-repro`：只收起阅读器的复演能持续自动翻页多分钟，并跨 Chapter One → Two；05:55:02.403 在 Chapter Two 页 43/348 超时。CastReader 下一页无变化，官方 Kobo 下一页立即到 Chapter Three 45–46/348。证明后台收起本身不是必然失效条件，并定位到双栏章节尾只有一页正文时的分页差异。

## 本轮修复与验证门禁

- Kobo 自动与手动翻页优先调用已经识别的官方 page button。无按钮的手机布局保留 UR exact progress / slider 路径；一次 turn 仍只执行一次动作，不在超时后补点。
- 翻页呈现超时后显示现有阅读器重试入口；经来源检查、非空且成功提交的页面才清除 Read/Explain 失效标记并恢复正文，恢复后保持暂停。空页不能解除失效状态。
- 新增同页和换页恢复 WKWebView 回归；旧源码下 Mac/iOS 各 2 项确实失败，红灯证据为 `g08-kobo-contracts/*-recovery-red.xcresult`。
- Kobo 原有合同：Mac 83 PASS、iOS 83 PASS，0 失败/跳过。新增恢复及共享桥接回归最终候选正在执行。
- JS 夹具新加桌面奇数章节尾和手动上一页，同时保留手机 UR 翻页检查；当前执行 PASS。
- 生成脚本因现有外部提取器/依赖产生大范围无关漂移，未将漂移带入交付。仅将经差异断言的 Kobo 模块更新到两份既有 bundle，变更各 12 行；记录 `g08-kobo-contracts/generated-module-verification.json`。不能宣称完整 bundle 构建已经可重现。

仍需：新包精确跨章复演、失败恢复可操作性、30 分钟 Read、15 分钟 Explain、字号/主题/窗口重排、重开位置、排序/重同步 UI、最终 Release。iOS 合同通过不代替这组实际 Mac 验收。

## 06:22 追加

- 新包（binary SHA `5904d9ae6a11c8e69a1093527a1e22898344ccf696eadf3913ed20b9c5fa4c28`）在相同第 43 页启动朗读，06:12:42.330 请求自动翻页，06:12:42.365 `method=button`，06:12:42.711 确认 Chapter Three 的 45–46 页，连续播放继续。精确失败点复演 PASS；长时门禁继续计时，目录 `g08-kobo-fixed-long-read`。
- 书架搜索无结果实际显示 No matching books；Title、Author、Recently read 排序操作正常。重新同步发现 5 本，实际完成 Synced 5 books。Close 在 470 点弹窗完整显示。整个过程后台音频继续。
- 重新同步后 Recently read 将未读书排到当前书前：现有 comparator 把新同步时间与阅读时间混排。已仅调整展示排序，已读优先、同组稳定排序；不改变同步数据合并逻辑，新增现有合同断言，待新包实测。
- Mac 最终第一轮：132 PASS、1 FAIL、1 SKIP；iOS 133 PASS、1 SKIP。唯一失败为 Google Books 位置消息 WKWebView 第二进程启动超过 3 秒，后续值相等断言并未失败；把事件等待上限改为 10 秒，等待重跑。SKIP 是原有可选真实 Google Books 网络测试，不计通过。
- 新包冷开观察到官方先展示 Chapter Three，旧 checkpoint 直接定位后却落到版权页，不能标记重开位置通过。还发现双栏 native location 被原代码拒绝，新的回归先失败（`spread-bookmark-red.log`），改为保存原生双栏首个页码后通过（`spread-bookmark-green.log`）。保存与翻页分开处理，错误范围仍拒绝，恢复仍需原文校验。真实新位置复测待进行。

## 07:02 追加

- Recently read 新排序已在真实首页复验，已读 Two Tickets 位于重新同步的未读书之前。搜索无结果、排序、Sync again 和完整 Close 均有实际 UI 证据。
- 新保存的位置冷启动恢复通过：93–94/348、Chapter Four，段落 1，保存音频 7.427550125 秒；重开保持暂停，明确点击 Play 后首个实际播放位置 7.451408376 秒。误差约 24 毫秒。证据 `g08-kobo-native-restore/`。这是原文匹配成功、同窗口恢复；不代表从错误官方位置直接定位或不同窗口恢复也已通过。
- 官方字号变化原来被识别成手动翻页，导致从新页第一段重读。新增 iframe 正文字体/行距/间距等样式变化检测并归类为 refresh；原用例红灯、新 bundle Mac/iOS 各 1 项通过；共享桥接 51 项分别 50 PASS、1 可选网络 SKIP。保留旧 bundle 非 Kobo 模块不变的校验。
- 重排发生在下一段首个音频返回前，原来没有恢复锚点。现保留正在生成的段落与播放意图；暂停后晚到音频不能擅自播放。原始两项用例 Mac/iOS 各失败，独立测试宿主还暴露 Auth 单例初始化循环，已让测试 setUp 先初始化 Auth。最终共享桥接、微信读书、恢复共 98 项在 Mac/iOS 均为 97 PASS、0 FAIL、1 可选网络 SKIP：`g08-kobo-contracts/*-integration-summary.json`。
- 06:47:47 缩小字号触发新失败：保留原来的 492 字符音频段落，但边界仍使用新页面较早句末，导致当前词源坐标不在新页 carry 区间，8 秒后 `anchor_ack_timeout`。`g08-kobo-final-long-read/result.json` 明确为 FAILED，未满足长读门禁。真实 Try Opening Again 能重新加载并保持暂停，明确 Play 后恢复朗读、词高亮和多次自动翻页。
- 新的端到端桥接回归在旧实现上 Mac/iOS 均精确复现：69 字符原文搭配 15 字符边界，首词被计算为 -54。证据 `*-boundary-red2.xcresult`。修复统一保留音频对应的视觉边界、绝对原文末端及消费游标，绿灯验证进行中。
- 失败测试诊断曾使磁盘可用空间降到 388 MiB；只清理本任务非活动的可再生编译缓存，保留源码、候选产品和全部失败证据。后续 XCTest 使用 `-collect-test-diagnostics never`。清理记录见 `inactive-build-cache-cleanup.json`。

当前仍为 IN_PROGRESS；30 分钟 Read、15 分钟 Explain、字号/主题/窗口组合、直接位置跳转和最终 Release 尚需通过。

## 07:40 追加：连续重排

- 原音频边界修复已通过共享桥接及分页回归：Mac/iOS 各 134 PASS、1 可选网络 SKIP。随后实际字号复演发生在跨页携带音频期间，暴露另一处恢复锚点为空；因此未把这次实际复演计为通过。
- 跨页音频的旧段落已退出当前页面时，现在仍保存其原文坐标、音频与暂停位置。生产 bundle 的真实 WKWebView 夹具先在 Mac/iOS 均复现空锚点，修复后通过；相关 132 项回归两端均 132 PASS、0 FAIL、0 SKIP。
- 07:22 快速连续改变字号，第二次重排发生在第一轮恢复音频返回前，旧实现将恢复位置改为零。新增连续重排断言，iOS 红灯复现 0 与约 0.406 的差异；修复保留尚未完成的恢复请求及暂停意图。`ios-repeat-reflow-green2.xcresult` 的 5 项通过。第一次名称带 green 的结果实际未包含新源码并失败，不能算绿灯。
- 扩大阅读区域时，保留旧音频段落还会丢失新露出的后半段文字。Mac/iOS 各 1 项红灯精确复现；修复把验证过的未读尾部排入下一段，保留它在同一 DOM 段落里的字符偏移。正在运行涵盖上述场景的两端 5 项回归。
- 磁盘不足导致的首次尾部回归构建失败与随后真正的测试红灯分开保留。已对本任务 3 份非活动测试 Products、21 份非活动隔离源码副本逐文件 SHA 校验、可恢复归档，再移除对应副本。原始测试结果、发布产品、认证数据保留。归档清单见 `inactive-isolated-source-archives.json` 及 `g08-kobo-contracts/inactive-test-products-archive.json`。未将失败的 xcresult 压缩尝试计为成功。

Kobo 门禁仍未通过；每次短时故障复演都单独记录，不能累加为 30 分钟连续朗读。

## 07:59 追加：官方设置的 Shadow DOM 点击

- 尾部保留及连续重排 5 项回归两端全部通过；随后共享桥接/分页 136 项两端均 135 PASS、0 FAIL、1 可选网络 SKIP。完整结果见 `*-tail-integration-summary.json`。
- 真实暂停调字号仍重置进度，进一步定位到共享 JS 的正文点击命中：官方设置用 Shadow DOM，事件 target 变成外壳，旧 closest 检查漏掉内部按钮，把面板下的段落当作点击目标。新 WK 回归两端旧源码均失败；改为检查 composedPath 后，相关 8 项 Mac/iOS 全部通过。
- 修复正文误触后，右侧 Increase font size 又触发 Kobo 页边翻页监听，导致 reason=manual。该监听也需检查 Shadow DOM 的完整点击路径。真实浏览器夹具红灯已确认“字号按钮在页边不能产生手动翻页”；修复同时保留官方 shadow next-page 的 next 意图。重新生成仅替换 Kobo 模块，其他模块前后缀 SHA 一致。
- 07:42:42 与 07:43:13 的两次网页进程退出，崩溃栈均是 AXPMacPlatformElement accessibilityPerformPress → Swift 数组越界断言；后续使用 CastReader More → Reading settings 正常打开。保留系统报告路径和脱敏栈 `g08-kobo-tail-live-reflow/ax-press-webkit-crashes.json`，不把工具触发的系统栈描述成 TTS 故障。
- 字号/主题路径仍等待最新候选实际复演；不能据单元测试宣称 Kobo 长读门禁通过。Mac 一次隔离包代码签名失败发生在磁盘 235 MiB 时；保留失败构建日志，清理本任务已结束构建的可再生缓存后重试通过。

## 08:18 追加：根节点点击与深色主题

- composedPath 防护通过夹具后，真实设置点击仍出现误触。诊断记录 `08:04:14.390 KOBO JS tap shell path=html`：部分官方控件把点击重新派发给根 html，丢失按钮身份；仅检查 Shadow DOM 路径不足。实际可见 `.PopUp_container[role=dialog]` 为 376×552 点，故在可见对话框打开时阻止底层正文命中和页边手动导航。保留正常官方控件操作和自动朗读。
- 增加根 html 重派发夹具，两端旧实现均红灯；修复后 Mac/iOS 各 8 项 PASS，真实浏览器 Kobo 夹具 PASS。临时路径诊断已移除，原生仅保留不含文本的段落点击 index 日志。
- 真实暂停复验：08:13:36 保存段落 1 音频 11.831407042 秒；字号 8→9→8→7，无 paragraphTapped、无 manual turn，08:14:14 以相同 20.30 秒音频恢复 progress=0.583，保持暂停并重绘词。`g08-kobo-modal-live/result.json` 为这项局部通过，不等于整个 G08 通过。
- 新长读开始后切为深色主题，自动翻页仍推进到 31–32/348，但实际当前词高亮不可辨认，即使日志持续 ov=1。08:15:54 主动暂停检查样式，`g08-kobo-modal-long-read/result.json` 为 STOPPED_FOR_UI_FAILURE，未满足 30 分钟。
- iOS 一次新隔离包代码签名 internal error 与低磁盘同时发生；只清理本任务已结束构建的缓存后串行重试通过。记录失败和 build2，不能把构建失败计为功能红灯。

### 08:32 theme overlay fix

- Live diagnostic: the dark provider theme changed `.cr-hl-ov` computed background to `rgba(0,0,0,0)`; multiply also cannot show an accent on pure black. Overlay now owns its translucent accent with important and normal alpha compositing. Temporary style diagnostics removed.
- Added real WKWebView iframe coverage of four provider themes with an important background reset. Old implementation: 1 test, 8 assertion failures. Fixed Mac: 9/9 tests passed, including font reflow, carried paused audio, clipping and modal clicks. Explain SVG ink assertions passed too.
- First iOS execution passed 9/9 but ran out of disk while saving xcresult; that result is incomplete evidence. Freed only this task's regenerable caches and reran to a separate green2 result. Normal build initially failed code signing internal error, then succeeded after cache cleanup.
- Evidence: g08-kobo-contracts/mac-theme-red.xcresult, mac-theme-green.xcresult, ios-theme-green.xcresult (incomplete), ios-theme-green2.xcresult; theme-candidate-identity.json; theme-generated-verification.json.
- Actual provider theme validation and a fresh sustained run remain pending.

### 08:50 live reflow and short-window UI follow-up

- Actual theme sequence gray -> black -> sepia -> white passed with visible word highlights. White remains selected; provider font returned to 7 after 7 -> 8 -> 7 during playback. No paragraph selection/manual turn was emitted by the settings controls.
- Playing resize 1024 -> 1728 -> 1024 retained exact source audio and proceeded into Chapter Three. Further 800x600 window testing showed mobile floating controls could cover the bottom text line. This is a separate UI failure, not a long-read pass. Mac generic readers now always reserve the playback row; iOS's conditional branch is unchanged. Real corrected small-window verification is still pending installation after the current long-read run.
- Presentation acknowledgement timeout now uses the existing localized content-retry message instead of claiming a network failure. Mac selected regression suite passed 20/20; iPad follow-up is running. Native restore logs were extended with bounded numeric request/completion location diagnostics to investigate the separate mismatched-page cold-restore case; no full source or credential is logged.
- Current long-read binary is still the theme-candidate identity. Later UI/message/diagnostic changes have not been installed in it. Preserve that distinction when inheriting runtime evidence.

### 09:03 sustained Read completed; G08 remains in progress

- `g08-kobo-theme-long-read/result.json`: first/last word events 08:32:07.960–09:02:42.913, span 1834.953 seconds; 40 automatic commits to 40 unique targets, 19 carry commits, 6 refresh commits, 0 manual commits. All 40 presentation holds released, median 330.77 ms and maximum 599.79 ms. No presentation timeout, stuck turn or repeated automatic target occurred.
- The 4803 word-paint events contain 10 zero-overlay events: 8 during window transitions, 1 during a font transition, and 1 isolated event at 08:36:24.785 that recovered at the following word. Do not describe this run as zero missing highlights. The isolated event remains a follow-up; no sustained invisible highlight occurred after the theme fix.
- CPU/RSS samples are in `resources.jsonl`; RSS samples were approximately 141–143 MiB. These are main-process samples, not a full energy or WebContent-process measurement.
- Mac and iPad desktop-controls/recovery selections both passed 20/20 with complete xcresult summaries. The normal candidate with reserved desktop controls is being built for actual 800×600 and recovery validation.
- At 09:02:42 paused Chapter Five, paragraph 1, segment time 7.096730083 seconds, word hash d1905cf90af2. Browsed Chapter Two 29–30/348 without playing, then quit. New `g08-kobo-direct-restore/` records whether a cold open recovers that original checkpoint from the mismatched official location. G08 is not yet passed; Explain 15 minutes and recovery remain open.

### 09:35 initial pagination and desktop resume follow-up

- Direct cold restore originally jumped while native `pagesOfBook` was NaN. The ready gate now requires finite valid whole-book range. Mac/iPad 8/8 contracts passed. Initial iPad result could not save under disk pressure; green2 and its summary are complete.
- Ready gating alone was insufficient: three cold opens stayed without a page total, while a real resize immediately completed pagination. A single standard resize notification, issued only for an explicit saved-location restore after the native controller appears and before it has a valid total, resolved the real case. Browser fixture checks only one notification and waits for settlement; virtual-time budget extended to 15 seconds for that additional asynchronous phase.
- 09:28:43 initial-layout notification; 09:28:45 one direct native jump with pages=348; 09:28:47 exact saved source matched in Chapter Five 109–110/348. Remained paused until explicit Play. 09:29:34 restored 7.096730083 seconds; first-play sample 7.151180125 and identical word hash d1905cf90af2. Evidence: g08-kobo-direct-restore/initial-layout-result.json.
- Final initial-pagination candidate passed Mac 28/28 and iPad 28/28 (0 skip). At 800×600 the reserved bottom row no longer covers text.
- A separate real playback defect remains: shrinking while paused moves the saved word past the old page edge. Play at 09:32:18 sees an artificial forward endpoint 2.838583 seconds behind the restored position 9.441225 seconds, then mistakes that event for full media completion. Current G08 is still in progress; adding an AVPlayer regression before modifying this shared audio path.
- Low-disk cleanup removed only inactive task build dependency/SDK caches, recorded in restore-ready-inactive-dependency-cleanup.json. A failed archive attempt was removed without deleting the original result. Available disk is now about 18 GiB.

### 10:03 restored segment regression

- The shared AVPlayer regression for a restored position beyond an old page endpoint failed on the old code (both paused and automatic cases). Deferring its observer until the initial seek settles, and rechecking it before explicit Play, passed the new test plus 136/136 Mac and 136/136 iPad related regressions with zero skips. Results: `*-restored-edge-integration.xcresult` and complete summaries. This establishes the audio contract; exact actual-provider reproduction still needs a pass.
- The normal candidate then exposed a separate VM defect at 09:50–09:51: after 1024×768 → 800×600 while paused, segment 1 resumed at progress 0.459 but the page observer still referenced segment 0. All subsequent words were off-page (`ov=0`), without a page turn. Evidence is frozen under `g08-kobo-restored-edge-live/later-segment-failure.*`; G08 remains in progress.
- A two-segment paused-reflow test reproduces that issue on the old VM (1 test, 7 failed assertions, including a missing hold and about six seconds of unpainted audio progression). The candidate rebinds the visual boundary to the verified restore/current segment when the original boundary segment has already been skipped. It retains the source-consumption cursor and pause intent.
- A third provider-text accessibility press crashed WebKit at 09:49:32. The diagnostic again names `AXPMacPlatformElement._synthesizeMouseClick/accessibilityPerformPress`, followed by an array bounds assertion. The app recovered its page while paused. Bounded stack evidence is in `g08-kobo-restored-edge-live/webkit-ax-crash-third.json`. Subsequent provider interactions use pixel clicks; native controls remain accessible.

- Final affected integration selection, including all 99 ReadingResume tests, passed Mac 230/230 and iPad 230/230, zero skips. Complete result bundles and summaries are `*-later-segment-integration.*`. The normal candidate source/binary identity is `later-segment-candidate-identity.json`.
- Actual 10:11 paused reflow of another long paragraph preserved second-segment progress 0.071 and immediately painted its saved word after finding the source page. That verifies ordinary paused reflow, not yet the earlier-edge regression; the exact earlier-edge replay remains open.

### 10:24 actual old-edge replay and stale producer intent

- Actual 10:17 reflow restored segment 0 at progress 0.755 (17.304-second item), beyond the old page cue 2.76358. Explicit Play revealed page 122/393, visibly highlighted the current word, and continued to the real 17.304-second item end. This verifies the artificial-endpoint fix in the provider UI.
- The following network segment arrived at 10:17:41 after the restored item had drained. It was enqueued with `auto=N` because the generating task had started while paused. A second explicit Play was required at 10:17:52. This is a new failure, retained under `same-segment-replay-with-late-tail-failure.*`, not a clean end-to-end pass.
- Two new offline producer regressions reproduce stale intent, both when Play arrives before the first restored item and when it arrives before a late successor. Old code: 2 tests, 2 failures. Candidate uses the latest owned playback request while preserving explicit Pause, navigation suspension, interruption and ownership gates. Targeted shared resume/streaming regression is running on both platforms.

- Stale producer intent fix: Mac 123/123 and iPad 123/123 affected tests passed, zero skips, including both new regressions and all 101 ReadingResume cases. Normal Debug build succeeded; source/binary identity is `paused-producer-candidate-identity.json`. Real late-tail replay still running.

### 10:29 later-segment provider replay passed

- Latest normal candidate restored saved segment 1 at 10.736708 seconds, remained paused, then reflowed from 1024×768 to 800×600. The original boundary in segment 0 was rebound to segment 1 at time zero while preserving restored progress 0.708 and the source cursor.
- Explicit Play at 10:28:53 revealed page 122/393, displayed the current word highlight, and continued the unheard tail. At 10:28:58 it automatically advanced to page 123 and the next paragraph, then page 124. Frozen evidence: `g08-kobo-restored-edge-live/later-segment-live-pass.{json,log}`.
- The exact later-segment earlier-edge defect is now a real-provider pass. The separate late-producer-after-drain scenario is covered by deterministic real-AVPlayer tests on both platforms; current network responses were faster, so no additional natural delayed-response pass is claimed.
- A new uninterrupted Explain run began with actual playback at 10:30:46.260 using this same candidate. Its minimum duration is 900 seconds; book-end handling is a separate check.

### 10:57 long Explain passed; book-end mode switch failed

- Frozen `g08-kobo-long-explain/result.json`: actual playback 10:30:46.260 through last timed subtitle 10:46:15.945, 929.685 seconds, 35 automatic commits to 35 unique targets, 162 subtitle cues, zero manual/refresh commits and no detected turn/presentation failures. Chapters Five → Six → Seven. Four backgrounds, font 7→8→7 and 800×600 / 1024×768 verified visually. Caption timing is not an acoustic dropout measurement; resource samples include only the main process.
- Separate Author-tail Explain reached 393/393 and `native-book-end` at 10:50:50.850, with the visible completed state. Switching to Read then spoke the two terminal paragraphs but reused the old failed-turn signature: completion was suppressed at 10:51:49.694, followed by presentation timeout and a retry overlay. This is retained as a failure in `g08-kobo-book-end/result.json`, not a full book-end pass. Adding real WK/AVPlayer regressions for Explain→Read and terminal-page replay.
- The paused caption covers the bottom Author entry in the small-window provider contents panel. It passes clicks through, but visually obscures text. This UI follow-up remains open.

### 11:37 terminal candidate and cold-pagination follow-up

- Explain→Read and explicit terminal replay now reuse an already verified `native-book-end` result for the current audio owner and drain the presentation hold. The original Mac regression failed; corrected Mac book-end regressions pass 2/2. Replay uses the actual jump-to-first-paragraph action, not an inert start on an already completed VM.
- Provider dialog visibility now hides only the Explain caption while preserving the cue and playback state; scoped messages accept the current Kobo owner only. Mac/iPad full integration runs each contained 187 cases: 185 passed, one new fixture setup failed, one pre-existing optional network case skipped. After correcting fixture readiness and the JS return type, the two affected cases passed on both platforms. See `g08-kobo-contracts/terminal-integration-rollup.json`; original failures remain intact.
- Actual cold opening of the completed Two Tickets book had no unfinished audio checkpoint and left native total pages unset. Explain ended through `javascript-no-change` at 11:23:59.410, not verified book end. Its provider recommendation panel had x=-50, width=740 at a 1024-wide window, leaving the close affordance outside the viewport. Frozen evidence: `g08-kobo-book-end/candidate-events.log`. This run is not a pass.
- The one-shot initial native pagination layout notification now also applies after the first published page when no saved cursor exists, with the same guards against an active turn/reflow. A browser fixture passes without calling restoreReady. Recommendation dialogs receive viewport bounds at initial rendered handoff, so the rule does not depend on opening Aa or contents first. A WK regression checks 390×410, 800×410 and 1024×579 while preserving source typography.
- Both changed targets compile. The first selected native run used invalid target-prefixed identifiers and executed zero cases; its successful process exit is explicitly not accepted as test evidence. Corrected identifier runs are in progress as `*-cold-pagination2.xcresult`. Actual provider replay is pending these checks.

### 11:44 cold-open, terminal switch and small-window caption pass

- Corrected native selections passed Mac 50/50 and iPad 50/50, zero skips. `*-cold-pagination2-summary.json` is the accepted count; the earlier zero-case results are excluded.
- Actual normal cold open from Continue Listening dispatched exactly one initial layout notification and showed 347–348/348 without any user resize. At 800×600, tail page settled to 393/393.
- Explain completed via verified `native-book-end` at 11:41:38.775. Switching to Read, both remaining paragraphs played with visible highlight; at 11:42:40.853 the remembered verified end drained the presentation hold and finished. No retry overlay or presentation timeout appeared. Manually pressing Next at the end kept the page paused.
- While Explain was paused, opening contents at 800×600 removed the subtitle and exposed the entire Author row. Closing contents restored the same subtitle and retained pause. Actual screenshot observations are in the task tool history.
- The recommendation dialog no longer opens in this verified terminal flow. Its new bounds have WK fixture coverage; an actual open of that recommendation after the fix is not claimed. Detailed observed-case result and bounded events: `g08-kobo-book-end/cold-fixed-result.json` and `cold-fixed-events.log`.
- Starting a second real Kobo title before closing the core gate.

### 11:50 core gate complete

Second title Falling for the Movie Star passed actual Read with automatic pages and 800×600 → 1024×768 reflow, then Explain automatically advanced 779–780 → 781–782/969 with visible marks in both columns. Cold restart matched the saved Read source directly at 11:48:38 and restored paragraph 2 while paused. Explicit Play continued with visible word highlighting. Evidence: `g08-kobo-second-book/result.json` and events.

G08 core gate PASS: shelf/search/sort/refresh, two titles, sustained Read and Explain, provider theme/font/resize, paused resume, direct cold restore and terminal mode switch have actual evidence. This is not a full release sign-off: M069 actual different-account isolation remains unrun; the optional recommendation popup bounds have WK coverage but no post-fix live open; three WebKit accessibility-press crashes are retained as a system interaction limitation (pixel actions used for provider controls). Continue G09 instead of claiming all four platforms complete.
