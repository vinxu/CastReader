# Kobo 多页同步交接说明

更新：2026-09-06。来源：Dulce 反馈 iPhone 上 Kobo 书架分为四页，CastReader 只同步第一页。

**当前状态：本地完整链路验证已完成。** 当前代码包含账号边界保护；真实两本完整 UI 用时 **138.461 秒**通过首页绑定／同步、逐本正文与翻页、重启回读，两本各自动重载一次，没有点击重试。100 本四页完整 UI 用时 **83.073 秒**通过。相关 79 项单元／DOM 测试已跨轮次通过，包含 6 项首次阅读恢复测试。首次正文仍需约 **40–50 秒**等待和自动恢复，本次未发布 App Store。

## 问题原因与修复

| 问题 | 原因 | 当前修复 |
|---|---|---|
| 只捕获第一页 | 旧 JS 只滚动当前 DOM；原生连续四次、间隔 350ms 数量稳定便允许完整提交 | 显式识别并点击分页，等待目标页就绪，累计所有页；末页稳定且遍历证据完整才允许 Sync |
| 重复同步可能丢失已有书籍与进度 | Store 把错误的“完整快照”用于替换同账号书架 | 中断、超时、重复页面及无法证明完整的扫描不能提交完整快照，保留旧书架和阅读锚点 |
| 已登录仍被识别为未登录 | 真实移动端账号菜单折叠，节点存在但不可见 | 结合 `DynamicConfiguration.user.isLoggedIn` 与 `body.Store-Library #library-grid .library-items`；可见认证表单、明确未登录状态优先否决残留书卡 |
| 两本书却被识别为 24 页 | “Show: 24”每页数量筛选器被当作页码 | 排除 `.pagination-filter-container`、`.pagination-controls.filter-chip`、`#pagination-option`，保留真正的页码和 Next |
| 官方书架可见却等待超时 | DOM 约 3 秒就绪，其他资源使 `WKWebView.isLoading` 持续约 40 秒 | 要求当前导航已 commit 到可信书架，随后以 DOM 认证／就绪证据启动扫描，不等待无关资源全部完成 |
| 原生显示同步成功，但没有落盘 | 早期 DEBUG 授权 host 未激活 metadata scope | Store 拒绝无活动 scope 的提交；测试入口激活 metadata 边界，验收包含进程重启后的读取 |
| 测试没有覆盖真实产品入口 | 旧 DEBUG host 只挂载独立 `KoboLibraryView`，没有首页的 player／reader 层 | 移除旧 host，`-CastReaderKoboHomeValidation` 进入正式 `MainTabView`，从首页完成绑定、同步与阅读 |

Kindle 的 `ad8dfa7` 修复处理的是滚动懒加载。此次复用其等待稳定、验证完整性和失败保留旧数据的原则，并额外验证 Kobo 的显式翻页确实到达；仅增加等待时间不能补齐后续页面。

账号身份不能来自 `Sign out`、`My Account` 等通用文字。书架缺少稳定身份时，仅通过页面已有的同源 `account/settings` 链接执行只读 GET，验证响应目标，并从官方账号设置页指定邮箱字段计算规范化 SHA-256。原生只接收哈希与域名标签，提交前重新核对身份；邮箱原文、认证表单值、Cookie 和 token 不进入同步结果或日志。

扫描 VM 捕获 Store 的存储边界 UUID，每次异步返回及提交前校验；换账号、登出及 A → B → A 均使旧任务失效。Store 写入前再次校验。首次阅读空正文的一次自动恢复另有 `AccountContentIsolation` 校验，详见[登录与阅读恢复说明](/Users/xuxuheng/Documents/CastReader/docs/kobo-login-audit-20260905.md)。

## 正式链路与测试隔离

正式路径为：`MainTabView → HomeView/KoboHomeSection → KoboReaderLauncher → PlayerCoordinator → ReaderHostView/WebReaderView`。验收必须从首页绑定入口进入，同步后返回首页，再点击每本真实书籍打开阅读器；独立原生书架的数量和持久化只能作为辅助证据。

`-CastReaderKoboHomeValidation` 仅在 DEBUG 提供入口。`AuthService` 为该入口激活测试 metadata 边界，保留用户原先授权的 Cookie jar；原 `-CastReaderSkipSignInGate` 单独使用时的行为不变，Release 不包含新增验证入口。

100 本 fixture 使用 `KoboLibraryStore.shared` 串联连接页、首页和列表，但该 shared store 在 fixture 参数下使用独立 suite `castreader.kobo.hundred-shelf-fixture.v1`，不覆盖真实两本书的 metadata。初次启动可指定 `-CastReaderResetKoboHundredFixture`；重启验证时移除此参数。

## 三种证据的范围

| 场景 | 已确认的证据 | 证明范围与限制 |
|---|---|---|
| 修复前 20 → 修复后 77 | 同一四页样本，每页 20 本，ID 分别为 1…20、20…39、39…58、58…77；翻页延迟 1.2 秒。旧版停第一页并允许同步 20 本，新版扫描及提交去重后 77 本 | 复现原故障及证明跨页去重；不是线上账号验证 |
| 真实账号 2 本 | 官方 `/sg/en/library/books`，`Two Tickets` 与 `Falls From Grace`；两本均有作者与封面。当前版本完整 UI 138.461 秒通过原生同步、首页展示、两本各自动重载一次后提交 3 段实际正文、Next 后不同 `bodyHash`（第一本 4 段、第二本 3 段），及重启首页仍有 2 本；无 `user-retry` | 证明实际授权会话、账号边界保护后的正式阅读链路和持久化；不证明真实四页账号，首次加载仍需约 40–50 秒 |
| 合成 100 本／4 页 | 每页 25 本，延迟 1.2 秒，包含真实移动端容器、折叠菜单和每页数量筛选器。完整 UI 用时 83.073 秒通过 Found 100 → Synced 100 → 首页 → View All → 搜索 1／25／26／50／51／75／76／100 → 重启后来源仍为 Synced 100 | 证明更大书架完整同步、列表接入与持久化；合成数据不含正文，不能证明这 100 本在真实 Kobo 阅读器中可读 |

100 本独立落盘回读同时确认 `exactUUIDSet1..100=true`、`allTitlesCorrect=true` 和 `allAuthorsCorrect=true`。首页最多展示最近 8 本；验证总量须进入 View All 并核对各页边界书籍，不能以虚拟化列表当前的行数判断总书数。View All 已补 `.accessibilityElement(children: .contain)`，列表搜索使用 `.navigationBarDrawer(displayMode: .always)`，并为 Mini Player 预留空间。

## 复现命令

使用已编译的 Debug App，默认模拟器为 iPhone 17 Pro，UDID `6A08602F-01D6-4B70-979D-5A5028E894E6`：

```bash
./scripts/launch-kobo-shelf-fixture.sh baseline
./scripts/launch-kobo-shelf-fixture.sh fixed
./scripts/launch-kobo-shelf-fixture.sh hundred
./scripts/launch-kobo-shelf-fixture.sh home
```

`baseline`／`fixed` 对比 77 本样本；`hundred` 从正式首页运行隔离的 100 本样本；`home` 复用已授权会话进入真实首页。第二个参数为模拟器 UDID，第三个为已编译的 `CastReader.app` 绝对路径。脚本覆盖安装和启动，不卸载应用或抹掉模拟器。

默认构建目录为 `/tmp/castreader-kobo-baseline-build` 与 `/tmp/castreader-kobo-fixed-build`。基线工作树 `/tmp/castreader-kobo-repro-20260905` 只加入相同展示入口、HTML 与隔离存储，保留旧扫描逻辑。若本地产物不存在，先用 workspace 编译修复版：

```bash
xcodebuild -workspace CastReader.xcworkspace -scheme CastReader \
  -destination 'platform=iOS Simulator,id=6A08602F-01D6-4B70-979D-5A5028E894E6' \
  -derivedDataPath /tmp/castreader-kobo-fixed-build build
```

运行 100 本完整 UI：

```bash
xcodebuild test -workspace CastReader.xcworkspace -scheme CastReader \
  -destination 'platform=iOS Simulator,id=6A08602F-01D6-4B70-979D-5A5028E894E6' \
  -derivedDataPath /tmp/castreader-kobo-fixed-build \
  -only-testing:CastReaderUITests/CastReaderUITests/testKoboHundredBooksBindSyncAndPersistOnHome
```

真实测试 `testKoboAuthorizedLiveShelfSync` 默认跳过；仅在账号主人授权后，为 **XCTest runner 环境**设置 `CASTREADER_KOBO_LIVE_SYNC=1` 与正整数 `CASTREADER_KOBO_LIVE_EXPECTED_BOOKS=2`。可通过 `.xctestrun` 的 `EnvironmentVariables` 设置，不能假定 shell 环境变量会自动传入 runner。测试不填写凭据、不清 Cookie，正文等待包含首次自动恢复预算。

## 验证与证据位置

相关 79 项单元／DOM 回归已跨轮次通过，覆盖 `KoboContractTests`、`KoboBindingFlowContractTests`、`KoboBindingPageWebTests`、`KoboShelfScanPolicyTests` 与 `KoboLibraryScanWebTests`。其中包括跨页重复、慢速加载、无效翻页、中断保留旧进度、账号身份和存储边界，以及 6 项首次阅读恢复合同；该数字不是同一轮执行 79 项的声明。

- [报告与截图索引](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/README.md)
- [同步验证结构化记录](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/live-sync-validation.json)
- [100 本验收日志](/tmp/castreader-kobo-100-acceptance.log)与 [09:15:01 xcresult](/Users/xuxuheng/Library/Developer/Xcode/DerivedData/CastReader-ebjfckwmeppjgicvbvqbtrpwfgqv/Logs/Test/Test-CastReader-2026.09.06_09-15-01-+0800.xcresult)
- [真实阅读验收日志](/tmp/castreader-kobo-live-acceptance.log)、[脱敏 reader 日志](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/live-reader-acceptance.log)与 [09:17:00 xcresult](/Users/xuxuheng/Library/Developer/Xcode/DerivedData/CastReader-btnekmzfsbnjwwbbcobaifcrwuhv/Logs/Test/Test-CastReader-2026.09.06_09-17-00-+0800.xcresult)
- [100 本独立持久化核验](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/hundred-persistence-validation.json)
- [修复前截图](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/baseline-simulator.png)、[77 本提交截图](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/four-page-77-synced-final.png)
- [真实首页](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/kobo-live-home-after-sync.png)、[真实第二本正文](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/kobo-live-book-2-readable.png)
- [验收后中文正式首页，保留真实两本](/Users/xuxuheng/Documents/CastReader/reports/kobo-shelf-sync-20260905/kobo-final-home-zh.png)

**本地完整链路验证已完成，首次正文约 40–50 秒的加载与自动恢复等待仍然存在。** 三种证据分别证明旧故障修复、真实两本阅读链路和更大书架完整同步；未直接访问或验收 Dulce 本人的四页账号，也未覆盖所有身份提供方授权链或发布 App Store。
