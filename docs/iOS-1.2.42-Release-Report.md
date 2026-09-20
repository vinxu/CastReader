# iOS 1.2.42（64）发布记录

状态：准备中。尚未上传或提交审核；当前手机不可用，真实核心矩阵待验收。

## 基线与分支整合

- App Store 当前已上线 1.2.41（63），`READY_FOR_SALE`；保存的 ASC 读取见 `reports/ios-release-1.2.42/asc-inspect.json`。
- 1.2.41 实际源码不只包含旧报告中的 `febfeab`。已用当时补丁和源码逐文件重建，216 文件摘要与发布记录完全一致：`8670be15e6d5e31df8752192c9b694a81f5149c65a22ce2c0eeb429d75f3dd06`。完整发布增量与后续阅读修复固化在 `94499d2`，证据见 `published-source-baseline.json`。
- 本轮修复 `9935c6d`：微信读书跨页预读接续、完整解读字幕、EPUB 目录修复和 PDF 导入内存优化。
- 插图分支 `d4e427c` 通过正式双亲 merge `3e1d347` 纳入：EPUB 嵌套/重复/内嵌/SVG 插图、PDF 原页与 OCR 几何。保留新版目录索引、资源限制、取消检查、每页 autoreleasepool、2800 像素光栅上限；缓存版本提升为 4，升级重建旧派生内容而保留原文件及阅读位置。
- `0db3f26` 合入旧本地 `main` 历史。其 Google Drive 提交 `f8d2ed3` 已在已发 1.2.29 `334ce5a` 中整合并演进；逐文件核对后保留当前 OAuth、账户隔离、Limited Use 路由及去除未上线 Safari 扩展的发布实现，未倒退到旧文件。
- 统一候选分支 `codex/ios-release-1.2.42`，完整内容同步到 `main` 和 `codex/mobile-voice-explore-20260914`。未来从远端 `main` 建立发布分支，运行 `scripts/build-voice-toc-integration.sh --check`；缺本批必备祖先即失败，不能仅复制功能文件。

## 已完成检查

- 合并后相关单测：42 项执行，38 通过、4 跳过、0 失败。xcresult `/tmp/CastReader1242Merge3.xcresult`，摘要 `merge-tests.json`。跳过项是外部 EPUB 语料、用户指定 EPUB、私有 PDF 导入及私有 PDF 冷重开样本；不能计为通过。
- 第一轮发现测试需要适配新合同：表格单元格明确分隔；PDF 高亮测试先设置当前段落以满足旧回调隔离条件。保留产品隔离检查，未移除断言。修复 OCR 恢复视口定位成功后应返回 true 的合并遗漏。
- 当前 ASC 元数据快照：11 种版本语言、11 种 App Info 语言、9 组共 45 张截图。本版仅计划更新 11 语 What's New，名称、副标题、现有描述/关键词/推广文案及截图保持原样。

## 核心服务门禁

| 地区/输出语言 | 朗读 Kokoro | 朗读克隆 vl/vc | 解读 Kokoro | 解读克隆 vl/vc |
| --- | --- | --- | --- | --- |
| 中国 / 中文 | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |
| 国际 / 英文 | NOT_RUN | NOT_RUN / NOT_RUN | NOT_RUN | NOT_RUN / NOT_RUN |

这批修改触及阅读编排与渲染，不能将旧版本或合并前包的历史测试计入最终候选。继续验收后更新本记录。
