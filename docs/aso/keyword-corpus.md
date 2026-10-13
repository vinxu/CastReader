# ASO 词库（活资产，随数据滚动更新）

## 2026-08-16 ASO×SEO 交叉复盘结论（1.2.25 已提审后）

网页端 28 天 GSC 数据交叉验证后的三条 ASO 结论：

1. **查询形态差异**：Google 赢在长疑问句（"does ao3 have text to speech"），App Store 是短名词组合——ASA 里的句式词（turn books into audiobooks 等）预期被证伪，已补短形态探针：`kindle audiobook / kobo audiobook / kindle tts / ebook audiobook`（Audible Intent 组，¥20）。
2. **fanfic/网文簇**（Google 侧实锤：fanfic audiobook pos 10.3、AO3 页 CTR 6.1%，无官方有声书内容 = TTS 不与真人演播对比的地盘）：ASA 探针 `fanfic audiobook / ao3 reader / ao3 text to speech / listen to webnovel / webtoon audiobook`（Long Tail 组，¥12），读展示验证 App Store 侧是否存在该需求。
3. **1.2.26 元数据候选**（当前版本在审不动）：
   - `kindle` 进关键词字段——两端数据均指向平台名是 wedge 需求真实形态，拒审代价仅改词重提，期望值已翻正；候选让位 token：`scan` 或 `caption`
   - **截图组换书库叙事**——App Store 排名引擎含转化率，截图是比关键词更大的 CVR 杠杆，wedge 词进来的用户首屏应见「Kindle 书架变有声书」画面
   - 副标题 `Audiobook from PDF, EPUB, Web` 维持——GSC 证实 audiobook 意图集中在 pdf 转换组合，与我们承载一致

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

## 2026-08-13 ASA 读数：日本配方成立、日本已饱和、德国样本量不足

**累计 08-06→08-13：¥607 / 3106 展示 / 73 点击 / 17 装 / CPA ¥36。**

### 日本：加码-回调循环跑完，效率甜点 = ¥60

| 日预算 | 边际 CPA |
|---|---|
| ¥40 | ¥46 |
| ¥60 | **¥31** ← 甜点 |
| ¥90 | ¥91（过头，08-13 已回调） |

回调当天 CPA ¥91→¥38。**规则：加码要一档一档试、每档读边际 CPA；累计 CPA 会滞后掩盖劣化。**

词级分层已验证——英文品牌词显著优于本地语品牌词：

| 词 | CPA |
|---|---|
| `audible` | ¥12–38 |
| `オーディブル` | ¥64（08-13 由 ¥28 降到 ¥18 挤出预算） |

**日本已饱和**：16 个关键词，搜索词报告中未收编词只剩 `おーでぃぶる`（15 展 0 点，输入法未转换的错拼），
且 ¥60 预算花不满（08-13 实花 ¥38）。**扩量不能再靠加词或加钱，只能靠加市场。**

### 德国：机制打通，但样本量不足以下任何结论

¥20 出价 + Audible 词把 8 天零消耗的市场撬开，展示 48→127。但 127 展示 / 2 点击。

**方法论教训（本轮犯过的错）**：曾据「DE CTR 1.6% vs JP 4.0%」判定德国素材/文案不匹配，并据此建议换 CPP。
实际核查后三个假设全被推翻：

1. de-DE localization 存在，副标题 `PDF, Web & Bücher anhören` 与 ja `PDF・Web・本を音声で聴く` 同构；
2. de-DE 有独立截图集（非复用 en），首图标题 `Hör deine Kindle-Bibliothek`，界面全德语；
3. **日本首图质量明显更差**——场景卡是葡萄牙语（`Artigos / Acadêmicos`）、书状态 `Não iniciado`、书架混葡语书——CTR 却是德国的 2.5 倍。

统计上，真实 CTR 4% 时 127 展示拿到 ≤2 点击的概率约 12%，**该差异根本不显著**。
**规则：展示 < 300 不对 CTR 下结论，更不据此改素材。**

（另记：现有截图存在真实缺陷——德/日首图的 Kindle 区都显示 🇺🇸 Amazon.com，与「你的 Kindle 书库」承诺矛盾；
日图混语言。这两点值得修，但与本轮 CTR 判断无因果关系，别混为一谈。）

### 下一步

日本饱和 + 德国单样本 → 需要第二个欧洲样本才能判断「日本配方可复制」还是「日本特殊」。
候选按「Audible 成熟市场 + 已有本地化商店页 + 非英语（英语市场对本账号结构性关闭）」筛选：**FR 优先，IT 次之**。
参数须与德国完全一致（¥40 预算 / ¥20 起价 / SM 关 / 仅 iPhone）才构成有效对照。

## 2026-08-14 三国对照推翻「audible 贴着走」：真正的信号是「免费」

法国上线 1 天即给出结论。**累计 ¥761 / 3320 展 / 84 点 / 21 装 / CPA ¥36。**

| 市场 | 花费 | 展示 | CTR | 装 | CPA |
|---|---|---|---|---|---|
| FR（1 天） | ¥55.6 | 38 | **13.2%** | 2 | **¥28** |
| JP | ¥464.6 | 850 | 4.0% | 8 | ¥58 |
| DE | ¥60.1 | 188 | 2.1% | 1 | ¥60 |

### 词级真相（搜索词 → 触发关键词）

```
FR  livre audio gratuit   9 展 · 4 点 · CTR 44.4% · 2 装 · CPA ¥21  ★ 原本只排第 6、出价 ¥18
FR  audible              28 展 · 1 点 · CTR  3.6% · 0 装             ← 原本 ¥35 最高价
DE  audible kostenlos   135 展 · 2 点 · CTR  1.5% · 1 装 · CPA ¥43
DE  audible（含 App 全名） 36 展 · 0 点 · CTR  0.0% · 0 装             ← 原本 ¥35 最高价
```

法国全部转化来自**泛词** `livre audio gratuit`；德国唯一安装也来自带 `kostenlos`（免费）的词，纯品牌词零点击。
统计上：若真实 CTR 为德国的 1.5%，9 展拿到 ≥4 点的概率约 0.02%——不是噪音。

### 结论修正

| 旧结论（08-13 写下） | 修正后 |
|---|---|
| 「audible 贴着走」是可复制配方 | **只在日本成立**；日本是品牌词市场，欧洲不是 |
| 品牌词 > 泛词，出价按品牌优先分层 | **「免费意图」才是跨市场共同信号**；`gratuit`/`kostenlos`/`gratis`/`free` 是真正的钥匙 |

与产品侧判断一致：这批用户在找**免费替代品**，不是在找 Audible 本身。搜品牌词的人多数是要装 Audible。

### 08-14 执行的出价重构（不加预算，只换押注）

```
FR  livre audio gratuit  ¥18 → ¥30      DE  audible kostenlos  ¥22 → ¥30
    audible             ¥35 → ¥20           hörbuch kostenlos  ¥18 → ¥25
                                            hörbücher gratis   ¥15 → ¥25
                                            audible            ¥35 → ¥20
```

日本保持不变——那边 `audible` 确实在转化（CPA ¥12–38），是真实市场差异，不跟改。

**规则：新市场开词时，「免费/替代」意图词必须与品牌词同价位起投，不能像本轮那样把泛词压在尾部——
差点因为出价结构埋掉唯一有效的词。**

### 08-16 回退：出价不是优先级旋钮

上面这次调价 08-16 已全部回退。**日本作为未调价对照组给出了干净证据**：

| | 08-14 展示 | 08-15 展示 | 08-14 CPT | 08-15 CPT |
|---|---|---|---|---|
| JP（未调价） | 146 | 102（−30%，全局） | ¥13.8 | **¥11.4 ↓** |
| FR（调价） | 35 | 11（−69%） | ¥8.4 | **¥23.4（+178%）** |
| DE（调价） | 105 | 10（−90%） | ¥18.1 | **¥28.2（+56%）** |

同一天日本 CPT 反而下降 → 全局竞价没变贵 → FR/DE 的 CPT 暴涨只能由调价解释。
（注：08-15 全局本就有 −30% 下滑，归因时必须先扣掉，别把整个跌幅算在自己的改动上。）

**机制（本轮最重要的收获）**：

- **提价买不到低搜索量词的量。** `livre audio gratuit` ¥18→¥30 后展示 9→6、单价 +78%，
  预算被两个昂贵点击吃光。冷门词的展示量由**搜索量**封顶，不由出价封顶。
- **降价直接切断展示来源。** DE 90% 展示来自 `audible`，¥35→¥20 后归零，
  而 kostenlos 族的搜索量根本接不住。

**规则：出价决定「能否参与竞价」，搜索量决定「能拿到多少展示」。
出价高低 ≠ 词的优先级——不同词的竞价环境不同，高竞争品牌词需要 ¥25–30 才进得去，
冷门长尾 ¥20 就够。想把预算导向某个词，正确手段是拆 adgroup 或调预算，不是抬它的 bid。**

回退后（保留方向、修正幅度——品牌词买展示量，免费词买转化率）：

```
FR  audible ¥25 · livre audio gratuit ¥20     （原始 ¥35 / ¥18）
DE  audible ¥30 · audible kostenlos    ¥22     （原始 ¥35 / ¥22）
```

## 2026-08-17 美国真相：TTS 主赛道进不去，书架长尾便宜 17 倍

US Exact 12 天零消耗后突然开跑。关键词级（08-06→08-17）：

```
ao3 reader        ¥12 出价 →  849 展 · 29 点 · CTR 3.4% · CPT ¥7.6 · 3 装
其余 29 个词      ¥6–45   →   52 展 ·  0 点 · 0 装
  turn kindle into audiobook  ¥45 → 1 展      ← 全账户最高出价，一次展示
  pdf to audio / read aloud app / text to speech pdf  ¥20 → 0 展
```

**结论：TTS 正统词（Speechify/ElevenReader 战场）出 ¥45 都进不去；
书架 reader 长尾 ¥12 拿到 849 展示——同一市场内 17 倍价差。**

### 美国的瓶颈不是流量贵，是点了不下载

| 市场 | CPT | 点击→安装 | CPA |
|---|---|---|---|
| BR | ¥4.7 | 16.7% | ¥28 |
| **US** | **¥7.8**（第二便宜） | **7.7%**（最低） | ¥101 |
| JP | ¥14.3 | 21.7% | ¥66 |
| FR | ¥13.5 | **33%**（最高） | ¥41 |

美区副标题是 `Text to Speech for PDF & Web`，搜 `ao3` 的人点进来看不到任何相关承诺；
法国转化率最高，正因为搜 `livre audio gratuit` 的人看到首图写着「听你的 Kindle 书库」。
**商店页与买词意图的匹配度，决定点击→安装那一段。**

### 撤回：「AO3/Wattpad 人群不对」缺乏依据

此前据此停投巴西，并一度要掐掉 `ao3 reader`。核查后不成立：

1. **安装率恰恰最好**——BR CPA ¥28 全账户最低，`ao3 reader` 单词 CPA ¥75 也优于 DE/US 整体；
2. **「我们不支持这些平台」是错的**——`.web` 渲染路径支持任意网页，AO3/Wattpad 本就能读；
3. **留存/付费从未验证**——这是产品推理，不是数据结论。

**规则：说某人群「不对」之前，先问是哪个环节不对（CPT / CTR / 点击→安装 / 留存 / 付费），
并指出对应的数字。拿不出数字就不叫验证。**
归因链路是有的（`AdAttributionService` 首启采集 AdServices token，服务端换 campaign/keyword），
但当前每市场仅 2–10 装，**样本量不足以支撑任何留存或付费结论**——攒到 50+ 再判。

### 待评估（08-17 决定暂不投）

`oreilly` 系值得记一笔：`CastReader/WebAssets/bundle.js` 内含**专门的 O'Reilly 适配模块**
（`#sbo-rt-content` 正文容器、跨章翻页、`pre`/`th`/`td` 可读元素、`oreillyNativeBottomOcclusion`
原生播放条避让、EZproxy 域名 `learning-oreilly-com.*`、ADAPTER_VERSION `2026-07-30-anchor-v2`）。
人群质量在所有候选里最高——O'Reilly Learning 订阅 $49/月，**付费意愿已被自己证明**，
且技术书长、通勤听是刚需。对比之下 AO3 是全免费平台，向其用户推 Pro 天然逆风。

**投之前必须先用真实 O'Reilly 账号实测 iOS 端能否读起来**——代码在不等于链路通。未实测前不投。

## 2026-08-19 账户重构：Search Match 比人工选词便宜 21 倍

**累计 14 天：¥2211 / 9216 展 / 264 点 / 60 装 / CPA ¥37**（两天前是 38 装 CPA ¥48——加量同时降本）。

### 核心发现：同国同人群，匹配方式决定一切

```
US Exact      精确买 ao3 reader 等 65 个词   CPT ¥7.6  转  6%  CPA ¥126
US Discovery  Search Match 宽泛匹配          CPT ¥2.6  转 48%  CPA ¥6   ← 便宜 21 倍
```

同一个国家、同一批用户、同一个商店页，唯一差异是**谁来选词**。
我们人工挑的高意图词选得比 Apple 的算法差 21 倍。

这解释了长期困扰的「美国结构性关闭」：**不是打不进去，是一直在用最贵的方式打**——
精确买人人都抢的词（`turn kindle into audiobook` / `kindle to audiobook` / `kobo read aloud`
出 ¥45 全部零展示），却放着 ¥3.6 起价、CPT ¥2.6、转化率 48% 的 Search Match 不用。

**规则：新市场先开 Search Match 探路，用它的搜索词报告反推该买哪些精确词；
不要一上来就人工列词精确投——那是在跟所有竞对抢同一批最贵的流量。**

### 出价对不同匹配方式的作用相反

| 场景 | 提价效果 | 例证 |
|---|---|---|
| 精确匹配 + 冷门词 | **无效**，只是把同样展示买贵 | FR `livre audio gratuit` ¥18→¥30：展示 9→6，CPT +78% |
| Search Match 宽泛 | **有效**，扩大可赢竞价范围 | US Disc 出价 ¥3.6 但 CPT 仅 ¥2.6 = 几乎赢下所有参与的竞价，限流点在出价太低 |

前者搜索量封顶，后者匹配池是全站流量。**判据：若实际 CPT 明显低于出价，说明没吃满竞价池，提价有空间。**

### 08-19 执行

- **停投**：JP（CPA ¥54）、US Exact（¥126）、DE（¥126）、CA、ES
- **US Discovery**：预算 ¥60→¥200，出价 ¥3.6→¥10（组默认 + 15 个种子词）
- 保留：BR ¥120（CPA ¥26）、FR ¥40（CPA ¥26）、IT ¥10
- 日预算 ¥370 不变，但 54% 压在 CPA ¥6 的组上

**日本注记**：停投时它正在改善（CPT ¥29→¥7.7，CPA ¥54→¥31），
拐点来自 `audible` ¥40→¥22（降价避开红海）。若重启，保持 ¥22，别退回 ¥40。

**待验证**：US Disc 提价后能否放量。CPA 缓冲极大（CPT 翻 3 倍到 ¥8，CPA 也才 ¥17），
超过 ¥25 才需回调；若 ¥200 预算仍只花 ¥30-50，说明限流不在出价，改从种子词扩容（现仅 15 个）。

## 2026-08-21 CPT 不能用来判断流量质量（一次判断失误的记录）

**累计 16 天：¥3000 / 13779 展 / 379 点 / 88 装 / CPA ¥34。**
四个市场 CPA 已收敛：BR ¥22 · US Disc ¥22 · FR ¥25 · JP ¥54。

### 提价解限流：完全验证

```
08-18  出价 ¥3.6  →  花 ¥31  ·  595 展 · 11 点 ·  2 装 · CPA ¥16
08-19  出价 ¥10   →  花 ¥201 · 1491 展 · 26 点 · 12 装 · CPA ¥17   预算几乎打满
```

花费一天涨 6.5 倍、展示涨 2.5 倍，CPA 纹丝不动。
**判据坐实：实际 CPT 明显低于出价 = 没吃满竞价池，提价有空间（仅适用 Search Match）。**

### 扩种子词：失败，且我第一时间判断错了

08-20 把种子词从 15 扩到 30（加 audiobook 意图 / 网文簇 / 其他书库三个方向）：

```
扩词前 08-19   ¥201 · 26 点 · 12 装 · 点击→装 46% · CPA ¥17
扩词后 08-20   ¥199 · 26 点 ·  2 装 · 点击→装  8% · CPA ¥100
```

同样的钱、同样的点击数，安装从 12 掉到 2。08-21 已全部回退（改 PAUSED 保留可恢复）。

**判断失误记录**：当天我看到 CPT 几乎没变（¥7.8→¥7.7→¥8.1），据此判断「流量质量没变差，CPA ¥55 是归因延迟」。
回填后 CPA 变成 ¥100，更差。错在**用 CPT 推断质量**——CPT 只反映买流量的价格，与流量对不对口无关。
当时点击→安装已经从 46% 掉到 8%，信号就在表里，我没看。

**规则：判断流量质量看「点击→安装」，判断流量价格看 CPT，两者不可互推。
扩词/换词后第一时间要看的是转化率，不是 CPT。**

### 08-21 执行

- US Discovery：15 个新种子词全部 PAUSED，回到 08-19 已验证配置（出价 ¥10 + 原 15 词）
- BR：¥120 → ¥160（连续三天打满，CPA ¥17–27，唯一「给钱就吃、成本还降」的市场）
- JP：拉平 ¥18 后 CPT 降至历史最低 ¥7.9 但量归零（展示 119→22，08-21 零点击）。
  **¥18 已是底**；暂不关停，零花费等于自然停摆，留作观察窗口。

## 2026-08-21 接通全循环：优化 CPA 优化错了目标

> 本节保留为 08-21 历史决策记录。自 2026-08-23 起，实际目标与拉数口径以
> `docs/US-GB-Apple-Ads-增长闭环数据目标与拉数SOP.md` 为唯一事实源。

**工具**：`ruby scripts/growth_loop.rb` 默认只拉 2026-08-21 后的 US / GB；
`ruby scripts/growth_loop.rb --full` 增加 ASC 全渠道对账。

### 数据源与口径（三段各有出处，不可混淆）

| 段 | 数据源 | 说明 |
|---|---|---|
| CPT / tap→install | ASA API | 广告归因口径 |
| install→trial | ASC `App Downloads Standard` | 分母取 `Download Type = First-time download`；**全渠道含自然** |
| trial→paid | ASC `App Store Subscription Event Report Standard` | 事件名：`Free trial start activation` → `Full price from free trial` |

**为什么 trial→paid 必须走 ASC**：转付费发生在试用结束（7 天后），用户当时多半没开 App，
客户端埋点采不到。ASC Analytics API 可用（`/v1/apps/{id}/analyticsReportRequests`，
取 `accessType=ONGOING` 那个），**不需要 Vendor Number**。

**⚠️ 订阅事件不带 ASA campaign 维度**，所以 install→trial / trial→paid 是该国全渠道混合值；
「广告花费 ÷ 全渠道付费」的分母含自然转化，数学上是**偏乐观的 CAC 下界**，不是广告 CAC。
纯广告口径需服务端解析 `ad_attribution` 的 AdServices token 建关联——**这是下一个待补的洞**。

### 首次全循环读数（08-06→08-21，¥3014）

```
CPT ≤ $2.50          $1.10    ✅
tap→install ≥ 40%    23.3%    ❌
install→trial ≥ 10%   6.7%    ❌  ← 真正的瓶颈，纯产品侧问题
trial→paid ≥ 30%     36.7%    ✅
混合每付费成本       ¥91 = $13（远优于目标 $50-65）
```

| 国 | ASA 花费 | 首装 | 试用 | 装→试用 | 付费 | 试→付 |
|---|---|---|---|---|---|---|
| US | ¥916 | 553 | 42 | 7.6% | **23** | 55% |
| **GB** | **¥0** | 67 | 9 | **13.4%** | **5** | 56% |
| IL | ¥0 | 8 | 3 | **37.5%** | 3 | 100% |
| AU | ¥0 | 28 | 3 | 10.7% | 2 | 67% |
| BR | ¥603 | 62 | 5 | 8.1% | **0** | 0% |
| JP | ¥861 | 61 | 3 | 4.9% | **0** | 0% |
| FR | ¥382 | 46 | 3 | 6.5% | **0** | 0% |
| DE | ¥252 | 36 | **0** | — | **0** | — |

### 两条硬结论

**1. 低 CPT 是「这个市场不值钱」的信号，不是优势。**
BR CPT ¥4.4 全账户最便宜，我为此连续加码到 ¥160——真相是那里的用户不付费，所以没人抢流量。
BR+JP+FR+DE 合计 ¥2098（占 70%）产出 **0 个付费**。
**规则：市场取舍看每付费成本，不看 CPA。CPA 最优排名与付费产出排名几乎完全相反。**

**2. 瓶颈在 install→trial（6.7%），不在投放。**
CPT 已达标 2.3 倍、trial→paid 超标，唯独安装到试用这一段差 3.3 个点。
这一段完全在产品侧（首启引导 → 首次价值 → 付费墙），投放再优化也救不了。

### 08-21 执行

- **停**：BR / JP / FR（连同此前的 DE / US Exact / CA / ES）
- **新建 GB**：`CR_GB_Search_Discovery_2026Q3` id=2144503591，¥100，
  adgroup `GB Search Match and Broad` id=2150470773，出价 ¥10，SearchMatch=on，
  种子词直接复用 US Discovery 那 15 个（英语通用且已验证 CPA ¥22）。
  **GB 直接上 Search Match，不重走 US Exact 的弯路**（同市场 Exact ¥126 vs Discovery ¥22）。
- 保留：US Discovery ¥200、IT ¥10
- 日预算上限 ¥450 → ¥310

**下轮判据**：GB 的每付费成本能否低于 US 的 ¥40；install→trial 是否随英语市场占比提升而上升。

## 2026-08-23 US / GB 目标重置：从 CAC < LTV 反推整条漏斗

旧阈值 `install→trial 10% × trial→paid 30%` 只能产生 3% 的 install→paid。
按 08-21→08-22 的安装 CPA，对应付费 CAC 为 US 约 ¥1,625、GB 约 ¥1,022，
明显高于 US v2 首年净 LTV ¥329。因此废止“每段分开达标就算跑通”的口径。

新的 US 运营目标是一组联动约束：

| 指标 | 目标 |
|---|---:|
| CPT | ≤¥8 |
| tap→install | ≥35% |
| 安装 CPA | ≤¥23 |
| 72h 绑书库/导入 | ≥20% |
| install→trial | ≥20% |
| trial→paid | ≥35% |
| install→paid | ≥7% |
| 真实广告 CAC | ≤¥329；可扩量≤¥263 |

其中 US 只计 v2 新价 SKU。GBR storefront 当前仍展示 v1，所以 GB 先验证获客、
绑书库、留存和 v1 付费；在 GBR 开放 v2 且核定当地净 LTV 前，不宣布“新价闭环跑通”。

策略讨论前只读快拉：

```bash
ruby scripts/growth_loop.rb
```

付费 cohort 成熟后 ASC 辅助对账：

```bash
ruby scripts/growth_loop.rb --full
```

完整的 cohort 定义、成熟时间、样本门槛、告警和决策树见
`docs/US-GB-Apple-Ads-增长闭环数据目标与拉数SOP.md`。

## 2026-08-23 关键词意图路由 v1

执行时间 `2026-08-23 11:52 CST`。`2026-08-23` 为混合日，当前策略的首个完整自然日从 `2026-08-24` 起算。

- US Discovery 暂停 22 个 Kindle / PDF / EPUB / ebook 高意图 Exact Negative；US Exact Campaign 继续暂停，避免高意图精确查询无人承接；
- US / GB 各新增四个 campaign-level Exact Negative：`wattpad`、`ao3`、`barnes & noble`、`goodreads`；
- US / GB Discovery 日预算继续各 ¥60；Search Match、Broad 状态及全部 ¥10 Max CPT 不变；
- 本轮只验证“搜索意图路由”，不把出价作为同时变化的变量，也不扩量。

## 待办数据源

- [ ] ASA 搜索词报表（等交付量起来，每周回填）
- [ ] ASC App Analytics 的 impressions→PPV→CVR（后台人工看或接 Analytics API）
- [ ] 订阅报表 trial starts（缺 Vendor Number，用户提供后自动化）
