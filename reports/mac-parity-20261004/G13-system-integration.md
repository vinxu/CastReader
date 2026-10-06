# Mac 系统入口验收（进行中）

- MacShare / MacWidget 是两个原生 macOS 扩展，最低系统 14.6；主程序仍复用 iOS 的 228 个源码。构建、签名验证、pluginkit 识别通过；iOS targets 设置和依赖保持基线不变。
- 共享 ShareInbox / 账号分区 / YouTube 持久待处理队列，Mac 只增加 AppKit 呈现和 NSImage 编码分支。分享使用本应用 bundle 的明确路径唤起主程序，避免与现有 Safari 宿主 URL scheme 冲突。
- 在系统 Sharing Extensions 启用当前测试包后，Finder `Mac sample.txt` → CastReader for Mac → Add to CastReader → Content Inbox → Read Aloud，四段中英文全文进入原生阅读器，国际服务开始朗读。首次扩展从启动到展示约 69 秒，需继续排查/复测；不能视为性能验收通过。
- 多窗口实测补齐：原窗真实网页朗读 → 新窗 Library → Window 菜单切回 CastReader → ⌘W，剩余 Library 窗自动接收同一阅读器并保持 Playing；暂停后第 10 段第 0 音频 segment 从 9.81 秒连续到 24.28 秒，没有从头重播。菜单同名窗口曾使工具定位失败，使用不同标签标题重测通过。
- Widget 当前只有编译/注册证据；桌面添加、当前账号内容、点击移交未验收。
- App Intents、系统媒体键、通知、Safari 宿主协作仍在验证；不宣称全部完成。


## Widget 操作工具限制

2026-10-05：原生 Notification Center 的 AX 仅返回空容器，截图为空；Control Center/SystemUIServer 获取超时，工具不支持 `fn` 键。系统 Desktop & Dock 中 Widget 显示配置可读但无编辑入口。已请用户方便时打开“编辑小组件”，未将实际添加/点击标记通过，也未修改系统 Widget 偏好。


## App Intents 真机执行（2026-10-05 19:25–19:32）

开发签名通用 Release 从 `/tmp` 安装到用户的 `/Users/xuxuheng/Applications/CastReader for Mac.app` 并启动、重开 Shortcuts 后，搜索可见 Read / Explain / Continue 三个动作。没有改动系统隐私权限或原有 Safari 应用。

- Read 输入任务自建的一句英文，正确打开 Shortcut Text / Read Aloud，实际 Playing 后自然结束，末词 `word` 橙色高亮可见。
- Explain 输入任务自建的两句光合作用说明，正确打开 Explain，生成讲解播放到完成；原文上的整句橙色高亮和下划线可见。第一次调用停留在系统初始化，取消后重试成功；随后一次重复调用也完成，不能把最初等待略去作为性能通过。
- Continue 未指定项目：主程序退出后由快捷指令冷启动，打开当前 continuing 列表首项 Shortcut Text / Read；最近项目菜单也列出当前账号的八个可继续项目。显式选择 Shortcut Text 后再次执行成功。这里测试的是当前账号可继续项目合同，不证明另一个账号或被删除项目的真实行为。
- 系统日志记录三种 `perform()` 实际进入并完成，冻结于 `g13-system/app-intents-execution.log`。只有元数据编译不计为执行证据。
- 临时快捷指令 `CastReader Mac Acceptance — temporary` 已删除；原有五个快捷指令均保留。测试文本历史保留为验收样本。

Shortcuts 动作左侧曾显示通用占位图标，应用包本身已有 AppIcon.icns；图标缓存/系统展示留待 UI 收尾确认。

## Safari 分享首次失败（保留原始失败证据）

旧 Safari 扩展仍为 `com.castreader.CastReader.Extension`，Mac Share 为独立入口。任务新开公开博客页，旧扩展控件可展开、设置显示 Free plan（Mac 主程序当前账号为 Pro；尚未证明两者当前身份一致）。旧扩展此次朗读停在 Loading 后被停止，未计音频通过。

Safari 系统 Share → CastReader for Mac 可以显示面板，但点击 Add to CastReader 返回 cannot open this item；Finder 文件分享通过不能替代此网页输入。正在对允许的 representation 类型和运行时类型加无内容诊断，以定位实际差异。没有修改旧 Safari 扩展或用户其他页面。


## Safari URL 输入与签名修复（2026-10-05 19:49–20:05）

真实 Safari 分享诊断证明 `public.url` 返回 `_NSInlineData`，原 Mac 入口只接受 URL/NSURL，导致有效网页被拒绝。新增共享 URL representation 解码，仅对 `public.url` / `public.file-url` 的非空、≤16 KiB 数据生效；仍保留 HTTP(S) 验证、文件类型/大小限制和账号边界。日志只记录 UTI、对象类型、数量与错误类型，不记录地址、正文或凭据。

- 当前四个新增回归覆盖 Safari 数据 URL 的编码/query/fragment、Finder URL 对象和文件 URL 字节、文档/图片数据不能误判为 URL，以及解码后的 scheme 校验。与既有系统入口及账号分区套件一起，Mac/iPad 各 **25 PASS，0 FAIL，0 SKIP**；`g13-system/share-{mac,ios}-summary.json`。这轮不包含后续冷启动修复。
- 修复版 Debug 实际 Safari Share → Add → Content Inbox 显示正确文章标题 → Read Aloud → 原网页真实 Playing、标题 `Captions` 和正文 `article` 橙色逐词高亮可见，自动滚动到正文。工具连接在一次移交时断开，重新读取实际 UI 后确认成功，未把工具响应当作产品成功。
- 原 Share/Widget entitlement 声明了共享组，但嵌入的 wildcard profile 没有授予组。三 Mac targets 增加 `REGISTER_APP_GROUPS=YES`，自动签名已取得明确应用标识和共享组授权。Xcode 在首次更新 profile 后仍可能沿用旧资源签名；仅重建本任务的可再生产物后，主程序和两个扩展的严格深度签名通过。
- 新增 `scripts/verify-mac-bundle.py`，将三 bundle 的签名、沙盒、应用标识、profile 有效期和组授权纳入安装前验证。Debug、通用 Release、安装路径均通过；Release 无 54 项测试标记残留，107 文件扫描通过。冻结结果在 `g13-system/`。
- 原分享启动长等：进程采样显示主线程阻塞在共享 UserDefaults，当前用户 cfprefsd 的一个线程卡在 sandbox 检查并占用偏好源锁。签名修正后仍有旧阻塞，一次有 PID/用户/命令校验的当前用户 cfprefsd 正常终止使 launchd 重建进程，主程序与分享恢复；没有删除偏好、重置账号或改变系统权限。恢复后曾测得请求→面板约 0.506 秒；仍需后续独立冷/热重测，不能把守护进程恢复遗漏为“单靠代码修复”。

## 冷启动自动展开收件箱（20:05 起，修复中）

一轮名义上的 Release 冷启动实际由 PlugInKit 选中了 `/tmp` 的 Debug 扩展，明确排除为 Release 证据。已仅注销本任务 DerivedData 下的重复 MacShare/MacWidget 注册，并注册 `/Users/xuxuheng/Applications/CastReader for Mac.app` 内扩展；进程路径回读确认主程序及扩展均来自安装目录，旧 Safari 宿主未改。

正确 Release 冷启动复现：内容保存、主程序启动成功，但仅显示 Home，未自动展开收件箱。源码中的一次性通知早于 MainTab/窗口就绪而丢失。候选改为目标 scene 保留待处理分享请求，待 active/key window 后消费；账号边界清空、其他窗口不消费。新增冷启动/账号边界/双窗口焦点测试，准备运行并实际重放。本阶段仍 IN_PROGRESS，不把保存成功替代完整冷移交通过。


### 冷移交候选回归与真实复验

新增 scene 请求保留/账号边界/双窗口消费检查后，Mac **29 PASS**（含两项 MacWindowRouting）、iPad **27 PASS**，均 0 FAIL/0 SKIP。SwiftUI 生命周期 modifier 链最初超过类型检查预算，移到既有 windowLifecycleContent 边界后双端编译通过；未改产品行为来绕过检查。iPad 后续等待是 Xcode 正在生成覆盖率报告，进程采样确认，最终成功结果已冻结。

Debug 正常安装候选实测：主程序与扩展均退出后，分享唤起指定安装路径并直接展开 Content Inbox；点击 Read 可真实播放原网页。已有暂停阅读器时再次分享，也能在阅读器之上展开 Inbox。两次扩展请求→面板分别 **0.774 秒**、**0.615 秒**，未再次重启偏好守护进程。对应 `cold-share-{mac,ios}-summary.json` 与 `cold-share-source-hashes.json`。后续重复同页 Explain 暴露共享模式激活竞态，正在补回归；不能因此提前关闭整个 G13。

同一网页从暂停 Read 通过 Inbox 显式 Explain，日志显示先 `EXPLAIN start requested status=idle`、进入 planning，随后 Host 根据旧 Read 的暂停意图执行 `activateAfterModeSwitch(autoplay:false)` 将新计划误置 idle。网络请求实际已启动；当前不是“没有内容”，也不能以模式标签已经切换计为完整成功。修复目标是保留已激活的新计划，同时继续保证手动暂停、旧模式已取消计划和其他窗口音频所有权。


### 重复同页解读回归

首次单独执行新回归时，隔离宿主尚未构造 AuthService，音频所有权回收→analytics 再次访问正在初始化的 AuthService 导致递归锁崩溃。此结果单独保留为 `explain-initial-harness-crash.json`，不把它称为上述产品竞态的复现。测试 setUp 按真实应用顺序先完成 AuthService 初始化后，旧产品代码稳定复现 **idle != planning** 一项断言失败（`explain-regression-red.json`）。测试使用本地 HTTP 计划/音频夹具及真实 AVPlayer，不调用生产生成服务。

候选将 `activateAfterModeSwitch(autoplay:false)` 的清理限定为 VM 已 inactive 的旧计划，避免清理显式请求刚激活的新计划。保留全部暂停逻辑，正在运行 52 项 SpeechPipeline、两项真实 AVPlayer 所有权转移与系统/账号入口回归，并准备再次实测重复分享 Explain。

### 最终候选通过范围（2026-10-05 20:30–20:44）

最终相关选择包括完整 52 项 SpeechPipeline、两项真实 AVPlayer 阅读/解读所有权转移、SystemIntegration、HistoryStoreAccountScope，以及 Mac 独有两项窗口路由测试。**Mac 83 PASS、iPad 81 PASS，均 0 FAIL、0 SKIP**，隔离账号宿主执行；`final-{mac,ios}-summary.json`、`final-source-hashes.json` 固定本轮范围。此前各轮存在重叠，不累加成独立用例总数。

通用 Release 重新构建后安装到 `/Users/xuxuheng/Applications/CastReader for Mac.app`。版本 1.2.47 (72)、arm64/x86_64，主程序 SHA-256 为 `4ccb41be75e3e1f2b6923aa0ed8c70004df2ff422ae0430a1a028a265b4cc112`。主程序及两个扩展严格签名、明确 profile 身份与 App Group 授权通过；107 个文件/54 个测试标记扫描无残留，Debug 阳性对照有效。没有提交商店或对外发布。

- 冷分享前正常主程序不在运行。20:31 实际 Safari Share → CastReader for Mac → Add 自动启动主程序并展开 Content Inbox，显示正确公开文章标题；扩展和主程序的实际进程均来自安装路径。随后 Read 真实 Playing，正文表格 `fine` 的橙色逐词高亮和空格暂停通过。
- 20:34 在同页 Read 已暂停时再次分享，Inbox 正确覆盖现有阅读器；显式 Explain 不再被旧 Read 暂停状态取消。20:39 观察到自然结束的 `Explanation complete`，正文末尾保留手写高亮/下划线。点击重播回到 Part 1/9、Playing，空格切 Paused；再次恢复后推进到 Part 3/9，空格仍可暂停。
- 两次 Release 扩展请求→面板分别 **0.538 秒、0.564 秒**，本轮未再次重启 cfprefsd。对应脱敏 `release-share-extension.log`；保留前述旧 profile/daemon 阻塞历史，不把原 69 秒等待抹去。
- 关闭仅本轮新建的 Safari 测试页后，原 11 个标签仍在；测试阅读器停在 Paused。既有 Safari 扩展和用户其他页面未替换。公开内容历史作为验收样本保留。

G13 仍未整体关闭：实际 Widget 添加/点击、通知送达/点击、物理媒体键与旧 Safari 的同账号/异账号协作仍缺少完整证据。电脑工具不支持 `XF86AudioPlay`（返回 keyNotFound），空格成功不等同于系统媒体键通过。现有 macOS Safari 按独立 Web 账号/Stripe 路径工作；iOS 的 App Group 合同存在不能证明旧 Mac Safari 已共享主 App 账号。

### 末窗重建暴露视觉恢复缺陷（20:47 起）

上述 Release 继续测试：Part 3/9 Playing 时 ⌘W 关闭最后窗口，主进程 PID 62883 保留；重新打开应用已到 Part 4/9，随后继续到 Part 5/9，说明没有把关窗当作退出或重头播放。新窗口起初回到文章标题，要等新的讲解事件才再次滚到原文、显示 marks。

在 Part 5/9 Paused 时再次关闭末窗并重开，字幕与暂停状态保持，但等页面完成加载后仍停在文章顶部，没有重绘原有 marks。这是产品缺陷，M014 的视觉部分不能标记通过。定位为新 WebReaderBridge 在 `didInit=false` 时丢弃 VM 初始 Published 值，暂停后又没有新事件补绘。

新增四项真实 WKWebView 测试：暂停解读重建、关闭跟随时重建、暂停朗读词高亮重建、正文变更时禁止使用旧 mark 偏移。旧实现 **1 PASS、3 FAIL、0 SKIP**，缺少 marks/定位/当前词共五项断言失败，`visual-restoration-red.json` 保留。候选在相同段落重新映射后补绘当前模式的视觉状态；保留暂停、跟随关闭及供应商独立分页事务。双端相关回归和通用 Release 构建中，尚未以代码修复代替实际重放。


### 视觉恢复候选：回归通过，实际复验仍失败

第一轮候选相关回归为 Mac 112 PASS、iPad 110 PASS，均 0 FAIL、0 SKIP；证据 `visual-restoration-{mac,ios}-green.json`。通用 Release 构建及安装签名/夹具检查通过，主程序 SHA-256 `e839ca116253db7d0aa7a2e8f7eeb7f5206270699dc0a1a4e9e58cfec910c123`。

21:03 左右实际公开网页 Explain Part 4/8 已暂停、正文下划线可见；关闭末窗并重开后，同一进程保留字幕与暂停状态，但网页仍回到顶部、未重绘 marks。因此视觉恢复 **FAIL / 修复中**，不以绿色 WK 夹具回归覆盖真实失败。当前 Debug 增加仅模式/段落数量/差异索引/marks 数的日志辅助诊断；尚未取得足够诊断结果。用户随后指出首页工具栏比例与拥挤问题，先修该项。

### 用户截图反馈：首页工具栏（21:15 起）

复现加号套巨大底座、书架图标过大且与头像尺寸不一；Google Books/Kobo/WeRead 的 View all 沿用 iPad 44pt 内容高度，又叠加原生桌面按钮边距，明显高于 Kindle。候选将 Mac toolbar 内容放在统一托管横排，32pt 点击区域、8pt 间距，plus 16pt、书架线框 18pt、头像 24pt，iOS 26 Catalyst 隐藏额外共享背景。触屏入口保留原尺寸；Mac 书架链接采用原生紧凑高度。

首轮 Debug 安装后，首页三个入口打开/关闭与正常、半屏、短窗口视觉检查通过，iPad 隔离宿主编译通过。音色页共用入口实测暴露 `LibrarySourcesSheet.body` 第 27 行 `EnvironmentObject.error()` 崩溃；工具再次读窗口会重启应用，故不能把重新出现音色页当作正常点击。已保留脱敏崩溃摘要，候选显式为托管工具栏注入当前窗口 ReaderSceneContext 及其播放器上下文，正在复验。


### 首页工具栏与弹窗最终复验通过（21:34–21:37）

只给工具栏横排补环境仍会在 sheet 根部丢失 PlayerCoordinator，第二/三轮候选真实崩溃也保留，未计为通过。最终由调用方明确传当前 ReaderSceneContext 给书架/账号按钮，在两个 sheet 根部注入该 scene 及 `scene.player`；不使用全局 player 代替当前窗口。

最终 Debug 实际验证：首页加号→Quick Import→取消，书架→Library Sources→关闭，头像→Settings/当前 Pro→关闭均通过；音色页书架→已连接列表→滚动显示 Kobo/WeRead→关闭，再打开头像设置→关闭，进程保持 PID 70964，没有新增崩溃。正常 1024×768 窗口最终目测通过，此前同布局半屏与短窗口约 865×543 通过；最终已回到正常首页。按钮比例/间距统一，Google Books 的 View all 与 Kindle 同高度。

最终 Mac Debug build、iPad 隔离 build-for-testing、严格 bundle 签名/App Group、工程引用一致性及 diff 空白检查通过。仅该 UI/弹窗项记 PASS，不增加单测通过数量，也不表示 G13/全平台验收完成。当前安装为本地 Debug 1.2.47 (72)，身份及六份改动源码摘要见 `home-toolbar-accepted.json`；未提交商店或发布。


### 网页恢复的第二次定位与回归（21:39 起）

当前正常 Debug 公开网页在 Explain Part 2/9 Paused 时，关闭最后窗口再重开：进程 PID 70964 保持，字幕/暂停保留；诊断 `old=83 new=72 changed=[1,2,3,4,5,6,7,8] restore=false marks=3`。网页正文提取受到周边内容变化影响，不能要求整页数组完全相同，也不能把新的段落序号直接覆盖已经生成的音频/标注源坐标。

新增三个实际 WK 回归：周边段落增删后的暂停解读、暂停朗读、重复目标段落禁止猜测。前一候选实际 **1 PASS、2 FAIL、0 SKIP，9 项断言失败**，`web-remap-red.json`。修复为保留 VM 已生成内容的源段落编号，仅用完整文本相同且唯一匹配的段落建立原生源编号→DOM 编号别名；整页相同可按位置保留重复段落，内容变更/匹配歧义的段落不复用偏移。点击 DOM 段落也反向映射到源编号；商业书架继续独立分页流程。

双端七项 WK 重建专项均已通过，完整相关回归与通用 Release 构建仍在进行。源码摘要见 `web-remap-source-hashes.json`；仍需正常安装候选真实重放后才更新产品状态。


### 第二轮网页恢复候选最终通过范围（约 21:55–22:00）

相关回归 **Mac 115 PASS、iPad 113 PASS，均 0 FAIL、0 SKIP**，包含七项真实 WK 重建专项、原有 AO3/外观、SpeechPipeline 52 项、音频所有权和系统/账号边界。这是本轮各平台选择的数量，不与前轮重叠结果累加。测试后八份源码摘要与两个隔离宿主逐份一致。证据 `web-remap-{mac,ios}-green.json`。

通用 Release 1.2.47 (72) 已安装到正常应用路径，arm64/x86_64；主程序 SHA-256 `02d27a96609d2f39979e4ef8d4e190670da4605ce7c97b61b3e58c98db327b57`。严格签名、三组件明确 profile/App Group 通过；107 文件/54 测试标记无残留且 Debug 阳性对照通过。本机只实际运行 arm64，不据此宣称 Intel 真机验收。

正常 Release 使用既有公开网页：Read 真实播放→空格暂停，原文词 `gets` 高亮可见；关闭最后窗口并重新打开后，PID 74245 保持、Paused 保持，同一个词在正确原文段落可见，滚动返回当前阅读区域。随后 Explain 真实播放到 Part 5/8→空格暂停，正文 `No speaker labels` 高亮、会议讲座句子的高亮和 four-person panel 句子的下划线可见。再次关闭末窗重开，PID 74245 保持，Part 5/8、相同字幕和 Paused 保持，原标注在正确正文恢复，未退回页顶，也没有为恢复而自动播放。主动空格后恢复 Part 5/8 Playing。该公开网页的暂停 Read/Explain 视觉恢复记 PASS；不扩大到全部网站/来源的最终联合验收。

### 同一 Release 的工具栏最终复验

上述 Release 继续检查首页截图：加号没有巨大白色底座，线框书架与头像留有间距，Google Play Books 与 Kindle 的 View all 均为紧凑高度。首页加号打开 Quick Import 后取消、书架打开 Library Sources 后关闭、头像打开 Settings/当前 Pro 后关闭；再进入 Voice 分别打开书架与账号设置并关闭，均通过。全过程进程保持 PID 74245，没有新崩溃报告（最新历史报告仍为 21:30:45 的旧候选）。最终停留 Home，迷你播放器保持 Paused。此项是在最终 Release 的真实 UI 复验，不新增自动化用例数量。
