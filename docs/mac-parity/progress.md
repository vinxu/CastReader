# CastReader Mac 国际版实施进度

更新日期：2026-10-06。用户要求：以最新 iOS 国际版的源码、框架和全部功能为对照，每个大功能先实现、测试、验证同等功能和效果，再进入下一项。Mac 仅支持国际版本；不开发或验证 Mac 中国版。

## Kindle 加载反馈修复（2026-10-06）

用户反馈开书、点播放后没有加载标识。本轮将实际开书准备、播放前文档准备及等待首段语音接入可见转圈与本地化文字；Mini Player 同步等待状态并可暂停。提示使用 overlay，保持 Kindle 阅读区高度不变。显式暂停撤销未完成的启动意图，迟到结果不能自动开始播放。

定点回归 **15 通过 / 0 失败 / 0 跳过**；Debug 实际 Kindle 验证准备提示、播放、收起、Mini Player 准备状态及等待时暂停。Release 编译与主应用/两扩展签名、沙盒、App Group 检查通过；最终安装包实际确认 Opening、Preparing、加载中收起至 Mini Player 及取消后 Paused。已安装 **1.2.47 (72)**，可执行文件 SHA-256 `f176672a55beb1f3cb79da2d8fb2f9d98f1d49305a74d7d35464bb592e154392`。本轮改善等待反馈，未宣称服务端首音延迟已优化，也不扩展为全平台重新验收。

证据：[kindle-loading-20261006/acceptance.json](../../reports/mac-parity-20261004/kindle-loading-20261006/acceptance.json)。隔离测试启动的签名/配置问题与最终运行结果分开记录。

## 最新核心验收（2026-10-06，覆盖下方历史状态）

用户要求控制时间和 Token，只补核心闭环，O’Reilly N/A。最新正常 Release 已安装：1.2.47 (72)，SHA-256 `511c78de8c364590a86d926c2dbab82e2ca9d10494bfd4d6bcd8a7279d3d32d2`。签名、主应用与扩展 App Group 核验通过。

- **声音核心 PASS**：后端 PR #67 已受保护上线，生产 SHA `481dcce5d4b3a2fc333ca95d84c381d8e1eb61ff`，两个入口均支持 `macos: [global]`。私人 `Mac QA Calm Narrator` 已完成授权音频导入/截取、创建、改名、云端试听、Read 逐词高亮与 Explain 原文标注。试听本轮连续观察捕获 `Stop Preview`，关闭此前未确认项。英文 Heart、中文晓萱已恢复。
- **微信版式/试读收起恢复 PASS，登录态复验待完成**：实际根因是收起时导航高度变化触发网页重排。保留页在收起及展开动画时冻结尺寸，仅应用稳定后的可见尺寸。最终 Release 第一章真实试读暂停 Part 1/4，收起再展开保持正文、字幕、暂停位置及橙色圈注，显式继续正常播放。微信会话失效；已打开真实扫码入口并请求用户登录，登录后完整书籍分页/冷恢复尚未复验，不能将试读结果扩展为整组通过。
- **Mac 本地购买 PASS，正式商店交易待上架配置**：4 项 StoreKit 测试实际通过商品加载、有效 xcode 交易、恢复账号边界、失效权益。Catalyst 改用真实 `Product.purchase()` 测试路径，已不跳过购买。测试账本重置后同步客户端收据，消除了旧缓存造成的失效断言失败。无真实扣款、无生产服务端入账结论。ASC 只读查询仍无 Mac 版本记录。
- **YouTube 新提取 BLOCKED_PROVIDER**：正常 Release 对未缓存 `NHHPNMIK-fY` 单次重试，UI 明确显示官方字幕访问临时限流，取消正常；不重复循环、不将缓存字幕算通过。
- 最终定点窗口与购买回归 **7 通过 / 0 失败 / 0 跳过**。继承文件/网页、Kindle/Kobo/Google 的既有核心通过证据，不重新扩展长测及全量矩阵。

**全部验收仍未完成**：实时平台还剩微信登录态末次复验、YouTube 新提取；正式 Mac 商店支付另属发布阶段待验证。

本轮总表与可复核证据：[core-convergence-20261006/README.md](../../reports/mac-parity-20261004/core-convergence-20261006/README.md)。先前证据保留于 `weread-desktop-density/`。

## 当前执行范围：核心收敛（2026-10-05，用户最新指示）

用户要求减少时间与 Token 消耗，先跑通核心、处理阻断问题。**O’Reilly 本轮 N/A，不再测试或等待账号**；不因此立即删除现有入口。原 145 项及下方全量盘点保留为后续清单，不再作为本轮完成门槛。

本轮仅处理：当前账号/Pro 正常进入；PDF/EPUB/DOCX/文本/网页导入后 Read/Explain；已连接书架打开/翻页/继续听；暂停/重开位置与高亮/标注、多窗口不叠音；Mac 消费现有同步书架。已有真实通过证据直接继承，修改影响到的部分才复验。

不新增全量矩阵、不重复 30/60/120 分钟长测、不为盘点重跑几百项套件。每个确认的核心缺陷只做定点修复、必要回归与一次正常包复验。外部账号/来源验证/StoreKit 环境不循环尝试；装饰性 UI、Widget/提醒、额外硬件组合、完整音色创建/购买生命周期、六方向冲突矩阵后置。账号权益错误、数据丢失/串号、导入或播放失败、崩溃、恢复位置错误仍须修复。

| 核心项 | 当前依据与有限动作 |
| --- | --- |
| 当前账号/Pro | 正常 Release 登录、权益、冷启动通过；继承 |
| 文件/网页 Read/Explain | PDF、DOCX/Drive、文本、网页已有闭环；EPUB 小样本本轮已补实测通过 |
| Kindle/Kobo/Google | 已有长测/恢复通过；不重复 |
| 微信/YouTube | 微信试读、YouTube 缓存字幕可用；内嵌微信登录限读、新视频官方验证分别保留外部阻塞，不宣称通过 |
| 位置/高亮/窗口 | 当前 Release 暂停重开、marks、主动续播、单一播放器与工具栏已实测；继承 |
| 书架同步消费 | 四书源在 Mac 可见且已有打开证据；六方向精确同步/冲突后置，不冒称已通过 |

收敛执行结果：沿用当前 Release 1.2.47（72）、SHA-256 `02d27a96609d2f39979e4ef8d4e190670da4605ce7c97b61b3e58c98db327b57`，只补 EPUB `Illustration preservation`。文库重开图文完整；Read 推进至末段，观察到 RETURN/illustration 词高亮；Explain 实际 Part 1/3→3/3，标题/图注圈注和正文高亮可见。另在 Part 2/3 暂停关窗，重开保留同字幕、暂停与原文 marks，显式继续仍是 Part 2/3，最终 Explanation complete。进程保持 PID 74245，最后回到 Home、迷你播放器 Finished。未发现新的核心阻断、未改产品源码、未重建/重跑全套。证据 [core-convergence-20261005.json](../../reports/mac-parity-20261004/core-convergence-20261005.json)。本轮核心范围完成收口；微信/YouTube 来源限制与 Mac StoreKit/后端音色依赖继续明确保留，不计全部产品/发布验收通过。

## 历史全量验收盘点（2026-10-05，已由上方核心范围收敛）

**全部测试和验收尚未完成。当前是主要功能已有可运行候选、多个核心流程通过，但仍有重要产品流程未完成实测的状态。** 下文按时间追加的历史记录保留原始失败和待验状态；判断当前结论应结合本节及各阶段报告的最后一次有效结果。

16 个阶段的状态统计：G00 静态盘点完成、G01 本机基础通过，共 2 个；G06/G08/G09/G11 核心范围通过，共 4 个；G02/G03/G04/G05/G07/G10/G12/G13 部分验证，共 8 个；G14 跨端联验与 G15 最终联合验收尚未完成整组执行，共 2 个。阶段大小不同，这个统计不能换算成工作量完成率，也不能把 CORE_PASS 当作整项最终验收。

四个书源与四个客户端分别统计：Kindle、Kobo、Google Play Books 已有各自至少 30 分钟 Read 和 15 分钟 Explain 的真实核心证据；微信读书目前只有约 18 分钟 Read，完整长测被内嵌登录/限读挡住。Mac/iPhone/iPad/Safari 四客户端之间的双向文件、书架、进度与冲突验收尚未关闭；用户完成同步实现，不等于助手已完成其产品验收。

### 剩余工作包与完成条件

| 工作包 | 已有证据 | 仍须完成 | 当前依赖/下一动作 |
| --- | --- | --- | --- |
| R01 文件、阅读与云盘边界（G03/G04/G11） | 混合 PDF 4 页/17 段 Read/Explain；图文 EPUB/目录；中英 DOCX；TXT/Markdown；中英图片 OCR；当前 Drive TXT/Docs 导出完整播放与冷恢复 | 复杂 PDF 与缩放定位、长篇 EPUB 深章冷恢复、Office/编码/大小限制、实际多文件拖放/取消/失效恢复；基础/社区/私人声音×Read/Explain；云盘新授权/换账号/远端版本变化/撤权/删除；相机实际多页拍摄/OCR | 可先用公开或合成样本补齐文件和网络边界；真实授权、现场拍摄与可改动远端样本单列。现有摄像头许可仅本地预览 |
| R02 音色创建与管理（G05） | 搜索/试听/正文应用；短音频/静音拒绝；合成语音片段裁剪预览；420 项已有合同 | 实际录音/导入授权样本→创建→正文使用→管理/分享/撤回的完整流程，失败恢复和扣费 | Mac `macos` 平台后端配套仍未发布，线上部分 voice consent/analytics 合同不接纳；需要合法测试音色样本及对应麦克风权限。不能以当前目录/试听通过代替创建通过 |
| R03 未闭合书源与网页（G07/G10，及 G06/G08/G09 边界） | Kindle/Kobo/Google 核心长测；微信部分翻页；普通网页 Read/Explain；YouTube 缓存字幕中英切换与冷恢复；O’Reilly 入口 | 微信登录后 ≥30 分钟 Read、≥15 分钟 Explain 与重新登录恢复；O’Reilly 实际书架/书籍闭环；YouTube 新视频字幕提取；特殊网页/源内容变化；三项已过书源的重绑/账号失效/不可读内容与最终候选差异回归 | 微信内嵌扫码、O’Reilly 可用授权账号；YouTube 官方验证限制仍存在，Safari 可播放不能证明应用提取会话已通过 |
| R04 账号、Pro 与额度（G02/G12） | 当前账号/Pro 冷启动恢复；真实恢复购买 UI；九语设置/偏好持久化；iPad 本地购买/账本 | Apple/邮箱完整登录，Google 重新授权/取消，A/B 账号在途切换；免费账号限额/午夜和失败场景；Mac 购买/取消/待处理/退款/恢复及克隆余额端到端 | 需要适合切换的独立测试账号和可用 Mac StoreKit 环境；当前 Mac SKTestSession 返回 505、未获取产品。iPad 通过不能替代 Mac 购买；现有 Pro 不证明新购买授予成功 |
| R05 四客户端同步与 Safari 协作（G14/G13） | Mac 能消费已同步的四书源；Finder/Safari 系统分享、冷/热 Inbox、原网页 Read/Explain 通过 | Mac↔iPhone、Mac↔iPad、Mac↔Safari 六个方向；文件可用性、真实停止点、离线重连/冲突/显式回退/删除不复活/切账号；Safari 播放位置移交和账号/权益一致 | 核对四端候选与支持协议、使用同一测试账号逐向执行；iPhone 镜像上次提示设备正在使用。旧 Safari 独立账号/Stripe 路径尚未完成同账号证明；分享 URL 不是精确续播移交 |
| R06 Mac 系统和硬件行为（G13） | 多窗口音频所有权、播放窗关闭移交、暂停网页关窗重开视觉恢复、快捷指令三动作、首页/Voice 工具栏弹窗 | Widget 实际添加/点击、提醒实际送达/点击、物理媒体键、耳机/蓝牙切换、睡眠唤醒、跨显示器/缩放 | 电脑工具的系统面板/媒体键覆盖有限，需可操作硬件路径或人工辅助；空格键不能替代系统媒体键结论 |
| R07 最终质量矩阵（G15） | 分模块源码回归、多个长读样本、九语设置和部分键盘 UI；本机 Apple silicon/macOS 26.2 | 固定样本至少 20 次冷启动/首音等 p50/p95、EPUB/PDF 各 60 分钟和高风险来源 2 小时、20 次开关资源趋势、网络/故障/迁移、VoiceOver/纯键盘/全流程九语、最低系统/低内存机器；Intel 仅在决定声明支持时真机验收 | 可先做本机测量和合成故障；需要补齐支持系统/硬件。Google 冷 Explain 首音约 43.8 秒及队列等待仍是性能项；阈值须按总规划冻结，不把建议值当作已经通过 |
| R08 候选冻结与用户验收（G15） | 当前开发签名通用 Release 构建、严格签名、无测试夹具残留、本机安装运行通过 | 将 145 条标准逐项挂到有效证据/状态，按源码差异继承早期结果并跑最终组合；干净安装/升级/数据迁移；用户 U01–U12 操作验收；分发前另验商店候选及审核路径 | 当前 Release 仅指编译配置，不是已完成分发/商店提交。用户本次仅要求盘点；未触发发布或提交审核 |

### 已知未关闭观察，不混入通过结论

- Upload Image 从 Go To Folder 首次选择曾停滞，后续从目录直接选择成功；间歇问题尚未定因。
- 设置冷启动后首次激活曾滚回顶部一次；尚未完成隔离复现。
- Google Read/Explain 交替后冷位置策略仍单列；同模式精确恢复通过不能覆盖该策略。
- YouTube 中文当前仅确认按字幕段高亮，未确认逐词高亮；这与共享质量门回退有关，不能写成两种精度都通过。
- Kobo 可选书末推荐弹窗的尺寸修复有 WK 回归，缺修复后的实际弹窗复验；WebKit 辅助功能点击引起的历史崩溃有记录，普通指针路径通过不代表 VoiceOver 通过。
- 测试产生的临时偏好需在收尾核对：WeRead 字号原 1、测试改 3；英文首选原 Heart、测试改 Bella。现有记录尚未证明这两项已恢复。

### 收口顺序与统计口径

先建立最终逐项执行状态、补齐无需外部条件的文件/核心/故障/键盘/性能检查；获得依赖后依次关闭书源、声音/购买和四端同步；最后对同一候选执行组合回归及用户 U01–U12。每个大功能仍按修复→影响范围回归→正常包真实复验关闭，外部阻塞仅允许继续独立工作，不能将其标为通过。

当前 145 条矩阵是验收标准，尚不是 145 条均有最终执行状态的结果表，不能据此给出精确“还剩 N 条”或百分比。各轮 420、246、158、115 等自动化结果包含重叠；最新网页恢复影响范围为 Mac 115/iPad 113 均零失败零跳过，也不代表整项目全通过。尚未进行完整最终硬件/来源/声音/网络组合，因此不承诺没有新缺陷或固定完成日。

主要依据：[功能清单](feature-parity.md)、[145 条验收标准](../CastReader-Mac-Acceptance-Matrix-2026-10-04.md)、[本地文件/阅读](../../reports/mac-parity-20261004/G03-G04-live-validation.md)、[账号](G02-auth-acceptance.md)、[权益/StoreKit](../../reports/mac-parity-20261004/G12-settings-entitlements-validation.md)、[系统/最新 Release](../../reports/mac-parity-20261004/G13-system-integration.md)及各书源、YouTube、O’Reilly、Drive 阶段报告的最后有效结果。

## 基线

- 已拉取 `origin/main`，当前为 `09456f1979cc14ca19977ede4b1edde043c5f840`。
- 最新参考发布记录为 iOS 1.2.47 Build 72，记录 2026-10-03 已提交审核；不据此宣称今天已上架。
- 独立工作树：`/Users/xuxuheng/.codex/worktrees/castreader-mac-parity/CastReader`，分支 `codex/mac-parity`。
- `bash scripts/build-voice-toc-integration.sh --check` 已通过，保留所有必需发布祖先。
- 本机：Apple silicon、macOS 26.2、Xcode 26.6；没有最旧支持系统的验证结果。
- Mac 应用 target 直接引用 iOS 应用的 228 个源码文件和 14 项资源；不复制阅读/账号/书源主干。独立 target 嵌入原生 MacShare/MacWidget，保持 iOS 扩展 target 不变；Safari 继续保留独立宿主，另验协作。

## 顺序和通过标准

| 阶段 | 范围 | 状态 | 进入下一阶段的条件 |
| --- | --- | --- | --- |
| G00 | 源码/功能盘点和基线 | 已完成静态盘点 | 基线门禁、源码资源清单、功能对齐表齐备 |
| G01 | Mac 工程、运行、国际版本约束、启动与窗口基础 | PASS（本机范围） | Debug/Release 构建；真实 Mac 安装启动；国际登录页；国际路由与不影响 iOS 的回归；测试宿主隔离 |
| G02 | 国际账号登录、会话持久化、退出和恢复 | 当前账号登录/重开 PASS；其他真实账号场景留待联合验收 | Google/Apple/邮箱入口与 iOS 同合同；真实登录重开和切账号不串数据 |
| G03 | 本地文档导入与展示 | IN_PROGRESS | PDF/EPUB/DOCX/文本/图片的真实输入、显示、目录和重开，与 iOS 样本对照 |
| G04 | 朗读和解读核心 | IN_PROGRESS（PDF/Markdown 真实闭环已验证） | 真实国际服务音频、高亮/滚动、原文 marks、切模式/声音/暂停/恢复通过 |
| G05 | 音色发现、创建、上传、管理与分享 | IN_PROGRESS（搜索/试听/正文应用、420 项合同通过） | 全部现行 iOS 音色入口和状态通过实际流程，不能以试听代替正文 |
| G06 | Kindle 在线及离线 | 核心流程 PASS；真实重绑/未购书与最终 Release 留待联验 | 书架、实书翻页/续播、离线保存/OCR/系统声音对齐 |
| G07 | 微信读书 | IN_PROGRESS（实书 24 次分页；长时阅读遇官方登录限读；UI/预取修复实测及双端各 48 项回归通过） | 登录、书架、双栏/分页、Read/Explain、重开恢复对齐 |
| G08 | Kobo | CORE_PASS | 30 分钟 Read、15 分钟 Explain、两本真书、主题/字号/重排、冷恢复、书尾切模式及小窗口目录已验；不同账号和 WebKit AX 限制保留 |
| G09 | Google Play Books | CORE_PASS（31 分钟 Read；修复后 Explain 实播音频 933.44 秒、22 次自动翻页；两本书、重排、冷恢复、加载提示和书尾已验） | 真实书架、Read/Explain、窗口和恢复效果对齐 |
| G10 | O’Reilly、YouTube、普通/特殊网页 | IN_PROGRESS（普通网页 Read/Explain 实测通过） | 既有国际版所有入口、字幕选择和网页提取/恢复对齐 |
| G11 | 云盘导入 | CORE_PASS（当前账号；TXT/DOCX、完整 Read/Explain、重读、冷恢复与最终 Release 界面；Mac/iPad 各 158 项回归通过） | 与已发布 iOS target 一致的 Google Drive 真实闭环与权限/版本失效恢复；Dropbox/OneDrive 未编入基线产品，另列未来扩展 |
| G12 | Pro、免费额度、克隆额度购买与设置 | IN_PROGRESS（九语设置/持久化/小窗口/当前 Pro 恢复 UI 已验；iPad 99 PASS＋独立克隆额度 9 PASS，Mac 96 PASS + 3 StoreKit SKIP；通用 Release 已验；Mac 克隆购买受 StoreKit 505 阻塞） | 当前服务端权益合同、沙盒购买/恢复、账本、九语设置流程通过 |
| G13 | 多窗口、菜单、系统入口和 Safari 协作 | IN_PROGRESS（快捷指令三动作、窗口移交与 Finder 分享已验；最终 Release 的 Safari 冷/热分享、Read/Explain/重播/空格暂停通过；相关 Mac 83、iPad 81 项全通过；末窗重建的网页标注/词高亮丢失已修复，第二轮 Mac 115/iPad 113 项回归及正常 Release 真实重开通过；首页工具栏比例/间距与弹窗上下文已修复并实测；Widget、媒体键、提醒及 Safari 账号协作待验） | 多窗口音频所有权、分享/快捷指令/Widget 的 Mac 适配、旧 Safari 共存与移交通过 |
| G14 | 用户负责的书架同步结果联验 | 待联验（不重复实现） | 用户已确认书架同步完成；验证 Mac 消费结果、账号隔离和跨设备对应行为，以实际证据为准 |
| G15 | 联合回归和最终验收 | NOT_STARTED | 完整矩阵、可访问性、性能、数据迁移、最终包身份与用户验收 |

编译通过只证明兼容性，不把任何 G02–G15 标成已通过。后续若缺少账号/样本/硬件，记录具体 BLOCKED 项；不以 mock 通过替代实测。用户已于 2026-10-05 确认四个书架的接入/同步全部完成，真实 Mac 首页已逐一可见，助手按 Kindle→WeRead→Kobo→Google Play Books 顺序验收并适配；等待其他账号、云盘或硬件的验收项明确保留，不阻塞独立功能实现。

## 本轮实现记录

1. 新增 Mac Catalyst target/scheme 和幂等工程同步脚本，来源引用保持与 iOS 一致。
2. Mac 区域与服务路由固定为 Global，忽略时区、CHN storefront、旧覆盖值和测试 CN 参数；iOS 继续使用原规则。
3. 已读取并复用本项目的本机构建配置，文件保持忽略和 0600，不输出或提交配置值。
4. Debug 与 Release 均已成功签名编译并实际启动；Release 首次生成 arm64/x86_64 双架构，最低系统解析为 macOS 14.6。Intel 与最低系统没有真机通过结论。
5. 国际版约束单测 8/8 通过；iOS 原有区域/路由回归 128 通过、0 失败、1 项真实九语音频测试按原规则跳过（留在 G04）。
6. 实际对照同基线 iPad 登录页，修复 Catalyst 多余按钮边框及 `.mac` 被误当作手机导致小窗口裁切的问题。已验证约 520 × 372 点窗口可滚动至邮箱、条款和隐私入口；普通/最大化窗口均正常。
7. 窗口修正后的最终 Release（arm64/x86_64）构建、签名核验及真实启动通过；最终源码隔离测试再次 8/8 通过。G01 在本机范围验收通过，进入 G02；已请求用户在独立 Mac 应用中登录现有国际版测试账号。详细证据见 `reports/mac-parity-20261004/G01-validation.md`。

证据：`reports/mac-parity-20261004/`。功能来源详见[功能对齐清单](feature-parity.md)。

## G02 当前门禁

Mac 已直接复用并执行 10 项现有 iOS 会话/凭据合同；连同 8 项国际版本合同，共 18 通过、0 失败、0 跳过。用户已在真实 Mac Release 包登录。已实测进入首页、显示当前账号及 Pro 月订阅；⌘Q 正常退出后重新启动，进程从 60195 变为 62820，账号与权益持续有效，没有重复登录墙。没有输出或移植凭据。其他登录供应商、真实 A/B 账号与网络失效场景保留到联合验收，不能宣称全覆盖。按用户最新要求继续 G03 和独立适配。细项见 [G02 账号验收](G02-auth-acceptance.md)。

## Mac 平台身份服务端配套（待发布，不计线上通过）

Mac 客户端使用 `macos` 平台身份。当前线上仍会拒绝该平台的部分 analytics/voice consent 合同；Core Read/Explain 和当前账号 Pro 已实测，但不能据此标记 Mac 音色创建线上闭环通过。

配套后端工作树 `/Users/xuxuheng/Documents/.worktrees/readout-web-mac-platform-20261005` 基于 `0564e38bd937f138e333897fb0f24373dbd12bc9`，新增 Mac 平台的事件/漏斗/身份/QuickRead header/音色授权来源及能力声明，Mac 能力仅列 Global。数据库迁移只扩展两项平台 CHECK 并新增索引，保留既有数据与旧索引。

验证：初次合同 173 PASS、1 SKIP；后续影响范围 146 PASS、1 SKIP；能力/音色合同 31 PASS；TypeScript 全量检查通过（先生成项目所需 MDX 索引）。独立本地 PostgreSQL 验证迁移重复执行、旧记录保留、非法平台拒绝、索引有效和失败事务回滚通过。各轮范围重叠，不相加为独立用例数。证据在 `reports/mac-parity-20261004/backend-macos-compatibility/`。

尚未部署或修改生产数据库。该后端仓库的 `docs/contracts/voice-clone-cross-platform-v3.md` 要求生产源为受保护 beta tip、先探测再推广同一产物；后续按此门禁发布后，才能完成相关 Mac 真实服务验收。

## G06 窄窗边界追加（2026-10-05 03:35）

Kindle 真实长解读先后发现并修复重排锚点搜索范围不足、已讲解页面的极短余文无法重新建讲解两处问题；新候选继续复测，不能用先前 30 分钟朗读通过代替解读通过。隔离真实 Amazon 未登录重定向已验证超时收敛与大小窗口提示，并修复遮罩下 WKWebView 登录输入框仍暴露给辅助功能的问题。详细证据与待验项见 G06 报告。

## G06 核心验收通过，进入 G07（2026-10-05）

最新整合 Debug 包签名校验通过，重开 Kindle 的位置选择弹窗可操作、加载遮罩正常释放，Bella 1x 真实播放及词级高亮正常。长朗读确认跨度 1815 秒；修复后长解读确认跨度 982.376 秒、40 次不同目标自动翻页、跨 CHAPTER 16，覆盖大小窗口反复重排。原来 32 字符余文的失败页另行精确复演通过。相关日志、失败证据及范围限制保留在 G06 报告。

WeRead 共享消费回归初轮 Mac 为 25 通过、3 恢复检查点用例失败，同组 iOS 28 通过；补齐真实 UIWindowScene 和替换文档加载等待后，三项仍在 Mac 失败、iOS 通过。正定位差异，尚不能归因为产品缺陷或夹具缺陷，不能写成微信读书已通过。

## G07 分页修复与实际限读（2026-10-05 04:40）

上述恢复失败已确认是替换页 CSS 与首屏夹具不一致：Mac 单行 root 高度 19px，未达到既有 20px 有效提取阈值。补齐相同 CSS 后通过，生产阈值未改。真实封面/推荐页发现原生分页 didInit 门禁、无正文页手动意图不释放、native snapshot 未 ready 三处适配问题，已修复并实际复验；相关 WKWebView 回归 Mac/iOS 各 30 项通过，另封面准备套件各 13 项通过。

《老人与海》04:19:32.752–04:37:26.875 有持续实际播放事件，跨度 1074.123 秒，24 次确认页面提交、13 次连续音频交接、5 次跨页余句承接，自然进入第二章。覆盖 1024/523/1376 点宽窗口、双栏、字号 1→3、收起/展开。04:37:30.434 官方显示“试读结束／登录后继续”，清空播放与预取；30 分钟门禁未满足，保留为 BLOCKED_BY_PROVIDER_ACCESS_GATE。同步书架存在不证明内嵌会话已认证。

另补 Mac 扫码指引九语，以及 Esc 优先关闭当前窗口微信字体面板的适配；新候选测试和 UI 复验完成后更新结果。详情见 G07 报告及 `g07-long-read/result.json`。

## G08 Kobo implementation and live verification (2026-10-05 08:40 CST)

G07 remains blocked only for the authenticated long-run cases; the user has been asked to scan the embedded WeRead login. Its shelf exists, but that does not authenticate the reader. Work continued with independently testable Kobo cases.

Kobo library: synced five books, search/empty result, title/author/recent sorting and the sync completion/close UI verified. Reader fixes cover official next-page priority at odd chapter tails, direct native spread bookmarks, provider-font refresh detection, pending and carried audio resume during repeated reflow, retention of newly exposed unread suffixes, and provider settings clicks retargeted to HTML/shadow DOM. Each defect has targeted failing-then-passing regression evidence. Relevant shared integration suites passed on both Mac and iPad; exact selections and exclusions are in `reports/mac-parity-20261004/g08-kobo-contracts/`.

Latest issue was invisible word highlighting under provider dark themes. The computed background was transparent despite live word rectangles. The overlay now preserves its own accent paint and uses normal alpha compositing. Four-theme WKWebView coverage failed before the fix and passed after it. Mac 9/9 and iPad 9/9 related regressions passed; the first iPad result was incomplete because disk filled while writing xcresult, and a separate `ios-theme-green2.xcresult` successfully records the rerun. Only this task's regenerable build caches were removed.

Real gray, black, sepia and white themes now show visible word highlights, including words split across lines. Playback continued through theme changes and a 1024-to-1728 point width change into Chapter Three. A fresh sustained Read run started at 08:32:07.960. It is IN_PROGRESS, not a 30-minute pass yet. Earlier failing runs remain failures. Explain 15 minutes, direct checkpoint recovery from a mismatched provider page/different layout, and the remaining UI cases are still open. One same-window, source-matching cold resume passed with about 24 ms audio-clock difference; that narrower result does not establish general recovery.

Canonical detail: `reports/mac-parity-20261004/G08-Kobo-live-validation.md`. G09 Google Play Books acceptance started after the G08 core gate passed at 11:50.

### G08 long Read result (09:03 CST)

The theme candidate completed 1834.953 seconds with 40 unique automatic page commits, 19 cross-page carry commits and no stuck/repeated automatic turn. All 40 presentation holds released (median 330.77 ms, max 599.79 ms). Ten zero-overlay word events remain disclosed: nine during layout/font transitions and one isolated event, with no sustained loss. The 800×600 floating-control overlap is fixed in source and passed related Mac/iPad suites (20 each), but the corrected normal app still needs actual UI verification. Direct cold recovery from a deliberately different provider chapter and 15-minute Explain are next. This closes the duration/page-count portion of M066, not the whole G08 gate.

### G08 restore follow-up (10:05 CST)

Actual 800×600 verification confirms reserved desktop playback controls no longer cover text. Direct native cold recovery from Chapter Two to the saved Chapter Five source passed after requiring settled pagination and requesting one initial layout when needed. Final related Mac/iPad selections passed 28/28 each.

Paused shrink tests exposed two separate defects: an AVPlayer artificial page endpoint behind the restored seek (fixed; 136/136 related tests on each platform), and a visual boundary bound to a skipped earlier audio segment (new regression reproduced failure, then passed on Mac/iPad after rebinding to the verified restored segment). Broader regression and actual replay are in progress. Do not treat the earlier long Read pass as coverage of these new resume cases. Full evidence and limitations remain in the G08 report.

The boundary retargeting candidate passed 230/230 shared tests on Mac and iPad. Actual provider replay confirmed the old endpoint now releases into visible original words and reaches the real item end. A later audio part still required another Play because its producer retained an old paused intent; two new failing tests reproduced this, then the fix passed 123/123 resume/streaming/ownership tests on each platform. Latest normal candidate is being replayed before G08 acceptance.

### G08 terminal and caption follow-up (11:10 CST)

Later-segment paused-shrink replay passed in the actual provider. The latest normal candidate completed 929.685 seconds of Explain across Chapters Five–Seven, with 35 unique automatic commits and no detected turn/presentation failures. Four themes and 800×600/1024×768 were checked; font/background returned to 7/white.

A separate final-chapter Explain reached the confirmed book end. Switching to Read then exposed a stale terminal-turn gate that timed out after speaking the final page. A real WK/AVPlayer regression reproduced three assertions on the old implementation; the fix completes each new queue's terminal hold without another physical turn. Two targeted cases passed in `mac-book-end-green2.xcresult`. The first replay-test attempt used `start()` on an already finished VM and never initiated another queue; its false-positive check was tightened, then its action corrected to the actual paragraph restart `jump(to: 0)`. Earlier red/green results are retained.

The small Kobo contents panel was visually covered by the paused native caption. The candidate reports visible-dialog transitions through the authenticated current frame and suppresses only the caption until the panel closes. Mac/iPad pagination, bridge, source-access and appearance integration suites are running. Both changes still require actual-provider verification in the rebuilt normal app.

## G08 核心门禁完成，进入 G09（2026-10-05 11:50）

书尾模式切换、无音频检查点冷启动分页和小窗口字幕遮挡均完成真实复验。最终新增影响范围 Mac/iPad 各 50/50 通过。第二册真实书验证跨页 Read/Explain、单栏/双栏及冷恢复通过。详细结果和限制以 G08 报告最后一节为准；跨账号、系统 AX 交互限制与全部发布门禁未被计为完成。


## G09 核心门禁完成，继续 G10（2026-10-05 16:10）

Google 双页解读发现的标注定位/自动续讲翻页竞态已修复；三项真实 WKWebView 回归先失败后通过，最终影响范围 Mac/iPad 各 163 PASS、0 FAIL、1 项原有网络 opt-in SKIP。实际新长测跨度 1011.180 秒、完整播放音频 933.44 秒、22 次不同目标自动翻页，覆盖缩窗、主题、收起/展开和自动排版恢复，未出现分页超时或提前结束。结合 1857.509 秒 Read、两本真书、精确冷恢复与书尾，G09 核心验收通过。跨账号、混合模式冷定位策略、冷生成等待和最终发布仍单列。冻结证据及限制见 G09 报告。


## G10 YouTube 适配继续（2026-10-05 16:54）

修复官方播放器覆盖按钮延迟出现时过早消耗单次初始化机会的问题；两项可执行 JS 回归先失败后通过。校正隔离宿主的公开 Embed origin 和漏选的十个模型测试类后，Mac/iPad 各 246 PASS、0 FAIL、1 项 opt-in 网络 SKIP。正常包新视频仍在约 12 秒后收到 YouTube 官方验证限制，准确提示并可取消，未把网络限制计为成功。

缓存视频中英字幕/声音切换、英文逐词高亮、大小窗口布局、暂停重开和真实续播已验；冷恢复音频偏差约 16 毫秒。中文当前按现行质量门回退到 segment 高亮，不计为中文逐词通过。生产基线仅缓存字幕和图像，音频需在线生成。另修复 Mac 滚轮浏览不显示“回到当前位置”的问题，正常包在暂停/播放和 800×600/1024×768 均复验通过，追加双端回归各 246 PASS、0 FAIL、1 opt-in SKIP。详情见 G10 报告。


### G10 O’Reilly 入口适配（2026-10-05）

真实官方个人登录页可打开；当前 O’Reilly 未连接。修复 Mac 连接说明被底部卡片覆盖、窄工具栏关闭文字截断，以及嵌套面板登录方式菜单无响应的问题。实际机构表单、无效 URL 本地拒绝、逐层取消、Mac 选项弹窗进入机构表单均通过。相关 O’Reilly/外观回归 Mac/iPad 各 33 PASS，无失败或跳过。真实书架/朗读/解读/恢复仍依赖可用账号，不以入口与夹具结果替代。


## G11 云盘闭环与共享重读修复（2026-10-05 17:55）

现有授权下真实 Google Drive 浏览、搜索/空结果、文件夹、格式拒绝、TXT 下载导入通过；26 段 TXT 完整朗读与八段真实解读自然完成。Google Docs 按 iOS 合同自动导出 DOCX，14 段包含列表、重复段落和导出标签页的正文完整读完。修复云盘三处九语漏译（100 个字面键无缺项、27 个新增翻译均已编入包）。

正文完成后播放按钮及迷你播放器不能重读的问题，新增真实 AVPlayer 用例在 Mac/iPad 各复现两项失败。修复后同一选择合计两端各 158 PASS，无失败或跳过；iPad 其中 20 项云盘导入测试补登记在隔离宿主后单独执行，未修改生产 iOS target。正常包正文重读完整走完 0–13 段，迷你播放器亦从首段开始。第 11 段中途暂停→关闭→退出→云盘历史冷重开保持暂停，首次播放恢复时钟较保存位置差约 32ms，后续自然完成。

账号菜单和数据说明可打开、滚动并完成返回，最后一处 Mac 设备图标与全部修复正在整合通用 Release。新授权、异账号、外部改版/撤权仍只保留合同覆盖，不冒充真实通过。详情见 G11 报告与冻结事件。

真机条件更新：iPhone/iPad 均已连上，安装版本元数据均为 1.2.47（72）；这不是源码基线证明，也没有覆盖安装。iPhone 镜像提示设备正在使用，已请用户方便时锁屏供联验，继续独立 Mac 工作。

### G11 Release 收尾完成，继续 G12

通用 Release 真启动、严格签名、无测试夹具残留通过；实测英文云盘搜索、Mac 设备图标、完整数据说明滚动与 Done 返回首页通过。G11 当前账号核心门禁关闭，未把新授权/异账号/撤权和远端改版计为完成。开始 G12 设置、权益展示与交互验收。

### G13 暂停网页的末窗重开与工具栏复验（2026-10-05）

最终本地 Release 1.2.47（72）实测：暂停 Read 后关闭最后窗口再重开，保留暂停、当前词高亮和原文阅读区域；暂停 Explain 后同样保留字幕、原文高亮/下划线与阅读区域，不自动播放，显式恢复后继续推进。普通网页周边段落会变化，修复以唯一完整文本建立源段落到 DOM 的映射，保留生成过的音频/标注源编号；重复或变化的目标不猜测位置。商业书架继续各自分页事务。本次真实样本通过不代表所有网页/来源都已联合验收。

实现与回归：[WebReaderBridge.swift](../../CastReader/Services/WebReaderBridge.swift)、[ReaderAppearanceTests.swift](../../CastReaderTests/ReaderAppearanceTests.swift)。冻结证据：[G13 复验记录](../../reports/mac-parity-20261004/G13-system-integration.md)、[源码摘要](../../reports/mac-parity-20261004/g13-system/web-remap-source-hashes.json)、[Mac 115 PASS](../../reports/mac-parity-20261004/g13-system/web-remap-mac-green.json)、[iPad 113 PASS](../../reports/mac-parity-20261004/g13-system/web-remap-ios-green.json)、[Release 安装身份](../../reports/mac-parity-20261004/g13-system/web-remap-installed-identity.json)。两端均零失败、零跳过，不与前轮重叠结果累加；Release 主程序 SHA-256 为 `02d27a96609d2f39979e4ef8d4e190670da4605ce7c97b61b3e58c98db327b57`。

同一 Release 首页加号、书架、头像的尺寸与间距，以及 Google Books/Kobo/WeRead 的 View all 高度已适配；首页三入口、Voice 页书架及账号弹窗打开/关闭实测通过，进程保持、不崩溃。G13 仍保留 Widget、物理媒体键、提醒及旧 Safari 同账号/异账号协作待验。


### Mac 阅读标题与 Kindle 返回修复（2026-10-06）

阅读页去掉重复的 CastReader 标题，将书名/文档标题设为 Mac 20 pt 半粗体。初版把自定义按钮上移到系统标题栏，实际鼠标点击 Back 无响应，而 AX 直接激活可返回；因此已撤销忽略顶部安全区的方案，交互控件保留在正常内容区域。隐藏底层首页/文库导航栏，系统控制区约 32 pt，阅读栏 52 pt，保留正常鼠标命中。iPhone/iPad 标题样式未改。

最终本地 arm64 Release 1.2.47（72）已安装。真实 Kindle 书实测：鼠标播放 → Reading Aloud → 鼠标 Back → Mini Player 继续 Reading Aloud → 鼠标展开 → 继续播放及词高亮 → 暂停返回，全部通过。文库入口残留工具栏已消失；普通文本鼠标返回也在 Debug 回归通过。本轮只关闭该 UI/返回问题，不扩展为全平台验收完成。正常主包、Share、Widget 的严格签名/沙箱/App Group 校验通过，主程序 SHA-256：`542789a06e42b9d69eaec96c61cb6af1bdcbaa668ee5fb93634848dc96923feb`。

证据：`reports/mac-parity-20261004/reader-header-ui-20261006.json`；构建日志：`/tmp/mac-reader-return-final-release.log`。当前保留 Kindle Mini Player 暂停状态与 1.5x 速度。此次最终包仅验证 arm64，不宣称 Intel 包完成。


### Mac 侧栏选中动画收敛（2026-10-06）

保留原生 sidebarAdaptable TabView、页面和播放器所有权；Mac 的选择 Binding 忽略同值写入，并使用无动画事务，Tab 表面不再继承播放器容器的弹簧动画。iPhone/iPad Binding 行为不变，未保留实验性的自定义侧栏容器。

定向 Debug 实测通过：四项鼠标切换/重复点击、文库 Kindle 筛选往返保留、真实 Kindle 朗读中鼠标返回 Mini Player、播放中切四个页面并继续朗读、展开后仍播放、暂停返回。正常 arm64 Release 1.2.47（72）已安装，四项实际鼠标切换、重复选择、Kindle 返回暂停 Mini Player 和切回首页保留 Mini Player 通过；主包/Share/Widget 严格签名、沙箱/App Group 通过。主程序 SHA-256 `56ec31f52c9c217b774804c0660f91592cd8cff1d34fffcb1a899298ed640144`。只关闭本项定向 UI 回归，不宣称全部核心/跨平台验收完成。

证据：`reports/mac-parity-20261004/sidebar-selection-20261006.json`；最终构建日志：`/tmp/mac-sidebar-transaction-release.log`。


### Mac 文库工具栏残留与排列修复（2026-10-06）

用户截图显示进入 Kindle 后，文库的 Downloaded、导入、书架来源仍被系统放在阅读页顶部。此前仅隐藏导航栏不足以保证已提升到 NSToolbar 的按钮移除。本轮为 LibraryView 传入页面/阅读器活动状态，阅读期间直接移除这组 toolbar items；文库正常显示时，三个入口合并到右上角同一组，统一图标、点击区域和间距。iPhone/iPad 保留原工具栏分支。

Debug 定向实测通过：三个入口打开/返回或取消，连续三轮鼠标返回文库与展开 Kindle，真实朗读高亮及返回后 Mini Player 继续播放。最终 arm64 Release 已安装；文库排列、阅读页无残留、真实 Kindle 高亮、鼠标返回后恢复三个按钮及继续朗读、再次展开仍播放且无残留、再次返回并暂停均通过。主包/Share/Widget 严格签名、沙箱及 App Group 校验通过。最终停留在文库及暂停的 Kindle Mini Player，保留用户声音与 1.5x 速度。

主程序 SHA-256：`1c4fe1fb50ae50c04fe2b61899b1bf5b14d954736949fc0963a5b12ed8e8299d`。证据：`reports/mac-parity-20261004/library-toolbar-20261006.json`；构建日志：`/tmp/mac-library-toolbar-release.log`。本次是定向 UI 验收，不代表所有来源或四平台全面验收完成。


### Mac Tab 高亮再次闪烁：替换自适应指示器（2026-10-06）

用户再次反馈侧栏 Tab 高亮来回闪烁，上一轮关闭 SwiftUI 动画的方案不足；旧报告验证的是最终选中状态，不能据此证明切换动画正确。本轮为旧实现记录六次点击，每次只出现一个请求和一次提交，未观察到应用选中值往返；系统内部高亮动画未做逐帧采样，不把推断写成已证实的系统缺陷。

Mac 改用四个固定导航按钮，每行独立显示无动画背景；保留 TabView 页面所有权与各页状态，使用 tabBarOnly 内容并隐藏系统 Tab 控件，阻止 Catalyst 在原生标题栏另生成一套 Tab。Mac 首页/声音/设置改为单行标题；阅读器仍在正常安全区中，保持实际鼠标返回。iPhone/iPad 导航分支不变。

最终 Debug 验证通过：四项鼠标切换、连续切换和重复点击当前项；文库 Kindle 筛选往返保留；真实 Kindle 朗读中返回、四项切换期间继续播放、展开保持播放、暂停返回；三个文库入口及取消/子页返回；Command-4/Command-2 同步高亮。最终 arm64 Release 已安装并复验四项鼠标切换、连续点击、唯一选中背景且无重复顶部 Tab、阅读页隐藏侧栏/文库按钮、鼠标返回后选中 Library 与暂停 Mini Player 和三个入口恢复。主包/Share/Widget 严格签名、沙箱及 App Group 均通过。

主程序 SHA-256：`236aac015a85152029eefb6789983e1834289a1111d667e24e9309af148a36f5`。证据：`reports/mac-parity-20261004/tab-flicker-20261006.json`，两份脱敏选择事件日志同目录；构建日志：`/tmp/mac-tab-fixed-sidebar-release.log`。仅此问题定向验收，不扩大为全部核心或四平台验收通过。
