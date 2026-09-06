# Kobo 登录与首次阅读恢复交接说明

更新：2026-09-06。用户在验证四页书架漏书时，进一步报告真实登录白屏、原生底卡遮挡，以及进入书籍后正文为空。

**当前状态：本地完整链路验证已完成。** 登录表单、空白页重试与弹窗三条 UI 回归已通过。当前代码包含账号边界保护；真实两本完整 UI 用时 **138.461 秒**通过，两本各自动重载一次后获得正文并翻页，没有点击重试。100 本四页完整 UI 用时 **83.073 秒**通过。首次正文仍需约 **40–50 秒**等待和自动恢复，不能描述为无延迟；本次未发布 App Store。

## 问题原因

| 现象 | 已确认原因 |
|---|---|
| 登录卡片遮住网页 | 旧 `didFinish` 对认证页也启动书架 probe；前几次失败调用 `presentShelfLoading()` 将认证页标记重置，底卡重新出现。原 `ZStack` 覆盖布局放大了遮挡 |
| 登录窗口白屏后难以返回 | 缺少清晰的返回／重载／关闭弹窗入口；单一导航状态不能准确区分主窗口、弹窗和迟到回调 |
| 已登录后一直等待书架 | 移动端账号菜单折叠、“Show: 24”误判页数，以及把整页资源加载完成作为扫描前提；这是登录后的扫描阻塞，不能继续记为未登录 |
| 某本书首次打开为空正文 | 现场阅读器一直未提交可读正文，origin 重载后可恢复。原生等待用尽后直接报错，没有先执行一次相同的自动恢复；未据此断言账号 Cookie 已失效 |
| 早期测试通过却不能证明正式阅读 | 独立 DEBUG 书架 host 没有挂载首页的 `PlayerCoordinator` 和 `ReaderHostView` |

不能仅凭视觉白屏推定网络或账号故障。诊断应区分认证表单、已登录书架、等待正文和页面失败，结合导航与 DOM 证据。Kindle 可复用的原则是认证和扫描状态分离、保留官方会话、界面说明不遮挡网页；Kobo 的分页与弹窗仍需各自适配。

## 当前修复

### 登录界面与窗口生命周期

- 独立 `KoboBindingPhase` 管理 opening、awaitingLogin、authenticating、scanning、ready、synced 和 failed；界面由状态派生，书架 probe 不再重置认证页显示状态。
- 可见认证表单优先于 URL、账号菜单和残留书卡。认证或失败时保证网页可交互；WebView 与紧凑底栏上下布局，认证及键盘显示期间隐藏底栏。
- 提供返回、重载和关闭弹窗。每个 WebView 保留自己的当前导航 token；挂起 opener 栈保留嵌套窗口生命周期，只展示活动窗口。旧窗口回调不能覆盖当前状态。
- 原生登录按钮调用官方入口，临时允许该次 JS 创建窗口，取消或导航时复位。合法 `about:blank` 弹窗保留原 configuration 与 opener，供网页写入表单或导航。
- 稳定空白页约 4 秒显示可见重试；HTTP 错误、加载停滞和 Web 内容进程退出有恢复入口。正常连接与重试保留持久 Cookie/profile，不清除共享会话。
- 日志记录脱敏 host/path、导航阶段、HTTP 状态和 JS probe 错误，不输出认证 query、表单值、Cookie 或 token。

真实书架识别、账号设置页哈希、分页及完整快照规则见[多页同步交接说明](/Users/xuxuheng/Documents/CastReader/docs/kobo-shelf-sync-20260905.md)。

### 首次空正文只自动重载一次

`KoboInitialReaderRecoveryPolicy` 接入 `WebReaderBridge` 的初始正文等待超时。尚未提交任何可读页、仍处于绑定书籍的可信 reader URL、应用在前台且账号边界有效时，允许一次延迟 `reloadFromOrigin()`。已授权 WebView 和 Cookie jar 保持不变，仍失败时显示可见重试，不循环重载。

策略使用一次性 ticket：等待期间若正文已经 commit，永久取消这次动作；旧 ticket 不能跨换书、重新配置或 A → B → A 书籍切换复用。延迟返回时再次核对 WebView、书籍 ID／URL、前台状态和正文是否已提交。已进入正常阅读的页面不会因这条“首次打开”策略被刷新。

Bridge 在 configure 时捕获 `AccountContentIsolation` token，首次恢复调度前及延迟返回／报错前重新校验。CastReader 账号切换、登出及 A → B → A 都使旧任务失效；校验到重载或报错之间没有异步间隙。新增 6 项纯策略测试覆盖单次预算、重复空结果、等待期 commit、其他恢复占用、换书／重开及后台取消。

### 正式入口与测试隔离

独立书架 DEBUG host 已移除。`-CastReaderKoboHomeValidation` 进入真实 `MainTabView`，从首页绑定、同步并逐本进入正式 player／reader。`AuthService` 在该 DEBUG 路径激活测试 metadata 边界，保留用户原先授权的 Cookie jar；原 `-CastReaderSkipSignInGate` 单独使用行为不变，Release 不包含新增入口。

100 本 fixture 通过 shared store 串联首页与列表，但使用独立 suite `castreader.kobo.hundred-shelf-fixture.v1`，不覆盖真实两本书的 metadata。登录表单、空白页、弹窗及原 77 本 fixture 使用非持久 WebView／隔离存储。

## 复现与回归命令

在已安装修复版 Debug App 的模拟器上，可直接启动本地登录表单：

```bash
xcrun simctl terminate 6A08602F-01D6-4B70-979D-5A5028E894E6 com.same.castreader
xcrun simctl launch 6A08602F-01D6-4B70-979D-5A5028E894E6 com.same.castreader \
  -CastReaderKoboLoginFixture -AppleLanguages '(en)' -AppleLocale en_US -interfaceLanguage en
```

替换 fixture 参数可验证其他场景：

| 参数 | 检查内容 |
|---|---|
| `-CastReaderKoboLoginFixture` | 合成本地 Email／Password 输入、键盘及 Continue，无网络提交；底卡始终不遮挡 |
| `-CastReaderKoboBlankFixture` | 空白等待结束后可见错误与重载，网页和底栏不重叠 |
| `-CastReaderKoboPopupFixture` | 原生 Sign in → 本地 `about:blank` 表单 → 实际输入 → 关闭 → 返回入口 |

运行这三条 UI 回归：

```bash
xcodebuild test -workspace CastReader.xcworkspace -scheme CastReader \
  -destination 'platform=iOS Simulator,id=6A08602F-01D6-4B70-979D-5A5028E894E6' \
  -derivedDataPath /tmp/castreader-kobo-fixed-build \
  -only-testing:CastReaderUITests/CastReaderUITests/testKoboLoginFixtureKeepsFormUsableWithoutNativeOverlay \
  -only-testing:CastReaderUITests/CastReaderUITests/testKoboBlankFixtureShowsVisibleRetryWithoutCoveringWebView \
  -only-testing:CastReaderUITests/CastReaderUITests/testKoboPopupFixtureKeepsBlankWindowLoginAndCloseUsable
```

真实首页与 100 本样本分别使用 `./scripts/launch-kobo-shelf-fixture.sh home` 和 `./scripts/launch-kobo-shelf-fixture.sh hundred`。真实 UI 默认跳过；只有账号主人授权后，才在 XCTest runner 环境中设置 `CASTREADER_KOBO_LIVE_SYNC=1` 和 `CASTREADER_KOBO_LIVE_EXPECTED_BOOKS=2`，运行 `testKoboAuthorizedLiveShelfSync`。测试不输入真实凭据、不清 Cookie，也不以点击重试替代自动恢复验收。

## 验证范围与交接结果

| 证据 | 已确认范围 |
|---|---|
| 三条本地登录 UI | 延迟 probe 后表单无遮挡、真实触摸与键盘输入、空白错误与重载、弹窗关闭返回均通过 |
| 原基线 20 → 77 | 相同四页样本证明旧版停第一页，新版扫描／去重／提交 77 本；不代表线上授权链 |
| 真实 2 本 | 09:17:00 启动的当前版本完整 UI 用时 138.461 秒通过：正式首页绑定／同步，两本各自动重载一次，分别提交 3 段正文；Next 后第一本 4 段、第二本 3 段，均产生不同正文 hash；重启后首页仍有 2 本，无 `user-retry` |
| 合成 100 本／4 页 | 09:15:01 启动的完整 UI 用时 83.073 秒通过：扫描／Sync／首页／View All／所有页边界书籍搜索／重启来源 Synced 100；独立落盘核对 100 个 UUID 及标题、作者均正确 |
| 79 项单元／DOM | 跨轮次全部通过，包含新增 6 项首次阅读恢复合同；不声明为同一轮运行 |

WebKit 的密码框 `isHittable` 曾为 false，但实际表单可见并能触摸输入；测试采用真实触摸、键盘输入和值校验，未用 JS 填值绕过。SwiftUI 父级 identifier 覆盖子级的问题通过 `.accessibilityElement(children: .contain)` 修正。100 本 View All 搜索已设为始终显示，并为 Mini Player 预留布局空间。

证据入口：

- [报告与截图索引](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/README.md)、[登录回归记录](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/login-validation.json)、[同步验证记录](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/live-sync-validation.json)
- [真实阅读验收日志](/tmp/castreader-kobo-live-acceptance.log)、[脱敏 reader 日志](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/live-reader-acceptance.log)、[09:17:00 xcresult](/Users/xuxuheng/Library/Developer/Xcode/DerivedData/CastReader-btnekmzfsbnjwwbbcobaifcrwuhv/Logs/Test/Test-CastReader-2026.09.06_09-17-00-+0800.xcresult)
- [100 本验收日志](/tmp/castreader-kobo-100-acceptance.log)、[09:15:01 xcresult](/Users/xuxuheng/Library/Developer/Xcode/DerivedData/CastReader-ebjfckwmeppjgicvbvqbtrpwfgqv/Logs/Test/Test-CastReader-2026.09.06_09-15-01-+0800.xcresult)
- [表单输入](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/login-form-input-passed.png)、[空白重试](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/login-blank-retry-passed.png)、[弹窗输入](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/login-popup-input-passed.png)
- [验收后中文正式首页，保留真实两本](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/kobo-final-home-zh.png)

**本地完整链路验证已完成，首次正文约 40–50 秒的加载与自动恢复等待仍然存在。** 当前证据覆盖用户实际使用的授权会话、真实两本与合成分页样本；不覆盖 Dulce 本人的四页账号、所有身份提供方授权链或 App Store 发布。
