# Google Play 图书登录与同步修复交接

日期：2026-09-06。范围：登录、认证弹窗、书架扫描与账号隔离，以及正式首页、完整书架和阅读器入口。

**状态：本地完整链路验证已完成。** 相关轮次共 123 项不同原生／DOM 测试、4 个本地 UI 用例通过；合成 100 本正式首页链路和真实两书完整链路分别通过。最新包已安装回原模拟器，中文正式 Home 显示真实两本书，保留已授权登录。本轮未提交商店。

## 真实观察与原因

用户完成真实 Google 登录后，原生界面曾显示 0 本，而已稳定的网页实际有两本。该截图证明结果不符，但没有捕获首次扫描的完整时序，不能单凭截图确定唯一原因。

| 证据 | 确定的观察 | 能支持的结论 |
|---|---|---|
| [真实 DOM 结构](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/real-page-dom-shape.json) | 没有 `main`、`role=main/list/grid`；实际为 `gpb-library-home → gpb-shelf-page → gpb-volume-card → .card.ebook`，书名链接在 `.below-cover .metadata` 内 | 必须适配 Google 自定义元素；通用列表 fixture 不足以验证真实结构 |
| [旧 baseline 在稳定页面的结果](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/real-page-baseline-on-settled-document.json) | 识别两本书及书名、作者、封面，报告 complete | **旧卡片提取并非从未识别这两本书**；现场 0 本需结合加载与原生完成判定分析 |
| [本轮较早版本探测](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/real-page-before-surface-fix.json) | 已读到两书，但 surface=false、complete=false，封面为空 | 新增完整性校验曾漏认真实容器；过早选择 metadata 的普通 div 还丢失封面上下文 |
| [真实结构适配后探测](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/real-page-after-surface-fix.json) | 两书元数据齐全，surface=true、unknown=0、complete=true | 证明脚本可识别这张稳定真实页面；原生 Sync、首页、阅读与重启的独立验收见下表 |

真实书为 `b_40EQAAQBAJ`（The Enchanted Isles）和 `QrpAEQAAQBAJ`（Sasha's Secret Life），作者均为 Esa Myllylä。探测只保留结构与书籍元数据，不含邮箱、身份 hash、Cookie 或凭据。

另外确认了两类可复现的旧逻辑风险：

- **过早确认空书架。** 旧 native 在零卡片连续 10 次稳定后即可接受空快照，轮间固定等待 700ms；通用容器和页面 ready 并不能证明异步填充完成。如果书卡更晚出现，原生可能提前停止在 0 本。回归分别模拟静默空 DOM、延迟填充和明确空书架；这解释可执行风险，不冒充已完整捕获的现场时序。
- **跳过虚拟列表窗口。** 旧脚本最小滚动步长 520px，超过手机嵌套列表的可视高度；旧 native 另有 24 次扫描上限。已经离开 DOM 的书卡不会通过后续稳定计数自动补回。

## 当前修复

### 登录与窗口生命周期

[GoogleBooksLibraryViews.swift](/Users/xuxuheng/Documents/CastReader/CastReader/Views/GoogleBooks/GoogleBooksLibraryViews.swift) 改为网页与底部状态的真实上下布局。可见认证表单优先于残留账号菜单、书卡和普通说明；认证中及键盘出现时隐藏常规底栏。错误区域独立显示，顶部提供 Back、Reload 和关闭当前弹窗，白屏或认证失败后仍能恢复。

主页面和各层 popup 分别维护导航、已 commit 标记及生命周期。连接 generation、活动窗口、账号边界共同使旧 probe／scan 失效；被覆盖 opener 可以完成可信导航，不能覆盖当前弹窗 UI。关闭弹窗恢复上层页面；退休的 WKNavigation 保留对象引用，避免仅存 ObjectIdentifier 的地址复用问题。认证回跳标记只消费一次，防止不断重载尚未填充的书架。

补齐两处实际竞态：书架扫描开始后，旧登录 polling 不能并发执行会回到首屏的 sessionProbe，避免扫描中途被重置；用户取消 credential popup 时清除 didEnterCredentialFlow，不把关闭窗口误认为登录成功并触发 recoverShelf。相应真实 WKWebView 回归通过，最后的取消弹窗 UI 也已通过。

探测由当前文档 commit 后开始，依据可见表单、书架和 DOM 判断，不要求整个 WebView 停止加载。`WKWebView.isLoading` 仅辅助短白屏判断，另有总期限；无关图片或资源未完成不会永久阻止扫描。恢复保留当前 WebView 和持久 Cookie。

### 完整书架与账号提交

[GoogleBooksWebScripts.swift](/Users/xuxuheng/Documents/CastReader/CastReader/Services/GoogleBooksWebScripts.swift) 和 [GoogleBooksModels.swift](/Users/xuxuheng/Documents/CastReader/CastReader/Models/GoogleBooksModels.swift) 共同执行以下条件：

- 识别实际 gpb-shelf-page 和 gpb-volume-card，优先取完整 .card，再取书名、作者和封面；装饰性封面的 aria-hidden 不再被误当作不可用元数据。
- 区分“明确空书架”和“尚未识别”。只有可见、无冲突的 empty-state，且没有书卡候选、loading 或活动筛选，才提供 `hasExplicitEmptyShelf`。稳定零计数本身不能授权空同步。
- 可见但未解码的书卡进入 `unrecognizedBookCandidateCount`。脚本停在当前位置等待；原生记住未解决窗口，短暂空白或卡片被虚拟化移除不能解除限制。无法恢复时有界失败，不提交部分书架。
- 选择书卡最近的滚动容器，从首屏开始，用重叠视口步长采集；等待虚拟列表实际替换内容再滚动。native 监听 DOM mutation，等待渲染安静期并有超时兜底；完成仍依据遍历和 DOM 证据，不能用固定睡眠代替。
- Google 进度筛选已选中，或明确书架搜索框非空时，结果是子集，不允许报告完整或覆盖整个账号目录。未支持的分页同样拒绝 complete。
- 到达末尾仍需确认身份、内容和元数据稳定。有书书架至少 4 次稳定且 3 秒；明确空书架要求更长确认。扫描使用有界总期限，移除旧 24 次循环上限。

扫描绑定同一个 Google 身份；身份改变、认证丢失、跳过窗口或非法书籍使快照不可提交。Sync 前再次核对当前文档、账号和书架证据。[GoogleBooksLibraryStore.swift](/Users/xuxuheng/Documents/CastReader/CastReader/Services/GoogleBooksLibraryStore.swift) 还验证 storage boundary UUID；切账号、退出及 A→B→A 后旧任务不能写回。CastReader 账号边界和 Google 身份分别检查，无活动存储 scope 时不声称保存成功。

### 正式首页链路与调试隔离

验收走 `Home → Sources → Google Play Books → 原生 Sync → 关闭 Sources → Home → View All／逐本 Reader`。首页和完整书架共用正式 store；阅读经 GoogleBooksReaderLauncher → PlayerCoordinator → ReaderHostView。首页 rail 最多 8 本，完整书架按 24 本分批显示，总数需用来源状态、搜索和落盘 ID 验证。

首页父级 accessibility 使用 .contain 保留 View All 和书卡标识；完整书架显式展示导航搜索，并为 Mini Player 留出底部空间。先前一轮“搜索框不存在”实际停留在被系统评价提示覆盖的 Home：测试只识别并点击 Not Now，先确认已进入书架再验证搜索，未据该失败猜测搜索产品缺陷。

DEBUG login／blank／popup fixture 使用本地 HTML 和非持久 WebView，表单只做本地提交。100 本样本采用独立 `castreader.googlebooks.hundred-shelf-fixture.v1` suite，reset 只清该 suite。`-CastReaderGoogleBooksHomeValidation` 进入正式 Home／player 层并保留已授权网页 profile；真实验收不使用会切换 profile 的 `-CastReaderSkipSignInGate`。这些行为都需显式 DEBUG 参数，普通无参数启动仍走正式登录与账号存储。

## Kindle／Kobo 对照

沿用 Kindle 的完整书架去重、稳定结束判定、正式首页和 reader 链路；Google 的虚拟滚动与异步 DOM 必须单独适配，不能直接复制 Kobo 四页 HTML 当作 Google 兼容性证据。

登录 UI 和导航生命周期主要参照已经验证的 Kobo：真实布局、表单优先、可见恢复、每个窗口的导航边界和提交前账号核对。现有 Kindle 普通绑定页仍用受限行数的覆盖状态栏和顶栏 Sync，没有完整 Back／Reload／ClosePopup 工具栏，因此不机械复制全部界面。

## 复现与验证范围

| 层级 | 当前证据或验收要求 | 状态 |
|---|---|---|
| 稳定真实两书页面 | real-page JSON：两书、真实自定义容器及元数据 | 已取得 DOM 证据，不能代替原生验收 |
| 真实结构的合成 100 本 | 独立 macOS WKWebView，180px 视口、每次约 4 卡、40ms 异步替换；无通用 main/list 角色或 data-volume-id 捷径 | 记录旧版 **49/100、13 次且误报 complete**；新版 **100/100、43 次**。调度可改变旧版遗漏量和次数 |
| 原生单元／DOM | 认证优先、真实结构、明确空状态、unknown 原地恢复、活动筛选、账号切换、提交边界、popup／迟到导航／并发 polling | 跨相关轮次去重 **123 项通过**：基础 121 项，加新增 polling 和 popup 取消回归；最终 6 项 Recovery 全通过 |
| 本地登录 UI | 表单无遮挡与键盘输入、白屏错误可见与 Reload、native Sign In→popup→关闭 | 3 项通过；最终 Popup UI **20.022 秒**，其中取消回归单测 **3.145 秒** |
| 原生合成 100 本链路 | Sync 100→Home→View All→搜索 1/24/25/48/49/72/73/96/97/100→重启来源 100，核对唯一 ID | **80.653 秒通过**；与 100 个精确唯一 ID 的落盘结果对齐。与上行合计 4 个本地 UI 用例通过 |
| 已授权真实两书 | 原生 Sync 2→Home 精确两 ID→逐本真实 reader／正文／下一页不同 digest→重启 | 两次完整通过，分别 **79.954 秒、157.505 秒**；正文来自真实页面；测试未输入凭据，未断言 TTS 播放 |

独立复现输入和结果见 [报告目录](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/README.md) 和 [observed-results.json](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/observed-results.json)。早期通用 DOM 样本保存在 legacy-contract/，只支持滚动缺陷证据。[100 本落盘](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/ios-hundred-persistence.json) 记录精确 100 个唯一 ID、书名全部匹配；[真实两书落盘](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/ios-live-persistence.json) 与真实 Home／重启结果对应。原生验收汇总见 [ios-validation.json](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/ios-validation.json)。

测试产物：基础原生／DOM [final-regression.xcresult](/tmp/castreader-googlebooks-final-regression.xcresult)，100 本 UI [completion-regression.xcresult](/tmp/castreader-googlebooks-completion-regression.xcresult)，最终 6 项 Recovery 和 Popup UI [popup-final.xcresult](/tmp/castreader-googlebooks-popup-final.xcresult)，真实两书两轮 [authorized-live.xcresult](/tmp/castreader-googlebooks-authorized-live.xcresult)、[authorized-final.xcresult](/tmp/castreader-googlebooks-authorized-final.xcresult)。截图保存在 [screenshots](/Users/xuxuheng/Documents/CastReader/reports/googlebooks-login-sync-20260906/screenshots)，交付后的中文首页见 [当前 Home](/tmp/googlebooks-delivered-home.png)。

真实第二轮初次加载较慢，后来自动完成，没有手动点击网络 Retry。不能将该通过结果写成“已实际使用 Retry 恢复”或“真实加载无延迟”。测试已具备仅对明确网络错误点击一次原生 Retry 的有界分支及截图记录；这属于测试能力，与本轮实际执行路径分开。

在仓库根目录运行独立脚本复现；它使用非持久 macOS WebView，不参与真实账号：

```sh
sh reports/googlebooks-login-sync-20260906/run_reproduction.sh
```

使用当前 DEBUG 包展示样本。第二参数是专用 Google QA 模拟器，第三参数须指向本轮构建产物；login 可替换为 blank、popup 或 hundred，home／bind 走保留已授权 profile 的正式首页路径：

```sh
sh scripts/launch-googlebooks-shelf-fixture.sh login \
  5E6C9500-D581-413A-8D75-A8586AB3C60B \
  /path/to/Debug-iphonesimulator/CastReader.app
```

回归入口是 [GoogleBooksBindingUITests.swift](/Users/xuxuheng/Documents/CastReader/CastReaderUITests/GoogleBooksBindingUITests.swift) 中 4 个本地 UI 用例；默认运行跳过真实账号测试。真实验收须在专用 .xctestrun 的 UI runner EnvironmentVariables 显式设置 `CASTREADER_GOOGLE_BOOKS_LIVE_SYNC=1`，可选 `CASTREADER_GOOGLE_BOOKS_LIVE_VOLUME_IDS=b_40EQAAQBAJ,QrpAEQAAQBAJ`，单独选择 `testGoogleBooksAuthorizedLiveShelfSync`。

真实 reader 的 DEBUG readiness 为 `ready:<volumeID>:<正字数>:<digest>`。首屏最多等 90 秒；无文本时截图后至多做一次 Next／30 秒诊断，该分支仍记首屏失败，不能把后续可读当作首屏通过。正常翻页须取得同一书籍的新 digest。截图保留 ready、来源、Home、正文、翻页和重启结果。

**验收范围：已证明本地合成 100 本书架及已授权真实两书的完整链路；未据此宣称所有 Google 授权方式、真实大账号容量或无延迟加载均已验证。本轮未执行商店发布。**
