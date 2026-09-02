# Kindle Page Flip 旁观探针

## 目的

在实现“整本书下载”前，用真实 Kindle 账号和真实书籍确认 Web Reader 的 Page Flip 是否能稳定提供：

1. 从第一页到最后一页连续、无缺口的页序号；
2. 可直接保存的清晰页面图，或可与页序号关联的高清预览渲染；
3. 浏览 Page Flip 前后不改变 Kindle 正文阅读位置。

探针只在 Debug 构建中注入。它不会点击、滚动、翻页、读取正文、复制响应体或重放 Amazon 私有请求；Page Flip 的打开、滚动与关闭全部由测试者手动完成。

## 真机采集

1. 用 Debug 包登录 Kindle 并打开一本支持 Page Flip 的书。
2. 通过 Safari Web Inspector 连接 CastReader 的 Kindle WebView。
3. 在 Console 启动一次唯一 run：

   ```js
   JSON.parse(window.__crKindlePFProbeStart('manual-20260902-01'))
   ```

4. 手动打开 Page Flip，从头滚到尾；期间可多次增量拉取，每次最多 100 条：

   ```js
   JSON.parse(window.__crKindlePFProbePoll('manual-20260902-01', 0, 100))
   ```

   后续把上一份结果的 `events` 最后一个 `seq` 作为 `afterSeq`。如果 `hasMore` 为 `true`，继续拉取；如果 `afterSeq < droppedBeforeSeq`，说明 ring buffer 已溢出，本次证据作废并重新采集。

5. 手动关闭 Page Flip，回到原正文页后停止：

   ```js
   JSON.parse(window.__crKindlePFProbeStop('manual-20260902-01'))
   ```

## 放行标准

只有 Native verdict 同时证明以下条件时，才允许进入整书下载实现：

- `positionStable == true`；
- `sawStart == true` 且 `sawEnd == true`；
- `declaredTotal > 0`；
- `ordinalCount == declaredTotal`；
- `ordinalGapCount == 0`；
- verdict 为 `thumbnailDirectCandidate` 或 `previewRenderRequired`。

`enumerable` 只表示页面可完整枚举，尚未证明图像质量；`blockedFrameOrShadow`、`positionUnsafe`、`inconclusive` 都必须继续保留当前安全的页面窗口方案，不能自动翻书或重放私有接口。

