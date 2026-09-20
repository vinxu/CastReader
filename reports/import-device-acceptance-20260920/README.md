# EPUB / PDF 真机导入验收（2026-09-20）

本轮使用 iPhone 15 Pro Max、iOS 26.7 (23H24)，通过 macOS iPhone Mirroring 实际操作 CastReader 的“Upload File”系统文件选择器。手机上的两个文件与用户附件 SHA-256 一致。修复包已安装并留在该手机，未发布到 App Store。

## 验收结论

| 项目 | 真机实测 | 结果 |
| --- | --- | --- |
| EPUB 目录 | 实际导入得到 1,463 段、40 个有效目录；从真机取回解析缓存，与 EPUB 源文件独立核验的 40 个目标逐一比对；镜像实点“欧洲”“三”“四”均定位到对应正文 | 通过 |
| 全部目录导航 | 真机 XCTest 调用生产导航方法遍历 40 项，均定位正确、无失效目录；修复从 NCX 选择为经正文印证的 guide 目录 | 通过 |
| PDF 完整导入 | 镜像从文件选择器导入完成，未闪退；另一次真机自动导入也通过。242 页产生 3,510 段，241 页包含正文，仅原文件第 8 页为空白 | 通过 |
| 首次效率 | EPUB 生产解析 0.189 秒；PDF 生产导入流水线 9.963 秒；镜像实际点击 PDF 到阅读器出现约 10.954 秒 | 通过本样本验收 |
| 再次打开 | 文库重新打开 PDF 命中解析缓存：缓存读取 0.033 秒，应用内部准备并提交阅读器 0.043 秒；不是重新跑 OCR | 通过 |
| 内存与稳定性 | 实际 UI 导入 Instruments 采样峰值 759,809,904 字节（约 725 MiB），结束后回落至 205,112,984 字节（约 196 MiB）；另一次真机 XCTest 100 毫秒采样峰值 770,557,808 字节（约 735 MiB），低于该样本 1 GiB 回归上限 | 通过 |

PDF 完成后在镜像中实际滚动、退出、从文库再次打开，正常响应。结束真机自动测试后重新启动 App，再从文库打开 PDF 也命中缓存：缓存读取 0.032 秒，内部准备并提交阅读器 0.051 秒，镜像已确认显示正文。计时不含人为停留在文件选择器的时间。缓存准备耗时来自应用日志，不等同于系统转场动画耗时。Instruments 峰值为采样观测值，回归上限不是 iOS 通用内存终止阈值。本结论限定为上述真实设备和两个用户原文件；没有将模拟器结果冒充真机结果，也没有在用户真机重跑已知可能导致内存终止的旧实现。

真机 OCR 与模拟器 Vision 结果的段落切分稍有差异（3,510 vs 3,507），页覆盖完全一致；没有通过丢页、截断文档或降低输入文件完整性来避免崩溃。

## 修复与测试源码

- 集成工作树：`/Users/xuxuheng/Documents/.worktrees/CastReader-mobile-voice-explore-20260914`
- HEAD：`febfeabf869c2f77b57d360e970218899c87aa02`，包含本地待提交修复和既有集成变更。`source-fingerprints.json` 保存本问题源码及测试文件指纹。
- 安装包：1.2.41 (63)，Debug dylib UUID `7A9ED6BA-1584-3403-8D03-58647AEF8EE3`。
- 构建前通过 `bash scripts/build-voice-toc-integration.sh --check`；构建通过同脚本 `--device`，独立 DerivedData `/tmp/CastReaderImportDevice20260920/DerivedData`。
- 两项附带私有样本的回归测试现可显式指定真机 Documents 下的相对路径；没有路径时仍跳过，不将附件嵌入 App 或提交仓库。本轮 2 项真机测试实际执行并通过，0 失败、0 跳过。
- EPUB 根因及模拟器回归：[EPUB 修复记录](../epub-toc-repair-20260920/README.md)。PDF 位图 3x 隐式放大及每页临时对象释放修复：[PDF 修复记录](../pdf-import-memory-20260920/README.md)。

## 证据

- `validation.json`：实际 UI 导入缓存的目录、页覆盖及文件哈希验证。
- `ui-reader-events.txt`：镜像目录点击、导入和缓存打开的应用日志摘录。
- `pdf-ui-memory-summary.json`：真实界面导入的 Instruments 内存采样。
- `pdf-device-test.json` / `device-test-summary.txt`：独立真机自动测试指标与通过记录。
- 原始设备测试包：`/tmp/CastReaderImportDevice20260920/device-tests.xcresult`。
- 原始 Instruments 记录：`/tmp/CastReaderImportDevice20260920/pdf-ui.trace`；通过导出的 `activity-monitor-process-live` 表读取 CastReader 进程的 `memory-physical-footprint`。
- 原始私有文档、真机缓存及完整日志保留在 `/tmp/CastReaderImportDevice20260920`，没有复制进本报告目录。
