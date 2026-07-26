# Kindle 登录页自动恢复 · 跨端对齐指南

面向 Android 端的落地要求。iOS 已实现，本文记录真机取证结论、契约与验收标准。

## 1. 现象

用户从书架点开一本已同步的 Kindle 书，阅读器里出现的是 **Amazon 登录页**，不是书。此时：

- 账号并没有退出，书架里的书都在
- 反复点同一本书**不会自愈**
- 只要去 Kindle 书架页转一圈再回来点，就能正常打开

## 2. 根因

`read.amazon.com/?asin=<ASIN>` 这个深链受 Amazon 的**阅读器会话**保护。会话失效时 Amazon 在**第一跳**就 302 到 OpenID 登录网关：

```
https://www.amazon.com/ap/signin
  ?openid.mode=checkid_setup
   openid.assoc_handle=amzn_kindle_mykindle_us
   openid.pape.max_auth_age=1209600
   openid.return_to=https://read.amazon.com/?asin=<ASIN>&ref_=...
```

**这个会话只有 Amazon 自己的书架客户端会激活。** 加载一次 `read.amazon.com/kindle-library` 即可，**不需要扫描书架、不需要同步**——页面加载本身就是全部机制。

### 真机证据（iOS，2026-07-25）

| 观测 | 结论 |
|---|---|
| 失败与成功请求携带的 18 个 Amazon cookie **名称完全一致** | 不是 cookie 丢失 |
| `at-main` / `sess-at-main` / `x-main` / `ubid-main` / `session-id` 全程**值未变**，有效期约 350~365 天 | **没有发生重新认证**，登录凭据一直有效 |
| 连续 7 次开书（旧日志 5 次 + 新日志 2 次，跨 17 分钟）全部落到登录页 | **失败不会自愈**，重试无用 |
| 一次 `/kindle-library` 加载（未点同步）后，紧接着开书成功 | **书架页加载是唯一有效的激活动作** |
| 书架被 302 的同时，reader 正在被打回 | reader 被拒时书架通路仍然可用 |

### 已排除的解释

- **不是 cookie 过期**：所有认证 cookie 都是长效且有效的。
- **不是 `max_auth_age` 14 天规则**：若是，恢复时 `at-main` 必然轮换，实测未轮换。
- **不是 `session-token` 轮换修好的**：让开书成功的那个 token 是更早一次失败时由登录页发的，书架加载并未改动它。
- **不是 Akamai 机器人 cookie（`ak_bmsc`/`bm_sv`）过期**：失败与成功之间其值未变。
- **不是应用侧删了 cookie**：全项目仅两处 `removeData`，都只在设置里手动解绑时触发，且各自按域名过滤。
- **不是与微信读书串扰**：用户交叉验证后确认无关。
- **不是进程/WebView 状态丢失**：杀掉 App 重开仍可正常打开。

**触发条件仍未定位。** 已知与闲置时长相关（一次观测到闲置 82 分钟后失效），但未能量化 TTL。这不影响恢复逻辑成立——恢复不依赖触发条件。

## 3. Android 必须实现的契约

### 3.1 识别落地页

不能只看「有没有报错弹窗」。必须判定 WebView **导航结束时的实际 URL**：

| 判定 | 条件 |
|---|---|
| `auth` | URL 含 `/ap/signin`、`/ap/cvf`、`authportal` 或 `openid.` |
| `library` | URL 含 `kindle-library` |
| `reader` | host 含 `read.amazon.`（且非上述两类） |

登录页与「书籍失效」是**两种不同故障**，各有各的检测：后者是 `please try to open this book from the library again` / `Oops, something went wrong` 弹窗，走既有的书架重扫恢复；前者走本文的会话恢复。**不要用其中一个的检测去覆盖另一个。**

### 3.2 恢复流程

```
开书导航结束 → 落地 = auth
   ↓
盖住页面（loading 态，用户不应看到登录表单）
   ↓
在独立 WebView 里加载 read.amazon.com/kindle-library
   ├─ 落地 library  → 重新加载原书 URL → 正常进书
   ├─ 落地 auth     → 会话真死了 → 走 3.3 的重新绑定引导
   └─ 超时（15s）   → 同上
```

### 3.3 恢复失败：必须把用户领到重新绑定

**不要把 Amazon 的原始登录页丢给用户就不管了。** 用户看到一个陌生的 Amazon 表单，不知道这跟「Kindle 绑定」有什么关系，也不知道登完要不要回去同步。

失败时展示**原生卡片**（盖住 WebView），说明「Kindle 登录已失效，需要重新绑定」，并提供一个明确按钮，点击后：

1. 清除 Amazon 网站数据（cookie / 存储），让绑定流程从干净状态开始
2. 置 `hasConnected = false`、清空书架缓存
3. **保留听书进度锚点**——锚点按 book id 存，重新同步后自动对上。这次失效不是用户主动解绑，不该让他丢阅读位置
4. 关闭书籍阅读页
5. 打开 Kindle 绑定流程

**解绑不要做成全自动。** 它会清空书架，而 auth 落地判定是启发式的：误判一次就把用户的书架清了。iOS 的做法是原生卡片 + 一次点击确认，引导同样明确，但不会静默毁数据。

### 3.4 顺带观测 HTTP 状态码

主 frame 响应的状态码要记进日志。会话过期表现为 **302 → 登录网关**；真正的 **401/403** 是请求被直接拒绝，两者原因不同。iOS 在 `decidePolicyFor navigationResponse` 里只记录、不改变决策。

### 3.5 硬性约束

1. **每次阅读会话只自动恢复一次**。落地 reader 后重置计数。账号真的退出时绝不能自旋。
2. **书架那一跳必须用书架客户端的配置**：不带桌面阅读器 UA、不注入阅读器脚本。带桌面 UA 去请求书架，Amazon 不会刷新 book session。
3. **不要扫描书架、不要触发同步**。只要页面加载完成即可，多余动作只会拖慢恢复。
4. **恢复期间必须遮住 WebView**，否则用户会看到登录页一闪、再看到书架一闪。
5. **恢复失败时不要停在 Amazon 登录页**：按 3.3 引导重新绑定。
6. **落到 auth 时不要跑阅读器初始化**（找设置按钮、锁定单页模式、几何探测）。iOS 上这会在登录表单上空转 12 秒，并错误显示「打开任意位置，然后点播放开始朗读」。

## 4. iOS 实现位置

| 内容 | 位置 |
|---|---|
| 落地页分类 | `KindleSessionProbe.landingKind(_:)`（`Views/Kindle/KindleBookView.swift`）|
| 恢复入口 | `KindleBookViewModel.webView(_:didFinish:)` 中 `landing == "auth"` 分支 |
| 恢复状态机 | `startAuthRecovery()` / `warmShelfSession()` |
| 书架客户端配置 | `makeLibraryRecoveryWebView()`（无桌面 UA、无阅读器脚本）|
| 遮罩 | `KindleBookView.authRecoveryOverlay` |
| 重新绑定引导 | `KindleBookView.kindleRebindOverlay` + `KindleBookViewModel.startKindleRebind()` |
| 保留进度的解绑 | `KindleLibraryStore.markSessionExpiredForRebind()` |
| 跳转绑定流程 | `Notification.Name.castReaderKindleRebindRequested` → `KindleHomeSection` |
| HTTP 状态观测 | `KindleBookViewModel.webView(_:decidePolicyFor:decisionHandler:)` |
| 会话诊断埋点 | `KindleSessionProbe.logCookies(reason:)` / `KindleSessionFreshness` |

## 5. 诊断埋点要求

排查这类问题时，**cookie 值一律不得入日志**。iOS 的做法是只记「名称 + 有效期 + 值的 8 位单向摘要」——足以看出某个 token 是否轮换或消失，不足以还原凭据。同时记录：

- 落地页分类、服务端重定向逐跳
- 距上次成功进书 / 成功加载书架的分钟数
- 进程启动横幅（区分「重启了 App」和「同一会话放久了」）

## 6. 验收标准

1. 会话失效状态下点开书籍：用户**全程看不到登录页**，只看到一次短暂 loading，然后正常进书。
2. 真实退出登录的账号：自动恢复只尝试一次，随后展示原生「需要重新绑定」卡片；点击后清除 Amazon 数据、关闭阅读页、进入绑定流程，**听书进度不丢**。
3. 「书籍失效」故障路径不受影响，仍走书架重扫恢复。
4. 正常开书路径**不增加任何网络请求**。
5. 日志能回答：这次恢复走到第几步、书架落地是什么、恢复前后各 cookie 是否轮换。
