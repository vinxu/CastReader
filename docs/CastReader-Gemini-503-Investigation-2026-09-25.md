# Gemini 503 排查记录

> 阶段记录归档：本文保留当时的计划、验证与发布状态。2026-09-25 后续客户端修复、送审状态及用户核查结论，以 [本轮交付汇总](CastReader-Pro-Release-Closure-2026-09-25.md) 和现行 [Pro 一致性标准](Pro一致性标准.md) 为准；早期到期计时器等设想不覆盖最终移动端实现。

时间：2026-09-25，Asia/Shanghai。范围：阻塞 Pro 后端发布的 Kindle Reading Fix 真实模型门禁。

## 结论与证据边界

已确认是 Gemini HTTP 请求返回 503，而不是 Pro 查询返回 503。现有证据支持上游间歇性不可用；没有证据支持密钥永久失效、模型名无效或本次 Pro 代码造成故障。历史日志未保留 Google 的具体错误正文，因此不能确认 Google 内部的容量、区域或路由原因，也不能称为全球性故障。

- 请求模型 `gemini-3.8-flash`，Google 官方 OpenAI 兼容入口 `generativelanguage.googleapis.com/v1beta/openai/chat/completions`。
- 9 月 24 日两次候选发布及独立复测记录到 `providerStatus=503`，对应 Kindle `STRATEGY_UNAVAILABLE`。部分失败约 1 秒返回，并非 25 秒客户端超时。
- 同一个候选曾先成功生成策略，后续请求失败；没有经过 Pro 判权管线。
- 9 月 25 日原候选 `readout-8of79flio-castreader.vercel.app`、相同源码 `0e675e6ba3d485643e3958cd9ec99156f35b3f7c`，完整真实模型复测通过 9 项检查，QA 清理 verified。没有更换模型、密钥或候选代码。
- 本机独立的小请求亦验证工具调用和原生 generateContent 均能成功；由于生产密钥为不可读的 sensitive 配置，无法核对本机密钥是否相同，这部分只作为补充，不替代同候选验证。本机另遇一次 RemoteDisconnected，不能把它算成 Google 503。

Google 官方将 503 UNAVAILABLE 解释为暂时过载或不可用，建议有限次数的指数退避并加入抖动；这支持故障类别判断，但不是本次历史错误正文的替代证据。

参考：<https://ai.google.dev/gemini-api/docs/generate-content/api-errors>、<https://ai.google.dev/gemini-api/docs/troubleshooting>。

## 我们的薄弱环节

`requestReadingAgentTurn` 使用一次直接 fetch，503 后立即抛出 `AGENT_PROVIDER_UNAVAILABLE`，没有传输层短暂重试。Kindle 编排随即终止当前修复任务，所以一次上游波动即可导致门禁或用户操作失败。

provider 已提取 errorCode / diagnostic，但 route 日志白名单只保留 providerStatus 与 token 计数，丢掉具体原因。历史正文无法从这些日志补回。

## 后续改进边界

独立改进应记录脱敏、有限枚举的错误原因和尝试次数，对明确的暂时性响应做有界退避；所有重试共用原取消信号和总时限，并计入真实模型调用预算。不能无限重试、隐藏额外调用、记录书页或密钥，也不能为了门禁通过临时切模型或跳过验收。应覆盖 503 后成功、持续失败、取消、超时和不可重试错误。

本次 Pro 发布未修改模型调用实现。真实模型恢复后，新候选 `95c32ff74e29a7e6a729a103c48ce6baaf1451e8` 的完整受保护流程 [36032768374](https://github.com/scmyyan/readout-web/actions/runs/36032768374) 成功，Kindle 9 项真实模型检查及 QA 清理通过，已切换生产。该结果验证本次发布可用，不代表已实现自动重试或永久解决上游 503。
