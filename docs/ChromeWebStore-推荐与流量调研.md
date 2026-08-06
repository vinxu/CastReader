# Chrome Web Store 推荐与流量 · 调研结论（2026-07-29）

## 现状盘点（readout-desktop 仓库 + 线上）

- **已上架**：id `foammmkhpbeladledijkdljlechlclpb`，v1.2.23，**MV3 ✓**（chrome/edge/firefox/safari 四端管线齐）
- 评分 4.5–4.7★（条数少）；Google 索引里出现过**三个历史标题**（Read Aloud + AI Explain → Free AI Text to Speech Reader → Free Read Aloud for Kindle…），说明标题已在迭代
- 内部数据（aso-mobile-2026-07）：**Chrome ≈113 新增/7 天（≈16/天），付费率 ≈2%**——当前三端里最大的自然增长源
- 基建已备：50 语列表（store-listings/）、promo 素材目录、trader 验证调研、博客 SEO（castreader.ai 两篇已在 Google 占位）、Reddit 播种手册
- 差异化牌：Kindle Cloud Reader 支持（23 个地区域名）、词级高亮、AI 解读、九语

## CWS 的「推荐」体系（与 App Store / Play 的本质区别）

| 机制 | 是什么 | 怎么进 |
|---|---|---|
| **Featured 徽章** | 列表页蓝色徽章 + 搜索/发现加权，**编辑合集的入场券** | **有官方提名表单**（见下），人工审核 |
| Established Publisher 徽章 | 发布者层信任标 | 验证身份 + 无违规记录，达标自动 |
| 编辑合集 / 首页轮播 | Editors' picks、主题合集 | 无公开申请，**从 Featured 池子里选** |
| 站内搜索 | 标题关键词 + 评分 + 用户数权重 | 50 语列表已是优势 |
| EU 可见性 | DSA trader 验证 | 未验证会限制欧盟曝光（仓库里已有调研文档，去后台确认状态） |

**关键结论：Chrome 是三端中唯一有官方「点名申请推荐」通道的商店**——One Stop Support 表单里 **My item → "I want to nominate my extension"** 直接提名 Featured 徽章。审核 7 天（忙时最长 30 天），通过后 1 小时内挂徽章。有开发者实测拿到徽章后安装量翻倍。

### 提名硬性条件（对照自查）

| 条件 | 我们 |
|---|---|
| 已发布且公开 | ✓ |
| 英文支持 | ✓ |
| 无活跃违规 | ✓（列表页显示 publisher 无违规史） |
| **核心功能免登录免付费可用** | ✓ 免费额度 20 分钟/天（提名前实测一遍全新浏览器安装即用） |
| MV3 + 最新平台 API | ✓ |
| 权限最小化 | ✓（刻意未申请 tabs/debugger） |
| 列表质量：清晰描述 + 高质量截图 | 截图需过一遍质量（见行动 2） |

## 行动清单（按 ROI 排序）

1. **本周就提 Featured 提名**（免费，一张表单）：One Stop Support → My item → nominate。提名前自查上表最后两项。
2. **Promo 图三件套补齐**：440×280（必需）、920×680、**1400×560 marquee**——marquee 是首页轮播/合集的物料前提，没有它编辑想选也选不了。
3. **Trader/EU 验证确认完成**（store-assets/trader-verification-research.md 已有调研，去 dashboard 确认状态）。
4. **扩展内评分引导**：CWS 搜索权重里评分条数占比高，现在 4.5–4.7★但条数少；在第 N 次成功朗读后加轻量引导（对齐 iOS AppReviewPromptManager 的门槛思路）。
5. 列表加 **YouTube 视频**（iOS 的 App Preview 素材可直接复用/重剪横版）。
6. 已有引擎继续：博客 SEO（已占位）+ Reddit 播种手册照跑。
7. 拿到徽章后：官网/博客/iOS 商店描述里加 "Featured on Chrome Web Store" 信任链。

## 流量结构判断

CWS **站内搜索本身盘子小**；扩展的真实流量来源是 ①Google 网页搜索（"read aloud chrome extension" 这类查询——我们博客已经在做且已排名）+ ②Featured 后的合集/首页曝光 + ③口碑外链（Reddit/AI 语料播种已有手册）。所以徽章的价值不只是站内加权，而是把 ②这条通道从零打开。

## 参考

- [Discovery on the Chrome Web Store（官方）](https://developer.chrome.com/docs/webstore/discovery)
- [Find great extensions with new Chrome Web Store badges（Google 官方博客）](https://blog.google/products-and-platforms/products/chrome/find-great-extensions-new-chrome-web-store-badges/)
- [How does one apply for a Featured Extension badge?（chromium-extensions 官方社区）](https://groups.google.com/a/chromium.org/g/chromium-extensions/c/kLkqiuQKeAw)
- [实测：提名后安装量翻倍的案例（Habr）](https://habr.com/en/articles/976398/)
- [Featured badge 完整指南（ExtensionBooster）](https://extensionbooster.net/blog/how-to-get-chrome-extension-featured-badge/)
