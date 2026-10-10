# iOS Voice tab 对齐需求 · 2026-10-09

状态：用户已确认 Android 本轮改版，要求交给 iOS 对齐。2026-10-09 补充：App 语言变化时 Voice 浏览语言必须同步重置，以下第 6 节覆盖初版无条件恢复浏览历史的规则。本文记录最终交互与展示要求；iOS 实施、截图和验收结果由 iOS 任务补充，当前均未据此宣称通过。

## 1. 交付范围与依据

这轮改版解决：新增语言只有一个或几个常规音色时，原有发现页显得空或重复；支持克隆的语言又必须保留对应语言的公开克隆推荐；语言、搜索、筛选、My Voices 的顶部层级需要清楚。

- **只调整 Global。中国区不做新语言适配，保留原有 9 语言及发现页行为。**
- 第三个底部 Voice tab 保留；独立浏览页与阅读器音色面板采用不同展示方式。
- UI 文案直接翻译，不调用翻译服务。
- 不修改服务端 wire、TTS 路由、Pro、月额度、账号与 Voice Gift 授权语义，不扩大克隆语言能力。
- 本交付不包含发布；原有 28 语言朗读、解读、OCR 验收继续独立记录。

Android 最终实现：`848c175d7c4997663671350a0997e49ce9da0772`；验收记录提交：`b12cb49`。以本轮最终行为为准，早期隐藏公开克隆、浏览页展示全部私人音色的方案已被用户纠正。

参考：[Android 最终报告](../Android-Adaptive-Voice-Browser-2026-10-09.md)、[展示规则 JSON](../contracts/android-adaptive-voice-browser-v1.json)、[Android 验收证据](../evidence/android-adaptive-voice-20261009/acceptance.json)。

交付附件：[iOS 验收清单](acceptance.csv)、[28 语言 × 6 条现有文案](ui-strings.json)、[文案与来源清单](sources.json)。

## 2. 顶部布局与页面顺序

独立 Global Voice 页按以下顺序组织：

1. 紧凑标题栏 Voices / 音色，保留 iOS 已有必要工具入口。
2. **Explore / My Voices** 两个清楚的主导航。
3. 语言工具栏：地球图标、语言名称、下拉指示；右侧按需出现搜索按钮。
4. 当前音色卡。
5. 对应源语言的精选公开克隆，最多 3 个；有数据才显示。
6. 可选常规音色：少量时直接列表，丰富时保留有效发现内容。
7. 我的音色预览：最新 3 个兼容私人/受赠音色；箭头进入完整 My Voices。
8. 按能力显示创建入口，以及浏览其他语言入口。

最近、收藏继续可达，可放在浏览内的次级导航中；不再与 Explore / My Voices 并列挤满顶部。不要将大号语言胶囊、孤立的橙色 My Voices 链接、常驻搜索卡、分离的筛选按钮堆在一起。

当前音色使用浅色背景与细描边，保留选中状态、试听及原有收藏能力。不要用整块高饱和橙色占据首屏。卡片说明独立浏览时是“某语言的默认音色”，阅读器中则说明当前正文/解读语言。

iOS 使用原生 SwiftUI 控件、间距与安全区，对齐信息层级和行为；不要求复制 Android 像素尺寸。保留已有 iPad、自适应宽度与 mini player 避让能力。

## 3. 搜索、筛选与少量音色

| 场景 | 最终要求 |
|---|---|
| 首页 | 搜索默认收起，点击语言栏搜索图标展开 |
| 搜索表面 | 查询、清除、筛选入口放在同一个表面内；不能分裂成两张卡 |
| 搜索是否需要 | 当前列表候选与兼容私人音色总数大于 6 才显示；不要把未选中的所有语言算入 |
| 筛选是否需要 | 性别、口音、等级分别有超过一个有效值才显示对应维度 |
| 列表详情 | 候选较多时直接显示搜索；搜索结果不再套发现模块 |
| 收起搜索 | 清空查询/筛选、移除焦点、收起键盘 |
| 换语言/页面 | 停止试听、收起键盘；清理当前查询状态，避免上一语言筛选产生假空页 |
| 常规音色 ≤ 6 | 直接显示可用音色列表；当前音色已在卡片展示时不重复 |
| 常规音色 > 6 | 可保留编辑推荐和真实合集；每个展示分组至少有 2 个不同音色；相同成员合集去重 |
| 阅读器面板 | 始终直接选择列表，不插入发现栏目或创建推广 |

判断“常规音色数量”时排除月额度公开克隆。韩语/俄语常规音色少，不代表对应语言的公开克隆也应消失。

例：芬兰语只有 Aino 时，展示当前音色与浏览其他语言入口，不造空分类；土耳其语的 5 个常规音色直接列出。数量从有效目录计算，不能永久硬编码服务端今天的数量。

## 4. 精选公开克隆：必须在首页容易找到

用户明确要求：支持克隆音色的语言，仍显示“对应语言的热门克隆音色”。现有后端没有可信的热度排名字段，因此标题采用 **Featured cloned voices / 精选克隆音色**，使用已有编辑精选顺序，然后保持其余服务端顺序，不造热度分。

生成完整推荐池，再截取首页 3 个：

1. 当前输出语言属于现有克隆支持集合。
2. 音色 enabled、selectable，声明支持当前输出语言，且为月额度/公开克隆音色。
3. `discoveryLanguage` 与当前语言一致，状态不为 lab/legacy，存在可用试听。
4. 已有编辑精选置前，其余保持服务端顺序，按 ID 去重。
5. 首页显示前 3 个；“查看更多”打开**完整的相同源语言公开克隆池**，不能只把首页 3 个或编辑精选 6 个传进去。

`discoveryLanguage` 沿用现有规则：规范化 `referenceLanguage` 优先；否则使用唯一的规范化 `previewLanguages` 值；仍不能确定时使用音色本身的 language/lang。

区分两个概念：`supportedLanguages` 决定能否用该音色合成某语言；`discoveryLanguage` 决定应在哪种语言的首页推荐。英文原始样本支持韩语合成，不等于它应填充韩语首页的精选模块。

“全部可用音色”仍可显示明确支持目标输出语言的跨源语言克隆。没有对应源语言条目时隐藏精选区，不回退英语填充。

2026-10-09 Android 验收快照中，对应源语言池有 en / zh / de / ja / fr / es / ko / pt / ru；意大利语可克隆合成，但没有 it 源语言公开条目。这是目录缺口，不应虚构推荐，也不能因此隐藏已有兼容私人音色。实施时重新使用实时目录，快照不是固定白名单。

试听保留 Free 可用规则；Pro 音色对 Free 用户仍可见，选用时走现有 Pro 与额度门禁。保留月额度、试听语言提示，不能通过页面改版绕过权限。

## 5. My Voices：首页预览与完整库分开

首页按下列顺序计算：

```text
当前账号完整 owned + gifted 库
→ 按现有授权与 ready 状态过滤
→ 按当前语言兼容性过滤
→ 排除已在当前音色卡展示的音色
→ createdAt 降序；日期相同或缺失时保持服务端顺序
→ ID 去重，取前 3 个
```

必须**先过滤再取 3 个**。不要先用全语言 `familiarVoices.prefix(3)` 再过滤，否则最新音色不兼容时会漏掉后面本来可用的音色。日期按 ISO 8601 解析，兼容带/不带小数秒；未知日期排在已知日期之后。

| 入口 | 数据范围 |
|---|---|
| Explore 首页“我的音色” | 最多 3 个符合上述条件的条目 |
| My Voices tab / 查看全部 | 当前账号完整权威库，保留 owned 与 gifted 的既有分区和管理行为 |
| 阅读器音色面板 | 全部当前语言可用的私人/受赠音色；当前卡与列表合计完整，不能套首页 3 条上限 |

不兼容当前浏览语言的私人/受赠音色在完整库仍可见、可按授权管理、可固定试听；选用禁用并显示支持语言。不得修改底层缓存、删除库记录或将首页预览当成权威 snapshot。

不支持克隆的语言隐藏录制、邀请和克隆推广/额度营销卡；已有音色数据与授权管理入口仍保留。已有授权数据按 Voice Gift 合同处理，不因语言筛选或网络错误清空。

## 6. 语言、偏好与克隆能力边界

- 首次使用/首次注册：独立 Voices 默认跟随 App UI 语言，例如越南语 App 默认展示越南语音色。
- 手动浏览语言仅在 **App UI 语言未变化** 时恢复。保存浏览语言时同时保存对应的 App 语言；该上下文一致时，优先级为本次明确选择 > 已保存浏览语言 > App UI 语言 > 英语。
- 用户切换 App 语言（包括从设置切换、跟随系统、页面重建）时，清除旧浏览覆盖并跟随新的 App 语言；即使设置切换时 Voices 未打开，也不能在下次进入时恢复旧值。旧版无 App 语言上下文的历史记录按当前 UI 语言重新初始化。
- 仅在该区支持的语言内解析；不支持的 UI 语言回退英语。CN 继续原 9 语言行为。
- 浏览语言与播放音色偏好/正文语言分开持久化。打开页面或换浏览语言不写播放默认音色。
- 阅读器以正文/解读语言进入；未知正文保留 `und`，不能拿 UI 语言或独立浏览历史猜成英语。
- 正文纠错需要明确的“朗读语言 / 更正朗读语言”操作。iOS 已有明确标识的纠错控件可保留；单纯浏览其他语言不能隐式触发重新朗读。解读继续遵从其独立语言设置。
- 目录或私人库加载时保留已保存的私人/公开克隆选择；只有没有既存偏好时才使用目录默认音色。
- 现有克隆**输出**语言集合为 `de en es fr it ja ko pt ru zh`。韩语/俄语不能因常规音色来自 Google 就整体被禁用克隆；印地语有 Kokoro 常规音色，也不能据此获得克隆输出能力。
- 输出支持与录制样本 `referenceLanguage` 是不同概念；本轮不改录制提示语言、可选 advisory 文本或上传协议。
- 语言集合仍须叠加单个音色的 supportedLanguages、区域与账号 capability 门禁。本轮不新增克隆引擎能力。

## 7. 异步、试听与现有协议保护

切语言、切目的页、账号变化、页面消失/进入后台应结束相关试听。迟到的私人试听 URL 或选用回调必须校验账号代次及当前页面/语言；不能在新页面突然响起或写回旧账号选择。

保留已有试听结束恢复、用户明确暂停与快速换声处理，不把固定试听的成功等同于真实朗读合成成功。页面重新组织不得破坏现有阅读器 overlay 对 WKWebView 几何、OCR 投影与播放位置的保护。

实施触及克隆时，先按 iOS 仓库要求阅读并校验控制面唯一架构文档 `voice-clone-system-v1` 与现有冻结合同：

- `readout-web/docs/voice-clone-system-architecture.md`（使用 iOS 版本锁要求的固定提交与 SHA）。
- `readout-web/docs/contracts/voice-gift-v1.md`。
- `readout-web/docs/contracts/fixtures/voice-gift-v1.json`。
- `readout-web/docs/contracts/voice-gift-cross-platform-delivery-v1.md`。

本机控制面仓库：`/Users/xuxuheng/Documents/MyProject/readout-web`。本说明只定义客户端展示，不重定义 wire。完整库、presentation、owner/recipient 管理动作、结构化失效刷新与服务端 Pro/额度继续以现有合同为准。CN 不调用 Gift API，不跨区回退。

## 8. iOS 当前代码差异与建议落点

已只读检查实际多语言工作树：`/Users/xuxuheng/.codex/worktrees/ios-28-languages/CastReader`，HEAD `09456f1979cc14ca19977ede4b1edde043c5f840`，含正在开发的未提交变更；以下是交付时快照，不能据此覆盖 iOS 后续工作。

| 文件 / 符号 | 当前观察 | 对齐动作 |
|---|---|---|
| `Views/Settings/VoiceBrowserView.swift`：body、categoryTabs | 常驻搜索在上，语言/筛选一行，四个分类，tab 使用 large title | Global 改为紧凑标题、Explore/My Voices、语言栏、按需搜索；保留最近/收藏次级入口 |
| 同文件：voiceResults | Explore 默认进入同一种发现 feed | 区分 compact/rich/reader，加入当前音色卡，My Voices 保持完整库 |
| `Views/Settings/VoiceDiscoveryView.swift`：VoiceDiscoveryFeed | 克隆模块位于常规推荐、合集之后 | 将对应语言公开克隆紧接当前音色卡，首页限 3，详情完整 |
| `Models/VoiceBrowseData.swift`：feed | featuredClones 取编辑 modules 的前 6 个；部分单条分组仍可进入 | 计算完整源语言克隆池，编辑排序优先；删除无效单条分组和重复合集 |
| `Models/VoiceCatalog.swift`：discoveryLanguage | 已区分源语言与 supportedLanguages | 复用并补测试，不再建立相冲突的推断逻辑 |
| `Models/VoiceCloneModels.swift`：VoiceFamiliarSelection.latest；`Models/VoiceCloneStore.swift`：familiarVoices | 已按时间排序取 3，但在全库阶段预先截断 | 从完整库先按语言/状态过滤并排除当前项，再取最新 3；保留完整库缓存 |
| `Views/Settings/VoiceDiscoveryView.swift`：VoiceFamiliarSection | 接收 store.familiarVoices，页面语言只用于选用 | 改为当前语言投影，不能让较新不兼容条目挤掉可用项 |
| `Views/Settings/VoiceCloneCreatedView.swift` | 已按 owned/invited 展示完整库 | 保留全部；增加/确认不兼容项的支持语言、选用禁用与管理/试听保留 |
| `Views/Settings/VoiceBrowserView.swift`：selectMonthlyVoice | 存在 `SupportedTTSLanguage(...).isGoogle != true` 判断 | 对照现有 10 种克隆输出支持和单条 metadata 校验，避免误挡 ko/ru；不得因此放开全部 19 种 |
| 同文件：chooseLanguage、synchronizeBrowserLanguage | 阅读器与独立页共用 library.browserLanguage；纠错通过回调完成 | 分离 reader/local browse state，保留明确的正文纠错入口与解读语言约束 |
| `Models/VoiceBrowserModel.swift` / 现有 library store | 已有搜索、筛选和 sample player | 复用底层，补按需展示与语言/页面/账号取消边界 |
| `Localizable.xcstrings`、`Views/MainTabView.swift` | 现有字符串与第三 tab 入口 | 导入附件中 6 条 × 28 语言，沿用 iOS locale 与 key 规范；确认 Global/CN 分支 |

以上路径均相对 iOS 的 `CastReader/`。建议先抽纯展示规则，再接 SwiftUI，最后做设备截图和真实播放回归。iOS 已存在的最新三条、源语言 metadata、收藏/试听能力应复用，不必重做。

## 9. 文案与截图

[ui-strings.json](ui-strings.json) 从 Android 本轮已直接翻译的资源逐条导出，共 168 条，无调用翻译服务。包含中英文对照、Android 原资源路径与 iOS `%1$@` 占位形式；接入 `Localizable.xcstrings` 时使用 iOS 项目现有 locale ID（例如 zh-Hans / pt-BR），不要复制 Android 的 iw/in/b+fil 目录名。新键以项目现有命名规范为准。

| 含义 | English | 中文 |
|---|---|---|
| 当前选中 | Current voice | 当前音色 |
| 可选列表 | Available voices | 可选音色 |
| 独立页作用域 | Default voice for %@ | %@的默认音色 |
| 语言入口 | Browse other languages | 浏览其他语言 |
| 私人音色支持 | Supported languages: %@ | 支持语言：%@ |
| 对应语言推荐 | Featured cloned voices | 精选克隆音色 |

实机视觉参考（Android，不能当作 iOS 已通过证据）：

| 场景 | 截图 | 观察重点 |
|---|---|---|
| 中文首页 | [chinese-clones.png](../evidence/android-adaptive-voice-20261009/chinese-clones.png) | 两级顶部、浅色当前卡、源语言克隆首屏可达 |
| 展开搜索 | [search-expanded.png](../evidence/android-adaptive-voice-20261009/search-expanded.png) | 搜索与筛选共用一个表面 |
| 芬兰语 | [finnish.png](../evidence/android-adaptive-voice-20261009/finnish.png) | 单音色没有假发现内容 |
| 土耳其语 | [turkish.png](../evidence/android-adaptive-voice-20261009/turkish.png) | 少量音色直接选择 |
| 阿拉伯语大字号 | [arabic-large-font.png](../evidence/android-adaptive-voice-20261009/arabic-large-font.png) | RTL、长文案和操作按钮不重叠 |

截图中的 UI 语言与音色浏览语言可不同，这是独立状态，不应为匹配音色语言而切换整个 App UI。

## 10. 验收交付要求

使用 [acceptance.csv](acceptance.csv)（补充后 56 项）逐项记录 iOS 实际结果与证据路径，初始状态全部 `NOT_RUN`。覆盖源语言克隆、最新 3 个、完整库、阅读器完整选择、搜索/布局、语言偏好、权益与 CN 回归。按仓库要求执行现有 VoiceCatalog / VoiceDiscovery / VoiceClone / ReadingLanguage / 区域与本地化合同；需要新增测试时验证规则和边界，不做只复述 UI 实现的快照断言。

最低视觉样本：中文、英语、韩语、俄语、芬兰语、土耳其语、意大利语；阿拉伯语/希伯来语 RTL、德语长文案、日语；iPhone 窄屏与 iPad / Dynamic Type。克隆推荐的数据测试覆盖 9 个当前已知源语言池及缺池/空池 fixture。

私人库 fixture 至少含 6 个兼容 owned/gifted、时间乱序、同时间/缺时间、一个更新但不兼容条目、当前选中项与未 ready/无访问条目，证明首页限 3 不会截断完整库或阅读器。

真实播放回归覆盖常规 ↔ 公开克隆、已有兼容私人/受赠音色、暂停恢复、快速换声、固定试听结束恢复及高亮/字幕；不为这个 UI 验收创建新音色、发送邀请或修改授权。原有多语言长时矩阵继续单独推进，不将 Android 或 UI fixture 通过数当作 iOS 真实合成证据。

完成时回报：实现提交/工作树、iOS 截图、逐项清单、实际执行的测试与未通过项、CN 回归结果。构建/安装遵守 iOS 最新发布基线门禁；这份需求不授权发布。
