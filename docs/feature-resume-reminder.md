# 「继续听」本地通知召回 v1

目标：补上产品唯一缺失的留存基础件——用户留下听到一半的内容离开后，24 小时后用本地通知叫回来。此前全项目没有任何召回机制（`UNUserNotificationCenter` 零处引用）。

## 行为

- **够格**：某内容累计**真实收听 ≥60s**（时长来自播放 tick 管线，单次 delta >2.01s 的拖动/跳变不计入，与评分资格、书库引导激活同一口径）。
- **调度**：App 进后台时，取最近听过的够格内容，在「最后收听 +24h」触发（至少距现在 6h）；锁屏后台听书时每 5 分钟刷新锚点，保证触发点跟着真实收听走。
- **取消**：回前台立即取消全部待发提醒——人已经回来，迟到的提醒只会显得愚蠢。同时只保留一条待发。
- **防骚扰上限**：单内容一生 ≤2 次、两次间隔 ≥7 天；全局 ≤1 条/天（不满足时顺延而非放弃，顺延后超出「新鲜窗 72h + 延迟」总预算则放弃）；最后收听超过 72h 的中断视为意图已冷，不再打扰。
- **权限时机**：首启绝不弹。累计 180s 真实收听后的下一次回前台才请求（此刻用户已被产品说服）；拒绝即永久沉默。
- **文案**：标题 = 内容真实标题，正文 = `上次还没听完，接着听？`（九语齐全）。点按仅打开 App（首页各 rail 自带「继续」入口），v1 无自定义深链。

## 实现

| 文件 | 职责 |
|---|---|
| `CastReader/Services/ResumeReminderManager.swift` | `ResumeReminderPolicy`（纯函数策略层）+ `@MainActor` 单例（权限、调度、取消、状态持久化 UserDefaults `resumeReminder.v1.state`，追踪内容上限 20 条） |
| `ReadAloudViewModel` tick 处 | 一行旁路：`recordPlayback(documentID:title:seconds:)`（与 AppReviewPromptManager / BoundLibraryOnboardingStore 同点） |
| `MainTabView` scenePhase `.active` | `appBecameActive()`：取消待发 + 时机成熟则请求权限 |
| `CastReaderApp` | `start()` 注册 didEnterBackground 观察者 |

**刻意不做（v1）**：启动归因埋点——本地通知拿不到可靠打开归因，不往 22 事件契约里塞测不准的东西；效果通过 D1/D7 留存曲线整体评估。深链直达播放、Kindle/WeRead 专属文案、服务端推送均留待 v2。

## 测试

`CastReaderTests/ResumeReminderPolicyTests.swift` 12 条：60s 门槛、72h 新鲜窗、+24h 锚点、6h 最小提前量、单内容 2 次/7 天冷却、全局频控只顺延不提前、顺延超预算放弃、候选按最近收听挑选、delta 口径与兄弟管线一致（2.01s）、权限阈值 180s。

## 验收（真机）

1. 听任意内容 ≥3 分钟 → 回首页 → 出现系统通知权限弹窗（首启无弹窗）。
2. 允许后听 ≥1 分钟，退后台 → 次日同时刻收到「《标题》：上次还没听完，接着听？」。
3. 收到前重新打开 App → 通知不再出现（已取消）。
4. 同一内容 7 天内不会收到第二条；连续多天使用不会一天收到多条。
