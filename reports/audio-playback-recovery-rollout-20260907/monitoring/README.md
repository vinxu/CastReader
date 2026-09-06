# US proxy v2：只读阶段日志与身份核对

此目录只采集生产代理现有日志、文件摘要、进程和 `GET /health`。不合成音频，不部署、重启或修改远端。源码 SHA、代理 PID/启动标识、R133 模型 PID/启动标识、green/revision 2 和模型回执必须与本轮 apply/status 回执一致。

覆盖起点固定为独立生产状态确认 **2026-09-06T16:36:52.292087Z**。候选进程也使用 v2 release ID，因此脚本拒绝确认前的窗口。Linux 启动时刻估计和 Supervisor 启动日志另存为证据，不能替代确认时间。

```bash
python3 reports/audio-playback-recovery-rollout-20260907/monitoring/collect_proxy_events.py \
  --start-utc 2026-09-06T16:36:52.292087Z \
  --end-utc now \
  --include-events \
  --output reports/audio-playback-recovery-rollout-20260907/monitoring/proxy-first-window.json
```

后续窗口使用明确的 `--start-utc` 与 `--end-utc`（含 `Z` 或 `+00:00`），边界为 `[start,end)`。默认读取合并日志尾部 64 MiB；`--max-scan-mib` 允许 1–128。若扫描起点无法覆盖窗口，保留结果但 `coverage.complete=false`、退出码 2；不要把它当完整窗口。JSON 事件和匿名请求明细默认各最多 2,000 行，参数可调整到 10,000；明细截断不改变全扫描窗口的计数。SSH/解析失败退出码 1，并只输出固定错误类型。

远端先丢弃正文、音频、请求头、原始 request ID、账号信息、异常内容及非目标日志，只导出固定阶段、数字、版本标识和 20 位匿名 hash。`phase` 是本工具从代理 `stage` 派生的分类。`requestKey = SHA256(x-request-id UTF-8)[:20]` 可与网关日志关联，`attempt` 仅取 1/2/3，尚未发送该头的调用方记为 unavailable。共享任务的 `flightKey` 与 `upstreamRequestKey` 是代理新建上游 ID 的 hash；它们不包含正文摘要。相同 requestKey/attempt 再次出现会标记可能混淆，不能强行当作唯一请求。

合并比例有两种明确口径：`callersJoined / (sharedProducersCreated + callersJoined)` 表示共享请求中的合并比例；再加 `independentCallers` 的分母表示所有已接纳请求中的比例。它们按窗口内 admission 事件计数，不是完整请求队列，也不是缓存命中率。共享任务失败分成一条 `shared_producer` 与各条 `shared_caller`，不可相加当作独立上游故障数。取消单列；已写出 200 的连接仍可能在后续体读取阶段失败。

`lastObservedUpstreamPhase` 记录故障前确实看到的阶段。连接复用不会再次产生连接开始/完成事件；只有 `upstream_request_created` 时不能判定连接失败。响应头等待仍不能拆分模型队列、语言锁、G2P 和推理耗时。HTTP 体传完也不能证明音频可解码或用户完成播放。无样本、零错误或零合并均不能独立证明播放可靠性。

`runtime.verified` 是采集时刻的文件/进程/监听/路由身份核对；事件不含进程 PID 或源码 SHA，所以不能凭一次核对推断整个区间从未重启。`identityAndCoverageVerified` 同时要求身份核对和扫描覆盖成立；仍须结合持续验收快照。`firstProxyEventUTC` 包括扫描到的候选阶段，只用于扫描位置证据；统计数据始终排除生产确认前事件。

已有 `reports/backend-audio-rollout-20260906/monitoring/remote_proxy_identity.py` **兼容 v2，无需改代码**：新版本继续使用 `r133_stable_proxy.py` 文件名、8889 端口和 `castreader.us-tts-origin-proxy-state.v1`。调用它时需传入 v2 完整源码路径，并在验收状态中更新 proxy release/source SHA/commit/activeFromUtc。候选和生产同时使用同一路径时会找到两个进程，核对不成立；本次候选已停止。模型 R133、green/revision 2 和模型回执沿用原值。

本工具复用上述现有身份采集器，并在输出中保存两个采集脚本和部署回执的 SHA256，便于复查。模型源码固定为本轮已核对的 R133 `06953419d01f961c70b22b12b4d59ecdfaa187e699cc555b3be4109522368e4e`。若后续正式更新模型或代理，应修改有版本记录的监控预期，不能忽略 mismatch。

本地合成 fixture 验证（不访问生产）：

```bash
cd reports/audio-playback-recovery-rollout-20260907/monitoring
python3 -B -m unittest -v test_proxy_events.py
```

覆盖隐私字段过滤、异常字段稳健性、UTC/确认前窗口拒绝、一次共享故障与多个调用方的计数区分、截断后完整计数以及实际发布回执一致性。
