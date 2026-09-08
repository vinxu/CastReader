本次检查结论：核心服务在采集时可用，未发现已核验的模型或代理版本被替换；但过去 24 小时不能判为“全正常”。已观察到国际区 2 条入口 HTTP 500、2 条 HTTP 429、343 次 Direct 响应前断开，中国区 12 条 HTTP 499、3 轮连续朗读探测失败，以及 1 次解读首块失败。不同层的记录不能直接相加成为“用户播放失败次数”。

检查窗口：北京时间 **2026-09-07 20:18:27 至 2026-09-08 20:18:27**，左闭右开；原始 UTC 为 `2026-09-07T12:18:27Z` 至 `2026-09-08T12:18:27Z`。只读后端既有日志、探针结果、健康状态、运行配置及代码；没有修改生产代码、重启服务、部署或新增生产合成请求，没有读取客户端埋点、用户正文或录音。窗口后的健康快照另列，不能代替全天数据。

| 服务 / 观测层 | 窗口内数据 | 判断 |
|---|---|---|
| 国际 Direct TTS 入口 | 46,521 条请求摘要；46,178 × 200；343 次未形成响应状态的断开 | 记录内断开占 0.7373%；不是 HTTP 5xx，也不能直接当正常取消 |
| 国际共享 TTS 代理 | 82,098 received；81,769 complete/200；328 cancelled；未见固定上游 failure 事件 | 模型供给总体正常；completed 不等于音频已送到终端 |
| 国际 Vercel 核心路由 | 2 × 500，2 × 429；返回的核心路由日志未见 3xx、502、503、504 | 存在真正的入口失败；没有完整全球入口分母，不能给全站成功率 |
| 中国 TTS Nginx 入口 | 3,892 × 200；12 × 499 | 下游在请求结束前关闭；未记录到该路由 5xx |
| 中国独立克隆朗读入口 | 114 × 200；另有 61 次克隆相关 GET × 200 | 这是入口记录，不能代表所有克隆入口的完整模型生成统计 |
| 国际连续朗读探针 | 278 / 278 轮完成全部余文并解码 | 固定样本正常，不是所有用户的播放 SLA |
| 中国连续朗读探针 | 274 / 277 轮完成；3 轮 `unexpected_monitor_error` | 3 次异常均在下一轮恢复，但原始原因被探针抹掉 |
| 国际解读 | 3 次 `extract-plan request_disconnected`；1 次 Pro gate deny | 断开发生于请求生命周期；deny 是业务门控事件，HTTP 状态未被完整记录 |
| 中国解读 | 2 次 `extract-plan request_disconnected`；1 次 `fast-block0` 错误 | 首块错误发生在 DeepSeek 响应体读取 / JSON 解析阶段 |
| 国际克隆模型 | 保留的部分窗口日志中 726 次 captioned-speech job completed | 日志保留范围不覆盖全天，不能用 726 作全天请求分母 |

来源：`summary.json`、`direct-streaming.json`、`proxy-day.json`、`vercel-hourly-*.json`、`cn-details-aliases.json`、`monitor-{us,cn}.json`、`backend-supply/*.json`。中国 `/api/captioned_speech_partly` 是共享入口，仅凭 access log 无法区分 Kokoro 与克隆音色；表内没有把所有 3,892 次均归为 Kokoro。

**国际区 2 条 500：已定位到 Vercel 函数调用 / 响应交付层，具体平台内部原因尚未确定。**

| 北京时间 | 外层 HTTP / 总耗时 | 同条记录附带的 TTS 应用日志 | 函数耗时 / 平台标记 |
|---|---|---|---|
| 09-08 04:50:23.980 | 500 / 60,021ms | upstream body 完整读到，request_finished=200，446ms | 483ms；`INTERNAL_FUNCTION_INVOCATION_FAILED` |
| 09-08 04:52:40.477 | 500 / 60,018ms | upstream body 完整读到，request_finished=200，538ms | 578ms；`INTERNAL_FUNCTION_INVOCATION_FAILED` |

两条均为同一生产部署 `dpl_EYb2UAVcLJvk7qaYchgmPhYoHYC5`，没有附带模型失败、重试耗尽或 20 / 28 秒生成预算耗尽事件，`hasFunctionCrashed=false`。因此不能把这两次 60 秒失败归为“模型生成太慢”。应用日志的“完成”仍早于真正的网络交付完成。

Vercel 外层把两条记录标为 GET，但所附应用事件来自生产代码中 POST 合成分支；这种记录关联 / 方法元数据不一致尚未解释。不能据此断言用户误发 GET，更不能拿不支持 GET 作为根因。现有数据也不足以确定是平台响应转发、连接、日志关联还是其他内部调用故障。应保留原请求在 Vercel 内的 trace，进一步区分函数返回和外层交付两个终点。

官方对该错误的定义允许函数自身或运行环境因素，错误码本身不是单一根因证明：[Vercel INTERNAL_FUNCTION_INVOCATION_FAILED](https://vercel.com/docs/errors/internal_function_invocation_failed)。直接证据见 `vercel-error-platform-details.json`；事件提取见 `vercel-error-details.json`。

**343 次 Direct 断开：确认是供给完成前后，下游连接先结束；最初发起关闭的一方仍未证实。**

全部摘要均记录 `downstreamDisconnected=true`、`abortSource=downstream_closed`；333 次处于等待上游 headers，10 次处于读取上游 body，耗时 3–4,961ms。它们没有集中到一个 20 / 28 / 30 / 60 秒超时阈值。

| 请求所带客户端版本 | 记录请求数 | 未形成响应的断开 | 该版本请求内占比 |
|---|---:|---:|---:|
| Android 1.0.46 | 9,397 | 208 | 2.21% |
| Android 1.0.47 | 3,118 | 58 | 1.86% |
| iOS 1.2.35 | 406 | 30 | 7.39% |
| iOS 1.2.36 | 661 | 41 | 6.20% |
| 扩展 1.2.37 | 32,656 | 6 | 0.018% |

其他版本 / 未知来源的 283 条记录均为 200。以上是请求上的版本声明，不是经认证的设备或用户数量；不同版本的阅读方式、预取行为和样本量也不同，不能用这些比例直接评价版本优劣。

按匿名请求键回连 US proxy：

- 327 次只对应 proxy cancelled。
- 1 个断开请求键还被用于后续一次成功请求；proxy 同键含 cancelled 和 complete，不能把后一次成功覆盖掉前一次断开。
- 14 次 Direct 断开时，proxy 已完成音频响应，其中 10 次 Direct 正在读 body，4 次仍记为 headers 阶段。
- 1 次 3ms 内断开未找到 proxy 请求；只说明匹配不到，不推断一定未发包。

这解释了为什么“上游模型没报错”仍会有请求收不到音频：代理已生成或正在生成，下游请求生命周期提前结束。当前证据只追到 **Caddy → Direct 的连接**；不能把所有关闭都解释成用户主动退出，也不能只归咎 Android，因为本窗还有 71 次 iOS 断开。

本次回读 Caddy 活跃配置，access logger 仍未启用，Caddy / Direct 均没有重启，Direct 源码 SHA 与冻结版本一致。旧报告中的 Android 预取取消路径只能作为候选机制，不能代替本窗逐请求证据。此前 74 次和本次 343 次窗口不同，不作“新增 269 次”这样的差值计算。

此外 Caddy 在北京时间 09-08 02:42:52.560 另有 1 条 **`aborting with incomplete response` / `http2: stream closed`**。这是实际响应交付中断证据，未保留可关联 request key，也没有同一分钟的 Direct 断开摘要，不能加入 343 后声称得到无重复的总数。说明只监测 Direct 的 200 状态仍会漏掉后续交付失败。见 `ingress-readback.json`、`caddy-error-classification.json`。

**两条 429：拒绝事实明确，业务限量与技术拥塞尚不能区分。**

| 北京时间 | 路由 | 状态 / 耗时 |
|---|---|---|
| 09-07 21:54:58.647 | `/api/voice-clone/captioned-speech` | 429 / 528ms |
| 09-08 17:44:10.492 | `/api/captioned_speech_partly` | 429 / 493ms |

两条 Vercel 记录都没有应用原因日志或保存的响应错误码。生产提交 `1f9a483c7f75c9acee30129c984ea9bc622c5ea1` 的 `src/shared/voice-clone/entitlements.ts:614` 会对 `CLONE_QUOTA_EXHAUSTED` 返回 429，而 `src/shared/voice-clone/worker.ts:79` 也把 worker busy 的 429 保留下来；共用 partly 路由能够承载克隆音色。因此目前不能将 429 全部计入“允许的业务限制”，也不能断言是 Kokoro 拥塞。

需要在拒绝发生处记录固定错误码、业务 / 技术类别、区域和匿名 request key；不记录正文 / 音频。此次没有修改额度或做推测性重试。证据见 `vercel-core-4xx-targeted.json` 和 `vercel-hourly-4xx.json`。

**中国区 3 轮探针失败：异常有实据，但日志误分类妨碍了归因。**

| 失败完成时间（北京时间 09-08） | 本轮耗时 | 已收到片段 | 下一轮恢复 |
|---|---:|---:|---|
| 12:14:26.311 | 46.541s | 0 | 12:18:51.033 |
| 14:19:33.442 | 75.977s | 0 | 14:23:28.743 |
| 15:32:42.022 | 85.149s | 1 | 15:36:32.615 |

探针在 fetch headers 阶段会区分网络 / 超时，但 `readJsonWithinLimit()` 中的 `await response.arrayBuffer()` 没有对应分类，抛出的 TypeError / AbortError 会被顶层统一替换为 `unexpected_monitor_error / monitor_fault`。结果文件不保存原始异常类别 / cause / 每次尝试的请求键。

使用与生产 SHA 完全一致的源文件做了 2 个离线注入测试：响应体 TypeError 和 AbortError 都被错误归入 monitor_error，且已发生 2 次尝试。这证明 **monitor_error 不等于监控机器自身故障**，不能排除真实响应体传输失败。历史 3 次究竟属于哪种错误，现有记录无法恢复。本轮耗时也不是服务宕机持续时间。CN Nginx 的 12 个 499 没有 request key，不能和这 3 轮直接相减或认定同源。

固定输入探针总耗时 p95：US 6.833s，CN 18.344s。两区输入语言、音频时长和分段次数不同，不能把它当同一工作量的跨区域性能对比。探针所收到的区域标记均符合所选区域，但失败在收到标记前的请求无法据此验证。

**中国区解读首块失败：DeepSeek 响应封套读取失败，不能直接断言是“模型输出非法 JSON”。**

北京时间 09-08 10:43:12.282 的固定错误是：`DeepSeek (deepseek-v4-pro) returned an invalid JSON envelope`。生产 `tools/llm-provider.mjs` SHA 为 `7c0370aff30427bf5d85f47595c7b14c1a2dd1aff486c970f877a7926098e9d2`，与离线检查源码一致。

实际路径为 `fast-block0 → extractFastBlock0 → DeepSeek → response.json()`。`response.ok` 检查已通过，失败发生于读取 / 解析整个供应商 HTTP 响应；并非后续讲解内容的 `kuaidao_bad_json` 校验。代码把 SyntaxError、TypeError、AbortError 全部重写成同一句 invalid JSON envelope，3 个离线测试均复现了这一点。所以候选原因包括响应体截断、读取期间中止 / 超时、或响应封套确实不是合法 JSON；当前无法进一步选定。

该路由 catch 在响应仍可写时走 502；若已断开则不再发送。当前 Nginx 对 `/api/quickread`、`/api/quickread/` 及专用解读路由配置 `access_log off`，因此这次最终是否向调用方发出 502 **没有入口日志证明**，不可把代码里的预期状态当实测状态。

该生产提供方路径固定为 CN DeepSeek，没有发现它转向海外备用；这只验证了已检查的提供方配置，不是所有历史链路“全程无跨境”的证明。见 `cn-fast-block0-cause.json`、`cn-fast-block0-error-shape.json`、`cn-nginx-route-map.json`、`offline-error-classification.json`。

**模型、解读积压与当前运行情况。**

US / CN Kokoro R135 的 PID、启动标记和所核验源码哈希仍与冻结版本相符；US proxy revision 10 仍指向 R135，Direct SHA 仍为 `e83932e7e1a343795ab1d0735f76ab764a406e588f7b7c9118b1de7262c8a685`。Vercel capabilities 指向原生产部署和提交 `1f9a483c7f75c9acee30129c984ea9bc622c5ea1`。没有发现这些受查核心组件被其他分支替换的证据；这不是对整仓全部文件的完整性担保。探针 response header 中的 DB routing revision 与 proxy revision 是不同字段，不互相当版本漂移。

R135 固定诊断日志没有 terminal failure、未知结构事件或解析坏行。US 记录日语数字恢复 2 次、英语 G2P 恢复 233 次、保留完整 PCM 149 次；CN 英语恢复 2 次、保留完整 PCM 30 次。`source_frontend_unavailable`、分隔符跳过等诊断事件不能按终止故障计数；这些日志也不是完整成功请求账本。

国际 Direct 请求耗时 p50 566ms / p95 2,042ms / max 7,994ms；共享代理 request_finished p95 2,049.613ms。代理所有已记录 attempt 都为 1，未发现重试风暴。received / finished 是分别按事件时间落窗，差 1 条不能自动认定为一个挂死任务。

采集时两区 QuickRead health 都为 200，queue=0，无 active job。窗口内修改的状态文件 US 496、CN 13，全部有 block0 且 ready；US 403 已生成所有块 / 93 部分 ready，CN 9 全部 / 4 部分 ready。按需只生成部分块本身不是失败。文件缺少明确 creation time，所以它们不是“全天新请求数”或用户成功率。

两区克隆 worker 当前 healthy / accepting、队列 0，启动以来失败和过期计数为 0；US submitted=completed=2,154，CN=159。它们是启动以来的累计计数，不是全天请求量。US 保留的模型日志只覆盖 UTC 09-08 03:54–08:44 内的事件：726 次 completed，12 个 duration warning、8 个 quality warning，未见固定拒绝事件。该部分样本 queue_wait p95 507.78ms、run p95 1,492.73ms。检查日志库存及 combined log 后仍不能补全 24 小时模型事件，不能宣称克隆全天零错误；入口还明确存在一条独立克隆 429。

**日志覆盖和其他服务。**

- Direct 原始 systemd journal 按流读取 2,042,942 行，解析 / 不完整记录错误为 0，保留请求发生次数，不用 request key 去重覆盖重试。
- US proxy 读取 1GiB 既有日志，覆盖窗口起点，区域 / release 记录核验通过；没有启动合成。
- CN access.log 与 access.log.1 合起来覆盖窗口，已解析核心路由无坏行。首轮只读当前文件的 3,287 × 200 / 11 × 499 是部分日数据，最终使用合并后的 3,892 / 12。
- Vercel 5xx 按 24 个小时分片均翻页完成；4xx 的 13 个分片达到页数上限，另按核心路由关键词补查，返回的分页均无后续，确认了上述两条 429。关键词可能命中日志内容，因此额外查出的 mobile-auth 401 未误计为克隆请求。
- Vercel 一般 TTS 事件只保留本次抽取的 4,900 条请求样本，样本中全部为一次尝试完成，不能扩展成全天 100%。早时段日志会在查询期间随保留窗口移动而减少，因此保留最早分片快照，不以晚查询覆盖早证据。分页完毕仍不等于证实平台采集零遗漏。
- Vercel 聚合 metrics 查询被 `payment_required / Observability Plus required` 拒绝。未购买或改变套餐；没有完整全入口分母。该采集限制不是用户服务故障。
- 已列核心路由之外，5xx 分片还记录 48 × 503 和 1 × 500。503 抽查落在 Google Play 对账 cron，固定日志为 incomplete；500 位于 `/api/app/config`，标记 `FUNCTION_INVOCATION_FAILED`。这些不混入 TTS / 解读模型失败数，本次不扩展到订单或会员数据排查。
- 全窗 / 全路径 Vercel 查询有 HTTPError 和一次本地 TLS 握手超时，已用成功的分片数据完成核心排查；不要把日志 API 采集失败计为生产音频故障。详见 `collection-notes.json`。

**后续迭代应针对已经证实的问题。**

1. 优先补齐响应交付终点：每次请求记录匿名键、路由、区域、固定错误码、阶段、完成 / 断开和耗时；覆盖 Caddy、Direct 的提前 503 返回、Vercel 外层与函数层。不能增加停止播放的检查门槛。当前 Direct 的 max-in-flight 503 提前返回在摘要日志之前，必须修复这个统计盲点。
2. 将 body 读取超时 / 中断 / JSON 解析分开分类，同时保留脱敏 cause code 和每次尝试键。离线复现证明现有 CN 探针与 DeepSeek 的分类有缺陷；修正后才能验证恢复策略，而不是继续扩大“监控错误”或“非法 JSON”兜底桶。
3. 对 429 明确业务限量与 worker busy；业务限量按产品规则处理，技术忙 / 传输失败在既有总预算和同一区域内恢复。历史这两条未确定原因前，不做“全部属于正常限量”的结论。
4. 针对国际两条平台 500，核对平台内部调用 / 响应转发 trace 与方法字段异常；为外层调用失败保留同区恢复路径。模型在这些记录中已完成，重新修模型前处理不能解决此类交付失败。

本次只做定位与报告。可复核聚合：`python3 -B reports/backend-service-review-20260908T121827Z/analyze_evidence.py`。离线错误分类验证共 5 项通过，这 5 项测试没有向生产发送请求；没有改动任何播放器、TTS 或解读生产代码。
