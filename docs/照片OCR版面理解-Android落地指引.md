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

## 3. 核心：`OcrLayoutAnalyzer.kt`（递归 XY-Cut）

iOS 的 `CastReader/Services/OCRLayoutAnalyzer.swift` 是**纯几何算法，无平台依赖**，1:1 回译到 `app/src/main/java/com/same/castreader/util/ocr/OcrLayoutAnalyzer.kt`。

### 3.0 为什么是递归分解，而不是「整页 → 列」

这是本方案最重要的一条，也是最初两层实现失败的根因。

报纸**不是**「页面 → 栏」的两层结构，而是**递归的矩形分割**：区域里还有区域，并列的两篇文章各自再分栏。固定层数表达不了这件事 —— 侧边那篇被裁切的文章会被当成主文的一栏，内容按层切碎后散插进主文的阅读流（实测主文开始前混进了 25 行碎片）。

正确模型是经典 **Recursive XY-Cut**（Nagy & Seth, 1984）：

```
decompose(lines):
  1. 收集所有候选切割（横切 + 竖切），按显著性排序
  2. 依次尝试，取第一条真正切得开的
  3. 对切出的两侧分别递归
  4. 切不动则成为叶子

阅读顺序 = 深度优先遍历
```

**每次只切一刀**。一次切成 N 份会退化回固定层数。

产出的是区域树：

```
stack ↓                      ← 横切
  图注区
  stack ↓
    大标题区
    row →                    ← 竖切
      栏1  栏2  栏3  栏4
    页脚区
```

副产品：**「跨栏横幅」这个特例消失了**。标题与正文之间有横向空白，自然被横切分成独立区域，不需要专门的 banner 逻辑。特例减少是结构变对的信号。

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
object Tuning {
    const val PROJECTION_BINS = 600           // 报纸栏缝约 1% 页宽，粗直方图会整条吞掉
    const val COVERAGE_VALLEY_RATIO = 0.22    // 覆盖低于峰值该比例即视为空白
    const val GAP_SHOULDER_RATIO = 0.30       // 竖缝两侧必须是实打实的正文（横切不适用，见 3.4）
    const val SHOULDER_WINDOW_RATIO = 0.05    // 判断「两侧有内容」时向外看多宽
    const val ZONE_BAND_HEIGHT_RATIO = 2.2    // 横切带至少这么多倍行高
    const val FULL_WIDTH_LINE_RATIO = 0.75    // 达到正文区宽度此比例即「通栏元素」

    const val MAX_DECOMPOSE_DEPTH = 8         // 递归深度上限
    const val MIN_LINES_TO_SPLIT = 6          // 少于此不再往下切
    const val MIN_LINES_PER_REGION = 1        // 一个区可以只有一行（大标题）

    const val EDGE_STRIP_WIDTH_RATIO = 0.22   // 边缘窄栏：多窄
    const val EDGE_STRIP_MARGIN_RATIO = 0.18  // 边缘窄栏：多贴边
    const val MIN_LINES_FOR_EDGE_STRIP = 6
    const val EDGE_STRIP_COVERAGE_RATIO = 0.6 // 纵向跨度 ≥ 主体的多少才算「贯穿」

    const val MAX_SKEW_DEGREES = 12.0         // 倾角搜索范围
    const val SKEW_STEP_DEGREES = 0.5
    const val MIN_LINES_FOR_SKEW = 16
    const val MIN_LINES_FOR_ORIENTATION = 6   // 方向推断的最少行数

    const val FURNITURE_BAND_RATIO = 0.06     // 顶/底版面家具带
    const val MIN_COLUMN_CONFIDENCE = 0.45
    const val MAX_COLUMNS = 6
}
```

还有两项**在分解之前**跑，缺了会让后面全白做：

- **倾角矫正（deskew）**：手持拍摄斜几度，栏就不再垂直，投影把栏缝整条抹平（实测直接 no-gaps → 整页乱序）。在 ±12° 内搜索使栏缝最清晰的角度，**只用于分析**，输出仍是原始行 id，所以 bbox 与画面依旧对得上。
- **页面方向推断**：报纸常横着拍，EXIF 解决不了这种**内容级**旋转。单次 OCR 的行几何 + 识别器返回顺序即可推断（`wideShare * 0.6 + orderScore * 0.4`），零额外识别成本。

改任一数值都要同步改 iOS，并跑两端的 fixture 回归（第 8 节）。

### 3.3 切割的显著性

```kotlin
val score = depth * (extent / (2 + extent))
```

- **`depth`（贯穿度，主项）**：空白带内最低覆盖相对两侧峰值的下降幅度。贯穿全高的竖缝（分隔并列的两篇文章）因此能排在被跨栏标题打断的横缝之前 —— 这正是固定两层做不到的。
- **`extent`（带宽）**：相对典型行高的倍数，用**平滑饱和**而非硬上限。

> ⚠️ **不要写成 `min(1.5, extent)`**。硬上限会把「3.75 倍行高的区间隔」和「2.5 倍行高的栏缝」压成同一个数，有意义的差异丢失，谁先谁后退化成看数组顺序 —— iOS 实测因此把跨栏标题切进了第一栏。

**同分时横切优先**（文档天然自上而下流动，先分区再分栏，XY-Cut 的标准取向）。不定这条规则，同分时结果取决于数组顺序，同一版面可能时而先分区、时而先分栏。

### 3.4 两个轴必须对称处理

各自要先剥掉会把自己那条缝填平的干扰项：

| 轴 | 怕什么 | 剥离函数 |
|---|---|---|
| 竖切 | **通栏元素**（大标题、通栏图注横穿每一条栏缝） | `columnarCandidates` |
| 横切 | **贯穿全高的窄边栏**（报纸边缘被裁切的文章从头通到尾，把所有横向区域分隔填平，层级建立不起来） | `zoneCandidates` |

只做前者不做后者，是 iOS 实现里踩到的坑：顶层一条横切都找不到，只能一路竖切。

**`shoulder` 判据两个轴的语义也不同**：

```kotlin
val shoulder = if (axis == HORIZONTAL) 1.0 else peak * GAP_SHOULDER_RATIO
```

竖切要求缝两侧都是实打实的正文；横切只要求两侧都有行 —— **一个区的厚度完全可以只有一行**（大标题本身就是一个区），拿正文区的峰值去卡它，区永远分不出来。区的厚度可以是一行，栏的宽度不会只有一个字。

同理 `MIN_LINES_PER_REGION = 1`，不是 2。

### 3.4.1 通栏行必须提升到父层

竖切时**跨越切割线的行不能按 midX 硬分给某一栏**。

通栏元素（大标题、页脚地址、通栏图注）不属于任何一栏 —— 它在版面上位于栏组的上方或下方，层级比栏更高。按 midX 分给某一栏，它就会黏在那一栏尾巴上读出来（iOS 实测页脚被接到了最后一栏后面）。

```
stack ↓
  ├── 栏组上方的通栏行
  ├── row → [左栏, 右栏]
  └── 栏组下方的通栏行     ← 页脚落这里
```

这同时消掉了一处自相矛盾：找栏缝时剥离通栏行、执行切割时却又把它们切进去。

### 3.4.2 边缘窄栏整块拆出

报纸边缘那篇被裁切的文章贯穿全高，参与分解会被横切切碎。用 `detachEdgeStrip` 在分解**之前**整块拆成独立区域，按 x 排在主体之后。

判据三条缺一不可：**窄**、**贴边**、**纵向跨度 ≥ 主体的 60%**。只有零星几行、或纵向只占一小段的不算 —— 那多半是图注或角标，拆出去反而打乱顺序。

拆出来的边栏**自己也要递归分解**（它可能是好几段），不能直接当叶子。

### 3.4.3 遍历时不要重排子节点

```kotlin
// ❌ 错的
is Node.Row -> children.sortedBy { minX(it) }.flatMap(::orderedLeaves)
// ✅ 对的
is Node.Row -> children.flatMap(::orderedLeaves)
```

`decompose` 切出的 `[前, 后]` 顺序本来就对。子树内部可以横跨很大范围，拿它的 minX 去和兄弟比较会把整棵子树排错位置 —— iOS 实测把正文第 2 栏甩到了最后读。

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

### ✅ 全部已实现（567 tests / 0 failures，`assembleDebug` 通过）

| 文件 | 内容 |
|---|---|
| `util/ocr/OcrLayoutAnalyzer.kt` | **递归 XY-Cut**：区域树、倾角矫正、方向推断、边栏拆分、通栏行提升、角色分类 |
| `kindle/KindleOcrParagrapher.kt` | 两阶段分析、按叶子聚类、误连行按词切分、家具过滤、多栏路径全链路保序 |
| `util/ocr/ImageQualityAssessor.kt` | 分辨率 + 拉普拉斯方差，与 iOS 同阈值 |
| `util/ocr/OcrRegionCropper.kt` | 选区裁剪判据（重叠 ≥ 50%、落空回退整页） |
| `ui/screens/capture/CaptureRegionPicker.kt` | Compose 拖框选区 |
| `ui/screens/capture/CaptureViewModel.kt` | 三态结果（READY / NEEDS_REGION / FAILED）、失败时附采集建议 |
| `test/.../OcrLayoutAnalyzerTest.kt` 等 5 个测试文件 | 合成用例 + **与 iOS 共用的真实报纸 fixture** + 端到端接入用例 |

**跨端一致性**：两个独立实现（Swift / Kotlin）在同一份真实报纸几何（297 行）上得到相同结果。

### ⏳ 待办

| 阶段 | 状态 | 备注 |
|---|---|---|
| ML Kit Document Scanner | 未开始 | 需加 `play-services-mlkit-document-scanner` 依赖（APK 体积 + 依赖 Google Play 服务，属产品决策）；不碰导航，改动面在 `CaptureScreen` 拍摄入口 |
| 方向推断接入 | 未开始 | 分析器已提供 `quarterTurnsToUpright`，需要在 `MultilingualOcrCoordinator` / `CaptureViewModel` 侧调用并旋转 Bitmap（**必须用高精度识别探测**，见下方踩坑） |
| 相册图透视矫正 | 未开始 | ⚠️ Android **没有** `VNDetectDocumentSegmentationRequest` 的等价物，需 OpenCV 或自研四角检测，建议单独评估 |
| 埋点 | 未开始 | 需与 iOS 同批，且要先对齐落后的契约副本 |

---

## 11. 已知限制

- **被 OCR 误连的跨栏行**在递归结构下被**提升为独立区域**，而不是按列切开。内容仍是「左栏尾 + 右栏头」的拼接，但**不会打断其他栏的连贯**。真正切开需要词级信息，是 `KindleOcrParagrapher` 两阶段切分的职责。
- 真实报纸 fixture 上仍有约 2/11 的块跨栏（正文栏窄、印刷与扫描噪声大）。测试守的是**比例 ≤ 20%**，不是零 —— 回归到大面积跨栏时会立刻报警。
- deskew 只能矫正**旋转**，矫正不了**梯形畸变**。严重透视的照片仍会掉栏，建议走文档扫描器。

---

## 12. iOS 实现过程中踩过的坑（Android 别重踩）

这些都不是调参能发现的，全部来自真实照片实测：

| 坑 | 现象 | 正解 |
|---|---|---|
| 用 `.fast` 级别做方向探测 | 横放的页面只认出 3 行（accurate 是 197 行），方向直接判反 | **必须 accurate**；缩图到最长边 900px 把耗时压到 0.5–0.8s |
| `min(1.5, extent)` 硬上限 | 区间隔与栏缝压成同一个分数，谁先谁后看数组顺序 | 平滑饱和 `extent / (2 + extent)` |
| 只试最优的一刀 | 横切排前面但切不开时直接放弃，竖切没机会 → 正文变成「同一行三栏并排读」 | 按显著性**依次尝试**直到切得开 |
| 遍历时按 minX 重排子节点 | 子树内部横跨大范围，整棵被排错位置 → 第 2 栏甩到最后读 | 信任 `decompose` 的顺序，不重排 |
| `MIN_LINES_PER_REGION = 2` | 单行大标题切不出来，被塞进第一栏开头 | 取 1 |
| 竖切按 midX 硬分通栏行 | 页脚黏在最后一栏尾巴上 | 提升到父层（3.4.1） |
| 边栏拆分后传 `depth = 1` | 白白浪费一层递归预算，跨栏块从 18% 涨到 31% | 传 0，拆分是预处理不算一层 |
| `columnRanges` 取最外层 | 递归后最外层只有两支，误连行切分判据失效 | 取**叶子级**并排除通栏叶子 |
