# CastReader iOS 27 系统集成 Phase 2

状态：待 Xcode 27 SDK 到位后启动

更新：2026-08-02

适用范围：CastReader iOS，最低部署版本继续保持 iOS 17.6

## 1. 目标与边界

Phase 2 的目标不是简单增加几个 Siri 口令，而是让系统能够正确理解 CastReader 的核心动作和当前阅读上下文：

- 用户可以从 Siri、Spotlight、快捷指令和 Widget 打开或继续最近内容；
- “朗读”和“解读”保持两个语义明确、结果可验证的动作；
- 系统能识别当前屏幕上的文档或段落，但不会收到原文、OCR 图片或私密网页内容；
- 新能力在 iOS 27 上增强，iOS 17.6～26 继续使用 Phase 1 的自定义 App Intents、深链和 Widget；
- 只有 TestFlight 安装包上的真实系统交互能够作为 App Store 提名证据。

CastReader 仍按“工具型 TTS + AI 解读”定位。不能为了套用 schema 把它描述成图书、音乐或播客 App，也不能把只支持 Shortcuts 的 schema 宣称成 Siri 能力。

当前 Apple 文档中的 Xcode 27 API 仍可能属于 beta。所有宏、协议、属性名和系统支持面，最终以安装到本机的 Xcode 27 RC/正式版 SDK、编译器诊断和设备行为为准；本文中的候选 API 不应在 SDK 到位前直接照抄提交生产。

## 2. 启动前置条件

进入 Phase 2 开发前必须同时满足：

1. Xcode 27 已安装，并可与当前稳定 Xcode 并存；
2. 至少一台可运行对应 iOS 27 的真机；
3. Phase 1 的 `ReadingItemEntity`、`ContinueInCastReaderIntent`、App Shortcuts 和继续阅读 Widget 已在稳定分支工作；
4. 最近内容的 App Group 快照只含 `id/title/sourceKind/updatedAt`，删除历史后会同步清理；
5. 先保存一次 Phase 1 的构建、测试和 Siri 基准结果，便于判断升级是否引入回归。

若拿到的仍是 beta SDK，只允许做分支开发和内部 TestFlight 验证。生产候选必须用 App Store Connect 当时接受的 Xcode 版本，并在 RC/正式 SDK 上重新完整验证。

## 3. App Schemas：先做语义匹配，再写宏

Apple 的 App Schema 通过 `@AppIntent(schema:)`、`@AppEntity(schema:)` 和 `@AppEnum(schema:)` 向系统说明类型的标准语义。schema 不是分发标签；只有 CastReader 的真实行为完整符合其必填参数、结果和运行方式时才能采用。

### 3.1 候选映射

| CastReader 能力 | Phase 2 候选 | 系统面 | 决策 |
| --- | --- | --- | --- |
| 打开指定最近内容 | `.system.open` + `OpenIntent` | Siri、Shortcuts | 第一优先；目标实体为 `ReadingItemEntity` |
| 搜索文库内容 | `.system.search` | Siri、Shortcuts | 只有文库内真实搜索已经落地才做，不以“最近项目查询”冒充搜索 |
| 打开导入文档或页 | `.reader.openDocument` / `.reader.openPage` | 当前文档标注为 Shortcuts | 可做 Shortcuts 增强，但不能作为 Siri 提名主证据 |
| 开始朗读 | `.audio.playAudio` | Siri、Shortcuts | 仅做技术 spike；动态生成 TTS 若无法真实满足 Audio/Media Intents 契约，则保留自定义朗读 Intent |
| 开始解读 | 无明显等价 schema | 自定义 Intent | 保留 `ContinueInCastReaderIntent(mode: .explain)`，不强套 audio/reader schema |
| 导入文本、URL 或文件 | 自定义 Intent，参数使用系统支持类型 | Siri、Shortcuts | 输入必须经过现有导入、额度、鉴权和错误处理路径 |

### 3.2 实施顺序

1. 在独立 spike 文件中使用 Xcode 27 代码补全生成 `.system.open` 模板，记录编译器要求的全部属性和协议；
2. 用现有深链路由打开 `ReadingItemEntity.id` 对应内容，不复制一套阅读器导航；
3. 分别验证目标存在、目标已删除、同名目标、无目标四种解析路径；
4. 再评估 `.reader` 与 `.audio`，每个 schema 单独形成“采用/拒绝”记录；
5. schema 类型用 `@available(iOS 27, *)` 隔离，旧系统继续暴露 Phase 1 自定义 Intent；
6. 检查系统目录中是否出现语义重复的两个动作。若用户会看到两个近似“继续朗读”，合并展示或只保留一个推荐入口。

### 3.3 `.audio.playAudio` 采用门槛

以下任一项不满足就不采用 `.audio.playAudio`：

- CastReader 能将用户请求真实映射为 schema 要求的音频实体，而不是伪装成歌曲、播客或有声书；
- Media Intents 查询能稳定返回可播放项目，并正确处理消歧；
- `perform()` 最终进入现有 `ReadAloudViewModel`/播放器所有权管线，不创建第二套播放状态；
- 锁屏、后台播放、暂停、继续、配额和 Pro 闸门与 App 内启动一致；
- Apple 文档明确把最终采用的实体和 intent 标为 Siri 支持。

不采用该 schema 不代表 Phase 2 失败。准确的自定义 Intent 比错误的标准 schema 更可靠，也更适合审核与提名陈述。

## 4. Semantic Entities：系统只拿轻量语义投影

这里的 semantic entity 指系统可解析的 `AppEntity`，不是把 `ReadingDocument` 整体序列化给系统。

### 4.1 `ReadingItemEntity`

Phase 2 延续独立轻量实体，并至少提供：

- 稳定 `id`，与 History 记录一致；
- `title`，用于显示、口语匹配和消歧；
- `sourceKind`，仅用于图标或必要过滤，不暴露私密来源 URL；
- `updatedAt`，用于 suggested entities 排序；
- 可恢复的应用内 URL 或等价打开表示；
- `DisplayRepresentation`、按 ID 查询和建议最近项查询。

查询约束：

- 默认建议最多返回最近 8 项，与 Phase 1 的 App Group / Widget 合同一致；
- 同名项目的显示表示必须能区分，但不能显示账户、完整 URL 或原文摘要；
- 已删除或无法恢复的 ID 返回空，不自动打开其他同名文档；
- App Group 快照不可包含文档正文、OCR 文本、图片、用户 token、阅读标注或网页 cookie；
- 删除单项、清空历史时，同时刷新 Widget、实体查询数据和 Spotlight 索引（若启用）。

### 4.2 Schema entity 的选择

在 Xcode 27 代码补全中逐项检查：

- 若 `.reader.document` 的含义和必填属性与“用户导入后在 CastReader 中查看的文档”完全一致，可创建单独的 schema adapter；
- 不要让现有业务模型直接承担 schema 宏，避免新 SDK 变化污染 `ReadingDocument`；
- `.reader.document/page` 当前主要增强 Shortcuts。即使采用，也保留能服务 `.system.open` 与自定义 Intent 的 `ReadingItemEntity`；
- 只有真正的文件来源才考虑 file schema。拍照 OCR、粘贴文本、网页和 Kindle 页面不能一律伪装成文件。

## 5. View Annotations：让“这个”指向正确内容

View Annotations 的最小目标是让 Siri/Apple Intelligence 在阅读器可见时知道“这个文档”指什么。系统获得实体标识和可见/选中状态，不应获得阅读正文。

### 5.1 标注位置

| 界面 | 标注 | 规则 |
| --- | --- | --- |
| `ReaderHostView` | 当前 `ReadingItemEntity` 的 `appEntityIdentifier` | 文档加载成功后添加，关闭阅读器即消失 |
| 文库/最近内容卡片 | 每张卡片对应实体标识 | 仅标注当前真实显示的卡片，不把缓存中不可见项目全部上报 |
| `TextReaderView` | 当前文档；必要时再加可见段落实体 | 第一版只做文档级，避免大量段落 annotation |
| `PhotoReaderCanvas` / 自绘标注层 | `appEntityUIElements` 候选 | 只有 bounds、可见性和选中态准确时启用；否则保持文档级 |
| 当前选中文本 | 独立选中态候选 | 只有真实用户选择才标 `isSelected=true`；TTS 当前高亮词不等于用户选择 |

SwiftUI 标准视图优先使用 `appEntityIdentifier(_:)`。只有 Canvas、UIKit 文本布局或一对多自绘内容才评估 `appEntityUIElements(_:)` 与 `AppEntityUIElement`。

### 5.2 隐私与准确性

- annotation 的实体属性不得带正文或 OCR 文本；Intent 执行后由 App 内部按 ID 读取源内容；
- 进入后台、切换文档、删除文档后不得残留旧实体；
- photo/PDF 坐标必须按最终 aspect-fit 和滚动位置计算，不能复用未换算的 Vision 坐标；
- “解释这个”若无法得到唯一目标，应请求消歧或打开 App 让用户确认，禁止默默解释上一份内容；
- 未登录、离线和免费额度耗尽时也必须返回可理解的状态，不能假装动作成功。

## 6. AppIntentsTesting

Xcode 27 到位后新增独立测试文件/测试 target 配置，使用 `AppIntentsTesting` 做 out-of-process 验证。它与普通单元测试互补：普通测试验证路由纯函数，App Intents Testing 验证系统实际发现的 intent、entity、enum、query 和 View Annotation。

### 6.1 必测清单

1. `IntentDefinitions(bundleIdentifier: "com.same.castreader")` 能发现预期 Intent、Entity 与 mode enum；
2. `.read` 与 `.explain` 参数可构造、读取和执行，结果不会互换；
3. `ReadingItemEntity` 按稳定 ID 查询成功，同名、删除和不存在 ID 结果正确；
4. 最近项查询按 `updatedAt` 排序且数量有界；
5. `.system.open` 打开的 ID 与 App 最终路由 ID 完全一致；
6. 无 item 时走明确的“最近内容”或导入路径，不发生崩溃；
7. schema intent 的必填参数和结果通过最终 SDK 生成定义校验；
8. `viewAnnotations()` 在 Reader 可见时包含当前实体，切换/关闭后旧实体消失；
9. 只有真实选择的段落或区域显示 `isSelected=true`；
10. iOS 17.6～26 构建仍能编译并运行 Phase 1，iOS 27 专属类型不会在旧系统加载。

### 6.2 测试数据

固定建立至少六条本地 fixture：

- 英文普通标题；
- 简体中文标题；
- 日文标题；
- 带重音符号的西文标题；
- 两条同名、不同 ID 的标题；
- 一条随后被删除的陈旧 ID。

测试只写隔离的 App Group/临时目录，不能读取开发者真实 History。测试结束后必须清理快照和 Spotlight 测试索引。

### 6.3 产物

- Xcode `.xcresult`；
- App Intents definition 列表快照；
- entity/query 通过与失败用例摘要；
- View Annotation 可见/选中状态断言结果；
- 最终 SDK 相比 beta 的 API 变化记录。

## 7. 九语 Siri 与 Shortcuts 验证

验证语言与 App 当前九语一致：`en`、`zh-Hans`、`ja`、`es`、`fr`、`de`、`pt-BR`、`it`、`hi`。

下面的句子是人工测试语义样例，不是保证 Siri 必须逐字接受的固定命令。最终口令以本地化 `AppShortcut` phrases、设备显示的 Shortcuts 名称和系统转写为准。

| 语言 | 继续 | 指定内容朗读 | 指定内容解读 |
| --- | --- | --- | --- |
| English | Continue reading in CastReader | Read “Title” aloud with CastReader | Explain “Title” with CastReader |
| 简体中文 | 用 CastReader 继续阅读 | 用 CastReader 朗读《标题》 | 用 CastReader 解读《标题》 |
| 日本語 | CastReaderで読書を続けて | CastReaderで「タイトル」を読み上げて | CastReaderで「タイトル」を解説して |
| Español | Continúa leyendo con CastReader | Lee «título» en voz alta con CastReader | Explica «título» con CastReader |
| Français | Continue ma lecture avec CastReader | Lis « titre » à voix haute avec CastReader | Explique « titre » avec CastReader |
| Deutsch | Lies mit CastReader weiter | Lies „Titel“ mit CastReader vor | Erkläre „Titel“ mit CastReader |
| Português (Brasil) | Continue lendo com o CastReader | Leia “título” em voz alta com o CastReader | Explique “título” com o CastReader |
| Italiano | Continua a leggere con CastReader | Leggi “titolo” ad alta voce con CastReader | Spiega “titolo” con CastReader |
| हिन्दी | CastReader में पढ़ना जारी रखो | CastReader में “शीर्षक” ज़ोर से पढ़ो | CastReader में “शीर्षक” समझाओ |

### 7.1 每种语言的验证步骤

1. 将 App、系统、Siri 和 Shortcuts 切到该语言/地区；
2. 从 TestFlight 冷启动一次 App，让系统完成 Intent metadata 注册；
3. 在 Shortcuts 中确认动作名、参数名、消歧文案和错误文案均为目标语言；
4. 分别执行“继续、指定朗读、指定解读”；
5. 使用普通标题与含本地文字/变音符号标题各跑一次；
6. 再测试两个同名项目，确认 Siri 请求选择而不是猜测；
7. 记录系统转写、实际解析的 Intent/mode/item ID、最终打开页面和播放状态；
8. 每个口令连续尝试 3 次，至少 2 次无需手动改写即可正确路由；任何一次路由到错误内容都记为失败，而不是识别波动。

九语均需先通过 Shortcuts 功能验证。Siri 只对该 iOS 版本与地区正式支持的语言计入上线门槛；若系统不提供某种 Siri 语言，报告中必须标记 `N/A — system unavailable` 并附 Apple 支持依据，不能宣传“九语 Siri 全支持”。

## 8. TestFlight 与提名证据包

所有提名证据必须来自 Archive/TestFlight 安装包，不使用 Xcode Preview、Debug 菜单或模拟器伪造 Siri 结果。

### 8.1 TestFlight 候选记录

- App 版本、Build、Git commit/tag；
- Xcode 与 SDK 完整版本号；
- 测试设备型号、系统 build、Siri 语言和地区；
- Intent/schema/entity 清单；
- 九语验证矩阵和失败复测记录；
- AppIntentsTesting `.xcresult`；
- iOS 17.6 最低版本回归结果；
- 已知限制，以及它们是否影响审核员复现。

### 8.2 可视证据

至少准备：

1. 一段 15～30 秒英文真机录屏：Siri 请求 → 命中最近材料 → CastReader 词级高亮朗读；
2. 一段 15～30 秒简体中文真机录屏：Siri 请求 → 指定材料 → 进入解读并出现原文标注；
3. Siri/Shortcuts 动作截图，清楚显示 CastReader 名称与目标内容；
4. Small/Medium Widget 截图，显示最近内容及朗读/解读入口；
5. 一张 View Annotation/AppIntentsTesting 结果图或简洁工程示意，作为实现真实性辅助材料；
6. 九语矩阵摘要，不需要把 27 轮录屏全部提交，但原始证据要归档可追溯。

录屏使用可公开的示例文本，不出现账户邮箱、真实书架、私人网页、通知、设备序列号或 API 凭据。

### 8.3 App Review Notes

审核备注提供最短、确定的复现路径：

- 无需登录即可使用的示例材料；
- 一个稳定的示例标题；
- 英文与简体中文各一个已验证口令；
- 从 Widget/Shortcuts 进入后的预期页面和按钮状态；
- 若朗读需要网络，明确说明网络要求和预期等待时间；
- 免费额度或 Pro 不得阻断审核员第一次完整体验。

### 8.4 Featuring Nomination 叙事

提名主叙事聚焦真实用户价值：用户无需先进入 App、寻找文件和定位进度，即可用系统入口继续多感官阅读；进入后仍保留 TTS、词级高亮、自动滚动，以及解读与原文标注。

证据文案只能写候选 Build 中已经运行的能力。可写“为 iOS 27 更新”以及实际采用的系统技术；不能写：

- Apple 未公布的编辑合集名称、固定窗口或保证曝光；
- 未采用或仅 spike 的 schema；
- `.reader` schema 带来 Siri 支持（当前它主要面向 Shortcuts）；
- “九语 Siri”而验证矩阵中存在系统不支持或未测试语言；
- 仅在 Debug、模拟器或开发签名中工作的效果。

## 9. 上线门槛

只有下表全部为绿色才可提交生产和第 4 份 iOS 27 主题提名。

| Gate | 必须满足的条件 |
| --- | --- |
| SDK | 使用 ASC 接受的 Xcode 27 版本归档；所有 beta API 已按最终 SDK 重新编译与审计 |
| Schema | 每个采用的 schema 都有书面语义匹配结论；无为了宣传而伪装的内容类型 |
| Build | Release Archive、导出、上传、处理均成功；无 App Intent metadata extraction 错误或警告 |
| Intent | 继续、指定朗读、指定解读、空状态和陈旧 ID 均走正确路由；朗读/解读模式零互换 |
| Entity | ID 稳定、同名可消歧、删除可清理；系统侧不含正文、OCR、图片、token、cookie 或私密 URL |
| Annotation | 当前文档可见时实体正确，关闭/切换后旧实体消失；选中态无误报 |
| 自动测试 | 既有单元/UI 测试与新增 AppIntentsTesting 全绿，`.xcresult` 已归档 |
| 九语 | 九语 Shortcuts 全部通过；每个系统支持的 Siri 语言三类口令均达到 2/3 成功率且无错误内容路由 |
| 兼容 | iOS 17.6～26 使用 Phase 1 fallback，无启动崩溃、符号加载错误或 Widget 回归 |
| 播放 | Siri/Widget 启动后仍走唯一播放器回调所有权，暂停、继续、后台、额度与 Pro 闸门一致 |
| TestFlight | 至少两台真机从 TestFlight 安装验证，其中一台做升级安装、一台做全新安装 |
| 审核复现 | Review Notes、公开示例材料、口令和预期结果完整；首轮体验不被登录或付费墙阻断 |
| 提名证据 | 英文朗读、中文解读录屏，截图，九语矩阵，build/commit/test 记录齐全 |
| 质量 | 无 P0/P1；已知 P2 不影响系统入口、隐私、播放正确性或审核复现 |

任一关键语言把朗读解析成解读、打开错误文档、泄露私密正文、或旧系统启动崩溃，均为立即 No-Go。

## 10. 推荐执行批次

### 批次 A：SDK 审计与 schema spike

- 安装 Xcode 27，保存 API diff；
- 生成 `.system.open` 模板；
- 对 `.reader`、`.audio.playAudio` 分别给出采用/拒绝结论；
- 确认 App Intents metadata 可从 Release 构建抽取。

### 批次 B：实体与路由

- 完成 schema adapter 和查询；
- 复用现有深链与 Reader 路由；
- 打通删除、同名、陈旧 ID、无最近项；
- 保持 iOS 17.6 fallback。

### 批次 C：View Annotations

- 先接 `ReaderHostView` 文档级 annotation；
- 再接文库卡片；
- 最后以测试结果决定是否增加段落/Canvas UI elements。

### 批次 D：测试与九语

- 建立 `AppIntentsTesting`；
- 跑普通测试与 annotation 测试；
- 完成九语 Shortcuts/Siri 真机矩阵；
- 修正本地化、消歧和语音转写问题。

### 批次 E：TestFlight 与提名

- 上传 RC，执行全新安装与升级安装；
- 收集录屏、截图、`.xcresult` 和版本记录；
- 通过上线门槛评审后，再提交 iOS 27 主题 Featuring Nomination。

## 11. 降级方案

若最终 SDK 改动、schema 行为不稳定或九语 Siri 未达门槛：

- 移除/停用有问题的 schema adapter；
- 保留 Phase 1 自定义 App Intents、App Shortcuts、深链和继续阅读 Widget；
- 不影响 iOS 17.6 最低版本与当前阅读/解读功能；
- 延后 iOS 27 主题提名，不用未完成能力换取提交时间。

Phase 2 的完成定义是“系统能可靠、准确、私密地完成用户任务”，不是“代码里出现了 iOS 27 API”。

## 12. Apple 官方参考

- [App schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)
- [System and in-app search schemas](https://developer.apple.com/documentation/appintents/app-schema-domain-system-and-in-app-search)
- [Reader schema](https://developer.apple.com/documentation/appintents/appschema/readerintent)
- [Audio schema](https://developer.apple.com/documentation/appintents/app-schema-domain-audio)
- [Defining app entities](https://developer.apple.com/documentation/appintents/defining-app-entities-for-your-custom-data-types)
- [Providing contextual cues to Apple Intelligence and Siri](https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri)
- [App Intents Testing](https://developer.apple.com/documentation/appintentstesting)
- [ViewAnnotation](https://developer.apple.com/documentation/appintentstesting/viewannotation)
