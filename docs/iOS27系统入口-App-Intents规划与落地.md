# iOS 27 系统入口 · App Intents 规划与落地

2026-08-07。目标是拿下 9 月「Apps updated for iOS 27」编辑合集曝光，同时把 Siri / Spotlight / 快捷指令 / 灵动按钮 / AI agent 变成 CastReader 的常驻入口。

## 0. 现状盘点（2026-08-07 实测，非推测）

`codex/ios27-system-entry` 分支上系统入口的**主体已完成并编译通过**：

| 组件 | 状态 |
|---|---|
| `CastReaderAppIntents.swift` | ✅ 三个 Intent（Read / Explain / Continue）+ AppShortcutsProvider，橙色磁贴 |
| `SystemIntegrationModels.swift` | ✅ `SystemAction` 枚举、`CastReaderIntentMode`、`ReadingItemEntity` + `EntityQuery`、URL 解析 |
| `SystemIntegrationStores.swift` | ✅ App Group 单槽位 `SystemActionStore`（last-write-wins + 原子取用）、`ContinueSnapshotStore`（读时重套契约、去重、上限 8） |
| `CastReader Widget` target | ✅ 已建、已 embed、`ContinueReadingWidget` + Bundle，19 键本地化 |
| 接线 | ✅ `onOpenURL` → `SystemActionStore.enqueue`；`MainTabView.routePendingSystemActionIfAvailable` 唯一消费者；`HistoryStore:128` 写快照 |
| Siri 短语本地化 | ✅ `AppShortcuts.xcstrings` 九语（AppShortcuts.strings 是短语本地化的唯一通路） |
| 编译 | ✅ 主 App + Widget + 两个扩展全绿 |

架构判断：**设计是对的，不用重做**。系统入口只投递一个命令，App 变为 active 后由 `MainTabView`（同时持有 PlayerCoordinator 与导入 UI 的唯一位置）负责文档解析、额度检查与播放副作用——这条边界让扩展进程不碰业务状态，是正确的。

## 1. 三个真实缺口

### 缺口 A · 没有 iOS 27 SDK（硬阻塞，需你操作）

```
Xcode 26.6 (17F113) — 仅 iOS 26.5 SDK
```

**「为 iOS 27 更新」的合集资格来自用 iOS 27 SDK 构建**，光有 App Intents 不算。同时 App Intents 2.0 的 iOS 27 独有能力（流式响应、多轮追问、屏幕感知）需要新 SDK 才能编译。

→ **必须安装 Xcode 27（beta 或正式版）**，这是唯一的外部依赖，也是整条排期的关键路径。

### 缺口 B · 零测试覆盖

`SystemIntegration/` 是**契约密集型**模块（跨进程 App Group、单槽位竞态、来源过滤契约、URL 解析），当前测试为 0。按本仓库惯例（WeRead 契约测试、Kindle storefront 真值表），这类模块必须有契约测试。

### 缺口 C · 归因不可度量

`appSessionStart.launchType` 目前只有 `cold` / `foreground_after_30m`。**Siri / Widget / 快捷指令拉起的会话无法与自然启动区分**——我们要争取的正是这波系统入口曝光，却没有量尺。

## 2. iOS 27 独有能力的取舍（拿到 SDK 后）

编辑要的是「有意义地采用招牌能力」，不是重编一遍。按对 TTS 产品的自然度排序：

| 能力 | 用法 | 优先级 |
|---|---|---|
| **流式响应**（App Intents 2.0） | 「正在为你朗读《书名》…」——长任务的进度回传，Siri 不再是黑盒等待 | **P0**，最自然、最好演示 |
| **多轮追问** | 「读哪一本？」→ 用户答书名 → 直接开播（复用 `ReadingItemEntity` 查询） | P1 |
| 屏幕感知 | 「读第三个」解析当前可见列表 | P2，收益小于成本 |

纪律：**部署目标保持 17.6 不动**，iOS 27 能力一律 `if #available(iOS 27, *)` 门控——全体用户可用，合集资格也真实。

## 3. 排期（倒推自 9 月发布日）

| 时间 | 事项 | 阻塞 |
|---|---|---|
| 现在 | 缺口 B + C（测试 + 归因埋点） | 无，立即做 |
| 你操作 | **装 Xcode 27** | 关键路径 |
| 8 月中 | iOS 27 SDK 构建 + 流式响应 | 需 Xcode 27 |
| ~~8 月 25 日前~~ **已于 8-07 提交** | 第 4 份 featuring 提名 `cd612946-514a-4418-b64f-f7366ce57b0e`，`SUBMITTED`，窗口 **2026-09-14 → 09-28**（iOS 27 发布档，且不与返校季 8/18–9/15、无障碍 9/29–10/31 撞车）。**API 三个坑**：无 `relatedTerritories` 关系、必须带 `submitted: true`、**name ≤60 / description ≤1000 字符** | — |
| 9 月发布日 | **day-one 提交适配版本**——这是合集入场券，晚一周就出池子 | — |

## 4. 验收标准

- 真机：「嘿 Siri，用 CastReader 继续听」→ 直接续播最近内容；锁屏 widget 点击直达；快捷指令可配置参数；灵动按钮可绑定
- 九语：切换系统语言后 Siri 短语与 widget 文案随之切换
- 归因：Siri/Widget 拉起的会话在埋点里可区分，能算出系统入口带来的会话占比
- 契约测试全绿（见下）

## 5. 本轮已执行（2026-08-07）

**缺口 C · 归因埋点**（可度量系统入口曝光）
- `SystemActionOrigin`（`intent` / `widget` / `deep_link`）随 action 一并写入 App Group
- `peekPendingOrigin()`：**非破坏性**读取——Intent 在独立进程投递后才拉起 App，`startAppSession` 时槽位已就绪；peek 不消费，路由仍归 MainTab
- `AnalyticsLaunchType` 五值域 + `app_session_start` 强校验（未知值抛错，不静默上报）
- 契约三端同步（iOS / Android / web 副本），`verify_mobile_analytics_contract.rb` 通过：JSON=25 iOS=25 Android=25
- 归因精度说明：`openAppWhenRun` 的 intent 可能在 widget 或 App 进程执行，故 widget↔Siri 是尽力而为；**「系统入口 vs 图标点击」永远准确**，这是分析真正需要的切分

**缺口 B · 契约测试**（`CastReaderTests/SystemIntegrationTests.swift`，15 条全绿）
- `castreader://` 真值表：三个 host、`id`/`item` 别名、模式回退、外来 scheme/host 拒绝、空输入拒绝、大小写不敏感
- 单槽位：last-write-wins、原子取用（不可重放）、坏数据清除而非无限重试
- 归因：peek 非破坏、take 一并清 origin、无 action 即无 origin
- **跨模块词表锁定**：`SystemActionOrigin.launchType` 必须是合法 `AnalyticsLaunchType`——两者分居扩展安全模块与主 App，无此测试则会静默漂移
- Continue 契约：绑定书库源（kindle/weread/google_books/kobo/oreilly）永不进入系统面、去重留最新、上限 8、最新在前、空 id 丢弃、**读时重新过滤**（旧构建写入的过期值不泄漏）

**验证**：定向测试 33/33 绿（SystemIntegration 15 + ProductAnalytics 18）；主 App + Widget + 两扩展编译全绿。
> ⚠️ 全量 `-only-testing:CastReaderTests` 会挂在 `PaymentTests`（StoreKit 确认弹窗挂起测试运行，仓库既有问题，见 1.2.14 试用测试记录）。挂起前 12 个套件全部 passed、0 失败。**验证本模块请用定向测试，别跑全量。**
