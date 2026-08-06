# CastReader Apple Ads 14 天托管

## 范围

- App：CastReader（Apple ID `6757636395`）
- 账户币种：RMB
- 目标市场：US、JP、DE、BR、IT
- 日均预算合计：不超过 ¥200
- 测试周期：2026-07-28 启动，统一结束于 2026-08-10 17:59 UTC（北京时间 2026-08-11 01:59）
- 计划金额上限：¥2,800
- 广告位：App Store 搜索结果
- 出价策略：Manage Bids / Manual CPT

Apple Ads 的 daily budget 是整月的日均预算，单日实际花费可能高于该值。正式启动时，六个广告系列必须使用同一个 14 天结束时间，防止测试结束后继续自动消耗。

## 初始结构

| 广告系列 | 市场 | 日预算 | 初始策略 |
|---|---:|---:|---|
| `CR_US_Search_Exact_2026Q3` | US | ¥100 | 30 个高意图长尾词，Exact |
| `CR_US_Search_Discovery_2026Q3` | US | ¥60 | Search Match + 12 个 Broad 种子词 |
| `CR_JP_Search_Local_2026Q3` | JP | ¥10 | 日语 Exact + Search Match |
| `CR_DE_Search_Local_2026Q3` | DE | ¥10 | 德语 Exact + Search Match |
| `CR_BR_Search_Local_2026Q3` | BR | ¥10 | 巴葡 Exact + Search Match |
| `CR_IT_Search_Local_2026Q3` | IT | ¥10 | 意大利语 Exact + Search Match |

竞品词（包括 Speechify、Natural Reader）只做否定词，本轮不投放。

## 启动状态

2026-07-28，用户明确授权不等待 1.2.14 审核完成，以线上 1.2.13 立即开始广告预热。启动前已确认：

1. 六个广告系列、广告组、关键词及否定词完整。
2. 所有对象的市场均在授权列表内，计划日预算合计不超过 ¥200。
3. `APP_NOT_CATEGORIZED`、`NO_PAYMENT_METHOD_ON_FILE`、`TAX_VERIFICATION_PENDING`、`APP_NOT_ELIGIBLE` 等阻塞消失。
4. 六个广告系列与广告组均已启用，并设置共同结束窗口。

最终回读状态：

- US Exact、US Discovery、JP、DE、IT：`ENABLED / RUNNING`。
- BR：`ENABLED / ON_HOLD`，原因是 `APP_LANGUAGE_INCOMPATIBLE` / `NO_ELIGIBLE_COUNTRIES`。ASC 只读回查确认 1.2.13 与 1.2.14 都已有完整 pt-BR 文字元数据，但 pt-BR locale 各自均为 0 个截图集、0 张截图；这与警告完全吻合。警告存在期间不会展示或产生花费。
- BR 不阻塞其他市场，也不延长本轮周期。每天复查；兼容性警告解除后应自动转为 `RUNNING`。

## 日常动作

每天拉取前一完整结算日与滚动 3/7 日数据：

- Campaign
- Ad Group
- Keyword
- Search Term

主要指标：

- Spend、Impressions、Taps、TTR、Average CPT
- Installs、Conversion Rate、CPA
- New Downloads、Redownloads

调整规则：

- 前 3 个完整投放日以学习为主。
- 明显无关且产生浪费的查询加入 Exact Negative。
- 有稳定安装且 CPA 合理的 Discovery 查询晋级 Exact，并在 Discovery 做精确否定分流。
- 单个关键词每次调价不超过 20%。
- 调整后总日均预算仍不得超过 ¥200，也不得新增国家或地区。

## 自动化与文件

- API 客户端：`scripts/searchads_api.rb`
- 初始计划：`scripts/searchads_campaign_plan.json`
- 幂等建单：`scripts/setup_searchads_campaigns.rb`
- 安全启动：`scripts/launch_searchads_campaigns.rb`
- 日报与调词：`scripts/searchads_daily_ops.rb`
- 日报输出：`reports/apple-ads/`（仅本机，不提交 Git）

默认日报命令是只读的：

```bash
ruby scripts/searchads_daily_ops.rb
```

只有显式加入 `--apply` 才会执行脚本护栏允许的关键词、否定词和出价调整。该脚本没有启停广告系列、修改预算、修改市场或国家的写接口。

## 衡量边界

当前客户端尚未实现 AdServices 安装归因，因此本轮可以可靠下钻到关键词的指标是曝光、点击、安装、CPA 和搜索词质量；App Store Connect 的试用开始及付费变化只能作为整体趋势参考，不能归因到某个关键词。

另外，7 天免费试用意味着测试后半段获取的用户在第 14 天尚未全部完成转正。本轮首先判断获客效率和早期试用意愿；完整付费转化应在最后一批试用结束并留出报表延迟后补看。
