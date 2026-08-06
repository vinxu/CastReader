# Play 商店分发增长 · Android ①②③⑤ 落地指引

> **状态 2026-07-27**：③ 客户端已全部实现并通过全量单测（259/259）——offer 选择策略反转（试用优先）、
> `trialDays` 全链路、Paywall/HomeProUpsell 试用文案、9 语 strings、8 条计费契约测试。
> 待办：①②③ 的 Play Console 后台操作（见文末操作单，约 20 分钟）；⑤ 暂缓（用户决定）。

对齐 iOS 2026-07 分发批次（见 `docs/feature-appstore-growth-2026-07.md`）。Android 现状（已核实代码）：
`com.same.castreader` v1.0.16(21)；Play Billing 订阅 `castreader_pro_monthly` / `castreader_pro_yearly`；
九语资源目录齐（`values` + de/es/fr/hi/it/ja/pt-rBR/zh）；`PurchaseVerifier` 已接后端；
`docs/CastReader-GooglePlay-Metadata-8-Languages.md` 已有元数据基线。

执行前先在 Play Console 确认一件事：当前**分类、内容分级、上架状态**各是什么（本指引按「已上架、分类/分级可能沿用旧默认」写；未上架则全部变成首次提交时直接配对）。

---

## ① 内容分级（对应 iOS 17+ → 4+）

Play 走 **IARC 问卷**（Play Console → App content → Content ratings），无 API，纯后台操作。

- iOS 的 17+ 根因是三个旧时代残留（手动 override + 酒精 + 恐怖）。Play 侧同样检查：重填问卷时全部按工具类如实回答**否**（暴力/性/毒品/赌博/脏话/恐怖均无）。
- **UGC 问题答否**：用户内容只进本机阅读器，不存在公开分享。
- **无限制网络访问答否**：与 iOS `unrestrictedWebAccess=False` 口径一致——WebView 只用于固定的阅读/绑定流程，不是浏览器。
- **Target audience（Play 独有）**：选 **13+ 及以上**，不要勾任何 13 岁以下年龄段。勾了会落入 Families 政策（设备标识符传输受限，自研埋点的 device_id 直接踩线）。13+ 目标人群与 Everyone 分级可以并存，不冲突。
- 预期结果：分级 **Everyone / PEGI 3**，与 iOS 4+ 对齐。

## ② 分类（对应 Utilities → Education/Productivity）

Play Console → Store presence → Store settings：

- **App category 只有一个**（没有 iOS 的次分类）：选 **Education**（与 iOS 主分类一致；同样的逻辑——竞争小、匹配学生/语言学习/无障碍人群、与 Everyone 分级组合）。
- **Store listing tags**（最多 5 个）补偿没有次分类：从可选集中挑 Education、Productivity 相关标签。
- 改动随下次商店信息发布生效，不需要发版。

## ③ 7 天免费试用（月付 + 年付）

### ⚠️ 先看地雷：现有客户端会绕过试用

`billing/BillingSubscriptionOffer.kt` 的 `BillingOfferPolicy.select` 排序里
`compareBy({ it.first.offerId != null }, …)` **刻意把基础方案（offerId == null）排在最前**。
Play 的 offer 机制与 StoreKit 相反——**intro offer 不会自动应用**，客户端必须显式把试用 offer 的
`offerToken` 传给 `launchBillingFlow`。所以：只在 Console 配 offer 而不改代码 = 用户永远买原价，试用形同虚设。
（旧版本 App 也是这个行为——无害但拿不到试用，与 iOS「服务端 offer 先生效、UI 随下版」不同，**Android 的试用必须等新版本铺开才真正生效**。）

### Console 配置（无需过审，随时生效）

两个订阅各自：base plan → **新建 Offer**：

- Offer id 建议：`monthly-trial-7d` / `yearly-trial-7d`
- Eligibility：**New customer acquisition（从未拥有过该订阅）**
- Phase：Free trial，时长 7 天
- 地区：全部

注意 Play 的资格粒度是**单个订阅商品**，不是 Apple 的订阅组：买过月付的老用户仍可能拿到年付试用。
比 Apple 略宽松，接受即可；想收紧要走 developer-determined eligibility + 服务端判定，不值得。

### 客户端改动（发版才生效）

1. **`BillingOfferPolicy.select` 改选择策略**：同一 billing period 的合格 offers 中，
   **优先含免费阶段（`priceAmountMicros == 0`）的 offer**；没有才回落基础方案。
   展示价格维持现逻辑（取 `INFINITE_RECURRING` 阶段），已经是对的，别动。
   Google 已在服务端按账号过滤资格——`queryProductDetails` 返回的 offers 就是当前账号可用的，
   所以「有免费阶段的 offer 存在」即等价于 iOS 的 `isEligibleForIntroOffer == true`，客户端不需要另做资格判断。
2. **`ResolvedSubscriptionOffer` 增加 `trialDays: Int?`**：解析免费阶段的 `billingPeriod`（`P1W`→7、`P3D`→3…）。
3. **UI 对齐 iOS 文案结构**（iOS 键名见 `CastReader/Localizable.xcstrings` 本批新增 10 键）：
   - `Paywall.kt` 套餐行：「N 天免费试用」+「试用结束后收费」；CTA：「开始 N 天免费试用」；
     底部披露：试用时长 + 到期价格 + 自动续订 + 可随时取消（Play 订阅政策同样强制自动续订披露，
     `strings.xml` 里已有披露区注释锚点）。
   - `HomeProUpsell.kt`：CTA 与底部续订说明的试用变体（对齐 iOS `HomeProTrialCopy` 两个纯函数的分支语义：
     无资格/无价格时**只讲价格、绝不空承诺试用**）。
   - 字符串 9 语齐全：`values`(en) + de/es/fr/hi/it/ja/pt-rBR/zh，译文直接抄 iOS xcstrings 对应键。
4. **埋点零改动**：沿用 `purchase_start/purchase_result`，与 iOS 本批一致，不扩 schema。
5. **后端核对项**：Play 试用期购买的 `paymentState = 2 (free trial)`，确认 `/api/pro/status` 与
   `PurchaseVerifier` 的服务端校验把试用期视为有效订阅（应当天然成立，因为按到期时间判断——但要真验一次）。

### 测试（扩展现有 `BillingSubscriptionOfferTest`）

- 试用 offer 与基础方案并存 → 选试用 offer 的 token，展示价仍为续费价；
- 无试用 offer（不合格账号）→ 回落基础方案，`trialDays == null`；
- `P1W`/`P7D` → 7 的解析；异常 period → null；
- 文案门控：`trialDays == null` 时任何字符串里不得出现试用字样（对齐 iOS `testHomeCardCopySwitchesBetweenTrialAndPrice` 的语言无关断言写法）。

## ⑤ 商店素材（对应 App Preview + 截图）

Play 与 ASC 的三个结构性差异决定做法：

| | App Store | Google Play |
|---|---|---|
| 视频 | 上传 mp4（886×1920） | **YouTube 链接**（建议 unlisted），列表页横屏播放器 |
| 视频入口 | 无前置条件 | **必须先有 1024×500 feature graphic**，否则视频不显示 |
| 截图 | 1320×2868 固定档 | 2–8 张，**9:16（1080×1920）** 才有资格进大图推广位 |

1. **Feature graphic 1024×500**（新做，唯一 iOS 没有的资产）：品牌底色 + 一句 hook + 设备样机
   （素材直接用 iOS 侧 `AppStoreAssets/6.9-inch/` 的 hero 截图）。九语各一张（Play 支持按语言上传全套图形）。
2. **视频**：iOS 的 886×1920 成片直接传 YouTube（unlisted）即可用；竖屏在横屏播放器里有黑边，
   能接受就零成本复用；追求质感再做一版 16:9 横屏（设备居中 + 两侧品牌底）。
3. **截图**：合成画布改 **1080×1920**，其余复用 iOS 的合成方案（奶油底 + 标题 + 圆角截图；
   CJK/天城文标题同样必须走系统级文本渲染，PIL 排不了）。
4. **采集管线移植**（对齐 iOS `AppStoreCaptureUITests` 的思路）：
   - 文本注入：Debug 构建加 intent extra（如 `--es capture_text_b64 <b64>`），走既有纯文本导入路径直开阅读器
     ——理由与 iOS 相同：输入法打非 ASCII 不可靠，剪贴板路径有系统弹窗。九语演示文本直接复用 iOS 侧的
     Walden 各语译文（zh/ja 是句级高亮，文案别写「逐词」）。
   - 状态栏：`adb shell settings put global sysui_demo_allowed 1` + `am broadcast -a com.android.systemui.demo`
     设 9:41 / 满电 / 满格 WiFi（等价 iOS 的 `simctl status_bar override`）。
   - 录屏：`adb shell screenrecord`；截屏走 Compose 测试（播放键补 `testTag`，断言「播放态出现才算数」——
     iOS 侧靠 `pause.circle.fill` 出现防录到静止页，Android 同理）。
   - 付费页采集需要关掉 debug Pro 直通的启动参数（对齐 iOS `-CastReaderDisableDebugPro` 的用途）。
   - 平板：Play 有 7"/10" 平板截图位，不阻塞手机列表质量，二期再补。

## 执行顺序与量级

| 项 | 位置 | 量级 | 生效 |
|---|---|---|---|
| ① 分级问卷 + Target audience | Console UI | ~10 分钟 | 商店信息发布即生效 |
| ② 分类 Education + tags | Console UI | ~5 分钟 | 同上 |
| ③ Console offers | Console UI | ~15 分钟 | 立即（但被客户端绕过，见地雷） |
| ③ 客户端 offer 策略 + UI + 9 语 + 测试 | 代码 | ~0.5–1 天 | 随下一版 |
| ⑤ Feature graphic + 截图 + YouTube | 素材 | ~1 天（复用 iOS 管线思路） | 商店信息发布即生效 |

顺序建议：①② 先做（零成本）→ ③ 客户端代码合入同一个版本 → Console offers 在该版本铺开前配好 → ⑤ 并行。

---

## 附：Play Console 操作单（人工，约 20 分钟）

offer 可以**现在就激活**：旧版本客户端会绕过它按原价购买（无害），新版本铺开即自动生效，无顺序依赖。

### ① 内容分级 + 目标受众

1. Play Console → 选 CastReader → 左栏 **政策 → 应用内容（App content）**
2. **内容分级（Content ratings）→ 重新填写问卷**：类别选工具/实用类；暴力、性、毒品、赌博、脏话、恐怖全部**否**；UGC **否**；无限制网络访问**否**（与 iOS `unrestrictedWebAccess=False` 口径一致）→ 提交，确认结果为 **Everyone / PEGI 3**
3. **目标受众和内容（Target audience）**：只勾 **13 岁及以上**（勾 13 以下会触发 Families 政策，自研埋点 device_id 踩线）

### ② 分类 + 标签

1. **拓展 → 商店发布 → 商店设置（Store settings）**
2. App category：**应用 → 教育（Education）**
3. Tags：从列表中加 Education / Productivity 相关标签（最多 5 个）→ 保存发布

### ③ 试用 offers（两个订阅各一次）

1. **创收 → 产品 → 订阅（Monetize → Subscriptions）** → `castreader_pro_monthly`
2. 在其 base plan 上 **添加优惠（Add offer）**：
   - Offer ID：`monthly-trial-7d`
   - 资格：**新客户获取（New customer acquisition）**（从未拥有过此订阅）
   - 阶段：**免费试用（Free trial）· 7 天**
   - 地区：全部
3. **激活（Activate）**
4. 对 `castreader_pro_yearly` 重复：Offer ID `yearly-trial-7d`，其余相同

### 验证

新版本客户端装真机 → 未买过订阅的 Google 账号打开付费页：套餐卡出现「7 天免费试用」徽标、
CTA 变「开始 7 天免费试用」、Google 购买面板显示「7 天免费，之后 US$xx.xx/年」。
已订阅过的账号：无试用字样，CTA 显示原价——两种都对才算过。
