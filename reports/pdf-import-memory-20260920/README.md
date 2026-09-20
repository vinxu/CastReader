# PDF 导入识别内存修复（2026-09-20）

修复增量位于当前发布集成工作树 `CastReader-mobile-voice-explore-20260914`，保留前一轮 EPUB 目录修复和已有 1.2.41 / Kindle / WeRead 改动。没有安装真机或提交新版本。

## 文件和问题

附件 `The_Psychology_of_Money.pdf` 为 2,982,509 字节、242 页、未加密的混合 PDF，所有页面为 612 × 792 pt。218 页有文本层，24 页无文本层；后者包含 23 页可识别图像和第 8 页空白页。文件 SHA-256、无文本层页码见 `source-audit.json`。

在实际 iOS 导入代码中发现两个叠加的内存问题：

1. `renderPDFPageForOCRCancellable` 已将 PDF 页面尺寸放大到 OCR 所需像素数（本书为 1836 × 2376），却直接使用 `UIGraphicsImageRenderer(size:)`。UIKit 默认再套用屏幕 scale=3，实际得到 5508 × 7128，像素量为预期的 9 倍；对于较大页面，所谓 2800 上限实际上达到 8400。
2. 文本扫描、空白检测和页面绘制没有显式的逐页 autorelease pool，长时间异步导入中 PDFKit / Core Image / UIKit 临时对象可能保留到更晚才释放。

修复前在 3x 模拟器中调用生产渲染函数，尺寸回归测试稳定失败（6 条断言）；原始文件通过真实 `DocumentImportPipeline` 导入时，采样峰值 `phys_footprint` 为 **4,275,288,960 字节（约 3.98 GiB）**，结束时仍约 2.85 GiB，耗时约 98.5 秒。模拟器能完成不代表真机能够承受该占用；该资源暴涨与用户报告的识别中退出高度吻合。没有客户设备的 jetsam / crash 日志，因此不将“客户那次退出已由系统日志确认”作为结论。

## 修改

- OCR 页面绘制显式 `scale = 1`，维持既定像素预算；`opaque = true`、`.standard` 避免不必要的透明 / 扩展色域开销。仍直接将无损页面像素交给 OCR，不通过 JPEG 缩略图识别。
- 为同步文本提取、空白检测和页面绘制加入 autorelease pool，使临时对象逐页释放。pool 不跨越 `await`，取消检查继续生效。
- 保留原有逐页顺序、语言选择、OCR、原始 PDF 数据、段落页码和阅读模式逻辑。没有截断页数、跳过扫描页或改成远端上传。
- 新增 `PDFImportMemoryTests.swift`，通过 `xcodeproj` Ruby API 登记到测试 target；生产改动仅在 `DocumentBuilder.swift`。

## 验证

- 发布集成祖先检查 `scripts/build-voice-toc-integration.sh --check` 通过；workspace `build-for-testing` 成功。
- 专用模拟器 `9B9DC969-34F1-488A-A6E5-2448472AD414`（iOS 26.5 / 3x），独立 DerivedData `/tmp/CastReaderEPUBRepair20260920`。
- 修复后普通页面为 1836 × 2376，超大页面最长边 2800，横向页面同样受限。
- 原始文件完整导入，241 个内容页全部保留、第 8 页为空白；仍为 3507 段，末页索引为 241。没有以减少页面或文本覆盖换取内存下降。
- 第一轮修复后原文件峰值为 **835,985,856 字节（约 797 MiB）**，耗时约 84 秒。该轮前置运行缓存 / OCR 回归，起始进程内存与单独基线不同；最终独立启动复测峰值 **836,526,464 字节（约 798 MiB）**、耗时 **85.4 秒**，相较原始基线峰值下降 **80.4%**；完整页面集合及 1 GiB 回归上限断言均通过。详见 `validation.json`。
- `PDFImportMemoryTests`、`LocalDocumentCacheTests`、`OCRVisionCancellationTests` 共 19 项：18 通过、1 跳过、0 失败。跳过项为既有可选 PDF 性能样本未提供。本次用户原始 PDF 测试确实执行，未跳过。
- 覆盖混合原生 / 扫描 / 空白 PDF，保留可搜索 PDF 原始范围，渲染取消，以及真实 Vision 取消后重试。原始文件回归要求完整内容页集合，并以 1 GiB 作为本模拟器样本的内存回归上限（不是 iOS 通用退出阈值）。
- 本次仅本地模拟器验证，没有客户真机的系统终止复现或发布操作。

## 证据和复跑

`validation.json` 保存源码摘要和结果；`import-before.json`、`import-fixed.json`、`import-final.json` 为同一附件导入采样；`raster-before-tests.txt` 和 `fixed-tests.txt` 为回归摘要。

设置 xctestrun 中 `CastReaderTests.EnvironmentVariables`：

- `CASTREADER_PDF_REGRESSION_PATH`：用户原始 PDF 的本地路径。
- `CASTREADER_PDF_REGRESSION_REPORT`：内存 / 耗时 / 页面覆盖 JSON 输出路径。

运行 `PDFImportMemoryTests/testReportedMoneyPDFImportsEveryPageWithoutExcessiveRasterMemory` 可单独复跑整本导入。私人 PDF 不加入仓库或应用包。
