# EPUB 目录错位修复与验证（2026-09-20）

修复已增量落在当前发布集成工作树 `CastReader-mobile-voice-explore-20260914`，HEAD `febfeab` 加既有 1.2.41 / Kindle / WeRead 增量。主目录旧分支没有 EPUB TOC 功能，因此未在旧基线覆盖实现。未安装真机、上传或提交新版本。

## 原因

用户附件 `ocb.epub` 的 NCX 和 OPF guide 目录都有 40 个条目，标题及顺序一致，但 NCX 的目标文件发生系统性错位。其中 13 个链接指向章节末尾无后续内容的空 `calibre_pb_*` 分页元素；截图中的“三”“四”均指向 `text/part0007.html#calibre_pb_7`。其余部分条目虽然可点，也会跳错章节。

OPF guide 指定的 `text/part0040.html#filepos506898` 保留正确链接：“三”指向 `text/part0015.html#filepos165612`，“四”指向 `text/part0016.html#filepos170876`。39 个 guide 锚点的文字与目录标签完全一致，首个空锚点正常对应紧随其后的正文。

原 `EpubNavigationSelection` 仅用 `.heading`（h1–h6）建立核验依据，附件却用 p / blockquote / span 表示标题，导致已有整份目录纠错逻辑未触发。解析本地 EPUB 时即可复现，问题位于 iOS 目录源选择，不需要修改上传服务。

## 变更

- `EpubNavigation.swift`：以出版物目录明确链接到的段落为证据；若目标文字与唯一目录标签完全一致，即使不是 h1–h6，也可参与核验。重复标签和多个不同位置的同名目标不参与纠错。继续要求至少三个冲突以及足够强的备选目录证据，不按标题搜索并改写单项链接，不将末尾空锚点随意映射到下一章。
- 保留正常 NAV / NCX 优先级；完整标签序列一致时保留原目录层级。无确切备选依据的坏链接仍禁用。
- `LocalDocumentCache.swift`：增加 EPUB 专属目录缓存版本。已有书籍重开时从保留的原始文件重建一次；PDF 缓存和阅读进度独立保留。
- `EpubNavigationTests.swift`：增加转换器错位、非标准标题、末尾空锚点、重复标题与不足证据保护、旧缓存恢复，以及外部原始样本的全部目录浏览回归。私人 EPUB 未加入仓库或应用包。

## 验证

- `bash scripts/build-voice-toc-integration.sh --check` 通过，保留所需发布祖先。
- 专用 DerivedData `/tmp/CastReaderEPUBRepair20260920`；专用 iOS 26.5 模拟器 `9B9DC969-34F1-488A-A6E5-2448472AD414`。
- 修复前新增两项测试均失败，重现错位 / 禁用及陈旧缓存问题；修复后同样测试通过。
- Workspace `build-for-testing` 成功。`EpubNavigationTests`、`EpubNativeEngineTests`、`LocalDocumentCacheTests` 共 26 项：25 通过、1 跳过、0 失败。跳过项为缺少可选本地 PDF 性能样本，与此问题无关。
- 原始附件最终选择 guide，40/40 目录可定位；真实 `ReadAloudViewModel.navigateToEpubParagraph` 对全部 40 项都更新到正确段落并保持未播放。
- 独立 Python ElementTree 校验 40 个 guide 链接、文件、fragment 和对应正文前缀，全部通过（不是仅断言按钮可用）。
- 测试启动曾遇 CoreSimulator `Invalid device state / Mach -308`；重启本任务模拟器后，相同二进制重跑通过。该次为环境启动失败，未发生测试断言失败。
- 本次未执行真机手动点击或 App Store 发布。

原始证据见 `source-audit.json`，独立核验见 `verified-destinations.json`，测试摘要与源码 SHA-256 见 `validation.json`、`before-tests.txt`、`after-tests.txt`。

## 复跑原始附件

对 build-for-testing 生成的 xctestrun 中 `CastReaderTests.EnvironmentVariables` 设置：

- `CASTREADER_EPUB_REGRESSION_PATH`：原始 ocb.epub 路径。
- `CASTREADER_EPUB_CORPUS_DIRECTORY`：只含该样本的本地目录。
- `CASTREADER_EPUB_CORPUS_REPORT`：Swift 目录核验 JSON 输出路径。

用 `xcodebuild test-without-building` 运行上述三个测试类。然后执行：

```sh
/usr/bin/python3 reports/epub-toc-repair-20260920/verify_destinations.py /tmp/CastReaderEPUBRepair-corpus.json reports/epub-toc-repair-20260920/verified-destinations.json
```
