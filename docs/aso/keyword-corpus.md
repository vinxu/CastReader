# ASO 词库（活资产，随数据滚动更新）

> 更新纪律：每周一跑 `python3 scripts/aso_rank_snapshot.py` 回填「排名」列；ASA 搜索词报表每周捞一次回填「ASA 展示/CVR」；每次发版前按本表重新分配字段。词表改动同步改 snapshot 脚本的 TERMS。
> 字段分配原则：**同一 token 不跨字段重复**；名称>副标题>关键词字段>（es-MX/zh-Hans 的美区扩容位）；ASA 验证过转化的词才有资格升仓。

## 美区（en-US 主战场 + es-MX/zh-Hans 扩容位）

| 词 | 意图簇 | 排名 07-29 | ASA 展示 | ASA CVR | 当前字段位 | 决策 |
|---|---|---|---|---|---|---|
| text to speech | 大词 | >100 | — | — | v2 副标题 | 长期爬，靠速度权重 |
| read aloud | 大词 | >100 | — | — | 名称 | 同上 |
| listen to pdf | 场景 | >100 | — | — | 组合（listen+pdf） | ASA Exact 主投 |
| pdf to audio | 场景 | >100 | — | — | 组合 | ASA Exact |
| pdf reader aloud | 场景 | >100 | — | — | 组合 | ASA Exact |
| listen to articles | 场景 | >100 | — | — | 组合（article） | ASA Exact |
| kindle read aloud | 场景 | >100 | — | — | 不入元数据（商标） | 仅 ASA |
| dyslexia reading app | 人群 | >100 | — | — | kw 字段（dyslexia） | 无障碍叙事主词 |
| adhd reading app | 人群 | 未跟踪 | — | — | kw 字段（adhd） | 下轮加入跟踪 |
| ai explain reader | 自有 | **#1** | — | — | 名称+组合 | 守住即可 |
| text reader | 大词 | >100 | — | — | 组合 | 观察 |

## 滩头市场（首批数据已见 Top100，优先攻）

| 市场 | 词 | 排名 07-29 | 打法 |
|---|---|---|---|
| GB | read aloud | **#50** | en-US 元数据直接覆盖；ASA 加 GB 只需复制 US Exact（同语言零成本）|
| IT | lettura vocale | **#62** | v2 关键词已含 lettore/voce；IT ASA ¥10/天已在跑 |
| ES | lector de pdf voz | **#64** | v2 kw 已含 lector/leer；考虑 ASA 加 ES |
| BR | texto em voz | **#82** | 名称自带 token；**注意 BR 无 ASA**，只能靠元数据+自然速度 |
| JP | pdf 読み上げ | **#86** | v2 副标题改成「PDF・Web・本を音声で聴く」正中此词；JP ASA 在跑 |

## 其余市场追踪词

见 `scripts/aso_rank_snapshot.py` 的 TERMS（de/fr 全部 >100，等 de-DE 商店页随 1.2.15 新建后再评估——德区目前根本没有德语列表，排名为零是应然）。

## ASA 出价阶梯实验（2026-08-01 起，读数 08-04）

背景：投放 6 天 ¥0 消耗、US Exact 零展示 → 目标从「买装机」改为「买信息」，用阶梯找美区真实竞价地板。

- **¥12 档**（10 词）：listen to pdf / pdf to audio / pdf reader aloud / text to speech pdf / pdf text to speech / read aloud app / listen to articles / listen to documents / document reader aloud / audiobook from pdf
- **¥8 档**（10 词）：read documents aloud / article reader aloud / epub reader aloud / ebook reader aloud / ai read aloud / web page reader aloud / website text to speech / reading assistant / dyslexia reading app / pdf audio reader
- **¥6 档**（对照组 10 词，用户先前手动调过）：study/academic/research/adhd/kindle 系等
- 同时：Discovery ¥3→¥5、JP/DE ¥2.5→¥4、新建 ES ¥10/天（id 2144375920）、BR 暂停、全部去 end date
- **读数口径（08-04）**：哪档开始出展示 = 地板位；看展示量/TTR/搜索词条数，**不看 CPA**；1.2.14 上线后 72h 相关性重算再读一次

## 点点数据全量覆盖分析（2026-08-05 导出，220 词）

美区覆盖 220 词，其中**流行度 ≥25 的真实流量词 35 个**，分带：

| 带 | 词数 | 关键成员 |
|---|---|---|
| **Top10 收割区** | **0** | ——最大缺口：所有流量潜力都锁在门外 |
| 11–30 脉冲推进区 | 7 | eleven reader #13(52)、read aloud free #18(40)、text reader #26(30)、read aloud #28(45)、**epub reader #29(45)**、novel effect #30(49) |
| 31–80 可爬区 | 8 | **reading #31(55)**、ebook reader #35(45)、learn to read #48(49)、book reader #59(43)、read text aloud #61(33) |
| 81+ 长尾区 | 20 | **kindle reader for iphone #131(53)**、book reading app #127(51)、kobo books reading app #188(47)、听书 #105(39)、tts #200(41) |

四个战略发现：

1. **`听书` 在美区 #105** —— zh-Hans 关键词字段被美区索引的机制被数据实锤（v2 设计验证成功）。
2. **`kindle reader for iphone` 流行度 53 排 #131**：Kindle 是我们真实差异化功能，但 "kindle" token 不在关键词字段（当时避商标）。**1.2.16 建议加入**——功能真实存在，描述性使用，风险可控（元数据被拒仅需重提）。
3. **`kobo books reading app` 流行度 47**：Kobo 功能 1.2.15 刚上线，"kobo" token 名正言顺。
4. `epub reader` #29 流行度 45 是脉冲推进区里**分/量比最好**的类目词。

### 1.2.16 en-US 关键词字段提案（91 字符 ✓）

```
tts,listen,audiobook,voice,reader,ocr,epub,ebook,book,kindle,kobo,novel,dyslexia,adhd,study
```

变更：+kindle +kobo +novel（均有覆盖数据佐证）；−scan（ocr 覆盖）−article −document（覆盖表中无对应真实流量组合；ASA 长尾不依赖元数据 token）。

### ASA 侧记（2026-08-04 执行）

- 三词探针 ¥20（listen to pdf / read aloud app / pdf to audio），48h 定美区付费生死
- 竞品词 adgroup「US Competitor Probe」¥8：eleven reader / elevenreader（自然 #13 → 相关性分应不低）
- DE ¥25/天（CPT ¥1.6 已验证）、JP ¥20/天
- ⚠️ 后台人工变动记录：ES 被暂停、BR 被重新启用（与 08-01 设置相反）；US Exact 被人工加了 8 个 ¥6 词（38 词总量）——¥6 在美区永远不会展示，无害但占报表

## 2026-08-05 读数：美区付费定案 + 自然排名多点爬升

- **¥20 探针 + 竞品词组 48h 零展示 → 美区正面竞价正式搁置**：$2.8 CPT 仍进不了场，账号冷启动（评分 3 条、无付费历史）压低相关性分。探针词保持 ¥20 挂着（评分涨起来后可能解锁），不再加价拉锯；重启条件 = 美区评分 30+。
- **自然排名是当前唯一在增长的曝光引擎**（API 视角，趋势口径）：us `ebook reader` **#26**、`aloud reader` #33；gb `pdf reader aloud` **62→39**；**br `ouvir pdf` 75→51 / `texto em voz` →67——巴西零投放纯元数据爬升**，证明发动机是 v2 元数据+自然复利，不是广告。
- 评分 1 → **3 条**（avg 5.0），创始人渠道起效，继续推向 30。
- 测量口径再确认：iTunes API（本脚本）与点点数据绝对值有偏差，**点点为准，本脚本只看趋势**。

## 2026-08-06 事故记录：1.2.16/1.2.17 关键词字段回退

1.2.16/1.2.17 提交时关键词被按旧来源重写，**10/11 locale 偏离目标**（仅 es-MX 幸存）。重点损失：
zh-Hans 美区扩容尾巴全删（`听书` 美区 #105 的机制被拆）、ja 丢 9 个主力 token 且剩余 token 与名称/副标题重复、
hi 回退到 44/100。en-US 的 kindle/kobo/novel 增补也未上车。

**防线（本日起生效）**：
- 唯一真相源 `docs/aso/approved-keywords.json`（当前 v3-1.2.18：v2 全量恢复 + en-US 增 kindle/kobo/novel、ja 增 Kindle、de 增 kindle）
- 漂移检查 `ruby scripts/verify_aso_keywords.rb [版本号]`——发版前核对提交内容、上线后核对生效结果，非零退出即偏离
- **规则：改词必须先改 json 并在本文记录理由**；1.2.18 按 json 全量粘贴修复

## 待办数据源

- [ ] ASA 搜索词报表（等交付量起来，每周回填）
- [ ] ASC App Analytics 的 impressions→PPV→CVR（后台人工看或接 Analytics API）
- [ ] 订阅报表 trial starts（缺 Vendor Number，用户提供后自动化）
