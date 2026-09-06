# Global 稳定入口 release/receipt 元数据核对

结论：固定 URL 和 node 是稳定入口身份；当前 `releaseId`/`receiptSha256` 已用于证明具体代理部署，不能事后把旧 v1 名称解释为不随二进制变化的永久入口 ID。实际路由仍正确；这是证据版本过时，不是已发现的跨区或模型漂移。本次只读审查未修改在线 DB、Vercel 环境或源码工作树。

旧 `09a5b95ffce55750bf4551e27674c8d31c70e6bdccea73959d25c07a0605c877` 经本地重算，精确对应 `reports/backend-audio-rollout-20260906/us-kokoro/proxy-release-receipt.json`。该回执绑定 v1 release、源码 SHA `927226ad967e7781a43ef6c37f4d1ed13380f23ca295b12062fd43e480085e44` 和源提交 `954730c1c67e0a103f8ce80992e97a2df400e4a8`；现在运行的 v2 已是另一份源码。

审查工作树：`/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-audio-recovery-release-20260907`。

| 位置 | 已确认行为 |
|---|---|
| `scripts/apply-tts-runtime-migration.ts:46` | `EXPECTED_TTS_PRODUCTION_CONFIGURATION` 固定旧 v1 release/receipt，并以精确值校验环境。 |
| `.github/workflows/backend-production-release.yml:131` | 每次 production release 用 `--force` 把 release/receipt 环境值写回旧值。 |
| `scripts/reconcile-global-tts-upstream-routing.ts:146` | target 取自上述常量；`targetsEqual` 同时比较 URL、node、release、receipt 和语言列表。 |
| 同一 reconcile 的前驱检查 | 只接受 target 已相同，或精确批准的 revision 0 bootstrap；现有合法 v1 revision 状态不自动迁移到 v2。 |
| `src/shared/ops/tts-upstream-routing.ts:172` | release 为标识符，receipt 必须是 SHA256；schema 不定义一个可永久复用的 stable release 别名。 |

最小可审阅修复建议：

1. 冻结本轮 v2 release receipt，引用已 verified 的 apply、status、候选完整音频验证及源 SHA/commit；发布后不可原地改写已被引用的回执。旧 v1 回执保留历史用途。
2. 同步更新 migration 常量和 production workflow 的两个配置值，以及 `apply-tts-runtime-migration.test.ts` 中对应的 workflow 断言。更稳妥的很小改动是 workflow 从同一已审阅配置源读取，避免两处字面量再次失配。
3. reconcile 增加精确审阅的 v1→v2 前驱许可：固定同一 URL/node、完整旧 release/receipt/语言证据、目标 v2；仍使用已读取 revision 的 CAS、已有音频探测和回读。不要放开任意合法非 bootstrap 前驱，也不要只按 URL 相同就批准切换。
4. root 在完整补丁、测试与新回执就绪后统一更新配置并通过既有受控入口迁移元数据，保留 previous/audit。不应先单改在线 DB、再留下旧 workflow 等待下一次运行。

故障边界：旧 reconcile 遇到已更新的合法 v2 DB 状态时会 `unapproved_predecessor`，不会静默把它重置成 v1；但 production workflow 已可能先强制重置环境值，造成下一次发布失败以及冷启动 fallback 的旧元数据。maintenance workflow 也取旧常量，所以同样要随代码源更新，不能只调整一轮运行的临时变量。

当前 `us-proxy-apply.json` 文件 SHA 为 `79ced525a6891183b7db4dd639ab76ffc39d9cda44c3538917c858925ff6b8e7`，可作为 v2 receipt 证据的一部分；它不是模型回执 SHA，也不应与代理源码 SHA 混用。
