# Kindle 适配：产品与技术方案

> 状态：iOS 正式 Kindle 入口与首版播放链路已落地（2026-07-03）。已完成：首页 6 场景横向 chips、Kindle 独立模块、Connect Kindle 登录 WebView、原生书架缓存/搜索/排序/分页、书籍 WebView、当前页/后续页 blob 图片捕获、Vision OCR、`.kindle` ReadingDocument 合成、现有 ReaderHostView 的朗读/解读复用、播放段落到 Kindle 原页面的 page key 同步。仍需后续硬化：真账号多书长时间连续播放、Amazon 验证码/二次验证处理、播放中无限低水位预取、安卓同功能对齐。

## 1. 结论先行

Kindle 适配可以做，但它不是普通 Web 链接朗读，也不是先抓完整本书再播放。扩展已经把 Kindle 的核心架构摸清楚了，App 端应当最大化复用扩展的判断和 schema，而不是重新发明一套。

正确架构是：

`播放当前页 TTS -> 推进 Kindle WebView 加载下一屏/下一页 -> 捕获新 blob 图片 -> OCR -> 生成下一段 TTS -> 接续播放`

核心约束：

- iOS 后台能力必须绑定真实音频播放。没有持续 TTS 播放时，App 只能获得短暂后台时间，不能稳定静默抓取。
- Kindle Cloud Reader 的正文主要以 blob 图片渲染，不能依赖普通 DOM 文本。
- App 端必须参考扩展的 Kindle 适配：`documentStart` 注入、hook `URL.createObjectURL`、给图片算 content key、OCR、缓存、预取。
- 扩展当前偏翻页模式，手机 Kindle 更像滚动模式；两者差异只在“如何推进页面”，本质都是：渲染图片 -> OCR -> TTS -> 高亮/mark -> 预加载 -> 预生成，避免卡顿。
- 朗读和解读都应由同一套 Kindle 页面捕获/OCR 管线供给，只是后续消费不同：朗读消费原文，解读消费 QuickRead 讲解和 marks。

## 2. 已验证事实

### 2.1 扩展侧 Kindle 架构

扩展不是用普通正文 DOM 提取 Kindle 内容，而是组合两条链路。App 端应以这些逻辑作为基准实现：

1. Main world 拦截 Kindle `/renderer/render` 请求。
   - 解析 TAR 包。
   - 提取 tokens、layout_data、page_data。
   - 累积 `allTokenPages`，用于定位页序、段落、页码和 layout。

2. Main world hook `URL.createObjectURL`。
   - 捕获 Kindle 创建的 `image/* Blob`。
   - 用 `sha256(size + first 256B)` 生成 content key。
   - 维护 `originalBlobUrl -> contentKey`。
   - 维护 `contentKey -> liveUrl`，避免 Kindle revoke 原 blob URL 后图片不可用。
   - LRU 保存最近页面，用于当前页 OCR 和下一页预 OCR。

扩展后续流程：

- 找当前可视 blob 图片。
- canvas 抓图，必要时按单双栏切图。
- tesseract-wasm OCR 得到段落和 word boxes。
- 用 OCR 文本做 TTS。
- 用 word boxes 做高亮/overlay。
- 当前页播放时触发下一页预 OCR。

扩展与手机端的主要差异：

- 扩展端主要面对桌面 Kindle Cloud Reader 的翻页/页模式。
- 手机端 Kindle Cloud Reader 当前表现为滚动加载。
- 两者不是两套架构，区别只是 page advancement actuator：
  - 扩展：点击/模拟翻页、scrubber、左右箭头或页码推进。
  - 手机：滚动容器、触摸滑动、滚动 runway 推进。
- downstream pipeline 必须一致：blob key、OCR、word boxes、TTS、overlay、prefetch、QuickRead 承接。

### 2.2 iOS Probe 结果

测试时间：2026-07-02。

无音频保活时：

- 锁屏后 JS/native tick 只能继续约 8 秒。
- Probe 音频初始化失败，日志出现 `OSStatus -50`。
- 不能作为稳定后台能力依据。

有音频保活时：

- `audio session active`
- `debug audio loop ON`
- `APP didEnterBackground` 后，JS/native tick 持续运行。
- 锁屏后台阶段出现新的 Kindle blob 图片：
  - `20:02:27 [background] IMAGE saved key=331181cb ...`
  - `20:02:28 [background] IMAGE saved key=5eea1281 ...`
- 拉出的缩略图确认为真实 Kindle 书页。

结论：只要真实 TTS 持续播放，iOS 锁屏后台下 WKWebView 仍能继续推进 Kindle 页面，并且 App 可以持续拿到新 blob 图片用于 OCR。但这个能力不应设计成静默后台任务。

### 2.3 iOS MVP 骨架进度

已落地：

- 新增 `ReadingSourceKind.kindle`，明确区分 Kindle 多页 OCR 图片源和普通拍照图片。
- `ReadingParagraph.pageIndex` 标记 OCR 段落属于哪一张 Kindle 渲染页。
- 新增 `KindleReaderView`：按页展示 Kindle 渲染图片，并把朗读高亮 / 解读 mark 通过 OCR bbox 叠回原图。
- DEBUG Kindle probe 支持：
  - 捕获当前页为单页 `ReadingDocument(.photo)`，快速验证朗读/解读。
  - 预取后续页面，缓存 page key、OCR 段落和图片。
  - 将缓存页合成为 `ReadingDocument(.kindle)`，验证多页连续朗读/解读。
- `ReadAloudViewModel` 已把 `.kindle` 纳入 OCR 图片高亮路径；无词时间戳时也能按 OCR 词线性推进。
- 文库和封面逻辑已兼容 `.kindle`，但历史重开先退化为 OCR 文本，避免未产品化的多页缓存格式污染正式历史。

仍未完成：

- 正式 Kindle 首页模块和书架 UI。
- 播放中根据 TTS 队列低水位自动滚动 WebView、持续捕获/OCR/TTS 下一页。
- 解读跨页 `prev_summary` 与 1-3 页逻辑批的正式 coordinator。
- Kindle 会话持久化、ASIN / 书名 / 阅读位置记录。

## 3. 产品目标

### 3.1 用户目标

用户在 App 首页点击 Kindle 后，可以：

- 登录 Kindle Cloud Reader。
- 看到自己的 Kindle 书架。
- 点击一本书进入阅读。
- 直接朗读 Kindle 书内容，锁屏后持续播放。
- 朗读时原文可高亮跟随。
- 对 Kindle 书进行解读，听 AI 讲解，同时在原文上 mark 重点。

### 3.2 产品边界

CastReader 仍然是工具型 TTS / 解读应用，不变成图书 App：

- 不提供书城。
- 不售卖 Kindle 图书。
- 不保存 Amazon 密码。
- 不绕过用户登录。
- 不承诺离线导出整本 Kindle 书。

Kindle 是一个“内容连接器 + 播放会话”，不是普通导入源。

## 4. 设计原则

所有 Kindle 设计遵循三条原则：

### 4.1 明确目标

每一步都服务于一个明确目标：

- 当前页 OCR：拿到可以立即播放的文字和高亮坐标。
- 下一页预取：保证 TTS 不断流，从而保持后台能力。
- content key：识别页面内容是否变化，避免重复 OCR。
- QuickRead：让用户听懂当前/连续页面，而不是逐页重复开头。

### 4.2 定义工具

Kindle 管线里定义稳定工具，而不是到处写临时逻辑：

- `KindleWebSession`：登录态、WKWebView、cookie / website data store。
- `KindleLibraryScanner`：扫描书架元数据。
- `KindleRenderInterceptor`：注入 JS，拦截 render / blob。
- `KindleBlobStore`：content key、live URL、LRU、缩略图。
- `KindleOCRPipeline`：图片 OCR、word boxes、段落聚合。
- `KindlePlaybackPipeline`：TTS 队列、预取阈值、后台播放。
- `KindleExplainPipeline`：OCR 文本 -> QuickRead -> marks -> 解说 TTS。
- `KindleOverlayResolver`：word boxes / mark anchors -> WebView overlay 坐标。

### 4.3 LLM 决策

LLM 只参与“如何解读”，不参与底层抓取。

底层确定性管线负责：

- 页面识别。
- 图片捕获。
- OCR。
- 段落和 word bbox。
- TTS 队列。

LLM 负责：

- 当前内容应该怎么讲。
- 哪些 span 值得 mark。
- mark 使用何种 action / weight / role。
- 连续页之间如何承接上下文。

## 5. 推荐交互

### 5.1 首页入口

首页新增 Kindle 模块，建议作为独立入口，而不是混在“输入 URL”里：

- 标题：Kindle
- 副标题：朗读和解读你的 Kindle Cloud Reader 书籍
- 状态：
  - 未登录：Connect Kindle
  - 已登录：Open Library
  - 上次阅读：Continue `<book title>`

### 5.2 登录流程

点击 Kindle：

1. 打开 App 内 Kindle WebView。
2. 进入 `https://read.amazon.com/kindle-library`。
3. 用户在 Amazon 官方页面完成登录。
4. App 只保存 WKWebsiteDataStore 中的 cookie / local storage，不接触密码。
5. 登录后扫描书架。

需要提供：

- 退出 Kindle 登录。
- 清除 Kindle 会话数据。
- 登录失效时重新登录。

### 5.3 书架流程

书架页展示：

- 封面。
- 标题。
- 作者。
- 阅读进度，如可取得。
- 最近打开状态。

点击书籍：

- 打开 Kindle Reader WebView。
- 等待页面 ready。
- 显示底部控制：朗读 / 解读 / 倍速 / 停止。
- 用户点击朗读或解读后才进入播放驱动管线。

### 5.4 朗读流程

朗读不是一次性抓完整本，而是连续流：

1. 识别当前可视 Kindle blob 图片。
2. OCR 当前页。
3. 生成当前页 TTS。
4. 开始播放。
5. 播放期间推进 WebView 到下一屏/下一页。
6. 捕获新 blob 图片。
7. OCR 下一页。
8. 提前生成下一页 TTS。
9. 当前页播完后无缝接下一页。

这里的“推进”在不同端有不同实现，但不改变核心链路：

- 桌面扩展：推进到下一页。
- 手机 App：滚动到下一屏 / 下一段 Kindle 预渲染窗口。
- 两者都以“新 blob 图片 content key 出现”为真正成功信号，而不是以 scrollTop 或页码作为唯一依据。

播放队列目标：

- 最低：当前页正在播放，下一页 OCR 中。
- 理想：当前页播放中，下一页 TTS 已就绪，再下一页图片已捕获。
- 警戒：队列剩余音频小于 20 秒时，优先暂停标注/缩略图等非关键任务，把资源给 OCR/TTS。

### 5.5 解读流程

解读同样以页面流推进，但不能让每页都像重新开始。

推荐：

1. 当前页 OCR。
2. 将当前页文本和 `prev_summary` 交给 QuickRead。
3. 生成讲解块。
4. 对讲解文本做 TTS。
5. 回填 mark 时刻。
6. 播放讲解。
7. 同时预取下一页 OCR。
8. 下一页 QuickRead 带上上一页摘要承接。

解读的批次策略：

- 不按“整本书”一次提交。
- 不按“每页孤立”提交。
- 以 1-3 个 Kindle 页面组成一个逻辑批，目标体量约 1500-3500 字。
- 由内容长度、当前 TTS 缓冲、OCR耗时动态决定批大小。

## 6. 技术架构

### 6.1 新模块

建议新增目录：

`CastReader/Services/Kindle/`

核心类型：

- `KindleSessionService`
  - 持有 WKWebView 配置。
  - 管理 Kindle 登录态。
  - 提供清除会话。

- `KindleBridge`
  - 注入 JS。
  - 处理 JS -> Native message。
  - 输出 render / blob / state 事件。

- `KindleBlobRegistry`
  - 记录 content key。
  - 记录 live URL 或 native data snapshot。
  - LRU。
  - 避免重复 OCR。

- `KindleOCRService`
  - 接收图片 data。
  - 调用端上 Vision OCR。
  - 输出 `ReadingDocument` / paragraphs / `OCRWord`。

- `KindlePlaybackCoordinator`
  - 管理朗读状态机。
  - 管理 TTS 队列。
  - 管理滚动推进和预取。
  - 抽象 `advance()`，iOS 用滚动，扩展用翻页，Android 依据 WebView 行为选择滚动或翻页。

- `KindleExplainCoordinator`
  - 管理 QuickRead 解读。
  - 管理 `prev_summary`。
  - 管理 marks 和 overlay。

### 6.2 JS 注入

注入时机：

- 必须 `documentStart`。
- 必须在 page/main world 生效，确保 hook 到 Kindle 自己调用的 `URL.createObjectURL` / `fetch`。

JS 侧能力：

- hook `URL.createObjectURL`。
- hook `URL.revokeObjectURL`。
- 计算 content key。
- 维护最近 N 张图片。
- 记录 blob URL -> key。
- 记录 key -> live URL。
- 捕获当前可视图片。
- 报告图片数量、bestKey、recentKeys。
- 可选：拦截 `/renderer/render`，解析 tokens/layout/page_data。

实现要求：

- 优先移植扩展已验证逻辑。
- content key 算法必须与扩展一致。
- blob LRU 窗口大小和策略应参考扩展，不随意扩大。
- render intercept / blob registry / image selection / OCR cache schema 尽量共享。
- 手机滚动模式新增的只是推进策略，不能改掉扩展已验证的捕获和缓存策略。

iOS 与扩展差异：

- 扩展有 content script / main world / isolated world 分层。
- iOS WKWebView 不需要完全照搬隔离模型，但要保留职责分层。
- 关键是不能等页面结束后再扫描，必须从文档开始就 hook。

### 6.3 图片与 OCR

图片抓取策略：

- 当前页：找 viewport overlap 最大的 blob img。
- 新页面识别：content key 变化。
- 重复页面：key 命中则复用 OCR。
- 图片压缩：OCR 前按最大宽度缩小，减少 Vision 成本。
- 双栏判断：按图片宽高比和 layout 数据综合判断。

OCR 输出：

- 段落文本。
- word boxes。
- 图片尺寸。
- 页序 key。
- OCR 质量分：
  - 文本长度。
  - 平均置信度，如可取得。
  - word box 数量。
  - 重复文本比例。

### 6.4 TTS 后台策略

生产环境不能用静音音频保活，必须播放用户可听的真实 TTS。

状态机：

- `idle`
- `loadingCurrentImage`
- `ocrCurrent`
- `generatingCurrentTTS`
- `playing`
- `prefetchingNextImage`
- `ocrNext`
- `generatingNextTTS`
- `bufferLow`
- `pausedByUser`
- `ended`
- `error`

后台原则：

- 只有播放中才推进 WebView。
- 暂停后停止后台抓取。
- 音频队列将空时优先生成下一页 TTS。
- 如果下一页 TTS 赶不上，允许短暂 loading，但要避免音频完全断流。

### 6.5 高亮与 mark

朗读高亮：

- Kindle 不使用普通 `ReaderTextView`。
- 使用 WebView overlay。
- OCR word boxes 映射到当前图片坐标。
- TTS timestamps 映射 OCR words。
- 当前词或句子在图片上叠加高亮。

解读 marks：

- QuickRead 返回 mark 锚文本。
- 先在 OCR 段落中锚定字符范围。
- 再通过 OCR word boxes 合成 bbox。
- 在 WebView 当前图片上绘制手写 mark。
- 若页面已滚走，mark 数据仍保留；回到对应页面时可重绘。

## 7. 与现有系统的关系

### 7.1 与 ReadingDocument

Kindle 可以输出临时 `ReadingDocument(.photo/.text-like)`，但不建议把 Kindle 书永久当普通文档保存。

建议：

- 每个 Kindle 页面 / 批次转换成统一段落模型，供 TTS / QuickRead 复用。
- Kindle 会话本身由 `KindlePlaybackCoordinator` 管，不完全塞进现有 `ReadAloudViewModel`。
- 复用现有 `TTSService`、`AudioPlayerService`、`QuickReadService`、`MarkAnchoring` 的能力。

### 7.2 与文库

文库可以保存 Kindle 最近阅读记录，但不要保存整本 Kindle 内容。

记录：

- book asin。
- title。
- author。
- cover。
- last position。
- last read time。
- 本地 OCR/TTS cache key，可设过期。

### 7.3 与 Pro

Kindle 属于高级入口，应走统一 Pro 标准：

- 登录后传 `device_id + user_id + email`。
- 状态由 `/api/pro/status` 判定。
- 免费用户可以试用少量分钟。
- iOS / Android / Web / 扩展口径必须一致。

## 8. Android 规划

Android 也应按同一架构推进，不要另起一套“普通 WebView 读 DOM”的实现。

关键对齐项：

- WebView 注入必须早于 Kindle 创建 blob。
- hook `URL.createObjectURL`。
- content key 算法与 iOS / 扩展一致。
- 图片 OCR 输出格式一致。
- TTS 队列和后台播放策略一致。
- 解读 `prev_summary` / mark schema 一致。

Android 需要额外验证：

- 锁屏后台 WebView JS 是否在 MediaSession + foreground service 下持续运行。
- 如果 JS 被暂停，是否可用 native 定时任务唤起 WebView evaluateJavascript。
- 是否需要前台服务通知保证持续播放。

## 9. 测试计划

### 9.1 Probe 级测试

已完成：

- 前台滚动后能看到 Kindle 页面推进。
- 有音频播放时，锁屏后台可继续 tick。
- 锁屏后台可抓到新 Kindle blob 图片。

还要补：

- 1 分钟锁屏测试。
- 5 分钟锁屏测试。
- 网络较差测试。
- 不同 Kindle 书籍排版测试。
- 横屏 / 字号变化 / 单双栏变化测试。

### 9.2 OCR 测试

样本：

- 英文小说。
- 英文非虚构。
- 中文书。
- 带脚注/引用的书。
- 图片较多的书。
- 字号大/小。

指标：

- OCR 文本可读率。
- 段落切分合理性。
- word boxes 覆盖率。
- 当前页识别是否稳定。
- 重复页 key 是否命中缓存。

### 9.3 TTS 连续播放测试

指标：

- 连续播放 10 分钟不断流。
- 锁屏播放 10 分钟不断流。
- 队列低水位恢复能力。
- TTS 失败重试。
- 用户暂停后后台抓取停止。
- 用户恢复后继续从当前位置播放。

### 9.4 解读测试

指标：

- 每页不是重新开头。
- `prev_summary` 能承接上下文。
- mark 与原文位置对应。
- 长书连续 5-10 个批次不乱序。
- 解读和朗读切换不会抢播放器回调。

### 9.5 验收标准

MVP 达标：

- 能登录 Kindle。
- 能展示书架。
- 能打开一本书。
- 能朗读当前页并自动推进下一页。
- 锁屏 5 分钟内持续播放，且能继续获取内容。
- 至少英文单栏书高亮可用。

Beta 达标：

- 朗读 30 分钟稳定。
- OCR cache 有效，重复页不重复识别。
- 解读支持连续 5 批以上。
- mark 定位可接受。
- 异常恢复可用。

上线达标：

- iOS / Android 行为一致。
- 免费/Pro 口径一致。
- 隐私说明清楚。
- 不保存 Amazon 密码。
- 失败提示可理解。

## 10. 分阶段实施

### Phase 0：实验封版

目标：把 Probe 结论固化。

- 保留 Debug Probe，但不进入 Release。
- 整理锁屏后台日志和图片证据。
- 明确：生产必须真实 TTS 播放，不做静默后台抓取。

### Phase 1：Kindle Connector 骨架

目标：有正式入口和登录态。

- 首页 Kindle 入口。
- Kindle WebView 登录页。
- 会话持久化 / 清除。
- 书架扫描。
- 点击书籍进入阅读 WebView。

### Phase 2：图片捕获和 OCR

目标：当前页可转成可朗读文本。

- 正式 JS bridge，优先从扩展 Kindle bridge 抽取。
- blob content key，与扩展算法一致。
- 当前可视图捕获。
- Vision OCR。
- OCR cache。
- 当前页段落和 word boxes。

### Phase 3：朗读闭环

目标：播放驱动连续读。

- 当前页 TTS。
- TTS timestamps -> word boxes 高亮。
- 当前页播放时预取下一页。
- 队列低水位策略。
- 锁屏后台 5-10 分钟测试。

### Phase 4：解读闭环

目标：Kindle 可连续解读。

- OCR 文本批次组装。
- QuickRead with `prev_summary`。
- 讲解 TTS。
- mark 锚定到 OCR words。
- 批间预取。

### Phase 5：稳定性与双端对齐

目标：可给用户使用。

- Android 同步实现。
- iOS/Android/扩展 schema 对齐。
- Pro 口径统一。
- 失败恢复。
- 多书籍、多语言、多排版测试。

## 11. 主要风险

### 11.1 后台能力风险

风险：音频断流后，iOS 会挂起 App，WebView 不再继续加载。

应对：

- TTS 队列必须保持缓冲。
- 后台抓取只在播放中运行。
- 队列低水位时停止非关键任务。

### 11.2 Kindle 页面结构变化

风险：Amazon 修改 Cloud Reader DOM / render 接口。

应对：

- JS bridge 做版本化。
- 关键 selector 多策略。
- 失败时保留诊断日志。
- 与扩展共用核心 JS 逻辑或 schema。

### 11.3 OCR 成本和速度

风险：Vision OCR 跟不上播放速度。

应对：

- 图片缩小。
- content key cache。
- 只 OCR 当前/下一页。
- 优先级队列：当前页高优先，预取低优先。

### 11.4 合规风险

风险：用户 Kindle 内容和 Amazon 服务条款边界敏感。

应对：

- 用户自行登录官方 Kindle 页面。
- 不保存 Amazon 密码。
- 不导出整本书。
- 不提供分享/下载 Kindle 内容。
- 只为用户本人做即时朗读/辅助理解。
- 上线前补隐私说明和合规确认。

## 12. 需要给各端 agent 的指令

### iOS agent

- 先不要把 Debug Probe 直接产品化。
- 新建正式 Kindle 模块，复用 Probe 已验证的 `documentStart + blob key + image snapshot` 方向。
- 以扩展 Kindle 实现为主参考，优先对齐其 content key、LRU、image selection、render intercept、OCR cache 设计。
- iOS 端新增的是滚动推进器，不是另写一套 Kindle 提取器。
- 生产只用真实 TTS 保持后台，不使用静音音频。
- 当前页 OCR/TTS 完成前，不推进太快。
- 所有日志带 book/session/page key，便于追踪。

### Android agent

- 按同一 schema 实现 Kindle WebView bridge。
- 同样参考扩展 Kindle 架构，差异只放在 WebView 推进策略上。
- 验证锁屏 + TTS + foreground service 下 WebView 是否继续执行。
- 若 Android WebView 后台 JS 暂停，设计 native tick / evaluateJavascript 方案。
- 输出与 iOS 一致的 blob key / OCR / paragraph / word bbox 数据。

### 扩展 agent

- 抽取 Kindle JS bridge 中可复用的 content key / blob registry / render intercept 逻辑。
- 提供简化版 schema 给 iOS/Android 复用。
- 保持扩展现有能力不回退。
- 明确哪些逻辑是桌面翻页特有，哪些逻辑是所有端共用；共用逻辑优先沉淀为 portable bridge。

## 13. iOS 当前落地清单

### 13.1 产品 UI

- 首页 6 个解读场景已收起为横向 chips，不再占首页大面积。
- Kindle 是独立内容源，不塞进 6 场景。
- 未连接时显示 `Connect Kindle`。
- 连接页使用 `WKWebView` 打开 `https://read.amazon.com/kindle-library`，用户在 Amazon 官方页面登录。
- 登录后通过 `KindleLibrarySyncViewModel` 扫描书架并缓存到 `KindleLibraryStore`。
- 首页展示最近 Kindle 书籍；完整 `KindleLibraryView` 支持搜索、排序、本地分页、刷新同步。
- 书架卡片字段：封面、书名、作者、进度、最近打开/同步时间。

### 13.2 数据与会话

- `KindleBook`：本地保存 ASIN、title、author、coverURL、readerURL、progressLabel、lastOpenedAt、lastSyncedAt、lastReadPageKey、lastReadURL。
- Amazon 登录态只存在 `WKWebsiteDataStore.default()` 的 cookie/session/local storage；CastReader 不保存 Amazon 密码。
- 书架刷新通过 WebView 重新打开 Kindle library 并滚动扫描，合并新书/进度/封面/链接。
- `KindleWebScripts.scrapeLibrary` 同时支持普通 `<a href>` 和 `data-asin` 卡片；无链接但有 ASIN 时合成 `https://read.amazon.com/?asin=ASIN`。

### 13.3 书籍页与播放

- `KindleBookView` 保留原 Kindle WebView 页面，不把 Kindle 页面替换为自有容器。
- 用户可手动滚到任意位置；点击 `Read Aloud` 或 `Explain` 后，从当前可视 Kindle blob 图片开始捕获。
- `KindleWebScripts.pageCaptureBootstrap` 在 documentStart 注入，hook `URL.createObjectURL`，建立 blob image content key、live URL、visible image snapshot、scroll、scrollToKey。
- `KindleBookViewModel.prepareDocument(pageBudget:)` 抓当前页和后续页，Vision OCR 后合成为 `ReadingDocument(sourceKind: .kindle)`。
- `.kindle` 文档每页包含一个 image paragraph，后跟该页 OCR 段落；OCR 段落带 `pageIndex` 和 word bbox。
- 播放进入现有 `PlayerCoordinator.open(...)`，复用 `ReaderHostView`、`ReadAloudViewModel`、`ExplainViewModel`、`ReadControlBar`、`ExplainControlBar`、速度菜单、字幕、停止/重试、Pro/额度逻辑。
- 播放时 `KindleBookViewModel.follow(...)` 监听当前朗读段落或解读 scrollTarget，按 paragraph.pageIndex 找 page key，并调用 `__crKindleScrollToKey` 同步底层 Kindle 原页面位置。
- 用户关闭 Reader 后会回到 KindleBookView，底层 WebView 已尽量停在当前播放页。

### 13.4 已验证

- `xcodebuild -workspace CastReader.xcworkspace -scheme CastReader -destination 'platform=iOS Simulator,id=652EE2B6-1ABE-414A-A24E-7BA9AF28E93A' -derivedDataPath build-kindle-sim build` 通过。
- UI 自动化通过：
  - `testHomeShowsScenarioChipsAndKindle`
  - `testKindleConnectOpensWebView`
  - `testPlusOpensImportSheet`
  - `testScenarioTapOpensSourcePicker`
- 可选真账号测试 `testKindleAmazonLoginAndSyncWhenCredentialsProvided` 已加入，默认无凭据时 skip；执行时通过环境变量传入，不把凭据写进代码。

### 13.5 当前限制

- 由于不能把 Amazon 密码写入命令、日志或仓库，自动化真账号登录需要在本机安全注入环境变量或人工完成登录；Amazon 也可能触发验证码/二次验证。
- 当前首版按批次预取若干页并生成 `.kindle` 文档；播放中无限低水位预取/自动换批仍需继续硬化。
- Kindle Cloud Reader DOM 变化风险仍在，必须持续参考扩展端 blob/render 适配逻辑。

## 14. Android 对齐任务

Android agent 必须实现与 iOS 对齐的 Kindle 功能，不做降级版：

1. 首页 6 场景收为横向 chips；Kindle 作为独立内容源。
2. 未登录态 `Connect Kindle`，登录后显示原生 Kindle 书架，不直接展示 read.amazon.com 书架网页。
3. 书架字段对齐 iOS：封面、书名、作者、进度、最近打开/同步时间。
4. 完整书架支持分页、刷新、搜索、排序。
5. 使用 Android WebView 登录 `read.amazon.com`，保存本机 cookie/session；不保存 Amazon 密码。
6. 书架同步逻辑对齐 iOS/扩展：扫描 library DOM，支持 `<a href>` 与 `data-asin`，从 ASIN 合成 reader URL。
7. 书籍页保留 Kindle 原页面；底部显示 CastReader 的 `Read Aloud` / `Explain` 操作。
8. 点击朗读/解读，从当前可视 Kindle 页面开始，而不是从书架或第一屏开始。
9. Android WebView bridge 对齐 iOS 的 `KindleWebScripts.pageCaptureBootstrap`：
   - hook `URL.createObjectURL`
   - content key
   - live blob URL
   - current page snapshot
   - scroll / scrollToKey
   - state diagnostic
10. OCR 输出统一为 page image + OCR paragraphs + word bbox，能进入 Android 现有 TTS 高亮/mark 管线。
11. 朗读、解读、速度、字幕、停止、重试、Pro/额度闸门都复用 Android 已有 Reader/Player UI，不另造 Kindle 专用播放器。
12. 播放时同步底层 Kindle WebView 到当前 page key；关闭播放器回到书籍页时停在当前播放位置。
13. 后台/锁屏必须用真实 TTS/Foreground Service 保活，验证 WebView 是否还能继续滚动/抓图；不能用静音保活作为产品方案。
14. 做 Android 模拟器测试：未登录入口、登录 WebView、书架同步、打开书籍、当前页捕获、朗读 TTS+高亮、解读 TTS+mark、停止、重试、回到书籍页位置。
