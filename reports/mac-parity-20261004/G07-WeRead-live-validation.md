# G07 微信读书 Mac 验收（进行中）

## 范围与当前状态

Mac 国际版，复用 iOS 微信读书的同步书架与阅读服务。用户负责书架同步实现；本轮只验证同步结果在 Mac 的消费、导航、读/解读、恢复及 UI。Kindle 核心流程已通过后进入本组。

## 已确认的真实行为

- 首页同步书架显示 8 本，包括《老人与海》《西线无战事》，能直接打开对应官方 reader。
- 《老人与海》原生目录列出 13 项，选择第一章抵达正文；晓萱 1x 真实服务朗读、原文高亮与自然下一页已观察。尚非 30 分钟通过。
- 显式暂停后退出应用；新进程 15586 重开《老人与海》，03:58 之后保存的阅读页通过官方 chapter offset + 文本检查点匹配恢复（04:18:28.281 matched turns=1），界面保持 Paused，随后显式 Play 开始长时测试。
- Mac 原生返回按钮去除额外系统边框，标题与模式选择布局正常。
- 《西线无战事》实测原生下一页从封面→推荐值页→简介，并能上一页回推荐值页；保持暂停，没有自动开始 TTS。此前两轮失败和修复见下节。
- 官方页面仍显示“登录”；同步书架可见不等同于当前内嵌阅读会话已认证。尚未验证付费/限读后的账号权限，不把公开试读当作登录态通过。

## 修复与验证

1. 原生分页入口先检查 didInit，封面没有可读段落导致按钮静默失效。WeRead 的显式手动分页先交给其已有 JS 分页验证；Google/Kobo 原门禁保持。
2. 非正文页不会发正文提交，pending manual turn 曾永久保留。现在从申请起就使用已有 2.5 秒手动意图期限，既阻止双击重复翻页，也能释放无正文页面的锁。
3. 推荐页的 native canvas snapshot 可存在但 ready=false。只有无已提交可读正文的手动操作，可调用可见且启用的官方分页按钮；打开的设置/对话框仍拦截，自动翻页仍需正文证据。
4. 回归新增 fresh cover→body、cover→non-text→body 两项；真实 WKWebView + bridge + VM + AVPlayer，只有 TTS transport 受控。初始 bug 的单项失败证据保留。

测试运行和包摘要位于 `g07-weread-native-pager/`。native bridge + 锁修复版本 Mac 30/30、iOS 30/30 通过；随后 native snapshot 非正文例外的新候选追加回归也为 Mac 30/30、iOS 30/30，0 失败、0 跳过。各轮范围重叠，不累计为独立用例数。

## 测试夹具修正（不是产品修复）

- 三个恢复用例只在 Mac 失败。诊断显示替换 HTML 的 root 高度为 19 px，低于生产提取器已有的 20 px 有效布局要求；原始页面却设置了 20px 字号和 160px 最小高度。替换页补齐相同 CSS 后三项通过，未修改生产提取阈值。
- 测试窗口关联真实 UIWindowScene，替换文档使用唯一 token 等待。双栏圆圈几何测试改为同一 JS 事务创建并读取人工标注，避免 native VM 已排队的 clearMarks 在两次 JS 调用之间清掉合成标注。真实 marks 生命周期另由活动 VM 与实书解读验证。

## 待完成

- 30 分钟实书 Read、15 分钟 Explain（含跨页/跨章/窗口变化）。
- 窄窗/宽窗、双栏、字号/主题、暂停恢复、手动页与目录深章。
- 限读/认证/网络错误、同步源刷新与持久化的实际验收。

没有把构建或单测通过记作本组最终通过。

## 实书长朗读尝试：官方访问限制（04:19–04:37）

- 首次 Playing 04:19:32.752，最后 Playing 04:37:26.875；确认跨度 1074.123 秒。24 次确认页面提交、13 次 continuous handoff、5 次 boundary carry，自然跨入第二章。
- 初始 1024×578 阅读面，缩小至 523×273，再放大至 1376×708 双栏。真实截图中左右栏高亮分别位于可见文本；官方 Aa 字号 1→3 后重新分页并继续朗读，没有主动暂停。通过迷你播放器收起再展开后仍 Playing。
- 04:37:30.434 官方“试读结束”，页面有“登录后获得专属福利”入口。应用已清掉预取/自动交接/音频所有权，并切 Retry/Paused，没有把限读提示当正文朗读。
- M061 的 30 分钟要求未满足，状态为 **BLOCKED_BY_PROVIDER_ACCESS_GATE**。现有书架条目不代表 Mac 内嵌阅读器会话已登录；尚需扫码恢复后继续验证。M064 只验证真实限读停止，尚未完成恢复/断网/其他认证状态。
- 证据 `g07-long-read/run.json`、`events.log`、`result.json`；保留原运行包和源码摘要。后续 UI 修复不冒用这一轮为新包全部通过。

## 追加 UI 与共享回归

- `WeReadOpeningPlaybackTests` Mac/iOS 各 13 项通过（封面识别、最多四次前进、慢页/付费页不跳过、取消/睡眠所有权）。两项独立 JavaScript 原生恢复/页面合同通过。native-resume 脚本初次缺 esbuild，改为只读复用本机现有依赖后通过；未修改主目录源码。
- Mac 登录指南改为手机微信扫码，保留 iOS 截图流程；两条文案补齐九语。
- 真实 Esc 先前直接收起阅读器并把官方字体面板留在后台。新候选先交给当前窗口的 WeRead 字体面板／Aa 引导处理，再收起阅读器；加入 provider 外部点击关闭及同书多窗口隔离回归。测试／实机结果待回填。
- CUA 路径绑定的坐标操作曾返回 AXError.noValue；改用 `com.same.castreader` Bundle ID 绑定后成功，字号调整在实际页面确认。此为工具访问问题，未误记成产品操作通过。

### 官方面板关闭事件定位

Aa 引导可由自身 close 清理；真实字体面板的外层是官方 BackgroundMask。先前 body.click 和 body mousedown/mouseup/click 两个候选均未关闭该面板，虽然各自 17 项夹具回归通过；这两轮实际失败保留，不计为 UI 通过。只读检查官方公开 JS 后，确认其 custom-selector 为 reader-font-control-panel-mask，click 经 emitClose 关闭。新候选点击此明确遮罩，不伪造 trusted 事件、不直接改 provider 状态、不用 CSS 隐藏面板；对应夹具改为提供同一语义遮罩。来源摘要见 escape-investigation.json，最终实机结果另记。

扫码页已显示 Mac 手机扫码指南，二维码完整可见。标题栏 Close 曾裁成 Cl…，新候选去除 Catalyst 按钮装饰并保持标签固有宽度，待实际复验。已请求用户补当前 Mac 内嵌微信登录；不重新实现书架同步。

### 05:06 字号关闭与书架 UI 实测

- 最终定位为桌面 ReaderFloatFontPanel 的 `controlled=true`：内层没有遮罩，外层 `.reader_float_font_panel > .wr_mask` 才拥有关闭事件。先前内层 selector 候选同样失败；改为当前面板的外层遮罩后，PID 20494 真实按 Esc 已关闭官方字号面板、保留阅读页且暂停。仍不直接修改 provider 状态。
- 此候选外观回归 Mac 17/17、iOS 17/17 通过。扫码页九语中的英语实际显示正确；Close 由 Cl… 恢复完整标签。
- 微信书架中文搜索“老人”只显示《老人与海》，不存在查询显示 No matching books，清空恢复；Title 排序和 Load More 展示后续书目；取消刷新扫码页后原缓存保留。当前同步书目作者字段均为 Unknown author，不能把 Author 排序的语义正确性判为通过，需同步数据补齐后联验。

### 05:07 解读追加失败与修复

- 公开第一章能产生真实讲解，但下一页只有 23 字，服务端明确 text_too_short，预取曾在当前页播放期间反复重发。增加当前 source/prediction/language/depth 的确定性拒绝记忆；变化或失效后才允许新预取，网络错误不冒充内容太短。新增真实 WKWebView + bridge + QuickRead transport 的重复 preview 回归；结果待填。
- 第一章尾部没有可读 successor，自动解读结束；手动下一页抵达第二章仅标题“2”，仍未登录。保留为限读环境下的未完成长时验收，没有通过 15 分钟要求。证据 `g07-weread-long-explain/`。
- 旧 Mac 外观套件曾 16/17、单项复跑仍失败。隔离宿主启动时 RootAuthGate 的属性会先初始化 AuthService，`restore → discardInvalidRestoredIdentity → AccountContentIsolation.deactivate → clearForAccountBoundary` 可清掉先开始的测试音频。调用栈证据保留；修正两个隔离脚本，在实例化 RouteReadyRoot 前挡住测试入口。生产 App 的账号边界完全未改；后续回归待填。

### 05:30 修复回归完成，认证门禁保留

- 最终 ReaderAppearance 17 + WeReadPageAvailability 31：Mac 48/48、iOS 48/48，0 失败、0 跳过。此前隔离宿主 45 PASS/3 崩溃源于测试延迟初始化 AuthService 时正在清理活动 VM，又由 analytics 递归访问单例；两个套件 setUp 先初始化 AuthService，恢复正常启动顺序后全过。生产账号隔离和分析逻辑未为测试修改。
- PID 22167 在原失败页 7bea48c2、预测页 5703b1cb 精确复演：05:20:34.930 仅一次预取，05:20:35.635 收到 text_too_short，余下播放未重复请求。证据 g07-weread-prefetch-replay/result.json；此结果只证明重复预取修复，不代替长解读通过。
- 同包再次实际验证 Esc 关闭字号面板并保持阅读页。书架 Recent 排序恢复，迷你播放器已关闭。官方字号仍是测试后的 3；恢复滑块的 CUA 坐标操作返回 AXError.noValue，不能宣称恢复到原 1。
- 微信扫码问题仍待用户回复；长 Read/Explain 与认证恢复继续 BLOCKED。已进入可独立执行的 Kobo 本地/界面验收，不将 G07 整组标为通过。


## 2026-10-06：已登录、Mac 页面比例与解读展开恢复

用户已确认微信扫码成功；《围城》内嵌页显示已登录头像及“我的书架”，此前认证阻塞已解除。用户手动将字号调到最小，保留该选择，不再把页面比例问题归因于字号滑块。

Mac 使用整页 `pageZoom=0.8`，关闭原有手机视口裁切放大；iPhone/iPad 仍为 pageZoom=1，保留原紧凑裁切。阅读时隐藏底层 Home/WeRead Library 的导航栏，返回书架后正常恢复。原候选 `3c8a73e...` 中观察到多次 Read 自动翻页及词高亮、Explain Part 1→2 的原文下划线。页面比例已有改善，但尚无用户目测确认。

复验发现收起→展开会采用较早的 Read 检查点，使解读进度和网页不一致；此失败已保留。增量修复优先找到仍在内存中的同一阅读页，仅在完整原文一致时恢复其音频与标注索引，不拿旧页覆盖活动讲解。新的真实 WKWebView 回归覆盖旧检查点/页面查找/标注重绘/不自动播放/不重请求，单项通过；受影响套件最终 33 PASS、0 FAIL、0 SKIP（包含原页面可用性套件及 Mac 几何测试，不与之前 32 项累加）。这次共享恢复代码变更未另跑 iPad 真机验收。

普通通用 Release 构建、App/Share/Widget 的严格签名及精确 profile/App Group 校验通过。安装候选 SHA-256 `94b6cd44547586dea26b84151e6cc77705daa87cece6e1b88d17d9d714be0526`；真实展开恢复复验结果见 `weread-desktop-density/live-validation.json`。

未重跑原全量长测、跨账号/跨客户端冲突矩阵，不据此宣称 G07 或整产品全部验收通过。声音创建 PR #67 按用户要求保留草稿、暂不上线；与微信布局修复相互独立。

### 00:11 正常 Release 复验未通过（不得用单测覆盖）

候选 `94b6cd44...` 中，新页面真实 Explain Part 1→3，橙色圈注、下划线和底色标注可见。Part 3 暂停→收起→展开后播放器仍为相同讲解字幕与 Paused Part 3/3，但原页从“身，只问小孩子……”回到了较早“待的伤痛……”所在页，标注未恢复。再次激活窗口后仍未恢复，故该项 FAIL。已保留现场暂停状态。33 项夹具回归通过只代表其覆盖场景，尚未解释真实 provider 的恢复差异；微信整组未验收完成。声音创建接口补丁仍仅为草稿，用户未授权上线。


## 2026-10-06 核心收敛补验

最新正常 Release 修复了收起/展开时隐藏 WebView 随导航高度重排的问题，真实第一章试读保持同页、Part 1/4 暂停、字幕及圈注，继续播放通过。当前 provider 会话失效，扫码页已打开，登录态与冷恢复最终复验尚未通过。 详见 `core-convergence-20261006/README.md`。
