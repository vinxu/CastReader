# US / GB Apple Ads 增长闭环数据目标与拉数 SOP

> **当前投放状态（2026-09-27 13:10 CST）：用户明确指示“美国暂停，英国继续投放”。英国 Discovery（2144503591）已恢复并独立回读为 ENABLED / RUNNING，日预算 RMB120；其探索组和 Kindle Exact 组均 RUNNING，预算、出价、关键词和否定词保留。美国 Discovery（2144343127）和旧 Exact（2144344391）继续 PAUSED / NOT_RUNNING，其他国家仍暂停。执行证据：[9/27英国恢复](../reports/apple-ads/2026-09-27-resume-gb/README.md)。英国 9/27 为恢复混合日，9/28 为首个完整账户日；恢复后 cohort 单列。9/17 10:54 的停投及其截断的 9/15–17 实验保留为历史，不与本轮恢复混算：[9/17获客暂停](../reports/apple-ads/2026-09-17-pause-acquisition/README.md)。**

> **最新调整（2026-10-13 11:32 CST）：用户授权执行本轮英国建议。Broad `listen to kindle books` Max CPT 10→8、`reading assistant` 10→7；新增 campaign EXACT negative `kindle`。独立回读及全资源差异检查通过。英国仍 RUNNING / RMB120 日预算，Search Match 默认价与其他资源不变。美国两个 Campaign、加拿大仍 PAUSED，澳大利亚尚无 Campaign；三国扩展仅讨论，未开启。10/13 为混合日，10/14 为首个完整账户日。详见第 16 节和[执行验证](../reports/apple-ads/2026-10-13-gb-adjustment/verification.json)。**

> **上轮调整（2026-10-02 21:50 CST）：用户授权“好 做调整”。英国 Broad `epub reader` Max CPT 10→8、`ebook reader` 8→6.40；新增 campaign EXACT negatives `whats app`、`boom reader`、`boomreader parents`、`kindle app for iphone`。独立回读及全资源差异检查通过。英国仍 RUNNING / RMB120 日预算，美国两个 Campaign 仍 PAUSED；Search Match 默认价、其他词和 Kindle Exact 出价/分流不变。10/2 是调整混合日，10/3 为首个完整账户日。详见第 15 节和[执行验证](../reports/apple-ads/2026-10-02-gb-adjustment/verification.json)。**

> 生效日：2026-08-23
> 最新路由变更：2026-09-09 10:24 CST（新增 US / GB Exact 广告组与组级否定分流，详见第 12 节）
> 当前路由实验切点：2026-09-10 00:00（Asia/Shanghai，UTC+8）；历史累计仍从 2026-08-24 起，不混作本轮效果。
> 最新出价实验：2026-09-11 10:44（Asia/Shanghai），US / GB 各 1 个 Exact 词显式出价改为 RMB10；完整观测日 9/12–9/13，详见第 13 节。9/6 历史出价实验保留于第 11 节。
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

后续发布基线更新（2026-09-04 03:47 UTC）：核心服务任务已将增长修复合入 `2d5575b6`，并报告部署为 `dpl_2CmzKBRfAMhhKYiVF6DwUjnakPRn`。本地 Git 已核对：`4720b4cf` 是该 merge commit 的直接父提交，增长事件入库、聚合、花费采集、两个 cron handler 均无代码差异，cron 配置保留。后续部署须从包含 `2d5575b6` 的生产基线继续，保留 TTS/QuickRead 两区修复；不得直接重部署本增长隔离分支旧 runtime。核心服务源码工作树为 `/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-core-audio-regional-continuity`。

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

## 11. 当前已执行：2026-09-06 分词降价实验

用户批准策略后，于北京时间 2026-09-06 09:23 完成以下两项，并通过 Apple Ads 独立 GET 回读：

| 国家 | Campaign / Ad Group / Keyword ID | Broad 关键词 | Max CPT |
|---|---|---|---|
| US | 2144343127 / 2149992107 / 2297161990 | listen to kindle books | RMB 10 → 8 |
| GB | 2144503591 / 2150470773 / 2303076128 | ebook reader | RMB 10 → 8 |

本轮仅调整以上两词。两国日均预算仍各 RMB 120，Search Match 与默认出价 RMB 10、其他词、否定词、状态和国家均不变。未执行 GB listen to kindle books → RMB 9 的可选项；Exact / 否定词方案等待本轮数据后另作一轮。第 9 节预算 RMB 60 是 8/23 的历史记录，不是当前预算。

下次拉数必须同时保留两个视角：

1. **9/6 出价实验（已被后续路由实验截断）**：排除 9/6 混合日，从 9/7 00:00 Asia/Shanghai（9/6 16:00 UTC）开始；对照 8/31–9/5 当前预算基线。原计划三日 9/7–9/9、七日 9/7–9/13；因 9/9 10:24 新增 Exact 路由，这两段不再是纯出价实验。只有 9/7–9/8 为完整未混入新路由的出价日，9/9 为混合日。按实际天数与星期结构解释点击量，不能直接比较不等长窗口总量，也不能把后续新增 Exact 效果归因于 9/6 降价。
2. **完整增长 cohort**：历史 8/24 起累计和首次 build 分层仍保留；设备继续按 UTC received_at / fresh_install 和成熟分母，不把 9/7 广告出价切点当产品版本切点，不将 ORTZ 同日期的 ASA 全量与设备子集混算。可信财务认证仍需 UTC 日事实与完整性滞后。

快捷报表曾将 totalInstalls / taps 标成 tap→install。本轮分析已直接读取 Apple 原始字段；后续点击转化率必须使用 tapInstalls / taps，浏览归因及 totalInstalls 分列，点击安装 CPA 与总安装 CPA 分列。旧标签尚未在本轮修改代码，不能原样引用。UNKNOWN keywordId 也不能直接当作 Search Match；广告搜索词来源用 Apple searchTermSource 分类。

调整后每国×词×match 至少 20 taps 或 5 安装再判断表现；样本不足只看方向，不每日连续调价。核对实际 CPT、点击安装率、安装 CPA 和真实激活/试用质量，不承诺降价后安装数不降。维持不扩量及成熟正价 CAC 门槛。本节仅记录已获授权动作与读取口径，不授权未来自动改价或自动化监控。

完整审计：[2026-09-06 出价执行与验证](../reports/apple-ads/2026-09-06-bid-adjustment/README.md)。

## 12. 当前已执行：2026-09-09 Exact 意图分流

用户授权“先推进出价和投放的调整，产品先出需求”。北京时间 2026-09-09 10:21 创建暂停组和关键词，10:24 启用并完成原组否定分流。Campaign 不变、两国日均预算仍各 RMB 120，不启用旧 US Exact Campaign。

| 国家 | 新广告组 ID / 名称 | Exact 关键词（每词显式 Max CPT） |
|---|---|---|
| US | 2150932283 / US Exact Own Content 20260909 | read aloud app；listen to pdf；pdf text to speech；scan text and read aloud：均 RMB 7 |
| GB | 2150932284 / GB Exact Kindle 20260909 | kindle read aloud；kindle text to speech；listen to kindle books；read kindle books aloud：均 RMB 8 |

新组均 Search Match 关闭、iPhone only、无 CPA goal；组默认出价与关键词显式出价一致。原 Broad / Search Match 组维持原状态、默认出价与关键词出价，包括 9/6 两词 RMB 8。

否定分流：仅暂停 US campaign-level EXACT negative `read aloud app`（2317144174）、`scan text and read aloud`（2317144299），其他 campaign negatives 不变。US 原组 2149992107 新增四个对应词 + `audible` 的 EXACT negatives；GB 原组 2150470773 新增四个对应词的 EXACT negatives。新 Exact 组无组级否定；不在 campaign 层屏蔽新词，不对 GB 添加 audible，不 Broad 否定 kindle。

这是一轮“意图分流 + US audible 排除”的组合实验，不能独立识别两项的因果贡献；audible 曾带来安装，排除是意图假设，不是已验证没有价值。Exact 分流可能减少旧组点击；新组低竞价可能无量。单 campaign 内广告组共享预算，没有组级硬配额，不能宣称固定花费比例。

读取与判断规则：

1. 9/9 为混合日，仅作运行审计；首个完整效果日 **9/10 Asia/Shanghai**。三完整日 9/10–9/12 最早 9/13 D+1 看方向，七日 9/10–9/16 最早 9/17 看完整获客。未成熟/不足样本不硬下结论；没有设置每日监控或自动改价。
2. 每国必须读取两个组，按 campaignId × adGroupId × keywordId × matchType 对比新 Exact 与原探索组；Search Term 使用 Apple searchTermSource，不用 UNKNOWN keywordId 猜 Search Match。原快捷报表 campaign 级拉取不限定旧组，但 normalize/top10 不保留完整组/关键词 ID，因此必须保留原始分页明细，不能用快捷摘要替代实验表。
3. 20 taps 或 5 点击安装/词可初看获客，30 广告安装/国才初看激活，均给人数与不确定性。无量先查状态、否定冲突、匹配与实际展示，再提议调价；不自动抬到 $2.5，不自动提高预算。
4. 点击安装率用 tapInstalls/taps，totalInstalls 和浏览归因单列；生产设备仍走 UTC fresh-install / 首次 build / 成熟度规则，不能直接拿账户日期与 UTC 同名日期混算 coverage/CAC。新 adGroup 不得从摄入或查询中被旧白名单丢掉。
5. US 归因质量未达标时保留 UNKNOWN 门；改善目标实际 CPT≤$1.20、点击安装≥40%、安装试用先10%再20%、同 cohort 成熟试用转正≥30% 只是本轮里程碑。历史 ≥35% 转正、≥7% 安装付费及 CAC≤¥329 / 扩量≤¥263 等经济验收门不放宽。$50–65 高于 US 首年净 LTV，不等于可扩量。

产品只交接需求，不在本轮实现或发布：[首次价值与试用转化产品需求及验收](./US-GB-首次价值与试用转化-产品需求与验收-2026-09-09.md)。产品首次 build 切点必须另记，不能拿广告切点代替。

完整执行与回读证据：[2026-09-09 Exact 路由审计](../reports/apple-ads/2026-09-09-exact-routing/README.md)。本节不授权后续自动修改、监控或扩量。

## 13. 当前已执行：2026-09-11 两词 Exact 竞价探测

用户批准“每国只选择1个现有Exact词改为¥10，观察两个完整日，其他不变”的小实验。北京时间9/11 10:44执行：

| 国家 | Campaign / Group / Keyword ID | Exact 词 | 显式 Max CPT |
|---|---|---|---|
| US | 2144343127 / 2150932283 / 2309512511 | read aloud app | RMB7 → 10 |
| GB | 2144503591 / 2150932284 / 2309509917 | kindle read aloud | RMB8 → 10 |

选择理由：各保留一个较短、直接描述当前TTS任务的现有Exact作诊断词；不是宣称已验证高搜索量或高转化。Apple建议价均null，因此RMB10只是与原探索组默认价对齐的试验档位，不是市场建议价，也不保证获得展示。

不变项：两campaign日均预算仍各RMB120；新Exact组默认价US7/GB8；剩余6个Exact分别保持US7/GB8；原Broad组默认/显式出价、所有Search Match开关、定向、状态与全部否定词均不变。没有新增关键词，没有修改产品或部署，没有创建定时监控/自动回退。

观测与解释：

1. 9/11为本轮提价混合日；**两个完整效果日是9/12与9/13 Asia/Shanghai，最早9/14读取D+1方向结果**。9/12可先看今日9/11混合日运行状态，但不得当完整实验日。
2. 9/9路由首个完整日9/10继续保留。原计划9/10–9/12三完整日现在混入9/11提价，不能再称为未变出价的纯路由实验；只有9/10是全日原起价的新路由数据。其余6词虽然显式价不变，也共享campaign预算，不作为严格随机对照。
3. 首要指标是测试词展示、点击、实际CPT，其次点击安装率与点击安装CPA；每个国家×adGroup×keyword×match分开。没有展示不能评判安装/试用转化；有少量展示不构成扩量证据。
4. 若提价词开始获得展示，说明竞价可能影响可获流量，仍需考虑时间/需求变化，不宣称因果确定。若仍零展示，优先核查实际搜索需求与相关性，不连续自动提价。
5. 若产生点击但没有安装，CPA为无有限估计，不报¥0；若有安装但样本低于20taps或5安装，仅作方向信号。install→trial/paid继续遵守UTC、fresh-install、首次build、成熟度和身份质量门。
6. 无论测试结果如何都不自动加总预算；试验后恢复原价或继续调整必须另行获得用户授权。本段日期是复盘口径，不是定时任务。

执行回执及独立资源回读：[9/11两词竞价探测](../reports/apple-ads/2026-09-11-exact-bid-probe/README.md)。

## 14. 当前已执行：2026-09-14 US Search Match 受控降价

北京时间10:17:45，仅US原探索组2149992107的默认Max CPT从RMB10降到8，Search Match保持开启。该组15个活跃手动关键词均有显式价，全部不变；两国Exact、GB全部资源、全部负词和两campaign日均预算各RMB120不变。独立回读2campaign、4组、53关键词及全部负词，只有默认价与修改时间变化。

9/14是混合日；完整观察日9/15–17，最早9/18读D+1方向。按Search Term source=AUTO拆分，不混同手动Broad；样本门仍20点击或5点击安装。无量/无安装不报0元CPA，不将浏览安装混入tap→install。若AUTO20点击仍0点击安装，或至少5点击安装而CPA仍>RMB35，只触发进一步收紧建议，不能自动暂停、回退或加价；没有创建每日监控。

9/12–13两个完整日Exact探测结果为零展示，已经完成既定观察窗口，不再称为“尚未等满两日”。两词¥10暂保持，不连续自动抬价；后续需需求/相关性与可投诊断依据。新增产品修复当前只是隔离候选，未发布，不能归因本次广告结果为产品改善。

执行与验证：[9/14 US Search Match受控降价](../reports/apple-ads/2026-09-14-us-searchmatch-cpt/README.md)。

## 15. 已执行：2026-10-02 英国广泛匹配收紧

用户在 10/2 英国复盘和成本归因后明确授权“好 做调整”。本轮是两词降价与四条精确否定组合调整，不是独立随机实验；不将随后效果完全归因于某一个动作。

北京时间 21:50:17 完成出价写入，21:50:21 完成否定词写入，21:50:35 完成独立 GET 回读。Campaign 2144503591、原探索组 2150470773：

| Broad 关键词 | Keyword ID | Max CPT（RMB） |
|---|---:|---:|
| epub reader | 2303076127 | 10 → 8 |
| ebook reader | 2303076128 | 8 → 6.40 |

两词均降 20%，保持 ACTIVE。它们占 9/28–10/1 已观察花费约 56.5%；本轮减少竞价强度，不保证花费或安装成本也按比例下降，不通过降低组默认价假装覆盖显式关键词价。

新增 campaign 层 EXACT negatives：

| 查询 | Negative ID | 9/28–10/1 花费 / 点击 / 点击安装 |
|---|---:|---|
| whats app | 2347433125 | RMB1.79 / 1 / 0 |
| boom reader | 2347433126 | RMB9.61 / 1 / 0 |
| boomreader parents | 2347433127 | RMB8.07 / 1 / 0 |
| kindle app for iphone | 2347433128 | RMB30.52 / 4 / 0 |

这四条合计约 RMB49.99、7 点击、0 安装。前三项按通讯/学校阅读记录的非目标任务排除；`kindle app for iphone` 按品牌导航意图做排除试验，但历史上确实带来过安装，不声称其永久无价值。只精确否定这四个查询，不 broad 否定 kindle，也不屏蔽已带安装的 audible / libby。精确否定不保证所有近似变体一起被挡住。

其他设置：英国日均预算仍 RMB120，Search Match 开启且默认 Max CPT RMB10；其余 Broad、四个 Kindle Exact 及原否定分流不变。美国两个 Campaign 和其他国家保持暂停。全账户 Campaign 与英国组/关键词/否定词的前后差异检查，只发现上述计划内变化及 Apple 修改时间等派生字段。

Exact 复查：Campaign/组 RUNNING、四词 ACTIVE；无结束日期、daypart 或 CPA goal；与有量探索组同为 iPhone 定向；campaign+Exact 组未发现字面否定冲突。两组 Ads 列表均为空，而探索组有真实展示，不能据此认定 Exact 缺广告。零展示的需求、相关性和竞价成因仍未分离，本轮不再提价。英国公开商店文案也已只读检查，标题包含 Read Aloud Books，描述开头强调 Safari/设备支持；文案排序与广告任务匹配是后续假设，不把它认定为已证实的低转化原因，本轮未修改商店内容。

复盘口径：10/2 为混合日，10/3–10/5 为最初三个完整账户日，10/6 起可人工拉取 D+1 方向结果；仍需注明归因回补。优先看各词实际 CPT、点击安装 CPA、AUTO/Broad 分量及安装后的首次有效使用，至少 20 点击或 5 点击安装后再对单词做较稳定初判；低样本不每日连续改价。D10 正价与身份/花费完整性门保持不变。该日期安排只定义后续观察窗口，未创建自动复盘、自动调整或暂停任务。

证据：[计划](../reports/apple-ads/2026-10-02-gb-adjustment/plan.json)、[执行验证](../reports/apple-ads/2026-10-02-gb-adjustment/verification.json)、[诊断](../reports/apple-ads/2026-10-02-gb-adjustment/diagnostic.json)、[调整前快报](../reports/apple-ads/2026-10-02-gb-followup/summary.json)。原始前后快照和逐次请求/响应日志保存在同目录；没有删除资源。

## 16. 已执行：2026-10-13 英国成本反弹收紧

用户在看到 10/10–10/12 关键词拆解及具体建议后指示“调整 和讨论是不是应该把美 澳 加 这三个地区也加上？”。本轮执行既定英国调整；美国、澳大利亚、加拿大仅作扩展讨论，未新增或恢复投放。

北京时间 11:32:57 完成两词出价写入，11:32:59 完成精确否定写入，11:33:04 完成独立 GET 回读与全资源差异验证。Campaign 2144503591、探索组 2150470773：

| Broad 关键词 | Keyword ID | Max CPT（RMB） |
|---|---:|---:|
| listen to kindle books | 2303076135 | 10 → 8 |
| reading assistant | 2303076130 | 10 → 7 |

新增 campaign 层 EXACT negative `kindle`（ID 2352209154，ACTIVE），仅排除该完整查询，不采用 Broad negative，以保留 `kindle read aloud` 等较长任务词。英国预算继续 RMB120/日，Search Match 默认价 RMB10，其他 Broad、Exact 与既有否定分流不变。美国两个 Campaign 与加拿大仍暂停，澳大利亚尚无 Campaign。

调整依据：账户日 10/10–12 花费 RMB331.22、47 点击、5 点击安装，CPI RMB66.24；此前 10/3–9 CPI RMB27.06，整体 CPT 从 RMB7.33 降至 RMB7.05，反弹主要体现为安装率下降。两项降价词占最近三天花费 48.2%；`reading assistant` 十天只有 10 点击、1 安装，降价为控制风险，不宣称低样本已证明关键词无效。具体搜索词未披露的花费占 69.6%，不能将其编造为已知查询。

本轮为两词降价与精确否定的组合调整，不是随机实验。10/13 排除为混合日，首批完整观察日 10/14–16，最早 10/17 读取 D+1 方向结果并注明归因回补；单词达到 20 点击或 5 点击安装再作较稳定初判。先观察实际 CPT、点击安装率和 CPI 是否向反弹前水平恢复，不能将该参考水平当作英国盈利阈值。下游仍按同 cohort 的 72h 使用、D10 正价与完整性门判断；没有安排自动复盘或后续自动改价。

证据：[调整前分析](../reports/apple-ads/2026-10-13-cost-rebound/analysis.json)、[执行计划](../reports/apple-ads/2026-10-13-gb-adjustment/plan.json)、[独立验证](../reports/apple-ads/2026-10-13-gb-adjustment/verification.json)。前后资源快照与逐次写入记录位于同一执行目录。
