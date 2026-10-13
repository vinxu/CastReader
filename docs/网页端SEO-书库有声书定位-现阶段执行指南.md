# 网页端 SEO · 书库有声书定位 · 现阶段执行指南

> 版本：v3（2026-08-16 二次修订：核事实后撤销 `.ai` 301、删 aggregateRating、noindex 判据加 28 天前置、Kindle 簇暂缓改 URL、更正仓库归属）
> 版本：v2（2026-08-16 修订：吸收 28 天 GSC 查询数据评估——品牌语与 SEO 词面分工、首页冻结、试水页先行、小说平台簇升格）
> 定位口径：与 App 侧一致的「书库→有声书」主轴，见 `docs/美区增长-书库有声书主轴落地方案.md`。
> 范围：**castreader.com —— 仓库 `castreader-content`，同名 Vercel 项目**（v3 更正：`readout-web` 服务的是 castreader.ai，不是 .com；按错仓库改会改了不上线）。castreader.ai 已全站 noindex，不在本指南范围内，见 §2.7。
> 前提约束：**不做大改版**——收敛与对齐，不推倒重来；**首页 title/H1 冻结**（见 §0.1）。

---

## 0. 一句话结论

网页端 SEO 的问题不是内容不够，是**定位分散导致每个意图簇都不够强**。现阶段做三件事：**wedge 试水页先行（不动首页）、现有内容按分支归位、建立日常存证制度**。品类大词不打，打法：**平台名长尾 + 品牌防御**。

### 0.1 首要原则：品牌语与 SEO 词面是两个工种（v2 核心修正）

- **品牌语**（转化文案）：「Your library, as audiobooks」——负责用户落地后**信不信**。用在首页 hero 副文案、App Store 副标题、paywall 锚点。跨渠道一句话一致性有真实转化价值。
- **SEO 词面**（title/H1/URL）：负责用户**能不能找到你**。28 天 GSC 实测：泛品类词（"audiobook" 单独用）pos 30-80 零点击，且把我们拖进与 Audible 真人演播的必输对比；**带具体平台名的查询 pos 6-10 有点击**（"listen to kindle books on iphone" 9.6、"does ao3 have text to speech" 6.8、"fanfic audiobook" 10.3）。
- 结论：**SEO 词面只打 `{平台名} + {能不能读给我听}` 形态**；"as Audiobooks" 不进 title/H1。首页 title/H1 冻结——首页现有 268 次品牌点击是站内最大存量资产，改错赔不起。
- ASO 侧不受此约束：Apple 是相关性判分制非竞争排名制，且 GSC 显示 audiobook 曝光实际集中在 "pdf to audiobook" 意图——恰与 App Store 副标题 `Audiobook from PDF, EPUB, Web` 的组合一致，副标题维持。

---

## 1. 现状快照（2026-08-16 抓取）

| 项 | 现状 | 判定 |
|---|---|---|
| title | `CastReader: Read Aloud and Explain Kindle, PDFs & Web Pages` | 底子好——已含 Kindle，但并列三意图，主次不清 |
| H1 | `Read Anything Aloud. Understand What Slows You Down.` | 泛化，"anything" 是无定位词 |
| meta description | 9 语 + 德语扩展进展 + 泛读 | 把版本公告写进了 description，浪费 |
| 导航 | Use Cases / Tools / Kindle on Phone / Blog / Pricing | 骨架已在，四分支可直接落位 |
| 主 CTA | Add to Chrome | 与 iOS 主轴脱节（见 §2.6） |
| 双域名 | castreader.ai **28 天 0 点击 / 0 曝光**（noindex, nofollow）+ castreader.com 994c / 49,885i | v3 更正：**不是「legacy 仍有流量」，是刻意废弃的域**。无权重分裂可言，见 §2.7 |

**诊断**：站点定位是"泛朗读+解读工具"，与 App 已切换的书库主轴脱节。不需要重做——需要把已有元素**重新排序**。

---

## 2. 现阶段具体做什么（不大动，按投入产出排序）

### 2.1 核心页调整（v2 改写：首页 title/H1 冻结，只动低风险位）

- **title / H1：不动**。现 title 已含 Kindle 平台词（正确形态），现 H1 保留。任何首页词面改动必须先有试水页数据背书（§2.0）。
- **hero 副文案**（H1 下那行小字，无 SEO 权重、纯转化位）：换成品牌语 `Your books, as audiobooks — Kindle, Kobo, AO3, or any PDF and EPUB.`
- **meta description**（影响 CTR 不影响排名，低风险可动）：`One audiobook costs more than a month of CastReader. Listen to your Kindle, Kobo, AO3 and Google Play Books — or any PDF and EPUB — with synced highlighting.`（版本公告类内容移出 description）
- 「解读」保留为 hero 第二句——差异化武器，不是主轴。

### 2.0 wedge 试水页先行（v2 新增，先于一切词面改动）

建 `/use-cases/ebook-to-audiobook` 试水页（一天成本、零存量风险），两周 GSC 读数回答「C 簇零曝光是没需求还是没页面」。读数决策：
- 进 Top 30 且有曝光增长 → 意图真实，扩建分支 1 其余页面
- 两周仍无曝光 → C 簇判定为无需求，SEO 资源全部转向平台名形态，品牌语保留在转化位不再上探词面

### 2.2 词库统一：SEO 与 ASO/ASA 用同一张表（零成本，制度性）

`docs/aso/keyword-corpus.md` 是活资产，SEO 不另建词库——**同一 wedge 词簇三处复用**（ASO 关键词字段 / ASA Exact / SEO 页面 title+H1）：

| 意图簇 | 代表词 | SEO 承载页 |
|---|---|---|
| 书库转听 | ebook to audiobook, turn books into audiobooks, listen to ebooks | 首页 + /use-cases/ebook-to-audiobook |
| 平台绑定 | listen to kindle books, kobo read aloud, kindle to audiobook | /use-cases/kindle（已有 Kindle on Phone 页可改造） |
| 文档转听 | audiobook from pdf, epub reader aloud, listen to pdf | /tools/ 对应工具页 |
| 无障碍/学习 | dyslexia reading app, adhd reading app | /learn/ 内容（§3 分支 3） |

纪律：**新增任何页面先查词表**，词表没有的意图不建页；页面数据（GSC 展示/点击）反哺词表的「排名」列。

### 2.3 收敛而非删除（1–2 天）

「大量信息、定位多样」的存量页面**不删**（删 = 丢历史权重），做三级归位：

1. **对齐**：与四分支匹配的页 → 改 title/H1 挂到对应簇，内链指向核心页
2. **降权**：过时但有流量的页（旧功能公告、版本页）→ 保留但从主导航/首页内链撤出，加 canonical 指向对应核心页
3. **隔离**：无流量无定位的页 → `noindex`，不 404

判定数据源：Google Search Console 近 90 天按页面导出，点击 < 5 且不在四分支内的进第 3 级。

> 🔴 **v3 加一条前置条件：页面必须已发布满 28 天，否则不进任何一级。**
> 实测新内容有**约两周滞后期**：`/blog/ttsmaker-review-2026` 发布后连续数周 0 点击，现在 316 曝光 / pos 6.8;`/blog/ao3-text-to-speech` 第 18 天才起量到 412 曝光。按「点击<5 就 noindex」这条规则，两篇都会在起量前被杀掉。
> 2026-08-06 那次「新增内容走不通」的误判，根因就是拿 10 天的数据下了结论。

> ⚠️ 另注：`点击 < 5` 判的是**点击**,但零点击不一定是失败 —— 66% 的非品牌曝光在第 3 页开外,那里的期望点击本来就接近 0。用「曝光 = 0 且满 28 天」比「点击 < 5」更稳。

### 2.4 技术卫生清单（1 天）

- [ ] `SoftwareApplication` 结构化数据（offers 指订阅价）。🔴 **v3 删除 aggregateRating**：给自家产品页标 aggregateRating 属于 Google 明确限制的**自我评分**，有被判 spam 的风险。商店评分（App Store 5.0/10、Google Play 4.5/12）已在首页与 /castreader-app **视觉展示**，代码见 `castreader-content/src/shared/blocks/funnel/store-ratings.tsx`——刻意只渲染不标注结构化数据，理由写在该文件注释里，别再加回来
- [ ] 九语 hreflang 对（App 有九语，web 若只有英语则先只声明 en + x-default，**不要机器翻译凑数**——低质翻页是 Google 质量信号负资产）
- [ ] sitemap 分组（core / use-cases / tools / blog），Search Console 分组提交，便于按分支读收录
- [ ] Core Web Vitals 过绿（Vercel 上现成 Speed Insights，截图看到未启用——开了，免费读数）
- [ ] OG/Twitter 卡对齐新叙事（分享出去的第一印象）

### 2.5 App 下载链路的 SEO 配套

- 每个 wedge 页尾统一放 App Store 徽章 + QR，落地目标带 `?ppid=` 对应 CPP（kindle 簇页 → kindle CPP）——**SEO 流量也走意图匹配的商店页**
- Apple Smart App Banner（`apple-itunes-app` meta）站级启用，iOS Safari 访客一键转 App

### 2.6 Chrome 扩展 CTA 的位置问题（决策项，不是执行项）

现在主 CTA 是 Add to Chrome。书库主轴的变现在 iOS（Kindle 深绑定只在 App），web 扩展是留存/触点资产。建议：**桌面访客保留 Chrome CTA，移动访客（UA 判定）主 CTA 换 App Store**。不动布局，只按端切按钮。

### 2.7 双域名：🔴 不要做 301（v3 反转，原方案会造成不可逆损害）

**原方案「`.ai` 全站 301 → `.com`」已撤销。** 它建立在一个错误前提上，而执行后撤不回来。

前提错在哪（2026-08-16 实测）：

```
sc-domain:castreader.ai     0 点击 /      0 曝光  (28 天)
sc-domain:castreader.com  994 点击 / 49,885 曝光  (28 天)
.ai 首页 robots: noindex, nofollow
```

`.ai` 不是「仍有流量与外链的 legacy」，是**刻意全站 noindex 的废弃域**（Phase D）。没有流量可承接，没有权重可传递。

更要紧的是**为什么它被废弃**：castreader.com 这个域存在的全部理由，就是 2026-06-05 为了**逃离 castreader.ai 的 HCS（Helpful Content System）域级压制**而启用的新域。把 `.ai` 301 到 `.com`，等于把当初费力甩掉的域级信号重新接回来 —— 而 301 一旦被 Google 消化，撤销不了。

**正确做法**：`.ai` 维持现状（noindex + nofollow，页面层不动）。它的 API 端点（`api.castreader.ai`、`quickread.castreader.ai`）仍在服务扩展与移动端，**必须保持存活**，这也是不能整域下线的原因。

> 关联：memory `castreader-com-content-site`（换域动机）、`castreader-com-deploy-trap`（仓库归属）。

---

## 3. 分支策略（可以做，且应该做——但每支一个意图，禁止混流）

原则：**子目录不子域名**（权重集中）；每分支独立读数；分支之间不抢同一词（cannibalization 检查进月度例行）。

### 分支 1：/use-cases/ —— wedge 收割区（主攻）

每个绑定平台一页：kindle / kobo / google-play-books / oreilly + ebook-to-audiobook 试水页（§2.0）。页面结构统一：H1 = **平台名意图词**（`{平台} + 能不能读给我听` 形态，非品类词）→ 30 秒演示视频（BookTok 素材复用）→ 三步骤 → 合规声明（见 §4.1）→ App CTA。**现有 "Kindle on Phone" 页改造为 /use-cases/kindle**，不新建重复页。

> 🔴 **v3 警告：Kindle 这一簇先别动。** 导航「Kindle on Phone」实际指向 `/castreader-app`,而站内还有一个 `/listen-to-kindle` —— 它是**全站非品牌点击第一**(24 点击 / 2,253 曝光 / pos 7.9),且**观察冻结至 2026-09-05**。
>
> 再建 `/use-cases/kindle` 会变成同平台三个页面。同平台两页抢词已有直接实测:AO3 的 `/listen-to-ao3` 与 `/blog/ao3-text-to-speech` 在 17 个可见词里**重叠 11 个**,`"ao3 text to speech"` 落地页 pos 9.8 / 博客 pos 5.3,两边都没排上去;而落地页 327i/20c 对博客 412i/7c,**转化差 3.6 倍**。
>
> 结论:**一个平台一个页面**。Kindle 簇的正确动作是等 09-05 解冻后,把「书库→有声书」的意图并进 `/listen-to-kindle` 这个既有赢家,而不是另起 URL。`/use-cases/` 分支先从**还没有页的平台**建起。

### 分支 1a：小说平台簇 —— 无官方有声书的内容（v2 升格，战略级）

GSC 实锤全站非品牌最强区：/listen-to-kindle（24 点击，全站第一）、/listen-to-ao3（CTR 6.1%）、小说平台利基播种 21 点击/周，合计占全站非品牌点击一大半；"fanfic audiobook" pos 10.3、"does webtoon have audiobooks" pos 10.3 自然进前 10。

**战略意义超出 SEO**：AO3 / 同人文 / 网文 / webtoon 是**永远不会有官方有声书的内容**——在这个地盘上 TTS 不需要与真人演播比（主轴方案 R1 质量预期风险的最优解）。执行：AO3 / Wattpad / Royal Road / webtoon 逐平台建页，形态复制已验证的 /listen-to-ao3；此发现同步反哺 App 侧（ASA 可试 fanfic/webnovel 词组、BookTok 素材可拍同人文场景）。

### 分支 2：/tools/ —— 文档转听工具页（承接现有 Tools）

pdf-to-audio / epub-reader-aloud 等。**决策点**：做纯落地页（描述+下载）还是做可用的在线 demo。demo 转化好但烧 TTS 成本——若做，限时长（60 秒试听）+ 强制登录后走 App。现阶段先落地页，demo 等循环闭合后评估。

### 分支 3：/learn/ —— 无障碍与学习内容（第二渠道伏笔）

dyslexia / ADHD / bimodal reading 的循证内容。这是主轴方案里「方向二」的种子——**内容先行成本低**，聚够 GSC 数据再决定是否升级为独立叙事。纪律：引用真实研究，不做医疗声明（YMYL 边界，Google 对健康类内容按高标准评估，写"辅助工具"不写"治疗"）。

### 分支 4：/blog/ —— 保留但降级为支撑

存量博客按 §2.3 归位。新内容只服务前三个分支的长尾（如 "how to listen to kindle books on iphone"），**停止**与定位无关的泛主题产出。

### 明确不做

- ❌ 品类大词专题页（"text to speech"/"read aloud app"）——Speechify 内容农场做了多年，正面打是给它送流量确认
- ❌ AI 批量生成长尾页——Google 2024 起的 scaled content abuse 政策直接打站级信任，一次惩罚全站陪葬
- ❌ 九语机器翻译全站——同上，质量信号负资产
- ❌ 购买外链/PBN——不解释

---

## 4. 举证与申诉：怎么开展

三种场景分开建流程。核心思想：**举证能力是提前建的，不是出事再补的**。

### 4.1 防御性：我们被投诉（最可能的场景）

风险源排序：Amazon/Audible 商标投诉 > 内容版权投诉 > Google 算法/手动处罚。

**事前（现在就做，这是本节的主体工作）**：

1. **商标使用规范上墙**：所有提及 Kindle/Kobo/Audible/Google Play Books 的页面遵守 nominative fair use 三原则——只做兼容性描述（"works with your Kindle library"）、不用对方 logo/视觉、不暗示官方关系。每个 use-case 页脚统一放声明：`Kindle is a trademark of Amazon.com, Inc. CastReader is not affiliated with, endorsed by, or sponsored by Amazon. You use your own account and content access.`（与 App Store 描述的免责段同源）
2. **敏感词边界**："Audible alternative" 类比较词**只出现在正文比较语境，不进 title/H1/域名/子目录名**——title 级使用是商标投诉最常引的证据
3. **快照存证制度**：每次核心页改版前后，Wayback Machine 手动存档 + 本地 `scripts/` 加一个月度定时任务抓核心页 HTML 落 git（git 时间戳即证据链）。目的：一旦被指控"曾暗示官方关系"，能证明任一时点的实际措辞
4. **投诉响应预案**（收到 C&D/商标函时照做，不临场发挥）：不下架先评估 → 24h 内律师/顾问过目 → 区分"要求停用商标词"与"要求停止功能"（前者可谈判缩窄措辞，后者才是 R2 级风险）→ 所有回复书面留痕

**事中（真收到 DMCA/商标投诉）**：

- DMCA 下架通知：先验证形式有效性（是否具备法定六要素）；对确属误伤的准备 counter-notice——**counter-notice 意味着同意美国司法管辖，签发前必须过人**，这是本指南里唯一"停下来问决策"的点
- Google 移除通知（GSC 收到版权移除）：在 Lumen 数据库查原始通知全文，针对性抗辩

### 4.2 防御性：Google 处罚申诉（Reconsideration Request）

先说概率：只要遵守 §3 的"不做清单"，手动处罚概率极低。真发生时：

1. GSC「手动操作」页确认处罚类型与影响范围（站级 vs 页面级）
2. 修复动作**逐条对应处罚原因**，全部留 before/after 证据（截图 + git diff + 日期）
3. 申诉信三段式：**承认具体问题（不辩解）→ 修复清单（带证据链接）→ 防复发机制**。申诉信里最忌讳的是"我们认为没有违规"——那是二次拒绝模板
4. 算法性下跌（无手动操作）没有申诉通道——回到内容质量本身，按 §2.3 收敛

### 4.3 进攻性：我们是权利方

1. **内容被抄袭**：举证包 = 原文 URL + git/CMS 首次发布时间戳 + Wayback 存档 + 对方页面快照。渠道：对方主机商 DMCA → Google 版权移除（批量走 GSC 移除工具）
2. **品牌词被竞价**（别家买 "castreader" 关键词）：Google Ads 商标投诉需先在 Google 登记商标——**若 CastReader 商标还没注册，这是本节唯一的前置采购项**，建议启动（美国 + 主要市场）
3. **仿冒 App/仿冒站**：App Store 走 Apple 的 App Dispute 表单；仿冒域名走 UDRP（成本高，非紧急不动）

### 4.4 日常存证节律（并入现有运营节奏）

| 频率 | 动作 |
|---|---|
| 每月 1 日 | GSC 数据全量导出落盘（表现+覆盖+手动操作截图）；核心页 Wayback 存档 |
| 每次改版 | 改版前后快照 + git commit（落地页进 git 天然满足） |
| 每季度 | 商标使用措辞巡检（新页面是否守 §4.1 边界）；`site:castreader.com` 收录抽查 |

---

## 5. 指标与节奏（对齐循环验证协议）

SEO 是慢变量，**不进 12 周循环判定**，按季度读：

| 指标 | 基线 | 季度目标 |
|---|---|---|
| GSC 非品牌点击 | 待建基线（本周导出） | +50% |
| wedge 词簇进 Top20 数 | 待测 | ≥3 个 |
| web → App Store 点击（带 UTM/ppid） | 待建 | 建立读数即达标 |
| 品牌词首位保有 | 假设 100% | 100%（防御红线） |

唯一进快循环的部分：**wedge 落地页作为 ASA/信息流备用落地页**的转化率——那是投放侧读数，不等季度。

---

## 6. 执行顺序（两周内，v2 调整）

1. 本周：**§2.0 试水页上线** + hero 副文案/meta description（§2.1 低风险位）+ GSC 基线导出 + §4.1 商标声明上墙
2. 下周：分支 1a 小说平台页扩建（复制已验证形态，这是数据说了算的确定性动作）+ §2.3 存量归位 + §2.4 技术卫生
3. 两周读数：试水页决定分支 1 扩不扩；**首页词面在有试水页数据前保持冻结**
4. 决策项交用户：§2.6 移动端 CTA 切换、§4.3 商标注册启动与否、分支 2 的 demo 做不做

> 关联：`docs/美区增长-书库有声书主轴落地方案.md`（主轴与 R1/R2 红线）、`docs/aso/keyword-corpus.md`（唯一词库）、memory `backend-domains-and-auth-ownership`（双域名现状）。
