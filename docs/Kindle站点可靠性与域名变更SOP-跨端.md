# Kindle 站点可靠性与域名变更 SOP（iOS / Android）

更新日期：2026-08-06

适用范围：CastReader iOS、Android，以及任何会打开 Kindle for Web、扫描书架、恢复阅读链接或注入脚本的客户端。

相关机器合同：

- [`contracts/kindle-storefronts-v1.json`](contracts/kindle-storefronts-v1.json)：站点唯一真相源。
- [`contracts/kindle-storefront-contract-cases-v1.json`](contracts/kindle-storefront-contract-cases-v1.json)：域名安全真值表。
- [`contracts/Kindle-Storefront-Contract-v1.md`](contracts/Kindle-Storefront-Contract-v1.md)：合同字段和跨仓库消费方式。
- [`Kindle多站点Storefront适配-跨端设计方案.md`](Kindle多站点Storefront适配-跨端设计方案.md)：产品与数据模型设计。
- [`Kindle-13站点与Cookie弹框-iOS交接-2026-08-07.md`](Kindle-13站点与Cookie弹框-iOS交接-2026-08-07.md)：当前实现状态、Cookie viewport/close 安全合同与 iOS 必测矩阵。

## 1. 结论先行

Kindle 同步可靠性的第一原则不是“猜用户语言”，而是始终保持以下链条一致：

> 用户绑定的 Amazon marketplace → canonical Kindle host → 同 marketplace 登录域名 → 同 storefront 书架 → 同 storefront reader URL。

必须同时遵守四条硬规则：

1. **新导航只使用 canonical host。** alias 只能识别老数据和接受 Amazon 官方迁移跳转，不能作为书架入口。
2. **站点是账号属性，不是语言属性。** 时区、设备地区、系统语言和 App 语言只能排序推荐；用户选定或已经绑定的站点才是权威值。
3. **验证完整重定向语义，不只验证“能打开”。** 书架必须保留 `/kindle-library` 返回目标；reader 必须保留 ASIN 和 `ref_`；每一跳都不能跨 marketplace。
4. **13 个 canonical 是入口全集。** 不得因为某国存在 Amazon 零售站，就自行拼接 `read.amazon.<tld>`。

违反任一条都可能出现“登录成功但书架为空”“扫描不到书”“有书但打不开”“被重写到美区”等表面相似、根因不同的问题。

### 1.1 13 个站点唯一允许的绑定流程

13 个 enabled storefront 的产品流程和技术状态机必须完全一致，差别只能来自合同中的 canonical Kindle host 与同 marketplace 登录 host：

1. 从已绑定/用户选中的 `storefrontID` 取得 entry-enabled storefront；设备语言和时区不能在此时改写它。
2. fresh navigation 精确构造 `https://<canonicalHost>/kindle-library`，不得从 alias、零售域名或语言拼接域名。
3. 未登录时 Amazon 可以把 canonical `/kindle-library` 导向同 canonical `/landing`。
4. landing 上的登录动作必须进入同 marketplace 的 `www.amazon.*`；`openid.return_to` / `return_to` 必须精确指回第 2 步的 canonical `/kindle-library`。
5. 登录、OTP 或 CAPTCHA 完成后，主框架必须回到同 storefront 的 canonical `/kindle-library`；回到根路径、alias、其他 marketplace 或未知 host 都不能算“已连接”。
6. 页面 ready 且结构快照稳定后扫描书架；每本书写入同一个 `storefrontID`，reader URL 立即 canonicalize。
7. 开书只构造 `https://<canonicalHost>/?asin=<ASIN>&ref_=kwl_kr_iv_rec_1`；reader 登录回链必须保留同 canonical、ASIN 和 `ref_`。
8. 首次出声后才能完成 L3 的“可用”验收；仅看到登录页、302 或书架 HTML 都不是 L3。

统一流程的最小不变量：

```text
bound storefront S
  → S.canonical/kindle-library
  → S.marketplace/ap/signin?return_to=S.canonical/kindle-library
  → S.canonical/kindle-library
  → scan books tagged S
  → S.canonical/?asin=...&ref_=kwl_kr_iv_rec_1
  → first audio
```

任一箭头跨 storefront、丢 `/kindle-library`、丢 ASIN/ref 或从 alias 起步，整条绑定都失败；不能用“页面能打开”兜底成成功。

### 1.2 英文 US 与本地化 IT：流程相同，域名不能照抄

| 环节 | US（英文、无 alias） | IT（本地化 canonical） | iOS/Android 共同要求 |
|---|---|---|---|
| storefront | `us` | `it` | 以用户绑定值为真相 |
| fresh 书架 | `https://read.amazon.com/kindle-library` | `https://leggi.amazon.it/kindle-library` | 只从 canonical 构造 |
| 登录 host | `www.amazon.com` | `www.amazon.it` | 必须与 storefront marketplace 一致 |
| 登录回链 | `read.amazon.com/kindle-library` | `leggi.amazon.it/kindle-library` | 必须精确回 canonical 书架 |
| fresh reader | `read.amazon.com/?asin=…&ref_=…` | `leggi.amazon.it/?asin=…&ref_=…` | 同 canonical，并保留 ASIN/ref |
| alias | 无 | `read.amazon.it` | IT alias 只能识别/迁移，不能 fresh navigation |
| alias 书架结果 | — | 跳 `leggi.amazon.it/`，丢 `/kindle-library` | 明确报 `ALIAS_RISK`，不能当 canonical 故障 |

因此不能把 US 的 `read.amazon.com` 字面量复制到所有语言，也不能按表面规律把 IT 写成 `read.amazon.it`。客户端只消费共享合同，不推导域名。

## 2. 本轮事故复盘：为什么意大利站会显示 Kindle 无效

Android v24 的意大利入口曾使用：

```text
https://read.amazon.it/kindle-library
```

匿名真实浏览器路由为：

```text
read.amazon.it/kindle-library
  --301--> leggi.amazon.it/
  --302--> leggi.amazon.it/landing
```

第一跳把 host 改成了正确的本地化域名，却**丢失 `/kindle-library` 路径**。同时旧客户端没有把 `leggi.amazon.it` 当作意大利 Kindle canonical host，于是登录、书架识别和扫描状态相互脱节。

旧检查之所以没有挡住，是因为它只回答了“域名是否可达、第一跳是否还像 Amazon”，没有回答：

- 最终是否仍属于同一 storefront；
- `/kindle-library` 是否被保留在登录 `return_to` 中；
- reader 的 ASIN、`ref_` 是否穿过完整登录链；
- WebView 是否允许最终本地化 host；
- 新导航是否错误地从 alias 出发。

这不是意大利特例。DE、FR、IT、ES、BR、MX、NL 的 7 个 `read.amazon.*` alias 对 `/kindle-library` 都有相同的路径丢失风险。

## 3. 2026-08-06 全球站点审计结果

### 3.1 证据等级

| 等级 | 能证明什么 | 不能证明什么 |
|---|---|---|
| L1 | DNS、TLS、匿名 HTTPS 可达 | 账号能看到书 |
| L2 | 完整匿名重定向链、marketplace 登录域、`return_to`、ASIN/ref 保留 | 登录后真实书架和购买权益 |
| L3 | 对应 marketplace 真实账号完成登录 → 扫书架 → 开已购书 → 首次出声 | 其他账号、其他书仍需抽样 |

本轮独立审计中 13 个 canonical 均已完成 L1/L2；不要把它描述成 13 个地区均已完成真实账号 L3。之后从当前中国大陆出口复跑时，日本站系统 DNS 被污染/拒绝，Cloudflare、Google DoH 不可达，AliDNS/DNSPod 能解析但正确 SNI/TLS 的目标 443 仍连接超时。这说明当前出口无法完成 JP 证据采集，不能把它降级成 PASS，也不能据此误判 Amazon 路由语义已损坏；必须换网络重跑。

### 3.2 13 个可选 canonical

使用真实 Android Chrome UA 验证；iOS 另外使用 iPhone Safari UA，以及当前 reader 使用的桌面 Chrome UA 验证。两类 iOS UA 的 canonical reader 登录返回目标均保留 ASIN/ref。

| ID | canonical Kindle host | Amazon 登录 marketplace | 登录语言 | alias（仅识别/迁移） | L2 结果 |
|---|---|---|---|---|---|
| `us` | `read.amazon.com` | `www.amazon.com` | `en_US` | — | 通过 |
| `uk` | `read.amazon.co.uk` | `www.amazon.co.uk` | `en_GB` | — | 通过 |
| `ca` | `read.amazon.ca` | `www.amazon.ca` | `en_CA` | — | 通过 |
| `au` | `read.amazon.com.au` | `www.amazon.com.au` | `en_AU` | — | 通过 |
| `jp` | `read.amazon.co.jp` | `www.amazon.co.jp` | `ja_JP` | — | 独立 L2 通过；当前中国大陆出口 NETWORK/FAIL，需换网络复核 |
| `de` | `lesen.amazon.de` | `www.amazon.de` | `de_DE` | `read.amazon.de` | canonical 通过；alias 书架路径丢失 |
| `fr` | `lire.amazon.fr` | `www.amazon.fr` | `fr_FR` | `read.amazon.fr` | canonical 通过；alias 书架路径丢失 |
| `it` | `leggi.amazon.it` | `www.amazon.it` | `it_IT` | `read.amazon.it` | canonical 通过；alias 书架路径丢失 |
| `es` | `leer.amazon.es` | `www.amazon.es` | `es_ES` | `read.amazon.es` | canonical 通过；alias 书架路径丢失 |
| `in` | `read.amazon.in` | `www.amazon.in` | `en_IN` | — | 通过 |
| `br` | `ler.amazon.com.br` | `www.amazon.com.br` | `pt_BR` | `read.amazon.com.br` | canonical 通过；alias 书架路径丢失 |
| `mx` | `leer.amazon.com.mx` | `www.amazon.com.mx` | `es_MX` | `read.amazon.com.mx` | canonical 通过；alias 书架路径丢失 |
| `nl` | `lezen.amazon.nl` | `www.amazon.nl` | `nl_NL` | `read.amazon.nl` | canonical 通过；alias 书架路径丢失 |

每个 canonical 的未登录 `/kindle-library` 都先到同 host 的 `/landing`；页面登录链接指向表中对应 `www.amazon.*`，且 `openid.return_to` 精确回到该 canonical 的 `/kindle-library`。

每个 canonical 的 reader 入口：

```text
https://<canonical>/?asin=<ASIN>&ref_=kwl_kr_iv_rec_1
```

都会进入同 marketplace 的登录链，且 `return_to` 同时保留 canonical host、ASIN 和 `ref_`。

#### 3.2.1 13 canonical 统一验收矩阵

下表中的“L1/L2”是匿名路由证据；“L3”必须使用对应 marketplace 的真实账号、已购书并完成首次出声。所有行使用同一状态机，不能为某个语言另写捷径。

| ID | fresh canonical library | 同站登录 host | 必须返回 | reader 必须保留 | L1/L2 状态 | L3 状态 |
|---|---|---|---|---|---|---|
| `us` | `read.amazon.com/kindle-library` | `www.amazon.com` | 同一 canonical library | US canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `uk` | `read.amazon.co.uk/kindle-library` | `www.amazon.co.uk` | 同一 canonical library | UK canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `ca` | `read.amazon.ca/kindle-library` | `www.amazon.ca` | 同一 canonical library | CA canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `au` | `read.amazon.com.au/kindle-library` | `www.amazon.com.au` | 同一 canonical library | AU canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `jp` | `read.amazon.co.jp/kindle-library` | `www.amazon.co.jp` | 同一 canonical library | JP canonical + ASIN/ref | 独立审计通过；当前出口 NETWORK/FAIL | 需换网并用对应账号验收 |
| `de` | `lesen.amazon.de/kindle-library` | `www.amazon.de` | 同一 canonical library | DE canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `fr` | `lire.amazon.fr/kindle-library` | `www.amazon.fr` | 同一 canonical library | FR canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `it` | `leggi.amazon.it/kindle-library` | `www.amazon.it` | 同一 canonical library | IT canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `es` | `leer.amazon.es/kindle-library` | `www.amazon.es` | 同一 canonical library | ES canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `in` | `read.amazon.in/kindle-library` | `www.amazon.in` | 同一 canonical library | IN canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `br` | `ler.amazon.com.br/kindle-library` | `www.amazon.com.br` | 同一 canonical library | BR canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `mx` | `leer.amazon.com.mx/kindle-library` | `www.amazon.com.mx` | 同一 canonical library | MX canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |
| `nl` | `lezen.amazon.nl/kindle-library` | `www.amazon.nl` | 同一 canonical library | NL canonical + ASIN/ref | 独立审计通过 | 需对应账号验收 |

验收结论必须按列记录，禁止把某行历史 L2 结果复制成当前网络 PASS，也禁止把 L2 填到 L3。JP 当前出口无法连接时应保持 `NETWORK/FAIL`，换可达网络重跑。

### 3.3 alias 的准确口径

7 个本地化 alias 的行为一致：

- alias `/kindle-library`：301 到 canonical 根路径，**丢失书架路径**，属于明确的高风险迁移行为；
- alias reader：301 到 canonical，ASIN/ref 当前会保留，可用于兼容老链接；
- 新绑定、重扫、修复 URL、首次开书：**绝不能生成 alias**。

因此线上门禁将 alias 书架路径丢失报告为 `ALIAS_RISK`，而不是误报 canonical 站点宕机；但客户端测试必须证明 fresh navigation 永远只从 canonical 出发。

| Storefront | 禁止作为 fresh 入口的 alias | fresh 必须使用 |
|---|---|---|
| DE | `read.amazon.de` | `lesen.amazon.de` |
| FR | `read.amazon.fr` | `lire.amazon.fr` |
| IT | `read.amazon.it` | `leggi.amazon.it` |
| ES | `read.amazon.es` | `leer.amazon.es` |
| BR | `read.amazon.com.br` | `ler.amazon.com.br` |
| MX | `read.amazon.com.mx` | `leer.amazon.com.mx` |
| NL | `read.amazon.nl` | `lezen.amazon.nl` |

### 3.4 不能作为入口的域名

- `read.amazon.cn`：仅识别历史数据，`entryEnabled=false`。匿名页面为空壳，不能提供新绑定入口。
- SE/TR/AE/SG/PL/EG/SA：抽查的 `read.amazon.se`、`.tr`、`.ae`、`.sg`、`.pl`、`.eg`、`.sa` 无可用 DNS/HTTPS Kindle for Web 服务，已从合同删除。
- 当前 13 个 canonical 均有可独立复核的 Amazon 官方 Kindle for Web landing；零售 marketplace 列表只用于交叉核对，不能单独推导 reader host。

**MUST NOT：**仅凭 Amazon 零售 marketplace 存在就合成 Kindle 阅读域名。

### 3.5 官方来源与人工复核入口

- [Amazon KDP 官方 marketplace/书籍链接列表](https://kdp.amazon.com/en_US/help/topic/G200652190)：用于核对 Amazon 零售 marketplace；它列出 `.com`、`.co.uk`、`.de`、`.fr`、`.es`、`.it`、`.co.jp`、`.com.br`、`.ca`、`.in`、`.com.au`、`.com.mx`、`.nl`。**该页面不能单独证明 Kindle for Web 的 reader host。**
- [Amazon Kindle for Web 全球入口（US）](https://read.amazon.com/landing)：用于人工查看 Amazon 当前暴露的 Kindle for Web 入口与登录动作。

13 个 canonical landing 人工复核入口：

| Storefront | 官方 landing |
|---|---|
| US | [read.amazon.com/landing](https://read.amazon.com/landing) |
| UK | [read.amazon.co.uk/landing](https://read.amazon.co.uk/landing) |
| CA | [read.amazon.ca/landing](https://read.amazon.ca/landing) |
| AU | [read.amazon.com.au/landing](https://read.amazon.com.au/landing) |
| JP | [read.amazon.co.jp/landing](https://read.amazon.co.jp/landing) |
| DE | [lesen.amazon.de/landing](https://lesen.amazon.de/landing) |
| FR | [lire.amazon.fr/landing](https://lire.amazon.fr/landing) |
| IT | [leggi.amazon.it/landing](https://leggi.amazon.it/landing) |
| ES | [leer.amazon.es/landing](https://leer.amazon.es/landing) |
| IN | [read.amazon.in/landing](https://read.amazon.in/landing) |
| BR | [ler.amazon.com.br/landing](https://ler.amazon.com.br/landing) |
| MX | [leer.amazon.com.mx/landing](https://leer.amazon.com.mx/landing) |
| NL | [lezen.amazon.nl/landing](https://lezen.amazon.nl/landing) |

人工页面只是一手来源之一，最终仍要跑完整 L1/L2 门禁：landing 能显示不代表 `/kindle-library` 的回链和 reader ASIN/ref 没有丢失。

## 4. 唯一真相源与跨端消费

唯一业务目录是：

```text
CastReader/docs/contracts/kindle-storefronts-v1.json
```

它必须定义：

- `canonicalHost`：新导航唯一允许的 host；
- `aliasHosts`：历史识别和同 storefront 迁移；
- `entryEnabled`：是否允许出现在选择器和推荐结果；
- `marketplaceRegion`：地区推荐；
- `languageCandidateOrder`：语言弱先验；
- 统一 library path、reader path 和 reader ref。

跨端要求：

- iOS 运行时目录必须逐字段投影 canonical JSON；
- Android 本地镜像和 `KindleStorefrontCatalog` 必须逐字段投影 canonical JSON；
- 各端不得另外维护“临时补丁 host 数组”；
- CI 必须跑结构化合同测试，不能依赖人工比对。

合同变更必须先改 canonical JSON，再同步/生成客户端镜像和测试。禁止只改某一端代码。

## 5. 站点选择：推荐不等于绑定

### 5.1 权威顺序

1. 用户明确选择或已绑定、且仍 `entryEnabled` 的 storefront；
2. 从可信老书 reader URL canonical/alias 反推的 storefront；
3. 设备地区；
4. App/系统语言候选；
5. 时区只作为最后排序信号；
6. 仍无法判断时使用合同 fallback，但界面必须允许切换。

语言和地区可能冲突。例如住美国的西语用户可能拥有 Amazon.com 书架；同一邮箱在 Amazon.com 与 Amazon.es 也可能是两个独立书架。

**MUST：**所有 13 个 enabled storefront 都可见；信号只改变排序和“推荐”标记。

**MUST NOT：**因为界面是西语就强制 Amazon.es，或因为时区是 GMT+1 就静默改站。

### 5.2 当前 App 语言候选

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

中文不把 `cn` 变成入口；荷兰站虽没有独立 App UI 语言候选，也必须通过 NL 地区推荐和完整站点列表可选。

## 6. URL 与 WebView 安全合同

### 6.1 精确 URL 验证

任何允许加载、注入、扫描或修复的绝对 URL 都必须满足：

- scheme 为 `https`；
- host 经系统 URL parser 解析后精确命中 canonical/alias 集合；
- port 为空或 `443`；
- username/password 为空；
- 当前主 WebView 的目标 storefront 与绑定 storefront 相同。

禁止 `contains("amazon")`、`contains("read.amazon.")`、前缀或后缀匹配。以下必须拒绝：

```text
https://read.amazon.com.phish.example/
https://user@read.amazon.com/
http://read.amazon.com/
https://read.amazon.com:444/
https://kindle.future.example/?asin=B012345678
```

ASIN 有效不等于 URL 可信。仅纯 ASIN 老记录可按已绑定 storefront 迁移；带未知绝对 host 的记录不得被“修复”为可信 URL。

### 6.2 登录例外也必须锁定 marketplace

WebView 可放行当前 storefront 的 Kindle host，以及同 marketplace 的 Amazon 登录页面。登录例外必须同时验证：

- 登录 host 属于当前 storefront 对应的 Amazon registrable domain；
- `openid.return_to` / `return_to` 若存在，目标是当前 entry-enabled storefront；
- 书架连接和后台书架恢复场景中，目标还必须是该 storefront 的 canonical `/kindle-library`，不能是 canonical 根路径，也不能是同站 alias；
- 识别到的另一 Kindle storefront 即使 path 叫 `/ap/signin`，也不能绕过跨站限制。

### 6.3 书架和 reader 的语义门禁

canonical library 验收：

- 完整链所有 URL 均属于同 storefront；
- 如果终点是 `/landing`，HTML 中登录链接必须把 `return_to` 指回 canonical `/kindle-library`；
- 不得把 alias 后续 landing 的登录按钮当成“alias 保留了路径”的证据。

reader 验收：

- 完整链所有 URL 均属于同 storefront；
- 任一嵌套 `return_to` 解码后必须同时包含原 ASIN 和 `ref_`；
- 只保留 ASIN、丢 ref，或只保留 ref、丢 ASIN，都失败。

### 6.4 iOS 出现问题时的直接补正顺序

iOS 不单独发明站点逻辑。按症状从上到下修，前一层未通过时不要用下一层兜底：

| 症状 | 先检查 | 应补正的位置 | 通过标准 |
|---|---|---|---|
| 第一次打开就进错站/alias | `boundStorefrontID` 与 `libraryURL` | `CastReader/Models/KindleStorefront.swift`、`CastReader/Views/Kindle/KindleLibraryConnectView.swift` | US 生成 `read.amazon.com`；IT 生成 `leggi.amazon.it`；所有 13 行来自合同 |
| 登录进入其他 marketplace | 登录 host、`openid.return_to` / `return_to` | `KindleStorefrontNavigationPolicy`，连接 WebView 的 navigation action 与 response delegate | 外层登录域和内层回链都属于当前 storefront；跨站、phish、畸形编码拒绝 |
| 登录完成仍停 landing/显示已连接但没书架 | 最终主框架 URL 是否精确 canonical `/kindle-library` | `KindleLibraryConnectView.swift`、`KindleLibraryStore.swift` | 根路径、alias、其他站点都不能设置 connected；只有 canonical library 可开始扫描 |
| 书架扫描过早结束或空书架误判 | ready/loading/滚动到底/结构快照 | `KindleWebScripts.swift`、`KindleLibraryStore.swift` | 空书架有独立证据；有书时结构稳定后完成；DOM 变化有明确失败码 |
| 书能同步但开书跳美区/别的站 | 每本书的 `storefrontID`、修复后的 reader URL | `KindleModels.swift`、`KindleLibraryStore.swift` | 扫描结果立即 canonicalize；reader 使用书所属 storefront，并保留 ASIN/ref |
| reader 出现 Cookie 同意层但操作按钮看不到 | WKWebView 是否被放大、上移并由外层裁切 | `KindleWebScripts.swift`、`KindleBookView.swift`、`KindleLibraryConnectView.swift` | 只侦测 Amazon 原生层；出现时临时使用完整 viewport，消失后恢复阅读裁切；不自动选择、不改 DOM |
| 一个站点过期导致所有 Amazon 会话退出 | website data 清理范围 | `KindleLibraryStore.swift` | 自动重绑只清当前 marketplace；用户主动断开才清全部 |
| 非英语站扫描失败 | 是否结构优先、目标语言 fixture 是否覆盖 | `KindleWebScripts.swift`、`CastReaderTests/KindleStorefrontTests.swift` | 目标语言有书/空书架/登录 challenge/reader 控件 fixture；不依赖单一英文文案 |

iOS 最小实现顺序应保持：

```text
KindleStorefront.entry(boundStorefrontID)
  → storefront.libraryURL
  → allowsMainFrame(expectedStorefrontID + exact auth return_to)
  → isExactLibraryURL
  → scrape(book.storefrontID = storefront.id)
  → storefront.readerURL(asin)
```

每次补正至少增加以下回归：

- US canonical 正例与 IT localized canonical 正例；
- IT `read.amazon.it/kindle-library` 不得成为 fresh URL；
- 同 marketplace 登录 + 正确回链正例；外层同站但回链 US、phish、malformed 负例；
- WebView navigation action 与 response 两层跨 storefront 负例；
- 7 alias 老书可迁移，但迁移后写 canonical；
- 13 storefront runtime 投影与共享 JSON 完全一致。

## 7. User-Agent 是路由合同的一部分

Amazon 会根据 UA 把 `/kindle-library` 路由到不同页面。curl 或自定义 UA 可能得到：

```text
/kindle-library/not-supported
```

这首先说明验证器或 WebView UA 不符合浏览器路径，不能直接下结论“站点宕机”。

要求：

- 匿名 live verifier 固定真实 Android Chrome/WebView 形态 UA；
- iOS 连接/默认 WebView 用真实 iPhone Safari UA 回归；
- iOS reader 桌面模式用生产 `desktopChromeUserAgent` 回归；
- 检测到 `not-supported` 时以 `verifier_browser_ua_rejected` 失败，提示修验证器/客户端 UA，而不是改 storefront。

## 8. 会话、切站与强制重新登录

- Amazon cookie 按 marketplace 域隔离，同一设备可能同时持有多个站点的合法会话。
- 用户切换 storefront 时保留其他 marketplace 会话，但清空当前绑定书架视图并重新扫描。
- 会话过期触发强制重新登录时，只清当前 storefront 的 Amazon website data/cookies。
- 用户明确“断开 Amazon 账号”时，才允许清全部 Amazon marketplace 数据。
- 任何日志、埋点、测试输出不得包含 Cookie、token、email、完整 URL、ASIN 或书名。

把“清所有 Amazon Cookie”当作通用恢复会导致其他站点被无故登出，也会掩盖实际的站点匹配错误。

## 9. 书架扫描与本地化页面

扫描逻辑必须**结构优先、文案兜底**：优先稳定的 DOM 属性、链接结构、ASIN、封面和卡片层级；不可把英文按钮或英文空书架文案当主判断。

每个 supported storefront 都要覆盖：

- 有书、空书架、未登录、OTP/CAPTCHA、登录过期；
- 标题、作者、最近阅读/位置、页码/进度；
- canonical 与 alias 老数据迁移；
- 非拉丁文字和双向/竖排内容不影响站点识别。

本轮 Android 与 iOS 均已补荷兰语空书架、账户/控件、bad title、`door` 作者、`Pagina/Locatie/Positie/Laatst gelezen` 进度词，以及翻页、目录、显示偏好兜底和测试；iOS 另有意大利语书架、作者、最近阅读、登录 challenge 与 reader 控件 WKWebView fixture。以后新增站点时必须同时添加目标语言 HTML fixture，不能只把 host 加入目录。

### 9.1 阅读页 Cookie 同意层与 viewport 裁切

真实 Amazon.it 账号暴露了另一个与站点域名无关、但会表现成“Kindle 无效”的问题：为了隐藏 Kindle 原生上下栏，客户端可能把 reader WebView 放大、上移，再由外层容器裁切。Amazon 原生 Cookie 同意层通常固定在其 DOM viewport 底部；底部裁切后，提示仍在但“接受/拒绝/管理偏好”等操作区可能落在 CastReader 可视范围之外，用户无法继续。

这不是意大利语专属问题。Cookie 层是否出现由 marketplace、会话状态、Amazon 灰度和隐私区域决定，13 个 enabled storefront 都必须使用同一状态机。跨端实现必须遵守：

1. **不代替用户作出隐私选择。** 优先识别 Amazon 稳定结构（例如 `#sp-cc`、`ion-modal` 与原生 action）。只有同时确认 Cookie/modal 语义、唯一可见且可交互的纯关闭按钮时，允许每个 document 最多点击一次关闭；不得点击 Accept/Allow/Agree/OK/Reject/Manage，不得移除/隐藏 Amazon DOM，也不得生成 CastReader 自制同意按钮。
2. **无法安全关闭时完整展示原生操作区。** Android 暂停 reader 的放大/平移/裁切；iOS 返回 `KindleViewportCrop.identity`。必须让 Amazon 原按钮在同一个 WebView 中自然重排到可见边界内，由用户自行处理。
3. **弹层消失后恢复阅读布局。** 观察器采用 DOM mutation 事件驱动，不使用持续轮询；自动关闭后只做一次短 follow-up，仍可见才切 identity。客户端保存正常 reader crop，不把临时 identity 覆盖为永久布局。新主框架导航和 reader 销毁时清除旧可见状态，避免旧 document 的迟到消息污染新页面。
4. **语言无关、结构优先。** EN、DE、FR、IT、ES、PT、NL、JA、HI 文案只能用于 generic dialog 兜底；已知 Amazon DOM ID/class/action 才是主要证据，不能因为新翻译没出现在正则里就再次遮挡按钮。
5. **不记录隐私内容。** 日志最多记录 storefront、`visible/hidden` 与阶段；不得记录 consent 文案、用户选择、Cookie 名称/值、完整 URL、账号信息。

iOS 对应实现位置：

```text
KindleWebScripts.amazonCookieConsentBridge
  → castReaderKindle { type: "kindle-cookie-consent", documentToken,
                       visible, autoCloseAttempted, decision }
  → KindleBookViewModel.isAmazonCookieConsentVisible
  → KindleCookieConsentViewportPolicy
  → KindleWebViewContainer（identity 展开 / 正常 crop 恢复）
```

Android 与 iOS 必须保持等价语义：WebView 内最多对唯一、明确的纯关闭控件尝试一次；否则原生容器临时取消 reader crop。任何 Cookie 选择都只能由用户点击 Amazon 原生控件完成。

最小回归 fixture 必须验证：唯一 X 恰好点击一次；Accept/Reject/Manage 点击数始终为 0；无 X、多个 X、link/submit/disabled/hidden 候选都不点击并进入完整 viewport；删除/关闭弹层后只恢复一次原 crop；旧 document 消息被丢弃。真实账号 L3 还需在至少一个本地化站点和一个英语站点各验证一次，不能只用静态 HTML fixture 代替。

## 10. 旧数据迁移与合并

每本 Kindle 书必须带 `storefrontID`。迁移顺序：

1. 有合法显式 `storefrontID` 时，以它作为书的所有权站点；
2. 否则从可信 `readerURL` host 反推，canonical 和 alias 都可识别；
3. 再看 `lastReadURL`，但不能让旧版本误写的美区 last-read 覆盖可信 reader URL；
4. 多本老书反推绑定站点时采用多数票，平票按合同稳定顺序；
5. 修复后的 reader URL 必须写成该 storefront canonical host。

扫描合并时，实际观察到的可信 URL host 优先于页面脚本声称的 storefront。跨站书不能混进当前绑定书架，“继续”区也不能跨站串书。

## 11. 可观测性与隐私

Kindle 内容链事件应带 `storefront`（只允许 13 个 enabled ID），用于区分：

- `content_intent` / `content_ready` / `content_failed`；
- `read_start` / `read_first_audio` / 里程碑 / 结束；
- 解读对应事件；
- `cross_storefront:<id>`、`unsupported_storefront:<id>`；
- `unknown_host:<registrable-domain>` 域名漂移哨兵。

未知 host 只记录隐私安全的 eTLD+1，并按域去重。禁止记录完整 URL、path/query、ASIN、书名、Amazon 邮箱、Cookie 或 token。

当前后端 `library_connection` 事件合同尚未接受 `storefront`。这是服务端 schema 缺口，不得由客户端单方面加字段后假设服务端已接收；必须先完成服务端合同、校验器和各端同步上线。

## 12. 自动化门禁

从 iOS 仓库执行：

```bash
cd /Users/xuxuheng/Documents/CastReader

# JSON 自检，并比对 Android 运行时投影。
node docs/contracts/test-kindle-storefront-contract.mjs \
  --android-root ../CastReader-Android

# 纯函数/离线 fixture：alias 路径丢失、跨站、return_to、ASIN/ref、隐私输出。
node docs/contracts/test-kindle-live-route-policy.mjs

# 无账号、无 Cookie 的 L1/L2 线上完整重定向预检。
node docs/contracts/verify-kindle-live-routes.mjs
```

live verifier 的固定行为：

- 使用合成 ASIN，不消费真实账号；
- 不发送 Cookie；
- canonical 检查 landing、library、reader；
- alias 检查 library、reader；
- 跟随最多 10 跳并检查整条链；
- 同一 storefront 内串行，storefront 之间有限并发；
- 系统 DNS 失败时并发查询 Cloudflare、Google、AliDNS、DNSPod DoH，缓存同 host 结果，并继续保留 SNI/证书校验；
- 输出只保留 host + path，不输出 query；
- 7 个 alias library path loss 显示为 `ALIAS_RISK`，不使 canonical 误判失败；
- 任何 canonical 路径丢失、跨 storefront、reader identity 丢失或 UA rejected 都退出失败。

DoH 只用于排除本地解析污染，绝不能关闭 TLS 验证、忽略 SNI 或把“DNS 解析成功但 443 不可达”记为通过。网络失败应保持 `NETWORK/FAIL`，换可达网络或 CI 出口复跑。

### 12.1 当前出口最近一次 iOS Safari 匿名结果

执行：

```bash
node docs/contracts/verify-kindle-live-routes.mjs --profile=ios-safari
```

2026-08-06 结果：US/UK/CA/AU/DE/FR/IT/ES/IN/BR/MX/NL 的 canonical landing、library、reader 共 36 项通过；DE/FR/IT/ES/BR/MX/NL 的 7 个 alias library 均准确报告 `ALIAS_RISK`，alias reader 保留 ASIN/ref。JP 的 landing/library/reader 共 3 项因当前出口系统 DNS 污染且 DoH 正确地址 443 仍不可达而保持 `NETWORK/FAIL`，进程退出 1。该结果证明门禁 fail-closed，不代表 JP canonical 语义失败；JP 必须换可达网络重跑，不能手工改为 PASS。

## 13. 真机/真实账号 L3 验收矩阵

发布前至少执行：

| 场景 | 验收结果 |
|---|---|
| US 主回归账号 | 登录、同步书架、开已购书、首次出声、返回继续阅读 |
| 本次修改涉及的 marketplace | 与 US 相同的完整链路 |
| 7 个本地化 canonical 中至少 1 个 | fresh navigation 证明未使用 alias |
| 错站账号 | 书架为空时能切换站点，不把空书架误报为“无 Kindle” |
| OTP/CAPTCHA | 返回 App 后 WebView 不重建、不丢上下文 |
| 会话过期 | 只清当前 marketplace，重新登录后恢复书架和阅读锚点 |
| 老版本 alias 书 | 识别旧 URL，迁移为 canonical，仍打开同一本书 |
| 跨站恶意/错误 URL | 拒绝加载、拒绝入库，并产生隐私安全错误码 |

没有对应地区真实账号时，要明确标为“L3 未验”，不能用匿名 302 代替。

## 14. 域名变化处理 SOP

当用户反馈“Kindle 无效/书架为空/登录循环”，按以下顺序处理：

1. **锁定用户选择的 storefront ID。** 不先看手机语言；确认 Amazon 购书 marketplace。
2. **只收集隐私安全证据。** App 版本、OS、storefront ID、失败阶段、eTLD+1、HTTP/导航分类；不要索取 Cookie/token/完整 URL。
3. **复现三条 canonical 路由。** landing、`/kindle-library`、合成 ASIN reader；记录完整跳转语义但只输出脱敏 host/path。
4. **对 alias 单独分类。** alias library path loss 是迁移风险，不代表 canonical 故障；先证明 fresh navigation 是否错误使用 alias。
5. **用真实浏览器 UA 复测。** 出现 `not-supported` 时先排 UA。
6. **核对 Amazon 官方入口。** 不能根据零售域名猜 Kindle 域名。
7. **先改 canonical JSON。** 新 host 标明 canonical 或 alias；禁用入口要写 `entryDisabledReason`。
8. **同步跨端消费者。** iOS、Android、扩展的运行时投影、WebView allowlist、cookie scope、JS host map、fixtures 一起更新。
9. **补回归 fixture。** 至少加入 canonical/alias、library/reader、cross-storefront、auth return_to、ASIN/ref、目标语言 DOM。
10. **跑第 12 节三层自动门禁。** 然后执行本次涉及 marketplace 的 L3 真机链路。
11. **灰度与监控。** 观察 `storefront_resolution`、空书架、首次出声转化；未知域漂移只看 eTLD+1。
12. **回滚原则。** 若 canonical 语义门禁失败，禁止发布新增入口；可以保留 alias 识别，但不能退回 alias fresh navigation。

## 15. 当前跨端落地状态

### Android

- 13 个 enabled canonical、7 个 alias、CN recognition-only 已进入统一 catalog；
- fresh library/reader 使用 canonical，alias 用于识别和旧数据迁移；
- WebView/auth 导航按 expected storefront 精确限制；
- 强制登录和 cookie 处理按 marketplace 收敛；
- 荷兰语空书架、账户/控件、bad title、`door` 作者、进度、翻页/目录/显示偏好兜底已覆盖；
- Kindle 内容事件带 storefront，未知域只记 eTLD+1；
- 合同、迁移、forced sign-in、恢复、analytics、本地化 DOM 已有单元测试覆盖；本轮全量 test、assemble、lint 通过。

### iOS

本轮已对齐以下关键差异：

- 13 个 enabled storefront 的书架新导航统一由 `libraryURL` 生成 `https://{canonicalHost}/kindle-library`；导航策略只接受 expected storefront 的 canonical host；
- 7 个 alias 仅供 URL 所有权识别、旧书迁移和 canonical 化，书架与 reader fresh navigation 均拒绝 alias；
- 英文界面不会覆盖 Amazon.it 的地区推荐或已绑定权威值，意大利站始终进入 `https://leggi.amazon.it/kindle-library`；
- 会话过期强制重绑只清当前 storefront；用户主动断开才清全部 Amazon 数据；
- 书籍校验拒绝未知/spoof/HTTP/userinfo/非 443 绝对 URL，即使带合法 ASIN；
- 登录例外限制到当前 marketplace，并校验 `openid.return_to` / `return_to`；书架场景还要求回到 canonical `/kindle-library`；
- 可见书架、reader、过期会话 warm-up 和旧书自动恢复 WebView 都有主框架 action 与 response 两层门禁，后台恢复不能绕过 canonical 限制；
- 保留纯 ASIN、已知 alias 的老数据迁移；
- fresh scrape 产出的 reader URL 立即 canonicalize，alias 只用于旧数据识别与迁移；
- 扫描完成要求 canonical library、页面 ready、非 loading、滚动到底和结构快照稳定，不再按“连续两轮没新增书”提前结束；
- 失败可区分 `auth_redirect_rejected`、`library_path_lost`、`empty_shelf`、`scan_timeout`、`DOM_changed`；
- 补齐意大利语与荷兰语的书架、作者、进度、登录 challenge、翻页/目录/显示偏好 DOM fallback 和 WKWebView fixture；
- reader Cookie 同意层只允许对唯一、明确的纯关闭控件尝试一次；其他情况展示完整 Amazon viewport，且绝不自动接受/拒绝/管理 Cookie；
- DEBUG 会话诊断只记录 storefront 粗粒度计数，不记录 Cookie 名称、值、哈希、完整 URL、ASIN、书名或邮箱；
- Kindle 内容事件携带 13 个 enabled `storefront`；`library_connection` 继续遵守当前后端合同，不由客户端单方面增加该字段。

`KindleStorefrontTests` 本轮 28 项测试通过，覆盖全部 13 个 canonical、全部 7 个 alias 拒绝 fresh navigation、alias→canonical 迁移、Amazon.it 英文界面/绑定权威、登录回链、Cookie scope、意大利/荷兰 DOM fixture；Cookie consent 另由 close-only/完整 viewport 合同测试覆盖。跨端 catalog 和离线 live-route policy 门禁同时通过。以后任何站点目录、URL 修复、WebView 或 cookie 变更，都必须保持这些测试和三层门禁通过。

## 16. 发布红线

出现任一项不得发布 Kindle 相关改动：

- 新导航生成 alias 或 recognition-only host；
- canonical library 丢失 `/kindle-library` 返回语义；
- reader 登录链丢 ASIN/ref；
- 任一跳跨 marketplace；
- auth 例外不检查 return target；
- URL 识别使用模糊字符串匹配；
- 清除所有 marketplace 会话来修单站过期；
- 只新增域名、不补目标语言 DOM fixture；
- 埋点包含完整 URL、ASIN、书名、邮箱、Cookie/token；
- 仅完成 L1/L2，却对外宣称真实账号同步已验证。
