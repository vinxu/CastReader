# Kindle 多站点（Storefront）适配 · 跨端设计方案

2026-07-30。动 Kindle 前先读本仓库 Kindle 系列文档；本方案描述产品与数据模型。线上域名真值、重定向风险、发布门禁和故障处理以 [`Kindle站点可靠性与域名变更SOP-跨端.md`](Kindle站点可靠性与域名变更SOP-跨端.md) 为准；机器目录以 [`contracts/kindle-storefronts-v1.json`](contracts/kindle-storefronts-v1.json) 为唯一真相源。

## 0. 问题的本质：站点是「账号属性」，不是「语言属性」

用户的书在哪，取决于他的亚马逊账号注册在哪个 marketplace（各 marketplace 的账号与书库互相独立，同一邮箱在 .com 和 .es 是两个书库）。App 语言只是弱先验：住美国的西语用户在 read.amazon.com，西班牙用户在 leer.amazon.es。所以：

> **语言只用来排序候选，永远不能用来决定站点；站点必须显式选择 + 持久化，并给「猜错」留自愈通道。**

三个身份要分清：App 界面语言（AppLanguageManager）/ 设备地区（`Locale.region` 或 SKStorefront）/ 亚马逊 marketplace（真相，只有用户和亚马逊知道）。默认值用设备地区，展示排序用语言先验，最终以用户选择为准。

## 1. 现状诊断（两类现象的代码根因）

| 现象 | 根因 | 位置 |
|---|---|---|
| 登录后书架为空 | 入口写死 `read.amazon.com/kindle-library`，西班牙账号登上美区空书库 | `KindleWebScripts.libraryURL`；HomeView 两处默认 URL |
| 书能开但不识别为 Kindle 页 | 识别用 `host.contains("read.amazon.")`，漏掉本地化别名 **leer.amazon.es / ler.amazon.com.br** | `KindleModels.isKindleReaderPath` / `isBareKindleRoot`（930/974）；`KindleBookView` 页面分类（1336） |
| **隐性：书被改写到美区**（最深的坑） | URL「修复」路径 `canonicalReaderURL(asin:)` 硬编码 `https://read.amazon.com/?asin=…`——非美用户的书修一次就跳错站 | `KindleModels.swift:967` |
| 安全瑕疵 | `contains("read.amazon.")` 可被 `read.amazon.phish.com` 伪匹配 | 同上两处 matcher |
| 扩展端同病 | content script 需要与共享合同的 21 个可识别 host 同源；「打开书架」动作不能写死 .com | `readout-desktop background.ts:678` |

## 2. 设计框架（六层，单一真相源贯穿）

### 第 0 层 · `KindleStorefront` 单一真相源（新文件 `Models/KindleStorefront.swift`）

```swift
struct KindleStorefront: Codable, Identifiable, Equatable {
    let id: String            // "us" "uk" "de" "es" "jp" "br" …
    let canonicalHost: String // "read.amazon.com" / "lesen.amazon.de" / "leer.amazon.es"
    let aliasHosts: [String]  // de: ["read.amazon.de"]；es: ["read.amazon.es"]
    let displayName: String   // "Amazon.es"
    var libraryURL: URL       // https://<canonicalHost>/kindle-library
    func readerURL(asin: String) -> URL   // https://<canonicalHost>/?asin=…
}
```

- **站点目录**（2026-07-30 官方入口匿名网络验证）：us uk ca au jp **de(lesen)** **fr(lire)** **it(leggi)** **es(leer)** in **br(ler)** **mx(leer)** **nl(lezen)**；**cn 只识别不提供入口**（Kindle 中国已关停，历史书签仍要能认）。SE/TR/AE/SG/PL/EG/SA 只有 Amazon retail marketplace，未发现可用 Kindle for Web 入口，不能合成 `read.amazon.*` 域名。
- **`matches(host:) -> Bool`**：精确域名集合（canonical + alias 全集）做**整域匹配**，替换所有 `contains("read.amazon.")`——同时修掉伪匹配。
- **默认推荐 `suggested(deviceRegion:appLanguage:)`**：设备地区 → 站点映射为主（ES→es、JP→jp、BR→br、US→us…），命不中时用语言先验排序：

| App 语言 | 候选顺序（先验，仅排序） |
|---|---|
| en | us, uk, ca, au, in |
| es | es, mx, us |
| pt-BR | br, us |
| ja | jp, us |
| de | de, us |
| fr | fr, ca, us |
| it | it, us |
| hi | in, us |
| zh | 本轮不参与候选适配（cn 不提供） |

### 第 1 层 · 入口（绑定时显式选站）

- 绑定页顶部加「亚马逊站点」选择器：默认 = `suggested(...)`，样式「🇪🇸 Amazon.es ▾」，登录前可改。
- 选定后写入 `KindleLibraryStore.boundStorefrontID` 持久化；此后所有入口 URL（书架、扫描、恢复）一律从 storefront 取，**删除全部字面 URL**。
- 设置页提供「切换亚马逊站点」（= 换站重绑流程）。

### 第 2 层 · 识别（全域名集合，处处同源）

`isKindleReaderPath` / `isBareKindleRoot` / KindleBookView 页面分类 / cookie 过滤 / 任何 JS 内 `location.host` 判断，全部改走 `KindleStorefront.matches(host:)`。识别集合**永远是全站点**（不只当前绑定站）——用户点到跨站链接也要认得。

### 第 3 层 · 书架数据（storefront 成为一等字段）

- `KindleBook` 增 `storefrontID: String?`；扫描入库时打上当前绑定站。
- **`canonicalReaderURL(asin:)` → `readerURL(asin:storefront:)`**：修复路径用 `book.storefrontID ?? boundStorefrontID`，禁止落回硬编码 .com。这是 P0 里最重要的一刀。
- **迁移**：老用户无 storefront 记录 → 从既有书的 `readerURL` host 反推（多数票），推不出默认 us；一次性完成，打日志（只记 storefront id，不记 URL）。

### 第 4 层 · 会话与 WebView 生命周期

- Cookie 天然按域隔离，共存于同一 `WKWebsiteDataStore`；换站**不清**其他站会话。
- 沿用绑定书库铁律（WeRead 契约同源）：登录期间不 reload/不重建 WebView；**换站 = 完整的重绑流程**（新导航到新站登录页），不做站内热切换。P0/P1 阶段同一时刻只有一个激活站点。

### 第 5 层 · 自愈（把两类现象变成产品内恢复路径）

- **空书架恢复卡**：登录成功 + 扫描 0 本 → 「书架是空的？你的书可能在其他亚马逊站点」+ 候选列表（设备地区优先）一键换站重扫。接入 `KindleLibraryRecoveryService` 既有状态机。
- **域名漂移哨兵**：URL 带 ASIN 形态但 host 不在集合内 → 埋点记 eTLD+1（不记完整 URL）。亚马逊改域名/加别名时第一时间在数据里看到（扩展端当年就是靠 extraction_fail 聚类发现 leer/ler 的）。

### 第 6 层 · 脚本与埋点

- `KindleWebScripts` 审计：所有选择器不得依赖英文界面文案（各站 UI 本地化），必须结构化（DOM 形态/属性）；进度/Whispersync 请求一律同源相对路径。
- 埋点：kindle 事件加 `storefront` 维度（契约 + 校验脚本 + 测试三件套同步改；禁 URL/PII，只有站点 id）。

## 3. 跨端对齐

| 端 | 动作 |
|---|---|
| iOS | 本方案 P0-P2 |
| 扩展 | `background.ts:678` 打开书架改为「最近 Kindle 标签页的 host ?? 设备语言先验」；matches 已全无需动 |
| Android | kindle/ 包按同一模型移植（storefront 字段 + 选择器 + 恢复卡），契约以本文为准 |

## 4. 分期落地

- **P0（随 1.2.15，止血）**：`KindleStorefront` 模型 + 全域名识别（含 leer/ler + 反伪匹配）+ `canonicalReaderURL` 站点化 + 绑定页选择器 + 老数据迁移。
- **P1**：空书架恢复卡 + 设置页换站 + 埋点维度 + 域名哨兵 + 扩展端书架入口修复。
- **P2**：多站点并存书架（旅居用户）、登录后 marketplace 自动探测、JS 选择器结构化审计收尾。

## 5. 测试契约

- 单测：`matches(host:)` 真值表（21 个 canonical + aliases 全过；`www.amazon.com`、`read.amazon.phish.com`、`fooread.amazon.com` 全拒）；`readerURL(asin:storefront:)` 逐站点；本地化 alias→canonical 跳转仍属于同一 storefront；迁移多数票推断；suggested 的地区/语言矩阵。
- 契约脚本：仿 `test-weread-ios-contract.mjs`，两端跑同一份站点目录 JSON（目录本身抽成共享数据，iOS/扩展/Android 三端同源）。
- 自动验收：13 个 canonical 入口均通过 HTTPS 响应验证；未登录的 `/kindle-library` 返回同一地区的 landing；DE/FR/IT/MX/NL 的旧 `read.amazon.*` 跳转目标均被识别为原 storefront，不会落到美国站。
- 账号验收：有对应 marketplace 账号时，再完成书架扫描→开书→朗读/解读；US 账号做回归。没有真实地区账号时，不把匿名路由验证误报为书架功能已实测。
