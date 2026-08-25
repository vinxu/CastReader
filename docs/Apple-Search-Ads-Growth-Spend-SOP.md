# Apple Search Ads → Growth Spend / Coverage SOP

## 目的与边界

`scripts/searchads_growth_spend_export.rb` 将 CastReader 的 Apple Search Ads **运营报表**转换为后端 growth 数据合同：

- 按 `marketing_country` 生成 `/api/admin/growth/import/spend` payload；
- 对同一国家、同一 UTC 单日、同一 source SHA 生成 `/api/admin/growth/import/coverage` payload；
- 为 CPA、付费 CAC 的广告成本分子提供可审计事实。

该脚本**只解决 ad spend / CPA**。它不读取 App Store 交易，也不能证明净收入或 LTV。`net proceeds`、退款/撤销、税费与可变成本仍须分别通过 financial/cost 权威事实导入，之后才能判断 `contribution LTV > CAC`。

Apple campaign report 不是财务 settlement 文件，响应中也没有本链路可依赖的 final 标志。因此 coverage 使用保守完整性策略：UTC 单日完整结束后继续等待 **72 小时**。未跨过该门槛的日期直接失败，不生成任何 coverage 文件。

## 安全保证

- Apple 侧只调用 `GET /api/v5/campaigns` 和只读的 `POST /api/v5/reports/campaigns`；不会修改 campaign、预算、国家、关键词或出价。
- 默认只生成本地 `dry_run=true` 文件，不请求 growth 后端。
- 后端请求只接受独立环境变量 `GROWTH_ADMIN_SECRET`，不回退到 cron、Apple 或其他密钥；token 不写文件、不写日志。
- `--post` 只提交 spend dry-run。因为 dry-run 不落事实，coverage 无法反查，所以不会 POST coverage。
- 只有显式同时传入 `--post --commit` 才会先提交所有国家 spend，再提交 coverage。
- 脚本本身不应加入自动上传生产的 cron；人工复核 source、金额、范围后再 commit。

Apple API 凭据沿用现有只读客户端：

```text
~/.searchads/config.json
~/.searchads/private-key.pem
```

输出和错误中不会出现 access token、私钥或 `GROWTH_ADMIN_SECRET`。

## 完整导出

### 1. 选择可覆盖日期

默认选择“当前 UTC 时间往前 72 小时之前，最近一个完整结束的 UTC 日”。也可显式指定：

```bash
ruby scripts/searchads_growth_spend_export.rb --date 2026-08-20
```

不要把昨天或仍处于平台数据延迟期的日期称为 settled；脚本会拒绝这些日期。

### 2. 本地检查

输出目录结构：

```text
reports/apple-ads-growth/<YYYY-MM-DD>/<run UTC timestamp>/
├── manifest.json
├── apple-ads-<date>-us.source.json
├── apple-ads-<date>-us.spend.json
├── apple-ads-<date>-us.coverage.json
└── ...每个计划国家三份文件
```

`source.json` 是完整的该国 campaign 日报输入，包含零花费 campaign 行。它经过 key 排序和 campaign ID 排序后写入；`source_file_sha256` 是对该文件**实际字节**计算的 SHA256。相同事实即使 API 分页或返回顺序改变，source SHA 也保持一致。

逐国确认：

- `provider_account_id` 等于 Search Ads `orgId`；
- `adam_id=6757636395`；
- 每个 campaign 的 ID、名称、国家都来自只读范围清单 `scripts/searchads_growth_export_scope.json`；该文件与会改预算/关键词的运营 plan 分离；
- Apple `RMB`/`CNY` 统一写成 ISO `CNY`；
- Apple 原始小数金额先与 `grandTotals` 精确对账，再按每个 campaign 行 `half-up` 到 CNY 分；`currency_minor_exponent=2`、`fx_rate_micros=1000000`、`spend_minor=spend_cny_fen`，可精确复算；
- `impressions` 原样写入，Apple `taps` 映射为 `clicks`；`totalInstalls` 只保留在 source 审计文件用于渠道对账，不冒充后端 install cohort；
- coverage 使用 UTC `[date 00:00Z, next date 00:00Z)`，行数和 CNY 分合计与 spend 文件一致。

### 3. 后端 dry-run

用安全方式在当前 shell 注入独立 admin secret，然后执行：

```bash
ruby scripts/searchads_growth_spend_export.rb \
  --date 2026-08-20 \
  --post
```

这一步只 POST `dry_run=true` spend。成功后仍不会写增长事实，也不会提交 coverage。

### 4. 人工复核后 commit

```bash
ruby scripts/searchads_growth_spend_export.rb \
  --date 2026-08-20 \
  --post \
  --commit
```

commit 顺序固定为：

1. 所有国家的 spend；
2. 只有全部 spend 均被接受后，才逐国提交 coverage。

接口和 source SHA 都是幂等的。网络中断时保留本次输出，核对后可重放同一命令；不要编辑 source 文件后继续复用旧 SHA。

## Fail-closed 门禁

以下任一情况都会终止整次构建，且原子输出目录不会出现 coverage：

- Apple API HTTP/JSON/error envelope 错误；
- campaign 列表或 report 任一分页缺页、重复、总数变化、超过页数上限；
- report 明细无法与 Apple `grandTotals` 对账；
- CastReader adamId、org、campaign ID、campaign name 对不上；
- 计划外 CastReader campaign，或计划 campaign 缺失/ID 改变；
- campaign 不是单一明确国家、国家与 plan/report 不一致；
- 非人民币账号/报表币种，金额小于分的精度，负数或溢出；
- campaign 日报重复维度，即使重复行内容相同；
- `returnRecordsWithNoMetrics=true` 后仍缺任何计划 campaign 行；
- API 返回零行日。零**花费**日必须仍返回每个计划 campaign 的明确 `0` 行，不能把“没有取到数据”伪装成“零花费完整覆盖”；
- UTC 日结束不足 72 小时。

后端 commit 时若任何 spend API 调用失败，脚本不会开始提交 coverage。若 coverage 阶段发生网络中断，后端按每个国家独立 fail-closed；用相同 source 文件幂等重放并逐 scope 核对。

## 测试

Fixture 覆盖分页、顺序稳定哈希、US/JP 拆分、零花费 campaign、CNY 恒等换算、延迟门禁、计划外 campaign、国家/币种错误、重复维度、API/分页失败，以及“spend 未全部成功绝不 POST coverage”：

```bash
ruby scripts/test/searchads_growth_spend_export_test.rb
```

语法检查：

```bash
ruby -c scripts/searchads_growth_spend_export.rb
```
