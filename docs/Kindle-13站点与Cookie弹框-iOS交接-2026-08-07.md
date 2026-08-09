# Kindle 13 站点与 Cookie 弹框：iOS 适配交接

更新日期：2026-08-07

适用对象：CastReader iOS Agent、Android Agent、发布验收人员。

权威站点合同与完整路由规范仍以以下文件为准，本文件只记录本轮实现状态、Cookie 弹框方案和 iOS 待办：

- [`contracts/kindle-storefronts-v1.json`](contracts/kindle-storefronts-v1.json)
- [`Kindle站点可靠性与域名变更SOP-跨端.md`](Kindle站点可靠性与域名变更SOP-跨端.md)

## 1. 结论

1. 13 个可绑定站点必须统一走同一状态机，差别只能是 canonical Kindle host 和同 marketplace 登录域名。
2. 意大利 fresh library 必须是 `https://leggi.amazon.it/kindle-library`，不能是 `https://read.amazon.it/kindle-library`。
3. DE/FR/IT/ES/BR/MX/NL 的 7 个 `read.amazon.*` alias 都会在书架跳转时丢 `/kindle-library`；alias 只能识别和迁移，不能 fresh navigation。
4. Android 与 iOS 当前工作区源码已经能生成 13 个 canonical fresh URL；但 iOS 的 canonical-only 导航门禁、登录回链校验、Cookie viewport 和相关测试仍是未提交改动。发布 iOS 前必须确认这些文件进入实际 archive，不能把“本地工作区已修”当作“线上已修”。
5. Android 当前 Cookie 方案不是自动同意 Cookie：它只对唯一、明确的关闭控件尝试一次关闭；无法安全确认时显示完整 Amazon viewport，由用户自行处理。
6. Android v3 仍有候选控件与分页稳定性风险。iOS 应实现下文的收敛版合同，而不是逐行照抄 Android 当前脚本。

## 2. 13 个站点

| ID | canonical Kindle host | 同站 Amazon 登录域 | alias（仅识别/迁移） |
|---|---|---|---|
| US | `read.amazon.com` | `www.amazon.com` | — |
| UK | `read.amazon.co.uk` | `www.amazon.co.uk` | — |
| CA | `read.amazon.ca` | `www.amazon.ca` | — |
| AU | `read.amazon.com.au` | `www.amazon.com.au` | — |
| JP | `read.amazon.co.jp` | `www.amazon.co.jp` | — |
| DE | `lesen.amazon.de` | `www.amazon.de` | `read.amazon.de` |
| FR | `lire.amazon.fr` | `www.amazon.fr` | `read.amazon.fr` |
| IT | `leggi.amazon.it` | `www.amazon.it` | `read.amazon.it` |
| ES | `leer.amazon.es` | `www.amazon.es` | `read.amazon.es` |
| IN | `read.amazon.in` | `www.amazon.in` | — |
| BR | `ler.amazon.com.br` | `www.amazon.com.br` | `read.amazon.com.br` |
| MX | `leer.amazon.com.mx` | `www.amazon.com.mx` | `read.amazon.com.mx` |
| NL | `lezen.amazon.nl` | `www.amazon.nl` | `read.amazon.nl` |

`read.amazon.cn` 只用于历史识别，`entryEnabled=false`。SE/TR/AE/SG/PL/EG/SA 没有可用的 Kindle for Web 入口，不得由零售站域名自行拼接。

### 2.1 统一不变量

```text
bound storefront S
  → https://S.canonical/kindle-library
  → S.marketplace/ap/signin?return_to=https://S.canonical/kindle-library
  → https://S.canonical/kindle-library
  → scan books tagged S
  → https://S.canonical/?asin=...&ref_=kwl_kr_iv_rec_1
  → first audio
```

必须同时满足：

- fresh library 与 fresh reader 只使用 canonical；
- 登录外层域属于当前 marketplace；
- `return_to` 属于当前 canonical；书架流程还必须精确保留 `/kindle-library`；
- reader 必须保留 ASIN 与 `ref_`；
- 只有精确 canonical `/kindle-library` 才能标记 connected 或开始扫描；
- alias、canonical 根路径、跨 marketplace、HTTP、非 443、userinfo、仿冒域全部拒绝；
- 老 `readerURL`、`lastReadURL` 和 alias 必须在进入 WebView 前 canonicalize。

### 2.2 iOS 当前状态

当前工作区的正确实现位置：

- `CastReader/Models/KindleStorefront.swift`：canonical library/reader、alias 识别、canonical-only navigation、登录回链校验；
- `CastReader/Views/Kindle/KindleLibraryConnectView.swift`：首次加载、刷新、切站和 action/response/didFinish 三层门禁；
- `CastReader/Models/KindleModels.swift`：旧 ASIN/alias 修复；
- `CastReader/Services/KindleLibraryStore.swift`：缓存加载时修复 reader/lastRead URL；
- `CastReader/Views/Kindle/KindleBookView.swift`：打开书与过期会话恢复使用 effective canonical URL；
- `CastReaderTests/KindleStorefrontTests.swift`：13 canonical、7 alias、return_to 和安全负例。

发布前必须运行：

```bash
cd /Users/xuxuheng/Documents/CastReader
node docs/contracts/test-kindle-storefront-contract.mjs \
  --android-root ../CastReader-Android
node docs/contracts/test-kindle-live-route-policy.mjs
```

当前离线结果为：14 条目录记录、21 个可识别 host、13 个入口，canonical/alias、nested `return_to`、ASIN/ref 和安全负例通过。该结果是 L1/L2 合同验证，不替代对应 marketplace 真实账号的 L3 登录、同步、开书和首次出声。

## 3. 为什么 Cookie 弹框会在 CastReader 中关不掉

Kindle 分页阅读为了隐藏 Amazon 原生 chrome，会创建比手机可见区域更大的 WebView，再由原生容器裁切到阅读内容。Amazon 的 Cookie Notice 是固定在完整 WebView 底部或右上角的原生层，因此关闭 X 可能落在裁切区域之外。用户看到的是弹框正文，却触达不到真正的关闭控件。

解决目标不是修改 Amazon Cookie，而是：

1. 安全识别 Amazon 自己的 Cookie Notice；
2. 能唯一确认“仅关闭、不做选择”的 X 时，最多尝试关闭一次；
3. 不能确认时临时展示完整 WebView，让用户操作 Amazon 原生 UI；
4. Notice 消失后只恢复一次正常阅读裁切，不 reload、不换页、不捕获弹框正文。

## 4. Android 当前 v3 机制

实现位置：

- `CastReader-Android/app/src/main/java/com/same/castreader/kindle/KindleWebScripts.kt`：event-driven Cookie automation；
- `CastReader-Android/app/src/main/java/com/same/castreader/ui/screens/kindle/KindleViewModel.kt`：bridge 状态、日志和 viewport policy；
- `CastReader-Android/app/src/main/java/com/same/castreader/ui/screens/kindle/KindleScreens.kt`：document-start 注入与 Identity/正常 crop 切换；
- `CastReader-Android/app/src/test/java/com/same/castreader/KindleCookieConsentContractTest.kt`：静态合同测试。

当前行为：

- 仅顶层 document、HTTPS、空端口或 443、13 个 enabled canonical host；
- 通过相关 DOM mutation 触发，不使用 `setInterval`、无限循环或持续轮询；
- 遍历 open Shadow DOM，识别 `ion-modal`、`ion-overlay`、`#sp-cc` 和本地化 Cookie 语义；
- 只有一个明确 close 候选时，先写 `attemptedClose=true`，再执行唯一一次 click；
- 不点击 Accept/Reject/Manage，不刷新页面；
- 单次 900ms follow-up 验证；仍可见或候选不唯一时上报 native；
- native 将阅读 crop 临时切为 Identity，弹框消失后恢复正常 crop；
- 日志只记录 visible、attempted、枚举 decision，不记录 Cookie、账号或弹框全文。

### 4.1 Android 当前已知风险，iOS 不得照抄

1. 当前候选集合仍可能包含 `<a role="button">`、submit、带 close class 的链接或 `ion-icon`；字符串测试不足以证明运行时绝不会误点。
2. 脚本当前会先上报 visible，再尝试 X。即使 X 很快成功，也会产生“正常 crop → Identity → 正常 crop”两次尺寸变化。
3. Notice 可见期间，Android 现有 layout repair、OCR 捕获、翻页和播放没有统一暂停门禁，可能重新分页或捕获到弹框。
4. native bridge 只检查 reader screen visible，尚未完整验证当前 WebView、canonical URL、storefront 与 document/runtime token；旧 document 的迟到消息有污染新页面的理论风险。
5. 当前测试主要检查脚本文本，没有执行真实 DOM/Shadow DOM 交互矩阵。

## 5. iOS Agent 实施合同

### 5.1 MUST

- 只在 paged Kindle reader WebView 的 top frame 运行；message handler 同时校验 `frameInfo.isMainFrame`。
- 只允许 13 个 enabled canonical host；alias 与 CN 不运行 Cookie automation。
- URL 必须是 HTTPS，端口为空或 443，且 storefront 与当前书一致。
- 递归发现所有 open Shadow DOM，并观察后续新增 shadow root。
- 必须同时确认 Amazon/Cookie Notice 语义与 modal/overlay/固定层结构，不能只凭正文出现 `cookie`。
- close 候选必须唯一、可见、可交互、enabled，并且是实际按钮宿主；icon 本身不能直接点击。
- 自动 close 前先持久化 document-scoped attempted 标记，每个 document 最多一次。
- 自动 close 后只做一次短 follow-up；确认仍可见时才请求 native 切 Identity，避免成功关闭也触发两次分页。
- 无法安全确认时退化为完整 viewport + 用户手动处理。
- bridge payload 包含 document/runtime token、storefront id、visible、autoCloseAttempted、枚举 decision。
- native 验证当前 reader、当前 WKWebView、canonical URL、storefront 与 document token；迟到消息丢弃。
- Notice 手动处理期间暂停 layout repair、页面捕获、OCR、自动翻页和新 TTS 准备。
- Notice 消失后只恢复一次正常 crop，等待 viewport 稳定，再恢复 overlay/capture；不得 reload。
- navigation start、reader hidden、destroy、renderer replacement 时清除 Notice 状态。
- 日志只记录 storefront、状态与枚举 decision。

### 5.2 MUST NOT

- 不得点击 Accept、Allow、Agree、OK、Reject、Decline、Manage、Settings、Customize。
- 不得点击 `<a>`、任何含 `href` 的元素、submit 控件或仅凭 `[role=button]` 命中的元素。
- 不得直接点击 `ion-icon`；必须找到并验证受约束的按钮宿主。
- 不得删除、隐藏、移动或改写 Amazon DOM，也不得创建 CastReader 自己的伪 Cookie 按钮。
- 不得刷新页面，不得使用持续轮询，不得失败后重复自动点击。
- 不得记录完整 URL/query、ASIN、Cookie、账号或弹框全文。

### 5.3 必测矩阵

- 13 canonical 全通过；7 alias、CN、HTTP、非 443、iframe 全拒绝。
- light DOM `#sp-cc`。
- 一层和多层 Shadow DOM 的 `ion-modal` / `ion-overlay`。
- 唯一 X：恰好点击一次。
- Accept/Reject 与 X 共存：只点击 X；没有 X：零点击并进入手动模式。
- 两个 X：零点击并进入手动模式。
- `<a class=close>`、`<a role=button>`、submit：零点击。
- disabled、inert、hidden、`pointer-events:none`：零点击。
- 重复安装与重复 mutation：仍最多一次。
- 旧 document/WKWebView 迟到消息：native 忽略。
- Notice 可见期间：零 layout repair、零 OCR、零自动翻页。
- Notice 消失：只恢复一次 crop，不 reload，当前页不变。

## 6. 发布口径

- 可以说“当前工作区已覆盖 13 个 canonical 和意大利站点修复”。
- 在 iOS 改动提交并进入实际 archive 前，不得说“线上 iOS 已修复”。
- 13 个站点完成匿名 L1/L2 不等于 13 个真实账号 L3；发布记录必须分开填写。
- Cookie automation 必须在真实 Amazon 页面至少完成 IT 一次真机复现；测试 fixture 不能替代现场验收。
