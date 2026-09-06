# Global Vercel 历史日志聚合

## 范围与口径

- 项目：`readout-web`（`prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK`）
- 环境：production
- 主窗口：`2026-09-05T18:50:21Z`（含）至 `2026-09-06T00:24:11Z`（不含）
- 查询方式：`vercel logs --status-code 5xx --json`，按 30 分钟切成 12 片；12 片均成功，每片最多返回 13 条，未触及 1000 条页上限。
- 去重口径：按 Vercel request-log `id` 去重后再单向散列。原始日志、正文、请求体、请求头、IP 和嵌套消息均未落盘。

Vercel 历史日志可能受保留、采集或抽样影响，因此下列数字是“CLI 在该窗口返回的唯一日志记录”，不是已证明的全量请求或唯一用户数。Metrics 查询返回 `payment_required`，本轮没有请求分母，不能计算失败率。

## 5xx 结果

| 路由组 | 状态 | 唯一记录数 | 部署 | 说明 |
|---|---:|---:|---|---|
| preset TTS `/api/captioned_speech_partly` | 502 | 129 | `dpl_58jqfHzCrV91FpC8s2unBG7XXcfX` | 全部为 `POST`、`api.castreader.ai`、serverless |
| 其他项目路由 | 503 | 11 | 同一部署 | 路径已折叠，不纳入音频核心失败 |
| QuickRead | 5xx | 0 | — | 返回日志中未见 |
| voice clone | 5xx | 0 | — | 返回日志中未见 |

129 条 TTS 502 都没有可用的嵌套运行时错误、`traceId`、User-Agent 或客户端身份字段，Vercel 顶层级别也是 `info`。因此只能定为 `http_502_unclassified`，不能从这些记录判断是 worker、网关解析、超时还是调用端中断。

这些 502 呈强周期形态：按相邻记录间隔超过 30 秒划分，得到 65 组，其中 64 组各有 2 条、1 组仅 1 条；组首之间间隔为 288.278–321.492 秒，中位数 310.014 秒。这使“周期性自动调用”成为合理排查方向，但日志没有来源身份，不能把它确认为 continuity monitor，也不能把 `129 - monitor 数` 当成真实用户失败数。

## 已知客户端事件短窗

短窗只查已知普通预设音色使用的 `/api/captioned_speech_partly`。查询按 15 秒切片并按 request-log `id` 去重；所有切片成功且未触及页上限。

| 客户端事件窗口 | 唯一 TTS 记录 | 状态 | 可以确认的事实 |
|---|---:|---|---|
| iOS Kindle `20:45:30.711Z` 前后各 30 秒 | 96 | 200×96 | 窗口内未见该端点 4xx/5xx；不能据此证明那台 iPhone 的具体请求成功 |
| iOS clipboard `20:48:17.066Z` 前后各 30 秒 | 131 | 200×131 | 窗口内未见该端点 4xx/5xx；不能据此证明那台 iPhone 的具体请求成功 |
| Android `23:49:45Z`–`23:53:30Z` | 84 | 200×82、502×2 | 未见 400/401/403/429；两条 502 分别在 `23:52:26.646Z`、`23:52:33.217Z` |

Android 事件聚合记录了 31 次 `generation_failed`，但 Vercel 窗口只有两条 502，并同时有 82 条成功请求。日志不含语言、音色、设备或共享 request id，无法确认两条 502 是否属于西语 `ef_dora` 的那台设备，也无法用这两条记录解释 31 次客户端失败。时间重叠只证明同一窗口存在全球 TTS 502，不构成逐请求因果链。

两次 iOS 事件的精确 ±30 秒窗口没有失败记录。主 5xx 数据中最近的 502 分别在 Kindle 事件前约 46–54 秒、clipboard 事件后约 90–98 秒，也没有共享身份可关联。因此 Kindle 翻页停止不能依据这些 502 归为模型错误；clipboard 失败也不能与相邻周期 502 直接绑定。

## 证据文件

- `vercel-5xx-observation.json`：固定主窗口 5xx 的匿名逐记录元数据和聚合。
- `vercel-client-window-status.json`：三个客户端事件短窗的 preset TTS 全状态记录。
- `collect-vercel-logs.py`、`collect-vercel-client-windows.py`：可复现的只读采集器；原始 Vercel 日志仅在进程内存中解析。
