# US / GB Apple Ads 增长闭环数据目标与拉数 SOP

> 生效日：2026-08-23
> 最新路由变更：2026-08-23 11:52 CST
> 广告路由切点：2026-08-24 00:00（Asia/Shanghai，UTC+8）
> 数据口径修订：2026-09-04；当前 1.2.33 (build 53)，不同首次安装 build 分开展示，不把升级日当安装日。
> 状态：**Apple Ads 增长分析的唯一现行口径**

## 1. 目标与边界

只验证一个闭环：

**Apple Ads 用户进来 → 72h 绑书库/导入整本书 → 听读留存 → 按当前可售价格付费 → 真实广告 CAC < 净 LTV。**

投放范围只有：

| 市场 | Campaign | ID | 价格口径 |
|---|---|---:|---|
| US | `CR_US_Search_Discovery_2026Q3` | `2144343127` | v2 新价：`monthly.v2` / `yearly.v2` |
| GB | `CR_GB_Search_Discovery_2026Q3` | `2144503591` | 新版已展示 v2；历史 v1 单列，GB 净 LTV 单独核定 |

所有决策数据必须满足：

- 获客报表日期不早于 `2026-08-24 00:00 Asia/Shanghai`；`2026-08-23` 是路由调整前后混合日，只作审计；
- 产品漏斗不得把广告路由切点当产品版本切点。build 47 缺少首次打开调用，只可审计；其他 build 必须有原始 `app_first_open.fresh_install` 接收证据，不凭版本号推定完整。按首次打开时的 build 分层，历史缺失不得回填成新安装；
- US 与 GB 分开计算，不用其他国家补样本；
- 广告用户必须有 `mobile_ad_attributions.status = attributed` 才能进入广告闭环；
- 自然量、全渠道 ASC 数据只能做国家趋势辅助，不能冒充广告 cohort。

## 2. 经济目标

### 2.1 US v2 LTV 基线

规划汇率固定用 `1 USD = 7.15 RMB`，避免日常汇率波动改变实验结论。

| 口径 | USD | RMB | 用途 |
|---|---:|---:|---|
| 首年净 LTV | $46 | ¥329 | 主判定线：首年回本 |
| 两年净 LTV | $54–65 | ¥386–465 | 容忍线：延长回本，不用于扩量 |
| 可扩量 CAC | ≤$36.8 | ≤¥263 | 首年 LTV:CAC ≥1.25 |

跑通定义：

- **首年跑通**：成熟 cohort 真实广告付费 CAC ≤ ¥329；
- **可扩量**：CAC ≤ ¥263，连续两个成熟周 cohort 达标，退款率 <5%；
- **仅两年可回本**：¥329 < CAC ≤ ¥386，保持小额验证，不扩量；
- **停投线**：成熟 CAC > ¥465，或者绑书库人群 W4 留存失败。

GB 在当地 v2 实际净 LTV 未核定前，只报真实 CAC，不用 US v2 LTV 宣判跑通；历史 v1 不混算。

### 2.2 联动漏斗目标

不再将每一段阈值独立判定。经济恒等式为：

```text
真实付费 CAC = 广告花费 / 广告归因的正价付费人数
允许的安装 CPA = 净 LTV × install→trial × trial→paid
```

US 运营目标用 `install→trial = 20%`、`trial→paid = 35%`，对应：

```text
install→paid = 7%
首年允许的安装 CPA = ¥329 × 7% ≈ ¥23
```

| 环节 | 主指标 | 目标 | 说明 |
|---|---|---:|---|
| 进来 | CPT | ≤¥8 | 价格指标，不代表流量质量 |
| 进来 | tap→install | ≥35% | 意图与商店页匹配度 |
| 进来 | 安装 CPA | ≤¥23 | 由首年 LTV 反推，不再用¥35 |
| 数据可用 | AdServices 归因覆盖 | ≥80% | ASA 安装后 48h 的设备归因覆盖 |
| 绑书库 | 72h 绑定/导入 | ≥20% | 分母为广告归因新用户 |
| 留存 | W1 听读 | 全体≥15%；绑定人群≥40% | W1 至少 2 个听读日，每日≥5min |
| 留存 | W4 听读 | 绑定人群≥30% | D22–D28 仍有听读 |
| 付费 | install→trial | ≥20% | US 只计 v2 新价 SKU |
| 付费 | trial→paid | ≥35% | 只计免费试用结束后的正价付费 |
| 付费 | install→paid | ≥7% | 联动经济目标 |
| 付费 | 年费占比 | ≥60% | 稳定 LTV |
| 回本 | 真实广告 CAC | ≤¥329 | US 首年跑通线 |

阈值是一组整体约束。即使安装 CPA 达标，如果付费 CAC 不达标，仍然不得宣布跑通。

## 3. 数据口径

### 3.1 广告 cohort

广告用户必须同时满足：

1. `mobile_ad_attributions.environment = production`；
2. `status = attributed`；
3. `campaign_id` 属于 US / GB 两个目标 Campaign；
4. 存在服务端接收并幂等冻结的 `app_first_open.firstOpenKind = fresh_install`；cohort 时间取服务端 `received_at`，不取客户端时间或归因首次出现时间；
5. 单版本验收用 `required_app_build = <所验收 build>` 断言整日是否纯净；版本诊断用 `app_build = <首次安装 build>`，但不能把整条 campaign 花费/ASA 安装分摊给子集。混合版本按 build 列出人数，跨版本整体仅作诊断，不评价某个新版本；
6. 同一 `anonymous_id` 只计一次首次打开与一次终态归因。

Apple Ads API 的 `totalInstalls` 与花费一并进入 `growth_ad_spend_daily`，仅用于渠道对账；设备级漏斗的安装分母必须来自 `app_first_open.fresh_install`，归因状态来自 production AdServices 服务端解析。

### 3.2 行为事件

| 环节 | 定义 |
|---|---|
| 72h 绑书库 | `library_connection.stage = sync_completed`、`result = success` 且明确非空书库 |
| 72h 导入 | `content_ready.contentFormat IN (epub, pdf)` 且 `paragraphCountBucket IN (1_5,6_20,21_100,101_plus)` |
| 听读日 | 同一安装相对的 24h 日桶内有 `read_milestone.milestoneSeconds >= 300`，重复里程碑不重复计日 |
| W1 | D0–D7 至少 2 个听读日 |
| W4 | D22–D28 至少 1 个听读日 |
| 试用开始 | 客户端 success + introductory 为候选；权威计数要求同安装身份连到 Apple production `zero_price_trial` 交易，US/GB 新价只计 v2 |
| 直接付费 | 成功购买且非 introductory，并经 Apple 服务端交易验证 |
| 试用转付费 | Apple 订阅对账确认 `Full price from free trial` / 订阅状态由 trialing 转 active |

`purchase_result success` 在免费试用场景只表示“试用启动”，**不是正价付费**。

### 3.3 辅助数据

ASC `App Downloads Standard` 与 `App Store Subscription Event Report Standard` 没有 ASA Campaign / Keyword 维度，只做：

- 国家大盘与设备级归因的对账；
- 试用转正价的 Apple 账务真值校验；
- 发现事件漏报。

严禁计算：

```text
ASA 花费 / 同国全渠道付费人数
```

该值只是偏乐观的 CAC 下界，不是广告 CAC。

## 4. 成熟度与决策样本

| 指标 | 最早可读 | 成熟条件 |
|---|---|---|
| ASA 花费/点击/安装 | D+1 | 已结算日 |
| AdServices 归因覆盖 | D+2 | 安装后满 48h |
| 72h 绑定/导入 | D+3 | 首见时间满 72h |
| W1 听读留存 | D+8 | D0–D7 完整结束 |
| 7 天试用转付费 | D+10 | 试用期 + ASC 2–3 天滞后 |
| W4 留存 | D+29 | D22–D28 完整结束 |

决策分层：

- 关键词/匹配方式：至少 20 taps 或 5 安装；
- 绑定与 W1：至少 30 个广告归因安装；
- 付费 CAC 初判：至少 10 个正价广告归因付费人；
- 扩量：至少 30 个正价广告归因付费人，且连续两个成熟周 cohort 结论一致。

样本不足只能报“方向性信号”，不能做启停或扩量结论。

## 5. 拉数 SOP

### 5.1 每次策略讨论前：快速获客快照

```bash
ruby scripts/growth_loop.rb
```

只在需要讨论新一轮策略、阈值越线或 cohort 成熟时运行，不做每日自动监控。默认窗口是 `2026-08-24 → 昨天`，只拉 US / GB，不下载 ASC 逐日分片。

固定读取：

1. Campaign 当前状态、日预算、`modificationTime`；
2. 昨日、近 3 个结算日、切点后累计；
3. Campaign / Ad Group / Keyword / Search Term；
4. 价格指标 CPT、质量指标 tap→install、联动指标安装 CPA；
5. 按当前 CPA 反推所需 `install→paid` 和 `install→trial`。

策略讨论不得输出全账户混合数据；如果窗口包含结构调整当日，必须另拉首个完整结算日，避免混用调整前后的流量。

### 5.2 付费 cohort 成熟时：完整商店对账

```bash
ruby scripts/growth_loop.rb --full
```

`--full` 只在 D+10 付费 cohort 成熟、ASC 异常或需要核对商店真值时运行，在快速报告后增加：

- ASC 首次下载，按 `Date` 字段过滤；
- ASC 试用开始、试用转正价、流失，按 `Event Date` 过滤；
- US / GB 分国家、分 SKU 对账；
- 明确标注为“全渠道辅助数据”。

### 5.3 策略迭代时：广告 cohort 漏斗

后端 `/api/cron/sync-apple-ads` 每小时自动读取两个固定 campaign，将已跨过日末 72h 滞后的 UTC 日事实写入 `growth_ad_spend_daily`，对账后写入 `growth_data_coverage`；原始来源哈希保存在 `growth_apple_ads_sources`。这是后台数据入库任务，不是每日向用户推送报告，不修改广告。优先补最新缺日，全部补齐后重查最近完整日；来源变化或对账失败不得继续宣称完整。

`growth_loop.rb` 的 D+1 快照仍可用于方向判断，但未到完整性滞后的日期不能据此认证 CAC。旧 Ruby 导出器保留为独立只读对账工具，不与自动采集器同时提交 coverage：

```bash
ruby scripts/searchads_growth_spend_export.rb --date YYYY-MM-DD
```

然后从 `readout-web` 使用唯一 cohort API。`from/to` 必须是 UTC 日边界，to 不包含；将下方 53 替换为实际所验收版本，不能一直沿用旧 build：

2026-09-04 后端修复的已部署 runtime commits 为 `5e69d2cc`、`4720b4cf`（生产部署 `dpl_HRfYUZQjRGPB2QybnKEYw9ykcZVo`），源码隔离工作树 `/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-growth-funnel-integrity`。本机若没有独立 GROWTH_ADMIN_SECRET，不替换/降低权限；在此工作树执行 `pnpm exec tsx scripts/growth-cohort-direct.mts --env-file /Users/xuxuheng/Documents/MyProject/readout-web/.env.local --from YYYY-MM-DD --to YYYY-MM-DD --country US`。该命令仅调用同一个 SELECT 聚合函数；严禁对共享生产连接池设置会话级参数（包括 `SET default_transaction_read_only`），防止污染应用连接。不得用原脏工作区的旧统计代码冒充已部署口径；后续部署须保留此修复。

此次生产回查：8 月 24 日至 9 月 4 日验收时的 26,040 条 iOS 原始事件，漏斗明细缺失 0、冲突 0；累计从原始记录修复 13,959 条。此结果只证明源表→漏斗表一致，不代表无来源记录的历史安装/试用已补齐。仍有一笔 US 全渠道试用缺少安装身份，不得补造归因。数据库异常时队列保留重试、降级返回 503；原样重发真实事件已验证不改变原始时间且不重复计数。完整记录见后端 `docs/growth-funnel-integrity-2026-09-04.md`。

```bash
GROWTH_ADMIN_SECRET=... pnpm growth:cohort --from YYYY-MM-DD --to YYYY-MM-DD \
  --platform ios --provider apple_ads --country US --campaign-id 2144343127 \
  --required-app-build 53 --horizon 10

GROWTH_ADMIN_SECRET=... pnpm growth:cohort --from YYYY-MM-DD --to YYYY-MM-DD \
  --platform ios --provider apple_ads --country GB --campaign-id 2144503591 \
  --required-app-build 53 --horizon 10
```

兼容命令 `scripts/loop-funnel-report.mts` 已改为调用同一个 API，不再接受手工 `coverage-us/coverage-gb`，也不再固定 `spendCny=null`。

权威查询按以下链路聚合：

1. 从 `app_first_open.fresh_install` 冻结安装与首次安装 build 分母，再连 production AdServices 终态；
2. 用 `anonymous_id` 连 72h 非空绑定、听读和试用启动；
3. 用 Apple 订阅对账将试用连到正价 active 交易；
4. 用 `growth_ad_spend_daily + growth_data_coverage` 读取同 campaign/UTC 日花费，计算安装 CPA 与真实付费 CAC；
5. 单列 US 规划首年净 LTV ¥329 与真实 CAC 的比较；observed contribution LTV 只有逐交易 net proceeds 和完整可变成本 coverage 均到齐后才输出。

若试用启动设备无法连到 Apple 正价交易，CAC 必须报 `UNKNOWN`；不得用 ASC 国家总付费填补。Apple 财务报表若没有可唯一匹配 `transaction_id` 的粒度，不得伪造逐交易 proceeds；可变成本没有完整全源账本时也保持 `UNKNOWN`，两者都阻断 `SCALE`，但不阻止在 D+10 后计算真实广告 CAC 和单列的规划 LTV/CAC。

### 5.4 状态解释

- 原始事件与明细存在缺失/冲突、试用无法连接身份、客户端试用无法连接 Apple 交易：`BLOCKED_INCOMPLETE`；漏斗比例与 CAC 为 `UNKNOWN`，不得解释成零转化。
- 报表必须同时列出 `observedTrialsStarted`（已验证、含未成熟）与 `trialsStarted/trialMatureInstalls`（72h 成熟子集），不得把后者称为全部试用。W1/W4 各用独立成熟分母。
- D+2 分母尚未成熟：`measurementStatus = WAITING_MATURITY`、覆盖率 `UNKNOWN`；不是 0%，也不是 P0。
- D+2 已成熟且终态覆盖 `<50%`：`P0_DATA_INCIDENT`。
- D+2 已成熟且覆盖 `50%–<80%`：`BLOCKED_INCOMPLETE`，后续漏斗/CAC 为 `UNKNOWN`。
- 指定 required build 的窗口出现其他/缺失 build：`UNEXPECTED_APP_BUILD_IN_COHORT`；单 build 子集没有可分摊的 ASA 安装分母，覆盖率必须 UNKNOWN，不能误报 P0。

## 6. 报告模板

每次只输出以下顺序：

1. **归因可用性**：attributed 数、覆盖率、是否能计算真实 CAC；
2. **US**：①→⑤各环分子/分母、成熟度、CAC/LTV；
3. **GB**：同上，新版 v2 与历史 v1 分开，当地 LTV 未核定前不宣判跑通；
4. **唯一瓶颈**：当前最早失败的环节；
5. **动作**：继续、减量、暂停或回产品；
6. **下次可读时间**：明确等待哪个 cohort 成熟。

## 7. 告警与动作

| 条件 | 动作 |
|---|---|
| 48h 归因覆盖 <50% | P0 数据事故；暂停所有“CAC 已跑通”结论 |
| 50%≤48h 归因覆盖<80% | 数据不完整；②–⑤报 `UNKNOWN`，不得做经济性结论 |
| 连续 2 个结算日安装 CPA >¥23，且累计 taps ≥20 | 不加预算；下钻搜索词与商店页匹配 |
| 72h 绑定/导入 <20% | 保留获客结论，回 onboarding / 首次价值交付 |
| 绑定人群 W4 <20% | 价值假设失败，停扩量，回产品 |
| 20%≤绑定人群 W4<30% | 未过目标；维持小额学习，先修持续使用价值 |
| install→trial <20% | 检查首次价值、额度闸门和 paywall trigger |
| trial→paid <20% | 价格/试用价值未成立，不加量 |
| 20%≤trial→paid<35% | 未过目标；不扩量，优化试用期价值与价格呈现 |
| ¥329 < CAC ≤¥386 | 只保留学习预算 |
| ¥386 < CAC ≤¥465 | 接近两年容忍上限；禁止扩量，优先降获客成本或提高转化 |
| CAC >¥465 | 停投对应 Campaign，保留 cohort 结论 |

本 SOP 是只读分析 SOP。任何启停、预算、出价、关键词或否定词修改，都必须另行获得用户授权。

## 8. 闭环优先运营原则

在“进来 → 绑书库 → 留下来 → 按当前可售价格付费 → CAC < LTV”完整跑通前，US / GB 都只保留学习预算，**不得扩量**。上游某一项单独变好，不构成扩量理由。

每轮只处理最早失败的一环：

| 顺序 | 当前失败环节 | 优先优化方向 | 下一次验证指标 |
|---:|---|---|---|
| 0 | 归因覆盖不足 | AdServices 首启上报、服务端摄入与解析 | 48h production attributed 覆盖 |
| 1 | tap→install / 安装 CPA | 搜索词意图、Custom Product Page、商店页承诺一致性 | tap→install、安装 CPA |
| 2 | 72h 绑书库/导入 | 首启路径、首次同步成功率、首本书价值交付 | 72h 绑定/导入率 |
| 3 | W1 / W4 留存 | 首次听读成功、播放体验、回访触发与书库持续价值 | 绑定人群 W1 / W4 |
| 4 | install→trial | 先体验价值再触发付费墙、额度时机、价格呈现 | install→trial |
| 5 | trial→paid / CAC | 试用期习惯形成、年费价值、退款与正价续费 | trial→paid、install→paid、真实 CAC |

优化纪律：

1. 数据门未过时，先修数据，不对下游做因果结论；
2. 同一成熟 cohort 尽量只改变一个主要变量，并记录变更时间；
3. 每个建议必须写清“假设 → 动作 → 目标指标 → 最早可读时间”；
4. 前一环未过线时，不用下游偶发付费掩盖问题；
5. 只有全部成熟门槛通过、真实 CAC ≤¥329，才称为“跑通”；只有 CAC ≤¥263 且连续两个成熟周稳定，才允许另行讨论扩量。

## 9. 当前迭代：关键词意图路由 v1

执行时间：`2026-08-23 11:52 CST`。本轮只改变流量路由，不改变预算、出价、Search Match 或 Broad 关键词状态。

- US Discovery：暂停 22 个 Kindle / PDF / EPUB / ebook 高意图 Exact Negative，让暂停的 US Exact Campaign 不再造成流量黑洞；
- US / GB：各新增 `wattpad`、`ao3`、`barnes & noble`、`goodreads` 四个 campaign-level Exact Negative；
- US / GB Discovery 日预算继续各 ¥60；所有 active Broad 与 Search Match 默认 Max CPT 继续 ¥10；
- US Exact Campaign 继续暂停，不增加总投放量；
- `2026-08-23` 排除，首个完整效果日为 `2026-08-24`。

本轮假设：把预算从不支持绑书库的平台词，重新路由到 Kindle / PDF / EPUB / ebook 高意图查询，可提高 tap→install，并最终提高 72h 绑书库率。出价不是本轮变量。

## 10. 下一版本产品与数据迭代

下一版本的详细范围、事件合同、身份/Apple 交易连接、产品触点、成熟时间与发版门槛见：

`docs/US-GB-增长闭环-下一版本产品与数据迭代计划.md`

本 SOP 中的 `install→trial≥20%`、`install→paid≥7%`、CAC≤¥329 是首年跑通保底线，不等于可扩量。若安装 CPA 恰为¥23、trial→paid 为35%，要达到扩量 CAC≤¥263，必须达到：

```text
install→paid ≥ 8.75%
install→trial ≥ 25%
```

若 install→trial 只能保持20%，则安装 CPA 必须进一步降到约¥18.4。所以下一版本内部运营目标采用 72h 绑定/导入≥35%、install→trial≥25%；原 20% 与 7% 保留为失败红线和首年打平线。
