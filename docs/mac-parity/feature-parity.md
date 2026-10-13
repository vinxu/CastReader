# iOS 国际版到 Mac 功能对齐清单

基线 `09456f1`。以下为源码盘点，不是 Mac 功能通过结果。Mac 的唯一产品/服务区域是 Global，界面语言保留 iOS 当前九语；国际版允许中文内容、中文声音和微信读书，不把“仅国际版”误解为删除中文能力。

| 编号 | iOS 已有功能和对应源码 | Mac 对齐目标 | 阶段与当前状态 |
| --- | --- | --- | --- |
| I01 | `CastReaderApp`、`RootAuthGate` | 相同启动、硬登录门、取消和错误状态 | G01 PASS；G02 当前 Google 账号登录与冷启动恢复 PASS，其他账号场景待验 |
| I02 | `AppRegion`、`ServiceRouting` | Mac 固定国际产品与国际服务，不读取 CN 覆盖 | G01 PASS |
| I03 | `LoginView`、`AuthService`、`AuthService+Apple` | Google、Apple、邮箱验证码、条款同意和会话恢复 | 当前 Google 账号登录/重开 PASS；Apple、邮箱及切换供应商实际流程待验 |
| I04 | `KeychainStore`、账号作用域与设置注销 | 凭据持久、退出/切账号、删除账号与晚回调隔离 | G02 待验证 |
| I05 | `MainTabView`、`HomeView`、首次书库引导 | 首页、导入、声音入口、继续听和国际 Kindle 引导 | G01/G03 待验证 |
| I06 | `DocumentImportPipeline`、`ReaderDropImport` | 所有现有格式校验、拖入/选择、进度、取消、限额 | 原生复制导入适配及 77 项本地合同通过；格式样本已实测，剩余边界见 G03 报告 |
| I07 | `PDFReaderView`、`DocumentBuilder` | 原页、缩放、页跳转、文本/扫描 PDF 和高亮/marks | 4 页混合 PDF、17 段真实 Read/Explain、高亮/圈注已验；复杂私有语料和缩放边界待验 |
| I08 | `EpubNativeEngine`、`HtmlParser`、`EpubTOCSheet` | 章节、目录、图片、重排、深章恢复 | 实际图文 EPUB、PNG/SVG、标题、目录与暂停定位已验；长篇深章恢复待验 |
| I09 | DOCX WebReader 与导入管线 | 图文/表格/标题、阅读顺序与错误边界 | Finder 冷启动 DOCX、中英图文和真实 TTS 高亮已验；扩展排版边界待验 |
| I10 | `CameraView`、`DocumentScannerView`、`OCRService`、`PhotoRegionPicker` | 在 Mac 可用的图片/相机采集路径实现相同 OCR 和区域选择结果；不假称手机扫描控制器可用 | Mac 多页相机适配已编译；用户授权的本地预览/取消 PASS，未拍摄或上传；中英文图片 OCR 实测通过 |
| I11 | 文本/Markdown/RTF 与现有扩展集合 | 编码、格式、全文排版、导入反馈 | 真实 Markdown 6 段、TXT 4 段与字号调整已验；其余格式合同通过，实际编码边界待验 |
| I12 | `ReadAloudViewModel`、`TTSService`、`AudioPlayerService` | 真实流式朗读、队列等待、失败恢复、段落起读 | 真实文档/Web/Kindle/Kobo 流式播放已验；Kobo 重排续播发现的共享竞态已修复并有双端回归，仍按场景收口 |
| I13 | `NativeReadingTextProjection`、`ReaderTextView` | 完整正文不跳动；segment 高亮严格投影到原文，保留 Unicode 修复 | G04 待验证 |
| I14 | `ExplainViewModel`、`QuickReadService`、`MarkAnchoring` | 所有讲解场景/语言/范围、块时间线、原文手写标注 | PDF 与普通网页 Explain 至自然完成已验；Kindle/Kobo 长解读通过，Kobo 书尾模式切换及目录字幕遮挡复验通过，其余源待验 |
| I15 | `ReaderMoreButton`、`ReaderAppearanceSettings`、`PlaybackSleepTimer` | 更多、Aa、字号/主题、定时、语速及条款内速度闸门 | 真实 1→1.5→1x、睡眠 5 分钟设置/取消、18→20 pt 与暂停保留已验；完整闸门/语言组合待验 |
| I16 | `PlayerCoordinator`、`MiniPlayerView`、恢复 checkpoint | 收起继续播、恢复展开、停止点、切文档/模式、唯一音频回调 | G04 待验证 |
| I17 | `VoiceDiscoveryView`、`VoiceBrowserView`、`VoiceDiscovery` | 推荐、主题、合集、搜索、全部声音、筛选、试听和应用 | 搜索 Bella/Isabella、Bella 试听及正文应用已验；420 项声音合同通过，其他目录 UI 待验 |
| I18 | `VoiceCloneRecorder`、`VoiceCloneAudioUploadViewModel` | 麦克风录制、导入样本、校验预处理、创建任务/失败恢复 | 短音频/静音拒绝及合成样本裁剪试听已验；麦克风、真实授权创建与线上 Mac 平台接纳待验 |
| I19 | `VoiceCloneCreatedView`、`VoiceCloneStore` | 私人/朋友/社区声音、备注/改名、删除/撤回/移除权限 | G05 待验证 |
| I20 | 声音分享/邀请和 `VoiceGiftRouteCenter` 相关路由 | 接收/分享/授权状态及深链恢复，与 iOS 权限一致 | G05 待验证 |
| I21 | `KindleLibraryStore`、`KindleBookView`、分页/预取脚本 | 国际书架、登录、目录、实书跨页/跨章与 Read/Explain | G06 核心通过：Read 1815 秒，Explain 982.376 秒，详见阶段报告范围 |
| I22 | `KindleOfflineDownloadCoordinator`、离线 store/reader | 整本页图保存、进度/取消、离线书架、按需 Vision OCR | 两本真实下载完成，72 页样本 OCR 与末页朗读通过；其余边界按矩阵追踪 |
| I23 | `SystemSpeechPlaybackService` | Kindle 离线系统声音，中日句级/英文词级高亮和暂停 | 英文 Samantha 实机通过；不以英文结果代替中日语音验收 |
| I24 | `WeReadLibraryStore`、`WeReadWebScripts`、WebReader | 扫码/会话、书架、双栏、分页、Read/Explain、恢复 | G07 部分通过：Read 1074.123 秒、24 次翻页；完整长跑受扫码登录和试读限制阻塞 |
| I25 | `KoboLibraryStore`、`KoboWebScripts`、library views | 登录/扫描分页、跨章、短尾/书末、Read/Explain、恢复 | G08 核心通过：两册真书、书架、四主题、1834.953 秒 Read、929.685 秒跨章 Explain、直接冷恢复、缩窗续播、书尾切模式及目录字幕复验通过；真实不同账号与系统 AX 限制保留 |
| I26 | `GoogleBooksLibraryStore`、web scripts/bridge | 登录、分页书架、iframe、双栏、Read/Explain、恢复 | G09 核心通过：五本书/窄窗、31 分钟 Read、修复后 Explain 实播 933.44 秒/22 次翻页、两本书/书尾/重排/精确冷恢复；不同账号及混合模式策略保留 |
| I27 | `OReillyLibraryStore`、`OReillyWebScripts`、library views | 国际版已有 O’Reilly 登录、书架、阅读和恢复 | 本轮 N/A：用户 2026-10-05 明确不再测试；保留历史入口 UI/33 项回归证据，不再等待账号，不宣称书籍验收通过 |
| I28 | `YouTubeHomeView`、`YouTubeListenView`、字幕服务/切换面板 | URL/历史、字幕提取、语言选择、字幕朗读与定位（当前 iOS 没有 YouTube 解读切换） | 已缓存中英字幕切换、英文逐词高亮、两种窗口布局与精确冷续播已验；滚轮手动浏览/返回跟随已修复实测；双端各 246 PASS/1 SKIP；新视频仍受 YouTube 官方验证限制，中文仅确认 segment 高亮 |
| I29 | WebReader、普通网页与 AO3 等既有专用行为 | 抓取/登录/提取、高亮/marks、原网页继续与失败分流 | W3 原始网页真实 Read/Explain/原文圈注与完成已验；特殊站点与其他边界待验 |
| I30 | `CloudStorageCenter`、已注册的 Google Drive | 既有 Google Drive 授权/选择/浏览、导出格式、下载/重开、版本/权限失效；Dropbox/OneDrive 文件存在但未进入当前 iOS target | 现有授权实际浏览/搜索、TXT 与 Google Docs→DOCX 导入、完整 Read/Explain、重读与云引用冷恢复已验；共享重读缺陷已修复，Mac/iPad 各 158 项相关回归通过；新授权/异账号/撤权改版实测保留 |
| I31 | `HistoryStore`、`ContentCatalog`、`ResumeCoordinator` | 文库、搜索、继续、删除/归档、云引用及账号隔离 | G03/G11 待验证 |
| I32 | `ProManager`、`ProBackendService` | 当前账号最近成功服务端 pro 为权威，不能退回历史 OR 逻辑 | 当前账号服务端 Pro、冷重开和恢复购买 UI 已验；首次未知态显示同步中；独立 Apple 权益授予和真实切账号仍待验 |
| I33 | `QuotaManager`、付费墙/试用展示 | 现行免费额度、试用、Pro 声音/语速限制和错误合同 | G12 待验证 |
| I34 | `CloneCreditStore`、`CloneCreditPurchaseView` | 余额、购买、恢复/入账、幂等、生成扣费/缓存不扣费 | iPad 本地 StoreKit 与账本 9 个核心场景通过；Mac StoreKit 产品获取 505 阻塞，未计购买成功 |
| I35 | `SettingsView` | 账号、连接书源、Pro、离线书籍、播放、声音、解读语言、外观、支持和清缓存 | 九语界面、精确语速显示、颜色键盘操作、偏好冷重开、小窗口滚动已实测；无 CN 入口 |
| I36 | `ReaderSceneContext`、窗口/键盘 utilities | 多窗口、恢复、登录呈现窗口、键鼠焦点和单一播放所有权 | Mac 窗口焦点和音频所有权适配已验；实际关闭播放窗后另一窗接收并连续播放通过；末窗重建的段落重排恢复修复后，正常 Release 的暂停网页 Read 词高亮/Explain 原文 marks、当前阅读区域和主动续播实测通过，相关 Mac 115/iPad 113 项全通过；剩余系统入口待验 |
| I37 | iOS Share Extension、`ShareInbox` | Mac 对应系统分享/文件入口、队列及重入；不能仅因未嵌入就视为不需要 | Finder→收件箱→朗读已验；最终 Release 的 Safari 冷/热分享面板 0.538/0.564 秒、冷启动自动展开、原网页 Read、高亮、同页重复 Explain 自然完成及重播/空格暂停已验；相关 Mac 83/iPad 81 项全通过 |
| I38 | App Intents、Widget、提醒和系统播放控制 | 按 Mac 系统能力实现对应继续听入口、媒体操作和通知行为 | Shortcuts Read/Explain/Continue 已真实执行并验证阅读/原文标注/冷打开；Widget 已修正共享组 profile，实际添加/点击受系统面板工具访问限制；媒体键/提醒待验 |
| I39 | Safari native contract、App Group 和账号/权益桥接 | 保留旧 Mac Safari 宿主；Mac 主 App 协作、移交和权益一致 | G13 待验证 |
| I40 | 九语 strings、无障碍、隐私、分析、增长/推荐行为 | 国际版本完整本地化与已公开功能；分析正确标识 Mac，避免当作 iOS | G15 待验证 |

## 额外工作与验收证据

跨设备文件、书架和精确播放进度的新增同步先核对现行后端；当前 iOS 尚未实现的部分标作新增工作，不以做一个 Mac App 为由自动宣称已经存在。基线中已有能力无论源码复用率多少，都必须走真实 Mac 效果验收。

每个阶段记录 iOS 参考样本/入口、Mac 候选、差异、复现步骤、实现提交、自动测试、实测录像/音频/事件及剩余问题。未通过的大功能不进入下一阶段；编译修复中被迫适配的其他文件只标“兼容性修改”，不能据此提前把对应产品功能勾成通过。
