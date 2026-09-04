# Android 解读续传修复验证（2026-09-04）

本轮在 `14b884bb29b4b335a5607b948183304c25e001d4` 的区域隔离修复之上补齐 Android 解读音频续传；没有操作生产服务器、发布商店或改动版本号。

## 已修复的问题

- QuickRead、PhotoReader、EPUB、PDF、Kindle、WebReader、WeRead 共 7 个入口原先最多取 24 段 TTS。多个入口还会在请求/解码失败时 `break`，随后将部分音频当成完整块播放并推进正文。
- 上述入口改用 `NarrationContinuation`，一直处理明确返回的 `unprocessed_text`，同时保留单次输入上限之外的原文。`processed_text` 仅用于显示与高亮，缺少余文字段时不会从显示文本推测额外请求。
- 网关会规范化空白和重复连字符；客户端接受服务端规范化的余文。只对规范化回声、已经出现过的余文循环、空音频或解码失败进行有限恢复，不以字节级后缀或字母计数限制有效音频。
- 网络中断、408/425/500/502/503/504、技术容量类 429 对同一输入自动重试，保留已生成部分。最多 4 次尝试，默认间隔 500/1500/3000ms；`Retry-After` 受累计 5 秒退避预算约束，超过预算不会提前重试。每次网络请求仍使用原有 API 超时。
- 明确的会员/额度/授权/owner 拒绝以及永久 HTTP 错误沿异常路径保留，取消不重试。429 错误体只作有界非消费读取，原处理器仍能读取错误体。
- 音频实际时长优先；时长探测失败、NaN/无限值、负值或异常高亮时间戳会降级显示和估时，不删除已拿到的音频。
- 移除了各入口 `extractBlock`、TTS 预取 `await` 的吞错点，避免终止异常再变成 `null → continue`。`QuickReadApi` 原有网络重试保留。可选 compose 的取消保持取消。
- EPUB/PDF/Web/WeRead 的失败展示复用已有本地化 `qr_failed`，内部异常和 HTTP 文本留在诊断层。播放器结构、会员/配额/音色选择规则不变。

## 验证

- Global：51 项定向单测，全部通过；CN：54 项，全部通过。其中共用续传新增 18 项在两区分别运行，覆盖超过 24 段、单次瞬态失败、502、容量与额度 429、Retry-After、坏时长/时间戳、缺失余文、规范化余文、emoji/符号前缀、无推进/循环、空音频、取消与永久拒绝。
- 其余测试为 `TtsTimestampPolicyTest`（29）、`QuickReadRegionalRequestTest`（3）、`PresetTtsFallbackPolicyTest`（1）；CN 额外 `ChinaTtsRoutingTest`（3）。
- 两区 `assemble*Debug` 成功。使用命令参数 `-Dorg.gradle.jvmargs='-Xmx6g -Dfile.encoding=UTF-8' -Pkotlin.compiler.execution.strategy=in-process -PdebugUsesReleaseSigning --max-workers=1`，未改全局或仓库 Gradle 内存配置。
- 两包均为 `com.same.castreader`、`1.0.44 (51)`、minSdk 24、targetSdk 36，`apksigner verify` 与 `zipalign -c 4` 通过，签名证书与前一轮测试包精确一致。CN 不含 Play Billing 权限。
- 发布技能预检确认 9 语资源各 727 条。其默认项目根目录 keystore 文件检测报缺失；实际 ignored `keystore.properties` 指向已有绝对路径，两包已通过真实签名校验。本次没有执行商店发布流程。
- 本轮没有发送线上合成请求，也没有进行 Android 真机交互/播放测试；以上是 JVM 故障注入、区域契约测试、完整编译和安装包结构/签名校验。

## 安装包与证据

| 产物 | 字节数 | SHA-256 |
|---|---:|---|
| `app/build/outputs/apk/global/debug/app-global-debug.apk` | 102607279 | `0d83d2e138752d585702223af820f7304a35bc6d6924c5f35c63778166aee193` |
| `app/build/outputs/apk/cn/debug/app-cn-debug.apk` | 102056041 | `eb254ad3fc4c9b01df9b637a4a898eafeacd4f4a79b284f4db5f3f45e826b21e` |

签名证书 SHA-256：`381a825d76ed0f3a9914dc04fcc22e7d15f1136c6d11fe43b0c5a4926f608a65`。

机器可读回执见本目录 `validation.json`。构建完整输出保存在 `/tmp/castreader-android-continuation-build-both.log`；测试 XML 位于 `app/build/test-results/testGlobalDebugUnitTest` 和 `app/build/test-results/testCnDebugUnitTest`。
