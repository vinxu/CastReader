# Kindle Storefront 共享合同 v1

本目录把 `Kindle多站点Storefront适配-跨端设计方案.md` 中的目录数据变成机器可校验的跨端合同：

- `kindle-storefronts-v1.json`：唯一业务目录，包括站点、规范域名、别名、reader 引用参数、兜底站点、地区推荐和八种非中文 App 语言的候选顺序。
- `kindle-storefront-contract-cases-v1.json`：域名真值表、规范化用例和安全负例。
- `test-kindle-storefront-contract.mjs`：目录自检；可选对比浏览器扩展的 `KINDLE_MATCHES`。

线上完整重定向语义、7 个 alias 书架路径丢失、User-Agent、真机验收与域名变更流程见 [`../Kindle站点可靠性与域名变更SOP-跨端.md`](../Kindle站点可靠性与域名变更SOP-跨端.md)。产品与数据模型见 [`../Kindle多站点Storefront适配-跨端设计方案.md`](../Kindle多站点Storefront适配-跨端设计方案.md)。

## 数量口径与验证范围

2026-07-30 对 Amazon 官方入口做了匿名网络验证，目录收敛为：

- 14 个 storefront 记录；
- 其中 13 个具有实际可访问的 Kindle for Web 入口；
- `cn` 只用于识别历史链接，不进入选择器或推荐结果；
- DE/FR/IT/ES/BR/MX/NL 的历史 `read.amazon.*` 地址会跳转或兼容到本地化域名，因此保留为 alias；
- 总计 21 个可精确识别的 host。

验证覆盖 HTTPS/TLS、入口是否返回有效响应、未登录访问
`/kindle-library` 是否仍停留在同一地区域名，以及 alias 跳转后是否仍被同一
storefront 接受。该验证不等价于拥有各地区账号后的书架内容验收；登录书架与开书仍需对应
marketplace 的真实账号。

原目录中的 SE/TR/AE/SG/PL/EG/SA `read.amazon.*` 地址没有可用的 Kindle for Web
服务，不能仅因为 Amazon 存在当地零售站就合成阅读域名，现已移除。

## 21 个 Host 的归属

| Host | Storefront | 类型 | 可作为入口 |
|---|---|---|---|
| `read.amazon.com` | `us` | canonical | 是 |
| `read.amazon.co.uk` | `uk` | canonical | 是 |
| `read.amazon.ca` | `ca` | canonical | 是 |
| `read.amazon.com.au` | `au` | canonical | 是 |
| `read.amazon.co.jp` | `jp` | canonical | 是 |
| `lesen.amazon.de` | `de` | canonical | 是 |
| `read.amazon.de` | `de` | alias | 仅识别/接受官方跳转 |
| `lire.amazon.fr` | `fr` | canonical | 是 |
| `read.amazon.fr` | `fr` | alias | 仅识别/接受官方跳转 |
| `leggi.amazon.it` | `it` | canonical | 是 |
| `read.amazon.it` | `it` | alias | 仅识别/接受官方跳转 |
| `leer.amazon.es` | `es` | canonical | 是 |
| `read.amazon.es` | `es` | alias | 仅识别/恢复已有链接 |
| `read.amazon.in` | `in` | canonical | 是 |
| `ler.amazon.com.br` | `br` | canonical | 是 |
| `read.amazon.com.br` | `br` | alias | 仅识别/恢复已有链接 |
| `leer.amazon.com.mx` | `mx` | canonical | 是 |
| `read.amazon.com.mx` | `mx` | alias | 仅识别/接受官方跳转 |
| `lezen.amazon.nl` | `nl` | canonical | 是 |
| `read.amazon.nl` | `nl` | alias | 仅识别/接受官方跳转 |
| `read.amazon.cn` | `cn` | canonical、recognition-only | 否 |

入口、修复后的 reader URL 和新扫描书籍必须使用 canonical host；alias 只参与识别和从老数据反推 storefront。

## 地区优先与语言候选

设备地区使用 ISO 3166-1 alpha-2。英国必须传 `GB`，不要使用非标准的 `UK`。地区能映射到启用站点时，它是第一推荐；App 语言只为其余候选排序，不能覆盖用户显式选择。

| App 语言 | 候选顺序 |
|---|---|
| `en` | `us, uk, ca, au, in` |
| `es` | `es, mx, us` |
| `pt-BR` | `br, us` |
| `ja` | `jp, us` |
| `de` | `de, us` |
| `fr` | `fr, ca, us` |
| `it` | `it, us` |
| `hi` | `in, us` |

中文 `zh/zh-Hans` 不参与本轮候选适配，也绝不能因此把 `cn` 暴露为入口。

推荐列表的确定性算法：

1. 已绑定站点存在且仍启用时，始终使用绑定值。
2. 未绑定时，将设备地区映射命中的站点放第一位。
3. 追加 App 语言候选并去重。
4. 若仍需展示“全部站点”，按 JSON 中启用站点的顺序追加并去重。
5. `cn` 永不进入候选，但全域名识别与旧链接迁移仍能返回 `cn`。

## 安全边界

所有端必须先由系统 URL 解析器取得 `host`，再进行大小写归一化、移除一个 DNS 末尾点，并对 21 个 host 做集合精确匹配。禁止使用 `contains("read.amazon.")`、`startsWith("read.amazon.")` 或 `^read\.amazon\.`；它们会把 `read.amazon.phish.com` 识别成 Kindle。

允许导航/注入的 URL 还必须满足：

- scheme 为 `https`；
- host 精确命中目录；
- port 为空或 `443`；
- 不含 username/password。

测试数据已覆盖前缀、后缀、子域、userinfo、非 HTTPS、非标准端口、原始 URL 误传为 host 和 Unicode 同形字攻击。

## 跨仓库消费方式

JSON 是合同，不建议把它作为线上可变远端配置。每个客户端应在构建期生成或复制为只读本地数据，并在自己的单元测试中将运行时代码投影回同一形状：

- iOS：`KindleStorefront.all` 与 JSON 逐字段相等；`matches(host:)` 跑全部正负用例。
- Android：`KindleStorefrontCatalog.all` 与 JSON 逐字段相等；URI 识别与候选排序跑同一用例。
- 扩展：本地只读 `kindle-storefront.ts` 必须逐字段投影本 JSON；`KINDLE_MATCHES`、extractor map、extractor matcher 和两份 content-script matches 全部从该模块派生，避免五处手工数组继续漂移。契约脚本同时验证生产构建后的 manifest 投影。

如果三个仓库暂时无法共享构建工作区，应保留一份 canonical JSON，并用同步脚本生成镜像；CI 必须比较 SHA-256 或结构化 JSON，禁止人工复制后各自演化。不要创建跨仓库相对 symlink，它在独立 checkout 和商店构建机上不可用。

## 执行

```bash
node docs/contracts/test-kindle-storefront-contract.mjs
node docs/contracts/test-kindle-storefront-contract.mjs \
  --android-root ../CastReader-Android
node docs/contracts/test-kindle-storefront-contract.mjs \
  --extension-root ../MyProject/readout-desktop

# 离线验证完整路由语义与安全负例。
node docs/contracts/test-kindle-live-route-policy.mjs

# 无账号、无 Cookie，使用真实 Android 浏览器形态 UA 的线上 L1/L2 预检。
node docs/contracts/verify-kindle-live-routes.mjs
```

Android 命令会把 Kotlin 运行时目录、地区映射、alias 和八语顺序投影回 canonical JSON；扩展命令验证运行时目录、所有派生消费者以及（已执行 `pnpm build` 时）生产 manifest 的 21 个注入 host 与共享合同完全一致。扩展的 background、content、TTS orchestrator、analytics、Pro moment 与 QuickRead 也统一使用同一精确 matcher。

线上预检会验证 13 个 canonical 的 landing/library/reader，以及 7 个 alias 的 library/reader 完整跳转链。alias `/kindle-library` 丢路径会明确显示为 `ALIAS_RISK`，不会被误报为 canonical 宕机；canonical 路径丢失、跨 marketplace、reader ASIN/ref 丢失或浏览器 UA 被拒都会失败。脚本不发送 Cookie，只使用合成 ASIN，输出不含 query 或账号信息。
