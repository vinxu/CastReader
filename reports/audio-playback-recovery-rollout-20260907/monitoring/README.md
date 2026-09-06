# US proxy v2：只读阶段日志与身份核对

此目录只采集生产代理现有日志、文件摘要、进程和 `GET /health`。不合成音频，不部署、重启或修改远端。默认入口仍按最初 v2 apply/status 回执核对代理及 R133 模型的 PID/启动标识、green/revision 2 和模型回执。模型切换或代理重启后必须使用新冻结的 `--identity-receipt`，不能忽略旧身份 mismatch。

默认旧回执的覆盖起点为独立生产状态确认 **2026-09-06T16:36:52.292087Z**；新入口使用新回执的 `verifiedAtUTC`。候选进程和正式重启都可能继续使用同一 v2 release ID，因此脚本拒绝确认前的窗口。Linux 启动时刻估计和 Supervisor 启动日志另存为证据，不能替代确认时间。

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

已有 `reports/backend-audio-rollout-20260906/monitoring/remote_proxy_identity.py` 支持 `--model-expectation-json`：代理继续使用固定 v2 `r133_stable_proxy.py` 文件路径、8889 端口和 `castreader.us-tts-origin-proxy-state.v1`；新入口将本地模型期望原样传给它。无此参数时仍沿用原 R132/R133 固定映射。候选和生产同时使用同一路径时会找到两个进程，核对不成立。每次采集还核对模型固定槽位端口、Supervisor、监听进程、启动标识、启用状态、源码路径/SHA 与模型回执。版本 commit 是冻结期望标签；远端实测证据是源码 hash、路径与进程，不能把回显 commit 当成运行时 git 读取。

本工具复用上述现有身份采集器，并在输出中保存采集脚本和部署回执的 SHA256，便于复查。默认旧模型源码仍固定 R133 `06953419d01f961c70b22b12b4d59ecdfaa187e699cc555b3be4109522368e4e`。新入口使用独立冻结的模型源码期望，不从生产实时 state 学习。窗口内日志除代理 release 外，也必须匹配期望的 slot/revision/model release；不匹配的行计入 `unexpectedRoutingIdentityEvents`，排除出新身份的业务计数，并令 `coverage.complete=false`，退出码 2。该计数不证明异常行属于新模型。

## 正式切换后冻结身份回执

新增可选 `--identity-receipt` 与显式 `--production-receipt` / `--status-receipt` 不能同时使用；旧参数及其默认值保持兼容。回执应由主任务在独立确认生产后写入本轮 `model-r134/`。以下是**字段模板，null 和尖括号占位符必须替换为真实证据值才能使用**，不能复制候选 PID 或使用进程启动时间代替确认时间：

```json
{
  "schema": "castreader.us-proxy-monitor-identity-receipt.v1",
  "verified": true,
  "verifiedAtUTC": "<独立生产确认的 UTC 时间>",
  "expected": {
    "sourcePath": "/workspace/castreader-runtime/proxy-releases/us-tts-origin-proxy-20260907-v2/r133_stable_proxy.py",
    "sourceSha256": "0502fc2d9b3793be6309ae6f13ea544380404721857e55162b3eae060daa7eba",
    "sourceCommit": "21cad1b1823d28b9b7c257744dc0b1704403931a",
    "proxyReleaseId": "us-tts-origin-proxy-20260907-v2",
    "revision": null,
    "currentSlot": "blue",
    "currentReleaseId": "<MODEL_RELEASE_ID>",
    "currentReceiptSha256": "<模型槽位回执的 64 位 SHA256>",
    "process": {
      "pid": null,
      "startTicks": "<代理的 Linux 启动 ticks>",
      "cwd": "/workspace/castreader-runtime/proxy-releases/us-tts-origin-proxy-20260907-v2"
    },
    "modelProcess": {
      "pid": null,
      "startTicks": "<模型的 Linux 启动 ticks>",
      "cwd": "/workspace/castreader-runtime/releases/<MODEL_RELEASE_ID>"
    },
    "modelSourceSha256": "<模型指定源码的 64 位 SHA256>"
  },
  "modelExpectation": {
    "slot": "blue",
    "releaseId": "<MODEL_RELEASE_ID>",
    "version": "<模型源码的 40 位小写 commit>",
    "releasePath": "/workspace/castreader-runtime/releases/<MODEL_RELEASE_ID>",
    "sourceRelativePath": "api/src/services/tts_service.py",
    "sourceSha256": "<与 expected.modelSourceSha256 相同>"
  },
  "deploymentEvidence": [
    {
      "path": "/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/model-r134/<最终身份或路由回执>.json",
      "sha256": "<该本地文件完整字节的 64 位 SHA256>"
    }
  ]
}
```

顶层、`expected`、两个 process、`modelExpectation` 和证据条目的字段集合严格校验，不允许混入任意信息。代理路径、release 和源码 SHA 固定为已审阅的 v2；两个 commit 必须 40 位小写 hex。模型 slot/release/path/source SHA 必须与 `expected` 和进程 cwd 一致，源码相对路径只能位于 `api/src/` 的 Python 文件，禁止绝对路径、`.` / `..` 和别名。每个 PID/启动 ticks 必须是有效正值，blue/green 分别固定模型端口 8880/18880 和原 Supervisor program。

`deploymentEvidence` 需包含 1–16 个不同的本地 JSON 文件及其实际 SHA256。身份回执与所有证据必须是本轮 `/Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/` 内的规范绝对路径、常规文件，不接受符号链接或逃逸；单文件最多 8 MiB。只保存路径和 SHA，不导出证据内容。文件 hash 绑定用于检测回执冻结后替换；部署证据的真实性由主任务的独立发布回读建立，collector 不会把任意 JSON 自动认证为一次发布。

```bash
python3 reports/audio-playback-recovery-rollout-20260907/monitoring/collect_proxy_events.py \
  --identity-receipt /Users/xuxuheng/Documents/CastReader/reports/audio-playback-recovery-rollout-20260907/model-r134/proxy-monitor-identity.json \
  --start-utc '<不早于 verifiedAtUTC 的明确 UTC 时间>' \
  --end-utc now \
  --include-events \
  --output reports/audio-playback-recovery-rollout-20260907/monitoring/proxy-model-r134-first-window.json
```

输出继续使用 `castreader.us-proxy-event-window.v1`，增加 `expectedModelIdentity` 和身份回执/部署证据 SHA 来源。`--production-active-from-utc` 若指定，也必须不早于回执确认且不晚于窗口起点。保持原有隐私、扫描截断、明细数量、边界请求和播放质量限制；零错误不能证明可解码或实际播放完成。两个 acceptance-state 和上级报告不由此脚本修改。

本地合成 fixture 验证（不访问生产）：

```bash
cd reports/audio-playback-recovery-rollout-20260907/monitoring
python3 -B -m unittest -v test_proxy_events.py
```

10 项本地测试覆盖隐私字段过滤、异常字段稳健性、UTC/确认前窗口拒绝、共享故障计数与截断、旧发布回执兼容、新本地证据 SHA 绑定、伪造/别名路径拒绝、同 v2 release 下真实进程/槽位/源码漂移、模型 JSON 实际传入 helper，以及旧槽位事件不能混作新模型成功样本。测试不连接生产。
