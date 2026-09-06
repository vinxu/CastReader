# 核心音频迭代后 24 小时只读验收工具

这套工具在三个必需生产组件都完成发布和验证以后，按固定 UTC 窗口汇总已有证据。它不会发起 TTS 或克隆合成，不会重启服务，不会改线上配置，也不会发送通知。`automaticVerdict` 只验收下表列出的现有数据源，不能认证 iOS、Android、Web、扩展四端完整链路，也不能单独证明所有请求都没有跨境。

当前状态文件是 [acceptance-state.json](acceptance-state.json)。截至本文生成时，US direct gateway 已完成正式切换和验证；Global 网关与 US Kokoro R133 仍是 `verified:false`。状态保持 `waiting_release`，24 小时计时尚未开始。

## 必需发布门禁

| 组件 | 当前候选 | 进入观察前必须填写的生产身份 |
|---|---|---|
| `globalGateway` | 源提交 `186e20b745b0b89f426d27d7f9ddb44f979dcae2` | `version` 填实际 Vercel production deployment ID，`sourceCommit` 填实际生产提交；发布验证时间和生效时间均需为真实 UTC |
| `directGateway` | 源提交 `339a49fe201609ca4aa51055e360607cc2eb0656`，已验证上线 | `version` 记录发布源提交；`runtimeSourceSha256` 是主机上实际 `gateway.mjs` SHA-256，当前为 `0bfb14b9363d25de01d78fdd3777b203d1ec86966e71389d9815bb62a8b66cb0` |
| `usKokoro` | R133 源提交 `ca857ee91c3367999fb905de1f0924a6e28edd81` | `version` 填实际发布提交；`runtimeReleasePath` 填正式 `current` 指向的不可变目录，`runtimeSourceSha256` 填现场 `english_g2p_recovery.py` SHA-256，再设置 `verified:true` |

`validate_state` 会遍历全部 `requiredComponents`。任一组件未验证时，`observing` 和 `window_complete` 都会被拒绝；默认 `waiting_release` 执行不会查询任何生产数据。

进入观察时，Global deployment ID、三个源提交、两个运行文件 SHA 和 Kokoro 不可变 release 路径都按固定格式校验。字段缺失或格式错误会在查询生产前拒绝启动，不能先累计时间再补版本证据。

US Kokoro 的预期版本来自发布回执和状态文件，每轮再通过只读 SSH 核对 `current` realpath 与恢复文件 SHA。现有 5 分钟探针能确认公开供给、余文追完、区域合同和音频解码，却没有可靠的 worker 源提交字段；不能从探针的 `upstreamRevision` 推断 R133。

Global capabilities 或 US Kokoro identity 任一读取失败、字段不完整或与状态不符，都会进入 `dataOrCoverageGaps`，当前已配置来源的自动验收不能通过。小时采样无法发现两次采集之间发生又恢复的瞬时切版；这仍是观察范围的证据边界。

## 状态生命周期

1. 尚未完成全部必需发布时保持 `cutoverState: waiting_release`，未完成的组件为 `verified:false`，已经核验的组件保留真实版本与时间；窗口起止时间仍为 `null`。
2. 三个组件全部在生产完成验证后，填写各自 `version`、`activeFromUtc`、`verifiedAtUtc`，以及上表列出的 commit、运行路径和文件 SHA。设置 `cutoverState: observing`，`startUtc` 使用最后一个必需组件完成验证之后的真实 UTC，`endUtc` 固定为起点后 24 小时。
3. 观察中若任何必需组件再次切换，先把旧版本身份及原生效时间写入 `releaseHistory`，再更新当前组件。报告会列出版本分段，并把最终版本观察不足判为 `inconclusive`。
4. 固定终点到达后设置 `cutoverState: window_complete` 并运行最后一次采集。工具不会因样本不足、数据缺口或中途发布而延长终点。

观察中的 `observationSeconds` 按 `min(当前 UTC, 固定终点) - startUtc` 计算，不会提前把配置好的 24 小时当成已观察时长。

## 读取的数据

| 数据源 | 读取方式 | 可以证明 | 不能证明 |
|---|---|---|---|
| US/CN continuity monitor | SSH 只读解析 `/var/lib/castreader-core-audio-monitor/<region>/results/*.json` | 固定非用户文本的供给状态、余文完整解码、请求合同、连续故障与恢复、区域匹配、探针间隙、时间与音频统计 | 真实用户播放完成；结果文件本身也不能区分 timer 与手动调用 |
| Global mobile funnel | HTTPS PostgREST，严格按服务端 `received_at` 和固定事件白名单分页 | iOS/Android 生产标签事件；同平台、同会话且首音频晚于朗读启动的首输出证据；技术失败、区域不匹配、业务额度和取消 | `production` 标签不能排除操作员手测；设备数不是人数；跨窗口会话不是完成率；不采集 Web/扩展客户端事件 |
| Vercel production logs | 每小时分片，只取 5xx，超时或 1000 行上限时递归细分且受总查询和墙钟预算约束 | Global TTS、QuickRead、clone 核心路径保留的 5xx、失败类型和 deployment 分布 | 请求分母、真实用户数以及超出日志保留范围的请求 |
| Global capabilities | HTTPS GET `api.castreader.ai/api/capabilities`，只保留 deployment、commit 和 region | 即使窗口内没有 5xx，也能发现 Global 生产切版或区域漂移 | 供给与用户播放结果 |
| US direct gateway | SSH 只读 `journalctl -u castreader-tts-gateway.service -o json` | 旧入口 HTTP 状态、延迟、运行源 SHA、调用方上报的平台/版本；支持一条 MESSAGE 或多行拆分的 Node console 结构 | HTTP 200 后客户端是否成功解码播放；调用方 header 不能排除伪造或手测 |
| US Kokoro identity | SSH 只读 `current` realpath 与 `english_g2p_recovery.py` SHA-256 | 正式 worker 是否仍指向验收版本；不会加载模型或执行诊断函数 | 其余发布文件是否被原地修改，仍依赖不可变 release 纪律 |

direct gateway 解析器只保留固定字段和匿名聚合，不输出正文、原始日志、请求 ID、header、IP 或凭据。真实历史窗口 `2026-09-05T23:49:45Z–23:53:30Z` 的只读验证读到 700 条 journal 行，重组为 70 个唯一 Android 1.0.45 请求，结构解析错误为 0；这只验证了解析器，不属于新版本 24 小时结果。

## 四个独立结论

- `supplyVerdict`：两区探针、Global 核心 5xx 和 US direct gateway 的供给结果。缺 Android 1.0.45 自然样本本身不会把服务判为不健康。
- `clientEvidenceVerdict`：生产标签移动事件中的技术失败、区域错误，以及每个平台至少一个同窗口 `read_start → read_first_audio` 会话证据。`explain_start` 不能代替朗读首音频证据。业务额度与用户取消单独记录，不算技术故障。
- `coverageVerdict`：固定窗口是否到期，以及各数据源读取、分页、timer 水位和探针间隙是否完整。技术故障不会把“数据采集完整”误写成“不完整”。
- `automaticVerdict`：当前已配置来源的保守总判定。任一技术故障为 `fail`；数据缺口、已结束但不足 24 小时、样本不足或最终版本观察不足为 `inconclusive`；尚在固定窗口内且采集正常时为 `observing`。即使结果为 `pass`，也只表示这些已采集来源满足本工具的判定条件，不等于四端、克隆、解读、完整播放和全链路区域隔离都已获认证。

“旧 Android 1.0.45 没有自然请求”和“服务供给失败”是两件事：前者只进入 `sampleGaps`，供给维度仍可通过，但总体验证证据不足。探针成功而客户端仍报告技术失败时，总结会明确保留矛盾，不能用探针覆盖客户端事件。

同样，窗口内出现朗读启动但没有同会话后续首音频，只进入 `sampleGaps`：会话可能跨越窗口边界，不能据此生成技术故障；不过客户端证据必须是 `insufficient_sample`，总判定不能为 `pass`。没有 session id 的启动也无法配对。首音频只证明已经开始输出，不证明正文全部播放完成。

`evidenceLimitations` 固定列出 Web 与扩展客户端事件未采集、首输出不等于完整播放，并按本轮自然样本说明克隆音色和解读是否出现过同窗口首输出证据。缺少克隆或解读自然样本本身不伪装成服务故障，也不会被普通音色朗读样本替代。

## 调用

在仓库根目录运行默认状态：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 reports/backend-audio-iteration-20260906/monitoring/collect_acceptance.py
```

默认输出写到 `monitoring/latest-acceptance.json`。发布尚未完成时，输出必须满足：

- `cutoverState = waiting_release`
- `sourcesQueried = []`
- `observationSeconds = 0`
- 当时所有未验证组件都列在 `unverifiedComponents`；当前应为 `globalGateway` 和 `usKokoro`

状态进入 `observing` 后，日常 heartbeat 使用状态文件中的固定起止时间调用同一命令。需要重放另一个已授权 UTC 窗口时，可显式传入：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 reports/backend-audio-iteration-20260906/monitoring/collect_acceptance.py \
  --state-file reports/backend-audio-iteration-20260906/monitoring/acceptance-state.json \
  --cutover-state observing \
  --start 2026-09-07T00:00:00Z \
  --end 2026-09-08T00:00:00Z \
  --output reports/backend-audio-iteration-20260906/monitoring/latest-acceptance.json
```

起止覆盖不会绕过组件验证门禁。Vercel 查询缓存只保存脱敏后的 5xx 记录；距离当前时间不足 15 分钟的分片默认不缓存，以便下一轮补收延迟日志。Vercel 与 mobile 分页都有固定查询数和总墙钟预算；预算耗尽会留下覆盖缺口。某个来源失败时，报告只记录安全错误类型，并把该来源列入覆盖缺口。

## 本地验证

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s reports/backend-audio-iteration-20260906/monitoring/tests \
  -p 'test_*.py' -v
```

fixture 覆盖等待门禁、全部组件验证、完整 24 小时、观察中实际时长、固定终点、中途切版、技术失败、业务额度、缺旧 Android 样本、缺数据源、服务端时钟过滤、按平台/会话/时间顺序配对首音频、启动后无首音频，以及 direct gateway 两种 multiline journal 形式。fixture 只用于代码验证，不能写成生产验收结果。
