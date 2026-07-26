# CastReader iOS 九语全功能合同

权威语言目录及顺序固定为：英语 `en`、简体中文 `zh`、日语 `ja`、西班牙语 `es`、法语 `fr`、德语 `de`、巴西葡萄牙语 `pt-BR`（内部主码 `pt`）、意大利语 `it`、印地语 `hi`。

## 输入入口

| 输入 | 语言判定 / OCR | 阅读渲染 | 朗读与解读 |
|---|---|---|---|
| 相机、相册、文件图片、剪贴板图片、系统分享图片 | 原始像素先判定语言，最终只用一个语言 profile；Hindi 使用 Tesseract | 原图 + OCR 几何 | 九语 TTS、高亮、解读 |
| PDF（完整文字层） | 本地文本检测 | PDFKit 原排版 + 精确 range | 九语 TTS、高亮、解读 |
| PDF（扫描 / 混合） | 页面无损高分辨率渲染后走统一图片 OCR | OCR 文本重排 | 九语 TTS、高亮、解读 |
| DOCX | mammoth.js 提取 DOM 后统一语言检测 | WebView 原排版 | 九语 TTS、DOM 高亮、解读；检测结果写回历史 |
| EPUB | 原生解析后统一语言检测 | 原生文本 / 图片 | 九语 TTS、高亮、解读 |
| TXT / Markdown / 输入文本 / 剪贴板文本 | 统一语言检测 | 原生文本 | 九语 TTS、高亮、解读 |
| URL / 网页 | DOM 正文提取后统一语言检测 | WebView 原排版 | 九语 TTS、DOM 高亮、解读；检测结果写回历史 |
| Kindle | 书籍语言 profile + 单语言 OCR 路由 | Kindle 页面 + OCR 几何 | 九语 TTS、高亮、解读 |

## 不可分叉的共享规则

1. UI 本地化必须同时具有 `en/zh-Hans/ja/es/fr/de/pt-BR/it/hi`，不可在业务 View 写死某一种语言。
2. OCR 多语言阶段只负责选语言；生成最终文字和几何时必须使用一个确定的语言 profile。
3. Vision 不支持 Hindi 时不得静默退回英文，必须使用 `hin` Tesseract 模型。
4. OCR 使用原始、方向归正后的像素；JPEG 只允许在 OCR 完成后用于显示和历史存储。
5. 句界统一由 `ReadingSentenceContract` 提供，必须覆盖 `。！？；…`、`.!?;`、Hindi `।॥` 及尾随引号。
6. 中文 / 日文视觉硬换行不得变成 TTS 停顿；PDF 的日文假名也按 CJK 连续文本处理。
7. 词级高亮与语言无关：每个实际音频 segment 都必须独立校验 timestamp 数量、文本覆盖率、时间单调性和音频有效区间；通过则使用词级高亮，失败只让当前 segment 回退句/segment 高亮。中文、日文整句只有一个 timestamp 的响应必须判定为句级。
8. 朗读、解读、音色、速度、额度、付费墙、后台播放和历史重开都消费同一个规范化语言码，不得按输入格式另建语言表。

## 回归门槛

- `SupportedTTSLanguage.allCases` 必须恰好为上述九种且顺序一致。
- 九个 Tesseract 模型必须随包存在：`eng/chi_sim/jpn/spa/fra/deu/por/ita/hin`。
- `Localizable.xcstrings`、`InfoPlist.xcstrings` 与分享扩展字符串目录的每个 key 必须具有九个 locale。
- 九语句界、逐段 timestamp 质量闸门、German/Hindi OCR 选择、PDF 原生 / OCR 重排分流必须有纯合同测试。
- 发布前真机抽测每种语言至少覆盖：图片、扫描 PDF、DOCX 或网页、朗读、解读、音色切换和历史重开。
