# EPUB 目录提取、准确跳转与验收

日期：2026-09-14。实现分支：`codex/epub-toc-20260914`。基于已送审的 iOS 1.2.39 应用源码；真机、解析测试和结构调研分开记账，不用模拟器结果代替真机验收。

Android 实施请参照[EPUB 目录与朗读滚动对齐规范](EPUB-TOC与朗读滚动-Android对齐实施规范-20260914.md)，包含现有 Android 源码缺口、精确锚点与恢复事务、42 项验收矩阵及机器可读数值契约。

## 结构调研

EPUB 是容器格式，章节文件的数量和目录条目的数量没有一一对应关系。一章可能跨多个文件，也可能整本书只有一个 XHTML。目录标题也可能与正文标题不同。准确跳转依赖资源路径和片段标识符，不能用标题相似度、文件名排序或第 N 个标题代替。

| 层 | 标准依据 | 本轮处理 |
|---|---|---|
| 容器 | `META-INF/container.xml` 选择 OPF；其 URL 从容器根解析 | 优先正确 media-type，兼容缺失的旧容器 |
| OPF | manifest 描述资源，spine 描述默认阅读顺序 | 以 spine 顺序建立全书段落；容忍目录引用 manifest 内但漏列 spine 的正文 |
| EPUB 3 NAV | `properties` 含 `nav` 的 XHTML，内部 `nav epub:type="toc"` | token 匹配，保留 `ol/li` 嵌套、原始次序、无链接分组；page-list/landmarks 不混入章节目录 |
| EPUB 2 NCX | spine 的 `toc` 指向 NCX；`navMap/navPoint/navLabel/content@src` | 仅取每层直属标签，保留层级；不按不可靠的 playOrder 重排 |
| 旧 HTML 目录 | OPF guide 的 `reference type="toc"` | 在 NAV/NCX 不可用时尝试；不把任意正文链接当目录 |
| 无目录 | 标题 h1–h6，或 spine 文档 | 生成兜底目录并明确标示来源 |

规范来源：[W3C EPUB 3.3 导航文档](https://www.w3.org/TR/epub-33/#sec-nav)、[W3C 阅读系统导航处理](https://www.w3.org/TR/epub-rs-33/#sec-nav)、[IDPF EPUB 2.0.1 NCX](https://idpf.org/epub/20/spec/OPF_2.0_latest.htm#Section2.4.1)、[W3C 容器 URL 解析](https://www.w3.org/TR/epub-33/#sec-container-iri)。目录的链接和非链接标题都需要可访问；页码导航属于另一个结构。

## 精确定位策略

1. 从目录所在文件解析相对 URL，分别处理 path、query、fragment。保留大小写和字面量 `+`，百分号只解码一次。支持中文路径、跨目录 `../`、纯片段引用，以及 HTML base / XML base 的兼容处理。
2. 正文提取与锚点索引使用同一次 DOM 遍历。目标可能是 body、section/div、标题、空 a、旧式 a[name] 或段落中的 span。容器锚点定位首个实际渲染块；空锚点定位其后的正文；被目录引用的行内锚点在该文字边界分块。最终索引指向合并并过滤图片后的真实段落，不使用提取前的临时下标。
3. 当多条 NCX 链接与全书唯一的同名正文标题发生系统性冲突、且另一套原书目录被正文独立印证时，采用正确的原书目录；不对单个链接做模糊标题猜测。若两套完整标题序列一致，可沿用原目录层级。本机《交易系统与方法》验证出这一类真实错误，并由书内 HTML 目录恢复正确跳转。
4. 引用不存在的 fragment 不能退回章首。外部 URL、不能解析的目标保留目录标签，禁用跳转。若整套 NAV 不可用，再选 NCX；不会把两个来源拼在一起产生重复目录。
5. 保持原生阅读与 TTS 的同一段落索引。选目录先取消旧的生成和队列，停在新位置，显式点击播放后再朗读；保存无音频的位置检查点，避免关闭后回到旧章。
6. 已解析文档缓存保存目录，解析版本升级使旧缓存重新构建；原始 EPUB 和既有阅读记录保留。

## 本机样本与验收原则

下载目录按 SHA-256 去重得到 93 个文件：84 个可识别 ZIP/OPF（81 个 EPUB 2，3 个 EPUB 3），9 个损坏或未下载完整的文件。独立 XML 结构扫描识别出最深四层目录，目标包括 html、h1–h4、div、a、span 和 p。部分文件的 XHTML 不符合严格 XML 语法，严格 XML 工具的失败不可直接归因为坏链接，后续以容错 DOM 和真实 App 解析结果交叉核对。

原始结构结果：`reports/epub-toc-20260914/corpus-structure.json`。逐本解析结果、每个目录的目标段落及耗时：`corpus-parser-results.json`。这些只证明提取和索引；真机还需验证用户导入入口、目录可见性、目标是否出现在屏幕、暂停和朗读、重开恢复。

验收矩阵覆盖：NAV 优先、NCX 嵌套、分组无链接、同文件多章、同名标题、中文与百分号路径、旧命名锚点、行内/空/容器锚点、失效链接、NAV→NCX→标题→spine 降级、重复目录目标、缓存重开与无播放跳转恢复。真实书批量检查必须逐本输出，不因首本异常停止。

## 支持边界

本轮目录面向可提取正文的 EPUB；不解 DRM，不把 EPUB CFI 或脚本生成的位置猜成 ID，不实现固定版式 SVG 的完整排版。无法映射到原生正文的目标应不可跳转。目录条目最多 10,000、层级最多 64；正文深度和已有 ZIP 展开/输入大小限制继续生效。

## 最终结果

- 相关单元回归 run4：110 项，109 通过、1 项缺本地 PDF 样本跳过，零失败。包括 EPUB、缓存、阅读恢复、字号、Kindle 导航与 WeRead 起读。
- EPUB 提取复验 run5：14 项全部通过；随后只将本地语料测试改为环境变量配置，run6 的11项目录测试再次全部通过，包含全部93个去重文件。
- 84 本有效 EPUB 均完成提取；9 个损坏 ZIP 均拒绝；总计 2,915 个目录项，2,911 个可跳转、4 个原文件坏目标保持不可用。
- 独立 lxml DOM 对照全部 2,911 个可跳转目标的原文边界（前 100 个非空白字符或图片标记）：零不一致。该检查不代替屏幕跳转验收。
- 真机：iPhone 15 Pro Max，安装开发测试包 1.2.39（60），非 App Store 发布。7/7 输入通过实际 Files 导入与目录跳转（3个结构实验文件、4本完整原书）。覆盖中文、英文、俄文、三级目录、搜索、跨数千段落正反跳转、播放中跳转停止、坏链接禁用、历史重开及进程重启恢复。保留原账号和图书数据。详细记录见[真机逐本验收](../reports/epub-toc-20260914/iphone-acceptance.md)。
- 冷启动后俄文书从解析缓存恢复3,581段、停在 paragraph 95 的原锚点，目录层级与当前章勾选保留，未自动播放。设备回执、源码指纹及筛选日志均在报告目录。
- run6 模拟器本地解析：每本中位数0.211秒，最慢2.225秒；这不是设备导入耗时或网络上传指标。
- 首轮测试的编译问题、损坏 ZIP 分类问题及后续修复均保留原始日志；通过结论以 run4/run5/run6 为准。

## 后续复验

仓库保留精简 `validation-summary.json`、真机逐本验收和输入文件指纹；本报告提到的原书、原文片段、完整测试日志及设备回执保留在本地报告目录，不随源码提交。使用下述测试配置可重新生成逐目标结果。

工作树：`/Users/xuxuheng/Documents/.worktrees/CastReader-epub-toc-20260914`，发布祖先 `b10d83c`，独立真机 DerivedData `/tmp/CastReaderEPUBTOCDevice20260914`。在此运行 `bash scripts/build-epub-toc-integration.sh --check` 核对来源，`--device` 编译真机包；不要从主目录的旧分支覆盖安装。

`EpubNavigationTests` 的可选全语料测试由测试进程环境变量 `CASTREADER_EPUB_CORPUS_DIRECTORY` 指定目录，`CASTREADER_EPUB_CORPUS_REPORT` 指定 JSON 输出；没有本地语料时明确跳过，不依赖开发者用户名或扫描任意默认目录。本轮通过 xctestrun 的 EnvironmentVariables 注入配置，结果包 `/tmp/CastReaderEPUBTOC-run6.xcresult`。生成逐目标 JSON 后，使用带 lxml 的 Python 运行 `scripts/verify-epub-toc-corpus.py` 进行独立边界核对。

以上验收证明本轮样本与已列结构的支持，不代表所有 EPUB、DRM 或固定版式都已覆盖。
