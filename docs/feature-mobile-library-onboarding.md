# 移动端书库首次引导

状态：iOS v1 已完成并可测试；Android 等 iOS 产品验收后按本文合同实现。

更新时间：2026-07-27

## 1. 产品目标

移动端首次引导的核心不是介绍全部功能，而是帮助用户尽快完成一次真实的书库朗读：

1. 选择 Kindle 或微信读书。
2. 复用现有登录与书架同步流程完成绑定。
3. 打开一本真实书籍。
4. 累计有效朗读 30 秒。

只有第 4 步完成才算激活。看过引导、点击绑定、同步成功或只打开阅读器都不算完成。

网页、PDF、EPUB、图片和粘贴文本仍完整保留，但只作为“暂时不绑定”的次级入口，不与两个书库入口争夺首次注意力。

## 2. 用户流程

### 首次启动

- 简体中文环境：微信读书在前，Kindle 在后。
- 其他八种语言：Kindle 在前，微信读书在后。
- 用户可选择“暂时不绑定，先读网页或文件”或“稍后再说”。
- 全屏选择页只自动展示一次，不能用手势误关闭。

### 选择书库后

- 已同步书籍：直接打开第一本真实书籍。
- 未同步书籍：进入现有 Kindle/微信读书绑定 WebView。
- 微信读书二维码、登录 UID、Cookie 和后续书架扫描始终由同一个
  `WeReadLibrarySyncViewModel` / `WKWebView` 会话持有，不能重建或 reload。

### 未完成激活

首次选择页关闭后，首页保留一张紧凑的“完成首次朗读”卡片。它根据当前状态显示：

- 绑定 Kindle / 绑定微信读书；
- 已有书时显示“打开一本书”；
- 真实播放进度。

累计有效播放达到 30 秒后，卡片永久消失。

## 3. iOS 实现

### 状态与持久化

实现文件：`CastReader/Models/AppSettings.swift`

`BoundLibraryOnboardingStore` 是 `@MainActor` 单例，保存：

- `selectedSource`：`kindle` / `weread`
- `hasSeenChooser`
- `isActivated`
- `activationPlaybackSeconds`
- `isChooserPresented`（仅运行时展示状态）

UserDefaults 使用版本化键：

- `boundLibraryOnboarding.v1.selectedSource`
- `boundLibraryOnboarding.v1.hasSeenChooser`
- `boundLibraryOnboarding.v1.isActivated`
- `boundLibraryOnboarding.v1.activationPlaybackSeconds`

切换书库来源会清零未完成的播放累计；已激活状态不会被普通重开引导破坏。

### 引导与路由

实现文件：

- `CastReader/Views/MainTabView.swift`
- `CastReader/Views/Home/HomeView.swift`
- `CastReader/Views/Settings/SettingsView.swift`

`MainTabView` 在根层展示 `BoundLibraryOnboardingView`。用户选择后先关闭全屏引导，再通过
`fullScreenCover(onDismiss:)` 执行真实路由，避免依赖固定延时造成 sheet 竞争。

书库入口复用：

- Kindle：`KindlePlaybackCenter` 或 `.castReaderKindleRebindRequested`
- 微信读书：`PlayerCoordinator` 或 `.castReaderWeReadRebindRequested`
- 网页/文件：现有 `ImportRouter.openQuickImport()`

设置页“数据”中可重新打开引导；Debug 构建还可完整重置首次状态。

### 30 秒有效播放

实现文件：

- `CastReader/ViewModels/ReadAloudViewModel.swift`
- `CastReader/Models/AppSettings.swift`

播放器每次时间更新都把原始正向 delta 交给共享 store：

- 只接受 Kindle / 微信读书来源；
- 只累计当前选择的书库；
- 单次 delta 大于 2.01 秒视为拖动或跳转，不累计；
- 暂停、倒退、没有真实音频 segment 时不累计；
- 每跨过 5 秒持久化一次；
- 在共享 store 中跨 `ReadAloudViewModel` 累计，因此 Kindle 第 1 页 12 秒 +
  第 2 页 18 秒可以正确完成激活；
- 达到 30 秒后立即持久化完成状态。

原有产品分析时长仍保留 2 秒 cap；引导激活使用未截断 delta，避免连续拖动进度条伪造 30 秒。

### 数据分析

没有新增事件类型或修改跨端 schema。继续使用：

- `content_intent`
- `content_ready`
- `read_start`
- `read_first_audio`
- `read_milestone`

真实书籍会话使用 `entry_point=library_onboarding`。选择书库本身不创建孤立的
`content_intent`，避免生成永远没有 `content_ready` 的假漏斗会话。

### 本地化

实现文件：`CastReader/Localizable.xcstrings`

覆盖九种正式语言：

- `zh-Hans`
- `en`
- `ja`
- `es`
- `fr`
- `de`
- `pt-BR`
- `it`
- `hi`

## 4. 测试入口

### 启动参数

- `-CastReaderResetLibraryOnboarding`：清空 v1 状态并展示首次引导。
- `-CastReaderSkipLibraryOnboarding`：仅在自动化旧用例中跳过引导。
- `-CastReaderForceLibraryOnboardingRebind`：Debug/UI Test 强制进入绑定页，不清空真实书架。

### 手工验收

1. 中文启动，确认微信读书在 Kindle 前。
2. 分别点击两个书库，确认进入现有真实绑定 WebView。
3. 登录并同步一本书，打开后朗读少于 30 秒，回首页确认提醒仍在。
4. 跨页累计朗读到 30 秒，确认提醒消失且重启后不再出现。
5. 拖动播放进度条，不应增加激活进度。
6. 点击“暂时不绑定”，确认直接打开现有快速导入。
7. 在设置页重新打开；Debug 下使用“重置书库首次引导”反复测试。

### 已完成自动化

- 最终 Debug 模拟器构建成功。
- 3 条状态/累计/防跳转单元测试通过。
- 1 条九语言目录完整性测试通过。
- 6 条相关 UI 测试通过：
  - 首次引导四个入口可见；
  - 网页/文件进入现有快速导入；
  - Kindle 进入现有绑定 WebView；
  - 微信读书进入现有绑定 WebView；
  - 设置页关闭后可稳定重开书库引导；
  - 九种语言均可独立启动。
- 微信读书 JS 合同、iOS/Android analytics 合同、Share Extension 合同通过。

全量测试曾运行到项目原有 StoreKit 模拟购买用例时因系统购买会话挂起而人工停止；停止前
`CastReaderTests` 44 条、EPUB 2 条、Eval 17 条、Localization 40 条均为 0 失败。
本功能相关用例随后已全部隔离重跑并通过。

## 5. Android 实施合同

Android 不重新设计产品流程，必须与 iOS 保持同一状态机和完成口径：

1. 根导航首次展示一次全屏书库选择。
2. 中文微信读书优先，其他语言 Kindle 优先。
3. 直接复用现有绑定、书架和真实阅读器。
4. 全屏页关闭后以首页卡片持续推动未完成用户。
5. 共享仓库累计真实播放 delta，跨页、跨 reader/ViewModel 保留。
6. 大跨度 seek、暂停、倒退不计入 30 秒。
7. 沿用现有 analytics 事件，只给真实书籍会话标记 `library_onboarding`。
8. 九语资源与 iOS key 的语义一致。

### Android 文件级实施映射

Android 仓库：`/Users/xuxuheng/Documents/CastReader-Android`

#### A. 状态层

新建：

- `app/src/main/java/com/same/castreader/data/local/BoundLibraryOnboardingStore.kt`
- `app/src/main/java/com/same/castreader/data/local/BoundLibraryOnboardingPolicy.kt`

通过 `di/AppModule.kt` 已有的全局 `settings` DataStore 持久化，写法参考
`data/local/SettingsRepository.kt`。状态与 iOS 一致：

- `selectedSource: KINDLE | WEREAD | null`
- `hasSeenChooser`
- `isActivated`
- `activationPlaybackSeconds`
- 仅运行时的 `isChooserPresented`

key 使用 `bound_library_onboarding_v1_*`。切换来源清零未完成累计；每新增 5 秒持久化；
30 秒完成后永久保持。首次选择或“稍后再说”后不再自动弹全屏，但首页提醒继续显示。
DataStore 第一次读取完成前必须有 `initialized` 门槛，避免已完成用户启动时闪现引导。

#### B. 全屏引导与真实路由

新建：

- `app/src/main/java/com/same/castreader/ui/screens/onboarding/BoundLibraryOnboardingScreen.kt`

接入：

- `ui/navigation/CastReaderNavHost.kt`
- Kindle 现有绑定/书架路由：`Route.KindleConnect` 及 Kindle library 分支
- 微信读书现有绑定/书架路由：`Route.WeRead` / `Route.WeReadLibrary`

在 `NavHost` 外层展示不可系统返回、不可点击外部关闭的全屏 `Dialog`，不新增一套登录页面。
中文把微信读书放前面，其他语言把 Kindle 放前面：

- 已有 Kindle 书籍：调用现有 `openKindleBook(...)` 打开最近/第一本真实书；
- 没有 Kindle 书籍：进入 `Route.KindleConnect`；
- 已有微信读书书籍：调用现有 `openWeReadBook(...)`；
- 没有微信读书书籍：进入 `Route.WeRead`；
- “暂时不绑定”：调用现有 `onShowImportSheet`。

需要让 `WeReadViewModel` 只读暴露现有 `shelfStore.books`，供根导航判断书架状态。

Kindle 已有链路可直接复用：

- `ui/screens/kindle/KindleScreens.kt`
- `data/local/KindleLibraryStore.kt`

微信读书同步成功目前只执行 `onBack()`。在
`ui/screens/weread/WeReadReaderScreen.kt`、`WeReadViewModel.kt` 与根导航增加
`onShelfSynced`，同步后进入 `Route.WeReadLibrary`，让用户立即选择真实书籍。

必须继续复用 `weread/WeReadSessionOwner.kt` 持有的单一 WebView 会话。引导不能另建
WebView，也不能在二维码、登录和书架扫描之间 reload，否则 Cookie/document 会话会丢失。

#### C. 首页提醒与设置重开

新建：

- `app/src/main/java/com/same/castreader/ui/components/BoundLibraryActivationCard.kt`

接入：

- `ui/screens/home/HomeScreen.kt`：放在顶部标题后、剪贴板卡片前；
- `ui/screens/settings/SettingsScreen.kt` 的数据区；
- `ui/screens/settings/SettingsViewModel.kt`。

首页卡片仅在 `hasSeenChooser && !isActivated` 时显示，包含 30 秒进度。未选来源时重开
选择器，未绑定时进入对应绑定，已有书架时直接打开最近一本书。设置发布版提供
“重新打开书库引导”，Debug 版额外提供完整 reset。

#### D. 真实播放 30 秒累计

唯一推荐接入点：

- `player/manager/AudioPlayerManager.kt` 的 `updatePlaybackPosition()`
- 来源读取：`player/manager/PlayerCoordinator.kt` 的 `sessionRoute`

不要分别在 Kindle/微信读书 ViewModel 计时，否则两个订阅者可能重复累计。规则：

1. 仅 `player.isPlaying`；
2. 仅普通朗读，`analyticsExplainBlockNumber == null`，防止“解读”音频计入；
3. `kindle_book/*` 只归 Kindle，`weread_book/*` 只归微信读书；
4. 使用 `(segmentId, currentPosition)` 计算正向音频时间差；
5. `delta <= 0`、切 segment 或切来源只重设锚点；
6. `delta > 2010ms` 视为 seek/调度跳跃，不累计；
7. 合法 delta 交给全局 `BoundLibraryOnboardingStore`。

累计存于全局 store，不随 Kindle/微信读书翻页和 reader session 重建而清零，所以
12 秒 + 下一页 18 秒仍能完成。倍速播放按实际音频内容时长累计。

#### E. Analytics

继续沿用 `analytics/AnalyticsContract.kt`、`ProductAnalytics.kt` 与
`ContentAnalyticsCoordinator.kt` 的既有事件，不扩 schema。

- Kindle：在 `KindleViewModel` 的 `contentAnalytics.begin/ready` 中，将待激活同来源的
  `entryPoint` 标为 `library_onboarding`；
- 微信读书：在 `WeReadViewModel.openBook()` 和首个稳定 reader snapshot 提交处补齐
  `begin/ready`；
- 只有真实开书才创建 `content_intent`，选择来源不创建孤立会话；
- 微信读书本轮继续沿用合同中的 `URL + WEB`，不要单独新增 `WEREAD` 枚举。

#### F. 九语资源

修改：

- `values/strings.xml`
- `values-zh/strings.xml`
- `values-ja/strings.xml`
- `values-es/strings.xml`
- `values-fr/strings.xml`
- `values-de/strings.xml`
- `values-pt-rBR/strings.xml`
- `values-it/strings.xml`
- `values-hi/strings.xml`

新增 `library_onboarding_*` 标题、副标题、隐私、稍后再说、提醒、重开与 reset 文案。
现有 `LocalizationContractTest.kt` 必须继续验证九语 key 和占位符完整。

#### G. 测试与验收门槛

新增：

- `app/src/test/java/com/same/castreader/BoundLibraryOnboardingPolicyTest.kt`
- `app/src/androidTest/java/com/same/castreader/BoundLibraryOnboardingTest.kt`

单测至少覆盖：只自动展示一次、稍后再说仍提醒、跨页 12+18 秒、来源不匹配、20 秒
seek 拒绝、换来源清零、重启后保持完成。UI 测试覆盖 Kindle、微信读书、其他内容、
稍后再说和首页提醒。

验证命令：

```bash
./gradlew testDebugUnitTest
./gradlew connectedDebugAndroidTest
./gradlew lintDebug
./gradlew assembleDebug
```

`verify_mobile_analytics_contract.rb` 必须继续通过；发布前至少各做一次 Kindle 和微信读书
真账号登录、同步、开书和跨页朗读 30 秒验收。

### Android 主要风险

- Kindle“解读”或其他来源音频误算进 30 秒；
- 以单页 `read_milestone(30)` 代替共享累计，导致短页用户永远无法激活；
- 微信读书另建第二个 WebView，造成二维码登录会话丢失；
- DataStore 尚未初始化就展示选择器；
- 为本功能单独扩展微信读书 analytics 枚举，破坏跨端合同。

## 6. 关键边界

- 不保存用户密码或整本正文。
- 不清除或迁移现有已绑定书库数据。
- 不把安装、看完页面或点击按钮当成激活。
- 不因引导改动重新实现 Kindle/微信读书登录。
- 真账号二维码/验证码、书架内容和跨页朗读仍需要账号持有者做最终人工验收。
