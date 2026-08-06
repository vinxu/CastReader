# App Store 分发增长 · 2026-07（①②③⑤）

背景：上线 6 个月全球评分仅 1 条、核心关键词无排名，瓶颈在分发不在产品。本轮冻结功能深度，只做分发侧四件事。ASC 操作全部通过 `scripts/app_store_connect_api.rb`（JWT 走 `~/.appstoreconnect/private_keys`）。

## ① 年龄分级 17+ → 4+（已在 ASC 生效，随 1.2.14 过审上线）

17+ 的成因是三个残留字段，不是 Unrestricted Web Access：

- `ageRatingOverrideV2 = SIXTEEN_PLUS`（手动强制抬高，旧图书 app 时代残留）
- `alcoholTobaccoOrDrugUseOrReferences / horrorOrFearThemes = INFREQUENT_OR_MILD`

三项已 PATCH 为 `NONE`，计算后 `appStoreAgeRating = FOUR_PLUS`。注意 API 坑：`ageRatingOverride` 与 `ageRatingOverrideV2` 不能同时传，只传 V2。

## ② 分类 Utilities → Education（主）/ Productivity（次）

对 READY_FOR_REVIEW 的 appInfo（`b652c1fe-…`）PATCH `primaryCategory=EDUCATION`、`secondaryCategory=PRODUCTIVITY`。理由：Education 榜竞争远小于 Productivity（Speechify/NaturalReader 所在地），且与学生/语言学习/无障碍人群和 4+ 分级组合。

## ③ 月付 + 年付各 7 天免费试用

- **ASC**：两个订阅（monthly `6780774787` / yearly `6780777004`）在全部 175 个可售地区创建 `FREE_TRIAL / ONE_WEEK` introductoryOffer（批量脚本幂等，按地区逐个 POST）。**Intro offer 不需要过审，服务器端已生效**——旧版本 App 内购确认单上就会显示试用。
- **本地**：`Configuration.storekit` 两个产品补 `introductoryOffer`（P1W free）。
- **代码**（随下个构建上线）：
  - `ProManager`：`introOfferEligibleIDs` + `showsFreeTrial(for:)` + `freeTrialDays(for:)`；资格来自 `subscription.isEligibleForIntroOffer`（每 Apple ID 订阅组内一次性），fail-open 方向是「查询失败 → 不承诺试用」。
  - `PaywallView`：套餐行显示「7 天免费试用/试用结束后收费」，CTA 变「开始 N 天免费试用」，底部 3.1.2 披露（试用时长 + 到期价格 + 自动续订 + 可取消）。**未登录用户也能看到套餐与试用**，登录门槛只留在购买动作上（原实现整段替换成登录按钮，试用等于没上线）。顺带修了 `selectedProductID` 在产品已缓存时不初始化导致 CTA 永久置灰的 bug。
  - `HomeProUpsellCard`：试用文案抽成 `HomeProTrialCopy` 纯函数（可单测）。
  - 九语文案 10 条新 key 全部齐（`Localizable.xcstrings`）。
- **测试**：`PaymentTests` 3 条新用例 + `LocalizationCatalogTests.testFreeTrialCopyIsCompleteInAllNineLanguages`（含占位符签名校验）。注意：真实购买翻转资格无法自动化——`Product.purchase()` 确认弹窗挂起测试运行（仓库已知），`SKTestSession.buyProduct` 同步版抛 SKInternalError 3、异步版抛 notEntitled；门控用 `setIntroOfferEligibilityForTesting` 注入覆盖。

## ⑤ App Preview 视频 + 截图（`AppStoreAssets/6.9-inch/`，未入 git 由团队决定）

- `app-preview-read-aloud.mp4`：886×1920 / 30fps / H.264+AAC 静音轨 / 25s，内容 = 点击播放 → 词级高亮逐词推进 + 自动滚动（真实云端 TTS，Walden 公版文本）。
- `store/1-4*.png`：1320×2868 带文案合成图（词级高亮 / 自动滚动 / 多源导入 / 7 天试用），奶油底 + 圆角截图。裸截图同目录保留。
- 可复现采集器：`CastReaderUITests/AppStoreCaptureUITests`，默认 `XCTSkip`，需 `TEST_RUNNER_CASTREADER_CAPTURE=1`；配合 `xcrun simctl status_bar override --time 9:41` 与 `simctl io recordVideo`。播放断言以 `pause.circle.fill` 出现为准（否则录到的是静止页面）。免费用户视角用新启动参数 `-CastReaderDisableDebugPro`（UserDefaults 参数覆盖不了 `debug_force_pro` 的 Bool 读取）。

## 观察基线（2026-07-27 提交日快照，后续对比用）

- 提交状态：1.2.14 `WAITING_FOR_REVIEW`，build 27（07-27 上传，含试用 UI + 付费页修复），分级 FOUR_PLUS，分类 EDUCATION/PRODUCTIVITY
- 线上（1.2.13）：美区评分 **1 条**（avg 5.0），其余 11 区 0 条；分级仍显示 17+、分类 Utilities（随 1.2.14 过审切换）
- 美区搜索排名：`text to speech` / `read aloud` / `pdf reader aloud` / `kindle read aloud` / `listen to articles` 全部 **Top50 之外**；`ai explain reader` #1
- 试用 offer：iOS 两产品 × 175 地区已激活（服务端生效）；Play 侧 `monthly-trial-7d` / `yearly-trial-7d` 已配置（用户操作）

每周对比口径：评分总数（review prompt 随 1.2.14 生效后应开始爬升）、上述 6 词排名、ASC 后台
impressions → product page views → conversion rate、订阅报表 trial starts → paid conversions、
Play Console 商店转化率与试用开始数。前两项可用公开 API 拉，脚本参考本仓库
`scripts/app_store_connect_api.rb` + iTunes lookup/search。

## 上线注意

1. **1.2.14 目前挂的是 7-25 的旧构建**：试用 UI、付费页修复要么打新构建替换后再提交，要么顺延到 1.2.15。分级与分类改动跟 version 走，提交即生效。
2. 截图/预览需在 ASC 界面手动上传到各 locale（本轮只产出 en 文案版；其他 locale 沿用或后续本地化）。
3. 中国区上架走 ICP 备案（用户自行推进），完成前 WeRead 链路的目标市场缺位。

## Featuring Nominations（2026-07-28）

Apple 官方建议至少提前两周提交；要争取更广泛的编辑考虑，建议提前三周至三个月。编辑考量明确包括用户体验、设计、创新、独特性、无障碍、本地化与产品页质量。

- 已有 1.2.14 提名：`8c76581d-e94b-4210-8c68-3da495cdf513`，状态 `SUBMITTED`，窗口 2026-07-28～2026-08-03。
- 新增 1.2.15 提名：`c24fe9bd-8ac9-4114-b911-11964f97a8c7`，名称 `CastReader 1.2.15 — Inclusive Back-to-School Reading`，类型 `APP_ENHANCEMENTS`，状态 `SUBMITTED`。
- 1.2.15 窗口：2026-08-18～2026-09-15；主题为返校季包容性阅读，主叙事是词级高亮、自动滚动、语音解读与原文标注帮助学生、语言学习者，以及受益于同步视听线索的 dyslexia / ADHD 用户。
- 相关 storefront：USA、JPN、DEU、ITA、GBR、AUS、CAN、SGP、TWN、HKG、MEX；相关 locale 共 11 个（含 1.2.15 计划新增的 de-DE、zh-Hant、es-MX）。
- 未在本次提名中声称尚未完成的 App Intents / Widgets。等 iOS 26 适配真正落地后，另建一份系统新功能主题提名，并继续保持至少三周提前量。
- 新增十月无障碍提名（2026-08-02 经 API 提交）：`e12dea24-c8b4-45b6-828b-061d97d5d459`，名称 `CastReader — Accessible Reading for Dyslexia & ADHD Month`，窗口 2026-09-29～10-31，叙事为十月双认知月（Dyslexia + ADHD）× 词级同步高亮/AI 标注的多感官阅读支持。API 坑位记录：nominations 资源**没有** relatedTerritories 关系（市场由 locales 推导），提交必须带 `"submitted": true` 属性。
