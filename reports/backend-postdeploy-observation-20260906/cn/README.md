# 中国区部署后真实流量观察

观察截止时间固定为 **2026-09-06 00:24:11 UTC**。Next/TTS 使用 `2026-09-05 18:50:21 UTC` 至截止时间；QuickRead 使用 `2026-09-05 17:51:37 UTC` 至截止时间。共同对比窗采用 Next/TTS 窗口。所有查询均为只读；证据中没有正文、邮箱、IP、token、录音、voice ID、请求 ID、原始日志或数据库连接串。

## 结论

部署后的中国区 TTS 在**服务端 HTTP 供给层**符合预期：共同窗口内 `/api/captioned_speech_partly` 共 268 个 POST，全部返回 200，没有 502、504、其他 5xx、499 或 4xx。其中 195 个请求与 65 轮本地连续供给监控的三段请求精确对应，1 个是切换时的运维请求，余下 72 个只能归为“非监控客户端形态”，不能称为已认证会员或确定真人。

这 72 个请求中，一组浏览器/扩展形态的临时客户端在 `18:55:09Z–18:57:52Z` 连续取得 70 个 200，响应完成间隔中位数 2 秒、P95 5 秒、最大 7 秒；另一组 CastReader/Apple 客户端形态在同一秒取得 2 个 200。前者很像连续分段或预取，但日志缺少请求 ID、输入摘要、`unprocessed_text` 和客户端确认，所以也可能混有重试、自动化或 NAT 后的多个调用。这个间隔不是服务端延迟。

固定监控提供了更强的音频合同证据：共同窗口内 65/65 轮健康，每轮依次覆盖 `stream` 省略、`true`、`false`，三段音频均完整解码且余文归零，无时间戳降级和区域元数据不一致。整轮耗时使用独立聚合器的 nearest-rank 口径：P50 2.631 秒、P95 5.502 秒、最大 15.101 秒。它只使用固定诊断文本和预设音色，证明后端供给，不代表真实客户端已经入队、播放或自动翻页。

克隆音色没有真实窗口样本可评价。通用朗读入口不记录所选 voice，但本区 `voice_clone_usage_ledger` 在共同窗口为 0，专用 clone 入口在共同窗口也没有请求，且没有 quota-admission-degraded 标记。因此没有正常克隆合成发生的证据。对 72 个客户端形态 200，普通非标点请求更支持“预设音色”推断，但证据不足以给每一条硬贴模型标签。

QuickRead 也没有足够真实流量来验证。窗口内：Nginx 对两个 QuickRead 入口均关闭 access log；unit journal 没有窗口内记录；持久化目录没有新 job，也没有旧 job 被续块/compose 修改；`mobile_quickread_job` 和移动端 explain 漏斗均为 0。这支持“未观测到成功 QuickRead 会话、续块或已记录错误”，不能换写成“所有 QuickRead 请求都是 0”或“错误率为 0”，因为无效请求和部分早期失败没有完整请求账本。

Next、QuickRead、Kokoro 隧道、clone 隧道和 Nginx 当前进程的 `NRestarts` 都是 0。固定窗口的 kernel journal 没有保留 OOM 标记；这只能说明当前可读留存内未见 OOM。共同窗口 Nginx error log 只有 2 条未进入 HTTP 应用路由的 TLS 握手记录，没有本地 upstream connect failure、timeout 或 premature close。

## TTS 流量拆分

| 流量类别 | 请求 | 状态 | 能证明什么 |
|---|---:|---|---|
| 本地连续供给监控 | 195 | 195×200 | 65 轮三段合同，音频完整解码、余文归零 |
| 运维请求 | 1 | 1×200 | 切换时服务可达 |
| 浏览器/扩展形态 | 70 | 70×200 | 一组连续服务器响应；身份与播放结果未知 |
| CastReader/Apple 客户端形态 | 2 | 2×200 | 服务器返回成功；身份与播放结果未知 |
| 合计 | 268 | 268×200 | HTTP 层在共同窗口没有错误状态 |

Nginx 当前 access format 不含 `$request_time` 或 `$upstream_response_time`，因此没有真实客户端的 P50/P95 生成延迟。`body_bytes_sent` 也不能证明 MP3 可解码或客户端完整消费响应。

## 部署前段已知异常如何计入

QuickRead 的窗口比 Next/TTS 早 58 分 44 秒。在 `18:31:49Z–18:47:31Z`，新版监控连续 4 轮在 `stream` 省略合同上失败，每轮 HTTP 客户端做 2 次尝试，所以 Nginx 记录 8 个 502。这些请求全部与固定监控对应，没有与客户端形态请求重叠。Next 新版本共同窗口开始后，65 轮监控全部恢复健康，502 为 0。

Nginx error log 还记录了 6 次本机 `:3000` connect failure，发生在 `18:24:03Z–18:50:15Z` 的发布和 reload 阶段，最后一条早于共同窗口 6 秒。正式切换回执本身已经明确这是 restart-based cutover，不应描述成零停机。

## QuickRead 可见范围

`extract-plan`、`extract-block`、`compose-block` 的精确请求量、状态码和延迟目前不可从生产日志还原：有效 Nginx 配置在这些 location 上 `access_log off`，worker 只记录部分 entitlement 判定和错误，不记录每个成功请求。窗口内可给出的下界都是 0：成功新 plan checkpoint 0、旧 job 状态修改 0、移动端 job 映射 0、相关 journal 错误 0。由于缺少请求账本，不能计算分母，也不能声明 0% 错误率。

持久化目录当前有 16 个可解析 job 文件，但最新 job 创建于 `17:49:32.787Z`、最新修改于 `17:49:44.071Z`，均早于 QuickRead 生产观察窗。源码在 [server.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-quickread-cancellation-recovery-20260905/scripts/video-pipeline/server/server.mjs:928) 建立 `quickread-state`，在 [job-assets.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-quickread-cancellation-recovery-20260905/scripts/video-pipeline/server/job-assets.mjs:61) 原子写 checkpoint；所以它是成功任务与持久续块的有效下界，不是完整 HTTP 访问日志。

## 区域证据边界

Next 进程的 `CASTREADER_SERVICE_ROUTE=cn`，预设 TTS 指向本机 `127.0.0.1:18880/dev/captioned_speech`，clone worker 指向本机 `:18890`，QuickRead origin 指向本机 `:7777`，COS 配置 region 为 `ap-shanghai`。共同窗口 65 个成功监控周期都返回 `upstreamNode=castreader-cn4090`、`upstreamSource=cn-environment`，没有 region mismatch。

监控结果里的 `gateway=vercel-r2` 是历史固定字符串，不能用于判断地理路由；实际区域证据来自当前 Next release/cwd、loopback upstream 配置和每次响应的 CN upstream metadata。真实客户端响应的区域 header 没有写入 access log，所以本报告不能对 72 条逐请求做 header 级证明，也不能仅凭 `castreader-cn4090` 标签证明 GPU 的物理位置。

## 日志与账本限制

- `/var/log/nginx/access.log` 完整覆盖两个观察窗；读取时 4,156 行中 4,129 行可按 combined format 解析，27 行未解析，但没有一行包含已知 TTS path。
- Next 的 `app.log` / `error.log` 是 append-only，当前条目没有可用时间戳，发布时也没有保留 byte offset；因此全文件错误关键词不能诚实归入本窗口，本报告未把它们计入错误率。
- `mobile_funnel_events.received_at` 是服务端时间，但窗口内无 read/explain 事件。legacy `analytics_events.created_at` 可能受客户端时间控制，只作辅助证据。
- clone ledger、mobile QuickRead job、移动端 listen ledger 都是历史上已有数据的有效表，本窗口为 0 不是“表不存在”；它仍只覆盖对应鉴权/计费合同。
- 没有 `listen-track` 或 `mobile_listen_usage_event` 可证明真实播放秒数，因此 200 响应不能等价成“用户听完”。

## 代码和配置锚点

- CN TTS 入口进入本机 Next：[nginx-api-castreader-cn.conf](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-cn-tts-upstream-framing-continuity-20260906/scripts/nginx-api-castreader-cn.conf:76)
- QuickRead access log 关闭：[nginx-api-castreader-cn.conf](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-cn-tts-upstream-framing-continuity-20260906/scripts/nginx-api-castreader-cn.conf:189)
- clone 与 preset 分流：[tts-gateway.ts](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-cn-tts-upstream-framing-continuity-20260906/src/shared/lib/tts-gateway.ts:292)
- preset 固定 `stream:false` 和 CN upstream metadata：[tts-gateway.ts](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-cn-tts-upstream-framing-continuity-20260906/src/shared/lib/tts-gateway.ts:338)
- clone durable usage ledger：[schema.ts](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-cn-tts-upstream-framing-continuity-20260906/src/config/db/schema.ts:633)
- mobile QuickRead job 映射：[schema.ts](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-cn-tts-upstream-framing-continuity-20260906/src/config/db/schema.ts:2800)
- QuickRead 三个 handler：[server.mjs](/Users/xuxuheng/Documents/MyProject/.worktrees/readout-desktop-quickread-cancellation-recovery-20260905/scripts/video-pipeline/server/server.mjs:1074)

## 证据文件

- [runtime-and-routing.json](/Users/xuxuheng/Documents/CastReader/reports/backend-postdeploy-observation-20260906/cn/runtime-and-routing.json)
- [nginx-tts-aggregate.json](/Users/xuxuheng/Documents/CastReader/reports/backend-postdeploy-observation-20260906/cn/nginx-tts-aggregate.json)
- [monitor-evidence-reference.json](/Users/xuxuheng/Documents/CastReader/reports/backend-postdeploy-observation-20260906/cn/monitor-evidence-reference.json)
- [business-ledger-aggregate.json](/Users/xuxuheng/Documents/CastReader/reports/backend-postdeploy-observation-20260906/cn/business-ledger-aggregate.json)
- [quickread-observation.json](/Users/xuxuheng/Documents/CastReader/reports/backend-postdeploy-observation-20260906/cn/quickread-observation.json)
- [log-and-error-observability.json](/Users/xuxuheng/Documents/CastReader/reports/backend-postdeploy-observation-20260906/cn/log-and-error-observability.json)
- 独立监控全量聚合：[aggregate.json](/Users/xuxuheng/Documents/CastReader/reports/backend-postdeploy-observation-20260906/monitor/aggregate.json)
