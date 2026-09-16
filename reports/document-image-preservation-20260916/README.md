# PDF / EPUB 图片保留修复（2026-09-16）

已修复 iOS 本地导入链路中两类内容丢失：EPUB 解析跳过嵌套图片；混合 / 扫描 PDF 因整本文字重排而丢失图片与原页布局。

## 源码范围

- 工作树：`/Users/xuxuheng/Documents/.worktrees/CastReader-document-image-preservation-20260916`
- 分支：`codex/document-image-preservation-20260916`
- 基线：`b10d83ced9b450e63c1d5f4e021849122e2d59d0`，包含已验证的 `b6dd4d7` 发布基线。
- 修改在独立工作树完成；主目录现有改动未被覆盖。

## 修复行为

1. EPUB 按正文顺序保留段落、链接、figure、div、表格中的图片；空 alt、单字 alt、重复图片不会再被误删。保留表格单元格文字、图片和图注。
2. 支持内联 SVG、SVG 文件、SVG 包裹的本地图片、data URI、百分号编码资源路径。正文继续原生渲染；仅单幅 SVG 使用禁用脚本、禁用网络的 WebKit 绘制。
3. 所有有原文件的 PDF 继续显示原 PDF 页面。可搜索页保留 PDFKit 文字范围，扫描页增加 OCR 词坐标，支持朗读高亮、解读标注、点击定位及续读。
4. OCR 使用裁剪框和页面旋转建立坐标变换；显式按目标像素缩放，长边不超过 2800 像素。补充实际栅格像素检查，防止仅坐标往返测试通过但页面缩在中央。
5. 用暗像素检测代替单像素平均亮度，避免稀疏扫描文字被当作空白页。
6. 解析缓存版本升至 3，保存 PDF OCR 坐标。旧 EPUB/PDF 缓存会从保留的原文件重建；测试覆盖新增图片后阅读位置迁移。

## 验证

最终结果：**83 项通过，0 失败，1 项跳过**（78 项单元测试通过、5 项界面测试通过；缺少用户 PDF 的性能样本测试跳过）。另有 12 种解析最小样例全部通过，修复前其中 9 种会丢图片。

测试摘要见 `verification-summary.json`；完整 XCTest 结果保存在 `/tmp/CastReaderDocumentImages-verified.xcresult` 和 `/tmp/CastReaderDocumentImages-legacy-route.xcresult`。主回归日志为 `test-verified.log`；旧 PDF 路由补充测试日志为 `test-legacy-route.log`。当前验证源码的哈希见 `source-sha256.json`。

- 新增专项测试：截图对应的双图结构、嵌套/重复图片、图注与表格、SVG 实际绘制、图片路径、混合 PDF、稀疏扫描、旋转/裁剪坐标、真实栅格像素、高亮和缓存迁移。
- 原有回归：EPUB 解析、持久缓存、ReadingResume、无原文件的旧 PDF 文本回退。
- 模拟器界面：含图 EPUB、120 页原生 PDF、120 页混合 PDF、含图扫描 PDF、长 EPUB 冷启动续读。
- 使用真实文件解析、真实 Vision OCR、PDFKit / WebKit 绘制。界面播放用项目现有确定性音频夹具，不调用收费云端 TTS。
- `scripts/build-reader-more-integration.sh --check` 和 `git diff --check` 通过。
- 诊断用 12 种 XHTML 最小样例的前后输出：`parser-before.json` / `parser-after.json`。

本地界面截图（由 xcresult 导出）：

- `epub-table-and-raster-chart.png`
- `epub-svg-and-repeated-charts.png`
- `pdf-original-searchable-page.png`
- `pdf-scanned-page-ocr-highlight.png`
- `pdf-scanned-page-cold-resume.png`
- `pdf-ocr-reopened.png`
- `standalone-svg-painted.png`

## 边界

- EPUB 保持可重排阅读，保留图片和内容；不保证完整复刻原书 CSS、分页或表格网格布局。PDF 保留原页面。
- 尚未取得反馈用户的《Beating the Street》原文件及 App 版本；本次以源码确认的问题、同结构夹具和现有回归验证，不能声称已复测该用户原文件。
- 本次完成代码和模拟器验证；未提交 App Store，也未覆盖真机安装。
