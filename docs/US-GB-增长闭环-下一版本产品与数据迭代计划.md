# US / GB 增长闭环 · 下一版本产品与数据迭代计划

> 规划日：2026-08-23
> 建议版本：1.2.28（版本号待发版时确认）
> 主验证市场：US；GB 保留 v1 价格，仅验证获客、激活与留存
> 唯一目标：让 **Apple Ads 安装 → 绑定/导入 → 首次价值 → 试用 → 正价付费 → CAC < LTV** 成为可验证、可迭代、可扩量的闭环。

## 1. 版本结论

下一版本不扩功能面，集中做四件事：

1. 修通 AdServices、安装身份、Apple 试用与正价订单之间的可信数据链；
2. 把新用户从登录后直接送到“选择来源 → 书库/整本书就绪 → 第一段声音”；
3. 用“书库已就绪”与真实听读后的价值时刻承接 7 天试用，不再给新用户 3 小时免费额度后才谈付费；
4. 在 7 天试用期内促成第二个听读日，并把年付选择率拉到能支撑 LTV 的水平。

在本版本成熟数据证明 CAC ≤¥263 前，US / GB 都保持学习预算，不扩量，也不把关键词、出价和产品改动放进同一个测量窗口。

## 2. 先纠正“跑通”和“可扩量”的数学

现有门槛可以证明首年打平，但不自动等于可扩量：

```text
安装 CPA ¥23 × install→paid 7%
⇒ 真实广告 CAC ≈ ¥23 / 7% = ¥329
```

要在同样 ¥23 安装 CPA 下达到扩量线 ¥263：

```text
所需 install→paid = ¥23 / ¥263 = 8.75%
若 trial→paid = 35%
所需 install→trial = 8.75% / 35% = 25%
```

反过来，如果 install→trial 只能保持 20%、trial→paid 35%，则安装 CPA 必须降到：

```text
¥263 × 20% × 35% = ¥18.4
```

因此使用两层目标：

| 指标 | 首年跑通保底线 | 本版本可扩量运营目标 |
|---|---:|---:|
| 安装 CPA | ≤¥23 | ≤¥23；若试用率只有 20%，则需≤¥18.4 |
| 72h 绑定/导入 | ≥20% | **≥35%** |
| 绑定/导入→72h 内试用 | 新增观察项 | **≥72%** |
| install→trial（首开后 72h） | ≥20% | **≥25%** |
| trial→paid | ≥35% | ≥35% |
| install→paid | ≥7% | **≥8.75%** |
| 年付选择率 | ≥60% | ≥60% |
| 真实广告 CAC | ≤¥329 | **≤¥263，连续两个成熟周** |
| 退款率 | <5% | <5% |

`72h 绑定/导入 20%` 只能作为失败红线。若它恰好只有 20%，要做到 install→trial 20% 就意味着几乎每一个绑定用户都必须开试用；要做到扩量所需的 25% 更是数学上不可能。所以下版本的真实产品目标必须把绑定/导入提升到至少 35%。

## 3. 2026-08-23 现状审计

### 3.1 可以复用的能力

- 五个书库连接已有 `entry_tapped → login → sync_completed/failed/cancelled` 阶段事件；
- EPUB / PDF 导入已有 `content_ready`，可统一计入 72h 激活；
- 听读已有 `read_first_audio`、30 秒本地激活状态和 300 秒里程碑；
- StoreKit 已能识别首购试用资格，US 展示 v2 SKU；
- Apple 交易会用账号绑定的 `appAccountToken` 做服务端验签；
- 服务端正价 Apple 交易会写入 `order`，零价格试用不会被记成收入；
- 继续听提醒已做到听满 180 秒后才请求权限、离开 24h 后提醒，可直接增强而无需重做。

### 3.2 当前四个硬缺口

#### P0-A：production AdServices 归因不可用

2026-08-21 之后 iOS 1.2.27 的其他生产事件持续进入数据库，但没有 `ad_attribution` 事件，也没有 attributed 设备。当前实现用 `try?` 吞掉系统错误，只在跨 5 次启动失败后上报 unavailable；因此既不知道失败原因，也无法保证首个会话内重试和事件送达。

结论：在修好并达到 48h 覆盖≥80%前，US / GB 广告漏斗和真实 CAC 都必须是 `UNKNOWN`。

#### P0-B：广告安装身份无法可靠连接 Apple 订单

当前有两个不同的设备标识：

- 广告归因与产品事件使用 `ProductAnalytics` 的 anonymous id；
- `/verify-apple` 和 `pro_device_link` 使用 Keychain 中的 `StableDeviceID`。

生产审计中，124 个 iOS analytics device 只有 2 个能直接命中 `pro_device_link`。虽然购买事件内已有 `backend_user_id`，但还缺一条由登录态服务端确认、持久化的安装→账号身份桥，不能依赖偶然相等或客户端自报身份计算真实 CAC。

#### P0-C：试用→正价缺少逐交易事实表

当前 `subscription` 只保存最新状态，`order` 保存正价收入，但缺少“每个 Apple subscription period”的不可变历史。仅凭当前状态，无法严谨确认同一个 `original_transaction_id` 是否从零价格试用进入 v2 全价交易，也无法稳定处理续费、升级、退款和乱序通知。

#### P1：产品漏斗更像卡在试用承接，而非入口数量

以下仅是 1.2.27 全渠道、未成熟、非广告 cohort 的方向性诊断，不能冒充 US / GB 投放结果：

- 52 个 production 首次见设备中，18 个在 72h 内完成书库同步或 EPUB/PDF 导入；
- 6 个设备启动试用，全部是 introductory；
- 6 个试用里仅 1 个选择年付；
- 55 个设备看过首页通用 Pro 卡，但该入口仅产生 1 个试用；
- 真正产生试用的主要触点是 `listen_quota` 与 `pro_voice`。

这说明下一版应优先优化“成功绑定后的价值确认、试用触发、年付呈现”，而不是再增加一个泛入口。

## 4. 下一版本的产品配置

### 4.1 配置隔离

| 市场 | 配置 | 价格 | 本版本变化 |
|---|---|---|---|
| US 新用户 | `us_growth_loop_v1` | 只展示 v2 | 完整激活、预览额度、价值触发试用、试用期留存 |
| GB 新用户 | `gb_growth_observe_v1` | 继续 v1 | 埋点与激活 UX；不切 US 的额度与新价结论 |
| 老用户 | 现有配置 | 保持原权益 | 不进入新用户效果 cohort |

配置由服务端按 App Store storefront、首次见时间和版本分配并持久化。样本小，不做并行 A/B；用一个冻结配置做前后 cohort 验证。服务端保留 kill switch，但测量期间不随意改参数。

当前 Apple Ads 路由 clean cohort 是 2026-08-24；下一版本发布后还要另设一个“产品配置切点”，取 100% 开启后的首个完整自然日。两个切点不能混为一个。

### 4.2 登录：保留硬登录，但把它变成可测环节

本版本不做 guest 架构改造。TTS、书库、账号权益和 Apple 订阅都依赖 canonical account，贸然移除登录门会扩大范围并制造跨端权益债务。

改动：

1. iOS 首屏以 Apple 登录为主按钮，Google / 邮箱为次级选择；
2. 登录成功后直接进入来源选择，不先落到通用首页；
3. 记录登录页展示、方式点击、成功、失败、耗时和允许枚举的错误码；
4. 若首开→登录成功低于 80%，下一轮才单独评估 guest preview，不与本轮并做。

### 4.3 绑定/导入：把路径压成一次选择和一次成功

将现有 sample、来源、Kindle storefront 等前置步骤压成一个“你的书在哪里？”页面：

- Kindle；
- EPUB / PDF；
- Kobo；
- Google Play Books；
- O'Reilly；
- 其他区域允许的书库。

具体行为：

1. Kindle storefront 按 US / GB 预选，允许修改，不单独占一整屏；
2. EPUB / PDF 与绑定书库同权展示，因为它们也满足闭环的“整本内容就绪”；
3. 用户点击后立即进入现有登录/文件选择器；
4. 同步完成后不回到通用首页，直接展示“已连接 X 本书”或“文件已准备好”；
5. 自动选择最近阅读或第一本可读书，主按钮为“开始试听”；
6. 失败页给原地重试和更换来源，并保留稳定 `errorCode`。

本环内部目标：

| 子步骤 | 目标 |
|---|---:|
| 登录成功→来源动作开始 | ≥60% |
| 连接/导入开始→内容就绪 | ≥75% |
| install→72h 绑定/导入 | ≥35% |

### 4.4 首次价值与试用：采用“成功页 + 试听”双触点

试用触发不能只等免费额度耗尽，也不能在用户尚未看到内容前用首页通用 Pro 卡打断。

新路径：

```text
书库/文件就绪
  → 成功页：展示书籍数量/内容就绪，首次提供 7 天试用 CTA
  → 用户可直接开试用，或选择“先试听”
  → 第一段音频成功播放
  → 累计真实听读 30 秒：再次出现与当前书绑定的软试用 CTA
  → 累计真实听读 5 分钟：到段落边界后出现硬付费墙
```

规则：

- 只有 StoreKit 判定仍有 intro offer 资格时才写“7 天免费试用”；
- 成功页和 30 秒触点的次按钮允许继续试听，不中断第一段声音；
- 5 分钟硬墙在段落边界出现，保留现有“读完本篇”的体验保护，但不再每天重置 20 分钟；
- 首页通用 Pro 卡在用户完成绑定/导入或 30 秒听读前隐藏，改放“连接/导入并开始听”；
- 购买成功后直接返回正在播放的书，不把用户丢回首页。

### 4.5 免费额度：不发布原计划的 3 小时首装赠额

3 小时赠额与“72h 内 install→trial≥20%”目标冲突：大部分新用户在测量窗口内根本不会走到付费触点。下一版把现有 `two_tier_v1` 客户端能力改造成服务端控制的 first-value preview：

- US 新配置：一次性 5 分钟真实听读预览；
- 首月不叠加 20 分钟月度额，避免实际变成 25 分钟后才触墙；
- 未开试用的用户从下一个计费月起可获得小额月度维持额度，具体值继续服务端配置；
- GB 和老用户保持当前额度，不混入 US 新配置；
- `quotaPolicy`、总余额、赠额余额必须由 `/api/mobile/pro/status/v2` 真正下发和记账；当前后端尚未实现，不能仅凭客户端注释宣称已上线。

### 4.6 试用期留存：目标不是“开了试用”，而是形成第二个听读日

7 天试用内只做与继续听书直接相关的触达：

1. D0：购买成功立即回到原书，完成首个 ≥10 分钟 session；
2. D1：复用现有 24h 继续听提醒，点击后深链回上次内容；
3. D2–D3：首页把“继续听”置顶，显示上次进度；
4. 试用结束前 24h：在有通知权限时明确提醒到期价格和自动续订；
5. 试用期不推无关功能，不用 AI 解读、音色等教育打散核心习惯。

试用健康前导指标：

| 指标 | 目标 | 用途 |
|---|---:|---|
| trial D0 听读≥10min | ≥70% | 购买后立即兑现价值 |
| trial D0–D3 至少 2 个听读日 | ≥50% | trial→paid 的核心前导指标 |
| trial 前 5 天累计≥30min | 建立基线 | 分层观察转正概率 |
| 绑定试用人群 W1 | ≥40% | 与闭环留存目标一致 |

### 4.7 年付承接：不改价格，只改选择表达

当前付费墙虽默认年付，但全渠道方向性样本中 6 个试用只有 1 个选年付。下一版本：

- 年付继续默认选中；
- 动态显示相对月付的节省百分比与“推荐”标记；
- 年付卡展示折合月价，月付作为可选但非视觉主项；
- 成功页、30 秒触点和首页卡使用同一套年付选择逻辑；
- 不再同时测试价格，US 继续 $9.99 / $59.99 v2。

## 5. 数据改造

### 5.1 可信连接链

下一版本的真实广告 CAC 必须按以下链路计算：

```text
AdServices attributed anonymous_id
  → 签名的 mobile_growth_identity_link
  → canonical user_id
  → verified apple_subscription_periods.original_transaction_id
  → 同 original_transaction_id 的全价 period
  → order.status = paid 且未退款
```

任何一跳缺失，都把相应 CAC 或 trial→paid 报为 `UNKNOWN`，不拿 ASC 国家总数补齐。

### 5.2 服务端新增事实

#### `mobile_growth_identity_links`

由有效 `cms_` session 的签名端点写入：

- `analytics_anonymous_id`；
- `stable_device_id`；
- canonical `user_id`；
- `linked_at`、`app_version`、`build`；
- 唯一/重绑审计字段。

客户端传入的 user id 不作为权威；服务端从 session 派生 user id。登录成功后立即写一次，购买前再次确保存在。

#### `apple_subscription_periods`

在 `/verify-apple` 和 App Store Server Notifications 两条入口中幂等写入：

- `transaction_id`（唯一）；
- `original_transaction_id`；
- canonical `user_id`；
- 实际 `product_id`；
- `offer_type`、`price`、`currency`；
- `purchase_date`、`expires_date`、`environment`；
- `revocation_date`、通知版本与来源。

判定规则：

- 试用开始：verified、production、`offer_type=1`、`price=0`；
- US 新价试用只认 monthly.v2 / yearly.v2；
- 试用转正：同一个 `original_transaction_id` 后续出现经过验证的正数交易，且不处于 introductory / promotional / offer-code / win-back 优惠期，金额与该 storefront 的 SKU 价目一致；ASC 的 `Full Price from Free Trial` 用于对账；
- 直接付费：没有零价试用 period、但存在上述已验证全价交易；它计入 install→paid，不进入 trial→paid 分母；
- 真正收入：同时命中 `order.status=paid`、金额>0，退款后从 paid 分子移除；
- 年付占比：以 verified Apple period 的实际 yearly SKU 为准；客户端付费墙选择事件只用于解释，不作为 LTV 权威；
- `purchase_result success + introductory` 只做客户端 UX 诊断，不再作为账务权威。

同时让 Apple `order.payment_product_id` 写入真实 SKU，避免 order 中只剩通用 `castreader-pro` 而无法区分 v1/v2。

#### `growth_config_assignments`

每个 analytics install id 只分配一次：

- `config_id`、market、app version/build；
- eligibility 与分配时间；
- 产品配置切点。

它的作用是保证 cohort 纯度，不用于小样本并行 A/B。

### 5.3 客户端事件合同

| 事件 | 改动 | 目的 |
|---|---|---|
| `ad_attribution_attempt` | attempt、outcome、latency、允许枚举的 errorCode；不带 token | 看见系统调用、重试与失败原因 |
| `ad_attribution` | 只记录 terminal token/unavailable/unsupported；token 事件立即 flush | 广告归因事实 |
| `growth_config_assigned` | configId、market、eligibility | 冻结 cohort 配置 |
| `onboarding_step` | 真正接入 auth gate、source chooser、library ready、first book、first audio、listen 30s/300s、trial offer | 找到最早流失步骤；当前该事件生产为 0 |
| `paywall_shown` | 增加 valueMilestone、offerEligible、selectedProductId、configId | 区分价值前/价值后付费墙 |
| `paywall_plan_selected` | productId、default/user、interval | 解释年付选择率 |
| `resume_reminder` | permission result、scheduled、opened；不上传书名 | 验证 D1 回访触达 |

继续保留并复用：

- `library_connection` 的 bindSessionId 与阶段事件；
- `content_ready` 的 EPUB / PDF 成功事件；
- `read_first_audio`、`read_milestone`；
- `purchase_start/result` 与 `entitlement_activated`，但只作客户端体验诊断。

所有新增字段都要同时更新 iOS schema、后端 `mobile-event-contract.ts`、测试 fixture 和查询脚本；后端拒收率必须可见，不能只在 DEBUG 客户端打印。

### 5.4 AdServices 可靠性改造

当前“一次调用失败就等下次启动”的策略改为：

1. 首个前台 session 内按 0s、2s、10s、60s 重试；进入前台仍可续重试，总窗口不超过 24h；
2. 每次调用记录 `ad_attribution_attempt`，错误映射为稳定枚举，移除静默 `try?`；
3. token 事件使用持久 event id，服务端幂等；
4. analytics pipeline 明确返回 accepted 后，才把 attribution 标成 reported；只入本地队列不算完成；
5. token 事件触发立即 flush，不等普通 2 秒批处理；
6. 升级 reported state 版本，让已装 1.2.27 的诊断设备可重新验证，但正式产品 cohort仍只认新版本切点后的新安装；
7. 服务端监控 pending、organic、invalid、expired 分布，48h attributed 覆盖低于 80%时自动把下游报表置为 UNKNOWN。

### 5.5 已替换错误的漏斗脚本

旧版 `readout-web/scripts/loop-funnel-report.mts` 曾把 `purchase_result success` 当成 payer，并用 global iOS 近似 US；这会把免费试用当正价用户。该旧口径已停用，当前实现只允许下列可信查询输出 CAC：

新查询/脚本只做：

- campaign 2144343127 / 2144503591；
- US / GB 分开；
- 只认 attributed device；
- 绑定、30 秒价值、W1/W4、verified trial、verified full-price period 分层；
- trial→paid 必须同 `original_transaction_id`；
- 按 app version、config id、campaign/ad group/keyword、安装周输出；
- 自动应用 D+2 / D+3 / D+8 / trial-end+3 / D+29 成熟度；
- 输出分子、分母、join coverage 和 UNKNOWN 原因。

## 6. 验收与发布门槛

### 6.1 发版前

- [x] iOS / Android / 后端 39 事件合同 parity 测试通过；
- [ ] 正式发版 artifact 的 `CURRENT_PROJECT_VERSION >= 47`；当前开发 build 46 必须保持不入组；
- [ ] 生产迁移先完成，再精确回读 `US_GROWTH_LOOP_V1_ENABLED=true`、`US_GROWTH_LOOP_V1_CUTOVER_ISO` 与 `US_GROWTH_LOOP_V1_MIN_BUILD=47`；缺失或不一致时保持 kill switch，不猜测启用；
- [x] disposable PostgreSQL 集成测试验证：buffered analytics 模式下，`app_session` ACK 后的 identity-link/status 首次请求即可读到冻结的 server first-seen，不会先回落 legacy 20 分钟；
- [ ] TestFlight 干净安装能看到 attribution attempt 与 terminal token 事件，并在服务端解析为 organic/attributed 等终态；
- [ ] 登录后 identity link 能把 analytics install id、stable device、canonical user 连成一行；
- [ ] Kindle 与 EPUB/PDF 各跑一遍：就绪 → 第一段音频 → 30 秒激活 → 试用墙；
- [ ] StoreKit sandbox 的零价试用进入 `apple_subscription_periods`，不进入 paid order；
- [ ] 模拟后续正价 transaction 后，能以相同 original transaction 连到 paid order；
- [ ] refund 会从 paid 分子移除；
- [ ] US 显示 v2，GB 仍显示 v1；
- [ ] 服务端 kill switch 可只关闭 US 新额度，不影响老用户和 GB。
- [ ] 词级 JSON 只有完整 D+10 成熟时才给 `installs/fullPricePayers`；否则必须是 `WAITING_MATURITY` 且 CAC 输入为 `null`。

### 6.2 发版后数据门

| 时间 | 必须确认 | 不达标动作 |
|---|---|---|
| 首日 canary | 事件接收率≥99%，identity link 可用 | 暂不开 US 新配置 |
| D+2 | production attributed 覆盖≥80% | P0 修数据；所有下游 UNKNOWN |
| D+3 | 72h 绑定/导入≥35%，绑定→试用方向性≥72% | 回来源选择/成功页/试用触点 |
| D+8 | 全体 W1≥15%，绑定人群 W1≥40% | 回第一听与 D1 继续听 |
| trial end +3d | install→trial≥25%，trial→paid≥35% | 分开处理触墙与试用习惯 |
| D+29 | 绑定人群 W4≥30% | 价值假设未稳，不扩量 |

### 6.3 扩量裁决

只有同时满足以下条件，才进入“讨论扩量”而不是自动加预算：

1. 两个连续成熟周均有≥30 个广告归因正价付费人；
2. US install→paid≥8.75%，或实际 CPA 与付费率组合能使 CAC≤¥263；
3. trial→paid≥35%、年付≥60%、退款<5%；
4. 绑定人群 W4≥30%；
5. 归因覆盖≥80%，广告安装→身份→Apple period→paid order 的 join coverage≥95%；
6. 测量窗内产品配置、价格、关键词路由和主要出价没有混杂变更。

达到 CAC≤¥329 但高于¥263，只能称“首年跑通”，继续小额学习，不扩量。

## 7. 实施顺序

### P0：先让结论可信

1. AdServices 重试、诊断、accepted ack；
2. 签名 identity link；
3. Apple subscription periods 与真实 SKU；
4. 新 cohort 查询替换旧 payer 口径；
5. 发版/生产 canary。

### P1：让 35% 绑定和 25% 试用成为可能

1. 登录成功直达来源选择；
2. 合并来源与 storefront 步骤，EPUB/PDF 同权；
3. 同步成功页与自动首本书；
4. 成功页 + 30 秒双试用触点；
5. US 5 分钟 first-value preview，停止 3 小时赠额方案；
6. 激活前隐藏首页通用 Pro 卡。

### P1：让试用有机会转正

1. 购买后返回当前书；
2. 首页继续听置顶；
3. D1 深链提醒与 reminder 埋点；
4. 年付节省标记；
5. 试用健康 cohort 查询。

## 8. 本版本明确不做

- 不扩 Apple Ads 预算；
- 不在产品版本测量窗内同时改关键词与主要出价；
- 不做 guest 全架构；
- 不新增声音、AI 功能或内容平台；
- 不改 US v2 价格；
- 不把 GB v1 结果解释成 US 新价闭环；
- 不发布 3 小时首装赠额；
- 不用全渠道 ASC 付费人数计算广告 CAC；
- 不用客户端 `purchase_result success` 冒充正价付款。

## 9. 下一次策略讨论的输入

下次不再泛看整体数据，只带四张按 US / GB 分开的表：

1. 广告获客：spend / taps / installs / CPA，按 campaign、keyword、search term；
2. 激活：auth → source start → sync/import → first audio → 30s，按新版本与 config；
3. 试用健康：trial start、D0 10min、D0–D3 两个听读日、verified full-price；
4. 经济性：paid/refund、install→paid、真实 CAC、年付占比与 LTV:CAC。

每次只改最早失败的一环。数据门未过时不讨论下游转化；CAC≤¥263 且连续两个成熟周稳定前，不扩量。
