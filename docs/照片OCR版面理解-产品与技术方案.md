# 照片 OCR 版面理解 —— 产品与技术方案

> 适用 iOS（本仓库）与 Android 同类实现。触发点：用户反馈「阅读英文报纸有点没识别排版」。
> 版本：2026-08-06。配套文档：`iOS-Nine-Language-Service-Contract.md`、`CastReader-数据采集与隐私边界.md`、`高亮与mark颜色统一规范.md`。

## 0. 一句话

**照片入口现在被实现成「扫描仪」（假设用户拍的是一页单栏规整文档），但用户实际把它当「取景器」（我想听画面里这一块内容）。** 缺的不是 OCR 识别精度，而是 OCR 与段落之间的**版面理解层**（列检测 + 阅读顺序 + 角色分类），以及「读哪一块」的用户控制权。

---

## 1. 根因（代码级）

用户截图里的英文报纸是多栏排版 + 跨栏大标题。当前管线必然读错，且**两条路径都错**：

| 位置 | 代码 | 问题 |
|---|---|---|
| `OCRService.rebuildOcrLines` | 按 `centerY` 把**整幅图**上高度相近的词聚成一「行」，无任何 x 方向约束 | 左栏第 3 行与右栏第 3 行 centerY 相同 → 合成一行 → 文本变成「左栏行1 + 右栏行1 + 左栏行2 + 右栏行2…」 |
| 同上，容差 `max(base, line.height * 0.7)` | 容差取自**行组的累积高度** | **雪球效应**：行组越高越贪吃，最终把整段吞进一行。实测一张 987 词的报纸被吞成 2 行乱序词流 —— 这是「整页读成乱序」的直接原因，**单栏页面同样中招** |
| `OCRService.groupLinesIntoParagraphs` | 按 `bbox.maxY` 降序排 Vision 行 → 纯 y 排序 | 跨栏行交错，段落聚类同样乱 |
| `rebuildKindleParagraphBoxes` 的 `collapsedTooMuch` 兜底 | 回落到上面那条 `fallback` | **兜底路径也是单栏假设**，救不回来 |

`recognizeImportedImage` 最终固定走 `.kindleLayout` 策略，因此拍照 / 相册 / 剪贴板 / 系统分享图片 / 扫描版 PDF 页 / Kindle 页**全部**吃这个缺陷。

> Kindle 已经踩过一次这个坑，解法是把页图**物理裁成左右两半**各跑一遍 OCR 再 remap 回全页坐标（`KindleBookView.mergeKindleColumnDocuments`）。那是「已知恰好两栏、栏宽相等」的特例，报纸的栏数 / 栏宽 / 跨栏标题都是未知量，套不上。本方案实现的通用列检测**应反向覆盖该特例**，Kindle 侧后续可迁移。

### 1.1 连带影响

- **解读（Explain）**：`MarkAnchoring` 在 `fullText` 上模糊匹配，段落乱序会让 mark 锚到错误位置（不会崩，但标注画错地方）。阅读顺序修好后自动受益，无需单独改。
- **扫描版 PDF**：`DocumentBuilder.fromPDF` 的 OCR 分支复用同一入口，双栏论文同样错乱。

---

## 2. 分层诊断

| 层 | 现状 | 缺口 |
|---|---|---|
| L0 采集 | `UIImagePickerController` 原始照片 | 无边缘检测 / 透视矫正 / 去阴影 / 多页；拍歪的报纸直接喂 Vision |
| L1 识别 | Vision 九语探针 + 单语言复识 + Hindi Tesseract | **不是瓶颈**，保持不动 |
| L2 版面 | ❌ 不存在 | 多栏、跨栏标题、图注、边栏、页眉页脚、页码全部平铺进正文朗读 |
| L3 阅读单元 | 整页全读 | 一张报纸有多篇文章，用户只想听其中一篇 |
| L4 交互补救 | ❌ 无 | 识别错了不能重拍 / 框选 / 编辑 / 排序，只能退出 |
| L5 度量 | ❌ 无 | 线上不知道多少张照片翻车 |

### 2.1 真实场景分布（对「正确」的定义各不相同）

| 类型 | 例子 | 当前表现 |
|---|---|---|
| A 单栏文档 | 书页、打印稿、合同 | ✅ 已适配 |
| B 多栏报刊 | 报纸、杂志、双栏论文 | ❌ 本次问题 |
| C 屏幕截图 | 网页/APP 截图 | ⚠️ 状态栏、导航、按钮被当正文读 |
| D 短文本实体 | 菜单、招牌、说明书、包装 | ⚠️ 非线性版面，顺序随机 |
| E 手写 | 笔记、白板 | ⚠️ 识别本身弱，超出本次范围 |
| F 幻灯片 | PPT 拍照 | ⚠️ 标题与要点被合并 |

本方案 P0 覆盖 B，附带改善 C/D/F；E 不在范围内。

---

## 3. 目标与非目标

**目标**
1. 多栏版面的**阅读顺序**正确（栏内自上而下，栏间自左而右，跨栏标题在前）。
2. 页眉 / 页脚 / 页码 / 水印等**版面家具**不进入朗读。
3. 版面分析失败时**行为不退化**（完整回落现有单栏路径）。
4. 用户可以决定**读哪一块**，而不是被迫听整页。
5. 全链路**离线**，照片与正文不因版面分析而上行。

**非目标**
- 不引入云端版面分析模型（照片不上传是产品承诺，也是离线可用前提）。
- 不为报纸写专用 hack。
- 不做手写体识别增强。
- **可选项（默认不做）**：把块级文本发给 quickread 后端让 LLM 定阅读顺序。效果更好，但朗读路径当前是纯本地的，这会改变隐私边界，需产品单独拍板后才可启用。

---

## 4. P0 — 版面理解层（根因修复）

### 4.1 新增 `Services/OCRLayoutAnalyzer.swift`

纯函数、不依赖 Vision/UIKit 运行时、可离线单测。输入是行级 `LayoutInputLine`（归一化 bbox，**统一转成原点左上的 layout 坐标**），输出块序列。

```
analyze(lines:pageAspect:language:) -> LayoutAnalysis
  ├── 1 估算正文度量：medianLineHeight / medianLineWidth / 页面左右边界
  ├── 2 剥离跨栏元素：宽度 > bodySpan * 0.72 且（字高 > 正文中位 * 1.25 或位于页顶）
  │      → fullWidthBand，按 y 保序插回
  ├── 3 列检测（XY-cut 垂直投影）
  │      ├── 把剩余行投影到 x 轴，得到覆盖直方图
  │      ├── 找连续空白带（gap ≥ medianLineHeight * 0.9 且贯穿 ≥ 60% 纵向范围）
  │      ├── 候选切分 1..6 栏，逐一打分
  │      └── 取最高分；分数 < 阈值 → 判单栏（保守 fail-safe）
  ├── 4 每列内按 y 排序 → 段落聚类（沿用现有 gap/缩进/终止符规则，但只在列内生效）
  ├── 5 角色分类 role：heading / body / caption / furniture
  └── 6 阅读顺序：跨栏块 → 其下方各列（左→右），交错保序输出
```

**列检测打分**（三项加权，全部可单测）：

| 因子 | 含义 | 权重 |
|---|---|---|
| `gapQuality` | 分隔带最小宽度 / medianLineHeight，越宽越可信 | 0.4 |
| `alignment` | 各列内行左边界的标准差（越小越像真栏） | 0.35 |
| `balance` | 各列行数、列宽的均衡度（报纸栏宽通常相近） | 0.25 |

低于 `Constants.OCRLayout.minColumnConfidence`（初值 0.55）→ 返回单栏，`fallbackReason` 记录原因。

**角色分类**（启发式，不上模型；语言无关优先用几何）：

| role | 判据 | 是否朗读 |
|---|---|---|
| `heading` | 字高 > 正文中位 * 1.25，或跨栏且行数 ≤ 3 | ✅ 读 |
| `caption` | 紧邻大面积空白/图片区，字高 < 正文中位 * 0.85，且行数 ≤ 4 | ✅ 读（可关） |
| `furniture` | 位于页面顶部/底部 6% 带内且行数 = 1；或纯页码；或重复出现的刊头 | ❌ **不读** |
| `body` | 其余 | ✅ 读 |

`furniture` 映射为现有 `ReadingParagraphType` 的不可读类型，复用 `isReadable` 门控，**不新增渲染路径**。

### 4.2 `OCRService` 改造点（已实现）

1. **行重建改由引擎行定边界**（`layoutLines(from:)`）：Vision / Tesseract 的行识别对倾斜是鲁棒的，只在**行内部**按 x 邻接拆分（该行横跨栏缝时）。纯几何重建在手持拍摄的 10° 倾斜下必然跨行错并 —— 一行的右端可以比下一行的左端还低。
2. **`groupWordsIntoLines` 修掉雪球**：纵向容差固定取页面中位词高，不随行组增高放大；并要求同行 x 邻接。
3. **两阶段版面分析**（`rebuildKindleParagraphBoxes`）：
   - 第一遍用原始行判列；
   - 若多栏，用列边界把「被 OCR 误连成一行的跨栏行」按词切开，再分析一次；
   - 仍是多栏才采用，否则完整回落。
4. 多栏时按块聚类（块内只有同一列的行 → 段落聚类天然获得列约束）；跨块再跑一次 `repairBrokenContinuations`，缝合「一栏底部续到下一栏顶部」的断句。
5. **单栏路径不改变既有段落聚类**，只额外剔除版面家具行 —— 保证零退化。
6. `ReadingParagraph.id` 仍连续重排（保 mark 锚定与批次不错位）；`ReadingParagraphType` 不新增 case，家具行在进入段落前就被滤掉。

#### 误连行判据（踩坑记录）

区分「真跨栏元素」和「被 OCR 误连的两栏行」，试过三种判据：

| 判据 | 结果 |
|---|---|
| 行高 ≤ 中位 × 1.15 | ❌ 分不开。实测通栏图注 1.7×、误连行 1.47×，正文行高本身波动就有 ±50% |
| 栏缝处有词间大空隙 | ❌ 不可用。`VNRecognizedText.boundingBox(for:)` 对长行是按字符**均匀插值**的，栏缝的物理空白被压没（实测只剩 0.002） |
| **两端是否贴栏边界** | ✅ 采用。误连行是两个满栏行拼接，左端贴起始栏左边界、右端贴结束栏右边界；通栏图注居中排版两端都不贴边；大标题满宽但由字号上限（2.5×）单独挡掉 |

### 4.3 诊断与埋点

P0 先落**本地诊断日志**（`KindleRunLog`，DEBUG only）：`OCR_LAYOUT columns=… confidence=… blocks=… roles=… paras=…`，以及回落原因。

线上埋点事件 `ocr_layout_result` 归入 **P3** 与 eval 集一起做（要同步改事件契约、校验脚本与测试，独立成批更稳）。字段：`columns`、`confidence`、`fallbackReason`、`roleCounts`、`lineCount`、`charCount`、`language`、`contentSource`。

**严禁**携带 `content` / `text` / `ocrText` / `imageData` / `title` / `fileName` 等 —— 见 `CastReader-数据采集与隐私边界.md`，`ProductAnalytics.validate` 会直接抛错。

---

## 5. P1 — 采集质量（已实现）

版面理解建立在「正投影页面」的假设上：栏是竖直的、行是水平的。手持拍摄的报纸倾斜十几度、带梯形畸变时，投影直方图会糊掉。这一层在采集阶段就把画面拉正，比事后补救可靠得多。

| 项 | 做法 | 文件 |
|---|---|---|
| 文档扫描 | 拍照入口优先用 VisionKit `VNDocumentCameraViewController`：系统级边缘检测 + 透视矫正 + 去阴影 + **多页连拍**。设备不支持或扫描器起不来时回落 `CameraView`（用 `forcePlainCamera` 标记，避免来回弹同一个失败的扫描器） | `Views/Capture/DocumentScannerView.swift` |
| 相册图矫正 | `VNDetectDocumentSegmentationRequest` 取四角 → `CIPerspectiveCorrection`。**四重保护**：置信度门槛、四边长度不退化、面积占比 ≥ 25%、对边长度比 ≤ 2.0；任一不满足就原样返回 | `Services/ImagePreprocessor.swift` |
| 质量闸 | 最短边像素 + 拉普拉斯方差（在 512 宽灰度缩略图上测，与原图分辨率无关） | 同上 |
| 多页合并 | 见 5.1 | `ViewModels/CaptureFlowViewModel.swift` |

矫正后的图像**同时**用于 OCR 与显示，否则 bbox 与画面对不上（现有铁律：OCR 用原始方向归正像素，JPEG 压缩只在 OCR 后用于显示/历史）。扫描器产出的页面已由 VisionKit 矫正，不再二次矫正（`alreadyRectified`）。

### 5.1 多页 → `.text` 而不是多图 `.photo`

**单页走 `.photo`**（原图 + 词 bbox，高亮与标注画在照片上）；**多页扫描合并成 `.text`**（重排文本连续朗读）。

理由：多页更像「一份文件」而不是「一张照片」，照片叠加在多图上既无处安放，也不是用户在那个场景下要的东西。这同时避免了为多图渲染改造 `PhotoReaderCanvas`（单图 `UIScrollView` + aspectFit）。合并时段落 id 连续重排、跳过不可读段与空段。

### 5.2 质量提示的时机

识别**成功**时不提示 —— 用户已经在听了，弹窗只是打扰。只有识别**失败**时才把「为什么」和「怎么改」一起说清楚：

```
未识别到文字
画面有点模糊，端稳手机重拍会识别得更准
```

三条新文案已按九语合同补齐 `Localizable.xcstrings`（9 个 locale 全覆盖）。

> ⚠️ 改 xcstrings 用**文本插入**，不要 `json.dump` 全量回写：原文件是 Xcode 风格（`" : "` 分隔，且部分条目单行紧凑），全量序列化会重排整个文件（实测 31593 insert / 25593 delete）。按字母序插入条目的做法只产生纯增量 diff。

---

## 6. P2 — 把「读哪一块」交给用户（已实现）

一张报纸照片常包含好几篇文章，用户通常只想听其中一篇。

**做法：用户在原图上拖框选区**（`Views/Reader/PhotoRegionPicker.swift`）。

- 触发条件（`PhotoRegionCropper.shouldOfferSelection`）：`.photo` 源 + 多栏 + 可定位段落 ≥ 6。**单栏、短页面完全不打扰**。
- 交互：识别完成 → 全屏展示原图，拖拽框选 → 「只读选中部分」/「读整页」二选一。
- 裁剪（`PhotoRegionCropper.crop`）：段落与选框重叠 ≥ 自身面积 50% 才算选中（擦到边的不进来，框住大部分的不漏掉）；裁剪后段落 id 连续重排；**选区落空返回 `nil` → 回退整页**，绝不产出空文档。
- 选择发生在**进入阅读器之前**，因此不触碰阅读器常驻生命周期。

### 6.1 为什么不做自动文章分割

原方案设想「自动识别文章块 + 自动选主块」。实测放弃：报纸的文章会**跨栏续接**、共用大标题、被图片和广告打断，自动分割是研究级难题；**猜错比不猜更糟** —— 用户会得到一篇被腰斩的文章，还不知道为什么。

框选是所见即所得的：一次拖拽就说清了意图，没有误判空间。

### 6.2 单一 cover 铁律

采集的三个全屏阶段（普通相机 / 文档扫描 / 选读区域）合并进**一个** `fullScreenCover`，由 `CaptureStage` 枚举驱动 —— 同屏挂多个 sheet/cover 会互相吞（CLAUDE.md 避坑指南第 9 条）。

### 6.3 未做（留给后续）

- 长按框选任意区域 → 仅对该区域**重新 OCR**（当前是从已识别结果里筛，不重识别）
- 「看原图 / 看文本」切换与文本编辑兜底

---

## 7. P3 — 回归集与线上度量

### 7.1 离线 eval（已实现）

`CastReaderTests/Fixtures/ocr-layout-*.json` 存**真实报纸照片的 Vision 行几何**：

| fixture | 来源 | 锁住什么 |
|---|---|---|
| `ocr-layout-three-column-newspaper` | Stars and Stripes 1944-04-25 p3（公有领域），相机扫描，297 行 | 3 栏识别、无块横跨两列、块内行自上而下、不丢行不重复 |
| `ocr-layout-skewed-single-column` | 手持拍摄、约 12° 倾斜的报纸页 | 倾斜不被误判成分栏 |

**只存几何，不存文本**：报纸正文有版权，而版面分析本来就只吃几何（fixture 里只保留每行的字符数 `n`）。样本图片同样不入 git。

重新生成 fixture：验证台 `ocrlab`（macOS CLI）跑 `OCRLAB_EXPORT=<path> OCRLAB_EXPORT_NAME=<name> ./ocrlab <image>`。

测试：`CastReaderTests/OCRLayoutFixtureTests.swift`。其中 `testNoBlockSpansTwoColumns` 是**核心不变量** —— 正是修复前失败的地方。

### 7.2 线上埋点（设计完成，待双端同步后启用）

事件 `ocr_layout_result`：

| 字段 | 说明 |
|---|---|
| `columns` | 判定栏数 |
| `layoutConfidenceBucket` | 置信度分桶（避免上报原始浮点） |
| `fallbackReason` | 回落单栏的原因（`low-confidence-47` / `columns-merged-to-one` / …） |
| `lineCount` / `headingCount` / `bodyCount` / `captionCount` / `furnitureCount` | 规模与角色分布 |
| `language` / `engine` | 语言与识别引擎 |

**严禁**携带 `content` / `text` / `ocrText` / `imageData` / `title` / `fileName` 等 —— 见 `CastReader-数据采集与隐私边界.md`，`ProductAnalytics.validate` 会直接抛错。

> ⚠️ **为什么还没启用**：埋点是**跨端契约**。`scripts/verify_mobile_analytics_contract.rb` 会同时比对 iOS Swift 定义、Android Kotlin 定义与 `docs/analytics/mobile-events-v2.json` 三方一致；单方面加 iOS 事件必然让校验失败。启用需要与 Android 同批提交。
>
> 顺带记录：跑该脚本需要 UTF-8 环境（`LANG=en_US.UTF-8 RUBYOPT="-EUTF-8"`，否则 Ruby 以 US-ASCII 读带中文注释的源码会抛 `invalid byte sequence`）。当前校验**本来就是失败的** —— Android 侧的契约副本落后于 iOS（缺 `se/tr/ae/sg/pl/eg/sa` 等 storefront 值），这是既有漂移，与本次改动无关，但会在加事件前需要一并对齐。

P0 期间的诊断走本地日志（`KindleRunLog`，DEBUG only）：

```
OCR_LAYOUT columns=3 confidence=61 blocks=15 roles=["heading": 6, "body": 9] paras=…
OCR_LAYOUT columns=1 reason=low-confidence-47 lines=296->294
```

### 7.3 线上分桶（待埋点启用后）

photo 源的朗读完成率 / 中途退出率 / 重新导入率，按 `columns` 与 `fallbackReason` 分桶。

---

## 8. 验收标准

| # | 标准 | 验证方式 | P0 状态 |
|---|---|---|---|
| 1 | 多栏报纸照片的段落顺序 = 人眼阅读顺序，无跨栏拼接 | 真实报纸照片实测 + 单测 | ✅ 3 栏报纸实测通过 |
| 2 | 跨栏大标题排在其所属栏组之前 | 单测断言 | ✅ |
| 3 | 页码 / 刊头不进入朗读文本 | 单测断言不在 `readableLineIDs` | ✅ |
| 4 | 单栏文档段落聚类与改造前一致（仅额外剔除版面家具） | 单测 + 全量回归 | ✅ 单栏路径未改动聚类逻辑 |
| 5 | 分析低置信 → 回落原路径，不抛错、不空文档 | 单测构造噪声输入 | ✅ |
| 6 | 倾斜照片不再把整段吞成一行 | 单测（雪球回归）+ 真实照片 | ✅ |
| 7 | 九语不回归（含日文竖排、Hindi） | 现有 `EvalTests` + Kindle 路径 | ✅ 全量测试通过 |
| 8 | 埋点不含任何正文/图像字段 | `ProductAnalyticsTests` + 契约校验脚本 | ⏳ 随 P3 |

### 8.1 P0 实测数据（真实相机拍摄样本）

| 样本 | 修复前 | 修复后 |
|---|---|---|
| 手持拍摄的英文报纸（倾斜，60 词） | **2 行**，第 2 行是 58 词乱序流 | **15 行**，语序完整 |
| 3 栏报纸整版（987 词） | **2 行**，985 词全乱 | 正确识别 **3 栏**（边界 0.405 / 0.696，置信度 0.611），15 个块按「报头 → 跨栏标题 → 左栏 → 中栏 → 右栏 → 下半部各栏」输出；被误连的跨栏行正确切回各自栏 |
| 报摊照片、荷兰语老报纸 | — | 无退化 |

验证台：`ocrlab`（macOS CLI，Vision OCR → 版面分析，对照修复前后）。样本从 Wikimedia Commons 下载到 scratchpad，**不入 git**（版权 + 体积）。

---

## 9. 跨端说明（Android）

**落地指引全文见 `照片OCR版面理解-Android落地指引.md`**，本节只列要点。

`OCRLayoutAnalyzer` 是纯几何算法、无 iOS 依赖，可 1:1 回译 Kotlin。所有阈值以**页宽/页高比例**表达，Android 必须先把 ML Kit 的像素坐标归一化再进分析器，否则阈值随分辨率漂移、双端行为立刻分叉。

两端缺陷**不完全一样**，不能照抄：

| | iOS | Android |
|---|---|---|
| 行重建雪球 | ❌ 有（词级重建，容差随行组增高） | ✅ 无（直接用 ML Kit 的 `Text.Line`）——**不要**移植 `groupWordsIntoLines` |
| 全局 y 排序导致多栏交错 | ❌ 有 | ❌ 有（`KindleOcrParagrapher.sortedLines`） |
| 列检测 / 角色分类 | ❌ 无（本次新增） | ❌ 无（需新增） |
| 词框可靠性 | 插值，**不可**用于找栏缝断点 | 真实几何，可作二次确认（但默认应与 iOS 判据一致） |

fixture 双端复用：`CastReaderTests/Fixtures/ocr-layout-*.json` 是归一化坐标 + 纯几何，Android 复制到 `app/src/test/resources/` 即可跑同一套断言。核心不变量「无块横跨两列」两端都要有。

埋点需**双端同批**提交（`verify_mobile_analytics_contract.rb` 三方比对），且当前 Android 契约副本已落后于 iOS，加事件前要先对齐。
