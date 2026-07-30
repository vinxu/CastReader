# CastReader iOS 1.2.15 发布准备审查

审查日期：2026-07-30
版本：`1.2.15 (28)`

## 结论

本轮 Kindle 多站点、Google Play Books、Kobo、书架入口、播放器以及相关体验改动已经完成工程整合、自动化测试和无签名 Release 构建验证。

当前状态是：

- **功能与工程层面：已具备候选版本条件。**
- **App Store 提交层面：尚不可直接提交。**

提交审核前必须先解决“App 内发起账号删除”这一 P0 合规阻断，并同步确认 App Store Connect 隐私标签、Build 号和正式签名归档。

## 本轮整合范围

- Kindle 多语言、多区域 Storefront。
- Google Play Books 绑定、书架、朗读、解读与翻页。
- Kobo 绑定、书架、朗读、解读与翻页。
- 商业阅读平台统一入口与绑定来源管理。
- 商业阅读平台共享的持久 Web 登录数据。
- 统一播放器、翻页按钮、封面、锁屏信息和加载状态。
- 九种 App 语言的新增文案。
- 浅色和深色模式。
- TTS、文档、上传链路的 HTTPS 收口。
- Safari Extension 资源重新构建与内嵌。

## Kindle 多站点验证

### Storefront 合同

当前支持 13 个可选择的 Kindle for Web 入口：

| 地区 | 入口 |
|---|---|
| 美国 | `read.amazon.com` |
| 英国 | `read.amazon.co.uk` |
| 加拿大 | `read.amazon.ca` |
| 澳大利亚 | `read.amazon.com.au` |
| 日本 | `read.amazon.co.jp` |
| 德国 | `lesen.amazon.de` |
| 法国 | `lire.amazon.fr` |
| 意大利 | `leggi.amazon.it` |
| 西班牙 | `leer.amazon.es` |
| 印度 | `read.amazon.in` |
| 巴西 | `ler.amazon.com.br` |
| 墨西哥 | `leer.amazon.com.mx` |
| 荷兰 | `lezen.amazon.nl` |

中国站 `read.amazon.cn` 仅保留历史 Host 识别，不作为可选入口。

连同旧入口别名，共识别 21 个 Host。iOS Storefront 模型、合同 JSON、Swift 测试和 Safari Extension `host_permissions` 使用同一套数据。

本轮已经核对任务 `019fb0f2-1334-7bf1-bacb-24d14ff2d840` 的完整实现记录，并整合了其中的 Storefront 一等模型、用户显式选站、旧数据迁移、单站书架隔离、运行时域名确认、跨站导航拒绝、登录恢复和多语言 DOM 识别。

原任务早期合同曾按 Amazon Marketplace 域名推测 20 个可入口站点。在线验证后确认，Amazon Marketplace 的存在不等于 Kindle for Web 入口存在，因此没有保留 `read.amazon.sg`、`.se`、`.com.tr`、`.ae`、`.sa`、`.pl`、`.eg` 等未经证实的地址；德、法、意、西、巴西、墨西哥、荷兰则改为 Amazon 实际使用的本地化 Kindle Host，并保留 `read.*` 别名用于兼容。这是对原实现的事实校正，不是遗漏整合。

### 不会固定路由到美国站点的证据

- 用户绑定 Kindle 时会明确选择站点。
- 设备语言和地区只负责排序建议，不会覆盖用户选择。
- 用户选择会持久化。
- WebView 打开的 URL 直接来自已选择 Storefront，而不是固定的美国 URL。
- 若实际导航落到一个已识别的地区 Host，会用该 Host 修正本地绑定。
- 13 个入口的路径和 21 个 Host 均有自动合同测试。

验证脚本：

```bash
node docs/contracts/test-kindle-storefront-contract.mjs
node docs/contracts/verify-kindle-live-routes.mjs
```

合同测试结果：

```text
PASS Kindle storefront contract: 14 storefronts, 21 recognized hosts,
13 entries, 8 non-Chinese language orders
```

### 在线路由验证边界

- 12 个区域站点已从当前环境直接验证 HTTPS、landing 路由和区域内 library 跳转。
- 日本入口是 Amazon 官方 Kindle for Web 入口；当前本机 DNS 将其错误解析到非 Amazon 地址。通过可信 DNS 查询得到其 CloudFront 地址后，以正确 SNI/TLS 请求验证 landing 为 `200`，library 保持日本 Host。
- 自动脚本会把这种 DNS 污染报告为环境失败，不会错误地回退到美国站点。
- 没有对应区域的 Kindle 账号，因此无法宣称已经完成所有区域的登录后书架和付费书籍真人验收。正式发布前建议至少准备日本、德国或西班牙中的一个真实区域账号做补充冒烟测试。

## 多语言与深浅色验收

支持语言：

```text
de, en, es, fr, hi, it, ja, pt-BR, zh-Hans
```

验收结果：

- `Localizable.xcstrings`：618 个 key。
- 9 种语言缺失数：0。
- 格式化占位符和翻译状态检查：通过。
- `InfoPlist.strings` 9 种语言覆盖：通过。
- 9 种语言 × 浅色/深色，共 18 种 UI 组合：通过。
- 书架来源入口、Kindle、Google Play Books、Kobo 的主要操作按钮均纳入 UI 自动化检查。
- Google/Kobo/Kindle WebView 背景使用动态系统背景，降低深色模式下的白屏闪烁。
- 错误色、正文色和小字号链接色已经改为动态主题颜色。

UI 测试结果：

```text
1 test, 0 failures
18 language/appearance combinations passed
```

结果包：

```text
/tmp/CastReader-1.2.15-Tests-Agent/Logs/Test/
Test-CastReader-2026.07.30_19-37-18-+0800.xcresult
```

## 自动化与构建结果

### 通过的测试

- Kindle Storefront：14 项。
- 本地化合同：2 项。
- TTS Endpoint 安全合同：3 项。
- 商业阅读 Web fixture/Kobo：通过。
- 九语言 × 深浅色 UI 矩阵：通过。

合并合同测试结果：

```text
19 tests, 0 failures
```

结果包：

```text
/tmp/CastReader-1.2.15-Tests-Agent/Logs/Test/
Test-CastReader-2026.07.30_19-41-57-+0800.xcresult
```

### 最终缺陷回归

全套运行首次暴露出 3 个失败，逐项确认并处理：

- 预加载测试只检查“仍在缓存”，未覆盖缓存已被立即提升到播放队列的合法状态；测试契约已修正。
- Google Books 底部半行测试把提取器主动裁掉的尾随空白算入正文长度；断言已改为与实际可读文本一致。
- 微信读书测试仍检查旧版仅“下一页”的硬编码实现；现已验证统一的“上一页/下一页”双向翻页契约。

修复后连同 Kindle 中文 OCR 后台线程安全检查，4 项目标回归全部通过：

```text
4 tests, 0 failures
/tmp/CastReader-1.2.15-TargetedFinal/Logs/Test/
Test-CastReader-2026.07.30_19-59-47-+0800.xcresult
```

另行尝试执行“除依赖真实网络的 Eval 外全部单元测试”时，Xcode Test Runner 两次进入
`Waiting for -runningDidFinish` / `waiting for workers to materialize`，无法产出完整结果包。
这是测试基础设施挂起，不能记为通过，也没有形成新的产品断言失败。发布证据以已完成的
19 项发布合同、18 组语言/主题 UI 矩阵、4 项缺陷目标回归和 Release 构建为准；全套
Test Runner 稳定性列为发布前建议继续清理的测试基础设施问题。

### Release 构建

使用 workspace、Release 配置和 generic iOS device 进行无签名构建：

```bash
xcodebuild \
  -workspace CastReader.xcworkspace \
  -scheme CastReader \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath /private/tmp/CastReader-1.2.15-Release-Final \
  build
```

无签名 Release 构建用于证明源码、资源和扩展可以完成生产配置编译；它不能替代正式证书签名、Archive、Validate 和上传检查。

结果：

```text
BUILD SUCCEEDED
/private/tmp/CastReader-1.2.15-Release-Final/Build/Products/Release-iphoneos/CastReader.app
```

最终包体复核确认：

- 主 App：`1.2.15 (28)`。
- Safari Extension：`1.2.15 (28)`。
- Share Extension：`1.2.15 (28)`。
- 三个 bundle 的嵌入二进制校验均通过。
- 无 `NSExceptionDomains`，仅保留 `NSAllowsArbitraryLoadsInWebContent`。
- QuickRead API key 已正确注入 Release 包；审查过程未输出其内容。

## 包体与依赖审查

- App、Safari Extension、Share Extension 均已统一为 `1.2.15 (28)`。
- workspace 只引用主工程，已移除失效的 Pods workspace 引用。
- SwiftSoup 和 ZIPFoundation 的两份 `Package.resolved` 内容一致。
- 两份 `Package.resolved` 当前是未跟踪文件，发布提交时必须纳入版本控制。
- Safari Extension 已从当前源码重新构建。
- Safari Extension 不再引用工作区外部绝对路径。
- Safari Extension 包含 manifest、九语言 `_locales`、content scripts、chunks、Tesseract、inbox 和 Pro paywall 资源。
- Safari Extension 的 21 个 Kindle Host 与 Storefront 合同精确一致。
- 主 App 包含 9 份 `Localizable.strings`、9 份 `InfoPlist.strings` 和 Privacy manifest。
- 显式 Foundation framework 引用已经改为 `SDKROOT`，不再绑定某个本机 iPhoneOS SDK 版本。

## 安全与隐私审查

### 已完成

- 文档、上传和 TTS 默认端点已统一为 HTTPS。
- 旧版远程配置中的 `http://api.castreader.ai:8123` 会被安全迁移到 `https://api.castreader.ai`。
- 其他非 HTTPS 的远程 TTS Endpoint 会被拒绝。
- 已移除 `api.castreader.ai` 的明文 HTTP ATS 例外。
- Release 日志不输出正文、邮箱、Cookie、Token 或认证凭据。
- Privacy manifest 已将 `Other User Content` 标记为可关联，因为登录用户的页面文本可能连同用户标识发送至解读服务。

### 仍需人工确认

- App Store Connect 的 Privacy Nutrition Label 必须将 Other User Content 更新为与本地 Privacy manifest 一致的“Linked to User”。
- `NSAllowsArbitraryLoadsInWebContent` 仍保留，用于用户输入网页和第三方商业阅读 WebView。提交审核资料中应准备说明其业务必要性。

## P0：提交审核前必须解决

### 1. App 内发起删除账号

App 支持 Google 和 Apple 登录并创建账号，但当前只有退出登录，没有可以在 App 内发起账号删除的入口和后端闭环。

Apple 要求支持账号创建的 App 允许用户在 App 内发起账号删除；除受监管等特殊行业外，要求用户发送邮件联系客服通常不足以满足该规则。使用 Sign in with Apple 时还需要处理相关 Token 撤销。

需要完成：

- 后端提供可验证、可追踪的账号删除请求或即时删除 API。
- iOS 设置/账号页增加明确的“删除账号”入口、二次确认和结果状态。
- 删除当前用户的服务端账号及关联数据，或明确进入允许的延迟删除流程。
- Sign in with Apple 用户删除账号时完成 Token 撤销。
- 更新线上隐私政策，不能继续只描述“发邮件申请删除”。
- 增加成功、失败、重复提交、离线和重新登录后的自动化/人工验收。

在后端能力完成前，不应在客户端伪造“删除成功”。

### 2. App Store Connect 隐私标签

把 Other User Content 的关联状态同步为 `Linked to User`，并复核用户 ID、设备 ID、购买信息和诊断数据的申报是否与当前实现一致。

### 3. Build 与正式签名

- 确认 App Store Connect 中 Build `28` 尚未使用。
- 使用 Distribution 签名完成 Archive。
- 执行 Validate App。
- 检查 App、Safari Extension 和 Share Extension 的 provisioning、entitlements 和版本号。

### 4. 从受控提交制作候选版本

当前工作区包含大量本轮以及用户已有的未提交修改和未跟踪资源。发布前必须：

- 审查实际要进入 1.2.15 的文件集合。
- 将两份 `Package.resolved` 和新源文件纳入版本控制。
- 避免把 `AppStoreAssets/` 等非运行时大资源误打入源码提交或 App 包。
- 从一个可追踪、可回滚的干净提交制作最终 Archive。

## P1：建议在提交前完成

- 使用至少一个非美国地区 Kindle 真实账号，验证登录后书架、打开书籍和重新进入时仍保持所选 Storefront。
- 真机覆盖一次日文、德文或西班牙文系统语言的浅色/深色冒烟测试。
- 排查全套 XCTest 中导致 Test Runner 无法回调 `runningDidFinish` 的慢速/系统集成用例，并将真实网络评估与确定性单元测试拆分为独立 Scheme 或 Test Plan。
- 对 WebKit actor、旧版 `onChange`、ZIPFoundation deprecated API 和 `Sendable` 编译警告建立后续清理任务。
- 保存最终 Archive、Validate 日志、测试 xcresult 和 Storefront 在线验证输出。

## 最终发布判定

只有在以下条件全部满足后，才可把状态改为“可以提交审核”：

- [ ] App 内账号删除闭环可用。
- [ ] Sign in with Apple 删除时 Token 撤销可用。
- [ ] 线上隐私政策已更新。
- [ ] App Store Connect 隐私标签已同步。
- [ ] Build 28 可用。
- [ ] 正式签名 Archive 成功。
- [ ] Validate App 通过。
- [ ] 候选版本来自已审查的干净提交。
- [ ] 至少完成一次非美国 Kindle 区域账号冒烟测试，或明确接受该剩余风险。
