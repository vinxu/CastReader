# App Store 评分增长 v2

## 目标与边界

在用户已经获得明确朗读价值、且界面处于安全空档时调用 Apple 原生评分请求；设置页同时提供中性的 App Store 评价入口和独立反馈入口。

系统不会记录或推断评分弹窗是否展示、用户是否提交、星级或评论内容。`RequestReviewAction` 由系统决定是否真正展示。

## 自动资格

本地持久化状态由 `CastReader/Services/AppReviewPromptManager.swift` 管理：

- 首次成功连接 Kindle、微信读书、Google Play 图书、Kobo 或 O’Reilly 书架后立即获得资格；
- 或者第一次自然朗读完当前内容后立即获得资格；
- 旧版“72 小时 + 2 个活跃日 + 3 个五分钟阅读会话”继续作为兼容兜底；
- 同一版本最多调用一次；
- 两次调用至少间隔 90 天；
- 滚动 365 天最多调用 3 次。

连接必须来自可信书架同步成功；加载失败或普通页面访问不计。朗读完成必须来自播放器自然走到当前内容末尾；手动停止、失败、配额拦截不计。资格满足时仅写入 `pending`，不会在阅读器内立即打断用户。

旧版五分钟兜底的朗读时长仍只累计同一音频 segment 内 `0 < delta <= 2.01s` 的正向播放器 tick。跳读、回退和异常时间跳变不能制造评分资格。

Kindle 与微信读书的自动续页会显式移交同一个评分阅读会话：无缝预取成功、普通 fallback 翻页都可让短页跨页累计到 300 秒，且不会被误算成多个不同会话。页末通常先生成 one-shot continuation token；若微信读书的页面确认早于音频完成且必须走 fallback，则会在 stop 前快照仍活跃的会话。两种 token 都只有已确认的自动下一页提交能消费；翻页失败、末页、手动换页/目录跳转、停止、重播、换书或切换模式都会丢弃并开始新会话。

证据集合是有界的：活跃日最多保留 2 个、合格会话最多保留 3 个、尝试记录只保留滚动窗口内最多 3 条；另存最近尝试版本用于同版本频控。

## 展示安全窗口

`CastReader/Views/MainTabView.swift` 仅在以下条件连续稳定 2 秒后调用 SwiftUI `RequestReviewAction`：

- App 位于前台且回到 MainTab 首页；
- 播放已完全静止（包括没有 buffering、流式队列没有等待下一段），原生/Kindle 阅读器均已收起；
- 没有首次引导、付费墙、系统 sheet、剪贴板/收件箱 sheet、导入/OCR/PDF 处理蒙层或音色浮层。

调用前先原子地写入本次尝试，调用返回后记录 `success`。这里的 `success` 只表示系统 API 已调用，不表示 Apple 展示了弹窗，也不表示用户提交了评分。

## 设置入口

`CastReader/Views/Settings/SettingsView.swift` 的“支持与反馈”包含：

- “评价 CastReader”：打开 `https://apps.apple.com/app/id6757636395?action=write-review`；
- “发送反馈”：打开 `support@castreader.com` 邮件入口。

三个设置字符串均覆盖运行时 9 种语言：`en`、`zh-Hans`、`ja`、`es`、`fr`、`de`、`pt-BR`、`it`、`hi`。

## Analytics v2

权威合同是 `docs/analytics/mobile-events-v2.json`。既有 v1 队列继续兼容，但以下新增事件仅接受 v2 envelope：

| event | 必填属性 | 可选属性 | legacy event |
| --- | --- | --- | --- |
| `review_prompt_eligible` | `trigger`, `store` | — | `rating_prompt_eligible` |
| `review_request_attempted` | `trigger`, `store`, `result` | `errorCode` | `rating_prompt` |
| `review_store_link_opened` | `trigger`, `store` | — | `rating_store_link_opened` |

固定值：

- `store=app_store`
- 自动资格/请求：`trigger=first_read_completed`、`library_connected`，旧版兜底为 `third_five_minute_read`
- 设置页商店链接：`trigger=settings`
- `review_request_attempted.result` 仅允许 `success` 或 `failed`

禁止新增 `shown`、`submitted`、`rating` 等无法由 Apple API 可靠观测的事件或属性。

## 验证

`CastReaderTests/ProductAnalyticsTests.swift` 覆盖：

- canonical 22-event 合同与 legacy 映射；
- 三个新事件的严格属性和值校验；
- 首次成功朗读完成与首次可信书架连接立即进入 pending，且同一版本只尝试一次；
- 旧版 72 小时、2 活跃日、3 个不同 5 分钟会话兼容兜底；
- 同版本一次、90 天冷却、滚动 365 天 3 次上限；
- 状态持久化、调用即计尝试、证据集合有界；
- Kindle/微信读书无缝与 fallback 自动翻页的逻辑阅读会话移交、手动翻页丢弃和单次 5 分钟计数；
- 流式段落等待、buffering、Home OCR/PDF 处理中均阻止展示；
- 三个设置字符串的 9 语言完整性。
