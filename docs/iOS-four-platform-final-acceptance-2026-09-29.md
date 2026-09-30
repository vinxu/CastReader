# iOS 四平台最终验收执行单

状态：执行中，尚未通过。2026-09-29 用户要求重新逐项复核三份文件；本执行单只针对 iOS 自有 WKWebView。Android 不因共享参考代码而算通过。iPad 暂无设备，不能计入已验证范围。

## 冻结依据

2026-09-30 补查：指南新增 Kindle K13–K16，当前 SHA-256 为 `7318a7b5c2c52ecc5e4e0ec164cb8120f0785fa715e7703fd4c9f76f77e264dd`，须补验缓存准入、共享失败重试预算、暂停与迟到响应。下方旧哈希保留为开始时的冻结依据。

- `docs/ebook-pagination-mobile-parity-guide-2026-09-29.md`：SHA-256 `fa1cbf66a62be6ec104882b2cf1f351a63a2231cf3227b3c118c15bfbcdb4da0`。
- `docs/ebook-pagination-mobile-acceptance-template.md`：SHA-256 `d0a8e9adb95b5ef33acee0998fb2aff2be522aa38b1edd1381e46258ae4226f4`。
- `reports/ebook-document-audit-2026-09-29/validation.md`：SHA-256 `1325c2590b910fa709efb203677902d63c0575acce7bb7404f85cbd0a6a51da7`。

## 范围与不可替代的证据

- Kindle、WeRead、Play Books、Kobo × Read、Explain，八个组合各自验收。
- 真机 iPhone 15 Pro Max / iOS 26.7；不使用模拟器。版本 1.2.48 (71) 的各迭代必须以 manifest 的 source identity 和 dylib UUID 区分。
- 最终构建每个优先组合连续前台 ≥30 分钟、≥3 完整章节、≥20 次自动翻页；操作干预不计入。核心组合另做 ≥2 小时。
- warm 额外等待 P95 ≤100 ms / max ≤200 ms；原生请求→呈现、同片段 hold→playing、相邻片段 ended→playing 三项分别计算，保留动画与冷路径总等待。
- 漏读、重复、错页/错栏/无锚点仍播放、重复导航、双声、停止后复活均为零容忍。真实音频 A/B 与语义审核不能用单元测试替代。
- T01–T17、控制矩阵和解读五阶段 × 四种操作完整填写；取消后观察至少 60 秒。
- 每次 source/分页、队列/媒体、取消/所有权、解读接管修改后，相关最终长测重跑。旧构建时长不累计。

## 最终构建矩阵（尚未冻结最终候选）

| 平台 | 模式 | T01–T17 适用项 | 真实控制矩阵 | 连续30分钟/3章/20页 | 核心2小时 | 判定 |
|---|---|---|---|---|---|---|
| Kindle | Read | 未完成最终构建验收 | 未完成 | 未执行 | 未执行 | 不通过/未完成 |
| Kindle | Explain | 未完成最终构建验收 | 未完成 | 未执行 | 未执行 | 不通过/未完成 |
| WeRead | Read | 未完成最终构建验收 | 未完成 | 未执行 | 未执行 | 不通过/未完成 |
| WeRead | Explain | 未完成最终构建验收 | 未完成 | 未执行 | 未执行 | 不通过/未完成 |
| Play Books | Read | 未完成最终构建验收 | 未完成 | 未执行 | 未执行 | 不通过/未完成 |
| Play Books | Explain | 未完成最终构建验收 | 未完成 | 未执行 | 未执行 | 不通过/未完成 |
| Kobo | Read | 未完成最终构建验收 | 未完成 | 未执行 | 未执行 | 不通过/未完成 |
| Kobo | Explain | 未完成最终构建验收 | 未完成 | 未执行 | 未执行 | 不通过/未完成 |

当前定点/夹具证据仅记录在 [实施报告](iOS-four-platform-pagination-2026-09-29.md) 和 candidate manifests，不填入最终长测栏。

## 开放问题对应审计编号

| 指南项 | iOS 位置 | 当前缺口及关闭证据 |
|---|---|---|
| R01 / O02,O06,O07,Q04 | WebReader/src/kobo.ts、mark-renderer.ts、source-text.ts | 受控投影/隐藏源已修改，尚需实际 Kobo 当前页源范围、左右栏/重排截图与语义审核 |
| R02 / Q01–Q06 | ExplainViewModel.PrefetchedFirstBlock、WebReaderBridge、KindleBookView | 同 job 首完整块接管、精确预解码租约和有界后继 producer 已有真机回归及 Kobo 定点记录；仍需最终长测、短页冷路径、摘要按书/章/跳转接力与语义审核 |
| R03 / G09 | play-books-native-pages.ts、WebReaderBridge | 可靠下一章源的提前准备与无源等待；实际跨章总等待待量测 |
| R04 / C18,C23 | TTSService、AudioPlayerService、ReadAloudViewModel | 短段缓冲/慢请求注入、真实克隆、首声与全部 underrun；不得将慢请求直接归咎服务器 |
| R05 | AudioPlayerService.finishPagePresentation、站点绘制回执 | WeRead live32 214/230ms、Google live43 804ms 已判失败；Google live47 native paint 路径 258/252/256ms 仍失败，第五页锚点未就绪导致停止 |
| R06 / C15 | 本执行单、各 manifest、ReaderRunLog | 所有最终构建长测与源覆盖账本仍未完成 |
| R07 / T17 | WebReaderBridge、ExplainViewModel、QuickReadService | 目录旧来源/取消重试有定点修复，但五阶段取消时延与60秒观察矩阵仍需完整执行 |
| R08 | iOS WKWebView + 原生桥 / Kindle OCR | 当前载体能力已有定点证据；不得宣称第三方阅读 App 或 Android 已适配 |
| C21 / G13 | play-books-native-pages.ts + ReadAloudViewModel | 已关闭24字符末页未呈现的真实生产链路反例待补；未关闭源继续背压 |
| C22 / G14 / O08,O09 | WebReaderBridge、播放完成逻辑 | 完成画面、所有控件空闲、零多余Next、迟到回调隔离及音频间隔需独立验收 |
| C07 / W06 | TTS source cue → liveWeb boundary | 私人中文克隆 source timing 缺失仍导致保护性停止。服务端中文候选38项本地合同通过、单条真实中文样本CPU对齐有29个实测区间；未部署、无线上/iOS通过证据，生产私有备份凭据待定位；预设通过不能覆盖 |
| G02 / T05 | Play Books 图像页检测 | SVG封面识别与进度条跳转清源已修改，iteration47 真实停留超过60秒、下一页/目录转正文定点通过；最终回归待跑 |
