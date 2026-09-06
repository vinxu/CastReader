# 四条 Vercel TTS 504：只读原因核验

结论：504 已定位到 Vercel 函数响应层。四次函数执行均在 **28.006–28.033 秒**结束，精确贴合已发布普通 TTS 的 **28 秒应用总预算**；平台允许 300 秒，四次均为热实例，未记录函数崩溃或平台错误码。因此，证据强烈支持应用预算到期后进入 `gatewayError` 的 504 分支。单条原始异常未记录，不能把这一推断升级为已捕获的 TimeoutError 堆栈。

| 匿名请求键 | 代理请求时间 UTC | 函数耗时 ms | 总请求耗时 ms | 函数区域 | User-Agent 家族 |
|---|---|---:|---:|---|---|
| `e061a66c335ef6dece59` | 2026-09-06T13:29:35.925000+00:00 | 28007 | 28024 | iad1 | chromium |
| `0865d60458fd5519c2d1` | 2026-09-06T13:29:36.132000+00:00 | 28006 | 28079 | iad1 | castreader |
| `498d54bede61726ce98c` | 2026-09-06T13:29:49.696000+00:00 | 28033 | 28041 | iad1 | chromium |
| `5e7c7c1c359ddd58195d` | 2026-09-06T13:29:49.992000+00:00 | 28006 | 28031 | iad1 | chromium |

四条 `functionEvents.httpStatus` 和 `proxyEvents.httpStatus` 都是 504；`errorCode` 均为空字符串，`hasFunctionCrashed=false`，`functionStartType=hot`，运行时为 Node.js 22，峰值内存 352 / 2048 MB。并发元数据为 44–45，单凭这个数字不能证明过载。三个 Chromium 家族与一个 CastReader 家族分类仅来自调用方 User-Agent，不能证明用户身份或请求是否为自然流量。

发布提交 `e8a755d4ea9602397cad138e6b3bbd3d91f7fa54` 的普通 partly 路径设置总预算 28,000 ms、单次请求上限 20,000 ms、重试退避 500 / 1,500 ms。总预算覆盖请求、完整响应体读取、JSON 验证和退避。`gatewayError` 对 TimeoutError 和 AbortError 都直接返回 504 且不记录日志；这解释了为什么 HTTP 状态存在而四次嵌套日志为空。实际每次发了几次上游请求、等待发生在连接/排队/推理/读体哪一阶段，当前 Vercel 证据无法区分。

各条根级时间戳与 `proxyEvents.timestamp` 相同。[Vercel 官方字段参考](https://vercel.com/docs/drains/reference/logs)将代理时间定义为请求发起时间，因此不能把 13:29:35 / 13:29:49 当成已完成响应的时间。函数事件时间比它晚 19–50 ms。根据函数事件时间加执行耗时，推算结束点分别为 13:30:03.957、13:30:04.188、13:30:17.748、13:30:18.029 UTC；这些是计算值。

四条 `traceId` 均为空；API 返回结构没有请求 headers，两个请求标签没有识别到 x-request-id、x-correlation-id 或 traceId。超时 catch 没有记录应用生成并传给上游的 request ID。因此目前没有能连接 Vercel、GPU、移动事件的可靠关联键。`iad1` 只说明函数执行区域，不能证明整条链路区域合规。

前次详情读取失败属于工具使用问题：`vercel api` 拒绝完整 vercel.com URL，而 `vercel logs` 内部使用该主机上的请求日志端点并在输出时丢弃详细事件字段。本次按 CLI 的同一已知 HTTPS 端点、用现有凭据在内存中只读访问后恢复了实际元数据；没有修改生产。

证据文件：[完整脱敏元数据](request-details.json)、[结构化原因分析](cause-analysis.json)、[读取脚本](inspect_requests.py)、[发布源码索引](production-source-index.json)、[网关源码摘录](production-tts-gateway-excerpts.ts)、[请求预算源码](production-speech-request-budget.ts)、[路由源码](production-partly-route.ts)。
