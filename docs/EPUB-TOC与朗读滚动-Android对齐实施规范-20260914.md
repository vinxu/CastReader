# EPUB 目录与朗读滚动：Android 对齐实施规范

日期：2026-09-14。对象：Android EPUB/PDF 阅读器、播放器、导入、阅读进度开发与测试人员。

本文是 **Android 实施与验收规范**。iOS 已有实现与证据；Android 已完成源码核对。本次交接未修改 Android 应用、未编译 Android 包、未执行 Android 验收。“必须”表示本轮对齐要求，“建议”表示可替换的实现方案；示例类型与伪代码不代表现有 API。

## 1. 最终产品约定

两项工作必须一起交付：

1. EPUB 恢复出版物目录的标题、次序、层级和分组；按资源路径与正文锚点准确跳转并保存位置。复杂结构与坏链接不能导致跳错章节。
2. EPUB 和 PDF 朗读时，高亮、播放游标与滚动协同工作，消除“切句先顶到顶部，再回到阅读区”和“每个词瞬移一次”。

**最终比例：触发下边界约为正文可见区域距顶部 88%；触发后，当前词/当前行的上沿平滑移到距顶部 25%，即离底部 75%。**

~~~text
正文可见区域顶部     0%  ┌─────────────────────────┐
                        │                         │
阅读区上界         18%  ├─────────────────────────┤
滚动后的落点       25%  │ → 当前正在读的词/行      │
                        │   后续正文              │
                        │   后续正文              │
                        │   后续正文              │
触发下界           88%  ├─────────────────────────┤
正文可见区域底部   100%  └─────────────────────────┘
~~~

目标完整位于 18%–88% 区间时保持原位。88% 是触发线，25% 是落点，两者独立。早期讨论中的居中、距顶部 75%、40% 落点均已被替换。

这里的区域是 **阅读器实际未被遮挡的正文视口**，不含状态栏、标题栏、底部播放器、导航栏和遮挡正文的浮层。不是整块手机屏幕高度；键盘、横屏、系统字体和播放器尺寸变化后需要重新测量。

目录点击属于显式导航：目标正文边界对齐正文视口顶部，不套用朗读的 25% 落点。点击目录后停在该位置，用户点击播放才朗读；不能自动消费 TTS、改变睡眠计时的用户恢复状态，或被旧高亮拉回旧章。

## 2. 源码基线与保护范围

| 项目 | 本次核对快照 | 用途 |
|---|---|---|
| iOS | [513c674e5db3ddd21a45585e85f8e122d7665314](https://github.com/vinxu/CastReader/commit/513c674e5db3ddd21a45585e85f8e122d7665314)，分支 codex/epub-toc-20260914 | 本轮 TOC、平滑滚动、最终比例及测试的实现依据 |
| Android | [82fe75504a826e6940122b4288bde294af1b2490](https://github.com/vinxu/CastReader-Android/commit/82fe75504a826e6940122b4288bde294af1b2490)，分支 codex/kindle-offline-latest-20260914 | 改造位置的只读核对快照，核对时工作树干净 |
| Android 发布祖先 | 8922600，已验证是上述 Android 快照祖先 | 仅说明本次基线关系，不代替实施时查询最新线上产物 |

本机工作树：

- iOS：/Users/xuxuheng/Documents/.worktrees/CastReader-epub-toc-20260914
- Android：/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-offline-latest-20260914

Android 主目录 /Users/xuxuheng/Documents/CastReader-Android 当时是旧基线且有大量未提交修改，不应直接以它覆盖最新集成。在实际开发时确认最新发布祖先，增量整合。

必须保留 Android 已有能力：

- EpubResourceStore 的文件资源、按需提取、LRU 与降采样，导入资源上限、协程取消和 close 清理；不照搬 iOS 的内存图片字典。
- DocSession.contentSessionKey、导入代次、播放器内容代次与队列代次，账号/发行区归属及历史持久化边界。
- 已有 Kindle 离线连续播放、华为翻页、阅读恢复、字号、手动导航、失败恢复、音色、睡眠定时与权限/额度行为。

打包仍遵循 Android 自身 [AGENTS.md](https://github.com/vinxu/CastReader-Android/blob/82fe75504a826e6940122b4288bde294af1b2490/AGENTS.md)：先确认 Play/CN 线上源码与祖先，保留构建配置门禁，使用既有私有配置与签名流程，不通过卸载清数据解决签名冲突。本文不包含密钥，也不变更发布流程。

## 3. Android 当前代码的具体缺口

以下为上述快照的实际代码事实；“建议入口”是实施建议。文件路径均相对 app/src/main/java/com/same/castreader。

| 已有位置/符号 | 核对结果与影响 | 建议入口 |
|---|---|---|
| epub/EpubNativeEngine.kt：EpubDoc、parseFile | 返回标题、段落、图片资源；遍历 book.spine.spineReferences 后只使用 HtmlParser.parse 的 paragraphs，未交付完整出版物 TOC | 增加导航结果及正文位置索引；目录候选先于正文锚点提取 |
| util/HtmlParser.kt：parse | 自身 TOC 由正文 h1–h6 生成，不能替代 NAV/NCX；还过滤 header/footer/table/svg，class 子串含 nav/toc 也会丢弃 | 新建 EPUB 专用正文解析器，保留共享解析器其他输入行为；使用语义与完整 class token |
| 同上：findElementId / MarkdownParagraph.anchorId | 单个段落 ID 无法表达同段多个锚点、跨文件同 ID、空锚点和容器边界；合并后 ID 又改为 epub_$index | 源身份与运行时 index 分离，保存一个块对应的多个源锚点 |
| EpubReaderScreen.kt：段落 LaunchedEffect，约第 93 行 | 段落、视口或 appearance 改变都 scrollToItem，然后 refocusEpoch++ | 移除无条件段首跳转，统一交给视口协调器 |
| 同文件：EpubParagraphItem，约第 200 行 | 词变化、布局、refocusEpoch 又执行 BringIntoViewRequester.bringIntoView | 子项只报告文本坐标，不再独立驱动朗读滚动 |
| PdfReaderScreen.kt：约第 92 行 | 每次 highlight 直接 scrollToItem；虽有 .25，但没有保持区、动画合并，采用整屏尺寸且未完整处理缩放 | 与 EPUB 共用决策器；提供经过完整变换的词矩形 |
| EpubReaderViewModel.playParagraph | 调用 loadAndPlayParagraph，属于点击正文后直接朗读 | 另建 navigateToTocEntry，不复用自动播放动作 |
| PlaybackController.pause | 已取消 TTS、预取，推进代次、清队列并暂停；未保存新目录位置或设置新导航游标 | 复用暂停语义，补“选择位置但不生成/不播放”的窄接口 |
| PlaybackController.captureReadingCheckpoint | 依赖实际听过的音频段，无音频目录选择无法自动保存 | 显式创建 audio=null 的位置 checkpoint，复用 repository |
| ui/screens/reader/ReaderShell.kt | 已有 onTOC 和 chrome.showTOCButton，EPUB 当前未接入 | 复用现有壳入口，接入 EPUB 目录面板 |

源码入口：

- [Android EPUB 引擎](https://github.com/vinxu/CastReader-Android/blob/82fe75504a826e6940122b4288bde294af1b2490/app/src/main/java/com/same/castreader/epub/EpubNativeEngine.kt)、[共享 HTML 解析器](https://github.com/vinxu/CastReader-Android/blob/82fe75504a826e6940122b4288bde294af1b2490/app/src/main/java/com/same/castreader/util/HtmlParser.kt)
- [EPUB Screen](https://github.com/vinxu/CastReader-Android/blob/82fe75504a826e6940122b4288bde294af1b2490/app/src/main/java/com/same/castreader/ui/screens/epubreader/EpubReaderScreen.kt)、[EPUB ViewModel](https://github.com/vinxu/CastReader-Android/blob/82fe75504a826e6940122b4288bde294af1b2490/app/src/main/java/com/same/castreader/ui/screens/epubreader/EpubReaderViewModel.kt)
- [PDF Screen](https://github.com/vinxu/CastReader-Android/blob/82fe75504a826e6940122b4288bde294af1b2490/app/src/main/java/com/same/castreader/ui/screens/pdfreader/PdfReaderScreen.kt)、[PlaybackController](https://github.com/vinxu/CastReader-Android/blob/82fe75504a826e6940122b4288bde294af1b2490/app/src/main/java/com/same/castreader/player/manager/PlaybackController.kt)
- [ReadingProgressRepository](https://github.com/vinxu/CastReader-Android/blob/82fe75504a826e6940122b4288bde294af1b2490/app/src/main/java/com/same/castreader/player/progress/ReadingProgressRepository.kt)、[ReaderShell](https://github.com/vinxu/CastReader-Android/blob/82fe75504a826e6940122b4288bde294af1b2490/app/src/main/java/com/same/castreader/ui/screens/reader/ReaderShell.kt)

## 4. EPUB 解析与准确目录

### 4.1 数据契约

建议新增以下概念，可按现有架构拆文件。示例省略序列化注解，不要求直接采用这些类名。

~~~kotlin
enum class TocSource { NAV, NCX, GUIDE, HEADINGS, SPINE }
enum class TargetProblem {
    EXTERNAL, MISSING_RESOURCE, MISSING_FRAGMENT,
    EMPTY_RESOURCE, UNRENDERABLE, INVALID_URI, UNSUPPORTED_LOCATOR
}
data class SourceTarget(
    val resourcePath: String, // ZIP 根相对路径，保留大小写
    val fragment: String?     // null 表示文档起点
)
data class RenderLocation(
    val paragraphIndex: Int,  // 最终渲染列表索引
    val sourceOffsetUtf16: Int = 0
)
data class TocEntry(
    val id: String,           // 来源 + 原始序号，不以标题/href 去重
    val title: String,
    val depth: Int,           // 0 起算，保留真实层级
    val isGroup: Boolean,
    val target: SourceTarget?,
    val location: RenderLocation?,
    val problem: TargetProblem?
)
data class EpubNavigation(
    val source: TocSource,
    val entries: List<TocEntry>, // 前序展开，保留出版顺序
    val repairedFrom: TocSource? = null
)
~~~

要求：

- location 存在时必须指向最终渲染内容。分组与失效项都可没有位置，但 UI 必须区分。
- 同标题、同目标的多个目录项仍保留；各自拥有唯一、稳定的 entry ID。
- 源锚点使用 (resourcePath, fragment)，不同文件相同 ID 互不覆盖。同一文件重复 ID 保留首次有效映射并记录诊断。
- **不要求 Android 与 iOS 全书段落数字相同**：两端 OCR、块类型和分块可能不同，应比较源目标和屏幕原文边界。
- 采用 iOS 的“被引用行内锚点处分块”时，TOC 目标通常是新块 offset 0；若保留段内偏移，必须在渲染、保存、恢复、TTS 四处完整支持。
- 当前章节：可解析项中取 paragraphIndex 不大于当前视觉位置的最大值，同位置选更深层，同深度固定平局顺序。显式选择先保留所选 entry，避免重复目标使勾选瞬间跳走。

### 4.2 解析流水线

~~~text
受限 ZIP → container.xml → OPF
  → manifest / spine / 全部目录候选
  → 汇总每个资源被引用的 fragment
  → 按 spine 提取正文，同时建立锚点
  → 资源有效性处理 + Android OCR 插入
  → 最终段落编号与锚点映射
  → NAV / NCX / guide 选择与校验
  → 必要时 headings / spine 兜底
  → 原子发布 EpubDoc + navigation + 位置索引
~~~

EPUB 3 在 manifest 的 properties 标出导航文件，内部 nav 语义区分章节目录、页码与地标；spine 给出默认阅读次序，不能用文件名排序替代。[W3C EPUB 3.3](https://www.w3.org/TR/epub-33/#sec-nav)

1. 从容器根解析 container.xml 的 rootfile，优先正确 OPF media-type；不默认 OPF 总叫 content.opf 或位于 OEBPS。
2. manifest 建立资源身份，spine 决定正文顺序。不要把 epub4j 返回的 href 默认当 ZIP 根路径，明确 OPF 相对语义，在一处转换。
3. 先收集 NAV、NCX、guide 引用，再解析正文，否则会漏掉段内目标边界。
4. 同一次 DOM 遍历生成正文块及锚点。参考 [EpubContentParser.swift](../CastReader/Utils/EpubContentParser.swift)。
5. 容忍目录引用 manifest 中但漏列 spine 的正文：在 spine 后按确定顺序追加一次。重复资源不重复全文，不把 NCX 当正文。
6. 先决定保留的渲染块，再产生最终 index。缺失/无法呈现的图片不能产生“跳转成功但空白”的目标。
7. Android 低文本量 EPUB 的 OCR 会插入新段落：先绑定源锚点与块身份，插入结束后映射最终 index，不猜测统一偏移。
8. 保留空文本图片块的视觉身份，朗读跳过不可读图像，不把 alt 或文件名合成正文；真实 figcaption/OCR 内容单独作为可读块。
9. 资源输出实际可呈现块后才建立文档起点；尾部空锚点无后续内容时，不借下一文件正文伪装成功。
10. 仅当导入仍属于当前 contentSessionKey 时发布结果；旧解析完成时释放资源，不覆盖新书。

### 4.3 来源与层级

| 优先级 | 来源 | 处理 |
|---|---|---|
| 1 | EPUB 3 NAV | properties 按空白 token 包含 nav；找 epub:type 含 toc 的 nav，兼容 role=doc-toc；处理命名空间前缀别名 |
| 2 | EPUB 2 NCX | 优先 spine@toc 指定资源，兼容 manifest NCX；递归 navMap/navPoint，取每层直属 navLabel/text、content@src |
| 3 | 旧 HTML 目录 | 优先 OPF guide 明确的 reference type=toc，支持嵌套列表与旧式链接列表 |
| 4 | 正文标题 | 真正正文 h1–h6，排除已识别目录文档的标题；标注“自动生成目录” |
| 5 | spine | 按正文资源起点兜底，标题取可用首文本或文件名；无正文不伪造位置 |

NCX 层级来自 navPoint 嵌套，content 指向内容位置。旧书 playOrder 可能错误，本产品保留 DOM 出版顺序，不用它重排。[EPUB 2 OPF/NCX](https://idpf.org/epub/20/spec/OPF_2.0_latest.htm#Section2.4.1)

NAV 的非链接 span 标题是合法分组，应展示并保留子项；不能把无 href 的父项整个丢掉。章节目录、page-list 与 landmarks 分开。[W3C 阅读系统导航处理](https://www.w3.org/TR/epub-rs-33/#sec-nav)

“可用候选”至少有一个实际解析成功目标。整套不可用才降级；部分坏链接保留并禁用，不能逐行拼不同来源。最多 10,000 项、最大 depth 64；正文嵌套深度与 iOS 的小于 256 对齐，超限受控退出并给出诊断。

### 4.4 URI 解析必须共用一条路径

目录 href 基于**目录所在文件**，图片 src 基于**章节所在文件**；HTML base / XML base 按祖先作用域合成有效基址。统一为 ZIP 根相对路径后精确查找。规范背景见 [OCF URL 解析](https://www.w3.org/TR/epub-33/#sec-container-iri)；下表是 CastReader 本轮兼容与拒绝策略。

| 输入/场景 | 要求 |
|---|---|
| ../Text/ch.xhtml#section | 从引用所在文件目录解析 ..，匹配资源内的 ID |
| #section | 同文件片段 |
| ch.xhtml?mode=x#section | query 不参与 ZIP entry 身份，fragment 仍参与 |
| %E7%AB%A0.xhtml#%E8%8A%82 | 百分号解码一次，支持中文资源与 ID |
| a+b.xhtml#x+y | + 保持字面量，不用表单 URLDecoder 转成空格 |
| a%2520b.xhtml | 一次解码后寻找字面量 a%20b.xhtml，不继续变成空格 |
| Chapter.xhtml / chapter.xhtml | 大小写敏感，不模糊匹配 |
| ch.xhtml# | 空片段按文档起点 |
| https、协议相对 URL、file、javascript | 不作为本地正文跳转，不访问网络 |
| 路径中的编码分隔符 %2f/%5c、原始反斜杠、NUL、畸形 URI | 拒绝歧义目标，不跨层重复解码 |
| 不存在的 fragment | 保留失效项，不降到章首 |
| 同名文件位于不同目录 | 不用尾缀或 basename 猜另一个文件 |

Android 的 normHref 只处理 %20 和路径片段，resolveArchiveEntry 存在唯一尾缀兜底，不足以用作 TOC 精确解析。新增 resolver 后先明确 epub4j 资源基准路径，再精确定位，不能用尾缀查找掩盖坐标系错误。数值示例见[机器可读契约](contracts/epub-reader-android-parity-v1.json)。

### 4.5 锚点与渲染块必须可追踪

| 源结构 | 可见落点 |
|---|---|
| h2 id=c | 标题文字起点 |
| section id=c 内含标题和正文 | 容器首个实际渲染块 |
| body id=c | 正文首个实际渲染块 |
| 空 a id=c 后接 p | 紧随空锚点的实际正文 |
| a name=c | 旧命名锚点对应的后续正文 |
| p 内“前文”之后的 span id=c“后文” | “后文”起点，不能回到“前文” |
| 多个连续空锚点 | 可共用后续块，所有 ID 保留 |
| 图片锚点 | 真实图片存在且可呈现时定位图片，否则不可用 |
| 隐藏/页码/脚本节点 ID | 不映射到已移除内容，不借无关正文制造成功 |
| 同章重复 ID | 首次有效映射，输出重复诊断 |

专用正文解析器保留正文 header、footer、表格文字、诗歌与内联相邻文本；按语义去除导航、pagebreak、脚本、隐藏内容。不能用 class 子串过滤：navy 含 nav，stock 含 toc。只对**被目录引用**的内联锚点分块，避免每个 span 都变成 TTS 段落。

图片由现有文件资源层处理：允许 manifest 漏列但正文精确引用、本地存在的可渲染图片；验证、限额和受控提取照常。探测尺寸尽量读元信息，不为 TOC 解码全书大图。异步图片显示时预留可信纵横比，避免加载完成挤走当前词；若移除占位块，重建最终索引并作版本控制，不能沿用旧 index。

### 4.6 “链接能解析但系统性跳错章”的修复

真实样本《交易系统与方法》中，250 条 NCX 文件号系统性偏移，同书 guide 的 HTML 目录提供正确链接。只检查资源/fragment 存在不能发现语义错位。

对齐 [EpubNavigationSelection](../CastReader/Models/EpubNavigation.swift) 的保守候选选择：

1. 标题键：NFC、去 Unicode 空白、小写；不模糊匹配、翻译或删编号。
2. 只让全书**唯一的同名正文标题**投票，重复“序言”“第一章”等不投票。
3. 目标恰为该标题，或位于它前面且中间块 text 全为空，计 matches；否则计 conflicts。未解析/无唯一标题不计票。
4. 原候选满足 conflicts >= 3 且 conflicts > matches，才考虑更换。
5. 替代候选同时满足 matches >= 3、matches > original.matches、matches >= 4 * max(conflicts, 1)。
6. 整套更换并记录 repairedFrom。最后一条意味着无冲突替代也至少需 **4 个**支持，不能写成“3 个就足够”。
7. 只有两套**完整规范化标题序列**一致时沿用原层级，否则使用新来源自身层级。

这是产品兼容启发式，不是 EPUB 标准，也不证明所有目录语义正确。证据不足时不猜改单个链接；测试同时覆盖“不修复”的反例。

## 5. 目录点击、播放器与恢复事务

### 5.1 一次点击的顺序

建议 ViewModel 暴露 navigateToTocEntry(entryId)，实际状态变更在拥有播放器与进度权限的层完成：

1. 按当前书解析 entry；无效项/分组返回，不改变播放。
2. 捕获 contentSessionKey、账号/区域 owner、导航 generation；连续点击最后一次有效意图生效。
3. 解读模式中取消解读生成与播放，解除回调所有权并切朗读；旧 marks 不再驱动滚动。
4. 复用 PlaybackController.pause 的取消/清队列语义，使旧 TTS、预取、完成回调失效。不要调用 clear 丢掉整份文档和进度 owner。
5. 清除旧字幕、高亮、临时 TTS 展示；设置 visualLocation 为精确目录目标。
6. 图片目标视觉停在图片，下次朗读从之后首个可读块开始。iOS 末尾无后续可读块时取最后可读块；整书无可读块时播放禁用。不能用语音起点覆盖视觉位置。
7. 创建 audio=null 的当前位置 checkpoint，经 ReadingProgressRepository.save 与 flush 写入；无需实际播放，不伪造“已听过”的音频游标。
8. 发布一次目录定位请求，等待有效布局后对齐目标顶部并关闭面板；不先展示错误位置再来回修正。
9. 保持暂停。点击播放时走既有权限、睡眠与额度路径，届时才允许词级跟随。

每个异步返回再次核对 session/generation/owner；晚到的旧回调无副作用退出。写入失败通过现有 readingProgressWriteFailure 提示，不宣称恢复成功。

### 5.2 对接现有进度层

Android 已有 PreparedReadingProgress.index.checkpoint(index, sourceOffset, audio, now)，以及 ReadingProgressRepository.save、flush、序列化原子文件、owner/lease 检查。

在控制器新增“无音频选点”方法，更新内部 readingCheckpoint、当前 index、恢复 offset，并复用持久化。只改 EpubReaderUiState 会被 controller state 覆盖；只写历史目录也不能替代 checkpoint。loadParagraphForExactResume 会生成 TTS，不适合纯目录浏览。

视觉位置与语音起点不同时，存储需同时恢复视觉位置与播放意图；扩展 checkpoint schema 时保留旧版读取。新导航提交后，关闭页面不能再把旧音频位置写回来。

### 5.3 缓存与解析版本

iOS 解析缓存版本由 2 升为 3，保存并校验 navigation。Android 不照抄版本号，应对**实际使用的 EPUB 派生缓存**增加 parser/schema version：

- 保存最终段落和导航的一致快照，避免新正文配旧目录。
- 命中时校验索引范围、唯一 ID、层级、源身份和输入 fingerprint；坏/旧缓存重解析，原始 EPUB 与历史保留。
- 内联分块改变 index；现有 ReadingDocumentIndex 无法确定映射时，保留旧数据并显示既有“内容变化/选择位置”提示，不能盲用旧数字。
- 建议添加资源路径/锚点辅助身份以便精确恢复；遵守远程引用不持久化正文/敏感标题的既有约束。
- 不删除书库来让新缓存“正常”。

## 6. Compose 朗读滚动实现

### 6.1 两个错误来源

EPUB 现状是段落 effect 的 scrollToItem 与子项词 effect 的 bringIntoView 同时拥有滚动权；临时 highlight=null 和后续首词把两个目标分开发出。PDF 则是每个 highlight 都直接定位，计算中有 .25 仍会瞬移。

只把 scrollToItem 改成 animateScrollToItem 不能完成修复：第二个请求仍可能取消/改写动画，布局重算还会重启它。必须先收敛滚动所有权，再实现动画。

Android 官方说明 scrollToItem 直接定位，animateScrollToItem 采用动画；列表状态可以通过 snapshotFlow 观察。本仓库 BOM 为 2024.09.00，使用实际依赖提供的 API，不为本修复引入最新版实验性接口。[Compose 列表指南](https://developer.android.com/develop/ui/compose/lists)

### 6.2 协调器输入与所有权

建议共享 ReaderViewportCoordinator，文本和 PDF 各提供几何适配器。

| 输入 | 用途 |
|---|---|
| documentSessionKey、mode、navigationGeneration | 丢弃旧书/旧模式/旧导航事件 |
| 当前段落/页稳定 key，当前词或恢复 offset | 确定唯一朗读目标 |
| textRevision、layoutEpoch | 防止旧文字/旧字号布局参与定位 |
| 真实可见区域、目标矩形、列表边界/剩余滚动能力 | 决策与终点钳位 |
| 用户拖动、惯性滚动、缩放手势 | 用户优先 |
| 动画 generation、剩余位移、计划终点 | 合并词 tick，避免重启 |
| 原因：目录、恢复、朗读、解读标记 | 明确不同动作策略 |

要求：

- 子项只报告矩形，高亮绘制不拥有滚动权。
- 段落变化而词暂缺：用有效恢复字符位置，否则当前段首个实际字形；不能把 null 当作“跳段落顶部”命令。
- 首词沿用同一条路径，已在阅读区就不动。
- 解读标记也经统一协调器按模式门控，不能与朗读并行争抢。本轮不要求把解读 mark 的落点也改为 25%。
- 字体、窗口、图片高度变化使旧布局失效；等新坐标后再判断，不无条件回段首。

### 6.3 坐标与决策公式

以下是产品算法，统一使用“未被遮挡的列表视口局部像素坐标”。target 是当前词/行矩形，不是整段矩形。

~~~text
H = viewportBottom - viewportTop
comfortableTop = viewportTop + 0.18 * H
comfortableBottom = viewportTop + 0.88 * H
landingY = viewportTop + 0.25 * H

若 target.top >= comfortableTop 且 target.bottom <= comfortableBottom：
    不发起滚动
否则：
    delta = target.top - landingY
    在真实可滚动边界内消费 delta
~~~

例：正文视口 800 px，区域起点 0：

- 阅读区 144–704，落点 200。
- 当前词 [680,700]：保持。
- 当前词 [700,720]：越过下界，向前滚 500 px，最终词上沿 200。
- 当前词 [130,150]：高于上界，向后滚 70 px，最终上沿 200。
- 文末只能再滚 60 px：最多滚 60；接下来仍越线也不能重复启动同一个受限动作。
- 视口不足一行高时，建立当前字形/单行的可实现目标，不以整段高亮反复判定越界。

可见 Compose item 的目标矩形，可由 item 偏移、Text 相对 item 偏移、TextLayoutResult 的字形框合成；也可通过 LayoutCoordinates 转成视口局部坐标。计入段落 padding、contentPadding 和 Scaffold padding，但不能重复减同一 inset。

LazyListState 正 scrollOffset 表示内容向前滚。段内/页内目标计算出的 item offset 可能为负，用来让 item 开头留在视口较低位置；不能一律 coerceAtLeast(0)。文档边界由列表处理，不等于每个 item offset 必须非负。isScrollInProgress 同时包含动画和惯性，不能单凭它把自己的动画当作用户操作。[AndroidX LazyListState 源码说明](https://github.com/androidx/androidx/blob/androidx-main/compose/foundation/foundation/src/commonMain/kotlin/androidx/compose/foundation/lazy/LazyListState.kt)

### 6.4 词坐标与文字版本

TextLayoutResult.getBoundingBox(offset) 和行号/行边界 API 给出本次 Text 布局内的位置，之后要转换到滚动视口。[AndroidX TextLayoutResult](https://github.com/androidx/androidx/blob/androidx-main/compose/ui/ui-text/src/commonMain/kotlin/androidx/compose/ui/text/TextLayoutResult.kt)

- 字符 offset 使用 Kotlin/Android 文本布局的 UTF-16 索引；越界、代理对、emoji、俄文/中文混排必须有样本。
- 坐标必须来自**当前实际显示的字符串**。Android EPUB 行目前显示 para.text；先核对 VM 给出的高亮是否映射到它，不能把 processed TTS offset 直接用于不同字符串的布局。
- iOS 当前段显示 processedDisplayText，词时间戳对应这份文字；Android 可以沿用既有可靠原文映射，也可显示 processed 文本，但渲染、高亮、坐标必须同版本。TOC/历史源位置不可被 processed 字符串覆盖。
- 跨行词范围取当前有效字形/行，不用几十行整段作为矩形。
- remember(para.id) 不代表布局仍有效；同时验证文本 revision、宽度、字号/行高/字体、density/fontScale。旧 TextLayoutResult 暂留时不发滚动。

### 6.5 平滑动画与事件合并

常规自动跟随必须有真实中间帧，连续朗读只发生一次方向稳定的运动。建议用 Compose 可取消滚动动画，完成/取消由 Job 生命周期记录；不要移植 iOS 的 0.6 秒超时作为 Android 动画完成信号。

协调器伪流程：

~~~text
onTarget(latest):
    拒绝旧 session / generation / layout
    用户拖动、缩放或用户惯性进行中：缓存最新目标，不抢滚动
    目录浏览暂停中：不执行朗读跟随

    若本协调器有动画：
        用“动画剩余位移”预测最新目标在终点的矩形
        终点仍在 18%–88%：保留现有动画，不重新 launch
        同一个钳位后终点：合并
        否则只保留最新目标，交给一次受控重规划

    没有动画或需要重规划：
        按阅读区公式决定 Hold / Move
        近距离 Move：一个动画 Job
        远距离恢复/导航：一个直接定位事务
        完成/取消：核对 generation，处理至多一个最新待定目标
~~~

实施注意：

- 不把每个词放进会 collectLatest 取消整个动画的消费者。可以合并目标事件，但目标更新与动画 Job 生命周期分离。
- 布局回调不能每帧无条件写状态再触发自身；只发布有效 revision，按行/目标/终点合并。
- 用户开始拖动立即让出所有权，取消自身动画；用户 fling 完成前不抢回。通过 drag interaction 与自有动画 token 区分来源。完全空闲后只评估最新目标，不回放积压请求。
- 不用 PreventUserInput 等高优先级压制手势。
- 协程取消继续向上传播，不能 runCatching 动画后继续 refocusEpoch++ 发旧意图。[Kotlin 协程取消与异常](https://kotlinlang.org/docs/exception-handling.html#cancellation-and-exceptions)
- 当前位移小于像素容差、到列表边界或实际消费量为 0 时停止；避免文末每个词启动一次无效果动画。
- 对齐 iOS：常规位移不超过 1.5 个正文视口时动画；跨很多页的恢复/显式导航直接定位，避免飞越全书。尊重系统关闭/减少动画配置。例外要记录原因，不能作为普通朗读瞬移的借口。

### 6.6 懒加载段落

LazyColumn 未出现的 item 没有可靠 Text 坐标。不能先对齐 item 顶部，让用户看到一帧，再由首词定位到 25%。

建议把“远处 item 实例化”和“精确定位”放在同一导航事务：用稳定 item key 和已知段内目标选择初始位置；若提前测量，文本、宽度、字体、行高必须与渲染一致。等待有效布局后完成定位，测量过渡不能呈现为顶部往返。普通连续朗读不做远跳式遮罩。

长段落必须定位段内字形。iOS 为 SwiftUI 懒加载使用段首点锚，Android 不用复制零高度 SwiftUI 结构，使用自己的 item/offset 语义即可。关键验收：第 70 个未实例化段落一次进入阅读区，首词到达不再次校正。

## 7. PDF 与重排文本

重排 PDF 与 EPUB 共用文本目标和协调器；固定版式 PDF 共用决策器，增加坐标适配层。

Android 当前 PDF boxes 是渲染位图像素。完整变换为：

~~~text
原 PDF/位图内词框
  → 当前页渲染尺寸、旋转/裁切变换
  → 页 item 内位置（含真实图片绘制偏移）
  → LazyColumn 位置与页间距
  → graphicsLayer 缩放、transformOrigin、平移
  → 未遮挡正文视口
~~~

- 当前代码用屏幕宽高，ReaderShell 缩小实际视口后会产生落点偏差；必须测实际绘制区域。
- 当前缩放施加在 LazyColumn 的 graphicsLayer。视觉 delta 与列表 delta 不一定相等；均匀 zoom=z 且只做纵向列表平移时，应将视觉 delta 经变换换回列表 delta，不能直接传放大后的像素。
- 保留用户横向平移和 zoom，自动朗读只调必要的纵向位置；捏合期间暂停跟随，结束后重算。
- 句子高亮只负责绘制，不先跳整句/选区再跳词框；无词时取首个有效字形或恢复位置。
- 页首词可能需要负 item offset，不强制截成 0；页高和图片 bottom padding 参与换算。
- 混合横竖页、旋转页、短页、扫描 OCR、长句跨页分别测试；无词框时只使用确认过的当前页/段起点，不使用旧段残留框。
- 某模式未实现缩放变换时明确未完成验收，不能用 EPUB/重排 PDF 的结果替代原稿 PDF。

## 8. 目录界面

复用 ReaderShell 已有目录入口，面板至少包含：

- 出版顺序与层级缩进；视觉缩进可封顶，真实 depth 不截断。
- 标题搜索，结果带原 entry ID/父级上下文，不修改原树/目标。
- 当前项标识、无链接分组、坏项禁用态及原因文案。
- 自动生成目录的来源提示；正常 NAV/NCX 不增加技术解释。
- 点击可跳项关闭面板并展示目标；打开/关闭目录不开始播放。
- TalkBack 读出标题、层级/分组、当前/不可用状态；动态字体和长中文/俄文标题不遮挡操作。
- 使用现有本地化资源，不向用户展示内部错误码。

## 9. 自动化验收矩阵

下表是 **Android 待实现并执行** 的最低矩阵。建议测试名是新文件建议，不代表仓库已存在。

### 9.1 TOC 与正文映射

| ID | 输入 | 必须断言 |
|---|---|---|
| T01 | NAV、NCX、page-list 同时存在 | 选 NAV toc，不混页码，标题/顺序/层级保留 |
| T02 | NCX 多层，playOrder 乱序 | DOM 原顺序，直属标题不混入子项文本 |
| T03 | 无链接分组、重复标题/目标 | 分组保留，ID 唯一，重复项不丢 |
| T04 | 一份 XHTML 多章；h/p/span/section/body 锚点 | 对应原文边界，不能统一回文件开头 |
| T05 | 空 a、a[name]、xml:id、连续空锚点 | 正确绑定后续块，多 ID 可共用位置 |
| T06 | 中文、大小写、空格、+、%25、query、相对路径 | 符合机器 URI 契约；单次解码 |
| T07 | HTML base、祖先 xml:base、命名空间别名 | 基址与 toc 语义正确 |
| T08 | 缺 fragment、缺资源、外部链接 | 保留禁用，不猜章首/同名文件/标题 |
| T09 | NAV 全失效，NCX 有效 | 整套降级，不逐行混合 |
| T10 | 无目录，有标题/无标题 | headings/spine，明确生成来源 |
| T11 | 被引用 manifest 正文漏列 spine | 追加一次，索引有效，既有顺序不变 |
| T12 | 缺图、空封面、manifest 漏列真实图 | 不伪造坏目标，合法精确引用可呈现 |
| T13 | navy、stock、正文 header/table、隐藏页码 | 正文保留，噪声移除，文本不重复/丢失 |
| T14 | 系统偏移 NCX + 正确 guide | 满足阈值才替换，完整标题同序才保留原层级 |
| T15 | 仅两个冲突、替代仅三个支持、重复同名标题 | 不触发无证据修复 |
| T16 | 超深树、超项数、坏 ZIP、超资源限额 | 可控退出/降级，无 OOM/死循环，不把半结果当成功 |
| T17 | OCR 插入、异步图片、取消解析后换书 | 最终索引有效，旧结果不发布，资源释放 |
| T18 | 缓存重开、旧 parser version、坏导航缓存 | 可重建，原文/历史保留，目录和位置一致 |

建议 EpubNavigationParserTest、EpubContentAnchorTest、EpubTocSelectionTest。保留现有 EpubResourceStoreTest、导入、远程持久化和阅读恢复回归，防止丢失 Android 原保护。

### 9.2 滚动

| ID | 场景 | 必须断言 |
|---|---|---|
| S01 | 当前/下一段在阅读区，highlight=null→首词 | 保持，偏移噪声不超过 2 dp，无顶部往返 |
| S02 | 当前词越过 88% | 一次平滑前移，上沿到 25%；无钳位时误差不超过 2 dp |
| S03 | 目标高于 18% | 一次到 25%，不先段首再回落 |
| S04 | 动画中每 30–100 ms 来下一词 | 多个中间帧、方向单调，同终点不重启 |
| S05 | 同行多词、重复布局回调 | 无新增滚动 |
| S06 | 80 行段落读第 60 行 | 当前行进入阅读区，段首不干扰 |
| S07 | 第 70 个未实例化 item，前后远跳 | 首词无二次校正，无可见顶部闪现 |
| S08 | 字号/行距、横屏/分屏、图片高度变化 | 使用新布局，当前词正确且不回段首 |
| S09 | 拖动/fling/捏合中持续来词 | 立即让出，手势中零抢滚动，结束只评估最新目标 |
| S10 | 文首/文末/短文、目标大于视口 | 合法钳位，无空动画或振荡 |
| S11 | PDF 页中、页首、跨页、混合尺寸 | 真实视口 25%，无整句再词的双路径 |
| S12 | PDF zoom 1×/2×/5×、平移/旋转 | 坐标正确，横向位置保留，不用整屏高度猜 |
| S13 | 减少/关闭动画，远距离恢复 | 可直接定位并记录原因；短距离不滥用例外 |
| S14 | 目录跳转后旧词/mark 晚到 | 保持所选顶部和暂停，不被拉回 |
| S15 | EPUB、重排 PDF、原稿 PDF | 逐模式分别记录，不互相替代 |

2 dp 是 Android 本轮建议几何容差，按 density 换算；iOS 原测试使用 2 point。记录布局稳定后的误差与逐帧偏移，不能只看最终截图。

建议 ReaderViewportPolicyTest（纯决策）、ReaderViewportComposeTest、PdfViewportGeometryTest（真实宿主）。纯函数不能证明 LazyColumn/Text/PDF 动画没有被第二消费者取消。

### 9.3 导航与恢复事务

| ID | 场景 | 必须断言 |
|---|---|---|
| P01 | 播放中点目录 | 旧音频停，旧请求失效，新处暂停，不生成新 TTS |
| P02 | 从未播放，目录跳转后退出/杀进程重开 | 所选位置、目录当前项正确，不自动播放 |
| P03 | 快速 A→B + A 旧回包 | B 生效，A 无晚到副作用 |
| P04 | 解读中点目录 | 解读停，朗读暂停，旧 marks 不滚动 |
| P05 | 图片目标，末尾无后续可读块 | 视觉/语音起点符合第 5 节，重开视觉不丢 |
| P06 | 重解析改变段落划分 | 确定映射才恢复，否则保留数据并提示选择 |
| P07 | 切书/切账号/切区、删除后旧写入 | session/owner/lease 拦截，不能恢复被删数据 |
| P08 | checkpoint 写盘失败 | 反馈失败，不声称成功，不回写旧音频位置 |
| P09 | 睡眠已暂停/额度不足时浏览目录 | 不自动恢复计时/生成音频；播放走原闸门 |

## 10. 多文件真机验收

### 10.1 样本分层

1. **合成样本**：NAV、NCX、无目录各一份，涵盖行内/空/命名/容器锚点、重复项和坏链接。参考 [iOS EpubNavigationTests](../CastReaderTests/EpubNavigationTests.swift) 的自造 XHTML，不能只测 h1/h2。
2. **真实 EPUB**：不同转换器、EPUB 2/3、同文件多章、中/英/俄文、数千段大书、深目录、图片与扫描/OCR。优先复用 iOS 样本指纹。
3. **故障样本**：坏 ZIP、缺资源、空封面、系统偏移 NCX、深度/资源超限。
4. **PDF**：重排和原稿分开；原稿追加扫描、长句、混合尺寸与缩放。

原书仅在授权本地目录使用，不提交 Git，不为“上传测试”上传到额外服务。通过 Android 正常文件选择/导入入口；若有既有云端上传入口，分别记录传输和本地解析阶段，不以直接向 VM 注入字节替代用户路径。缺语料明确 SKIP，不扫描任意默认下载目录。

### 10.2 每本操作

1. 从正常入口打开系统文件选择器并导入，记录文件 SHA-256、结构、包版本/commit、设备/系统、模式。
2. 核对目录首/中/尾、父子层级、重复标题、搜索、分组与坏项。
3. 前部跳尾部再回中部；对照原 href/fragment 正文，记录原文边界是否在屏幕。
4. 播放中跳章确认旧音频停；点击播放从新位置开始。正常与较高速连续播放，至少跨 10 个段落、5 次自动滚动。
5. 不播放再选目录项，退出重开、杀进程重开各一次，确认目录/位置恢复。
6. 调大字号、横屏、手动拖动、文末重复词；原稿 PDF 加捏合/横向平移。
7. 故障文件后继续导入正常文件，确认应用可用、临时资源清理。

至少一台接近用户环境的华为真机、一台不同厂商/系统设备；有条件覆盖较低内存设备。正常冷启动录像。遵循 Android AGENTS：真实体验验收不由 Compose 测试时钟接管，避免测试框架对无限动画的处理误导结论。

### 10.3 独立核对与日志

解析器自己的“目标=自身索引”不能证明准确。独立工具根据源 href/fragment 提取边界，再与 App 输出比较；本地可比较前 100 个非空白字符，图像比较精确资源身份。语义错位另以唯一正文标题和人工抽样检查，DOM 对照不证明标题语义。

iOS [verify-epub-toc-corpus.py](../scripts/verify-epub-toc-corpus.py) 可作方法参考；Android 输出 schema/分块不同，适配后使用，不假设直接兼容。

测试日志建议：

~~~json
{
  "type": "reader_follow",
  "sessionGeneration": 12,
  "mode": "epub",
  "reason": "word_below_band",
  "paragraphIndex": 123,
  "layoutEpoch": 7,
  "viewportHeightPx": 800,
  "targetTopPx": 700,
  "targetBottomPx": 720,
  "requestedDeltaPx": 500,
  "animated": true,
  "animationGeneration": 4
}
~~~

另记完成/取消原因、实际消费、钳位、计划终点、用户交互状态。目录日志记录本地文件 hash、entry 序号、来源、解析状态；原文只留本地受控报告，不记正文、账号/token、私有外部链接到提交的日志。

### 10.4 构建与报告

当前 Android flavor 为 global / cn。以下是实施后正确工作树中的检查命令；本交接**未执行这些 Android 检查**：

~~~bash
git merge-base --is-ancestor <实际线上源码提交> HEAD
./gradlew :app:testGlobalDebugUnitTest :app:testCnDebugUnitTest
./gradlew :app:assembleGlobalDebug :app:assembleCnDebug
./gradlew :app:connectedGlobalDebugAndroidTest
~~~

私有构建配置、同签名安装参数与设备选择按 Android AGENTS，发布/送商店仍按发布流程。无关基线失败单独记录，不为报告变绿跳过或改无关功能。

| 报告字段 | 内容 |
|---|---|
| 构建身份 | commit、分支、版本/build、APK SHA-256、发布祖先 |
| 设备 | 型号/系统、density/fontScale、窗口/播放器视口、动画设置 |
| 样本 | SHA-256、NAV/NCX/guide、有效/坏目标数、解析/OCR模式 |
| 自动化 | 实际测试名、通过/失败/跳过及原因、结果文件 |
| 真机 | 每本正常导入、准确跳转、无播放恢复、连续滚动录像 |
| 滚动 | 中间帧、最大反向偏移、落点误差、重复请求、手势冲突 |
| 性能 | 解析/OCR耗时、峰值内存、图片缓存上限、取消/释放 |
| 结论 | T/S/P 逐项 PASS/FAIL/SKIP，未通过项与剩余限制 |

[机器可读契约](contracts/epub-reader-android-parity-v1.json) 是静态验收合同，不是 Android 通过报告。

## 11. iOS 证据与适用范围

| 已有结果 | 证明范围 | Android 要补的证据 |
|---|---|---|
| 84 本有效 EPUB，2,915 项目录，2,911 个精确目标，4 个原书坏目标禁用；9 个坏 ZIP 拒绝 | iOS 本批语料解析与边界 | 相同文件 Android 解析，比较资源/边界，不强求段落号 |
| 2,911 个可跳目标独立 DOM 对照零不一致 | 资源与原文起点 | Android 独立核对，另做语义/屏幕检查 |
| iPhone 7/7 正常 Files 导入与目录流程 | iOS 导入、目录、暂停跳转/恢复 | Android 文件选择器与既有本地/云端入口 |
| 最终 25% 滚动专项 7/7 通过并安装 iPhone | iOS 自动化几何/动画与安装身份 | Android Compose 宿主与最终比例真机录像 |
| 早期平滑版真机 EPUB/PDF 连续播放通过 | 当时落点 40%、下界 70%；PDF 为重排 | 不冒充最终 25% 真机、原稿 PDF 或 Android 通过 |

iOS 最终测试包 1.2.39（60）。最后一次 25% 调整时镜像提示手机在使用，因此完成自动化与安装，未得到新屏幕复验。不得改写成“全部模式最终真机均通过”。

具体资料：

- [EPUB 结构调研与验收](EPUB-TOC-Research-and-Acceptance-20260914.md)
- [滚动根因与验收](Reader-Scroll-Fix-20260914.md)
- [EPUB 汇总](../reports/epub-toc-20260914/validation-summary.json)、[iPhone 逐本记录](../reports/epub-toc-20260914/iphone-acceptance.md)、[输入指纹](../reports/epub-toc-20260914/iphone-input-manifest.json)
- [滚动汇总](../reports/reader-scroll-20260914/validation-summary.json)、[最终源码身份](../reports/reader-scroll-20260914/source-identity-upper-quarter.json)
- [目录模型与选择](../CastReader/Models/EpubNavigation.swift)、[EPUB 引擎](../CastReader/Services/EpubNativeEngine.swift)、[视口协调](../CastReader/Views/Reader/ReaderTextView.swift)、[滚动测试](../CastReaderTests/ReaderViewportTests.swift)

原书、原文片段、完整日志、中间设备回执仅在本地报告目录。仓库保留精简汇总与指纹；复测配置语料路径，不硬编码开发者用户名。

## 12. 实施拆分与交付条件

建议四个可审阅提交，最后仍整体验收：

1. **解析与模型**：专用正文/锚点、URI、候选 TOC、最终索引、资源/OCR一致性，T01–T18。
2. **目录 UI 与恢复**：ReaderShell、层级/搜索/禁用、无播放 checkpoint、缓存升级，P01–P09。
3. **滚动协调**：去双路径、统一比例、动画合并、PDF 坐标，S01–S15。
4. **真机与报告**：多 EPUB/PDF 导入、目标对照、录像、原恢复/播放器/Kindle/资源回归。

交付检查：

- [ ] 使用 18%–88% 保持区、25% 上方落点；目录仍对齐目标顶部。
- [ ] 朗读只有一个滚动所有者；旧词/旧布局/旧模式无法抢回位置。
- [ ] 目录依据资源/锚点，坏项不猜，同文件多章与内联锚点覆盖。
- [ ] 无音频导航也保存；冷启动、缓存迁移与账号/会话隔离通过。
- [ ] Android 文件资源、OCR、取消和播放器恢复保持。
- [ ] 各 Android 模式独立记录，iOS 结果未被当成 Android 结果。
- [ ] 真机多个平滑中间帧，88% 后到 25%，无往返、重启和手势争抢。
- [ ] 报告包含失败、跳过与支持边界。

范围是能映射到原生内容的 EPUB 目录与朗读滚动，不包含 DRM 解密、脚本生成位置、完整固定版式 SVG 排版、EPUB CFI 解释。不能映射的目标明确不可用；不以未经限定的“支持所有 EPUB 结构”作为发布结论。
