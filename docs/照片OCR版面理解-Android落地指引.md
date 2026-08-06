# 照片 OCR 版面理解 —— Android 落地指引

> iOS 已实现并用真实报纸照片验证（详见 `照片OCR版面理解-产品与技术方案.md`，本文是它的 Android 落地版）。
> 阅读顺序：先读方案文档的第 1、4 节（根因与算法），本文只讲 Android 怎么改、哪些**不要**照抄。
> 版本：2026-08-06。

---

## 0. 一句话目标

让安卓拍报纸/杂志/双栏论文时，**按人眼的阅读顺序**朗读：栏内自上而下、栏间自左而右、跨栏大标题排在前面，页码刊头不朗读。

触发点是 iOS 用户反馈「阅读英文报纸有点没识别排版」。同一张照片在 Android 上会以**另一种方式**读错（见第 2 节），所以不能等 iOS 改完直接抄，要按本文对症下药。

---

## 1. iOS 侧已验证的结论

真实相机拍摄样本实测：

| 样本 | 修复前 | 修复后 |
|---|---|---|
| 手持拍摄的倾斜报纸（60 词） | **2 行**，其中 1 行是 58 个词的乱序流 | **15 行**，语序完整 |
| 3 栏报纸整版（987 词） | **2 行**，985 词全乱 | 正确识别 **3 栏**，15 个块按「报头 → 跨栏标题 → 左栏 → 中栏 → 右栏 → 下半部各栏」输出 |

修复由三件事组成，Android 只需要其中两件（见下节）。

---

## 2. Android 现状诊断（按代码）

### 2.1 ❌ 会错：全局按 top 排序 → 多栏交错

`KindleOcrParagrapher.sortedLines()`：

```kotlin
return raw.sortedWith { a, b ->
    val topDelta = a.top - b.top
    if (abs(topDelta) > max(4.0, medianHeight * 0.5)) topDelta else a.left - b.left
}
```

整页行按 `top` 排序，同高度按 `left`。在 3 栏报纸上产出的顺序是「左栏行1、中栏行1、右栏行1、左栏行2、中栏行2…」—— 每读一行就跳一次栏。

随后 `shouldStartNewParagraph()` 在这个交错序列上按 gap/缩进切段，段落边界同样是乱的。

**这是 Android 的主缺陷，必须修。**

### 2.2 ✅ 不用改：Android **没有** iOS 的「雪球」缺陷

iOS 的 `rebuildOcrLines` 会把行拆成词再纯几何重建行，容差随行组累积高度增长 → 一个行组把整段吞掉。**Android 不做词级行重建**，直接用 ML Kit 的 `Text.Line`，所以没有这个问题。

> ⚠️ **不要**照抄 iOS 的 `OCRLayoutAnalyzer.groupWordsIntoLines`。那个函数是 iOS 为了修自己的历史包袱写的；Android 引入它只会把可靠的 ML Kit 行拆散再拼回去，纯属倒退。

### 2.3 ❌ 会错：没有列检测 / 没有角色分类

`shouldStartNewParagraph` 只看垂直间隙、缩进、句子终止符，全部建立在**整页单栏**假设上。页码、刊头、页脚同样会进入朗读文本。

### 2.4 ⚠️ 半成品：`OcrColumn` 只是外部传入

`OcrLine.column: OcrColumn { SINGLE, LEFT, RIGHT }` 与 `mergeColumnPages()` 是 Kindle 双栏 spread 的特例 —— 那是把页图**物理裁成两半**各跑一遍 OCR 后标注的，不是检测出来的。报纸的栏数、栏宽、跨栏标题都是未知量，套不上。

新的列检测应当**反向覆盖**这个特例：`mergeColumnPages` 后续可迁移到通用实现。

---

## 3. 必须新增：`OcrLayoutAnalyzer.kt`

iOS 的 `CastReader/Services/OCRLayoutAnalyzer.swift` 是**纯几何算法，无平台依赖**，可 1:1 回译 Kotlin。建议放 `app/src/main/java/com/same/castreader/util/ocr/OcrLayoutAnalyzer.kt`。

### 3.1 坐标约定（第一件要做对的事）

| 端 | OCR 原始坐标 | 分析器输入 |
|---|---|---|
| iOS | Vision 归一化，**原点左下** | layout 归一化，**原点左上** |
| Android | ML Kit 像素，**原点左上** | layout 归一化，**原点左上** |

**Android 必须先归一化再进分析器**：`x / imageWidth`、`y / imageHeight`。

理由：本文所有阈值都是**页宽/页高比例**，两端必须同值。用像素会让阈值随分辨率漂移，双端行为立刻分叉。

```kotlin
fun OcrLine.toLayoutLine(id: Int, page: OcrPage) = LayoutLine(
    id = id,
    text = text,
    x = left.toDouble() / page.imageWidth,
    y = top.toDouble() / page.imageHeight,
    w = (right - left).toDouble() / page.imageWidth,
    h = (bottom - top).toDouble() / page.imageHeight
)
```

### 3.2 阈值表（**两端必须同值**）

```kotlin
object LayoutTuning {
    const val MIN_COLUMN_CONFIDENCE = 0.55   // 低于此回落单栏
    const val MAX_COLUMNS = 6
    const val PROJECTION_BINS = 600          // 报纸栏缝约 1% 页宽，粗直方图会整条吞掉
    const val COVERAGE_VALLEY_RATIO = 0.22   // 覆盖低于峰值该比例即视为空白
    const val GAP_SHOULDER_RATIO = 0.30      // 栏缝两侧必须是实打实的正文
    const val SHOULDER_WINDOW_RATIO = 0.05   // 判断「两侧是正文」时向外看多宽
    const val COLUMN_OCCUPANCY_RATIO = 0.45  // 行占据某列的判据
    const val FURNITURE_BAND_RATIO = 0.06    // 顶/底版面家具带
    const val MIN_LINES_PER_COLUMN = 3       // 少于此与相邻列合并
}
```

改任一数值都要同步改 iOS，并跑两端的 fixture 回归（第 8 节）。

### 3.3 算法规格

```
analyze(lines) -> LayoutAnalysis
  1 medianHeight = median(行高)
  2 栏缝检测 columnGaps()
      a 垂直投影：每个 x bin 被多少行覆盖
        ⚠️ 只累计**完全**落在行内的 bin：lo = ceil(minX*bins), hi = floor(maxX*bins)-1
           向外取整会让 1% 页宽的栏缝被两侧 bin 吃掉，直方图变成一整片高台
      b 找连续低覆盖区间（<= 峰值 * 0.22）
      c 丢弃触及页面左右边缘的区间（那是页边距）
      d 宽度 >= max(0.0015, medianHeight * 0.15)
        ⚠️ 栏缝可以只有一个 bin 宽，**不要**用宽度当主判据
      e 两侧邻域峰值（各看 5% 页宽）>= 峰值 * 0.30
        ⚠️ 用邻域**峰值**而非紧邻单个 bin：栏边缘覆盖天然衰减，
           且各栏行数本就能差一倍（一栏被插图截断、另一栏通到页底）
      f 记录 depth = 1 - 缝内最低覆盖 / min(左峰, 右峰)
  3 列区间 = 相邻栏缝中点切分；行数 < 3 的列并入相邻列（迭代到稳定）
  4 打分（见 3.4），< 0.55 回落单栏
  5 跨栏行 = 同时占据 >= 2 列 → 聚成横幅带（banner）
  6 阅读顺序：横幅带把页面分层，每层内各列左→右、列内上→下
     ⚠️ 最后做一次全域清扫，把夹在横幅带内部的漏网行补上 —— 绝不丢内容
  7 角色分类（见 3.5）
```

### 3.4 打分（四项加权）

```kotlin
val gapQuality = minDepth * 0.7 + widthScore * 0.3   // 干净程度为主，宽度为辅
val alignment  = 1 - clamp(列内行左边界 MAD / (列宽 * 0.18))
val occupancy  = clamp(median(行宽 / 列宽) / 0.75)
val balance    = 1 - min(1, max(列宽变异系数, 行数变异系数))
val total = gapQuality * 0.35 + alignment * 0.30 + occupancy * 0.20 + balance * 0.15
```

> **踩坑记录**：最初 `gapQuality` 只按缝宽打分，3 栏报纸实测只得 0.12，整体 0.47 < 0.55 被判单栏。报纸栏缝仅约 1% 页宽但**缝内几乎无字**，所以「干净程度（depth）」才是主信号。

### 3.5 角色分类（启发式，不上模型）

| role | 判据 | 朗读 |
|---|---|---|
| `HEADING` | 行高 > 正文中位 × 1.25 且行数 ≤ 4；或跨栏且行数 ≤ 3 | ✅ |
| `CAPTION` | 行高 < 正文中位 × 0.85 且行数 ≤ 4 | ✅ |
| `FURNITURE` | 单行块 + 位于顶/底 6% 带内 + 行高 ≤ 中位 × 1.6 + （纯数字/罗马数字 或 ≤ 40 字符） | ❌ |
| `BODY` | 其余 | ✅ |

`FURNITURE` 的四个条件缺一不可，否则会误删只有一行文字的页面。**兜底**：剔除后若无可读内容，全部保留 —— 宁可多读，绝不产出空文档。

---

## 4. 必须改：`KindleOcrParagrapher`

### 4.1 入口改成「先判列、再按块聚类」

```kotlin
fun rebuildNaturalPage(page: OcrPage, language: String = "en"): OcrPage {
    val lines = sortedLines(page)
    if (lines.size <= 1) return page.copy(blocks = page.blocks.mapNotNull(::normalizeBlock))

    val analysis = OcrLayoutAnalyzer.analyze(lines.toLayoutLines(page))
    if (!analysis.isMultiColumn) {
        // 单栏：段落聚类流程**一字不改**，只额外剔除版面家具行
        return rebuildSingleFlow(readableLines(lines, analysis), language, page)
    }

    // 多栏：按阅读顺序逐块聚类。块内只有同一列的行 → 段落聚类天然获得列约束
    val blocks = analysis.blocks
        .filter { it.role.isReadable }
        .flatMap { block -> rebuildSingleFlow(block.lineIds.map(lines::get), language, page).blocks }
    // 跨块再缝一次「一栏底部续到下一栏顶部」的断句
    return page.copy(blocks = mergeBrokenParagraphs(blocks, language, false))
}
```

**铁律：单栏路径不改变既有段落聚类逻辑**，只加家具过滤。这样单栏文档零退化，改动风险集中在多栏分支。

### 4.2 `sortedLines` 的全局排序只在**块内**用

原来的 `sortedWith { top, then left }` 保留，但只作用于**同一列（块）内**的行。跨列顺序由版面分析决定。

---

## 5. 两阶段拆分：被 OCR 误连的跨栏行

ML Kit 和 Vision 一样，偶尔把两栏里**同高度的两行**识别成一整行（报纸底部尤其常见）。这种行会被当成跨栏横幅，把两栏的半句话拼一起读出来。

### 5.1 流程

```
第一遍 analyze(原始行)                → 得列边界
若多栏：用列边界把误连行**按词**切成每列一段
第二遍 analyze(切开后的行)            → 仍是多栏才采用，否则完整回落
```

### 5.2 判据：**两端是否贴栏边界**

```kotlin
fun isMisjoinedColumnLine(line: LayoutLine, columns: List<ClosedRange<Double>>): Boolean {
    val tolerance = 0.12
    val first = columns.firstOrNull { it.endInclusive > line.x } ?: return false
    val last = columns.lastOrNull { it.start < line.x + line.w } ?: return false
    if (first.start >= last.start) return false        // 没跨列
    val firstWidth = first.endInclusive - first.start
    val lastWidth = last.endInclusive - last.start
    return abs(line.x - first.start) <= firstWidth * tolerance &&
        abs((line.x + line.w) - last.endInclusive) <= lastWidth * tolerance
}
```

再加字号上限 `行高 <= 中位 * 2.5` 挡掉跨栏大标题。

**原理**：误连行是两个**满栏**行拼接，所以左端贴起始栏左边界、右端贴结束栏右边界；通栏图注是**居中**排版，两端都不贴边。

### 5.3 ⚠️ 两条走不通的判据（iOS 实测，别重踩）

| 判据 | 为什么不行 |
|---|---|
| 行高 ≤ 中位 × 1.15 | **分不开**。实测通栏图注 1.7×、误连行 1.47×，而正文行高本身波动就有 ±50% |
| 栏缝处有词间大空隙 | **iOS 上不可用**。`VNRecognizedText.boundingBox(for:)` 对长行是按字符**均匀插值**的，栏缝的物理空白被压没（实测只剩 0.002 页宽） |

### 5.4 Android 的一个优势（可选增强）

ML Kit 的 `Text.Element.boundingBox` 是**真实几何**，不是插值。所以 Android 上「栏缝处有词间大空隙」这条判据其实是可用的。

**但默认不要启用**：双端判据不一致会让同一张照片在两端产出不同段落，跨端 bug 无法复现。若确实需要，作为**二次确认**叠加在 5.2 主判据之上（两者都成立才切），并同步更新本文与 iOS 实现。

---

## 6. P1 采集质量

| 项 | Android 做法 |
|---|---|
| 文档扫描 | ML Kit Document Scanner（`com.google.android.gms:play-services-mlkit-document-scanner`）：自动找边 + 透视矫正 + 多页。对应 iOS 的 `VNDocumentCameraViewController` |
| 相册图矫正 | 无系统级等价物。可用 OpenCV / 自研四角检测 + `Matrix.setPolyToPoly` 透视变换；**四重保护照搬 iOS**：置信度门槛、四边不退化、面积占比 ≥ 25%、对边长度比 ≤ 2.0，任一不满足就原样返回 |
| 质量闸 | 最短边像素 < 900 或拉普拉斯方差 < 55（在 **512 宽灰度缩略图**上测，与原图分辨率无关）→ 提示重拍 |
| 多页合并 | 合并为**纯文本文档**而不是多图 —— 多页是「一份文件」不是「一张照片」，照片叠加在多图上无处安放 |

**矫正后的图像必须同时用于 OCR 与显示**，否则词框与画面对不上。

质量提示的时机：识别**成功**时不提示（用户已经在听，弹窗只是打扰）；只有**失败**时把「为什么」和「怎么改」一起说清楚：

```
未识别到文字
画面有点模糊，端稳手机重拍会识别得更准
```

---

## 7. P2 让用户选「读哪一块」

一张报纸照片常包含好几篇文章。

**做法：用户在原图上拖框选区**，不做自动文章分割。

> iOS 原方案设想「自动识别文章块 + 自动选主块」，实测放弃：报纸文章跨栏续接、共用大标题、被图片和广告打断，自动分割是研究级难题，**猜错比不猜更糟** —— 用户会得到一篇被腰斩的文章还不知道为什么。

- 触发条件：照片源 + 多栏 + 可定位段落 ≥ 6。**单栏、短页面完全不打扰**。
- 裁剪判据：段落与选框重叠 ≥ **段落自身面积的 50%**（擦到边的不进来，框住大部分的不漏掉）。
- 选区落空 → **回退整页**，绝不产出空文档。
- 裁剪后段落索引连续重排，否则标注锚定会错位。
- 选择发生在**进入播放器之前**，不触碰播放器生命周期。

---

## 8. P3 回归集（**fixture 可直接复用**）

iOS 已把真实报纸照片的行几何入库，Android 可直接拿来跑同一套断言：

| fixture | 内容 | 锁住什么 |
|---|---|---|
| `CastReaderTests/Fixtures/ocr-layout-three-column-newspaper.json` | Stars and Stripes 1944-04-25 p3（公有领域），297 行 | 3 栏识别、**无块横跨两列**、块内行自上而下、不丢行不重复 |
| `CastReaderTests/Fixtures/ocr-layout-skewed-single-column.json` | 手持拍摄、约 12° 倾斜 | 倾斜不被误判成分栏 |

复制到 `app/src/test/resources/`。格式（**归一化坐标，原点左上**）：

```json
{ "name": "...", "expectedColumns": 3,
  "lines": [ { "id": 0, "x": 0.11, "y": 0.28, "w": 0.25, "h": 0.009, "n": 34 } ] }
```

`n` 是原始行的字符数，**文本本身不入库**（报纸正文有版权，而版面分析只吃几何）。构造测试输入时用 `"x".repeat(n.coerceAtMost(60))` 占位即可。

**核心不变量**（对应 iOS `testNoBlockSpansTwoColumns`）：每个栏内块的所有行必须落在同一列。这正是修复前失败的地方，是整套回归里最该先写的一条。

建议 Android 侧同时补：单栏不误判、跨栏标题排在栏组之前、页码不进朗读文本、空/超短输入安全回落。

### 8.1 埋点（需双端同批提交）

事件 `ocr_layout_result`，字段：`columns`、`layoutConfidenceBucket`、`fallbackReason`、`lineCount`、`headingCount`/`bodyCount`/`captionCount`/`furnitureCount`、`language`、`engine`。

**严禁**携带 `content`/`text`/`ocrText`/`imageData`/`title`/`fileName`。

> ⚠️ `scripts/verify_mobile_analytics_contract.rb` 会三方比对 iOS Swift 定义、Android Kotlin 定义与 `docs/analytics/mobile-events-v2.json`，**单方面加事件必然让校验失败**，所以两端要同批提交。
>
> 两条现状记录：
> 1. 跑该脚本需要 UTF-8 环境（`LANG=en_US.UTF-8 RUBYOPT="-EUTF-8"`），否则 Ruby 以 US-ASCII 读带中文注释的源码会抛 `invalid byte sequence`。
> 2. 该校验**当前本就是失败的** —— Android 的契约副本 `app/src/main/assets/contracts/mobile-events-v2.json` 落后于 iOS，缺 `se/tr/ae/sg/pl/eg/sa` 等 storefront 值。加事件前需先把这份副本对齐。

---

## 9. 验收标准

| # | 标准 | 验证方式 |
|---|---|---|
| 1 | 多栏报纸照片的段落顺序 = 人眼阅读顺序，无跨栏拼接 | fixture + 真机拍一张报纸 |
| 2 | 跨栏大标题排在其所属栏组之前 | fixture 断言 |
| 3 | 页码 / 刊头不进入朗读文本 | fixture 断言 |
| 4 | **单栏文档段落切分与改造前一致**（仅额外剔除版面家具） | 现有 Kindle/照片用例回归，零退化 |
| 5 | 分析低置信 → 回落原路径，不抛错、不空文档 | 单测构造噪声输入 |
| 6 | 九语不回归（含日文竖排、Hindi） | 现有多语用例 |
| 7 | 双端同一 fixture 得到相同列数与块归属 | 两端跑同一份 JSON |

---

## 10. 落地进度

### ✅ P0 已实现（547 tests / 0 failures）

| 文件 | 内容 |
|---|---|
| `util/ocr/OcrLayoutAnalyzer.kt` | 新增：列检测、阅读顺序、角色分类、诊断打分 |
| `kindle/KindleOcrParagrapher.kt` | 接入：两阶段分析、按块聚类、误连行按词切分、家具过滤 |
| `test/.../OcrLayoutAnalyzerTest.kt` | 10 个合成用例，与 iOS 逐条对齐 |
| `test/.../OcrLayoutFixtureTest.kt` | 4 个真实报纸用例，**与 iOS 共用 fixture** |
| `test/.../OcrColumnParagraphingTest.kt` | 5 个端到端用例（验证接入，不只是分析器） |
| `test/resources/ocr-layout-*.json` | 从 iOS 仓库复制的真实版面几何 |

**跨端一致性已验证**：两个独立实现（Swift / Kotlin）在同一份真实报纸数据（297 行）上得到完全相同的结果 —— 3 栏、无块横跨两列、块内行自上而下。

#### 实现过程中的两个测试教训

1. **跨块缝合会把整页连成一段**。测试数据若每行都不以句号结尾，「一栏底部续到下一栏顶部」的缝合规则会把三栏 36 行全连起来。这是**设计行为**（真实报纸的文章确实跨栏续接），但意味着构造测试数据时要让句子正常收尾，否则测的不是列约束。
2. **误连行切开后，右半段的 `left` 落在栏缝里**。断言「是否跨栏」不能用栏缝中点当分界，要用**栏主体**范围，否则正确结果会被误判成失败。

### ✅ P1 质量闸已实现

| 文件 | 内容 |
|---|---|
| `util/ocr/ImageQualityAssessor.kt` | 分辨率 + 拉普拉斯方差（512 宽灰度缩略图上测，与原图分辨率无关），与 iOS 同阈值 |
| `ui/screens/capture/CaptureViewModel.kt` | 识别**失败**时才附上采集建议；成功时保持沉默 |
| `test/.../ImageQualityAssessorTest.kt` | 7 个用例 |

核心算法做成接受灰度数组的纯函数（`Bitmap` 在 JVM 单测里不可用），Bitmap 版本只是包装 —— 这样判据和方差计算都能单测。

### ✅ P2 框选区域已实现

| 文件 | 内容 |
|---|---|
| `util/ocr/OcrRegionCropper.kt` | 裁剪判据（重叠 ≥ 段落自身面积 50%、落空回退整页）+ 触发条件 |
| `ui/screens/capture/CaptureRegionPicker.kt` | Compose 拖框选区（aspectFit 几何、遮罩挖洞） |
| `data/model/Ocr.kt` | `OcrPage.columnCount`（默认 1，兼容历史数据） |
| `test/.../OcrRegionCropperTest.kt` + `CaptureRegionGeometryTest.kt` | 6 + 7 个用例 |

**关键决定：选区做成 `CaptureScreen` 内的覆盖层，不新增导航目的地。** `CastReaderNavHost.kt` 当前有 523 行在途改动（`weread-explain-and-background-reading` 分支），加路由必然撞车；覆盖层方案完全不碰导航栈，返回键语义也保持不变（选区界面上按返回 = 回到取景）。

### ⏳ 待办

| 阶段 | 状态 | 备注 |
|---|---|---|
| P1 ML Kit Document Scanner | 未开始 | 需加依赖 `play-services-mlkit-document-scanner`（APK 体积 + 依赖 Google Play 服务，属产品决策）；不碰导航，改动面在 `CaptureScreen` 的拍摄入口 |
| P1 相册图透视矫正 | 未开始 | ⚠️ Android **没有** `VNDetectDocumentSegmentationRequest` 的系统级等价物，需要 OpenCV 依赖或自研四角检测，工作量与风险都明显高于 iOS，建议单独评估 |
| P3 埋点 | 未开始 | 需与 iOS 同批，且要先对齐落后的契约副本 |

**当前状态：567 tests / 0 failures，`assembleDebug` 通过。** 多栏报纸的阅读顺序、采集质量提示、框选区域都已可用，可以真机验收。
