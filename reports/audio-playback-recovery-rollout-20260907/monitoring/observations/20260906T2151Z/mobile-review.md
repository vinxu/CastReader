# 2151Z 移动端新增事件只读审阅

新增技术失败只有 `a6fbedfbaf4a619cc70c`：Android 1.0.46/build53 的 `explain_end / failed / pipeline_failed / unexpected_error / pipeline`。原两个朗读失败 `14826f73872753709911`、`75181424100861e4d767` 均按键复核仍在，无其他新增失败。

| 事件 | 客户端 occurred UTC | 服务端 received UTC | 证据 |
|---|---|---|---|
| Explain 开始 | 21:24:16.505 | 21:24:24.746 | 英文 PDF 文件 |
| Explain 首块 | 21:24:56.226 | 21:25:04.245 | `latencyMs=39719` |
| 同内容朗读开始 | 21:25:07.561 | 21:25:17.724 | 新 read session，resume=false |
| 朗读首音频 | 21:25:08.740 | 21:25:17.724 | `latencyMs=1180` |
| Explain 失败 | 21:27:07.828 | 21:27:15.844 | 所选字段无播放秒数，不能记为 0 |
| 朗读 600 秒里程碑 | 21:43:14.564 | 21:43:33.045 | 另有 30/180/300 秒里程碑 |

39.719 秒样本与新增失败具有相同匿名设备、content session 和 **explain session**，这是同会话直接配对。它是 `explain_first_block`，不是 `read_first_audio`。主聚合 `acceptance_core.py:416–423` 的 `firstOutputLatencyMs` 合并这两种事件，因此不能据该 p95/max 声称朗读首音频延迟升至 39.719 秒。

Explain 匿名会话 `6765082db16611044d10`，content `72af40afc1bac633fd74`，device `001fcd8338988e183e62`。随后朗读会话 `68f5388a9c0be3cc92e4` 继续获得播放里程碑；这不构成 Explain 已恢复的证据。未见后续 Explain 重试或成功结束。

Explain 失败距朗读开始 120.267 秒，仅为客户端时序事实；不能据此认定超时、模式切换或取消就是根因。所选 `request_id` / `requestId` / `trace_id` 均无值，没有与 Direct、代理或其他 504 请求的精确关联键。`completionBucket=complete` 与 `result=failed` 同时出现，不能将前者解释为管线成功。

固定字段 GET 完整回读保存于同目录 `mobile-new-failures.json`，完成于 2026-09-06T21:57:17.416029Z。上下文查询截至 21:57:15.172636Z；无账号/原始设备或会话标识、正文、音频或任意 metadata 导出，无合成和生产修改。
