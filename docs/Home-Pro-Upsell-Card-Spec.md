# 首页「成为 Pro」卡片需求规范

状态：产品方案已确认，待各端独立实施
适用平台：iOS、Android
更新时间：2026-07-19

## 1. 目标

在首页最底部、Kindle 模块下方增加一张紧凑的「成为 Pro」转化卡片。卡片需要在首页直接说明核心权益、年度订阅完整价格和折算后的每周价格，让已经完成购买决策的用户可以直接发起年度订阅，避免先进入完整付费墙再点击购买的重复路径。

首页卡片只对非 Pro 用户展示。现有完整付费墙继续保留，用于额度耗尽、选择高级音色、查看月度方案、恢复购买等其他触发场景。

## 2. 展示位置与条件

- 位置：首页主滚动区最底部，紧接 Kindle 模块之后。
- 与 Kindle 模块建议保持 20–24pt/dp 的纵向间距。
- 仅当统一权益状态为非 Pro 时展示；本地商店权益或服务端跨平台权益任一有效，都必须隐藏卡片。
- 权益在当前会话内发生变化后，卡片应立即消失，不要求用户重启页面。
- Debug/测试环境需要能够关闭强制 Pro，便于验收非 Pro 卡片。

## 3. 推荐视觉方案

采用 ElevenReader 首页转化卡片的紧凑信息层级，但完全使用 CastReader 自身的设计语言。

### 3.1 卡片结构

```text
┌─────────────────────────────────┐
│      [无文字的抽象书封构图]       │
│                                 │
│  CASTREADER PRO                 │
│  让每本 Kindle 都开口说话          │
│  Kindle 连续朗读 · 100+ 专业音色   │
│  · 9 种语言                       │
│                                 │
│  US$34.99/年        ← 最醒目价格   │
│  折合约 US$0.67/周   ← 次要换算     │
│                                 │
│  [ 以 US$34.99/年成为 Pro ]       │
│  月度方案与恢复购买                 │
│  按年自动续订，可随时取消             │
└─────────────────────────────────┘
```

### 3.2 视觉参数

- 卡片：全宽；圆角建议 20pt/dp；1pt/dp 细边框；不得使用厚重阴影。
- 浅色模式：暖白页面背景，卡片使用暖灰/浅米灰 Surface。
- 深色模式：使用现有深色 Surface 和 Border 语义色，不单独硬编码纯黑。
- 品牌色：CTA 使用 CastReader 品牌橙 `#FD5F01`，白色按钮文字。
- 内边距：建议 16–18pt/dp。
- 顶部插画区：约 104–112pt/dp 高。
- 主标题：22–24sp，Bold/Semibold，最多两行。
- 权益摘要：13–14sp，次级文字色，允许换成两行。
- 年度完整价格：18–20sp，Bold，必须比周价格更醒目。
- 周价格：13–14sp，次级文字色。
- CTA：全宽，高度约 50–52pt/dp，圆角 14–16pt/dp。

### 3.3 顶部插画约束

- 使用 5 本知名英文公版名著的真实英文封面错落排布：`Pride and Prejudice`、`Dracula`、`Frankenstein`、`Moby-Dick`、`Alice’s Adventures in Wonderland`。
- 封面作为本地图片资源随 App 打包，不依赖运行时网络；封面保持英文书名，不随界面语言切换。
- 去掉音频波浪、白色耳机以及其他悬浮装饰，保持视觉简洁。
- 封面以外不得嵌入固定语言文案；所有产品文案仍必须跟随九语言资源切换。
- 不使用 Amazon Logo、Kindle Logo 或仿制商标图形；正文中可以正常使用文字“Kindle”说明兼容能力。
- 封面素材采用 Standard Ebooks 提供的英文公版版本，并在入包前降采样到移动端所需尺寸。

## 4. 文案与九语言本地化

所有可读文案必须进入平台语言资源，不得将中文、价格或货币符号写进图片，也不得在业务代码中写死价格。

| Locale | 主标题 | 权益摘要 | CTA 年度购买 | 次级入口 | 自动续订说明 |
|---|---|---|---|---|---|
| `zh-Hans` | 让每本 Kindle 都开口说话 | Kindle 连续朗读 · 100+ 专业音色 · 9 种语言 | 以 %@/年成为 Pro | 月度方案与恢复购买 | 按年自动续订，可随时取消 |
| `en` | Make every Kindle book speak | Continuous Kindle reading · 100+ professional voices · 9 languages | Become Pro for %@/year | Monthly plan and restore purchases | Renews annually. Cancel anytime. |
| `ja` | Kindleの本を、声で楽しもう | Kindleを連続朗読 · 100種類以上のプロ音声 · 9言語 | 年額%@でProになる | 月額プランと購入の復元 | 年ごとに自動更新。いつでもキャンセルできます |
| `es` | Haz que tus libros Kindle cobren voz | Lectura continua de Kindle · Más de 100 voces profesionales · 9 idiomas | Hazte Pro por %@ al año | Plan mensual y restaurar compras | Renovación anual. Cancela cuando quieras. |
| `fr` | Donnez une voix à vos livres Kindle | Lecture Kindle en continu · Plus de 100 voix professionnelles · 9 langues | Passez Pro pour %@ par an | Forfait mensuel et restaurer les achats | Renouvellement annuel. Annulation à tout moment. |
| `de` | Gib jedem Kindle-Buch eine Stimme | Kontinuierliches Kindle-Vorlesen · 100+ professionelle Stimmen · 9 Sprachen | Pro werden für %@/Jahr | Monatsplan und Käufe wiederherstellen | Jährliche Verlängerung. Jederzeit kündbar. |
| `pt-BR` | Dê voz aos seus livros Kindle | Leitura contínua no Kindle · Mais de 100 vozes profissionais · 9 idiomas | Seja Pro por %@/ano | Plano mensal e restaurar compras | Renovação anual. Cancele quando quiser. |
| `it` | Dai voce ai tuoi libri Kindle | Lettura Kindle continua · Oltre 100 voci professionali · 9 lingue | Passa a Pro per %@ all’anno | Piano mensile e ripristina acquisti | Rinnovo annuale. Annulla quando vuoi. |
| `hi` | अपनी Kindle किताबों को आवाज़ दें | लगातार Kindle वाचन · 100+ प्रोफ़ेशनल आवाज़ें · 9 भाषाएँ | %@/वर्ष में Pro बनें | मासिक प्लान और खरीदारी बहाल करें | सालाना नवीनीकरण। कभी भी रद्द करें। |

其他本地化键：

- Badge：所有语言统一显示 `CASTREADER PRO`。
- 年度完整价格：使用平台商店返回的本地化价格，再通过各语言格式键表达“%@/年”。
- 周价格格式：
  - `zh-Hans`：`折合约 %@/周`
  - `en`：`About %@/week`
  - `ja`：`週あたり約%@`
  - `es`：`Aproximadamente %@ por semana`
  - `fr`：`Environ %@ par semaine`
  - `pt-BR`：`Cerca de %@ por semana`
  - `it`：`Circa %@ a settimana`
  - `hi`：`लगभग %@/सप्ताह`
- 价格加载中：九语本地化“正在加载价格”。
- 价格不可用：九语本地化“查看 Pro 方案”，点击后进入现有付费墙，不得显示缓存的其他地区价格。

## 5. 价格与订阅规则

- 主推并默认购买年度方案，但不能默默选择：卡片必须明确写出年度周期和年度完整扣款价格。
- 年度完整扣款价格必须是页面中最醒目的价格；每周折算只能作为字号更小、颜色更弱的辅助信息。
- 年度价格必须来自 StoreKit / Google Play Billing 当前商店返回的本地化商品数据。
- 每周价格由年度数值价格除以 52 后计算，并使用当前商品的货币与 Locale 格式化。
- 不硬编码 `US$34.99`、`US$0.67`、人民币符号或任何价格。
- 当前未配置免费试用时不得出现“免费试用”“先免费后付费”等文案。未来只有在商店返回用户确实可用的优惠资格时，才可动态展示。
- 月度方案继续存在，但不是首页主按钮；通过次级入口进入现有付费墙选择。

## 6. 购买交互

### 6.1 主按钮

- 点击 CTA 后直接对年度商品发起平台内购，不再先打开自定义付费墙。
- 平台系统购买确认框仍会正常出现；这是商店安全确认步骤，不得规避。
- 只有 CTA 按钮发起购买。点击插画、标题或卡片空白区域不得直接购买，避免误触。
- 购买进行中按钮进入 Loading 并锁定，防止重复触发。
- 成功后刷新统一 Pro 权益并立即隐藏卡片。
- 用户取消、Pending、失败分别走已有购买结果处理，不能误报成功。

### 6.2 登录前置

- 如果跨平台 Pro 体系要求用户先登录邮箱/账号，点击 CTA 后先进入登录。
- 必须保存“待购买年度方案”的意图；登录成功后自动继续年度购买，不要求用户返回首页再点一次。
- 登录取消则终止本次购买意图，不弹错误。

### 6.3 次级入口

- `月度方案与恢复购买` 打开现有完整付费墙。
- 完整付费墙继续提供月度/年度选择、恢复购买、服务条款、隐私政策以及账号同步状态。

## 7. 平台实施说明

### iOS

- 使用 `ProManager.yearly` 的 StoreKit `Product`。
- 使用 `Product.displayPrice` 展示年度完整价格。
- 周价格用 `Product.price / 52` 计算，并用该 Product 的价格格式格式化。
- CTA 购买埋点触发源使用 `home_pro_card_yearly`。
- 卡片放入 `HomeView` 的 Kindle 模块之后，并复用 Home 的单一 Sheet 路由打开现有付费墙/登录页，避免多个 Sheet 抢占。

### Android

- 使用 Android 现有统一 Pro 权益作为展示真相，不另建只看本地缓存的 Pro 判定。
- 使用 Google Play Billing 返回的年度 Base Plan / Offer 数据；完整价格使用 Play 返回的 formatted price。
- 周价格从年度 price micros 除以 52 计算，并按 Play 返回的 currency code 与当前 Locale 格式化。
- 主按钮直接启动年度 Billing Flow；不得先打开 Android 自定义付费墙。
- 若年度商品或合格 Offer 未加载，不得使用测试价格兜底。

## 8. 埋点

至少覆盖：

- `home_pro_card_impression`
- `home_pro_card_yearly_purchase_tap`
- 现有 `purchase_start` / `purchase_result`，trigger=`home_pro_card_yearly`
- `home_pro_card_secondary_tap`

Impression 同一次页面展示只记录一次。购买结果需要区分 success、cancelled、pending、failed、blocked-login。

## 9. 无障碍与适配

- 支持浅色与深色模式。
- 支持 Dynamic Type / Android Font Scale；主标题和权益文案允许换行，价格及 CTA 不得被截断。
- VoiceOver / TalkBack 按“Badge → 标题 → 权益 → 年度价格 → 周价格 → CTA → 次级入口”顺序朗读。
- CTA 最小可点击高度 44pt / 48dp。
- 小屏设备不得横向溢出；较长的法语、葡语、印地语重点验收。

## 10. 验收清单

- [ ] 卡片位于 Kindle 模块下方且只有非 Pro 可见。
- [ ] Pro 状态改变后卡片即时隐藏。
- [ ] 顶部插画为 5 本英文名著封面，无波浪、无耳机、无 Amazon/Kindle Logo。
- [ ] 英、中、日、西、法、葡（巴西）、意、印地语八种 UI 均无回退中文、截断或硬编码。
- [ ] 年度完整价格比周折算价格更醒目。
- [ ] 价格来自当前平台商店和当前地区，不使用测试价格。
- [ ] 主 CTA 直接启动年度平台购买确认流程，不先打开自定义付费墙。
- [ ] 月度方案与恢复购买仍可通过次级入口访问。
- [ ] 未登录时登录完成可自动续接购买。
- [ ] 购买成功、取消、Pending、失败和重复点击均正确处理。
- [ ] 浅色、深色、大字体和小屏通过真机验收。
